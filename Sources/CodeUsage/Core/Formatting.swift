import Foundation

/// Display formatting shared by the menu bar label, the popover, the copy-summary text and debug output.
enum Fmt {
    private static let koreanLocale = Locale(identifier: "ko_KR")

    // MARK: Percent

    /// "9%", "77%", "100%"; "<1%" for values strictly between 0 and 1; "0%" for 0 or negative.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        if value <= 0 { return "0%" }
        if value < 1 { return "<1%" }
        // Never show 100% unless the window is really full.
        let rounded = value < 100 ? min(99, Int(value.rounded())) : Int(value.rounded())
        return "\(rounded)%"
    }

    // MARK: Reset text

    /// "Resets in 2 hr 7 min (수, 16:40)", "Resets in 3 days 4 hr (화, 22:00)", "Resets in <1 min".
    static func resetText(resetsAt: Date, now: Date = Date()) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining < 60 { return "Resets in <1 min" }
        return "Resets in \(durationText(remaining)) (\(weekdayTime(resetsAt)))"
    }

    /// "2 hr 7 min", "45 min", "3 days 4 hr", "1 day". Inputs below one minute yield "<1 min".
    static func durationText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 60 else { return "<1 min" }
        let totalMinutes = Int((interval / 60).rounded())
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            let dayText = days == 1 ? "1 day" : "\(days) days"
            return hours > 0 ? "\(dayText) \(hours) hr" : dayText
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
        }
        return "\(minutes) min"
    }

    /// "수, 16:40" — Korean abbreviated weekday plus 24-hour clock, in the current time zone.
    static func weekdayTime(_ date: Date) -> String {
        "\(weekday(date)), \(time(date))"
    }

    /// "수" (ko_KR, "E").
    static func weekday(_ date: Date) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated)",
            locale: koreanLocale,
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
        return date.formatted(style)
    }

    /// "16:05" — 24-hour clock in the current time zone.
    static func time(_ date: Date) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
        return date.formatted(style)
    }

    // MARK: Rates and relative times

    /// "8.0%/hr".
    static func rate(_ percentPerHour: Double) -> String {
        guard percentPerHour.isFinite else { return "–" }
        return String(format: "%.1f%%/hr", max(0, percentPerHour))
    }

    /// "지금" (< 60 s or in the future), "3분 전", "2시간 전", "3일 전".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "지금" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 전" }
        return "\(hours / 24)일 전"
    }

    /// "현재 속도면 16:05에 한도 도달"; when the date is not today: "현재 속도면 (목) 16:05에 한도 도달".
    static func exhaustionText(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let when = calendar.isDate(date, inSameDayAs: now) ? time(date) : "(\(weekday(date))) \(time(date))"
        return "현재 속도면 \(when)에 한도 도달"
    }
}
