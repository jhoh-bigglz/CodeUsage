import AppKit
import SwiftUI

/// Content of the status item popover: one section per provider plus header and footer.
struct PopoverView: View {
    @ObservedObject var store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PopoverContent(store: store, now: context.date)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PopoverContent: View {
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(store: store)
                .padding(.bottom, 16)

            ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 {
                    Divider().padding(.vertical, 16)
                }
                ProviderSectionView(store: store, provider: provider, now: now)
            }

            Divider().padding(.top, 16).padding(.bottom, 10)

            PopoverFooter(store: store, now: now)

            Divider().padding(.vertical, 10)

            PopoverBottomBar()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

// MARK: - Header

private struct PopoverHeader: View {
    @ObservedObject var store: UsageStore

    private var isLoading: Bool { !store.loading.isEmpty }

    var body: some View {
        HStack(spacing: 2) {
            Text("Code Usage")
                .font(.system(size: 16, weight: .bold))
            Spacer(minLength: 8)
            IconButton(systemName: "chart.line.uptrend.xyaxis", help: "사용량 기록") {
                WindowManager.shared.showHistory(store: store)
            }
            IconButton(systemName: "gearshape", help: "설정") {
                WindowManager.shared.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            IconButton(systemName: "arrow.clockwise", help: "새로고침", spinning: isLoading) {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isLoading)
        }
    }
}

/// Borderless outline icon button with a subtle hover background.
private struct IconButton: View {
    let systemName: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.2),
                           value: spinning)
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering && isEnabled ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Provider section

private struct ProviderSectionView: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderID
    let now: Date

    var body: some View {
        let snapshot = store.snapshots[provider]
        let error = store.errors[provider]

        VStack(alignment: .leading, spacing: 0) {
            ProviderHeader(provider: provider, account: snapshot?.account, isLoading: store.loading.contains(provider))
                .padding(.bottom, 12)

            if let error {
                ErrorNotice(error: error, lastSuccess: isNotLoggedIn(error) ? nil : snapshot?.fetchedAt, now: now)
                    .padding(.bottom, snapshot == nil || isNotLoggedIn(error) ? 0 : 12)
            }

            if let snapshot, !(error.map(isNotLoggedIn) ?? false) {
                SnapshotRows(store: store, snapshot: snapshot, now: now)
                    .opacity(error == nil ? 1 : 0.5)
            } else if snapshot == nil && error == nil {
                PlaceholderRow(isLoading: store.loading.contains(provider) || store.lastRefresh == nil)
            }
        }
    }

    private func isNotLoggedIn(_ error: ProviderError) -> Bool {
        if case .notLoggedIn = error { return true }
        return false
    }
}

private struct ProviderHeader: View {
    let provider: ProviderID
    let account: AccountInfo?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: UsageTheme.glyph(for: provider))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UsageTheme.color(for: provider))
                .frame(width: 16)
            Text(provider.displayName)
                .font(.system(size: 14, weight: .semibold))
            if let name = account?.name ?? account?.email, !name.isEmpty {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let plan = account?.plan, !plan.isEmpty {
                PlanBadge(text: plan)
            }
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            }
        }
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

private struct SnapshotRows: View {
    @ObservedObject var store: UsageStore
    let snapshot: ProviderSnapshot
    let now: Date
    // Observed so the rows re-render when the display mode changes in Settings.
    @AppStorage(SettingsKey.claudeShowsRemaining) private var claudeShowsRemaining = SettingsDefaults.claudeShowsRemaining
    @AppStorage(SettingsKey.codexShowsRemaining) private var codexShowsRemaining = SettingsDefaults.codexShowsRemaining

    var body: some View {
        let provider = snapshot.provider
        let remaining = provider == .claude ? claudeShowsRemaining : codexShowsRemaining
        VStack(alignment: .leading, spacing: 18) {
            if let session = snapshot.session {
                UsageRowView(kind: .session,
                             window: session,
                             provider: provider,
                             burnRate: store.burnRatePerHour(for: provider, session: true),
                             exhaustion: store.projectedExhaustion(for: provider, session: true),
                             showsRemaining: remaining,
                             now: now)
            }
            if let weekly = snapshot.weekly {
                UsageRowView(kind: .weekly,
                             window: weekly,
                             provider: provider,
                             burnRate: store.burnRatePerHour(for: provider, session: false),
                             exhaustion: store.projectedExhaustion(for: provider, session: false),
                             showsRemaining: remaining,
                             now: now)
            }
            if !snapshot.extraWindows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.extraWindows) { named in
                        ExtraWindowRowView(named: named, provider: provider, showsRemaining: remaining, now: now)
                    }
                }
            }
            if snapshot.session == nil && snapshot.weekly == nil && snapshot.extraWindows.isEmpty {
                Text("표시할 사용량 한도가 없습니다")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaceholderRow: View {
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("불러오는 중…")
            } else {
                Text("아직 데이터가 없습니다")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

private struct ErrorNotice: View {
    let error: ProviderError
    let lastSuccess: Date?
    let now: Date

    private var isLogin: Bool {
        switch error {
        case .notLoggedIn, .tokenExpired, .unauthorized: return true
        default: return false
        }
    }

    private var tint: Color { isLogin ? UsageTheme.critical : UsageTheme.warning }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isLogin ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "알 수 없는 오류")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let lastSuccess {
                    Text("마지막 성공: \(Fmt.relative(lastSuccess, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.1))
        )
    }
}

// MARK: - Footer

private struct PopoverFooter: View {
    @ObservedObject var store: UsageStore
    let now: Date

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 12))
            Text(store.lastRefresh.map { Fmt.relative($0, now: now) } ?? "–")
                .font(.system(size: 12))
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: copied ? .semibold : .regular))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("사용량 요약 복사")
            .accessibilityLabel("사용량 요약 복사")
        }
        .foregroundStyle(.secondary)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.summaryText(), forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

private struct PopoverBottomBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(action: showDashboardMenu) {
                HStack(spacing: 3) {
                    Text("대시보드 열기")
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Claude / Codex 사용량 웹 페이지 열기")
            Spacer(minLength: 8)
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("종료")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .help("Code Usage 종료")
        }
    }

    /// Native menu with one item per provider dashboard, shown at the mouse location.
    private func showDashboardMenu() {
        let menu = NSMenu()
        for provider in ProviderID.allCases {
            let item = NSMenuItem(title: "\(provider.displayName) 사용량 페이지",
                                  action: #selector(DashboardMenuTarget.open(_:)),
                                  keyEquivalent: "")
            item.target = DashboardMenuTarget.shared
            item.representedObject = provider.dashboardURL
            item.image = NSImage(systemSymbolName: UsageTheme.glyph(for: provider), accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Target for the dashboard menu items (NSMenuItem needs an Objective-C target).
@MainActor
private final class DashboardMenuTarget: NSObject {
    static let shared = DashboardMenuTarget()

    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
