import Foundation
import AgentRuntimeCore
import OrchestrationCore

enum ToolCallKind {
    case command, edit, read, search, list, find, write, other

    init(name: String) {
        switch name {
        case "bash", "pikachu_bash": self = .command
        case "edit", "pikachu_edit": self = .edit
        case "read", "pikachu_read": self = .read
        case "grep", "pikachu_grep": self = .search
        case "ls", "pikachu_ls": self = .list
        case "find", "pikachu_find": self = .find
        case "write", "pikachu_write": self = .write
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
        let operation = operationLabel.map { String(localized: $0) } ?? summary.name
        let status = summary.state == .completed ? nil : String(localized: summary.state.statusLabel)
        let description = [operation, object].filter { !$0.isEmpty } + qualifiers.map { String(localized: $0) }
        return (description + [status].compactMap { $0 })
            .joined(separator: String(localized: "，"))
    }
}

enum ToolEditDiff {
    enum Ending: String {
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

    struct Line: Equatable {
        enum Kind { case context, removal, insertion }
        let kind: Kind
        let text: String
        var ending: Ending? = nil
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
        guard replacement.oldText.utf8.count + replacement.newText.utf8.count <= RuntimeTool.EditArguments.maximumPreviewBytes else { return nil }
        let old = split(replacement.oldText)
        let new = split(replacement.newText)
        let lineLimit = RuntimeTool.EditArguments.maximumPreviewLinesPerSide
        guard old.count <= lineLimit, new.count <= lineLimit else { return nil }
        let oldEndings = endingsByText(old)
        let newEndings = endingsByText(new)

        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var oldIndex = 0
        var newIndex = 0
        var lines: [Line] = []
        while oldIndex < old.count || newIndex < new.count {
            if removals.contains(oldIndex) {
                lines.append(old[oldIndex].change(.removal, comparedTo: newEndings))
                oldIndex += 1
            } else if insertions.contains(newIndex) {
                lines.append(new[newIndex].change(.insertion, comparedTo: oldEndings))
                newIndex += 1
            } else {
                lines.append(.init(kind: .context, text: String(old[oldIndex].text)))
                oldIndex += 1
                newIndex += 1
            }
        }
        return lines
    }

    private static func endingsByText(_ lines: [SourceLine]) -> [Substring: Set<Ending>] {
        Dictionary(grouping: lines, by: \.text).mapValues { Set($0.map(\.ending)) }
    }

    private static func split(_ text: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            let ending = Ending(rawValue: String(text[index])) ?? .none
            lines.append(.init(text: text[start..<index], ending: ending))
            if lines.count > RuntimeTool.EditArguments.maximumPreviewLinesPerSide { return lines }
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
