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

/// Semantic skeleton type inferred for the unstable trailing segment during streaming.
public enum ProgressiveMarkdownSkeletonKind: String, Sendable, Equatable {
    case text
    case list
    case code
    case table
}

/// Result of splitting a streaming Markdown source into a semantically stable prefix
/// (safe to parse and display immediately) and an unstable trailing segment (represented
/// by a stable semantic skeleton until its block structure closes or streaming ends).
public struct ProgressiveMarkdownSplit: Sendable, Equatable {
    public let stableSource: String
    public let unstableTail: String
    public let skeletonKind: ProgressiveMarkdownSkeletonKind?

    public init(stableSource: String, unstableTail: String, skeletonKind: ProgressiveMarkdownSkeletonKind?) {
        self.stableSource = stableSource
        self.unstableTail = unstableTail
        self.skeletonKind = skeletonKind
    }
}

public enum ProgressiveMarkdownSplitter {
    /// Splits streaming Markdown source along semantic block boundaries.
    /// When `isStreaming` is false, the entire source is treated as stable so the
    /// rendered output always matches one-shot `MarkdownBlocks.parse(text)`.
    public static func split(_ text: String, isStreaming: Bool) -> ProgressiveMarkdownSplit {
        guard isStreaming else {
            return ProgressiveMarkdownSplit(stableSource: text, unstableTail: "", skeletonKind: nil)
        }
        guard text.contains(where: { !$0.isWhitespace }) else {
            return ProgressiveMarkdownSplit(stableSource: "", unstableTail: "", skeletonKind: nil)
        }

        let lines = splitLinesPreservingNewlines(text)
        var stableEnd = text.startIndex
        var blockStart: String.Index? = nil
        var activeFenceChar: Character? = nil
        var activeFenceLen = 0
        var inTable = false
        var tableHasSeparator = false
        var inList = false
        var inQuote = false

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let content = line.content
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let hasNewline = line.hasNewline

            // 1. Inside fenced code block
            if let fenceChar = activeFenceChar {
                if hasNewline && isClosingFence(trimmed, char: fenceChar, minLength: activeFenceLen) {
                    activeFenceChar = nil
                    activeFenceLen = 0
                    blockStart = nil
                    stableEnd = line.range.upperBound
                }
                index += 1
                continue
            }

            // 2. Check opening fenced code block
            if let fence = openingFence(trimmed) {
                if blockStart != nil && !inTable {
                    // Previous paragraph/list/quote ended cleanly before the new fence.
                    stableEnd = line.range.lowerBound
                }
                inTable = false
                tableHasSeparator = false
                inList = false
                inQuote = false
                activeFenceChar = fence.char
                activeFenceLen = fence.length
                blockStart = line.range.lowerBound
                index += 1
                continue
            }

            // 3. Blank line closes open paragraphs, quotes, lists, and tables
            if trimmed.isEmpty {
                if hasNewline {
                    if inTable && !tableHasSeparator {
                        // Incomplete table-like text without separator becomes a normal paragraph once blank-terminated.
                    }
                    inTable = false
                    tableHasSeparator = false
                    inList = false
                    inQuote = false
                    blockStart = nil
                    stableEnd = line.range.upperBound
                }
                index += 1
                continue
            }

            // 4. Incomplete final line (no trailing newline) is always unstable,
            //    but if it opens a new distinct block (list item, heading, fence, table),
            //    commit the preceding newline-terminated block immediately.
            if !hasNewline {
                if blockStart != nil {
                    if isATXHeading(trimmed) || isListItem(trimmed) || openingFence(trimmed) != nil ||
                        (!inTable && isTableRow(trimmed)) {
                        stableEnd = line.range.lowerBound
                        if isListItem(trimmed) { inList = true }
                    }
                } else {
                    blockStart = line.range.lowerBound
                }
                break
            }

            // 5. Table continuation / header detection
            if inTable {
                if isTableRow(trimmed) {
                    if !tableHasSeparator && isTableSeparator(trimmed) {
                        tableHasSeparator = true
                        stableEnd = line.range.upperBound
                    } else if tableHasSeparator {
                        // Complete newline-terminated body row is safe to commit progressively!
                        stableEnd = line.range.upperBound
                    }
                    index += 1
                    continue
                } else {
                    if tableHasSeparator {
                        stableEnd = line.range.lowerBound
                    }
                    inTable = false
                    tableHasSeparator = false
                    blockStart = nil
                }
            }

            // 6. ATX Heading (# Heading) terminated by newline
            if isATXHeading(trimmed) {
                if blockStart != nil {
                    stableEnd = line.range.lowerBound
                }
                inList = false
                inQuote = false
                blockStart = nil
                stableEnd = line.range.upperBound
                index += 1
                continue
            }

            // 7. Thematic break (--- / *** / ___) — only commit immediately if not immediately following paragraph (Setext guard)
            if isThematicBreak(trimmed) && blockStart == nil {
                inList = false
                inQuote = false
                stableEnd = line.range.upperBound
                index += 1
                continue
            }

            // 8. Potential Table start (pipe line)
            if isTableRow(trimmed) && !inQuote && !inList {
                if blockStart != nil {
                    stableEnd = line.range.lowerBound
                }
                inTable = true
                tableHasSeparator = false
                blockStart = line.range.lowerBound
                index += 1
                continue
            }

            // 9. List item start — commit previous complete list item when a new sibling item begins
            if isListItem(trimmed) && !inQuote {
                if inList, blockStart != nil {
                    stableEnd = line.range.lowerBound
                } else if blockStart != nil {
                    stableEnd = line.range.lowerBound
                }
                inList = true
                blockStart = line.range.lowerBound
                index += 1
                continue
            }

            // 10. Blockquote line
            if trimmed.hasPrefix(">") {
                if !inQuote && blockStart != nil {
                    stableEnd = line.range.lowerBound
                    inList = false
                }
                inQuote = true
                if blockStart == nil { blockStart = line.range.lowerBound }
                index += 1
                continue
            } else if inQuote {
                inQuote = false
                stableEnd = line.range.lowerBound
                blockStart = line.range.lowerBound
                index += 1
                continue
            }

            // 11. Setext heading underline (=== or ---) closes the preceding paragraph
            if blockStart != nil && !inList && isSetextUnderline(trimmed) {
                blockStart = nil
                stableEnd = line.range.upperBound
                index += 1
                continue
            }

            // Regular text line inside paragraph or list item continuation
            if blockStart == nil {
                blockStart = line.range.lowerBound
            }
            index += 1
        }

        let stable = String(text[..<stableEnd])
        let tail = String(text[stableEnd...])
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else {
            return ProgressiveMarkdownSplit(stableSource: stable, unstableTail: "", skeletonKind: nil)
        }

        let skeletonKind: ProgressiveMarkdownSkeletonKind
        if activeFenceChar != nil || openingFence(trimmedTail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "") != nil {
            skeletonKind = .code
        } else if inTable || isTableRow(trimmedTail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "") {
            skeletonKind = .table
        } else if inList || isListItem(trimmedTail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "") {
            skeletonKind = .list
        } else {
            skeletonKind = .text
        }

        return ProgressiveMarkdownSplit(stableSource: stable, unstableTail: tail, skeletonKind: skeletonKind)
    }

    private struct LineSlice {
        let range: Range<String.Index>
        let content: Substring
        let hasNewline: Bool
    }

    private static func splitLinesPreservingNewlines(_ text: String) -> [LineSlice] {
        var result: [LineSlice] = []
        var start = text.startIndex
        var current = start
        while current < text.endIndex {
            if text[current] == "\n" {
                let next = text.index(after: current)
                let contentEnd = (current > start && text[text.index(before: current)] == "\r")
                    ? text.index(before: current)
                    : current
                result.append(LineSlice(range: start..<next, content: text[start..<contentEnd], hasNewline: true))
                start = next
                current = next
            } else {
                current = text.index(after: current)
            }
        }
        if start < text.endIndex {
            result.append(LineSlice(range: start..<text.endIndex, content: text[start..<text.endIndex], hasNewline: false))
        }
        return result
    }

    private static func openingFence(_ trimmed: String) -> (char: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let rest = trimmed.dropFirst(count)
        if first == "`" && rest.contains("`") { return nil }
        return (first, count)
    }

    private static func isClosingFence(_ trimmed: String, char: Character, minLength: Int) -> Bool {
        let count = trimmed.prefix(while: { $0 == char }).count
        guard count >= minLength else { return false }
        return trimmed.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func isATXHeading(_ trimmed: String) -> Bool {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return false }
        let after = trimmed.dropFirst(hashes)
        return after.isEmpty || after.first == " " || after.first == "\t"
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func isListItem(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ||
            trimmed.hasPrefix("-\t") || trimmed.hasPrefix("*\t") || trimmed.hasPrefix("+\t") {
            return true
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty && digits.count <= 9 else { return false }
        let after = trimmed.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")" else { return false }
        let rest = after.dropFirst()
        return rest.first == " " || rest.first == "\t"
    }

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.split(separator: "|").count >= 2)
    }

    private static func isTableSeparator(_ trimmed: String) -> Bool {
        guard trimmed.contains("-") else { return false }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
        guard !cleaned.isEmpty else { return false }
        return cleaned.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }
}
