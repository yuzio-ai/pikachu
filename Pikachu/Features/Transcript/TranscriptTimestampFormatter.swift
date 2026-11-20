import Foundation

enum TranscriptTimestampFormatter {
    static func shortTime(_ date: Date, relativeTo reference: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: reference)
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdjm" : "yMMMdjm")
        return formatter.string(from: date)
    }

    static func fullTimeWithZone(_ date: Date, calendar: Calendar = .current, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmszzz")
        let abbr = formatter.string(from: date)
        return "\(abbr) (\(timeZone.identifier))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(localized: "不足 1 秒")
        }
        let total = Int(clamped.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(localized: "\(hours) 小时 \(minutes) 分 \(secs) 秒")
        }
        if minutes > 0 {
            return String(localized: "\(minutes) 分 \(secs) 秒")
        }
        return String(localized: "\(secs) 秒")
    }
}
