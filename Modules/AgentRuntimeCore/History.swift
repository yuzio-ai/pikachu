import Foundation

public struct RuntimeModel: Identifiable, Codable, Sendable, Equatable {
    public var id: String { provider + "/" + modelID }
    public let provider: String
    public let modelID: String
    public let name: String
    public init(provider: String, modelID: String, name: String) { self.provider = provider; self.modelID = modelID; self.name = name }
}
public struct RuntimeSelection: Codable, Sendable, Equatable {
    public var provider: String
    public var modelID: String
    public var thinking: String?
    public init(provider: String, modelID: String, thinking: String? = nil) { self.provider = provider; self.modelID = modelID; self.thinking = thinking }
}
public struct RuntimeConfigurationOptions: Sendable {
    public var models: [RuntimeModel]
    public var thinkingLevels: [String]
    public init(models: [RuntimeModel], thinkingLevels: [String]) { self.models = models; self.thinkingLevels = thinkingLevels }
}
public enum HistoryItemKind: String, Sendable { case user, assistant, tool, notice }
public struct HistoryItem: Sendable, Identifiable {
    public let id: String
    public let kind: HistoryItemKind
    public var text: String
    public var tool: RuntimeTool?
    public var sentAt: Date?
    public var messageTimestampMs: Int64?
    public init(id: String, kind: HistoryItemKind, text: String = "", tool: RuntimeTool? = nil, sentAt: Date? = nil, messageTimestampMs: Int64? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.sentAt = sentAt; self.messageTimestampMs = messageTimestampMs
    }
}
public struct HistoryTurnInfo: Sendable, Equatable {
    public let id: String
    public let itemIDs: [String]
    public let firstUserItemID: String?
    public let firstUserTimestampMs: Int64?
    public let firstAssistantTimestampMs: Int64?
    public let lastAssistantTimestampMs: Int64?
    public let firstToolCallID: String?
    public let endedAt: Date?
    public let durationSeconds: TimeInterval?
    public let status: TurnStatus
    public init(id: String, itemIDs: [String], firstUserItemID: String? = nil,
                firstUserTimestampMs: Int64? = nil, firstAssistantTimestampMs: Int64? = nil, lastAssistantTimestampMs: Int64? = nil,
                firstToolCallID: String? = nil, endedAt: Date? = nil, durationSeconds: TimeInterval? = nil, status: TurnStatus) {
        self.id = id; self.itemIDs = itemIDs; self.firstUserItemID = firstUserItemID; self.firstUserTimestampMs = firstUserTimestampMs
        self.firstAssistantTimestampMs = firstAssistantTimestampMs; self.firstToolCallID = firstToolCallID
        self.lastAssistantTimestampMs = lastAssistantTimestampMs ?? firstAssistantTimestampMs
        self.endedAt = endedAt; self.durationSeconds = durationSeconds; self.status = status
    }
}
public struct RuntimeHistory: Sendable {
    public let sessionID: String
    public let file: URL
    public let cwd: String
    public let title: String
    public let items: [HistoryItem]
    public let turns: [HistoryTurnInfo]
    public let incompleteTail: Bool
    public let warnings: [String]
    public let selection: RuntimeSelection?
    public let usage: RuntimeUsage?
    public let activityAt: Date?
    public let lastObservedModel: RuntimeSelection?
    public let needsAttention: Bool
    public init(sessionID: String, file: URL, cwd: String, title: String, items: [HistoryItem], turns: [HistoryTurnInfo] = [], incompleteTail: Bool, warnings: [String], selection: RuntimeSelection?, usage: RuntimeUsage? = nil,
                activityAt: Date? = nil, lastObservedModel: RuntimeSelection? = nil, needsAttention: Bool = false) {
        self.sessionID = sessionID; self.file = file; self.cwd = cwd; self.title = title; self.items = items; self.turns = turns
        self.incompleteTail = incompleteTail; self.warnings = warnings; self.selection = selection
        self.usage = usage
        self.activityAt = activityAt; self.lastObservedModel = lastObservedModel
        self.needsAttention = needsAttention || incompleteTail
    }
}

public struct RuntimeHistorySummary: Sendable {
    public let sessionID: String
    public let file: URL
    public let cwd: String
    public let title: String
    public let activityAt: Date?
    public let model: RuntimeSelection?
    public let needsAttention: Bool

    public init(_ history: RuntimeHistory) {
        sessionID = history.sessionID
        file = history.file
        cwd = history.cwd
        title = history.title
        activityAt = history.activityAt
        model = history.lastObservedModel ?? history.selection
        needsAttention = history.needsAttention
    }
}
public struct HistoryDiscovery: Sendable {
    public var sessions: [RuntimeHistory]
    public var issues: [String]
    public init(sessions: [RuntimeHistory], issues: [String]) { self.sessions = sessions; self.issues = issues }
}
public protocol RuntimeHistoryReader: Sendable {
    func read(_ file: URL) async throws -> RuntimeHistory
    func discover(locations: [String]) async throws -> HistoryDiscovery
    func discoverSummaries(locations: [String]) async throws -> (sessions: [RuntimeHistorySummary], issues: [String])
}

public extension RuntimeHistoryReader {
    func discoverSummaries(locations: [String]) async throws -> (sessions: [RuntimeHistorySummary], issues: [String]) {
        let discovery = try await discover(locations: locations)
        return (discovery.sessions.map(RuntimeHistorySummary.init), discovery.issues)
    }
}
