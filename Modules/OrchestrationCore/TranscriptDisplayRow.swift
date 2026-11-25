@MainActor public struct TranscriptTurnStart {
    let turn: TurnRecord
    let precedingItemID: String?
}

@MainActor public enum TranscriptDisplayRow {
    case item(TranscriptItem)
    case modelChange(TranscriptItem, SessionModelChange)
    case turnHeader(TurnRecord)
    case turnChanges(TurnRecord)
    case thinking(TurnRecord)
    case toolCalls([TranscriptItem]) // Consecutive tool calls in the same turn.

    public var id: String {
        switch self {
        case .item(let item): item.timelineID
        case .modelChange(let item, _): "model-change:\(item.timelineID)"
        case .turnHeader(let turn): "turn-header:\(turn.timelineID)"
        case .turnChanges(let turn): "turn-changes:\(turn.timelineID)"
        case .thinking(let turn): "thinking:\(turn.timelineID)"
        case .toolCalls(let items): items[0].timelineID
        }
    }

    public func hasSameItems(as other: Self) -> Bool {
        switch (self, other) {
        case (.item(let item), .item(let otherItem)):
            item === otherItem
        case (.modelChange(let item, let change), .modelChange(let otherItem, let otherChange)):
            item === otherItem && change == otherChange
        case (.turnHeader(let turn), .turnHeader(let otherTurn)),
             (.turnChanges(let turn), .turnChanges(let otherTurn)),
             (.thinking(let turn), .thinking(let otherTurn)):
            turn === otherTurn
        case (.toolCalls(let items), .toolCalls(let otherItems)):
            items.count == otherItems.count && zip(items, otherItems).allSatisfy { $0 === $1 }
        default:
            false
        }
    }

    public func contains(_ itemID: String) -> Bool {
        if case .toolCalls(let items) = self { return items.contains { $0.timelineID == itemID } }
        return id == itemID
    }

    public static func placingHandoff(_ marker: TranscriptItem?, in rows: [Self]) -> [Self] {
        guard let marker else { return rows }
        let users = rows.indices.compactMap { index -> (Int, TranscriptItem)? in
            guard case .item(let item) = rows[index], item.kind == .user, item.delivery != .rejected else { return nil }
            return (index, item)
        }
        let anchored = marker.handoff?.firstSubmissionID.flatMap { id in
            users.first { $0.1.submissionID == id }?.0
        }
        var placed = rows
        placed.insert(.item(marker), at: anchored ?? users.first?.0 ?? rows.startIndex)
        return placed
    }

    public static func project(_ items: [TranscriptItem], turnStarts: [TranscriptTurnStart] = [],
                               showsThinking: Bool = false) -> [Self] {
        let startsByPredecessor = Dictionary(grouping: turnStarts, by: \.precedingItemID)
        var lastItems: [String: String] = [:]
        for item in items {
            if let turn = item.turn { lastItems[turn.displayID] = item.id }
        }
        var rows: [Self] = []
        var tools: [TranscriptItem] = []
        var shownTurns = Set<String>()

        func flushTools() {
            guard !tools.isEmpty else { return }
            rows.append(.toolCalls(tools))
            tools = []
        }

        func showHeader(_ turn: TurnRecord) {
            guard shownTurns.insert(turn.displayID).inserted else { return }
            flushTools()
            rows.append(.turnHeader(turn))
            if lastItems[turn.displayID] == nil { showChanges(turn) }
        }

        func showChanges(_ turn: TurnRecord) {
            guard let changes = turn.fileChanges, !changes.files.isEmpty, turn.status != .running else { return }
            flushTools()
            rows.append(.turnChanges(turn))
        }

        for start in startsByPredecessor[nil] ?? [] { showHeader(start.turn) }
        for item in items {
            if item.kind != .user, let turn = item.turn { showHeader(turn) }
            if item.kind == .tool {
                if let last = tools.last, last.turn !== item.turn { flushTools() }
                tools.append(item)
            } else if item.kind != .assistant || item.hasVisibleText {
                flushTools()
                if let change = item.modelChange { rows.append(.modelChange(item, change)) }
                rows.append(.item(item))
            }
            if item.kind == .user, let turn = item.turn { showHeader(turn) }
            if let turn = item.turn, lastItems[turn.displayID] == item.id { showChanges(turn) }
            if let starts = startsByPredecessor[item.id] {
                for start in starts { showHeader(start.turn) }
            }
        }
        // An empty assistant placeholder can disappear before the next turn emits anything.
        for start in turnStarts { showHeader(start.turn) }
        flushTools()
        if showsThinking {
            switch rows.last {
            case .toolCalls(let tools):
                if let turn = tools.last?.turn, turn.status == .running,
                   !turn.thoughtText.isEmpty ||
                       !items.contains(where: { $0.turn === turn && $0.kind == .tool && $0.toolSummary?.state == .running }) {
                    rows.append(.thinking(turn))
                }
            case .turnHeader(let turn):
                if turn.status == .running, !turn.thoughtText.isEmpty {
                    rows.append(.thinking(turn))
                }
            default:
                break
            }
        }
        return rows
    }
}
