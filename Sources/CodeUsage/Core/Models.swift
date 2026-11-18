import Foundation

// MARK: - Shared contract. Every other file builds on these types; change them only with care.

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Web page with the provider's own usage dashboard.
    var dashboardURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }
}

/// One rate-limit window (5-hour session or 7-day weekly, or a scoped weekly bucket).
struct UsageWindow: Codable, Equatable, Sendable {
    /// Share of the window used, 0...100.
    var usedPercent: Double
    /// When the window resets. nil when the server reports no running window.
    var resetsAt: Date?
    /// Window length in seconds (18_000 for 5h, 604_800 for 7d).
    var windowSeconds: TimeInterval

    /// Short windows (<= 1 day) are "sessions"; longer ones are "weekly".
    var isSessionLength: Bool { windowSeconds <= 86_400 }

    var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-windowSeconds) } }

    /// True when the window is currently running (has a reset time in the future).
    func isLive(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt > now
    }

    /// Live and actually started. Some servers (Codex) report an idle window as 0 % used with a full-length
    /// reset that moves forward on every fetch; that is not a running session.
    func isActive(now: Date = Date()) -> Bool {
        guard let resetsAt, resetsAt > now else { return false }
        return usedPercent > 0 || resetsAt.timeIntervalSince(now) < windowSeconds - 300
    }
}

struct NamedWindow: Codable, Equatable, Sendable, Identifiable {
    var id: String          // stable key, e.g. "seven_day_opus"
    var label: String       // display label, e.g. "Opus 주간"
    var window: UsageWindow
}

struct AccountInfo: Codable, Equatable, Sendable {
    var name: String?
    var email: String?
    /// Human readable plan, e.g. "Team", "Max", "Pro", "Plus", "Pro Lite".
    var plan: String?
}

struct ProviderSnapshot: Codable, Equatable, Sendable {
    var provider: ProviderID
    var account: AccountInfo
    /// The 5-hour (or other <= 1 day) window, if the plan has one.
    var session: UsageWindow?
    /// The all-models 7-day window, if the plan has one.
    var weekly: UsageWindow?
    /// Additional scoped windows (per-model weekly limits, etc.), in server order.
    var extraWindows: [NamedWindow]
    var fetchedAt: Date

    /// True when a session window exists and is currently running.
    func hasLiveSession(now: Date = Date()) -> Bool {
        session?.isActive(now: now) ?? false
    }

    /// The single window the menu bar shows for this provider:
    /// the current session while one is running, otherwise the weekly limit.
    func menuBarWindow(now: Date = Date()) -> UsageWindow? {
        if let session, session.isActive(now: now) { return session }
        return weekly ?? session
    }
}

enum ProviderError: Error, Equatable, LocalizedError, Sendable {
    /// No local CLI login found. Associated text tells the user how to log in.
    case notLoggedIn(String)
    /// Token expired and could not be refreshed.
    case tokenExpired(String)
    case unauthorized
    case http(Int, String?)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let hint): return hint
        case .tokenExpired(let hint): return hint
        case .unauthorized: return "인증이 거부되었습니다. 다시 로그인하세요."
        case .http(let code, let msg): return "HTTP \(code)" + (msg.map { ": \($0)" } ?? "")
        case .network(let msg): return "네트워크 오류: \(msg)"
        case .decoding(let msg): return "응답 해석 실패: \(msg)"
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Fetch fresh usage. Must never log or return secrets.
    func fetch() async throws -> ProviderSnapshot
}

/// One stored sample used for history charts and burn-rate estimates.
struct UsageSample: Codable, Equatable, Sendable {
    var date: Date
    var sessionPercent: Double?
    var sessionResetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
}
