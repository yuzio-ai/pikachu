import Foundation

public struct MarkdownBlock: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        case heading(Int)
        case code(String)
        case list(ordered: Bool, items: [MarkdownListItem])
        case table(MarkdownTable)
        case quote([MarkdownBlock])
        case divider
    }

    public let id: Int
    public let sourceOffset: Int?
    public let kind: Kind
    public let content: AttributedString
    public let isLooseList: Bool
    public var text: String { String(content.characters) }

    init(id: Int, sourceOffset: Int?, kind: Kind, content: AttributedString, isLooseList: Bool = false) {
        self.id = id
        self.sourceOffset = sourceOffset
        self.kind = kind
        self.content = content
        self.isLooseList = isLooseList
    }
}

public struct MarkdownListItem: Identifiable, Sendable, Equatable {
    public let id: Int
    public let sourceOffset: Int?
    public let ordinal: Int
    public let blocks: [MarkdownBlock]
    public let taskChecked: Bool?
}

public struct MarkdownTable: Sendable, Equatable {
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: Int
        public let sourceOffset: Int?
        public let isHeader: Bool
        public let cells: [AttributedString]
    }

    public let columns: [PresentationIntent.TableColumn]
    public let rows: [Row]
}

public enum MarkdownBlocks {
    public static func parse(_ text: String, workspaceDirectory: URL?) -> [MarkdownBlock] {
        TranscriptFileLinks.enrich(parse(text), workspaceDirectory: workspaceDirectory)
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        // Source positions also make Foundation emit literal HTML blocks as runs.
        let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let emptyRows = emptyTableRow.matches(in: text, range: range)
        let marker = emptyRows.isEmpty ? nil : "\u{E000}\(UUID().uuidString)\u{E000}"
        let insertions = emptyRows.map {
            Insertion(offset: NSMaxRange($0.range), value: marker ?? "")
        }
        let prepared = PreparedSource(text, insertions: insertions)
        let positions = LineOffsets(prepared.text.utf8)
        guard let attributed = try? AttributedString(markdown: prepared.text, options: options) else { return [] }

        var nodes: [Node] = []
        var literalID = -1
        for run in attributed.runs {
            var path = run.presentationIntent?.components ?? []
            var content = AttributedString(attributed[run.range])
            let position = run.markdownSourcePosition
            content.presentationIntent = nil
            content.markdownSourcePosition = nil
            if let marker {
                while let markerRange = content.range(of: marker) {
                    content.replaceSubrange(markerRange, with: AttributedString())
                }
            }
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                content = AttributedString("\n")
            }
            if let link = run.link, run.imageURL == nil, let position {
                content = restoreLinkLabel(in: content, link: link, position: position,
                                           source: prepared.text.utf8, positions: positions)
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
            let offset = position.flatMap { positions.offset(line: $0.startLine, column: $0.startColumn) }
            append(content, path: path[...], offset: offset.map(prepared.originalOffset),
                   startLine: position?.startLine, endLine: position?.endLine, nodes: &nodes)
        }
        return nodes.map { $0.block(source: text.utf8, blankLines: positions.blankLines) }
    }

    // Foundation omits rows without any text runs. Mark one empty cell in pipe-only
    // lines before parsing. The parser still decides whether the line is a table.
    private static let emptyTableRow = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:>[ \t]*|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*\|(?=[ \t]*\|[| \t]*$)"#,
        options: .anchorsMatchLines
    )
    private static func restoreLinkLabel(
        in content: AttributedString, link: URL, position: AttributedString.MarkdownSourcePosition,
        source: String.UTF8View, positions: LineOffsets
    ) -> AttributedString {
        // Foundation flattens formatting within link labels. Its source range
        // sometimes excludes adjacent code delimiters from a code-only label.
        guard let startOffset = positions.offset(line: position.startLine, column: position.startColumn),
              let endOffset = positions.offset(line: position.endLine, column: position.endColumn),
              startOffset <= endOffset, endOffset < positions.length else { return content }
        var start = source.index(source.startIndex, offsetBy: startOffset)
        var end = source.index(source.startIndex, offsetBy: endOffset + 1)
        while start > source.startIndex, source[source.index(before: start)] == 96 { source.formIndex(before: &start) }
        while end < source.endIndex, source[end] == 96 { source.formIndex(after: &end) }
        guard start > source.startIndex, source[source.index(before: start)] == 91,
              end < source.endIndex, source[end] == 93 else { return content }
        let label = source[start..<end]
        guard label.contains(where: { $0 == 96 || $0 == 42 || $0 == 95 || $0 == 126 }) else { return content }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: String(decoding: label, as: UTF8.self), options: options),
              String(parsed.characters).utf8.elementsEqual(String(content.characters).utf8),
              parsed.runs.contains(where: { $0.inlinePresentationIntent != nil }) else { return content }

        let surrounding = content.runs.first?.inlinePresentationIntent ?? []
        var restored = AttributedString()
        for run in parsed.runs {
            var fragment = AttributedString(String(parsed[run.range].characters))
            fragment.link = link
            let intent = (run.inlinePresentationIntent ?? []).union(surrounding)
            fragment.inlinePresentationIntent = intent.isEmpty ? nil : intent
            restored.append(fragment)
        }
        return restored
    }

    private struct Insertion {
        let offset: Int
        let value: String
    }

    private struct LineOffsets {
        let offsets: [Int]
        let length: Int
        let blankLines: Set<Int>

        init(_ source: String.UTF8View) {
            var offsets = [0]
            var previousWasCR = false
            var blankLines: Set<Int> = []
            var isBlank = true
            for (index, character) in source.enumerated() {
                if character == 13 || character == 10 {
                    if previousWasCR && character == 10 {
                        offsets[offsets.count - 1] = index + 1
                    } else {
                        if isBlank { blankLines.insert(offsets.count) }
                        offsets.append(index + 1)
                        isBlank = true
                    }
                } else if character != 32 && character != 9 && character != 62 {
                    isBlank = false
                }
                previousWasCR = character == 13
            }
            self.offsets = offsets
            length = source.count
            self.blankLines = blankLines
        }

        func offset(line: Int, column: Int) -> Int? {
            guard line > 0, line <= offsets.count, column > 0 else { return nil }
            let offset = offsets[line - 1] + column - 1
            return offset <= length ? offset : nil
        }
    }

    private struct PreparedSource {
        let text: String
        let insertedRanges: [Range<Int>]
        let removedPrefix: [Int]

        init(_ text: String, insertions: [Insertion]) {
            let sorted = insertions.sorted { $0.offset < $1.offset }
            guard !sorted.isEmpty else {
                self.text = text
                insertedRanges = []
                removedPrefix = []
                return
            }
            let source = text as NSString
            var result = ""
            var nextOffset = 0
            var emittedBytes = 0
            var insertedBytes = 0
            var prefix: [Int] = []
            insertedRanges = sorted.map { insertion in
                let chunk = source.substring(with: NSRange(location: nextOffset, length: insertion.offset - nextOffset))
                result += chunk
                result += insertion.value
                nextOffset = insertion.offset
                let start = emittedBytes + chunk.utf8.count
                let count = insertion.value.utf8.count
                emittedBytes = start + count
                insertedBytes += count
                prefix.append(insertedBytes)
                return start..<(start + count)
            }
            removedPrefix = prefix
            result += source.substring(from: nextOffset)
            self.text = result
        }

        func originalOffset(_ offset: Int) -> Int {
            var lower = 0
            var upper = insertedRanges.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if insertedRanges[middle].lowerBound < offset { lower = middle + 1 }
                else { upper = middle }
            }
            guard lower > 0 else { return offset }
            let last = insertedRanges[lower - 1]
            return offset - removedPrefix[lower - 1] + max(0, last.upperBound - offset)
        }
    }

    private static func append(_ content: AttributedString,
                               path: ArraySlice<PresentationIntent.IntentType>,
                               offset: Int?, startLine: Int?, endLine: Int?,
                               nodes: inout [Node]) {
        guard let component = path.last else { return }
        if nodes.last?.component.identity != component.identity {
            nodes.append(Node(component: component))
        }
        let index = nodes.count - 1
        if nodes[index].sourceOffset == nil { nodes[index].sourceOffset = offset }
        if nodes[index].startLine == nil { nodes[index].startLine = startLine }
        if let endLine { nodes[index].endLine = max(nodes[index].endLine ?? endLine, endLine) }
        if path.count == 1 {
            nodes[index].content.append(content)
        } else {
            append(content, path: path.dropLast(), offset: offset, startLine: startLine, endLine: endLine,
                   nodes: &nodes[index].children)
        }
    }

    private struct Node {
        let component: PresentationIntent.IntentType
        var content = AttributedString()
        var children: [Node] = []
        var sourceOffset: Int?
        var startLine: Int?
        var endLine: Int?

        func block(source: String.UTF8View, blankLines: Set<Int>) -> MarkdownBlock {
            let kind: MarkdownBlock.Kind
            var inlineContent = content
            var isLooseList = false
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
                    isLooseList = isLooseList || Self.hasBlankBetween(child.children, blankLines: blankLines)
                    var blocks = child.children.map { $0.block(source: source, blankLines: blankLines) }
                    let taskChecked = Self.extractTask(from: &blocks, source: source)
                    return .init(id: child.component.identity, sourceOffset: child.sourceOffset, ordinal: ordinal,
                                 blocks: blocks, taskChecked: taskChecked)
                }
                isLooseList = isLooseList || Self.hasBlankBetween(children, blankLines: blankLines)
                kind = .list(ordered: component.kind == .orderedList, items: items)
            case .table(let columns):
                let rows = children.map { row in
                    var cells = Array(repeating: AttributedString(), count: columns.count)
                    for cell in row.children {
                        if case .tableCell(let column) = cell.component.kind, cells.indices.contains(column) {
                            cells[column] = cell.content
                        }
                    }
                    return MarkdownTable.Row(id: row.component.identity, sourceOffset: row.sourceOffset,
                                             isHeader: row.component.kind == .tableHeaderRow, cells: cells)
                }
                kind = .table(.init(columns: columns, rows: rows))
            case .blockQuote:
                kind = .quote(children.map { $0.block(source: source, blankLines: blankLines) })
            case .thematicBreak:
                kind = .divider
            default:
                kind = .paragraph
            }
            return .init(id: component.identity, sourceOffset: sourceOffset, kind: kind,
                         content: inlineContent, isLooseList: isLooseList)
        }

        private static func hasBlankBetween(_ nodes: [Node], blankLines: Set<Int>) -> Bool {
            zip(nodes, nodes.dropFirst()).contains { previous, next in
                guard let end = previous.endLine, let start = next.startLine,
                      end >= 1, end < start - 1 else { return false }
                return ((end + 1)..<start).contains { blankLines.contains($0) }
            }
        }

        private static func extractTask(from blocks: inout [MarkdownBlock], source: String.UTF8View) -> Bool? {
            guard let first = blocks.first, case .paragraph = first.kind,
                  let offset = first.sourceOffset, offset >= 0,
                  let startIndex = source.index(source.startIndex, offsetBy: offset, limitedBy: source.endIndex),
                  let endIndex = source.index(startIndex, offsetBy: 4, limitedBy: source.endIndex) else { return nil }
            let marker = String(decoding: source[startIndex..<endIndex], as: UTF8.self)
            let isChecked: Bool
            switch marker {
            case "[x] ", "[X] ", "[x]\t", "[X]\t": isChecked = true
            case "[ ] ", "[ ]\t": isChecked = false
            default: return nil
            }
            guard first.text.hasPrefix(marker) else { return nil }
            let start = first.content.characters.index(first.content.startIndex, offsetBy: 4)
            blocks[0] = MarkdownBlock(id: first.id, sourceOffset: first.sourceOffset, kind: first.kind,
                                      content: AttributedString(first.content[start...]))
            return isChecked
        }
    }
}
