import Foundation

/// Persists usage samples per provider for the history charts and burn-rate estimates.
///
/// File: `~/Library/Application Support/CodeUsage/history.json`, keeping the last 8 days.
/// Only percentages and reset times are stored — never account data or tokens.
@MainActor
final class HistoryStore {
    /// How long samples are kept.
    nonisolated static let retention: TimeInterval = 8 * 86_400
    /// A new sample is skipped when it is closer than this to the previous one and nothing changed.
    nonisolated static let minimumSpacing: TimeInterval = 60

    nonisolated static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("CodeUsage", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    private(set) var samples: [ProviderID: [UsageSample]]
    /// nil → in-memory only (previews, tests).
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.jhoh.CodeUsage.history", qos: .utility)

    /// Loads persisted history from `fileURL` (pass nil for an in-memory store).
    init(fileURL: URL? = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        self.samples = [:]
        if let fileURL {
            self.samples = Self.prune(Self.load(from: fileURL), now: Date())
        }
    }

    /// In-memory store pre-filled with samples (used by `UsageStore.preview()`).
    init(inMemorySamples: [ProviderID: [UsageSample]]) {
        self.fileURL = nil
        self.samples = inMemorySamples.mapValues { $0.sorted { $0.date < $1.date } }
    }

    func samples(for provider: ProviderID) -> [UsageSample] {
        samples[provider] ?? []
    }

    /// Appends a sample built from a successful fetch. Returns false when it was skipped as a duplicate.
    @discardableResult
    func record(_ snapshot: ProviderSnapshot) -> Bool {
        let sample = UsageSample(
            date: snapshot.fetchedAt,
            sessionPercent: snapshot.session?.usedPercent,
            sessionResetsAt: snapshot.session?.resetsAt,
            weeklyPercent: snapshot.weekly?.usedPercent,
            weeklyResetsAt: snapshot.weekly?.resetsAt
        )
        var list = samples[snapshot.provider] ?? []
        if let last = list.last,
           abs(sample.date.timeIntervalSince(last.date)) < Self.minimumSpacing,
           Self.sameValues(sample, last) {
            return false
        }
        list.append(sample)
        if list.count > 1, list[list.count - 2].date > sample.date {
            list.sort { $0.date < $1.date }
        }
        samples[snapshot.provider] = list
        samples = Self.prune(samples, now: Date())
        scheduleSave()
        return true
    }

    /// Blocks until every pending write has reached disk (call before the app terminates).
    func flush() {
        ioQueue.sync {}
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard let fileURL else { return }
        let snapshot = samples
        ioQueue.async {
            Self.write(snapshot, to: fileURL)
        }
    }

    private struct FileFormat: Codable {
        var version: Int
        var samples: [String: [UsageSample]]
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private nonisolated static func write(_ samples: [ProviderID: [UsageSample]], to url: URL) {
        let file = FileFormat(
            version: 1,
            samples: Dictionary(uniqueKeysWithValues: samples.map { ($0.key.rawValue, $0.value) })
        )
        do {
            let data = try makeEncoder().encode(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("CodeUsage: 기록 저장 실패: \(error.localizedDescription)\n".utf8))
        }
    }

    private nonisolated static func load(from url: URL) -> [ProviderID: [UsageSample]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let file = try makeDecoder().decode(FileFormat.self, from: data)
            var result: [ProviderID: [UsageSample]] = [:]
            for (key, list) in file.samples {
                guard let id = ProviderID(rawValue: key) else { continue }
                result[id] = list.sorted { $0.date < $1.date }
            }
            return result
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return [:]
        }
    }

    private nonisolated static func prune(
        _ samples: [ProviderID: [UsageSample]],
        now: Date
    ) -> [ProviderID: [UsageSample]] {
        let cutoff = now.addingTimeInterval(-retention)
        return samples.mapValues { list in
            guard let first = list.first, first.date < cutoff else { return list }
            return list.filter { $0.date >= cutoff }
        }
    }

    private nonisolated static func sameValues(_ a: UsageSample, _ b: UsageSample) -> Bool {
        a.sessionPercent == b.sessionPercent
            && a.weeklyPercent == b.weeklyPercent
            && sameReset(a.sessionResetsAt, b.sessionResetsAt)
            && sameReset(a.weeklyResetsAt, b.weeklyResetsAt)
    }

    private nonisolated static func sameReset(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) <= 120
        default: return false
        }
    }
}
