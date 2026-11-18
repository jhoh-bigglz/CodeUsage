import Foundation

/// UserDefaults keys and defaults. Views use @AppStorage(SettingsKey.x) with these defaults.
enum SettingsKey {
    /// Polling interval in seconds. Default 120.
    static let refreshInterval = "refreshInterval"
    /// When a CLI token is expired, refresh it with its refresh token and write it back
    /// to the CLI's own store (Claude Code keychain item / ~/.codex/auth.json). Default true.
    static let autoRefreshTokens = "autoRefreshTokens"
    /// Show Claude in the menu bar. Default true.
    static let showClaudeInMenuBar = "showClaudeInMenuBar"
    /// Show Codex in the menu bar. Default true.
    static let showCodexInMenuBar = "showCodexInMenuBar"
    /// Show Claude as remaining (100 − used) instead of used. Default false (Claude's own UI shows used).
    static let claudeShowsRemaining = "claudeShowsRemaining"
    /// Show Codex as remaining (100 − used) instead of used. Default true (Codex's own UI shows "% left").
    static let codexShowsRemaining = "codexShowsRemaining"
}

enum SettingsDefaults {
    static let refreshInterval: Double = 120
    static let autoRefreshTokens = true
    static let showClaudeInMenuBar = true
    static let showCodexInMenuBar = true
    static let claudeShowsRemaining = false
    static let codexShowsRemaining = true

    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.refreshInterval: refreshInterval,
            SettingsKey.autoRefreshTokens: autoRefreshTokens,
            SettingsKey.showClaudeInMenuBar: showClaudeInMenuBar,
            SettingsKey.showCodexInMenuBar: showCodexInMenuBar,
            SettingsKey.claudeShowsRemaining: claudeShowsRemaining,
            SettingsKey.codexShowsRemaining: codexShowsRemaining,
        ])
    }
}

extension ProviderID {
    /// UserDefaults key choosing "remaining" display for this provider.
    var showsRemainingKey: String {
        switch self {
        case .claude: return SettingsKey.claudeShowsRemaining
        case .codex: return SettingsKey.codexShowsRemaining
        }
    }

    var showsRemainingDefault: Bool {
        switch self {
        case .claude: return SettingsDefaults.claudeShowsRemaining
        case .codex: return SettingsDefaults.codexShowsRemaining
        }
    }

    /// True when this provider's values are shown as remaining (100 − used) rather than used.
    func showsRemaining(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsRemainingKey) == nil ? showsRemainingDefault : defaults.bool(forKey: showsRemainingKey)
    }

    /// Converts a used percentage (0...100) into the value shown for this provider.
    func displayedPercent(used: Double, defaults: UserDefaults = .standard) -> Double {
        let used = min(max(used, 0), 100)
        return showsRemaining(defaults: defaults) ? 100 - used : used
    }

    /// Suffix after a displayed percentage: " 남음" in remaining mode, "" otherwise.
    func percentSuffix(defaults: UserDefaults = .standard) -> String {
        showsRemaining(defaults: defaults) ? " 남음" : ""
    }
}
