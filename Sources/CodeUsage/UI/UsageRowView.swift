import SwiftUI

// MARK: - Theme

/// Colors and glyphs shared by the popover, the menu bar label and the history window.
enum UsageTheme {
    /// Claude terracotta, #D97757.
    static let claude = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    /// Codex blue, #5B8DEF.
    static let codex = Color(red: 0x5B / 255.0, green: 0x8D / 255.0, blue: 0xEF / 255.0)
    /// Fill used once a window is at or above `criticalThreshold`, #E5484D.
    static let critical = Color(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0)
    /// Warning text (projected exhaustion, transient errors).
    static let warning = Color.orange

    static let criticalThreshold: Double = 90

    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// SF Symbol used as the provider's small glyph.
    static func glyph(for provider: ProviderID) -> String {
        switch provider {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    static func barColor(percent: Double, provider: ProviderID) -> Color {
        percent >= criticalThreshold ? critical : color(for: provider)
    }
}

// MARK: - Display state for a window

/// What a usage row shows for a window at a given moment.
struct WindowDisplay: Equatable {
    var percent: Double
    var caption: String
    var isLive: Bool

    enum Kind { case session, weekly, extra }

    static func make(_ window: UsageWindow, kind: Kind, now: Date) -> WindowDisplay {
        let used = min(max(window.usedPercent, 0), 100)
        if kind == .session, window.isLive(now: now), !window.isActive(now: now) {
            // Idle window reported with a full-length, ever-moving reset: no session has started.
            return WindowDisplay(percent: 0, caption: "활성 세션 없음", isLive: false)
        }
        if let resetsAt = window.resetsAt, resetsAt > now {
            return WindowDisplay(percent: used, caption: Fmt.resetText(resetsAt: resetsAt, now: now), isLive: true)
        }
        switch kind {
        case .session:
            // The plan has a session window, but none is running right now.
            return WindowDisplay(percent: 0, caption: "활성 세션 없음", isLive: false)
        case .weekly, .extra:
            if window.resetsAt == nil {
                // Server reported a value without a running window; show the value as is.
                return WindowDisplay(percent: used, caption: "초기화 시간 정보 없음", isLive: false)
            }
            // The window has already reset since the last fetch.
            return WindowDisplay(percent: 0, caption: "초기화됨 · 갱신 대기 중", isLive: false)
        }
    }
}

// MARK: - Progress bar

/// Rounded capsule progress bar: tinted track with a solid fill.
struct UsageBar: View {
    var percent: Double
    var tint: Color
    var height: CGFloat = 8
    var trackOpacity: Double = 0.18

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(trackOpacity))
                if fraction > 0 {
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: max(height, geo.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: percent)
        .accessibilityHidden(true)
    }
}

// MARK: - Main usage row ("현재 세션" / "주간 한도")

struct UsageRowView: View {
    enum Kind {
        case session
        case weekly

        var defaultTitle: String {
            switch self {
            case .session: return "현재 세션"
            case .weekly: return "주간 한도"
            }
        }
    }

    let kind: Kind
    let window: UsageWindow
    let provider: ProviderID
    var title: String?
    /// %/hour, shown right-aligned next to the title while the window is live.
    var burnRate: Double?
    /// When usage reaches 100 % at the current rate (only if before reset).
    var exhaustion: Date?
    /// Show remaining (100 − used) instead of used.
    var showsRemaining: Bool = false
    var now: Date = Date()

    private var display: WindowDisplay {
        WindowDisplay.make(window, kind: kind == .session ? .session : .weekly, now: now)
    }

    var body: some View {
        let display = self.display
        let critical = display.percent >= UsageTheme.criticalThreshold
        let shown = showsRemaining ? 100 - display.percent : display.percent

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? kind.defaultTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if display.isLive, let burnRate, burnRate >= 0.05 {
                    Text((showsRemaining ? "−" : "") + Fmt.rate(burnRate))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("최근 사용 속도")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.percent(shown))
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(critical ? UsageTheme.critical : Color.primary)
                    .contentTransition(.numericText())
                if showsRemaining {
                    Text("남음")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            UsageBar(percent: shown, tint: UsageTheme.barColor(percent: display.percent, provider: provider))
                .padding(.top, 6)

            Text(display.caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 7)

            if display.isLive, let exhaustion {
                ExhaustionCaption(date: exhaustion, now: now)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small orange line: "현재 속도면 16:05에 한도 도달".
struct ExhaustionCaption: View {
    let date: Date
    let now: Date

    var body: some View {
        Label {
            Text(Fmt.exhaustionText(date, now: now))
        } icon: {
            Image(systemName: "flame.fill")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(UsageTheme.warning)
        .labelStyle(CompactLabelStyle())
    }
}

struct CompactLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Compact row for scoped/extra windows

struct ExtraWindowRowView: View {
    let named: NamedWindow
    let provider: ProviderID
    var showsRemaining: Bool = false
    var now: Date = Date()

    var body: some View {
        let display = WindowDisplay.make(named.window, kind: .extra, now: now)
        let critical = display.percent >= UsageTheme.criticalThreshold
        let shown = showsRemaining ? 100 - display.percent : display.percent

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(named.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                UsageBar(percent: shown,
                         tint: UsageTheme.barColor(percent: display.percent, provider: provider),
                         height: 5)
                    .frame(width: 92)
                Text(Fmt.percent(shown) + (showsRemaining ? " 남음" : ""))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(critical ? UsageTheme.critical : Color.primary)
                    .frame(minWidth: showsRemaining ? 58 : 34, alignment: .trailing)
            }
            Text(display.caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
