import AppKit
import Combine
import Foundation

/// Central state: latest snapshot and error per provider, polling, history and burn-rate estimates.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// Latest successful snapshot per provider (kept when a later fetch fails).
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    /// Latest error per provider; cleared on success.
    @Published private(set) var errors: [ProviderID: ProviderError] = [:]
    /// Providers whose fetch is in flight.
    @Published private(set) var loading: Set<ProviderID> = []
    /// When the last refresh cycle finished (successful or not).
    @Published private(set) var lastRefresh: Date?

    private let providers: [UsageProvider]
    private let historyStore: HistoryStore
    private let isPreview: Bool
    private var isRefreshing = false
    /// A wake-triggered refresh arrived while another was running; run once more when it finishes.
    private var refreshAfterCurrent = false
    /// Consecutive HTTP 429 responses per provider; drives the rate-limit backoff.
    private var rateLimitStreak: [ProviderID: Int] = [:]
    /// Consecutive network errors per provider; drives a short retry backoff.
    private var networkStreak: [ProviderID: Int] = [:]
    /// When each provider's last fetch finished and how it ended; each provider is scheduled on its own from this.
    private var lastFetch: [ProviderID: FetchRecord] = [:]

    private struct FetchRecord {
        var finishedAt: Date
        var outcome: Outcome
    }

    private enum Outcome {
        case answered
        case networkError(streak: Int)
        /// HTTP 429; `pause` = how long the server asked us to stay away.
        case rateLimited(pause: TimeInterval)
    }
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// Minimum polling interval, whatever the settings say.
    private static let minimumInterval: TimeInterval = 30
    /// Burn-rate sample matching: samples belong to the current window when their reset time is this close.
    private static let resetTolerance: TimeInterval = 120

    convenience init(providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()]) {
        self.init(providers: providers, history: HistoryStore(), preview: false)
    }

    /// Store pre-filled with snapshots; never fetches or polls (SwiftUI previews, `--render-preview`).
    convenience init(
        previewSnapshots: [ProviderID: ProviderSnapshot],
        history: [ProviderID: [UsageSample]] = [:],
        errors: [ProviderID: ProviderError] = [:],
        lastRefresh: Date? = Date()
    ) {
        self.init(providers: [], history: HistoryStore(inMemorySamples: history), preview: true)
        self.snapshots = previewSnapshots
        self.errors = errors
        self.lastRefresh = lastRefresh
    }

    private init(providers: [UsageProvider], history: HistoryStore, preview: Bool) {
        self.providers = providers
        self.historyStore = history
        self.isPreview = preview
    }

    // MARK: - Lifecycle

    /// Initial refresh, polling loop (interval re-read from UserDefaults each cycle, min 30 s) and refresh on wake.
    func start() {
        guard !started, !isPreview else { return }
        started = true

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let step = self?.nextPollStep() else { return }
                switch step {
                case .wait(let seconds):
                    // Sleep in short chunks so a changed interval takes effect quickly.
                    try? await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0.5), 30) * 1_000_000_000))
                case .fetch(let ids):
                    await self?.refresh(only: ids)
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Give the network a moment to come back after wake.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                // A refresh started before the network was back may be hanging: follow it with a fresh one.
                if self.isRefreshing { self.refreshAfterCurrent = true; return }
                await self.refresh()
            }
        }
    }

    private enum PollStep {
        case wait(TimeInterval)
        /// Fetch these providers: they are due on their own schedule.
        case fetch(Set<ProviderID>)
    }

    /// What the poll loop does next. Each provider runs on its own schedule (see `nextDue`),
    /// so a rate-limited or failing provider never changes how often the other one is fetched.
    private func nextPollStep(now: Date = Date()) -> PollStep {
        if isRefreshing { return .wait(2) }
        let interval = Self.pollInterval()
        var due = Set<ProviderID>()
        var next = Date.distantFuture
        for provider in providers {
            let date = nextDue(provider.id, interval: interval, now: now)
            if date <= now { due.insert(provider.id) } else { next = min(next, date) }
        }
        if !due.isEmpty { return .fetch(due) }
        return .wait(next.timeIntervalSince(now))
    }

    /// When a provider should be fetched next, measured from the end of its last fetch:
    /// - normal: after the polling interval;
    /// - network error: sooner (15 s, 30 s, 60 s, … capped at the interval);
    /// - HTTP 429: after the longer of the interval and the server-requested pause.
    /// Never fetched, or the wall clock moved backwards past the last fetch: due now.
    private func nextDue(_ id: ProviderID, interval: TimeInterval, now: Date) -> Date {
        guard let record = lastFetch[id], record.finishedAt <= now else { return now }
        let delay: TimeInterval
        switch record.outcome {
        case .answered:
            delay = interval
        case .networkError(let streak):
            delay = min(interval, 15 * pow(2, Double(min(max(streak, 1) - 1, 10))))
        case .rateLimited(let pause):
            delay = max(interval, pause)
        }
        return record.finishedAt.addingTimeInterval(delay)
    }

    /// When the app will ask a rate-limited provider again; nil when it is not held back.
    func nextRetry(for provider: ProviderID, now: Date = Date()) -> Date? {
        guard isRateLimited(provider, now: now) else { return nil }
        return nextDue(provider, interval: Self.pollInterval(), now: now)
    }

    private static let maximumRateLimitDelay: TimeInterval = 3_600

    /// How long to pause a provider after HTTP 429: the server's Retry-After (30 s…1 h),
    /// otherwise 5 min, 10 min, 20 min, then 30 min for each consecutive 429.
    static func rateLimitDelay(retryAfter: TimeInterval?, streak: Int) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite {
            return min(max(retryAfter, 30), maximumRateLimitDelay)
        }
        let step = max(streak, 1) - 1
        return min(300 * pow(2, Double(min(step, 10))), 1_800)
    }

    /// True while a provider whose last answer was HTTP 429 is held back until its next scheduled fetch
    /// (the longer of the polling interval and the server-requested pause). Every refresh path — the poll loop,
    /// the refresh button, opening the popover, waking — skips it until then.
    /// Measured from the end of the 429 fetch, so a wall clock moved backwards ends the hold instead of stretching it.
    func isRateLimited(_ provider: ProviderID, now: Date = Date()) -> Bool {
        guard let record = lastFetch[provider], case .rateLimited = record.outcome, record.finishedAt <= now else {
            return false
        }
        return now < nextDue(provider, interval: Self.pollInterval(), now: now)
    }

    static func pollInterval() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        let interval = stored > 0 ? stored : SettingsDefaults.refreshInterval
        return max(minimumInterval, interval)
    }

    // MARK: - Refresh

    /// Fetches the providers concurrently, skipping providers paused after HTTP 429.
    /// `only` limits the fetch to those providers (the poll loop passes the ones that are due).
    /// Ignored while a refresh is already running.
    func refresh(only: Set<ProviderID>? = nil) async {
        guard !isRefreshing, !isPreview, !providers.isEmpty else { return }
        let start = Date()
        let providers = self.providers.filter { provider in
            (only?.contains(provider.id) ?? true) && !isRateLimited(provider.id, now: start)
        }
        guard !providers.isEmpty else { return }
        isRefreshing = true
        loading = Set(providers.map(\.id))

        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, ProviderError>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.id, .success(try await provider.fetch()))
                    } catch {
                        return (provider.id, .failure(UsageStore.normalize(error)))
                    }
                }
            }
            for await (id, result) in group {
                self.apply(result, for: id)
            }
        }

        loading = []
        lastRefresh = Date()
        isRefreshing = false

        if refreshAfterCurrent {
            refreshAfterCurrent = false
            Task { await self.refresh() }
        }
    }

    /// Refreshes in the background unless the last refresh is younger than `maxAge` seconds.
    func refreshIfStale(maxAge: TimeInterval) {
        guard !isPreview, !isRefreshing else { return }
        // A negative age (clock moved backwards) counts as stale.
        if let lastRefresh {
            let age = Date().timeIntervalSince(lastRefresh)
            if age >= 0, age < maxAge { return }
        }
        Task { await self.refresh() }
    }

    private func apply(_ result: Result<ProviderSnapshot, ProviderError>, for id: ProviderID) {
        let finished = Date()
        switch result {
        case .success(let snapshot):
            snapshots[id] = snapshot
            errors[id] = nil
            rateLimitStreak[id] = nil
            networkStreak[id] = nil
            lastFetch[id] = FetchRecord(finishedAt: finished, outcome: .answered)
            historyStore.record(snapshot)
        case .failure(let error):
            errors[id] = error
            switch error {
            case .rateLimited(let retryAfter):
                let streak = (rateLimitStreak[id] ?? 0) + 1
                rateLimitStreak[id] = streak
                networkStreak[id] = nil
                let pause = Self.rateLimitDelay(retryAfter: retryAfter, streak: streak)
                lastFetch[id] = FetchRecord(finishedAt: finished, outcome: .rateLimited(pause: pause))
            case .network:
                // A timeout says nothing about the rate limit: keep the 429 streak so its backoff keeps growing.
                let streak = (networkStreak[id] ?? 0) + 1
                networkStreak[id] = streak
                lastFetch[id] = FetchRecord(finishedAt: finished, outcome: .networkError(streak: streak))
            default:
                // The server answered with something other than 429: the pause is over.
                rateLimitStreak[id] = nil
                networkStreak[id] = nil
                lastFetch[id] = FetchRecord(finishedAt: finished, outcome: .answered)
            }
            // Logged out: the old numbers belong to a login that no longer exists.
            if case .notLoggedIn = error { snapshots[id] = nil }
        }
        loading.remove(id)
    }

    nonisolated private static func normalize(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return .network("요청이 취소되었습니다") }
        if let urlError = error as? URLError { return .network(urlError.localizedDescription) }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .network(error.localizedDescription)
    }

    // MARK: - History & estimates

    func history(for provider: ProviderID) -> [UsageSample] {
        historyStore.samples(for: provider)
    }

    /// Waits for pending history writes (call on quit).
    func flushHistory() {
        historyStore.flush()
    }

    /// Whether the menu bar should mark this provider's value as stale: the last fetch failed and the shown
    /// snapshot is old. Persistent errors (expired token, rejected auth, HTTP) count at once; network errors
    /// only after a while, so a brief outage does not flicker the label.
    func isStale(_ provider: ProviderID, now: Date = Date()) -> Bool {
        guard let error = errors[provider], let snapshot = snapshots[provider] else { return false }
        switch error {
        case .network, .rateLimited:
            let threshold = max(3 * Self.pollInterval(), 600)
            return now.timeIntervalSince(snapshot.fetchedAt) > threshold
        default:
            return true
        }
    }

    /// Usage growth in %/hour for the session (or weekly) window; nil when unknown.
    ///
    /// Uses samples from the current window (same reset time ±120 s) in the last 60 min (weekly: 24 h)
    /// when they span at least 10 minutes; otherwise the average since the window started (≥ 5 min elapsed).
    func burnRatePerHour(for provider: ProviderID, session: Bool) -> Double? {
        burnRatePerHour(for: provider, session: session, now: Date())
    }

    private func burnRatePerHour(for provider: ProviderID, session: Bool, now: Date) -> Double? {
        guard let window = window(for: provider, session: session),
              let resetsAt = window.resetsAt, resetsAt > now
        else { return nil }

        let lookback: TimeInterval = session ? 3_600 : 86_400
        let cutoff = now.addingTimeInterval(-lookback)
        let points: [(date: Date, percent: Double)] = history(for: provider).compactMap { sample in
            let percent = session ? sample.sessionPercent : sample.weeklyPercent
            let reset = session ? sample.sessionResetsAt : sample.weeklyResetsAt
            guard let percent, let reset,
                  abs(reset.timeIntervalSince(resetsAt)) <= Self.resetTolerance,
                  sample.date >= cutoff, sample.date <= now.addingTimeInterval(60)
            else { return nil }
            return (sample.date, percent)
        }

        if let first = points.first, let last = points.last {
            let span = last.date.timeIntervalSince(first.date)
            if span >= 600 {
                return max(0, (last.percent - first.percent) / (span / 3_600))
            }
        }

        guard let start = window.windowStart else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 300 else { return nil }
        return max(0, window.usedPercent) / (elapsed / 3_600)
    }

    /// When usage reaches 100 % at the current burn rate — only if that happens before the window resets.
    func projectedExhaustion(for provider: ProviderID, session: Bool) -> Date? {
        let now = Date()
        guard let window = window(for: provider, session: session),
              let resetsAt = window.resetsAt, resetsAt > now,
              window.usedPercent < 100,
              let rate = burnRatePerHour(for: provider, session: session, now: now),
              rate > 0.01
        else { return nil }
        let date = now.addingTimeInterval((100 - window.usedPercent) / rate * 3_600)
        return date < resetsAt ? date : nil
    }

    private func window(for provider: ProviderID, session: Bool) -> UsageWindow? {
        guard let snapshot = snapshots[provider] else { return nil }
        return session ? snapshot.session : snapshot.weekly
    }

    // MARK: - Summary

    /// Plain-text summary for the copy button.
    func summaryText() -> String {
        let now = Date()
        var lines: [String] = []
        let stamp = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
        lines.append("Code Usage — \(now.formatted(stamp))")

        for id in ProviderID.allCases {
            let snapshot = snapshots[id]
            let error = errors[id]
            guard snapshot != nil || error != nil else { continue }
            lines.append("")

            var header = id.displayName
            if let snapshot {
                let details = [snapshot.account.plan, snapshot.account.name].compactMap { $0 }.filter { !$0.isEmpty }
                if !details.isEmpty { header += " (\(details.joined(separator: " · ")))" }
            }
            lines.append(header)

            if let snapshot {
                if let session = snapshot.session {
                    lines.append("  현재 세션: " + windowSummary(session, provider: id, session: true, now: now))
                }
                if let weekly = snapshot.weekly {
                    lines.append("  주간 한도: " + windowSummary(weekly, provider: id, session: false, now: now))
                }
                for extra in snapshot.extraWindows {
                    var text = "  \(extra.label): \(Fmt.percent(id.displayedPercent(used: extra.window.usedPercent)))\(id.percentSuffix())"
                    if let reset = extra.window.resetsAt, reset > now {
                        text += " · " + Fmt.resetText(resetsAt: reset, now: now)
                    }
                    lines.append(text)
                }
            }
            if let error {
                lines.append("  오류: \(error.errorDescription ?? String(describing: error))")
            }
        }

        if lines.count == 1 { lines.append("데이터 없음") }
        return lines.joined(separator: "\n")
    }

    private func windowSummary(_ window: UsageWindow, provider: ProviderID, session: Bool, now: Date) -> String {
        guard let reset = window.resetsAt, reset > now else {
            return session ? "활성 세션 없음" : Fmt.percent(provider.displayedPercent(used: window.usedPercent)) + provider.percentSuffix()
        }
        var parts = [Fmt.percent(provider.displayedPercent(used: window.usedPercent)) + provider.percentSuffix(), Fmt.resetText(resetsAt: reset, now: now)]
        if let rate = burnRatePerHour(for: provider, session: session, now: now) {
            parts.append(Fmt.rate(rate))
        }
        if let exhaustion = projectedExhaustion(for: provider, session: session) {
            parts.append(Fmt.exhaustionText(exhaustion, now: now))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Preview

    /// Store with built-in sample data — no network, no polling.
    /// Claude: Team, session 9 % resetting in 2 h 7 min, weekly 2 % resetting in 7 h 27 min.
    /// Codex: Pro Lite, no session window, weekly 77 % resetting in 4 days.
    static func preview() -> UsageStore {
        let now = Date()
        // A few seconds of slack so the reset captions read exactly "2 hr 7 min" etc.
        let slack: TimeInterval = 20

        let claudeSession = UsageWindow(
            usedPercent: 9,
            resetsAt: now.addingTimeInterval(2 * 3_600 + 7 * 60 + slack),
            windowSeconds: 18_000
        )
        let claudeWeekly = UsageWindow(
            usedPercent: 2,
            resetsAt: now.addingTimeInterval(7 * 3_600 + 27 * 60 + slack),
            windowSeconds: 604_800
        )
        let codexWeekly = UsageWindow(
            usedPercent: 77,
            resetsAt: now.addingTimeInterval(4 * 86_400 + slack),
            windowSeconds: 604_800
        )

        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(
                provider: .claude,
                account: AccountInfo(name: "Alex", email: nil, plan: "Team"),
                session: claudeSession,
                weekly: claudeWeekly,
                extraWindows: [],
                fetchedAt: now
            ),
            .codex: ProviderSnapshot(
                provider: .codex,
                account: AccountInfo(name: "Alex", email: nil, plan: "Pro Lite"),
                session: nil,
                weekly: codexWeekly,
                extraWindows: [],
                fetchedAt: now
            ),
        ]

        let history: [ProviderID: [UsageSample]] = [
            .claude: previewClaudeHistory(now: now, session: claudeSession, weekly: claudeWeekly),
            .codex: previewCodexHistory(now: now, weekly: codexWeekly),
        ]
        return UsageStore(previewSnapshots: snapshots, history: history, lastRefresh: now)
    }

    /// Seven days of plausible Claude samples. The last hour of the current session grows at 8 %/hr.
    private static func previewClaudeHistory(now: Date, session: UsageWindow, weekly: UsageWindow) -> [UsageSample] {
        guard let sessionReset = session.resetsAt, let sessionStart = session.windowStart,
              let weeklyReset = weekly.resetsAt, let weeklyStart = weekly.windowStart
        else { return [] }

        var samples: [UsageSample] = []
        for step in stride(from: 7 * 86_400.0, through: 0, by: -600) {
            let date = now.addingTimeInterval(-step)
            let ago = step

            // Session: current window, else earlier 5 h windows separated by 1 h idle gaps.
            var sessionPercent: Double?
            var sessionResetsAt: Date?
            if date >= sessionStart {
                sessionResetsAt = sessionReset
                if ago <= 3_600 {
                    sessionPercent = 9 - 8 * ago / 3_600
                } else {
                    let span = now.addingTimeInterval(-3_600).timeIntervalSince(sessionStart)
                    sessionPercent = max(0, date.timeIntervalSince(sessionStart) / span)
                }
            } else {
                let sinceEarlier = sessionStart.timeIntervalSince(date)
                let index = Int(sinceEarlier / 21_600)
                let windowStart = sessionStart.addingTimeInterval(-Double(index + 1) * 21_600)
                let offset = date.timeIntervalSince(windowStart)
                if offset < 18_000 {
                    let peak = 25 + 45 * (0.5 + 0.5 * sin(Double(index) * 1.7))
                    sessionPercent = (peak * offset / 18_000).rounded()
                    sessionResetsAt = windowStart.addingTimeInterval(18_000)
                }
            }

            // Weekly: current window grows to 2 %, the previous one ended near 64 %.
            let weeklyPercent: Double
            let weeklyResetsAt: Date
            if date >= weeklyStart {
                weeklyPercent = (2 * date.timeIntervalSince(weeklyStart) / now.timeIntervalSince(weeklyStart) * 10).rounded() / 10
                weeklyResetsAt = weeklyReset
            } else {
                let previousStart = weeklyStart.addingTimeInterval(-604_800)
                weeklyPercent = (64 * date.timeIntervalSince(previousStart) / 604_800).rounded()
                weeklyResetsAt = weeklyStart
            }

            samples.append(UsageSample(
                date: date,
                sessionPercent: sessionPercent,
                sessionResetsAt: sessionResetsAt,
                weeklyPercent: weeklyPercent,
                weeklyResetsAt: weeklyResetsAt
            ))
        }
        return samples
    }

    /// Seven days of Codex samples: weekly only, current window grew from 0 to 77 %.
    private static func previewCodexHistory(now: Date, weekly: UsageWindow) -> [UsageSample] {
        guard let reset = weekly.resetsAt, let start = weekly.windowStart else { return [] }
        var samples: [UsageSample] = []
        for step in stride(from: 7 * 86_400.0, through: 0, by: -1_800) {
            let date = now.addingTimeInterval(-step)
            let percent: Double
            let resetsAt: Date
            if date >= start {
                percent = (77 * date.timeIntervalSince(start) / now.timeIntervalSince(start)).rounded()
                resetsAt = reset
            } else {
                let previousStart = start.addingTimeInterval(-604_800)
                percent = (91 * date.timeIntervalSince(previousStart) / 604_800).rounded()
                resetsAt = start
            }
            samples.append(UsageSample(
                date: date,
                sessionPercent: nil,
                sessionResetsAt: nil,
                weeklyPercent: percent,
                weeklyResetsAt: resetsAt
            ))
        }
        return samples
    }
}
