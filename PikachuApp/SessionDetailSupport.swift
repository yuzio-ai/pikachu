import SwiftUI

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

struct GitBranchIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var line = Path()
            line.move(to: CGPoint(x: 6 * w, y: 3 * h))
            line.addLine(to: CGPoint(x: 6 * w, y: 15 * h))
            line.move(to: CGPoint(x: 18 * w, y: 9 * h))
            line.addCurve(to: CGPoint(x: 6 * w, y: 18 * h),
                          control1: CGPoint(x: 18 * w, y: 14 * h),
                          control2: CGPoint(x: 12 * w, y: 18 * h))
            var topCircle = Path()
            topCircle.addEllipse(in: CGRect(x: 15 * w, y: 3 * h, width: 6 * w, height: 6 * h))
            var bottomCircle = Path()
            bottomCircle.addEllipse(in: CGRect(x: 3 * w, y: 15 * h, width: 6 * w, height: 6 * h))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            context.stroke(line, with: .foreground, style: style)
            context.stroke(topCircle, with: .foreground, style: style)
            context.stroke(bottomCircle, with: .foreground, style: style)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

struct GitCommitIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 9 * w, y: 9 * h, width: 6 * w, height: 6 * h))
            var lines = Path()
            lines.move(to: CGPoint(x: 3 * w, y: 12 * h))
            lines.addLine(to: CGPoint(x: 9 * w, y: 12 * h))
            lines.move(to: CGPoint(x: 15 * w, y: 12 * h))
            lines.addLine(to: CGPoint(x: 21 * w, y: 12 * h))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            context.stroke(circle, with: .foreground, style: style)
            context.stroke(lines, with: .foreground, style: style)
        }
        .frame(width: 14, height: 13)
        .accessibilityHidden(true)
    }
}

struct FileTextIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var outline = Path()
            outline.move(to: CGPoint(x: 14 * w, y: 2 * h))
            outline.addLine(to: CGPoint(x: 6 * w, y: 2 * h))
            outline.addQuadCurve(to: CGPoint(x: 4 * w, y: 4 * h), control: CGPoint(x: 4 * w, y: 2 * h))
            outline.addLine(to: CGPoint(x: 4 * w, y: 20 * h))
            outline.addQuadCurve(to: CGPoint(x: 6 * w, y: 22 * h), control: CGPoint(x: 4 * w, y: 22 * h))
            outline.addLine(to: CGPoint(x: 18 * w, y: 22 * h))
            outline.addQuadCurve(to: CGPoint(x: 20 * w, y: 20 * h), control: CGPoint(x: 20 * w, y: 22 * h))
            outline.addLine(to: CGPoint(x: 20 * w, y: 8 * h))
            outline.closeSubpath()

            var fold = Path()
            fold.move(to: CGPoint(x: 14 * w, y: 2 * h))
            fold.addLine(to: CGPoint(x: 14 * w, y: 8 * h))
            fold.addLine(to: CGPoint(x: 20 * w, y: 8 * h))

            var lines = Path()
            lines.move(to: CGPoint(x: 8 * w, y: 13 * h))
            lines.addLine(to: CGPoint(x: 16 * w, y: 13 * h))
            lines.move(to: CGPoint(x: 8 * w, y: 17 * h))
            lines.addLine(to: CGPoint(x: 16 * w, y: 17 * h))

            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            context.stroke(outline, with: .foreground, style: style)
            context.stroke(fold, with: .foreground, style: style)
            context.stroke(lines, with: .foreground, style: style)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

struct ComposerControlSurface: ViewModifier {
    let isOpen: Bool
    let isEnabled: Bool
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        if isOpen {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
        if isHovered && isEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
        }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(backgroundColor, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct ComposerControlButtonStyle: ButtonStyle {
    let isOpen: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = {
            if !isEnabled { return .clear }
            if isOpen {
                return Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.13)
            }
            if configuration.isPressed {
                return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.11)
            }
            if isHovered {
                return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
            }
            return .clear
        }()

        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
