import SwiftUI
import OrchestrationCore

struct MarkdownContent: View {
    let text: String
    let streaming: Bool
    let width: CGFloat

    var body: some View {
        let blocks = streaming ? [] : MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            if blocks.isEmpty {
                Text(text).textSelection(.enabled)
            } else {
                GlassEffectContainer(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks) { block in
                            MarkdownBlockView(block: block, width: width)
                        }
                    }
                }
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let width: CGFloat

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content).textSelection(.enabled)
        case .heading(let level):
            Text(block.content)
                .font(level <= 2 ? .title3 : .headline)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CopyCodeButton(text: block.text).frame(width: 66, height: 23)
                }
                ScrollView(.horizontal) {
                    Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 9))
        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items, width: width)
        case .table(let table):
            MarkdownTableView(table: table, width: width)
        case .quote(let children):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(children) { child in
                    MarkdownBlockView(block: child, width: max(1, width - 20))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(in: .rect(cornerRadius: 8))
        case .divider:
            Divider()
        }
    }
}

private struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownListItem]
    let width: CGFloat

    var body: some View {
        let markerWidth: CGFloat = ordered ? max(20, CGFloat(String(items.last?.ordinal ?? 1).count + 1) * 8) : 12

        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(item.ordinal)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: markerWidth, alignment: .trailing)
                        .accessibilityHidden(!ordered)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.blocks) { block in
                            MarkdownBlockView(block: block, width: max(1, width - markerWidth - 8))
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let width: CGFloat

    private var columnWidths: [CGFloat] {
        let minimum: CGFloat = 112
        let weights = table.columns.indices.map { column in
            let longest = table.rows.map { $0.cells[column].characters.count }.max() ?? 0
            return CGFloat(max(8, min(longest, 72)))
        }
        let weightTotal = weights.reduce(0, +)
        let extra = max(0, width - minimum * CGFloat(weights.count))
        return weights.map { minimum + extra * $0 / weightTotal }
    }

    private func alignment(for column: Int) -> Alignment {
        switch table.columns[column].alignment {
        case .left: .leading
        case .right: .trailing
        case .center: .center
        @unknown default: .leading
        }
    }

    var body: some View {
        let widths = columnWidths

        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                ForEach(table.rows) { row in
                    if row.id != table.rows.first?.id { Divider() }
                    HStack(alignment: .top, spacing: 0) {
                        // Each row has one immutable cell slot per column.
                        ForEach(table.columns.indices, id: \.self) { column in
                            let cellAlignment = alignment(for: column)
                            Text(row.cells[column])
                                .fontWeight(row.isHeader ? .semibold : .regular)
                                .multilineTextAlignment(cellAlignment == .trailing ? .trailing : cellAlignment == .center ? .center : .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: widths[column] - 20, alignment: cellAlignment)
                                .padding(.horizontal, 10)
                                .textSelection(.enabled)
                                .accessibilityAddTraits(row.isHeader ? .isHeader : [])
                        }
                    }
                    .padding(.vertical, 6)
                    .background(row.isHeader ? Color.primary.opacity(0.07) : .clear)
                    .accessibilityElement(children: .contain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .glassEffect(in: .rect(cornerRadius: 8))
    }
}
