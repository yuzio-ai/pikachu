import SwiftUI
import OrchestrationCore

/// Static, low-contrast semantic skeleton rendered for an unstable trailing Markdown block
/// during streaming. Never shimmers, flashes, or changes geometry per token.
struct MarkdownSemanticSkeletonView: View {
    let kind: ProgressiveMarkdownSkeletonKind
    let width: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    private var barFill: Color {
        contrast == .increased ? ZivviTheme.border : ZivviTheme.subtleDivider
    }

    private var surfaceFill: Color {
        ZivviTheme.mutedSurface
    }

    var body: some View {
        let clampedWidth = max(120, width)
        Group {
            switch kind {
            case .text:
                textSkeleton(width: clampedWidth)
            case .list:
                listSkeleton(width: clampedWidth)
            case .code:
                codeSkeleton(width: clampedWidth)
            case .table:
                tableSkeleton(width: clampedWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("markdown-semantic-skeleton-\(kind.rawValue)")
    }

    private var accessibilityLabel: String {
        switch kind {
        case .text: String(localized: "正在生成正文内容")
        case .list: String(localized: "正在生成列表内容")
        case .code: String(localized: "正在生成代码块")
        case .table: String(localized: "正在生成表格内容")
        }
    }

    private func bar(_ fraction: CGFloat, in width: CGFloat, height: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(barFill)
            .frame(width: max(24, floor(width * fraction)), height: height)
    }

    private func textSkeleton(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            bar(0.92, in: width)
            bar(0.98, in: width)
            bar(0.84, in: width)
            bar(0.90, in: width)
            bar(0.62, in: width)
        }
        .padding(.vertical, 4)
    }

    private func listSkeleton(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.78, 0.86, 0.68, 0.74], id: \.self) { ratio in
                HStack(spacing: 8) {
                    Circle()
                        .fill(barFill)
                        .frame(width: 5, height: 5)
                    bar(ratio, in: max(80, width - 16))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func codeSkeleton(width: CGFloat) -> some View {
        let innerWidth = max(80, width - 24)
        return VStack(alignment: .leading, spacing: 8) {
            bar(0.18, in: innerWidth, height: 8)
                .padding(.bottom, 2)
            bar(0.76, in: innerWidth, height: 8.5)
            bar(0.62, in: innerWidth, height: 8.5)
            bar(0.88, in: innerWidth, height: 8.5)
            bar(0.48, in: innerWidth, height: 8.5)
            bar(0.70, in: innerWidth, height: 8.5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tableSkeleton(width: CGFloat) -> some View {
        let colWidth = max(48, floor((width - 36) / 3))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                bar(0.65, in: colWidth, height: 9)
                bar(0.75, in: colWidth, height: 9)
                bar(0.55, in: colWidth, height: 9)
            }
            ZivviDivider(color: barFill)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 18) {
                    bar(row == 1 ? 0.80 : 0.60, in: colWidth, height: 8.5)
                    bar(row == 2 ? 0.68 : 0.84, in: colWidth, height: 8.5)
                    bar(row == 0 ? 0.72 : 0.52, in: colWidth, height: 8.5)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
