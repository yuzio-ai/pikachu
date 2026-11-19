import Foundation

enum TranscriptTimestampFormatter {
    static func shortTime(_ date: Date, relativeTo reference: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: reference)
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func fullTimeWithZone(_ date: Date, calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss zzz"
        let abbr = formatter.string(from: date)
        return "\(abbr) (\(timeZone.identifier))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return "不足 1 秒"
        }
        let total = Int(clamped.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分 \(secs) 秒"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(secs) 秒"
        }
        return "\(secs) 秒"
    }
}
