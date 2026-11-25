import Foundation
import AgentRuntimeCore

public enum SessionHistoryCoverage: String, Codable, Sendable {
    case available, partial, unavailable
}

public struct SessionHandoffPreview: Sendable {
    public let sourceAgent: String
    public let directory: String
    public let coverage: SessionHistoryCoverage
    public let draft: SessionHandoffDraft
    public var context: String { draft.context }
    public let excerpts: [Excerpt]
    let source: UUID
    let history: SessionHistorySnapshot?
    let token: UUID

    public struct Excerpt: Identifiable, Sendable {
        public let id: String
        public let text: String
        public let isUser: Bool
    }

}

public struct SessionHandoffFile: Codable, Sendable, Equatable, Identifiable {
    public struct Change: Codable, Sendable, Equatable {
        public let segmentID: UUID
        public let turnID: UUID
        public let file: TurnFileChanges.File
    }

    public let path: String
    public let changes: [Change]
    public let kind: TurnFileChanges.File.Kind
    public let previousPaths: [String]
    public let added: Int?
    public let deleted: Int?
    public var id: String { path }
    public var pathBase: String? {
        // Earlier names may have different bases. Repeated entries for this name must agree.
        guard let file = changes.last?.file, file.path == path, let base = file.pathBase,
              changes.allSatisfy({ $0.file.path != path || $0.file.pathBase == base }) else { return nil }
        return base
    }

    init(path: String, changes: [Change]) {
        self.path = path
        self.changes = changes
        kind = changes.last?.file.kind ?? .modified
        var seen = Set<String>()
        previousPaths = changes.compactMap(\.file.previousPath).filter { $0 != path && seen.insert($0).inserted }
        added = Self.total(changes, \.file.added)
        deleted = Self.total(changes, \.file.deleted)
    }

    private static func total(_ changes: [Change], _ value: KeyPath<Change, Int?>) -> Int? {
        var count = 0
        for change in changes {
            guard let lines = change[keyPath: value], lines >= 0 else { return nil }
            let (sum, overflow) = count.addingReportingOverflow(lines)
            guard !overflow else { return nil }
            count = sum
        }
        return count
    }

    var contextLine: String {
        let paths = (previousPaths + [path]).map(\.debugDescription).joined(separator: " → ")
        let operations = changes.reduce(into: [TurnFileChanges.File.Kind]()) { kinds, change in
            if kinds.last != change.file.kind { kinds.append(change.file.kind) }
        }.map(\.rawValue).joined(separator: " → ")
        let counts = [added.map { "+\($0)" }, deleted.map { "−\($0)" }].compactMap { $0 }.joined(separator: " ")
        return counts.isEmpty ? "- \(paths) [\(operations)]" : "- \(paths) [\(operations)] \(counts)"
    }
}

public struct SessionHandoffDraft: Codable, Sendable, Equatable {
    public var userRequest: String
    public var notes: String
    public var excludedPaths: Set<String> = []
    public var omitsHistory = false
    public let files: [SessionHandoffFile]
    public let hasIncompleteFileHistory: Bool
    public let segmentCount: Int

    public var selectedFiles: [SessionHandoffFile] {
        omitsHistory ? [] : files.filter { !excludedPaths.contains($0.id) }
    }

    public var textContext: String {
        guard !omitsHistory else { return "" }
        var sections: [String] = []
        if !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(String(localized: "最近的用户请求\n\(userRequest)", bundle: #bundle))
        }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(notes) }
        return sections.joined(separator: "\n\n")
    }

    public var context: String {
        let text = textContext
        let files = selectedFiles
        guard !files.isEmpty else { return text }
        let list = files.map(\.contextLine).joined(separator: "\n")
        let fileContext = String(localized: "文件改动\n\(list)", bundle: #bundle)
        return text.isEmpty ? fileContext : text + "\n\n" + fileContext
    }
}

struct SessionHandoffFileHistory {
    let id: UUID
    let coverage: SessionHistoryCoverage
    let turns: [RecordedTurnRecord]

    static func files(in segments: [Self]) -> [SessionHandoffFile] {
        var byPath: [String: [(order: Int, change: SessionHandoffFile.Change)]] = [:]
        var order = 0
        for segment in segments {
            for turn in segment.turns {
                let files = turn.fileChanges?.files ?? []
                // Detach rename sources before applying destinations, including swaps.
                var moved: [String: [(order: Int, change: SessionHandoffFile.Change)]] = [:]
                for file in files where file.kind == .renamed {
                    if let previous = file.previousPath, previous != file.path, moved[previous] == nil,
                       let history = byPath.removeValue(forKey: previous) {
                        moved[previous] = history
                    }
                }
                for file in files {
                    if file.kind == .renamed, let previous = file.previousPath,
                       let changes = moved.removeValue(forKey: previous) {
                        byPath[file.path, default: []].append(contentsOf: changes)
                    }
                    let change = SessionHandoffFile.Change(segmentID: segment.id, turnID: turn.id, file: file)
                    byPath[file.path, default: []].append((order, change))
                    order += 1
                }
            }
        }
        return byPath.keys.sorted().map { path in
            SessionHandoffFile(path: path, changes: (byPath[path] ?? []).sorted { $0.order < $1.order }.map(\.change))
        }
    }
}

public struct SessionHandoff: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let source: UUID
    public let sourceAgent: String
    public let targetAgent: String
    public let coverage: SessionHistoryCoverage
    public internal(set) var context: String
    public internal(set) var draft: SessionHandoffDraft?
    public internal(set) var sentTextContext: String?
    public internal(set) var targetModel: SessionTurnModel?
    public internal(set) var lastSubmissionRejected: Bool?
    public internal(set) var lastRejectedSubmissionID: UUID?
    public internal(set) var firstSubmissionID: UUID?
    public internal(set) var delivered = false
}

struct FrozenSessionSegment: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let runtimeID: String
    let runtimeSessionID: String?
    let file: URL?
    let modelName: String?
    let selection: RuntimeSelection?
    let modeID: String?
    let coverage: SessionHistoryCoverage
    let incomingHandoff: SessionHandoff?
}

/// A read-only copy of the visible segment. It excludes live requests and transient reasoning.
public struct SessionHistorySnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        let history: HistoryItem
        let files: [URL]
        let turnID: String?
        var modelChange: SessionModelChange?
        var submissionID: UUID?
    }

    struct Turn: Codable, Sendable, Equatable {
        let displayID: String
        let record: RecordedTurnRecord
    }

    struct Start: Codable, Sendable, Equatable {
        let turnID: String
        let precedingItemID: String?
    }

    let coverage: SessionHistoryCoverage
    let items: [Item]
    let turns: [Turn]
    let starts: [Start]?
    // Earlier snapshots kept only captured changes here. Keep the visible
    // turns as well so missing capture and a known empty change set stay distinct.
    var fileChangeRecords: [RecordedTurnRecord]? = nil

    var fileRecords: [RecordedTurnRecord] {
        fileRecords(including: [])
    }

    func fileRecords(including stored: [RecordedTurnRecord]) -> [RecordedTurnRecord] {
        var records: [UUID: RecordedTurnRecord] = [:]
        var order: [UUID] = []
        for record in stored + (fileChangeRecords ?? []) + turns.map(\.record) {
            if let existing = records[record.id] {
                if existing.fileChanges == nil, record.fileChanges != nil { records[record.id] = record }
            } else {
                records[record.id] = record
                order.append(record.id)
            }
        }
        return order.compactMap { records[$0] }.sorted {
            ($0.startedAt ?? $0.endedAt ?? .distantPast) < ($1.startedAt ?? $1.endedAt ?? .distantPast)
        }
    }

    @MainActor init(transcript: [TranscriptItem], turnStarts: [TranscriptTurnStart] = [], coverage: SessionHistoryCoverage) {
        self.coverage = coverage
        var turns: [String: Turn] = [:]
        func recordTurn(_ turn: TurnRecord) {
            guard turns[turn.timelineID] == nil else { return }
            let record = RecordedTurnRecord(id: turn.id, startedAt: turn.startedAt, endedAt: turn.endedAt,
                                            durationSeconds: turn.durationSeconds, status: turn.status,
                                            fileChanges: turn.fileChanges)
            turns[turn.timelineID] = Turn(displayID: turn.timelineID, record: record)
        }
        items = transcript.compactMap { row in
            guard row.delivery != .rejected, row.expiredInteraction == nil,
                  row.kind != .assistant || row.hasVisibleText else { return nil }
            let kind: HistoryItemKind = switch row.kind {
            case .user: .user
            case .assistant: .assistant
            case .tool: .tool
            case .notice: .notice
            }
            if let turn = row.turn { recordTurn(turn) }
            var tool = row.tool
            tool?.outputImage = nil
            let item = HistoryItem(id: row.timelineID, kind: kind, text: row.kind == .user ? row.editableText : row.text,
                                   tool: tool, sentAt: row.sentAt, messageTimestampMs: row.messageTimestampMs)
            return Item(history: item, files: row.editableFiles, turnID: row.turn?.timelineID,
                        modelChange: row.modelChange, submissionID: row.submissionID)
        }
        let timelineIDs = Dictionary(transcript.map { ($0.id, $0.timelineID) }, uniquingKeysWith: { first, _ in first })
        starts = turnStarts.map { start in
            recordTurn(start.turn)
            return Start(turnID: start.turn.timelineID, precedingItemID: start.precedingItemID.flatMap { timelineIDs[$0] })
        }
        self.turns = turns.values.sorted { $0.displayID < $1.displayID }
    }

    @MainActor func timeline() -> (items: [TranscriptItem], rows: [TranscriptDisplayRow]) {
        let turnsByID = Dictionary(turns.map { turn in
            let record = turn.record
            return (turn.displayID, TurnRecord(id: record.id, status: record.status, startedAt: record.startedAt,
                                              endedAt: record.endedAt, durationSeconds: record.durationSeconds,
                                              displayID: turn.displayID, fileChanges: record.fileChanges))
        }, uniquingKeysWith: { first, _ in first })
        let items = self.items.map { item in
            let history = item.history
            let kind: TranscriptKind = switch history.kind {
            case .user: .user
            case .assistant: .assistant
            case .tool: .tool
            case .notice: .notice
            }
            let row = TranscriptItem(id: history.id, kind: kind, text: history.text, tool: history.tool,
                                     sentAt: history.sentAt, messageTimestampMs: history.messageTimestampMs,
                                     turn: item.turnID.flatMap { turnsByID[$0] }, attachedFiles: item.files)
            row.modelChange = item.modelChange
            row.recordedSubmissionID = item.submissionID
            return row
        }
        let turnStarts = (starts ?? []).compactMap { start in
            turnsByID[start.turnID].map { TranscriptTurnStart(turn: $0, precedingItemID: start.precedingItemID) }
        }
        return (items, TranscriptDisplayRow.project(items, turnStarts: turnStarts))
    }

    var handoffExcerpts: [SessionHandoffPreview.Excerpt] {
        let recent = items.lazy.filter { $0.history.kind == .user || $0.history.kind == .assistant }.suffix(12)
        return recent.compactMap { item in
            guard !item.history.text.isEmpty else { return nil }
            return .init(id: item.history.id, text: item.history.text, isUser: item.history.kind == .user)
        }
    }

    func preview(source: UUID, agent: String, directory: String, token: UUID, retainingHistory: Bool,
                 fileHistory: [SessionHandoffFileHistory]) -> SessionHandoffPreview {
        let messageItems = items.lazy.filter { $0.history.kind == .user || $0.history.kind == .assistant }
        let goal = messageItems.last { $0.history.kind == .user && !$0.history.text.isEmpty }?.history.text
        let result = messageItems.last { $0.history.kind == .assistant && !$0.history.text.isEmpty }?.history.text
        let notes = result.map { String(localized: "最近的智能体回复\n\($0)", bundle: #bundle) } ?? ""
        let draft = SessionHandoffDraft(userRequest: goal ?? "", notes: notes,
                                       files: SessionHandoffFileHistory.files(in: fileHistory),
                                       hasIncompleteFileHistory: fileHistory.contains {
                                           $0.coverage != .available || $0.turns.isEmpty || $0.turns.contains { $0.fileChanges == nil }
                                       },
                                       segmentCount: fileHistory.count { $0.turns.contains { $0.fileChanges != nil } })
        return SessionHandoffPreview(sourceAgent: agent, directory: directory, coverage: coverage,
                                     draft: draft, excerpts: handoffExcerpts,
                                     source: source, history: retainingHistory ? self : nil, token: token)
    }
}
