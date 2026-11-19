import Foundation

public struct MarkdownBlock: Identifiable, Sendable {
    public enum Kind: Sendable {
        case paragraph
        case heading(Int)
        case code(String)
        case list(ordered: Bool, items: [MarkdownListItem])
        case table(MarkdownTable)
        case quote([MarkdownBlock])
        case divider
    }

    public let id: Int
    public let kind: Kind
    public let content: AttributedString
    public var text: String { String(content.characters) }
}

public struct MarkdownListItem: Identifiable, Sendable {
    public let id: Int
    public let ordinal: Int
    public let blocks: [MarkdownBlock]
}

public struct MarkdownTable: Sendable {
    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let isHeader: Bool
        public let cells: [AttributedString]
    }

    public let columns: [PresentationIntent.TableColumn]
    public let rows: [Row]
}

public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        // Source positions also make Foundation emit literal HTML blocks as runs.
        let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
        var source = text
        var emptyCellMarker: String?
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if emptyTableRow.firstMatch(in: text, range: range) != nil {
            let marker = "\u{E000}\(UUID().uuidString)\u{E000}"
            source = emptyTableRow.stringByReplacingMatches(in: text, range: range, withTemplate: "$0" + marker)
            emptyCellMarker = marker
        }
        guard let attributed = try? AttributedString(markdown: source, options: options) else { return [] }

        var nodes: [Node] = []
        var literalID = -1
        for run in attributed.runs {
            var path = run.presentationIntent?.components ?? []
            var content = AttributedString(attributed[run.range])
            content.presentationIntent = nil
            content.markdownSourcePosition = nil
            if let marker = emptyCellMarker {
                while let markerRange = content.range(of: marker) {
                    content.replaceSubrange(markerRange, with: AttributedString())
                }
            }
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                content = AttributedString("\n")
            }
            switch path.first?.kind {
            case nil, .blockQuote, .listItem:
                // A raw block has no leaf intent of its own.
                path = PresentationIntent(.paragraph, identity: literalID, parent: run.presentationIntent).components
                literalID -= 1
                content.inlinePresentationIntent = nil
                if content.characters.last == "\n" { content.characters.removeLast() }
            default:
                break
            }
            // Foundation lists the innermost block first.
            append(content, path: path[...], nodes: &nodes)
        }
        return nodes.map(\.block)
    }

    // Foundation omits rows without any text runs. Mark one empty cell in pipe-only
    // lines before parsing. The parser still decides whether the line is a table.
    private static let emptyTableRow = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:>[ \t]*|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*\|(?=[ \t]*\|[| \t]*$)"#,
        options: .anchorsMatchLines
    )

    private static func append(_ content: AttributedString,
                               path: ArraySlice<PresentationIntent.IntentType>,
                               nodes: inout [Node]) {
        guard let component = path.last else { return }
        if nodes.last?.component.identity != component.identity {
            nodes.append(Node(component: component))
        }
        let index = nodes.count - 1
        if path.count == 1 {
            nodes[index].content.append(content)
        } else {
            append(content, path: path.dropLast(), nodes: &nodes[index].children)
        }
    }

    private struct Node {
        let component: PresentationIntent.IntentType
        var content = AttributedString()
        var children: [Node] = []

        var block: MarkdownBlock {
            let kind: MarkdownBlock.Kind
            var inlineContent = content
            switch component.kind {
            case .header(let level):
                kind = .heading(level)
            case .codeBlock(let language):
                kind = .code(language ?? "")
                if inlineContent.characters.last == "\n" {
                    inlineContent.characters.removeLast()
                }
            case .orderedList, .unorderedList:
                let items = children.compactMap { child -> MarkdownListItem? in
                    guard case .listItem(let ordinal) = child.component.kind else { return nil }
                    return .init(id: child.component.identity, ordinal: ordinal, blocks: child.children.map(\.block))
                }
                kind = .list(ordered: component.kind == .orderedList, items: items)
            case .table(let columns):
                let rows = children.map { row in
                    var cells = Array(repeating: AttributedString(), count: columns.count)
                    for cell in row.children {
                        if case .tableCell(let column) = cell.component.kind, cells.indices.contains(column) {
                            cells[column] = cell.content
                        }
                    }
                    return MarkdownTable.Row(id: row.component.identity, isHeader: row.component.kind == .tableHeaderRow, cells: cells)
                }
                kind = .table(.init(columns: columns, rows: rows))
            case .blockQuote:
                kind = .quote(children.map(\.block))
            case .thematicBreak:
                kind = .divider
            default:
                kind = .paragraph
            }
            return .init(id: component.identity, kind: kind, content: inlineContent)
        }
    }
}
