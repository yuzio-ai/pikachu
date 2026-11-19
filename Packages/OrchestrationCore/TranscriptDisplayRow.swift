@MainActor public enum TranscriptDisplayRow {
    case item(TranscriptItem)
    case completedTools([TranscriptItem])

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .completedTools(let items): items[0].id
        }
    }

    public var isTool: Bool {
        switch self {
        case .item(let item): item.kind == .tool
        case .completedTools: true
        }
    }

    public func hasSameItems(as other: Self) -> Bool {
        switch (self, other) {
        case (.item(let item), .item(let otherItem)):
            item === otherItem
        case (.completedTools(let items), .completedTools(let otherItems)):
            items.count == otherItems.count && zip(items, otherItems).allSatisfy { $0 === $1 }
        default:
            false
        }
    }

    public func contains(_ itemID: String) -> Bool {
        switch self {
        case .item(let item): item.id == itemID
        case .completedTools(let items): items.contains { $0.id == itemID }
        }
    }

    public static func grouped(_ items: [TranscriptItem]) -> [Self] {
        var rows: [Self] = []
        var completed: [TranscriptItem] = []

        func flushCompleted() {
            if completed.count > 1 {
                rows.append(.completedTools(completed))
            } else if let item = completed.first {
                rows.append(.item(item))
            }
            completed.removeAll()
        }

        for item in items {
            if item.kind == .tool && item.isCompletedTool {
                if let last = completed.last, last.turn !== item.turn {
                    flushCompleted()
                }
                completed.append(item)
            } else {
                flushCompleted()
                rows.append(.item(item))
            }
        }
        flushCompleted()
        return rows
    }

    public static func turnHeaders(for rows: [Self]) -> [Int: TurnRecord] {
        var headers: [Int: TurnRecord] = [:]
        var currentTurn: TurnRecord?
        var firstRowIndex: Int?
        var firstAssistantIndex: Int?

        func flushSegment() {
            guard let turn = currentTurn, let target = firstAssistantIndex ?? firstRowIndex else { return }
            headers[target] = turn
        }

        for (index, row) in rows.enumerated() {
            let rowTurn: TurnRecord?
            let isAssistant: Bool
            switch row {
            case .item(let item):
                rowTurn = (item.kind == .assistant || item.kind == .tool) ? item.turn : nil
                isAssistant = item.kind == .assistant
            case .completedTools(let items):
                rowTurn = items.first?.turn
                isAssistant = false
            }

            if rowTurn !== currentTurn {
                flushSegment()
                currentTurn = rowTurn
                firstRowIndex = rowTurn == nil ? nil : index
                firstAssistantIndex = (rowTurn != nil && isAssistant) ? index : nil
            } else if currentTurn != nil && isAssistant && firstAssistantIndex == nil {
                firstAssistantIndex = index
            }
        }
        flushSegment()
        return headers
    }
}
