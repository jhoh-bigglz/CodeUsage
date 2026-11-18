import Charts
import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: UsageStore
    @State private var range: HistoryRange = .day

    enum HistoryRange: String, CaseIterable, Identifiable {
        case day
        case week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: return "24시간"
            case .week: return "7일"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 560)
        .environment(\.locale, Locale(identifier: "ko_KR"))
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("사용량 기록")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Picker("기간", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(ProviderID.allCases) { provider in
                        ProviderHistoryChart(
                            provider: provider,
                            snapshot: store.snapshots[provider],
                            samples: store.history(for: provider),
                            range: range,
                            now: now
                        )
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(20)
    }
}

private enum HistorySeries: String, CaseIterable {
    case session = "세션"
    case weekly = "주간"
}

private struct HistoryPoint: Identifiable {
    var date: Date
    var value: Double
    var series: HistorySeries
    var id: String { "\(series.rawValue)-\(date.timeIntervalSince1970)" }
}

private struct ProviderHistoryChart: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let samples: [UsageSample]
    let range: HistoryView.HistoryRange
    let now: Date

    private var start: Date { now.addingTimeInterval(-range.seconds) }

    private var points: [HistoryPoint] {
        var result: [HistoryPoint] = []
        for sample in samples where sample.date >= start && sample.date <= now {
            if let value = sample.sessionPercent {
                result.append(HistoryPoint(date: sample.date,
                                           value: Self.effective(value, resetsAt: sample.sessionResetsAt, at: sample.date),
                                           series: .session))
            }
            if let value = sample.weeklyPercent {
                result.append(HistoryPoint(date: sample.date,
                                           value: Self.effective(value, resetsAt: sample.weeklyResetsAt, at: sample.date),
                                           series: .weekly))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// A window whose reset time had already passed when the sample was taken counted as 0 %.
    private static func effective(_ value: Double, resetsAt: Date?, at date: Date) -> Double {
        if let resetsAt, resetsAt <= date { return 0 }
        return min(max(value, 0), 100)
    }

    private var tint: Color { UsageTheme.color(for: provider) }

    var body: some View {
        let points = self.points
        let present = HistorySeries.allCases.filter { series in points.contains { $0.series == series } }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: UsageTheme.glyph(for: provider))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if let plan = snapshot?.account.plan, !plan.isEmpty {
                    PlanBadge(text: plan)
                }
                Spacer()
                Text(currentSummary)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Chart(points) { point in
                LineMark(
                    x: .value("시간", point.date),
                    y: .value("사용률", point.value),
                    series: .value("종류", point.series.rawValue)
                )
                .foregroundStyle(by: .value("종류", point.series.rawValue))
                .lineStyle(point.series == .weekly
                           ? StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3])
                           : StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.linear)
            }
            .chartForegroundStyleScale(domain: present.map(\.rawValue),
                                       range: present.map { $0 == .session ? tint : tint.opacity(0.55) })
            .chartYScale(domain: 0...100)
            .chartXScale(domain: start...now)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Int.self) { Text("\(v)%") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .day ? 6 : 7)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.axisLabel(date, range: range))
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 170)
            .overlay {
                if points.isEmpty {
                    Text("이 기간의 기록이 없습니다")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d (E)"
        return formatter
    }()

    private static func axisLabel(_ date: Date, range: HistoryView.HistoryRange) -> String {
        (range == .day ? hourFormatter : dayFormatter).string(from: date)
    }

    private var currentSummary: String {
        guard let snapshot else { return "" }
        var parts: [String] = []
        if let session = snapshot.session {
            let display = WindowDisplay.make(session, kind: .session, now: now)
            parts.append("세션 \(Fmt.percent(snapshot.provider.displayedPercent(used: display.percent)))\(snapshot.provider.percentSuffix())")
        }
        if let weekly = snapshot.weekly {
            let display = WindowDisplay.make(weekly, kind: .weekly, now: now)
            parts.append("주간 \(Fmt.percent(snapshot.provider.displayedPercent(used: display.percent)))\(snapshot.provider.percentSuffix())")
        }
        return parts.joined(separator: " · ")
    }
}
