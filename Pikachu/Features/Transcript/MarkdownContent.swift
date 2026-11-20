import AppKit
import CoreText
import SwiftUI
import OrchestrationCore

struct MarkdownContent: View {
    @Environment(\.pikachuTypography) private var typography
    @State private var cache = MarkdownContentCache()
    let text: String
    let streaming: Bool
    let width: CGFloat

    var body: some View {
        let layout = streaming ? nil : cache.layout(for: text, typography: typography)
        VStack(alignment: .leading, spacing: 15) {
            if let layout, !layout.blocks.isEmpty {
                ForEach(layout.blocks) { block in
                    MarkdownBlockView(block: block, width: width, tableWidths: layout.tableWidths)
                }
            } else {
                Text(text).textSelection(.enabled)
            }
        }
        .lineSpacing(3)
    }
}

@MainActor final class MarkdownContentCache {
    struct Layout {
        let blocks: [MarkdownBlock]
        let tableWidths: [Int: [CGFloat]]
    }

    private var entry: (source: String, typography: PikachuTypography, layout: Layout)?

    func layout(for text: String, typography: PikachuTypography) -> Layout {
        let previous = entry.flatMap { $0.source.utf8.elementsEqual(text.utf8) ? $0 : nil }
        if let previous, previous.typography == typography { return previous.layout }

        let blocks = previous?.layout.blocks ?? MarkdownBlocks.parse(text)
        var tableWidths: [Int: [CGFloat]] = [:]
        measureTables(in: blocks, typography: typography, widths: &tableWidths)
        let layout = Layout(blocks: blocks, tableWidths: tableWidths)
        entry = (source: text, typography: typography, layout: layout)
        return layout
    }

    private func measureTables(in blocks: [MarkdownBlock], typography: PikachuTypography, widths: inout [Int: [CGFloat]]) {
        for block in blocks {
            switch block.kind {
            case .table(let table):
                widths[block.id] = MarkdownTableLayout.naturalWidths(of: table, typography: typography)
            case .quote(let children):
                measureTables(in: children, typography: typography, widths: &widths)
            case .list(_, let items):
                for item in items {
                    measureTables(in: item.blocks, typography: typography, widths: &widths)
                }
            default:
                break
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let width: CGFloat
    let tableWidths: [Int: [CGFloat]]

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content).textSelection(.enabled)
        case .heading(let level):
            Text(block.content)
                .pikachuFont(level <= 2 ? .title3 : .headline, weight: .semibold)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.isEmpty ? String(localized: "代码") : language).pikachuFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CopyCodeButton(text: block.text)
                }
                ScrollView(.horizontal) {
                    Text(block.text).lineSpacing(0).pikachuFont(.callout, design: .monospaced).textSelection(.enabled)
                }
            }
            .padding(12)
            .flatSurface(PikachuTheme.mutedSurface, radius: 9)
        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items, width: width, tableWidths: tableWidths)
        case .table(let table):
            MarkdownTableView(table: table, width: width, naturalWidths: tableWidths[block.id])
        case .quote(let children):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(children) { child in
                    MarkdownBlockView(block: child, width: max(1, width - 20), tableWidths: tableWidths)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(PikachuTheme.mutedSurface, in: .rect(cornerRadius: 8))
            .overlay(alignment: .leading) {
                Rectangle().fill(PikachuTheme.selectionBorder).frame(width: 1).allowsHitTesting(false)
            }
        case .divider:
            PikachuDivider()
        }
    }
}

private struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownListItem]
    let width: CGFloat
    let tableWidths: [Int: [CGFloat]]

    var body: some View {
        let markerWidth: CGFloat = ordered ? max(20, CGFloat(String(items.last?.ordinal ?? 1).count + 1) * 8) : 12

        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(item.ordinal)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: markerWidth, alignment: .trailing)
                        .accessibilityHidden(!ordered)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.blocks) { block in
                            MarkdownBlockView(block: block, width: max(1, width - markerWidth - 8), tableWidths: tableWidths)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

struct MarkdownTableLayout {
    static let columnSpacing: CGFloat = 18

    let columnWidths: [CGFloat]
    let needsHorizontalScroll: Bool

    init(naturalWidths: [CGFloat], bodySize: CGFloat, availableWidth: CGFloat) {
        let spacing = Self.columnSpacing * CGFloat(max(0, naturalWidths.count - 1))
        var widths = naturalWidths.map { min($0, 6 * bodySize) }
        let minimumWidth = widths.reduce(0, +) + spacing
        needsHorizontalScroll = minimumWidth > availableWidth
        var remaining = availableWidth - minimumWidth
        let weights = naturalWidths.indices.map { min(naturalWidths[$0], 28 * bodySize) - widths[$0] }
        var flexibleColumns = widths.indices.filter { weights[$0] > 0 }

        while remaining > 0.01, !flexibleColumns.isEmpty {
            let weightTotal = flexibleColumns.reduce(CGFloat.zero) { $0 + weights[$1] }
            let budget = remaining
            for column in flexibleColumns {
                let extra = min(budget * weights[column] / weightTotal, naturalWidths[column] - widths[column])
                widths[column] += extra
                remaining -= extra
            }
            flexibleColumns.removeAll { naturalWidths[$0] - widths[$0] < 0.01 }
        }
        columnWidths = widths
    }

    @MainActor static func naturalWidths(of table: MarkdownTable, typography: PikachuTypography) -> [CGFloat] {
        let headerFonts = MarkdownTableFonts(typography: typography, isHeader: true)
        let bodyFonts = MarkdownTableFonts(typography: typography, isHeader: false)
        var widths = Array(repeating: CGFloat.zero, count: table.columns.count)
        for row in table.rows {
            let fonts = row.isHeader ? headerFonts : bodyFonts
            for (column, cell) in row.cells.enumerated() {
                widths[column] = max(widths[column], fonts.naturalWidth(of: cell))
            }
        }
        return widths
    }
}

private struct MarkdownTableView: View {
    @Environment(\.pikachuTypography) private var typography
    let table: MarkdownTable
    let width: CGFloat
    let naturalWidths: [CGFloat]?

    var body: some View {
        let layout = MarkdownTableLayout(naturalWidths: naturalWidths ?? MarkdownTableLayout.naturalWidths(of: table, typography: typography),
                                         bodySize: typography.pointSize(for: .body), availableWidth: width)
        let rows = MarkdownTableRows(table: table, widths: layout.columnWidths, typography: typography)

        if layout.needsHorizontalScroll {
            ScrollView(.horizontal) { rows }
                .frame(width: width)
        } else {
            rows
        }
    }
}

private struct MarkdownTableRows: View {
    let table: MarkdownTable
    let widths: [CGFloat]
    let typography: PikachuTypography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(table.rows.enumerated(), id: \.element.id) { index, row in
                if index > 1 {
                    Rectangle().fill(PikachuTheme.subtleDivider).frame(height: 1).accessibilityHidden(true)
                }
                MarkdownTableRow(row: row, columns: table.columns, widths: widths, typography: typography)
                if row.isHeader {
                    PikachuDivider()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MarkdownTableRow: View {
    let row: MarkdownTable.Row
    let columns: [PresentationIntent.TableColumn]
    let widths: [CGFloat]
    let typography: PikachuTypography

    var body: some View {
        let fonts = MarkdownTableFonts(typography: typography, isHeader: row.isHeader)
        HStack(alignment: .top, spacing: MarkdownTableLayout.columnSpacing) {
            ForEach(columns.indices, id: \.self) { column in
                let alignment = columns[column].alignment
                MarkdownTableCell(content: row.cells[column], fonts: fonts,
                                  alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .frame(width: widths[column],
                           alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .accessibilityAddTraits(row.isHeader ? .isHeader : [])
            }
        }
        .frame(minHeight: ceil(fonts.body.ascender - fonts.body.descender + fonts.body.leading), alignment: .top)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

private struct MarkdownTableCell: View {
    let content: AttributedString
    let fonts: MarkdownTableFonts
    let alignment: TextAlignment

    var body: some View {
        Group {
            if content.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) {
                markedText(fonts.stylingCode(in: content))
                    .textRenderer(MarkdownTableCodeRenderer())
            } else {
                Text(content)
            }
        }
        .font(Font(fonts.body))
        .multilineTextAlignment(alignment)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func markedText(_ cell: AttributedString) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: cell.runs.count)
        for run in cell.runs {
            let span = Text(AttributedString(cell[run.range]))
            let marked = run.inlinePresentationIntent?.contains(.code) == true ? span.customAttribute(MarkdownTableCode()) : span
            interpolation.appendInterpolation(marked)
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation))
    }
}

@MainActor struct MarkdownTableFonts {
    let body: NSFont
    let code: NSFont

    init(typography: PikachuTypography, isHeader: Bool) {
        let weight: NSFont.Weight = isHeader ? .semibold : .regular
        body = typography.nsFont(.body, weight: weight)
        code = .monospacedSystemFont(ofSize: typography.pointSize(for: .callout), weight: weight)
    }

    private func font(for intent: InlinePresentationIntent) -> NSFont {
        let isCode = intent.contains(.code)
        var font = isCode ? code : body
        if intent.contains(.stronglyEmphasized) {
            font = isCode
                ? .monospacedSystemFont(ofSize: code.pointSize, weight: .bold)
                : .systemFont(ofSize: body.pointSize, weight: .bold)
        }
        if intent.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    func naturalWidth(of cell: AttributedString) -> CGFloat {
        let text = NSMutableAttributedString()
        for run in cell.runs {
            let font = font(for: run.inlinePresentationIntent ?? [])
            text.append(NSAttributedString(string: String(cell[run.range].characters), attributes: [.font: font]))
        }

        let string = text.string
        var width: CGFloat = 0
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: [.byLines, .substringNotRequired]) {
            _, range, _, _ in
            let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(range, in: string)))
            width = max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return ceil(width)
    }

    func stylingCode(in cell: AttributedString) -> AttributedString {
        var styled = AttributedString()
        for run in cell.runs {
            var span = AttributedString(cell[run.range])
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                span.swiftUI.font = Font(font(for: intent))
            }
            styled.append(span)
        }
        return styled
    }
}

private struct MarkdownTableCode: TextAttribute {}

private struct MarkdownTableCodeRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[MarkdownTableCode.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(PikachuTheme.selected))
            }
            context.draw(line)
        }
    }
}
