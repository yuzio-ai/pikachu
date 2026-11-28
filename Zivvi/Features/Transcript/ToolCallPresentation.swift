import Foundation
import AgentRuntimeCore
import OrchestrationCore

@MainActor struct ToolResultSource {
    typealias Validator = @MainActor @Sendable (TranscriptItem) -> Bool

    let item: TranscriptItem
    var includesItem: Validator?

    var current: TranscriptItem? {
        includesItem?(item) == false ? nil : item
    }
}

enum ToolCallKind {
    case command, edit, read, search, list, find, write, other

    var glyph: ToolCallIcon.Glyph {
        switch self {
        case .read: .read
        case .list: .list
        case .search, .find: .search
        case .edit, .write: .edit
        case .command: .terminal
        case .other: .generic
        }
    }

    init(name: String) {
        switch name {
        case "bash", "zivvi_bash": self = .command
        case "edit", "zivvi_edit": self = .edit
        case "read", "zivvi_read": self = .read
        case "grep", "zivvi_grep": self = .search
        case "ls", "zivvi_ls": self = .list
        case "find", "zivvi_find": self = .find
        case "write", "zivvi_write": self = .write
        default: self = .other
        }
    }
}

struct ToolCallPresentation {
    private struct Command: Decodable {
        let command: String
    }

    struct Read: Decodable {
        let path: String
        let offset: Int?
        let limit: Int?

        private enum CodingKeys: String, CodingKey { case path, offset, limit }

        init(from decoder: Decoder) throws {
            let arguments = try decoder.container(keyedBy: CodingKeys.self)
            path = try arguments.decode(String.self, forKey: .path)
            offset = (try? arguments.decode(Int.self, forKey: .offset)).map { max(1, $0) }
            limit = try? arguments.decode(Int.self, forKey: .limit)
        }

        var rangeLabels: [LocalizedStringResource] {
            var labels: [LocalizedStringResource] = []
            if let offset { labels.append("第 \(offset) 行起") }
            if let limit, limit >= 0 { labels.append("最多 \(limit) 行") }
            return labels
        }
    }

    struct Search: Decodable {
        let pattern: String
        let path: String?
        let glob: String?
        let limit: Int?

        private enum CodingKeys: String, CodingKey { case pattern, path, glob, limit }

        init(from decoder: Decoder) throws {
            let arguments = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try arguments.decode(String.self, forKey: .pattern)
            path = try? arguments.decode(String.self, forKey: .path)
            glob = try? arguments.decode(String.self, forKey: .glob)
            limit = try? arguments.decode(Int.self, forKey: .limit)
        }
    }

    struct Directory: Decodable {
        let path: String?
        let limit: Int?
    }

    private struct Write: Decodable {
        let path: String
    }

    enum Parameters {
        case command(String)
        case edit(RuntimeTool.EditArguments)
        case read(Read)
        case search(Search)
        case list(Directory)
        case find(Search)
        case write(String?)
        case raw
    }

    let summary: TranscriptToolSummary
    let parameters: Parameters

    init(_ summary: TranscriptToolSummary) {
        self.summary = summary
        parameters = Self.parse(summary)
    }

    private static func parse(_ summary: TranscriptToolSummary) -> Parameters {
        let arguments = summary.arguments
        switch ToolCallKind(name: summary.name) {
        case .command:
            if let command = try? JSONDecoder().decode(Command.self, from: Data(arguments.utf8)),
               command.command.contains(where: { !$0.isWhitespace }) {
                return .command(command.command)
            }
        case .edit:
            if let edit = summary.editArguments ?? (try? RuntimeTool.EditArguments.decodeToolArguments(from: Data(arguments.utf8))),
               edit.path.contains(where: { !$0.isWhitespace }), edit.replacementCount > 0 {
                return .edit(edit)
            }
        case .read:
            if let read = try? JSONDecoder().decode(Read.self, from: Data(arguments.utf8)),
               read.path.contains(where: { !$0.isWhitespace }) {
                return .read(read)
            }
        case .search, .find:
            if let search = try? JSONDecoder().decode(Search.self, from: Data(arguments.utf8)),
               !search.pattern.isEmpty {
                return ToolCallKind(name: summary.name) == .find ? .find(search) : .search(search)
            }
        case .list:
            if let directory = try? JSONDecoder().decode(Directory.self, from: Data(arguments.utf8)) {
                return .list(directory)
            }
        case .write:
            let path = summary.writePath ?? (try? JSONDecoder().decode(Write.self, from: Data(arguments.utf8)))?.path
            return .write(path.flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil })
        case .other:
            break
        }
        return .raw
    }

    var operationLabel: LocalizedStringResource? {
        switch parameters {
        case .command: "运行"
        case .edit: "编辑"
        case .read: "读取"
        case .search: "搜索"
        case .list: "列出目录"
        case .find: "查找文件"
        case .write: "写入文件"
        case .raw: nil
        }
    }

    var object: String {
        switch parameters {
        case .command(let command):
            return command.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        case .edit(let edit):
            return Self.fileName(edit.path)
        case .read(let read):
            return Self.fileName(read.path)
        case .list(let directory):
            return directory.path.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "当前目录")
        case .write(let path):
            return path.map(Self.fileName) ?? ""
        case .search(let search), .find(let search):
            return search.pattern.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .first.map(String.init) ?? search.pattern
        case .raw:
            return summary.arguments.prefix(256).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var isFileOperation: Bool {
        switch parameters {
        case .edit, .read, .write, .list: true
        case .command, .search, .find, .raw: false
        }
    }

    var qualifiers: [LocalizedStringResource] {
        switch parameters {
        case .edit(let edit): ["\(edit.replacementCount) 处替换"]
        case .read(let read): read.rangeLabels
        case .search(let search), .find(let search):
            if let path = search.path, !path.isEmpty { ["在 \(path)"] } else { [] }
        case .command, .list, .write, .raw: []
        }
    }

    var accessibilityDescription: String {
        let primary = primarySummaryText
        let status = summary.state == .completed ? nil : String(localized: summary.state.statusLabel)
        return ([primary] + [status].compactMap { $0 })
            .joined(separator: String(localized: "，"))
    }

    /// Tool Summary First (Workbench 2.0 Section 11.2):
    /// Prefers explicit `toolSummary` / `summary` / `description`, then synthesizes a
    /// concise human-readable description from trusted parameters. Never dumps raw `{JSON...}`.
    var primarySummaryText: String {
        if let explicit = explicitToolSummary {
            return explicit
        }
        switch parameters {
        case .command(let command):
            let firstLine = command.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init) ?? command
            return String(localized: "运行 \(firstLine)")
        case .edit(let edit):
            let name = Self.fileName(edit.path)
            return edit.replacementCount > 1
                ? String(localized: "编辑 \(name) · \(edit.replacementCount) 处替换")
                : String(localized: "编辑 \(name)")
        case .read(let read):
            let name = Self.fileName(read.path)
            if let offset = read.offset, let limit = read.limit, limit > 0 {
                return String(localized: "读取 \(name) · \(offset)–\(offset + limit - 1) 行")
            } else if let offset = read.offset {
                return String(localized: "读取 \(name) · 第 \(offset) 行起")
            }
            return String(localized: "读取 \(name)")
        case .write(let path):
            if let path { return String(localized: "写入 \(Self.fileName(path))") }
            return String(localized: "写入文件")
        case .search(let search):
            if let path = search.path, !path.isEmpty {
                return String(localized: "搜索 \"\(search.pattern)\" · \(path)")
            }
            return String(localized: "搜索 \"\(search.pattern)\"")
        case .find(let search):
            return String(localized: "查找文件 \(search.pattern)")
        case .list(let directory):
            let dir = directory.path.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "当前目录")
            return String(localized: "列出目录 \(dir)")
        case .raw:
            return summary.name.isEmpty ? String(localized: "工具调用") : summary.name
        }
    }

    /// Explicit human-readable toolSummary from RuntimeTool or JSON input keys.
    var explicitToolSummary: String? {
        if let explicit = summary.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        guard !summary.arguments.isEmpty,
              let data = summary.arguments.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["toolSummary", "summary", "description", "title"] {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
                    return trimmed
                }
            }
        }
        return nil
    }

    /// Structured key-value pairs for MCP / other tools so expanded details avoid dumping raw JSON immediately.
    var structuredRawEntries: [(key: String, value: String)] {
        guard case .raw = parameters,
              !summary.arguments.isEmpty,
              let data = summary.arguments.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return dict.keys.sorted().compactMap { key in
            guard key != "toolSummary" else { return nil }
            let rawValue = dict[key]
            let formatted: String
            if let str = rawValue as? String {
                formatted = str
            } else if let num = rawValue as? NSNumber {
                formatted = num.stringValue
            } else if let val = rawValue,
                      JSONSerialization.isValidJSONObject(val),
                      let encoded = try? JSONSerialization.data(withJSONObject: val),
                      let text = String(data: encoded, encoding: .utf8) {
                formatted = text
            } else {
                return nil
            }
            return (key, formatted)
        }
    }

    var targetFilePath: String? {
        switch parameters {
        case .read(let r): r.path
        case .edit(let e): e.path
        case .write(let p): p
        default: nil
        }
    }
}

enum ToolEditDiff {
    static func preview(for edit: RuntimeTool.EditArguments) -> [Line] {
        edit.edits.flatMap { lines(for: $0) ?? [] }
    }

    enum Ending: String, Hashable, Sendable {
        case lf = "\n", crlf = "\r\n", cr = "\r", verticalTab = "\u{B}", formFeed = "\u{C}"
        case nextLine = "\u{85}", lineSeparator = "\u{2028}", paragraphSeparator = "\u{2029}", none = ""

        var label: String {
            switch self {
            case .lf: "LF"
            case .crlf: "CRLF"
            case .cr: "CR"
            case .verticalTab: "VT"
            case .formFeed: "FF"
            case .nextLine: "NEL"
            case .lineSeparator: "LS"
            case .paragraphSeparator: "PS"
            case .none: String(localized: "无行尾换行")
            }
        }
    }

    struct Line: Equatable, Hashable, Sendable {
        enum Kind: Hashable, Sendable { case context, removal, insertion }
        let kind: Kind
        let text: String
        var ending: Ending? = nil
    }

    struct InlineChangedRanges: Equatable {
        let oldRange: Range<String.Index>?
        let newRange: Range<String.Index>?
    }

    private struct SourceLine: Equatable {
        let text: Substring
        let ending: Ending

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.ending == rhs.ending && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func change(_ kind: Line.Kind, comparedTo other: [Substring: Set<Ending>]) -> Line {
            let endingChanged = other[text]?.contains { $0 != ending } == true
            return Line(kind: kind, text: String(text), ending: endingChanged ? ending : nil)
        }
    }

    static func lines(for replacement: RuntimeToolApproval.Replacement) -> [Line]? {
        diffLines(
            oldText: replacement.oldText,
            newText: replacement.newText,
            maxBytes: RuntimeTool.EditArguments.maximumPreviewBytes,
            maxLinesPerSide: RuntimeTool.EditArguments.maximumPreviewLinesPerSide
        )
    }

    /// Computes complete unified diff lines for an approval request without silently dropping large changes.
    static func approvalLines(oldText: String?, newText: String) -> [Line] {
        guard let oldText else {
            return split(newText, maxLines: .max).map { Line(kind: .insertion, text: String($0.text), ending: nil) }
        }
        return diffLines(
            oldText: oldText,
            newText: newText,
            maxBytes: 4_194_304,
            maxLinesPerSide: 20_000,
            maxMiddleLinesPerSide: 4_000,
            fallbackMiddleOnOverflow: true
        ) ?? []
    }

    struct DiffSegment: Equatable, Hashable, Sendable, Identifiable {
        enum Content: Equatable, Hashable, Sendable {
            case lines([Line])
            case collapsedContext([Line])
        }

        let id: Int
        let content: Content

        var lines: [Line] {
            switch content {
            case .lines(let lines), .collapsedContext(let lines):
                return lines
            }
        }
    }

    /// Groups diff lines into change hunks with surrounding context and collapsible unchanged gaps.
    static func approvalSegments(from lines: [Line], contextLines: Int = 3, minimumCollapsedLines: Int = 4) -> [DiffSegment] {
        guard !lines.isEmpty else { return [] }
        let changedIndices = lines.indices.filter { lines[$0].kind != .context }
        guard !changedIndices.isEmpty else {
            if lines.count >= minimumCollapsedLines {
                return [DiffSegment(id: 0, content: .collapsedContext(lines))]
            }
            return [DiffSegment(id: 0, content: .lines(lines))]
        }

        var activeRanges: [Range<Int>] = []
        for index in changedIndices {
            let start = max(0, index - contextLines)
            let end = min(lines.count, index + contextLines + 1)
            if let last = activeRanges.last, start <= last.upperBound {
                activeRanges[activeRanges.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                activeRanges.append(start..<end)
            }
        }

        // Merge tiny collapsed gaps so we never show an expander for fewer than `minimumCollapsedLines`.
        var mergedRanges: [Range<Int>] = []
        for range in activeRanges {
            if let last = mergedRanges.last, range.lowerBound - last.upperBound < minimumCollapsedLines {
                mergedRanges[mergedRanges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                mergedRanges.append(range)
            }
        }

        var segments: [DiffSegment] = []
        var cursor = 0
        func appendCollapsed(_ slice: ArraySlice<Line>) {
            guard !slice.isEmpty else { return }
            if slice.count < minimumCollapsedLines {
                if case .lines(let previous)? = segments.last?.content {
                    segments[segments.count - 1] = DiffSegment(id: segments.count - 1, content: .lines(previous + slice))
                } else {
                    segments.append(DiffSegment(id: segments.count, content: .lines(Array(slice))))
                }
            } else {
                segments.append(DiffSegment(id: segments.count, content: .collapsedContext(Array(slice))))
            }
        }

        for range in mergedRanges {
            appendCollapsed(lines[cursor..<range.lowerBound])
            let activeSlice = Array(lines[range])
            if case .lines(let previous)? = segments.last?.content {
                segments[segments.count - 1] = DiffSegment(id: segments.count - 1, content: .lines(previous + activeSlice))
            } else {
                segments.append(DiffSegment(id: segments.count, content: .lines(activeSlice)))
            }
            cursor = range.upperBound
        }
        appendCollapsed(lines[cursor..<lines.endIndex])
        return segments
    }

    /// Computes minimal changed character ranges between a paired removal and insertion line.
    static func inlineChangedRanges(oldLine: String, newLine: String) -> InlineChangedRanges {
        guard oldLine != newLine, !oldLine.isEmpty, !newLine.isEmpty else {
            return InlineChangedRanges(oldRange: nil, newRange: nil)
        }
        var oldStart = oldLine.startIndex
        var newStart = newLine.startIndex
        while oldStart < oldLine.endIndex, newStart < newLine.endIndex, oldLine[oldStart] == newLine[newStart] {
            oldStart = oldLine.index(after: oldStart)
            newStart = newLine.index(after: newStart)
        }

        var oldEnd = oldLine.endIndex
        var newEnd = newLine.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let prevOld = oldLine.index(before: oldEnd)
            let prevNew = newLine.index(before: newEnd)
            guard oldLine[prevOld] == newLine[prevNew] else { break }
            oldEnd = prevOld
            newEnd = prevNew
        }

        // Skip inline highlights if the lines share neither prefix nor suffix (100% replaced).
        if oldStart == oldLine.startIndex && oldEnd == oldLine.endIndex &&
            newStart == newLine.startIndex && newEnd == newLine.endIndex {
            return InlineChangedRanges(oldRange: nil, newRange: nil)
        }

        let oldRange = oldStart < oldEnd ? oldStart..<oldEnd : nil
        let newRange = newStart < newEnd ? newStart..<newEnd : nil
        return InlineChangedRanges(oldRange: oldRange, newRange: newRange)
    }

    static func unifiedText(for lines: [Line]) -> String {
        lines.map { line in
            let prefix = switch line.kind {
            case .context: "  "
            case .removal: "- "
            case .insertion: "+ "
            }
            return prefix + line.text
        }.joined(separator: "\n")
    }

    private static func diffLines(
        oldText: String,
        newText: String,
        maxBytes: Int,
        maxLinesPerSide: Int,
        maxMiddleLinesPerSide: Int? = nil,
        fallbackMiddleOnOverflow: Bool = false
    ) -> [Line]? {
        if !fallbackMiddleOnOverflow {
            guard oldText.utf8.count + newText.utf8.count <= maxBytes else { return nil }
        }
        let maxLines = fallbackMiddleOnOverflow ? Int.max : maxLinesPerSide
        let old = split(oldText, maxLines: maxLines)
        let new = split(newText, maxLines: maxLines)
        if !fallbackMiddleOnOverflow {
            guard old.count <= maxLinesPerSide, new.count <= maxLinesPerSide else { return nil }
        }

        var prefixCount = 0
        let minCount = min(old.count, new.count)
        while prefixCount < minCount, old[prefixCount] == new[prefixCount] {
            prefixCount += 1
        }
        var suffixCount = 0
        while suffixCount < minCount - prefixCount,
              old[old.count - 1 - suffixCount] == new[new.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let oldMiddle = Array(old[prefixCount..<(old.count - suffixCount)])
        let newMiddle = Array(new[prefixCount..<(new.count - suffixCount)])
        let oldEndings = endingsByText(oldMiddle)
        let newEndings = endingsByText(newMiddle)

        var lines: [Line] = []
        lines.reserveCapacity(prefixCount + oldMiddle.count + newMiddle.count + suffixCount)
        for index in 0..<prefixCount {
            lines.append(.init(kind: .context, text: String(old[index].text)))
        }

        let middleCap = maxMiddleLinesPerSide ?? maxLinesPerSide
        let middleTooLarge: Bool
        if fallbackMiddleOnOverflow {
            let middleBytes = oldMiddle.reduce(0) { $0 + $1.text.utf8.count } + newMiddle.reduce(0) { $0 + $1.text.utf8.count }
            middleTooLarge = middleBytes > maxBytes
                || oldMiddle.count > middleCap
                || newMiddle.count > middleCap
        } else {
            middleTooLarge = oldText.utf8.count + newText.utf8.count > maxBytes
                || old.count > maxLinesPerSide
                || new.count > maxLinesPerSide
                || oldMiddle.count > middleCap
                || newMiddle.count > middleCap
        }

        if middleTooLarge {
            if !fallbackMiddleOnOverflow { return nil }
            for item in oldMiddle {
                lines.append(item.change(.removal, comparedTo: newEndings))
            }
            for item in newMiddle {
                lines.append(item.change(.insertion, comparedTo: oldEndings))
            }
        } else {
            var removals = Set<Int>()
            var insertions = Set<Int>()
            for change in newMiddle.difference(from: oldMiddle) {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset)
                }
            }

            var oldIndex = 0
            var newIndex = 0
            while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
                if removals.contains(oldIndex) {
                    lines.append(oldMiddle[oldIndex].change(.removal, comparedTo: newEndings))
                    oldIndex += 1
                } else if insertions.contains(newIndex) {
                    lines.append(newMiddle[newIndex].change(.insertion, comparedTo: oldEndings))
                    newIndex += 1
                } else {
                    lines.append(.init(kind: .context, text: String(oldMiddle[oldIndex].text)))
                    oldIndex += 1
                    newIndex += 1
                }
            }
        }

        for index in (old.count - suffixCount)..<old.count {
            lines.append(.init(kind: .context, text: String(old[index].text)))
        }
        return lines
    }

    private static func endingsByText(_ lines: [SourceLine]) -> [Substring: Set<Ending>] {
        Dictionary(grouping: lines, by: \.text).mapValues { Set($0.map(\.ending)) }
    }

    private static func split(_ text: String, maxLines: Int) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            let ending = Ending(rawValue: String(text[index])) ?? .none
            lines.append(.init(text: text[start..<index], ending: ending))
            if lines.count > maxLines { return lines }
            start = text.index(after: index)
        }
        if start < text.endIndex { lines.append(.init(text: text[start...], ending: .none)) }
        return lines
    }
}

struct ToolOutputPresentation {
    let preview: String
    let hasMore: Bool
    let diagnostic: String?

    init(output: String, failed: Bool) {
        let prefix = output.prefix(4096)
        let lines = prefix.split(maxSplits: 8, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let lineEnd = lines.count > 8 ? lines[7].endIndex : prefix.endIndex
        preview = String(output[..<lineEnd])
        hasMore = lineEnd < output.endIndex

        diagnostic = failed ? Self.firstDiagnostic(in: output) : nil
    }

    private static func firstDiagnostic(in output: String) -> String? {
        var diagnostic: String?
        output.enumerateLines { line, stop in
            let text = line.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            if lower.hasPrefix("error:") || lower.hasPrefix("fatal:") || lower.hasPrefix("fatal error:") ||
                lower.hasPrefix("[error]") || lower.contains(": error:") || lower.contains(": fatal error:") ||
                text.hasPrefix("Command exited with code ") || text.hasPrefix("Command timed out after ") ||
                text == "Command terminated without an exit code" || text == "Command aborted" {
                diagnostic = String(text.prefix(512))
                stop = true
            }
        }
        return diagnostic
    }
}
