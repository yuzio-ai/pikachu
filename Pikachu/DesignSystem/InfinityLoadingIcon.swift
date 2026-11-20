import SwiftUI

/// Native rendering of Jannchie Icons' `loading-infinity` (MIT; see THIRD-PARTY-NOTICES.md).
struct InfinityLoadingIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0.15 : elapsed.truncatingRemainder(dividingBy: 2) / 2

            Canvas { context, canvasSize in
                let unit = canvasSize.width / 24
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                func point(at phase: Double) -> CGPoint {
                    let angle = 2 * Double.pi * phase
                    let sine = sin(angle)
                    let x = 9 * unit * cos(angle) / (1 + sine * sine)
                    return CGPoint(x: center.x + x, y: center.y + x * sine)
                }

                func curve(from start: Double, length: Double, segments: Int) -> Path {
                    Path { path in
                        path.move(to: point(at: start))
                        for step in 1...segments {
                            path.addLine(to: point(at: start + length * Double(step) / Double(segments)))
                        }
                        if length == 1 { path.closeSubpath() }
                    }
                }

                var track = context
                track.opacity = 0.55
                track.stroke(curve(from: 0, length: 1, segments: 64), with: .foreground,
                             style: StrokeStyle(lineWidth: unit, lineJoin: .round))
                context.stroke(curve(from: phase, length: 0.3, segments: 16), with: .foreground,
                               style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round))
                let tip = point(at: phase + 0.3)
                let radius = 1.5 * unit
                context.fill(Path(ellipseIn: CGRect(x: tip.x - radius, y: tip.y - radius,
                                                    width: 2 * radius, height: 2 * radius)), with: .foreground)
            }
        }
        .frame(width: size, height: size)
    }
}
