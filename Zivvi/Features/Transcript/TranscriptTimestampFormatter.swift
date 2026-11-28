import Foundation

enum TranscriptTimestampFormatter {
    static let displayLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)

    static func approvalDeadline(_ date: Date, relativeTo reference: Date = .now, calendar: Calendar = .current,
                                 timeZone: TimeZone = .current, locale: Locale = displayLocale) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        guard !calendar.isDate(date, inSameDayAs: reference) else { return time }
        formatter.locale = locale
        let sameYear = calendar.isDate(date, equalTo: reference, toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return "\(formatter.string(from: date)) \(time)"
    }

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

    static func durationText(_ seconds: TimeInterval, locale: Locale = displayLocale) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(localized: LocalizedStringResource("不足 1 秒", locale: locale))
        }
        let total = Int(clamped.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(localized: LocalizedStringResource("\(hours) 小时 \(minutes) 分 \(secs) 秒", locale: locale))
        }
        if minutes > 0 {
            return String(localized: LocalizedStringResource("\(minutes) 分 \(secs) 秒", locale: locale))
        }
        return String(localized: LocalizedStringResource("\(secs) 秒", locale: locale))
    }
}
