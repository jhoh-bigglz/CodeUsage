import Foundation

/// Claude plan usage via the Claude Code OAuth login on this Mac.
final class ClaudeProvider: UsageProvider {
    let id: ProviderID = .claude

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    static let sessionWindowSeconds: TimeInterval = 18_000
    static let weeklyWindowSeconds: TimeInterval = 604_800

    private let tokens = ClaudeTokenManager()
    private let profiles = ClaudeProfileCache()

    init() {}

    func fetch() async throws -> ProviderSnapshot {
        let autoRefresh = (UserDefaults.standard.object(forKey: SettingsKey.autoRefreshTokens) as? Bool)
            ?? SettingsDefaults.autoRefreshTokens

        let (json, creds) = try await fetchUsage(autoRefresh: autoRefresh)
        let now = Date()
        let parsed = Self.parseUsage(json)
        if parsed.session == nil, parsed.weekly == nil, parsed.extras.isEmpty {
            throw ProviderError.decoding("사용량 정보가 응답에 없습니다")
        }

        let profile = await profiles.profile(accessToken: creds.accessToken)
        let account = AccountInfo(
            name: profile?.name,
            email: profile?.email,
            plan: profile?.plan ?? Self.planName(subscriptionType: creds.subscriptionType)
        )

        return ProviderSnapshot(
            provider: .claude,
            account: account,
            session: parsed.session,
            weekly: parsed.weekly,
            extraWindows: parsed.extras,
            fetchedAt: now
        )
    }

    // MARK: Usage request with 401 handling

    /// 1. use stored credentials (refreshing first when they expire within 60 s);
    /// 2. on 401, re-read the store once (Claude Code may have refreshed meanwhile) and retry with a changed token;
    /// 3. if still 401, refresh (when allowed) and retry once more.
    private func fetchUsage(autoRefresh: Bool) async throws -> ([String: Any], ClaudeCredentials) {
        var creds = try await tokens.validCredentials(autoRefresh: autoRefresh)
        do {
            return (try await Self.requestUsage(creds.accessToken), creds)
        } catch ProviderError.unauthorized {}

        let reread = try await tokens.validCredentials(autoRefresh: autoRefresh)
        if reread.accessToken != creds.accessToken {
            creds = reread
            do {
                return (try await Self.requestUsage(creds.accessToken), creds)
            } catch ProviderError.unauthorized {}
        }

        guard autoRefresh else { throw ClaudeTokenManager.tokenExpiredError }
        creds = try await tokens.refresh(rejectedAccessToken: creds.accessToken)
        return (try await Self.requestUsage(creds.accessToken), creds)
    }

    static func authHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
        ]
    }

    private static func requestUsage(_ accessToken: String) async throws -> [String: Any] {
        try await HTTP.getJSON(usageURL, headers: authHeaders(accessToken), debugLabel: "Claude usage")
    }

    // MARK: Mapping

    struct ParsedUsage {
        var session: UsageWindow?
        var weekly: UsageWindow?
        var extras: [NamedWindow]
    }

    /// Maps the usage response. Prefers `limits[]`; falls back to `five_hour` / `seven_day` (+ opus/sonnet extras).
    static func parseUsage(_ json: [String: Any]) -> ParsedUsage {
        var result = ParsedUsage(session: nil, weekly: nil, extras: [])
        var usedIDs = Set<String>()

        func uniqueID(_ base: String) -> String {
            var candidate = base
            var n = 2
            while usedIDs.contains(candidate) {
                candidate = "\(base)#\(n)"
                n += 1
            }
            usedIDs.insert(candidate)
            return candidate
        }

        let limits = (HTTP.array(json["limits"]) ?? []).compactMap { HTTP.dict($0) }
        if !limits.isEmpty {
            for row in limits {
                guard let kind = HTTP.string(row["kind"]) else { continue }
                let group = HTTP.string(row["group"])?.lowercased()
                let percent = max(0, HTTP.double(row["percent"]) ?? HTTP.double(row["utilization"]) ?? 0)
                let resetsAt = HTTP.date(row["resets_at"])
                let scopeName = Self.scopeDisplayName(row["scope"])

                if kind == "session", scopeName == nil, result.session == nil {
                    result.session = UsageWindow(usedPercent: percent, resetsAt: resetsAt, windowSeconds: sessionWindowSeconds)
                    continue
                }
                if kind == "weekly_all", scopeName == nil, result.weekly == nil {
                    result.weekly = UsageWindow(usedPercent: percent, resetsAt: resetsAt, windowSeconds: weeklyWindowSeconds)
                    continue
                }

                let isSessionGroup = group == "session" || (group == nil && kind == "session")
                let windowSeconds = isSessionGroup ? sessionWindowSeconds : weeklyWindowSeconds
                let label: String
                if let scopeName {
                    label = "\(scopeName) \(isSessionGroup ? "세션" : "주간")"
                } else {
                    label = HTTP.string(row["label"]) ?? kind
                }
                let idBase = scopeName.map { "\(kind):\(Self.slug($0))" } ?? kind
                result.extras.append(NamedWindow(
                    id: uniqueID(idBase),
                    label: label,
                    window: UsageWindow(usedPercent: percent, resetsAt: resetsAt, windowSeconds: windowSeconds)
                ))
            }
            // Fill anything limits[] did not cover from the legacy fields.
            if result.session == nil { result.session = legacyWindow(json["five_hour"], seconds: sessionWindowSeconds) }
            if result.weekly == nil { result.weekly = legacyWindow(json["seven_day"], seconds: weeklyWindowSeconds) }
            return result
        }

        result.session = legacyWindow(json["five_hour"], seconds: sessionWindowSeconds)
        result.weekly = legacyWindow(json["seven_day"], seconds: weeklyWindowSeconds)
        for (key, label) in [("seven_day_opus", "Opus 주간"), ("seven_day_sonnet", "Sonnet 주간")] {
            if let window = legacyWindow(json[key], seconds: weeklyWindowSeconds) {
                result.extras.append(NamedWindow(id: uniqueID(key), label: label, window: window))
            }
        }
        return result
    }

    /// `{"utilization": 9.0, "resets_at": "..."}` → window; nil when the field is null/absent.
    private static func legacyWindow(_ value: Any?, seconds: TimeInterval) -> UsageWindow? {
        guard let dict = HTTP.dict(value) else { return nil }
        let utilization = HTTP.double(dict["utilization"]) ?? HTTP.double(dict["percent"])
        let resetsAt = HTTP.date(dict["resets_at"])
        if utilization == nil, resetsAt == nil { return nil }
        return UsageWindow(usedPercent: max(0, utilization ?? 0), resetsAt: resetsAt, windowSeconds: seconds)
    }

    /// `scope.model.display_name` ?? `scope.surface.display_name`.
    private static func scopeDisplayName(_ value: Any?) -> String? {
        guard let scope = HTTP.dict(value) else { return nil }
        for key in ["model", "surface"] {
            if let entry = HTTP.dict(scope[key]),
               let name = HTTP.string(entry["display_name"]) ?? HTTP.string(entry["name"]) {
                return name
            }
        }
        return nil
    }

    private static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(mapped)
    }

    // MARK: Plan names

    /// "claude_team" → "Team", "claude_max" → "Max", "claude_enterprise" → "Enterprise", "foo_bar" → "Foo Bar".
    static func planName(organizationType: String?) -> String? {
        guard var raw = organizationType?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("claude_") { raw.removeFirst("claude_".count) }
        return prettyPlan(raw)
    }

    /// Credentials `subscriptionType` ("team", "max", "pro", ...) capitalized.
    static func planName(subscriptionType: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        return prettyPlan(raw)
    }

    private static func prettyPlan(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Token management

/// Serializes credential reads and refreshes so two fetches never refresh concurrently.
actor ClaudeTokenManager {
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let expiryMargin: TimeInterval = 60

    static let tokenExpiredError = ProviderError.tokenExpired("Claude Code 토큰이 만료되었습니다. 터미널에서 claude 를 한 번 실행하세요")

    /// Refreshed credentials that could not be written back, together with the stored access token they replace.
    /// Used until the store changes (e.g. Claude Code refreshes or logs in again).
    private var memoryOverride: (replacedAccessToken: String, creds: ClaudeCredentials)?
    private var inFlightRefresh: Task<ClaudeCredentials, Error>?

    /// Current credentials from the store (or the in-memory override), without refreshing.
    func current() async throws -> ClaudeCredentials {
        let stored: ClaudeCredentials
        do {
            stored = try await ClaudeCredentialStore.load()
        } catch {
            if let memoryOverride { return memoryOverride.creds }
            throw error
        }
        if let override = memoryOverride {
            if stored.accessToken == override.replacedAccessToken { return override.creds }
            memoryOverride = nil
        }
        return stored
    }

    /// Credentials that are not about to expire, refreshing when allowed.
    func validCredentials(autoRefresh: Bool) async throws -> ClaudeCredentials {
        if let inFlightRefresh { return try await inFlightRefresh.value }
        let creds = try await current()
        guard creds.expires(within: Self.expiryMargin) else { return creds }
        guard autoRefresh else { throw Self.tokenExpiredError }
        return try await refresh(rejectedAccessToken: creds.accessToken)
    }

    /// Refreshes the token unless the store already holds a different, still-valid one.
    /// Concurrent callers share one refresh.
    func refresh(rejectedAccessToken: String?) async throws -> ClaudeCredentials {
        if let inFlightRefresh { return try await inFlightRefresh.value }
        let task = Task { try await self.performRefresh(rejectedAccessToken: rejectedAccessToken) }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performRefresh(rejectedAccessToken: String?) async throws -> ClaudeCredentials {
        // Re-read right before refreshing: Claude Code may have refreshed meanwhile.
        let latest = try await current()
        if let rejectedAccessToken, latest.accessToken != rejectedAccessToken, !latest.expires(within: Self.expiryMargin) {
            return latest
        }
        guard let refreshToken = latest.refreshToken, !latest.refreshTokenExpired else {
            throw Self.tokenExpiredError
        }
        // Refresh tokens rotate: never refresh unless the result can be stored for Claude Code too.
        guard ClaudeCredentialStore.canWriteBack(latest) else { throw Self.tokenExpiredError }

        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        if !latest.scopes.isEmpty {
            body["scope"] = latest.scopes.joined(separator: " ")
        }

        let response: [String: Any]
        do {
            response = try await HTTP.postJSON(Self.tokenURL, body: body)
        } catch ProviderError.unauthorized {
            throw Self.tokenExpiredError
        } catch ProviderError.http(let code, _) where (400..<500).contains(code) && code != 429 {
            // invalid_grant / revoked refresh token: the user must re-run Claude Code.
            throw Self.tokenExpiredError
        } catch ProviderError.decoding {
            throw ProviderError.decoding("토큰 갱신 응답을 해석할 수 없습니다")
        }

        guard let accessToken = HTTP.string(response["access_token"]) else {
            throw ProviderError.decoding("토큰 갱신 응답에 access_token 이 없습니다")
        }
        let newScopes = HTTP.string(response["scope"]).map {
            $0.split(separator: " ").map(String.init)
        }
        guard let refreshed = ClaudeCredentialStore.applyingRefresh(
            to: latest,
            accessToken: accessToken,
            refreshToken: HTTP.string(response["refresh_token"]),
            expiresIn: HTTP.double(response["expires_in"]),
            refreshTokenExpiresIn: HTTP.double(response["refresh_token_expires_in"]),
            scopes: newScopes
        ) else {
            throw ProviderError.decoding("갱신된 자격 증명을 만들 수 없습니다")
        }

        do {
            try await ClaudeCredentialStore.write(refreshed)
            memoryOverride = nil
        } catch {
            // Keep working with the new token in memory; the store still holds the old one.
            // When an override is already active, `latest` is that override, not what the store holds:
            // keep recording the stored token so the next `current()` still recognises it.
            memoryOverride = (memoryOverride?.replacedAccessToken ?? latest.accessToken, refreshed)
            if HTTP.isDebug {
                FileHandle.standardError.write(Data("[CodeUsage debug] Claude credential write-back failed\n".utf8))
            }
        }
        return refreshed
    }
}

// MARK: - Profile cache

struct ClaudeProfile: Sendable, Equatable {
    var name: String?
    var email: String?
    var plan: String?
}

/// Caches `/api/oauth/profile` for about an hour. Failures never propagate.
actor ClaudeProfileCache {
    static let maxAge: TimeInterval = 3600
    static let retryAfterFailure: TimeInterval = 300

    private var cached: ClaudeProfile?
    private var fetchedAt: Date?
    private var lastFailure: Date?

    func profile(accessToken: String) async -> ClaudeProfile? {
        let now = Date()
        if let cached, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.maxAge { return cached }
        if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryAfterFailure { return cached }
        do {
            let json = try await HTTP.getJSON(ClaudeProvider.profileURL, headers: ClaudeProvider.authHeaders(accessToken))
            let profile = Self.parse(json)
            cached = profile
            fetchedAt = Date()
            lastFailure = nil
            return profile
        } catch {
            lastFailure = Date()
            return cached
        }
    }

    static func parse(_ json: [String: Any]) -> ClaudeProfile {
        let account = HTTP.dict(json["account"]) ?? [:]
        let organization = HTTP.dict(json["organization"]) ?? [:]
        return ClaudeProfile(
            name: HTTP.string(account["display_name"]) ?? HTTP.string(account["full_name"]),
            email: HTTP.string(account["email"]) ?? HTTP.string(account["email_address"]),
            plan: ClaudeProvider.planName(organizationType: HTTP.string(organization["organization_type"]))
        )
    }
}
