import SwiftUI

struct IconButtonLabel: View {
    nonisolated static let side: CGFloat = 26

    let systemName: String
    var weight: Font.Weight? = nil

    var body: some View {
        Image(systemName: systemName)
            .pikachuFont(.callout, weight: weight)
            .frame(width: Self.side, height: Self.side)
    }
}

struct ToolCallIcon: View {
    @Environment(\.pikachuTypography) private var typography
    var tool: String? = nil

    private var assetName: String {
        switch tool {
        case "read", "pikachu_read": "ToolCallFile"
        case "grep", "pikachu_grep": "ToolCallFileSearch"
        case "edit", "pikachu_edit": "ToolCallFileCode"
        case "bash", "pikachu_bash": "ToolCallTerminal"
        default: "ToolCallCodeSparkle"
        }
    }

    var body: some View {
        // The artwork is inset inside its SVG view box.
        let side = typography.pointSize(for: .caption) + 4
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

private let gitIconStroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)

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
            context.stroke(line, with: .foreground, style: gitIconStroke)
            context.stroke(topCircle, with: .foreground, style: gitIconStroke)
            context.stroke(bottomCircle, with: .foreground, style: gitIconStroke)
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
            context.stroke(circle, with: .foreground, style: gitIconStroke)
            context.stroke(lines, with: .foreground, style: gitIconStroke)
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

            context.stroke(outline, with: .foreground, style: gitIconStroke)
            context.stroke(fold, with: .foreground, style: gitIconStroke)
            context.stroke(lines, with: .foreground, style: gitIconStroke)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}
