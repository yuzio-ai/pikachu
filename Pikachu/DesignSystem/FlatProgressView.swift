import SwiftUI

struct FlatProgressView: View {
    let title: LocalizedStringKey?

    init(_ title: LocalizedStringKey? = nil) {
        self.title = title
    }

    var body: some View {
        Group {
            if let title {
                ProgressView(title)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(FlatIndeterminateProgressStyle())
    }
}

private struct FlatIndeterminateProgressStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let diameter: CGFloat = switch controlSize {
        case .mini: 12
        case .small: 14
        default: 16
        }
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round)

        HStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                ZStack {
                    Circle().strokeBorder(PikachuTheme.border, lineWidth: stroke.lineWidth)
                    Circle().inset(by: stroke.lineWidth / 2).trim(from: 0, to: 0.25)
                        .stroke(PikachuTheme.selectionBorder, style: stroke)
                        .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360))
                }
                .frame(width: diameter, height: diameter)
            }
            configuration.label
        }
    }
}
