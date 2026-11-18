import Foundation

/// Codex (ChatGPT plan) usage, using the login the Codex CLI stored in `auth.json`.
struct CodexProvider: UsageProvider {
    let id: ProviderID = .codex

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let authStore: CodexAuthStore

    init(authStore: CodexAuthStore = .shared) {
        self.authStore = authStore
    }

    func fetch() async throws -> ProviderSnapshot {
        var credentials = try await authStore.validCredentials()
        let data: Data

        if let body = try await requestUsage(with: credentials) {
            data = body
        } else {
            // 401: the CLI may have refreshed meanwhile — re-read auth.json once.
            var current = try await authStore.load()
            var body: Data?
            if current.accessToken != credentials.accessToken {
                body = try await requestUsage(with: current)
            }
            if body == nil {
                // Still rejected: refresh (gated by autoRefreshTokens) and retry once.
                current = try await authStore.refresh(replacing: current.accessToken)
                body = try await requestUsage(with: current)
            }
            guard let body else { throw ProviderError.unauthorized }
            data = body
            credentials = current
        }

        let now = Date()
        let parsed = try Self.parseUsage(data: data, now: now)
        let account = AccountInfo(
            name: credentials.name ?? credentials.email,
            email: credentials.email,
            plan: Self.planDisplayName(parsed.planType) ?? Self.planDisplayName(credentials.planClaim)
        )
        return ProviderSnapshot(
            provider: .codex,
            account: account,
            session: parsed.session,
            weekly: parsed.weekly,
            extraWindows: parsed.extras,
            fetchedAt: now
        )
    }

    /// GET wham/usage. Returns nil on 401 so the caller can re-read / refresh.
    private func requestUsage(with credentials: CodexCredentials) async throws -> Data? {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CodexSupport.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await CodexSupport.send(request)
        switch response.statusCode {
        case 200..<300:
            if CodexSupport.debugEnabled {
                FileHandle.standardError.write(Data("[CodeUsage] Codex wham/usage response:\n".utf8))
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            return data
        case 401:
            return nil
        default:
            throw ProviderError.http(response.statusCode, CodexSupport.apiErrorMessage(from: data))
        }
    }

    // MARK: - Response mapping

    private enum WindowRole: String {
        case primary
        case secondary
    }

    /// Maps a `wham/usage` response. Windows are classified by `limit_window_seconds`
    /// (<= 1 day → session, else weekly); primary is NOT assumed to be the 5-hour window.
    static func parseUsage(data: Data, now: Date) throws -> (session: UsageWindow?, weekly: UsageWindow?, extras: [NamedWindow], planType: String?) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProviderError.decoding("Codex 사용량 응답이 JSON 이 아닙니다")
        }
        guard let root = object as? [String: Any] else {
            throw ProviderError.decoding("Codex 사용량 응답 형식이 올바르지 않습니다")
        }

        var session: UsageWindow?
        var weekly: UsageWindow?
        var extras: [NamedWindow] = []
        var usedIDs = Set<String>()

        func appendExtra(id baseID: String, label: String, window: UsageWindow) {
            var candidate = baseID
            var counter = 2
            while usedIDs.contains(candidate) {
                candidate = "\(baseID)_\(counter)"
                counter += 1
            }
            usedIDs.insert(candidate)
            extras.append(NamedWindow(id: candidate, label: label, window: window))
        }

        // Main rate limit.
        if let rateLimit = root["rate_limit"] as? [String: Any] {
            for (role, window) in windows(of: rateLimit, now: now) {
                if window.isSessionLength {
                    if session == nil {
                        session = window
                    } else {
                        appendExtra(id: "rate_limit_\(role.rawValue)", label: "추가 \(windowLabel(window.windowSeconds))", window: window)
                    }
                } else {
                    if weekly == nil {
                        weekly = window
                    } else {
                        appendExtra(id: "rate_limit_\(role.rawValue)", label: "추가 \(windowLabel(window.windowSeconds))", window: window)
                    }
                }
            }
        }

        // Additional (feature/model scoped) limits.
        if let additional = root["additional_rate_limits"] as? [Any] {
            for (index, entryAny) in additional.enumerated() {
                guard let entry = entryAny as? [String: Any],
                      let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
                let limitName = CodexSupport.string(entry["limit_name"])
                let feature = CodexSupport.string(entry["metered_feature"])
                let key = limitName ?? feature ?? "additional_\(index)"
                let baseLabel = limitName ?? feature.map(prettifyFeature) ?? "추가 한도"
                for (role, window) in windows(of: rateLimit, now: now) {
                    appendExtra(
                        id: "additional_\(key)_\(role.rawValue)",
                        label: "\(baseLabel) \(windowLabel(window.windowSeconds))",
                        window: window
                    )
                }
            }
        }

        return (session, weekly, extras, CodexSupport.string(root["plan_type"]))
    }

    /// Human readable plan name from the `plan_type` value (or JWT `chatgpt_plan_type` claim).
    static func planDisplayName(_ raw: String?) -> String? {
        guard let raw = CodexSupport.string(raw) else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite", "pro_lite", "pro-lite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default:
            return raw
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: Helpers

    /// Present windows of one `rate_limit` object, in primary/secondary order.
    private static func windows(of rateLimit: [String: Any], now: Date) -> [(WindowRole, UsageWindow)] {
        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]
        var result: [(WindowRole, UsageWindow)] = []
        if let primary {
            result.append((.primary, window(from: primary, role: .primary, hasSibling: secondary != nil, now: now)))
        }
        if let secondary {
            result.append((.secondary, window(from: secondary, role: .secondary, hasSibling: primary != nil, now: now)))
        }
        return result
    }

    private static func window(from raw: [String: Any], role: WindowRole, hasSibling: Bool, now: Date) -> UsageWindow {
        let used = CodexSupport.number(raw["used_percent"]) ?? 0
        let resetAfter = CodexSupport.number(raw["reset_after_seconds"])

        var resetsAt: Date?
        if var resetAt = CodexSupport.number(raw["reset_at"]), resetAt > 0 {
            if resetAt > 100_000_000_000 { resetAt /= 1000 } // tolerate epoch milliseconds
            resetsAt = Date(timeIntervalSince1970: resetAt)
        } else if let resetAfter, resetAfter >= 0 {
            resetsAt = now.addingTimeInterval(resetAfter)
        }

        let seconds: TimeInterval
        if let declared = CodexSupport.number(raw["limit_window_seconds"]), declared > 0 {
            seconds = declared
        } else {
            // No declared length: infer without assuming primary = 5h.
            let remaining = resetAfter ?? resetsAt.map { $0.timeIntervalSince(now) }
            if let remaining, remaining > 18_000 {
                seconds = 604_800
            } else if role == .primary && hasSibling {
                seconds = 18_000
            } else {
                seconds = 604_800
            }
        }

        return UsageWindow(usedPercent: min(max(used, 0), 100), resetsAt: resetsAt, windowSeconds: seconds)
    }

    /// "5시간", "주간", "24시간", "30일" …
    private static func windowLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s == 604_800 { return "주간" }
        if s <= 86_400 {
            if s >= 3_600 && s % 3_600 == 0 { return "\(s / 3_600)시간" }
            if s >= 60 && s % 60 == 0 { return "\(s / 60)분" }
            return "세션"
        }
        if s % 86_400 == 0 { return "\(s / 86_400)일" }
        return "주간"
    }

    private static func prettifyFeature(_ feature: String) -> String {
        let words = feature.replacingOccurrences(of: "_", with: " ").split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
