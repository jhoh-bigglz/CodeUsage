import SwiftUI

/// The status item's content: for each provider enabled in settings (Claude, then Codex) one value —
/// the current session while a session is live, otherwise the weekly limit (`ProviderSnapshot.menuBarWindow()`).
/// Compact layout: with two providers the values are stacked in two rows (≈ 40 pt wide);
/// a weekly value carries a tiny "w". Values follow each provider's used/remaining display setting.
///
/// Rendered to an image with `ImageRenderer`; needs no environment objects. With `forTemplate == true`
/// everything is drawn in black (alpha carries the shading) so the image can be used as a template.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    var forTemplate: Bool = true
    var now: Date = Date()
    /// Providers to show. nil = read the menu bar toggles from `UserDefaults.standard`.
    var providers: [ProviderID]?

    init(store: UsageStore, forTemplate: Bool = true, now: Date = Date(), providers: [ProviderID]? = nil) {
        self.store = store
        self.forTemplate = forTemplate
        self.now = now
        self.providers = providers
    }

    /// Providers enabled for the menu bar in settings, in display order.
    static func enabledProviders(defaults: UserDefaults = .standard) -> [ProviderID] {
        ProviderID.allCases.filter { provider in
            let key: String
            let fallback: Bool
            switch provider {
            case .claude:
                key = SettingsKey.showClaudeInMenuBar
                fallback = SettingsDefaults.showClaudeInMenuBar
            case .codex:
                key = SettingsKey.showCodexInMenuBar
                fallback = SettingsDefaults.showCodexInMenuBar
            }
            return defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
    }

    /// What one menu bar item shows.
    struct Item: Equatable {
        var provider: ProviderID
        /// Value as displayed (used, or remaining when `showsRemaining`). nil → no data ("–").
        var percent: Double?
        /// True when the value is the live session; false when it is the weekly limit.
        var isSession: Bool
        /// The last fetch failed and this value is old: drawn dimmed.
        var stale: Bool = false
        /// `percent` is remaining (100 − used) rather than used.
        var showsRemaining: Bool = false
    }

    static func item(for provider: ProviderID, snapshot: ProviderSnapshot?, stale: Bool = false, now: Date) -> Item {
        guard let snapshot, let window = snapshot.menuBarWindow(now: now) else {
            return Item(provider: provider, percent: nil, isSession: false, showsRemaining: provider.showsRemaining())
        }
        let live = window.isActive(now: now)
        let isSession = window.isSessionLength
        var percent = min(max(window.usedPercent, 0), 100)
        // A window whose reset time has passed has been reset since the last fetch.
        if let resetsAt = window.resetsAt, resetsAt <= now { percent = 0 }
        // A session window that is not running counts as unused.
        if isSession && !live { percent = 0 }
        return Item(provider: provider,
                    percent: provider.displayedPercent(used: percent),
                    isSession: isSession && live,
                    stale: stale,
                    showsRemaining: provider.showsRemaining())
    }

    static func items(store: UsageStore, providers: [ProviderID], now: Date) -> [Item] {
        providers.map { item(for: $0, snapshot: store.snapshots[$0], stale: store.isStale($0, now: now), now: now) }
    }

    /// Spoken/tooltip description, e.g. "Claude 현재 세션 9%, Codex 주간 한도 23% 남음".
    static func accessibilityText(store: UsageStore, providers: [ProviderID]? = nil, now: Date = Date()) -> String {
        let list = providers ?? enabledProviders()
        guard !list.isEmpty else { return "Code Usage" }
        return items(store: store, providers: list, now: now).map { item in
            guard let percent = item.percent else { return "\(item.provider.displayName) 데이터 없음" }
            let kind = item.isSession ? "현재 세션" : "주간 한도"
            return "\(item.provider.displayName) \(kind) \(Fmt.percent(percent))"
                + (item.showsRemaining ? " 남음" : "")
                + (item.stale ? " (갱신 실패)" : "")
        }.joined(separator: ", ")
    }

    private var ink: Color { forTemplate ? .black : .primary }

    var body: some View {
        let list = providers ?? Self.enabledProviders()
        let items = Self.items(store: store, providers: list, now: now)
        Group {
            if list.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13, weight: .medium))
            } else if items.count == 1 {
                MenuBarItemView(item: items[0], ink: ink, metrics: .single)
            } else {
                // Two rows stacked to keep the status item narrow.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.provider) { item in
                        MenuBarItemView(item: item, ink: ink, metrics: .stacked)
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 1)
        .frame(height: 22)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(store: store, providers: list, now: now))
    }
}

private struct MenuBarItemView: View {
    struct Metrics {
        var glyphSize: CGFloat
        var codexGlyphSize: CGFloat
        var glyphWidth: CGFloat
        var textSize: CGFloat
        var markerSize: CGFloat
        var rowHeight: CGFloat?

        static let stacked = Metrics(glyphSize: 7.5, codexGlyphSize: 6, glyphWidth: 9, textSize: 9.5, markerSize: 6.5, rowHeight: 10.5)
        static let single = Metrics(glyphSize: 10.5, codexGlyphSize: 8.5, glyphWidth: 13, textSize: 12, markerSize: 7.5, rowHeight: nil)
    }

    let item: MenuBarLabel.Item
    let ink: Color
    let metrics: Metrics

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Image(systemName: UsageTheme.glyph(for: item.provider))
                .font(.system(size: item.provider == .claude ? metrics.glyphSize : metrics.codexGlyphSize, weight: .bold))
                .frame(width: metrics.glyphWidth)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                percentText(item.percent.map(Fmt.percent) ?? "–")
                // Weekly marker; reserved even for session values so the width stays constant.
                Text("w")
                    .font(.system(size: metrics.markerSize, weight: .heavy))
                    .opacity(item.percent != nil && !item.isSession ? 1 : 0)
            }
            .opacity(item.stale ? 0.45 : 1)
        }
        .frame(height: metrics.rowHeight)
    }

    /// Fixed width (that of "100%") so the status item does not change size as the digit count changes.
    private func percentText(_ text: String) -> some View {
        Text("100%")
            .font(.system(size: metrics.textSize, weight: .semibold))
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .trailing) {
                Text(text)
                    .font(.system(size: metrics.textSize, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
            }
    }
}
