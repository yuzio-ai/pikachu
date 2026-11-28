import Foundation
import AgentRuntimeCore

public struct ProjectRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var previousPaths: [String]
    public var lastViewed: Date
    public var customDisplayName: String?

    public var displayName: String {
        customDisplayName ?? (name.prefix(1).uppercased() + name.dropFirst())
    }

    public init(id: UUID = UUID(), path: String) {
        self.id = id; self.path = path; name = URL(fileURLWithPath: path).lastPathComponent
        previousPaths = []; lastViewed = Date()
    }
}

public enum SessionSettingSource: String, Codable, Sendable {
    case project, global, session
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
    public var fileChanges: TurnFileChanges?
    var model: SessionTurnModel?
    var modelChange: SessionModelChange?
    // The submission associated with the turn's effective model.
    var modelSubmissionID: UUID?
    public init(id: UUID = UUID(), anchorAssistantTimestampMs: Int64? = nil, endAssistantTimestampMs: Int64? = nil,
                anchorToolCallID: String? = nil, anchorUserTimestampMs: Int64? = nil,
                startedAt: Date? = nil, endedAt: Date? = nil,
                durationSeconds: TimeInterval? = nil, status: TurnStatus, fileChanges: TurnFileChanges? = nil) {
        self.id = id
        self.anchorAssistantTimestampMs = anchorAssistantTimestampMs
        self.endAssistantTimestampMs = endAssistantTimestampMs
        self.anchorToolCallID = anchorToolCallID
        self.anchorUserTimestampMs = anchorUserTimestampMs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.status = status
        self.fileChanges = fileChanges
    }
}

public struct SessionTurnModel: Codable, Sendable, Equatable {
    public let provider: String?
    public let id: String
    public let name: String

    init?(_ session: RuntimeSession?) {
        guard let session, let id = session.modelID, !id.isEmpty else { return nil }
        self.id = id
        provider = session.provider
        name = session.model.isEmpty ? id : session.model
    }

    func matches(_ other: Self) -> Bool {
        id == other.id && provider == other.provider
    }

    public var identifier: String {
        provider.map { "\($0)/\(id)" } ?? id
    }
}

public struct SessionModelChange: Codable, Sendable, Equatable {
    let previous: SessionTurnModel
    let current: SessionTurnModel

    public var title: String {
        let sameName = previous.name == current.name
        let from = sameName ? previous.identifier : previous.name
        let to = sameName ? current.identifier : current.name
        return "\(from) → \(to)"
    }
}
public struct RecordedMessageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var files: [URL]?
    public var sentAt: Date?
    public var messageTimestampMs: Int64?
    var handoffContext: String?
    public init(id: UUID, text: String, files: [URL]? = nil, sentAt: Date? = nil, messageTimestampMs: Int64? = nil,
                handoffContext: String? = nil) {
        self.id = id
        self.text = text
        self.files = files
        self.sentAt = sentAt
        self.messageTimestampMs = messageTimestampMs
        self.handoffContext = handoffContext
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

/// Lightweight read-only offline display cache entry for file-less ACP sessions.
/// Never treated as execution source of truth; reconnecting replaces it with runtime history replay.
public struct CachedTranscriptItem: Codable, Sendable, Equatable, Identifiable {
    public static let maximumItemCount = 60
    public static let maximumTextBytes = 8_192
    public static let maximumToolOutputBytes = 4_096

    public let id: String
    public let kind: HistoryItemKind
    public let text: String
    public let tool: RuntimeTool?
    public let sentAt: Date?
    public let endedAt: Date?
    public let files: [URL]?
    public let submissionID: UUID?
    public let delivery: DeliveryState?

    public init(id: String, kind: HistoryItemKind, text: String = "", tool: RuntimeTool? = nil, sentAt: Date? = nil,
                endedAt: Date? = nil, files: [URL]? = nil, submissionID: UUID? = nil, delivery: DeliveryState? = nil) {
        self.id = id
        self.kind = kind
        self.text = Self.boundedUTF8(text, limit: Self.maximumTextBytes)
        self.tool = tool.map(Self.sanitizedTool)
        self.sentAt = sentAt
        self.endedAt = endedAt
        self.files = files?.isEmpty == true ? nil : files
        self.submissionID = submissionID
        self.delivery = delivery
    }

    public var asHistoryItem: HistoryItem {
        HistoryItem(id: id, kind: kind, text: text, tool: tool, sentAt: sentAt)
    }

    private static func sanitizedTool(_ tool: RuntimeTool) -> RuntimeTool {
        var copy = RuntimeTool(
            id: tool.id,
            name: tool.name,
            summary: tool.summary,
            arguments: boundedUTF8(tool.arguments, limit: maximumToolOutputBytes),
            output: boundedUTF8(tool.output, limit: maximumToolOutputBytes),
            state: tool.state == .running ? .interrupted : tool.state,
            truncated: tool.truncated || tool.output.utf8.count > maximumToolOutputBytes
        )
        copy.argumentsTruncated = tool.argumentsTruncated ?? (tool.arguments.utf8.count > maximumToolOutputBytes ? true : nil)
        copy.editArguments = tool.editArguments
        copy.writePath = tool.writePath
        copy.outputImage = nil
        return copy
    }

    private static func boundedUTF8(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        result.reserveCapacity(min(limit, text.utf8.count))
        var used = 0
        for character in text {
            let bytes = character.utf8.count
            if used + bytes > limit { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}

public struct SessionReference: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var runtimeID: String
    public var runtimeSessionID: String?
    public var file: URL?
    public var historyConfirmed: Bool? = false
    public var title: String
    var customTitle: String?
    var generatedTitle: String?
    var awaitsAutomaticTitle: Bool?
    var automaticTitleSubmissionID: UUID?
    var attachmentTitleFilename: String?
    public var lastViewed: Date
    public var draft: String
    public var draftFiles: [URL]?
    public var mode: SendMode
    public var modelSource: SessionSettingSource?
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
    var unreadCompletionTurnID: UUID?
    public internal(set) var archivedAt: Date?
    public var recordedTurns: [RecordedTurnRecord]?
    public var recordedMessages: [RecordedMessageRecord]?
    public internal(set) var worktreePath: String?
    var boundWorkingDirectory: String?
    public internal(set) var historicalModel: RuntimeSelection?
    public var runtimeModeID: String?
    public var resumableSession: Bool?
    public internal(set) var remoteHistoryDeleted: Bool?
    public internal(set) var canDeleteRemoteHistory: Bool?
    public var cachedHistoryItems: [CachedTranscriptItem]?
    var frozenSegments: [FrozenSessionSegment]?
    var activeSegmentID: UUID?
    public internal(set) var handoff: SessionHandoff?
    public internal(set) var handoffCleanupID: UUID?
    public var isACPRuntime: Bool { RuntimeAgentProfile.isACPRuntimeID(runtimeID) }
    public var hasBoundWorkingDirectory: Bool {
        boundWorkingDirectory != nil || file != nil || recordedMessages?.isEmpty == false
    }
    public var hasBoundRuntime: Bool {
        hasBoundWorkingDirectory || runtimeSessionID != nil ||
            (isACPRuntime && (cachedHistoryItems?.isEmpty == false || recordedTurns?.isEmpty == false))
    }
    var hasNonResumableACPHistory: Bool {
        isACPRuntime && hasBoundRuntime && (handoff == nil || handoff?.delivered == true || runtimeSessionID != nil) &&
            (remoteHistoryDeleted == true || resumableSession != true || runtimeSessionID == nil)
    }
    var segmentID: UUID { activeSegmentID ?? id }

    func containsRuntimeSession(agent: String, id: String) -> Bool {
        (runtimeID == agent && runtimeSessionID == id) ||
            frozenSegments?.contains { $0.runtimeID == agent && $0.runtimeSessionID == id } == true
    }

    var requiresHandoffCleanupConfirmation: Bool {
        guard isACPRuntime, let handoff else { return false }
        // Older snapshots can retain a rejected target's binding without a receipt.
        return handoffCleanupID != nil || (!handoff.delivered && handoff.firstSubmissionID == nil &&
                                           runtimeSessionID != nil && resumableSession != true &&
                                           recordedMessages?.isEmpty != false)
    }

    mutating func discardUnacceptedHandoffSubmission(_ submissionID: UUID) {
        handoff?.firstSubmissionID = nil
        handoff?.lastSubmissionRejected = true
        handoff?.lastRejectedSubmissionID = submissionID
        recordedMessages?.removeAll { $0.id == submissionID }
        cachedHistoryItems?.removeAll { $0.id == "user:\(submissionID)" }
    }

    mutating func releaseUnacceptedACPBinding() {
        guard runtimeSessionID != nil, resumableSession != true,
              let handoff, !handoff.delivered, handoff.firstSubmissionID == nil,
              recordedMessages?.isEmpty != false else { return }
        runtimeSessionID = nil
        resumableSession = nil
        canDeleteRemoteHistory = nil
    }

    mutating func beginHandoff(_ handoff: SessionHandoff, target: SessionReference, selection: RuntimeSelection?,
                               modelName: String?, directory: String, frozenSegments: [FrozenSessionSegment]) {
        self.handoff = handoff
        handoffCleanupID = nil
        self.frozenSegments = frozenSegments
        activeSegmentID = handoff.id
        runtimeID = target.runtimeID
        runtimeSessionID = nil
        file = nil
        historyConfirmed = false
        cachedHistoryItems = nil
        recordedMessages = nil
        recordedTurns = nil
        submissions = []
        wasExecuting = false
        boundWorkingDirectory = directory
        self.selection = nil
        pendingSelection = selection ?? target.pendingSelection
        pendingModelName = modelName ?? target.pendingModelName
        self.modelName = nil
        modelSource = selection == nil ? target.modelSource : .session
        historicalModel = nil
        runtimeModeID = nil
        resumableSession = nil
        remoteHistoryDeleted = nil
        canDeleteRemoteHistory = nil
        processingStatus = .open
    }
    public func workingDirectory(in project: ProjectRecord) -> String {
        boundWorkingDirectory ?? worktreePath ?? project.path
    }
    public var sidebarStatus: SessionProcessingStatus { processingStatus ?? .open }
    public var hasUnreadCompletion: Bool { unreadCompletionTurnID != nil }
    public var activity: SessionActivity { sidebarActivity ?? .init(date: lastViewed, isEstimate: true) }
    public func reminderState(at date: Date) -> SessionReminderState {
        guard let reminderDueAt, sidebarStatus == .open else { return .none }
        return reminderDueAt > date ? .snoozed(until: reminderDueAt) : .due
    }
    public var displayTitle: String {
        if let customTitle { return customTitle }
        if let generatedTitle { return generatedTitle }
        if let attachmentTitleFilename {
            return String(localized: "查看 \(attachmentTitleFilename)", bundle: #bundle)
        }
        switch title {
        case "新会话": return String(localized: "新会话", bundle: #bundle)
        case "历史会话": return String(localized: "历史会话", bundle: #bundle)
        default: return title
        }
    }
    public init(id: UUID = UUID(), projectID: UUID, runtimeID: String, title: String = "新会话") {
        self.id = id; self.projectID = projectID; self.runtimeID = runtimeID; self.title = title; lastViewed = Date()
        draft = ""; mode = .steer; recovered = []; submissions = []; wasExecuting = false
    }
}
public struct WorkspacePreferences: Codable, Sendable, Equatable {
    public var acpAgents: [RuntimeAgentProfile]?
    public var defaultRuntimeID: String?
    public var resolvedDefaultRuntimeID: String? {
        let enabled = (acpAgents ?? []).filter(\.enabled)
        return enabled.first { $0.id == defaultRuntimeID }?.id ?? enabled.first?.id
    }
    public init(acpAgents: [RuntimeAgentProfile]? = nil, defaultRuntimeID: String? = nil) {
        self.acpAgents = acpAgents; self.defaultRuntimeID = defaultRuntimeID
    }
}
public struct WorkspaceModelPreferences: Codable, Sendable, Equatable {
    public var defaultModel: RuntimeModel?
    public var favorites: [RuntimeModel] = []
    public var hiddenModelIDs: Set<String> = []
    public var hiddenModelReferences: [String: RuntimeModel]?
    public init() {}

    public var savedModelReferences: [RuntimeModel] {
        favorites + [defaultModel].compactMap { $0 } + hiddenModelIDs.sorted().compactMap { id in
            if let model = hiddenModelReferences?[id], model.id == id { return model }
            // Older snapshots kept only the composite ID. Model IDs can contain slashes.
            let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return RuntimeModel(provider: String(parts[0]), modelID: String(parts[1]), name: String(parts[1]))
        }
    }

    public func pickerModels(from catalogue: [RuntimeModel], keeping modelIDs: Set<String>, showAll: Bool) -> [RuntimeModel] {
        let visible = catalogue.filter { !hiddenModelIDs.contains($0.id) || modelIDs.contains($0.id) }
        guard !showAll else { return visible }
        let favoriteIDs = Set(favorites.map(\.id)).subtracting(hiddenModelIDs)
        guard visible.contains(where: { favoriteIDs.contains($0.id) }) else { return visible }
        return visible.filter { favoriteIDs.contains($0.id) || modelIDs.contains($0.id) }
    }
}
public struct SessionTitleModel: Codable, Equatable, Identifiable, Sendable {
    public let runtimeID: String
    public let model: RuntimeModel
    public var id: String { runtimeID + ":" + model.id }

    public init(runtimeID: String, model: RuntimeModel) {
        self.runtimeID = runtimeID
        self.model = model
    }
}

public struct SessionTitleSettings: Codable, Equatable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        case automatic, specified, disabled
    }

    public static let maximumRuleBytes = 4096
    public var mode: Mode
    public var model: SessionTitleModel?
    public var rules: String

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .automatic
        rules = try values.decodeIfPresent(String.self, forKey: .rules) ?? ""
        if (try? values.decode(RuntimeModel.self, forKey: .model)) != nil {
            // Pre-ACP title settings stored a Pi model without an agent binding.
            model = nil
        } else {
            model = try values.decodeIfPresent(SessionTitleModel.self, forKey: .model)
            if model?.runtimeID == "pi" { model = nil }
        }
        if mode == .specified, model == nil { mode = .automatic }
    }

    public init(mode: Mode = .automatic, model: SessionTitleModel? = nil, rules: String = "") {
        self.mode = mode
        self.model = model
        self.rules = rules
    }
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var version = 1
    public var revision: Int64 = 0
    public var projects: [ProjectRecord] = []
    public var sessions: [SessionReference] = []
    public var selectedSessionID: UUID?
    public var preferences = WorkspacePreferences()
    public var runtimeEnvironments: [String: [String: String]]?
    public var modelPreferencesByRuntime: [String: WorkspaceModelPreferences]?
    public var sessionTitleSettings: SessionTitleSettings?
    public init() {}

    public func modelPreferences(forRuntime runtimeID: String) -> WorkspaceModelPreferences {
        return modelPreferencesByRuntime?[runtimeID] ?? WorkspaceModelPreferences()
    }
}
public protocol WorkspaceStore: Sendable {
    func load() async throws -> WorkspaceSnapshot
    func save(_ snapshot: WorkspaceSnapshot) async throws
    func saveSessionHistory(_ history: SessionHistorySnapshot, segmentID: UUID) async throws
    func loadSessionHistory(segmentID: UUID) async throws -> SessionHistorySnapshot
    func pruneSessionHistory(retaining segmentIDs: Set<UUID>) async throws
    func removeSessionHistory(segmentIDs: Set<UUID>) async throws
}

public extension WorkspaceStore {
    func saveSessionHistory(_ history: SessionHistorySnapshot, segmentID: UUID) async throws {
        throw CocoaError(.fileWriteUnsupportedScheme)
    }

    func loadSessionHistory(segmentID: UUID) async throws -> SessionHistorySnapshot {
        throw CocoaError(.fileReadNoSuchFile)
    }

    func pruneSessionHistory(retaining segmentIDs: Set<UUID>) async throws {}
    func removeSessionHistory(segmentIDs: Set<UUID>) async throws {}
}
