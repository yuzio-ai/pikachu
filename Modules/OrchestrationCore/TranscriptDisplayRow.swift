@MainActor public struct TranscriptTurnStart {
    let turn: TurnRecord
    let precedingItemID: String?
}

@MainActor public enum TranscriptDisplayRow {
    case item(TranscriptItem)
    case turnHeader(TurnRecord)
    case turnChanges(TurnRecord)
    case runningTool(TranscriptItem)
    case toolCalls([TranscriptItem]) // Consecutive tool calls that have stopped running.

    public var id: String {
        switch self {
        case .item(let item), .runningTool(let item): item.id
        case .turnHeader(let turn): "turn-header:\(turn.displayID)"
        case .turnChanges(let turn): "turn-changes:\(turn.displayID)"
        case .toolCalls(let items): items[0].id
        }
    }

    public func hasSameItems(as other: Self) -> Bool {
        switch (self, other) {
        case (.item(let item), .item(let otherItem)), (.runningTool(let item), .runningTool(let otherItem)):
            item === otherItem
        case (.turnHeader(let turn), .turnHeader(let otherTurn)),
             (.turnChanges(let turn), .turnChanges(let otherTurn)):
            turn === otherTurn
        case (.toolCalls(let items), .toolCalls(let otherItems)):
            items.count == otherItems.count && zip(items, otherItems).allSatisfy { $0 === $1 }
        default:
            false
        }
    }

    public func contains(_ itemID: String) -> Bool {
        if case .toolCalls(let items) = self { return items.contains { $0.id == itemID } }
        return id == itemID
    }

    public static func project(_ items: [TranscriptItem], turnStarts: [TranscriptTurnStart] = []) -> [Self] {
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
                if item.toolSummary?.state == .running {
                    flushTools()
                    rows.append(.runningTool(item))
                } else {
                    if let last = tools.last, last.turn !== item.turn { flushTools() }
                    tools.append(item)
                }
            } else if item.kind != .assistant || item.hasVisibleText {
                flushTools()
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
        return rows
    }
}
