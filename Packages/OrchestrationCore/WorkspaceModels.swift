import Foundation
import AgentRuntimeCore

public struct ProjectRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var previousPaths: [String]
    public var lastViewed: Date
    public init(id: UUID = UUID(), path: String) {
        self.id = id; self.path = path; name = URL(fileURLWithPath: path).lastPathComponent
        previousPaths = []; lastViewed = Date()
    }
}
public struct SubmissionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var mode: SendMode
    public var files: [URL]?
    public var delivery: DeliveryState
    public var needsReview: Bool
    public var acknowledged: Bool
    public var sentAt: Date?
    public init(_ prompt: UserPrompt, sentAt: Date? = nil) {
        id = prompt.id; text = prompt.text; mode = prompt.mode; files = prompt.files.isEmpty ? nil : prompt.files
        delivery = .pending; needsReview = false; acknowledged = false; self.sentAt = sentAt
    }
}
public struct RecordedTurnRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var anchorAssistantTimestampMs: Int64?
    public var endAssistantTimestampMs: Int64?
    public var anchorToolCallID: String?
    public var anchorUserTimestampMs: Int64?
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: TimeInterval?
    public var status: TurnStatus
    public init(id: UUID = UUID(), anchorAssistantTimestampMs: Int64? = nil, endAssistantTimestampMs: Int64? = nil,
                anchorToolCallID: String? = nil, anchorUserTimestampMs: Int64? = nil,
                startedAt: Date? = nil, endedAt: Date? = nil,
                durationSeconds: TimeInterval? = nil, status: TurnStatus) {
        self.id = id
        self.anchorAssistantTimestampMs = anchorAssistantTimestampMs
        self.endAssistantTimestampMs = endAssistantTimestampMs
        self.anchorToolCallID = anchorToolCallID
        self.anchorUserTimestampMs = anchorUserTimestampMs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.status = status
    }
}
public struct RecordedMessageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var files: [URL]?
    public var sentAt: Date?
    public var messageTimestampMs: Int64?
    public init(id: UUID, text: String, files: [URL]? = nil, sentAt: Date? = nil, messageTimestampMs: Int64? = nil) {
        self.id = id
        self.text = text
        self.files = files
        self.sentAt = sentAt
        self.messageTimestampMs = messageTimestampMs
    }
}
public enum SessionProcessingStatus: String, Codable, Sendable, CaseIterable {
    case open, settled
}

public struct SessionActivity: Codable, Sendable, Equatable {
    public let date: Date
    public let isEstimate: Bool

    init(date: Date = Date(), isEstimate: Bool = false) {
        self.date = date
        self.isEstimate = isEstimate
    }
}

public enum SessionReminderState: Equatable, Sendable {
    case none, snoozed(until: Date), due
}

public struct SessionReference: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var runtimeID: String
    public var runtimeSessionID: String?
    public var file: URL?
    public var historyConfirmed: Bool? = false
    public var title: String
    public var lastViewed: Date
    public var draft: String
    public var draftFiles: [URL]?
    public var mode: SendMode
    public var agentMode: AgentMode?
    public var recovered: [PendingPrompt]
    public var submissions: [SubmissionRecord]
    public var wasExecuting: Bool
    public var selection: RuntimeSelection?
    public var pendingSelection: RuntimeSelection?
    public var pendingModelName: String?
    public var modelName: String?
    // Optional fields let version 1 workspaces decode before migration.
    var processingStatus: SessionProcessingStatus?
    var sidebarActivity: SessionActivity?
    var reminderDueAt: Date?
    public var recordedTurns: [RecordedTurnRecord]?
    public var recordedMessages: [RecordedMessageRecord]?
    public internal(set) var historicalModel: RuntimeSelection?
    public var sidebarStatus: SessionProcessingStatus { processingStatus ?? .open }
    public var activity: SessionActivity { sidebarActivity ?? .init(date: lastViewed, isEstimate: true) }
    public func reminderState(at date: Date) -> SessionReminderState {
        guard let reminderDueAt, sidebarStatus == .open else { return .none }
        return reminderDueAt > date ? .snoozed(until: reminderDueAt) : .due
    }
    public var executionMode: AgentMode { agentMode ?? .automatic }
    public init(id: UUID = UUID(), projectID: UUID, title: String = "新会话") {
        self.id = id; self.projectID = projectID; runtimeID = "pi"; self.title = title; lastViewed = Date()
        draft = ""; mode = .steer; recovered = []; submissions = []; wasExecuting = false
    }
}
public struct WorkspacePreferences: Codable, Sendable, Equatable {
    public var piPath: String
    public var nodeDirectory: String
    public var proxy: String
    public var extensionPaths: [String]?
    public init(piPath: String = "", nodeDirectory: String = "", proxy: String = "", extensionPaths: [String] = []) {
        self.piPath = piPath; self.nodeDirectory = nodeDirectory
        self.extensionPaths = extensionPaths
        // Proxy credentials are configuration secrets, not workspace metadata.
        let parts = URLComponents(string: proxy)
        self.proxy = parts?.user == nil && parts?.password == nil ? proxy : ""
    }
}
public struct WorkspaceSnapshot: Codable, Sendable {
    public var version = 1
    public var revision: Int64 = 0
    public var projects: [ProjectRecord] = []
    public var sessions: [SessionReference] = []
    public var selectedSessionID: UUID?
    public var preferences = WorkspacePreferences()
    public init() {}
}
public protocol WorkspaceStore: Sendable {
    func load() async throws -> WorkspaceSnapshot
    func save(_ snapshot: WorkspaceSnapshot) async throws
}
