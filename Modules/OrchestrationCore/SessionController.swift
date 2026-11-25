import Foundation
import Observation
import AgentRuntimeCore

public enum ConnectionState: String, Sendable { case disconnected, connecting, connected, closing, blocked }
public enum TranscriptKind: Sendable { case user, assistant, tool, notice }
public enum DeliveryState: String, Sendable, Codable { case pending, accepted, queued, recovered, handled, rejected, unknown }

@MainActor @Observable public final class TurnRecord: Identifiable {
    public let id: UUID
    let displayID: String
    var timelineSegmentID: UUID?
    var timelineID: String { timelineSegmentID.map { "\($0):\(displayID)" } ?? displayID }
    public var status: TurnStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: TimeInterval?
    public var anchorAssistantTimestampMs: Int64?
    public var endAssistantTimestampMs: Int64?
    public var anchorToolCallID: String?
    public var anchorUserTimestampMs: Int64?
    public var fileChanges: TurnFileChanges?
    var model: SessionTurnModel?
    var modelChange: SessionModelChange?
    var modelSubmissionID: UUID?
    public var thoughtText: String = ""
    @ObservationIgnored var monotonicStart: ContinuousClock.Instant?

    public init(id: UUID = UUID(), status: TurnStatus = .running, startedAt: Date? = nil, endedAt: Date? = nil,
                durationSeconds: TimeInterval? = nil, anchorAssistantTimestampMs: Int64? = nil,
                endAssistantTimestampMs: Int64? = nil, anchorToolCallID: String? = nil,
                anchorUserTimestampMs: Int64? = nil, monotonicStart: ContinuousClock.Instant? = nil,
                displayID: String? = nil, fileChanges: TurnFileChanges? = nil) {
        self.id = id
        self.displayID = displayID ?? id.uuidString
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.anchorAssistantTimestampMs = anchorAssistantTimestampMs
        self.endAssistantTimestampMs = endAssistantTimestampMs
        self.anchorToolCallID = anchorToolCallID
        self.anchorUserTimestampMs = anchorUserTimestampMs
        self.fileChanges = fileChanges
        self.monotonicStart = monotonicStart
    }

    public func elapsedTime(at now: Date, monotonicNow: ContinuousClock.Instant) -> TimeInterval? {
        if let monotonicStart {
            let elapsed = (monotonicNow - monotonicStart).components
            return max(0, TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18)
        }
        return startedAt.map { max(0, now.timeIntervalSince($0)) }
    }
}

public struct TranscriptToolSummary: Equatable {
    public let name: String
    public let arguments: String
    public let editArguments: RuntimeTool.EditArguments?
    public let writePath: String?
    public let state: ToolState

    fileprivate init(tool: RuntimeTool) {
        name = tool.name
        arguments = tool.arguments
        editArguments = tool.editArguments
        writePath = tool.writePath
        state = tool.state
    }
}

@MainActor @Observable public final class TranscriptItem: Identifiable {
    public let id: String
    public let kind: TranscriptKind
    var timelineSegmentID: UUID?
    public var timelineID: String { timelineSegmentID.map { "\($0):\(id)" } ?? id }
    public internal(set) var handoff: SessionHandoff?
    public internal(set) var modelChange: SessionModelChange?
    var recordedSubmissionID: UUID?
    public var text: String {
        didSet {
            let visible = text.contains { !$0.isWhitespace }
            if visible != hasVisibleText { hasVisibleText = visible }
        }
    }
    // Let row projection observe the first visible text, not every streamed delta.
    public private(set) var hasVisibleText: Bool
    public var delivery: DeliveryState
    public var streaming: Bool
    public var sentAt: Date?
    public var messageTimestampMs: Int64?
    public var turn: TurnRecord?
    public internal(set) var originalText: String?
    public internal(set) var attachedFiles: [URL]
    public let expiredInteraction: RuntimeInteraction?
    let submission: UserPrompt?
    public var submissionID: UUID? { submission?.id ?? recordedSubmissionID }
    @ObservationIgnored fileprivate var observedQueueLane: SendMode?
    public var submittedMode: SendMode? { submission?.mode }
    public var editableText: String { originalText ?? submission?.text ?? text }
    public var editableFiles: [URL] { attachedFiles.isEmpty ? (submission?.files ?? []) : attachedFiles }
    public var tool: RuntimeTool? {
        didSet {
            let summary = tool.map(TranscriptToolSummary.init)
            if summary != toolSummary { toolSummary = summary }
        }
    }
    // Collapsed rows observe status and arguments without observing streamed output.
    public private(set) var toolSummary: TranscriptToolSummary?
    @ObservationIgnored private var blocks: [Int: String] = [:]
    public init(id: String, kind: TranscriptKind, text: String = "", delivery: DeliveryState = .accepted, streaming: Bool = false, tool: RuntimeTool? = nil, sentAt: Date? = nil, messageTimestampMs: Int64? = nil, turn: TurnRecord? = nil, submission: UserPrompt? = nil, originalText: String? = nil, attachedFiles: [URL] = [], expiredInteraction: RuntimeInteraction? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.delivery = delivery; self.streaming = streaming; self.tool = tool
        self.sentAt = sentAt; self.messageTimestampMs = messageTimestampMs; self.turn = turn
        hasVisibleText = text.contains { !$0.isWhitespace }
        self.originalText = originalText; self.attachedFiles = attachedFiles; self.expiredInteraction = expiredInteraction
        toolSummary = tool.map(TranscriptToolSummary.init)
        self.submission = submission
    }
    public func append(index: Int, delta: String) {
        blocks[index, default: ""] += delta
        text = blocks.keys.sorted().compactMap { blocks[$0] }.joined(separator: "\n")
    }
}

/// One supervised execution instance. Workspace orchestration owns project/session selection.
@MainActor @Observable public final class SessionController {
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var phase: ExecutionPhase = .idle
    public private(set) var session: RuntimeSession?
    public private(set) var transcript: [TranscriptItem] = []
    public private(set) var transcriptTurnStarts: [TranscriptTurnStart] = []
    var timelineSegmentID: UUID?
    private(set) var receivedHistoryReplay = false
    @ObservationIgnored private var lastTurnModel: SessionTurnModel?
    var reconnectingACPHistory = false
    public private(set) var queue = RuntimeQueue()
    public private(set) var queueIsKnown = true
    public private(set) var recoveredDrafts: [PendingPrompt] = []
    public private(set) var failure: RuntimeFailure? {
        didSet { failedModelInput = nil }
    }
    private var failedModelInput: TranscriptItem?
    public var retryableModelPrompt: UserPrompt? {
        guard connection == .connected, phase == .idle, !commandPending,
              queueIsKnown, queue.isEmpty, interactions.isEmpty,
              failedModelInput?.delivery == .accepted else { return nil }
        return failedModelInput?.submission
    }
    public private(set) var notice: String?
    private var regularPending = false
    private var stopPending = false
    public var commandPending: Bool { regularPending || stopPending }
    public var isStopping: Bool { stopPending || phase == .stopping }
    public private(set) var interactions: [RuntimeInteraction] = []
    public private(set) var replying = false
    public private(set) var usage: RuntimeUsage?
    public private(set) var usageStale = true
    public private(set) var usageLoading = false
    public private(set) var usageNotice: String?
    public private(set) var extensionStatus: [String: String] = [:]
    public private(set) var plan: [RuntimePlanEntry] = []
    public private(set) var showingCachedHistory = false
    private var toolFailureTurnID: UUID?
    private var dismissedToolFailureIDs: Set<String> = []

    public var recentToolFailures: [TranscriptItem] {
        guard let turnID = toolFailureTurnID else { return [] }
        return transcript.reversed().filter {
            $0.turn?.id == turnID && $0.toolSummary?.state == .failed && !dismissedToolFailureIDs.contains($0.id)
        }
    }

    public func dismissToolFailures(_ items: [TranscriptItem]) {
        dismissedToolFailureIDs.formUnion(items.map(\.id))
    }
    @ObservationIgnored private var cachedHistoryNotice: String?
    @ObservationIgnored private var phaseBeforeWaiting: ExecutionPhase = .idle
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var usageGeneration = UUID()
    @ObservationIgnored private let clock: any RuntimeClock
    @ObservationIgnored public private(set) var activeTurn: TurnRecord?
    @ObservationIgnored private var activeTurnHadFailure = false
    @ObservationIgnored private var activeTurnHasVisibleOutput = false
    @ObservationIgnored private var activeTurnUser: TranscriptItem?
    @ObservationIgnored private var startingSubmission: TranscriptItem?
    @ObservationIgnored private var sendingSubmission: TranscriptItem?
    @ObservationIgnored private var awaitingUserStarts: [TranscriptItem] = []
    public internal(set) var isDraftEditingLocked = false
    private var draftText = ""
    private var draftAttachments: [URL] = []
    public var draft: String {
        get { draftText }
        set {
            guard !isDraftEditingLocked, newValue != draftText else { return }
            draftText = newValue
            (onDraftEdited ?? onControlChanged)?()
        }
    }
    public var draftFiles: [URL] {
        get { draftAttachments }
        set {
            guard !isDraftEditingLocked, newValue != draftAttachments else { return }
            draftAttachments = newValue
            (onDraftEdited ?? onControlChanged)?()
        }
    }
    public var mode: SendMode = .steer { didSet { onControlChanged?() } }
    @ObservationIgnored public var onControlChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onDraftEdited: (@MainActor () -> Void)?
    @ObservationIgnored var onRuntimeActivityChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var runtimeReads = 0
    var canReclaimIdleRuntime: Bool {
        connection == .connected && phase == .idle && activeTurn == nil && queueIsKnown && queue.isEmpty &&
            interactions.isEmpty && !commandPending && !replying && runtimeReads == 0
    }
    @ObservationIgnored public var prepareSubmission: (@MainActor (UserPrompt) async throws -> Void)?
    @ObservationIgnored public var resolveSubmission: (@MainActor (UUID, DeliveryState) async -> Void)?
    @ObservationIgnored public var onTurnFinished: (@MainActor (TurnRecord) -> Void)?
    @ObservationIgnored var onPromptConfirmed: (@MainActor (UserPrompt) -> Void)?
    @ObservationIgnored public var onApprovalRequested: (@MainActor (RuntimeInteraction) -> Void)?
    @ObservationIgnored public var onUserMessageTimestamp: (@MainActor (UUID?, Int64) -> Void)?
    @ObservationIgnored private var runtime: (any AgentRuntime)?
    @ObservationIgnored private var instance: UUID?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var recoveredOperations = Set<UUID>()
    @ObservationIgnored private var settledCounter = 0
    @ObservationIgnored private var rowsByID: [String: TranscriptItem] = [:]
    @ObservationIgnored private var pendingReplayMetadata: [ReplaySegmentMetadata]?
    @ObservationIgnored private var pendingReplayRecordedTurns: [RecordedTurnRecord] = []
    @ObservationIgnored private var pendingReplayRecordedMessages: [RecordedMessageRecord] = []

    private struct ReplaySegmentMetadata {
        let userText: String?
        let submissionID: UUID?
        let sentAt: Date?
        let attachedFiles: [URL]
        let originalText: String?
        let startedAt: Date?
        let endedAt: Date?
        let durationSeconds: TimeInterval?
    }
    public var supportsQueuedPrompts: Bool {
        session?.capabilities.contains(.queuedPrompts) == true
    }
    public var supportsModeSelection: Bool {
        session?.capabilities.contains(.modeSelection) == true || !(session?.availableModes.isEmpty ?? true)
    }
    private var acceptsInput: Bool {
        guard connection == .connected, !commandPending,
              phase != .uncertain, phase != .stopping, phase != .waitingInput else { return false }
        if phase.isActive && session?.capabilities.contains(.queuedPrompts) == false {
            return false
        }
        return true
    }
    public var canSend: Bool {
        acceptsInput && draftPrompt.hasContent
    }
    public var draftPrompt: UserPrompt { .init(text: draft, mode: mode, files: draftFiles) }
    func matchesDraft(_ prompt: UserPrompt) -> Bool { draft == prompt.text && draftFiles == prompt.files && mode == prompt.mode }
    public var canStop: Bool { connection == .connected && !stopPending && (!regularPending || !interactions.isEmpty) && (phase.isActive || !queue.isEmpty) }
    public var canConnect: Bool { connection == .disconnected && !commandPending }
    public init(clock: any RuntimeClock = SystemRuntimeClock()) { self.clock = clock }
    public func connect(_ newRuntime: any AgentRuntime, history: [HistoryItem] = [], turns: [HistoryTurnInfo] = [], recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = [], historyOnly: Bool = false) async {
        guard canConnect else { return }
        receivedHistoryReplay = false
        let wasShowingCached = showingCachedHistory
        let cachedSegments = history.isEmpty ? Self.replaySegments(from: transcript) : []
        let keepCachedWhileConnecting = wasShowingCached && history.isEmpty && !transcript.isEmpty
        regularPending = true; connection = .connecting; failure = nil; notice = nil; showingCachedHistory = false; cachedHistoryNotice = nil
        instance = nil
        if let runtime {
            do { try await runtime.close(force: true) }
            catch {
                if keepCachedWhileConnecting { showingCachedHistory = !transcript.isEmpty }
                failure = .init(.supervision, String(localized: "上一执行实例的清理未确认，不能建立新连接。", bundle: #bundle)); connection = .blocked; regularPending = false; return
            }
        }
        consumer?.cancel()
        runtime = newRuntime; instance = newRuntime.instanceID
        pendingReplayMetadata = cachedSegments.isEmpty ? nil : cachedSegments
        pendingReplayRecordedTurns = recordedTurns
        pendingReplayRecordedMessages = recordedMessages
        if !keepCachedWhileConnecting {
            transcript = []; rowsByID = [:]
        }
        transcriptTurnStarts = []; queue = .init(); queueIsKnown = true; phase = .idle; session = nil
        lastTurnModel = recordedTurns.last(where: { $0.model != nil })?.model
        activeTurn = nil; activeTurnUser = nil; startingSubmission = nil
        sendingSubmission = nil; awaitingUserStarts = []
        activeTurnHadFailure = false; activeTurnHasVisibleOutput = false
        toolFailureTurnID = nil; dismissedToolFailureIDs.removeAll()
        interactions = []; extensionStatus = [:]; plan = []; usage = nil; usageStale = true; usageLoading = false; usageGeneration = UUID()
        seedHistory(history, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        consumer = Task { [weak self] in
            for await envelope in newRuntime.events {
                guard !Task.isCancelled else { return }
                self?.receive(envelope)
                if case .batch = envelope.event { try? await Task.sleep(for: .milliseconds(1)) }
            }
            guard !Task.isCancelled, let self, self.instance == newRuntime.instanceID,
                  self.connection == .connected || self.connection == .connecting else { return }
            self.markPendingHandoffUnknown()
            self.failure = .init(.connection, String(localized: "运行时事件流意外结束，进程清理尚未确认。", bundle: #bundle))
            self.connection = .blocked; self.phase = .uncertain; self.finishRound(status: .uncertain, confirmedEndTime: false); self.interruptUnfinished()
            self.onControlChanged?()
        }
        do {
            let opened = historyOnly ? try await newRuntime.connectForHistory() : try await newRuntime.connect()
            guard connection == .connecting else { throw RuntimeFailure(.connection, String(localized: "连接在启动期间中断。", bundle: #bundle)) }
            // Only a nonempty replay can replace the cached rows. Some agents
            // advertise replay support but return no history for a given session.
            if !opened.replaysHistory {
                pendingReplayMetadata = nil
                pendingReplayRecordedTurns = []
                pendingReplayRecordedMessages = []
            }
            session = opened; connection = .connected
        } catch {
            if keepCachedWhileConnecting && !receivedHistoryReplay {
                showingCachedHistory = !transcript.isEmpty
            }
            pendingReplayMetadata = nil
            pendingReplayRecordedTurns = []
            pendingReplayRecordedMessages = []
            failure = (error as? RuntimeFailure) ?? .init(.setup, String(localized: "连接失败，请检查项目与运行时配置。", bundle: #bundle))
            do { try await newRuntime.close(force: true); connection = .disconnected }
            catch { connection = .blocked; phase = .uncertain }
        }
        regularPending = false
        if connection == .connected { scheduleUsage() }
        onControlChanged?()
    }
    public func sendDraft(_ submitted: UserPrompt? = nil) async {
        let prompt = submitted ?? draftPrompt
        guard acceptsInput, prompt.hasContent, let runtime else { return }
        let text = prompt.runtimeText
        let origin = runtime.instanceID
        regularPending = true
        do { try await prepareSubmission?(prompt) }
        catch {
            failure = .init(.setup, String(localized: "发送状态未能持久化，没有发送任务。请先修复本地存储。", bundle: #bundle))
            regularPending = false; onControlChanged?(); return
        }
        let item = TranscriptItem(id: "user:\(prompt.id)", kind: .user, text: text, delivery: .pending, sentAt: clock.now(), submission: prompt, originalText: prompt.text, attachedFiles: prompt.files)
        append(item)
        sendingSubmission = item
        if phase == .idle && activeTurn == nil && queue.isEmpty {
            startingSubmission = item
            toolFailureTurnID = nil
            dismissedToolFailureIDs.removeAll()
        }
        if matchesDraft(prompt) { draft = ""; draftFiles = [] }
        failure = nil
        let before = settledCounter
        var waitsForAcceptance = false
        do {
            let disposition = try await runtime.send(prompt)
            switch disposition {
            case .started where item.delivery == .pending || item.delivery == .accepted:
                item.delivery = .accepted
                if instance == origin && settledCounter == before && !isStopping {
                    if phase == .idle { phase = .running }
                    startRound(startingWith: item)
                }
            case .queued:
                // Ordered queue events may already have moved this input on.
                if item.delivery == .pending { item.delivery = .queued }
            case .handled where item.delivery == .pending: item.delivery = .handled
            case .awaitingAcceptance: waitsForAcceptance = true
            case .started, .handled: break
            }
        } catch {
            let problem = (error as? RuntimeFailure) ?? .init(.outcomeUnknown, String(localized: "发送结果尚未确认，不会自动重发。", bundle: #bundle))
            if item.delivery != .accepted && item.delivery != .recovered {
                item.delivery = [.outcomeUnknown, .connection, .protocolError, .supervision].contains(problem.kind) ? .unknown : .rejected
            }
            if instance == origin {
                if connection != .blocked || failure == nil { failure = problem }
                if item.delivery == .unknown { phase = .uncertain }
            }
            // A rejected input can be restored without overwriting new typing.
            if item.delivery == .rejected { recoveredDrafts.append(.init(id: prompt.id, text: prompt.text, mode: prompt.mode, files: prompt.files)) }
        }
        if startingSubmission === item { startingSubmission = nil }
        if sendingSubmission === item { sendingSubmission = nil }
        if instance == origin { regularPending = false }
        if !waitsForAcceptance { await resolveSubmission?(prompt.id, item.delivery) }
        onControlChanged?()
    }
    public func stop() async {
        guard canStop, let runtime else { return }
        stopPending = true; phase = .stopping
        do {
            try await runtime.stop()
            let until = Date().addingTimeInterval(2)
            let receivesFileChanges = session?.capabilities.contains(.turnFileChanges) == true
            // A runtime may acknowledge abort before its final checkpoint reaches the controller.
            while (regularPending || (receivesFileChanges && activeTurn != nil)) && Date() < until {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !regularPending else { throw RuntimeFailure(.outcomeUnknown, String(localized: "仍有未完成的控制请求，不能确认停止。", bundle: #bundle)) }
            awaitingUserStarts.removeAll()
            phase = .idle
            finishRound(status: .stopped, confirmedEndTime: true)
            interruptUnfinished()
        }
        catch {
            awaitingUserStarts.removeAll()
            failure = (error as? RuntimeFailure) ?? .init(.outcomeUnknown, String(localized: "停止结果尚未确认。请结束受管进程。", bundle: #bundle))
            phase = .uncertain
            finishRound(status: .uncertain, confirmedEndTime: false)
        }
        stopPending = false
        onControlChanged?()
    }
    @discardableResult public func disconnect(force: Bool = false) async -> Bool {
        guard !commandPending || (force && !stopPending) else { notice = String(localized: "请等待当前控制请求结束。", bundle: #bundle); return false }
        guard let runtime else { connection = .disconnected; return true }
        regularPending = true; connection = .closing
        awaitingUserStarts.removeAll()
        do {
            if phase.isActive && !force { try await runtime.stop() }
            try await runtime.close(force: force)
            markPendingHandoffUnknown()
            connection = .disconnected; phase = .idle; queue = .init(); queueIsKnown = true
            consumer?.cancel(); self.runtime = nil; instance = nil
            interactions = []; usageTask?.cancel(); usageGeneration = UUID(); usageStale = true
            finishRound(status: .uncertain, confirmedEndTime: false)
            interruptUnfinished()
            regularPending = false; onControlChanged?(); return true
        } catch {
            markPendingHandoffUnknown()
            failure = (error as? RuntimeFailure) ?? .init(.supervision, String(localized: "进程清理尚未确认，不能继续执行。", bundle: #bundle))
            connection = .blocked; phase = .uncertain
            finishRound(status: .uncertain, confirmedEndTime: false)
            regularPending = false; onControlChanged?(); return false
        }
    }
    public func restoreDraft(_ id: UUID) {
        guard !isDraftEditingLocked, let index = recoveredDrafts.firstIndex(where: { $0.id == id }) else { return }
        mergeIntoDraft(recoveredDrafts.remove(at: index))
    }
    func mergeIntoDraft(_ recovered: PendingPrompt) {
        if !recovered.text.isEmpty { draft = draft.isEmpty ? recovered.text : draft + "\n\n" + recovered.text }
        for file in recovered.files ?? [] where !draftFiles.contains(file) { draftFiles.append(file) }
        mode = recovered.mode
        onControlChanged?()
    }
    public func restoreLocalState(draft: String, mode: SendMode, recovered: [PendingPrompt], files: [URL] = []) {
        guard !isDraftEditingLocked else { return }
        self.draft = draft; self.mode = mode; recoveredDrafts = recovered; draftFiles = files
        onControlChanged?()
    }
    public func showHistory(_ items: [HistoryItem], usage: RuntimeUsage? = nil, turns: [HistoryTurnInfo] = [],
                            recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) {
        guard connection == .disconnected else { return }
        let rows = historyRows(items, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        Self.applyRecordedMetadata(recordedTurns: [], recordedMessages: recordedMessages,
                                   modelTurns: recordedTurns, handoffAndModelMessagesOnly: true, onto: rows)
        rowsByID = [:]
        for row in rows { rowsByID[row.id] = row }
        transcript = rows
        transcriptTurnStarts = []
        toolFailureTurnID = nil
        dismissedToolFailureIDs.removeAll()
        showingCachedHistory = false
        cachedHistoryNotice = nil
        self.usage = usage; usageStale = false
    }

    func resetForHandoff(to segmentID: UUID) {
        guard connection == .disconnected else { return }
        timelineSegmentID = segmentID
        lastTurnModel = nil
        receivedHistoryReplay = false
        reconnectingACPHistory = false
        session = nil
        failure = nil
        notice = nil
        usageNotice = nil
        extensionStatus = [:]
        plan = []
        showHistory([])
    }

    func reconcileLoadedSessionHistory() async {
        guard let runtime, let items = await runtime.loadedSessionHistory(),
              !receivedHistoryReplay, connection == .connected else { return }
        receive(.init(instanceID: runtime.instanceID, event: .historyReplayed(items)))
    }
    public func showCachedHistory(_ items: [CachedTranscriptItem],
                                  recordedTurns: [RecordedTurnRecord] = [],
                                  recordedMessages: [RecordedMessageRecord] = [],
                                  notice: String? = nil) {
        guard connection == .disconnected else { return }
        let rows = historyRows(items.map(\.asHistoryItem), defaultFallbackStatus: .completed)
        for (row, cached) in zip(rows, items) {
            if row.kind == .user {
                row.recordedSubmissionID = cached.submissionID
                if let files = cached.files, !files.isEmpty {
                    row.attachedFiles = files
                    row.originalText = cached.text
                }
            }
            if let endedAt = cached.endedAt, let turn = row.turn {
                turn.endedAt = endedAt
            }
        }
        Self.applyRecordedMetadata(recordedTurns: recordedTurns, recordedMessages: recordedMessages, onto: rows)
        rowsByID = [:]
        for row in rows { rowsByID[row.id] = row }
        transcript = rows
        transcriptTurnStarts = []
        toolFailureTurnID = nil
        dismissedToolFailureIDs.removeAll()
        showingCachedHistory = !items.isEmpty
        cachedHistoryNotice = items.isEmpty ? nil : notice
        self.notice = cachedHistoryNotice
        usage = nil
        usageStale = true
    }
    private func seedHistory(_ items: [HistoryItem], turns: [HistoryTurnInfo] = [],
                             recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) {
        let rows = historyRows(items, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        Self.applyRecordedMetadata(recordedTurns: [], recordedMessages: recordedMessages,
                                   modelTurns: recordedTurns, handoffAndModelMessagesOnly: true, onto: rows)
        for row in rows { rowsByID[row.id] = row }
        transcript.append(contentsOf: rows)
    }
    private func historyRows(_ items: [HistoryItem], turns: [HistoryTurnInfo] = [],
                             recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = [],
                             defaultFallbackStatus: TurnStatus = .uncertain) -> [TranscriptItem] {
        var turnByItemID: [String: TurnRecord] = [:]
        var turnByUserID: [String: TurnRecord] = [:]
        var usedRecords = Set<UUID>()
        var activeRecordedTurn: (endIndex: Int, turn: TurnRecord)?
        let usersByTime = Dictionary(grouping: items.filter { $0.kind == .user }, by: \.messageTimestampMs)
        let messagesByTime = Dictionary(grouping: recordedMessages, by: \.messageTimestampMs)
        let recordsByTool = Dictionary(grouping: recordedTurns, by: \.anchorToolCallID)
        let recordsByAssistant = Dictionary(grouping: recordedTurns, by: \.anchorAssistantTimestampMs)
        let recordsByUser = Dictionary(grouping: recordedTurns, by: \.anchorUserTimestampMs)
        let turnsByTool = Dictionary(grouping: turns, by: \.firstToolCallID)
        let turnsByAssistant = Dictionary(grouping: turns, by: \.firstAssistantTimestampMs)
        let turnsByEnd = Dictionary(grouping: turns.indices) { turns[$0].lastAssistantTimestampMs }

        func unique<T>(_ matches: [T]?) -> T? { matches?.count == 1 ? matches?.first : nil }
        func matchesHistory(_ record: RecordedMessageRecord, user: HistoryItem) -> Bool {
            UserPrompt(text: record.text, files: record.files ?? [], handoffContext: record.handoffContext).runtimeText == user.text
        }

        for (index, info) in turns.enumerated() {
            if let current = activeRecordedTurn {
                for id in info.itemIDs { turnByItemID[id] = current.turn }
                if index == current.endIndex { activeRecordedTurn = nil }
                continue
            }
            let userByTime = info.firstUserTimestampMs.flatMap { unique(usersByTime[$0]) }
            let recordByTool = info.firstToolCallID.flatMap {
                unique(turnsByTool[$0]) == nil ? nil : unique(recordsByTool[$0])
            }
            let recordByAssistant = info.firstAssistantTimestampMs.flatMap {
                unique(turnsByAssistant[$0]) == nil ? nil : unique(recordsByAssistant[$0])
            }
            let recordByUser = userByTime.flatMap { user -> RecordedTurnRecord? in
                guard let ts = user.messageTimestampMs else { return nil }
                if let messages = messagesByTime[ts] {
                    guard let message = unique(messages), matchesHistory(message, user: user) else { return nil }
                }
                return unique(recordsByUser[ts])
            }
            let match = recordByTool ?? recordByAssistant ?? recordByUser
            let record = match.flatMap { usedRecords.insert($0.id).inserted ? $0 : nil }
            // Older live records marked a recovered attempt as a failed turn. Only
            // override that badge when history confirms the exact same reply ended normally.
            let recovered = record?.status == .failed && info.status == .completed && info.hadAssistantFailure
                && info.lastAssistantTimestampMs != nil && record?.endAssistantTimestampMs == info.lastAssistantTimestampMs
            let turn = TurnRecord(
                id: record?.id ?? UUID(),
                status: recovered ? .completed : (record?.status ?? info.status),
                startedAt: record?.startedAt,
                endedAt: record?.endedAt ?? info.endedAt,
                durationSeconds: record?.durationSeconds ?? info.durationSeconds,
                anchorAssistantTimestampMs: record?.anchorAssistantTimestampMs ?? info.firstAssistantTimestampMs,
                endAssistantTimestampMs: record?.endAssistantTimestampMs,
                anchorToolCallID: record?.anchorToolCallID ?? info.firstToolCallID,
                anchorUserTimestampMs: record?.anchorUserTimestampMs ?? info.firstUserTimestampMs,
                displayID: info.id,
                fileChanges: record?.fileChanges
            )
            turn.timelineSegmentID = timelineSegmentID
            turn.model = record?.model
            turn.modelChange = record?.modelChange
            turn.modelSubmissionID = record?.modelSubmissionID
            for id in info.itemIDs { turnByItemID[id] = turn }
            if let userID = info.firstUserItemID ?? userByTime?.id, turnByUserID[userID] == nil {
                turnByUserID[userID] = turn
            }
            if let endMs = record?.endAssistantTimestampMs, let endIndex = unique(turnsByEnd[endMs]), endIndex > index {
                activeRecordedTurn = (endIndex, turn)
            }
        }
        var fallbackTurn: TurnRecord?
        return items.map { item in
            let kind: TranscriptKind = switch item.kind { case .user: .user; case .assistant: .assistant; case .tool: .tool; case .notice: .notice }
            if kind == .user {
                fallbackTurn = nil
                let timestampMatch = item.messageTimestampMs.flatMap { ts in
                    unique(usersByTime[ts]) == nil ? nil : unique(messagesByTime[ts])
                }
                // Older workspaces can contain a timestamp associated with a different input.
                let matchedMessage = timestampMatch.flatMap { record in
                    matchesHistory(record, user: item) ? record : nil
                }
                let row = TranscriptItem(
                    id: item.id,
                    kind: kind,
                    text: item.text,
                    sentAt: item.sentAt ?? matchedMessage?.sentAt,
                    messageTimestampMs: item.messageTimestampMs,
                    turn: turnByUserID[item.id],
                    originalText: matchedMessage?.text ?? item.text,
                    attachedFiles: matchedMessage?.files ?? []
                )
                row.timelineSegmentID = timelineSegmentID
                row.recordedSubmissionID = matchedMessage?.id
                row.modelChange = turnByUserID[item.id]?.modelChange
                return row
            }
            let assignedTurn: TurnRecord?
            if kind == .assistant || kind == .tool {
                if let known = turnByItemID[item.id] {
                    assignedTurn = known
                    fallbackTurn = nil
                } else {
                    if fallbackTurn == nil {
                        fallbackTurn = TurnRecord(status: defaultFallbackStatus, displayID: item.id)
                        fallbackTurn?.timelineSegmentID = timelineSegmentID
                    }
                    assignedTurn = fallbackTurn
                }
            } else {
                assignedTurn = nil
            }
            let row = TranscriptItem(id: item.id, kind: kind, text: item.text, tool: item.tool, turn: assignedTurn)
            row.timelineSegmentID = timelineSegmentID
            return row
        }
    }
    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        try await readModelMetadata { try await $0.configurationOptions() }
    }

    func modelCatalogue() async throws -> [RuntimeModel] {
        try await readModelMetadata { try await $0.modelCatalogue() }
    }

    func thinkingLevels() async throws -> [String] {
        try await readModelMetadata { try await $0.thinkingLevels() }
    }

    private func readModelMetadata<Value: Sendable>(_ read: @MainActor (any AgentRuntime) async throws -> Value) async throws -> Value {
        guard connection == .connected, let runtime else { throw RuntimeFailure(.setup, String(localized: "会话尚未连接。", bundle: #bundle)) }
        let source = runtime.instanceID
        runtimeReads += 1; onRuntimeActivityChanged?()
        defer { runtimeReads -= 1; onRuntimeActivityChanged?() }
        let value = try await read(runtime)
        guard connection == .connected, instance == source else { throw RuntimeFailure(.connection, String(localized: "会话连接已变化，请重试模型查询。", bundle: #bundle)) }
        return value
    }
    public func configure(_ selection: RuntimeSelection) async -> Bool {
        guard connection == .connected, !commandPending, phase == .idle, let runtime else { return false }
        regularPending = true
        usageGeneration = UUID()
        usageStale = true
        defer { regularPending = false; onControlChanged?(); scheduleUsage() }
        do { session = try await runtime.applyConfiguration(selection); failure = nil; return true }
        catch {
            failure = error as? RuntimeFailure ?? .init(.outcomeUnknown, String(localized: "模型配置结果不明，请重新连接核对。", bundle: #bundle))
            if let confirmed = try? await runtime.currentSession() { session = confirmed }
            if failure?.kind == .outcomeUnknown { phase = .uncertain }
            return false
        }
    }
    @discardableResult public func setRuntimeMode(_ modeID: String) async -> Bool {
        guard connection == .connected, !commandPending, phase == .idle, let runtime else { return false }
        regularPending = true
        defer { regularPending = false; onControlChanged?() }
        do {
            session = try await runtime.setMode(modeID)
            failure = nil
            return true
        } catch {
            failure = error as? RuntimeFailure ?? .init(.outcomeUnknown, String(localized: "模式切换结果不明，请重新连接核对。", bundle: #bundle))
            if let confirmed = try? await runtime.currentSession() { session = confirmed }
            if failure?.kind == .outcomeUnknown { phase = .uncertain }
            return false
        }
    }
    public var noticeExcludingExpiredInteraction: String? {
        notice == Self.expiredInteractionNotice ? nil : notice
    }

    public var noticeExcludingComposerPills: String? {
        guard let notice = noticeExcludingExpiredInteraction else { return nil }
        return showingCachedHistory && notice == cachedHistoryNotice ? nil : notice
    }

    private static var expiredInteractionNotice: String {
        String(localized: "扩展交互已过期，未提交过期回复。", bundle: #bundle)
    }
    public func didExpire(_ request: RuntimeInteraction) -> Bool {
        expiredInteraction(for: request) != nil
    }
    public func expiredInteraction(for request: RuntimeInteraction) -> RuntimeInteraction? {
        // The lookup index itself is not observable; the transcript publishes new rows.
        _ = transcript
        let expired = rowsByID[Self.expiryRowID(request.id)]?.expiredInteraction
        return expired?.instanceID == request.instanceID ? expired : nil
    }
    private static func expiryRowID(_ id: String) -> String { "expired-interaction:\(id)" }
    public func cancelInteractions() async { await runtime?.cancelInteractions() }
    @discardableResult public func reply(_ request: RuntimeInteraction, _ response: InteractionResponse) async -> Bool {
        guard !replying, phase != .stopping, request.instanceID == instance,
              interactions.contains(where: { $0.id == request.id }), let runtime else { return false }
        replying = true; onRuntimeActivityChanged?()
        defer { replying = false; onRuntimeActivityChanged?() }
        do { try await runtime.respond(to: request, with: response); return true }
        catch let problem as RuntimeFailure where problem.kind == .unsupportedInteraction { notice = problem.detail }
        catch { failure = .init(.outcomeUnknown, String(localized: "交互回复结果不明，请停止任务并核对运行时状态。", bundle: #bundle)); phase = .uncertain }
        return false
    }
    public func refreshUsage() async {
        guard connection == .connected, !usageLoading, let runtime else { return }
        let generation = usageGeneration; usageLoading = true
        runtimeReads += 1; onRuntimeActivityChanged?()
        defer {
            if generation == usageGeneration { usageLoading = false }
            runtimeReads -= 1; onRuntimeActivityChanged?()
        }
        do {
            let value = try await runtime.usage()
            guard generation == usageGeneration, instance == runtime.instanceID, value.sessionID == session?.id else { return }
            usage = value; usageStale = phase != .idle; usageNotice = nil
        } catch { if generation == usageGeneration { usageNotice = String(localized: "运行时统计暂不可用，未将缺失数据计作零。", bundle: #bundle) } }
    }
    private func scheduleUsage() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await self?.refreshUsage()
        }
    }
    private func append(_ item: TranscriptItem) {
        item.timelineSegmentID = timelineSegmentID
        rowsByID[item.id] = item
        transcript.append(item)
    }
    private func interruptUnfinished() {
        for item in transcript {
            item.streaming = false
            if item.tool?.state == .running { item.tool?.state = .interrupted }
        }
    }

    private func resolveRuntimeAcceptance(_ id: UUID, as acceptance: RuntimePromptAcceptance) {
        guard let item = rowsByID["user:\(id)"], let prompt = item.submission else { return }
        if item.delivery != .pending {
            // Disconnect can be observed before the response to this same prompt.
            let isHandoffResolution = item.delivery == .unknown && prompt.handoffContext != nil
            // ACP can acknowledge the local write before rejecting the remote request.
            let isOrdinaryRejection = item.delivery == .accepted && prompt.handoffContext == nil && acceptance == .rejected
            guard isHandoffResolution || isOrdinaryRejection else { return }
            if case .unknown = acceptance { return }
        }
        switch acceptance {
        case .accepted: item.delivery = .accepted
        case .unknown: item.delivery = .unknown
        case .rejected:
            item.delivery = .rejected
            recoveredDrafts.append(.init(id: id, text: prompt.text, mode: prompt.mode, files: prompt.files))
        }
        let delivery = item.delivery
        Task { [weak self, weak item] in
            guard let self, let item, rowsByID[item.id] === item, item.delivery == delivery else { return }
            await resolveSubmission?(id, delivery)
        }
    }

    func canReviewHandoffSubmission(_ id: UUID) -> Bool {
        guard let item = rowsByID["user:\(id)"], item.submission?.handoffContext != nil else { return true }
        return item.delivery == .unknown
    }

    func finishHandoffSubmissionReview(_ id: UUID, delivery: DeliveryState) {
        if let item = rowsByID["user:\(id)"], item.delivery == .unknown { item.delivery = delivery }
    }

    private func markPendingHandoffUnknown() {
        for item in transcript where item.delivery == .pending {
            guard let prompt = item.submission, prompt.handoffContext != nil else { continue }
            resolveRuntimeAcceptance(prompt.id, as: .unknown)
        }
    }
    private func startRound(startingWith submitted: TranscriptItem? = nil, allowWhileStopping: Bool = false) {
        guard phase != .uncertain, !isStopping || allowWhileStopping else { return }
        let user = submitted ?? startingSubmission
        if let turn = activeTurn {
            // An acknowledgement may arrive after the execution-start event.
            if let user, activeTurnUser == nil, let last = transcriptTurnStarts.indices.last {
                let start = transcriptTurnStarts[last]
                if start.precedingItemID == user.id || (!activeTurnHasVisibleOutput && transcript.last === user) {
                    activeTurnUser = user
                    turn.anchorUserTimestampMs = user.messageTimestampMs
                    attachModelChange(turn, to: user)
                    if start.precedingItemID != user.id {
                        transcriptTurnStarts[last] = .init(turn: turn, precedingItemID: user.id)
                    }
                }
            }
            return
        }
        failedModelInput = nil
        let turn = TurnRecord(id: UUID(), status: .running, startedAt: clock.now(), monotonicStart: clock.monotonicNow())
        turn.timelineSegmentID = timelineSegmentID
        turn.anchorUserTimestampMs = user?.messageTimestampMs
        activeTurn = turn
        activeTurnUser = user
        activeTurnHadFailure = false
        activeTurnHasVisibleOutput = false
        toolFailureTurnID = turn.id
        dismissedToolFailureIDs.removeAll()
        // A queued user message may precede more output from the previous turn.
        transcriptTurnStarts.append(.init(turn: turn, precedingItemID: transcript.last?.id))
    }

    private func attachModelChange(_ turn: TurnRecord, to user: TranscriptItem) {
        guard let change = turn.modelChange else { return }
        user.modelChange = change
        turn.modelSubmissionID = user.submission?.id
    }

    private func confirmTurnModel() {
        guard let turn = activeTurn, turn.model == nil, let current = SessionTurnModel(session) else { return }
        // Some runtimes announce a run before the request is accepted.
        turn.model = current
        if let previous = lastTurnModel, !previous.matches(current) {
            turn.modelChange = .init(previous: previous, current: current)
            if let user = activeTurnUser { attachModelChange(turn, to: user) }
        }
        lastTurnModel = current
    }

    private func startDequeuedFollowUp(_ consumed: [TranscriptItem]) {
        guard (!isStopping || phase == .stopping), phase != .uncertain,
              !consumed.contains(where: { $0.submission?.mode == .steer }),
              let user = consumed.first(where: { $0.submission?.mode == .followUp }),
              activeTurnUser !== user else { return }
        finishRound(status: activeTurnHadFailure ? .failed : .completed, confirmedEndTime: true)
        startRound(startingWith: user, allowWhileStopping: phase == .stopping)
    }

    private func updateQueue(_ next: RuntimeQueue) {
        let previous = queue
        queue = next
        queueIsKnown = true
        guard connection == .connected, phase != .uncertain else { return }
        // Clearing the queue during stop emits an empty snapshot without executing queued rows.
        guard !isStopping || !next.isEmpty else { return }

        struct Slot: Hashable {
            let lane: SendMode
            let text: String
        }
        func counts(_ snapshot: RuntimeQueue) -> [Slot: Int] {
            let steering = snapshot.steering.map { Slot(lane: .steer, text: $0) }
            let followUp = snapshot.followUp.map { Slot(lane: .followUp, text: $0) }
            return Dictionary((steering + followUp).map { ($0, 1) }, uniquingKeysWith: +)
        }
        func reserve(_ item: TranscriptItem, in lane: SendMode, from slots: inout [Slot: Int]) -> Bool {
            let slot = Slot(lane: lane, text: item.text)
            let count = slots[slot, default: 0]
            guard count > 0 else { return false }
            slots[slot] = count - 1
            return true
        }

        let queued = transcript.filter { $0.delivery == .queued }
        let current = counts(next)
        var remaining = current
        // The acknowledgement can overtake older snapshots. Only a row already
        // observed in the queue can be consumed. Identical entries leave FIFO.
        let consumed = Array(queued.reversed().filter { item in
            guard let lane = item.observedQueueLane else { return false }
            return !reserve(item, in: lane, from: &remaining)
        }.reversed())
        for item in consumed { item.delivery = .accepted }
        awaitingUserStarts.append(contentsOf: consumed)
        startDequeuedFollowUp(consumed)

        let earlier = counts(previous)
        var added = current
        for (slot, count) in earlier {
            added[slot] = max(0, added[slot, default: 0] - count)
        }
        let unobserved = queued.filter { $0.observedQueueLane == nil }
        for item in unobserved {
            guard let lane = item.submission?.mode, reserve(item, in: lane, from: &added) else { continue }
            item.observedQueueLane = lane
        }
        if let pending = sendingSubmission, pending.delivery == .pending,
           let lane = pending.submission?.mode, reserve(pending, in: lane, from: &added) {
            pending.observedQueueLane = lane
            pending.delivery = .queued
            if startingSubmission === pending { startingSubmission = nil }
        }
        // Preserve cross-lane matching for acknowledged inputs.
        for item in unobserved where item.observedQueueLane == nil {
            guard let mode = item.submission?.mode else { continue }
            let lane: SendMode = mode == .steer ? .followUp : .steer
            if reserve(item, in: lane, from: &added) { item.observedQueueLane = lane }
        }
    }

    private func recordUserStart(timestamp: Int64, text: String?) {
        guard connection == .connected, phase != .uncertain else { return }
        let sender: TranscriptItem
        var dequeued = false
        if !awaitingUserStarts.isEmpty {
            let matches = awaitingUserStarts.indices.filter { text == nil || awaitingUserStarts[$0].text == text }
            guard let first = matches.first else { return }
            // Equal payloads in one lane are consumed FIFO. Across lanes the queue snapshot alone cannot disambiguate them.
            guard matches.count == 1 || (text != nil && matches.allSatisfy {
                awaitingUserStarts[$0].submission?.mode == awaitingUserStarts[first].submission?.mode
            }) else { return }
            sender = awaitingUserStarts.remove(at: first)
            dequeued = true
        } else if !activeTurnHasVisibleOutput, let starting = activeTurnUser ?? startingSubmission,
                  starting.delivery != .queued, starting.messageTimestampMs == nil, text == nil || starting.text == text {
            sender = starting
        } else if isStopping {
            // An empty queue snapshot during stop can hide a final pre-stop dequeue until its user start arrives.
            let queued = transcript.filter {
                $0.kind == .user && $0.delivery == .queued && $0.messageTimestampMs == nil
                    && (text == nil || $0.text == text)
            }
            let preferred = queued.filter { $0.observedQueueLane != nil }
            let candidates = preferred.isEmpty ? queued : preferred
            guard let first = candidates.first else { return }
            guard candidates.count == 1 || (text != nil && candidates.allSatisfy {
                $0.submission?.mode == first.submission?.mode
            }) else { return }
            first.delivery = .accepted
            sender = first
            dequeued = true
        } else {
            return
        }
        if dequeued && activeTurnHasVisibleOutput { startDequeuedFollowUp([sender]) }
        guard sender.messageTimestampMs == nil, let promptID = sender.submission?.id else { return }
        sender.messageTimestampMs = timestamp
        if activeTurnUser === sender { activeTurn?.anchorUserTimestampMs = timestamp }
        onUserMessageTimestamp?(promptID, timestamp)
    }

    private func recoverQueuedDrafts(_ drafts: [PendingPrompt]) -> [PendingPrompt] {
        struct Slot: Hashable {
            let mode: SendMode
            let text: String
        }
        var exactCounts: [Slot: Int] = [:]
        for draft in drafts { exactCounts[Slot(mode: draft.mode, text: draft.text), default: 0] += 1 }
        // When the runtime drains its FIFO queue, the remaining entries are the trailing ones.
        var claimedIDs = Set<String>()
        var exactMatches: [Slot: [TranscriptItem]] = [:]
        for item in transcript.reversed() where item.kind == .user && item.delivery == .queued {
            guard let mode = item.submission?.mode else { continue }
            let slot = Slot(mode: mode, text: item.text)
            let needed = exactCounts[slot, default: 0]
            guard needed > 0 else { continue }
            exactCounts[slot] = needed - 1
            claimedIDs.insert(item.id)
            exactMatches[slot, default: []].append(item)
        }
        for key in exactMatches.keys { exactMatches[key]?.reverse() }

        var matchedRows: [Int: TranscriptItem] = [:]
        var unmatchedIndices: [Int] = []
        var pendingAvailable = sendingSubmission.flatMap { $0.delivery == .pending ? $0 : nil }
        for (index, draft) in drafts.enumerated() {
            let slot = Slot(mode: draft.mode, text: draft.text)
            if var list = exactMatches[slot], !list.isEmpty {
                matchedRows[index] = list.removeFirst()
                exactMatches[slot] = list
            } else if let pending = pendingAvailable,
                      pending.submission?.mode == draft.mode, pending.text == draft.text {
                matchedRows[index] = pending
                pendingAvailable = nil
            } else {
                unmatchedIndices.append(index)
            }
        }

        if !unmatchedIndices.isEmpty {
            var crossCounts: [String: Int] = [:]
            for index in unmatchedIndices { crossCounts[drafts[index].text, default: 0] += 1 }
            var crossMatches: [String: [TranscriptItem]] = [:]
            for item in transcript.reversed() where item.kind == .user && item.delivery == .queued && !claimedIDs.contains(item.id) {
                let needed = crossCounts[item.text, default: 0]
                guard needed > 0 else { continue }
                crossCounts[item.text] = needed - 1
                claimedIDs.insert(item.id)
                crossMatches[item.text, default: []].append(item)
            }
            for key in crossMatches.keys { crossMatches[key]?.reverse() }
            for index in unmatchedIndices {
                let text = drafts[index].text
                if var list = crossMatches[text], !list.isEmpty {
                    matchedRows[index] = list.removeFirst()
                    crossMatches[text] = list
                }
            }
        }

        return drafts.enumerated().map { index, draft in
            guard let row = matchedRows[index] else { return draft }
            row.delivery = .recovered
            if let prompt = row.submission {
                return .init(id: prompt.id, text: prompt.text, mode: draft.mode, files: prompt.files)
            }
            return draft
        }
    }

    private func finishRound(status: TurnStatus, confirmedEndTime: Bool) {
        guard let turn = activeTurn else { return }
        turn.status = status
        turn.thoughtText = ""
        if confirmedEndTime {
            let endedAt = clock.now()
            turn.endedAt = endedAt
            turn.durationSeconds = turn.elapsedTime(at: endedAt, monotonicNow: clock.monotonicNow())
        } else {
            turn.endedAt = nil
            turn.durationSeconds = nil
        }
        if status == .failed, failure?.kind == .model {
            failedModelInput = activeTurnUser
        }
        activeTurn = nil
        activeTurnUser = nil
        activeTurnHadFailure = false
        activeTurnHasVisibleOutput = false
        onTurnFinished?(turn)
    }
    /// Public for deterministic contract tests; every event carries its origin.
    public func receive(_ envelope: RuntimeEnvelope) {
        guard envelope.instanceID == instance else { return }
        switch envelope.event {
        case .promptAcceptance(let id, let acceptance):
            resolveRuntimeAcceptance(id, as: acceptance)
        case .promptConfirmed(let id):
            if let prompt = rowsByID["user:\(id)"]?.submission { onPromptConfirmed?(prompt) }
        case .batch(let events):
            for event in events { receive(.init(instanceID: envelope.instanceID, event: event)) }
            return
        case .phase(let phase):
            if !interactions.isEmpty && phase != .stopping { phaseBeforeWaiting = phase }
            else if self.phase != .stopping || phase == .stopping { self.phase = phase }
            if phase == .running { startRound() }
            if phase == .running || phase == .compacting { usageStale = true }
            if phase == .compacting {
                usageGeneration = UUID()
                let window = usage?.context?.window
                usage?.context = .init(window: window)
            }
        case .runStarted:
            startRound()
        case .userMessageTimestamp(let ts, let text):
            recordUserStart(timestamp: ts, text: text)
        case .assistantStarted(let id):
            awaitingUserStarts.removeAll()
            startRound()
            confirmTurnModel()
            if rowsByID["assistant:\(id)"] == nil {
                append(.init(id: "assistant:\(id)", kind: .assistant, streaming: true, turn: activeTurn))
                activeTurnHasVisibleOutput = true
            }
        case .assistantTimestamp(let id, let ms):
            if let turn = rowsByID["assistant:\(id)"]?.turn ?? activeTurn {
                if turn.anchorAssistantTimestampMs == nil { turn.anchorAssistantTimestampMs = ms }
                turn.endAssistantTimestampMs = ms
            }
        case .textDelta(let id, let index, let delta): rowsByID["assistant:\(id)"]?.append(index: index, delta: delta)
        case .assistantCompleted(let id, let text):
            awaitingUserStarts.removeAll()
            let key = "assistant:\(id)"
            if text.isEmpty { transcript.removeAll { $0.id == key }; rowsByID.removeValue(forKey: key) }
            else if let item = rowsByID[key] {
                confirmTurnModel()
                item.text = text; item.streaming = false; activeTurnHasVisibleOutput = true
            }
            else {
                startRound()
                confirmTurnModel()
                append(.init(id: key, kind: .assistant, text: text, turn: activeTurn))
                activeTurnHasVisibleOutput = true
            }
        case .assistantAttemptFailed(let id, let failure):
            startRound()
            let key = "assistant-attempt-failed:\(id)"
            if rowsByID[key] == nil {
                append(.init(id: key, kind: .notice, text: failure.detail, turn: activeTurn))
                activeTurnHasVisibleOutput = true
            }
        case .tool(let tool):
            startRound()
            confirmTurnModel()
            if let activeTurn, activeTurn.anchorToolCallID == nil { activeTurn.anchorToolCallID = tool.id }
            activeTurnHasVisibleOutput = true
            let key = "tool:\(tool.id)"
            if let row = rowsByID[key] { if row.tool != tool { row.tool = tool } }
            else { append(.init(id: key, kind: .tool, tool: tool, turn: activeTurn)) }
        case .thought(let text):
            if let text, !text.isEmpty {
                startRound()
                confirmTurnModel()
                activeTurn?.thoughtText = text
            } else {
                activeTurn?.thoughtText = ""
            }
        case .plan(let entries):
            plan = entries
        case .queue(let queue):
            updateQueue(queue)
        case .turnFileChanges(let changes):
            activeTurn?.fileChanges = changes
        case .settled(let aborted):
            awaitingUserStarts.removeAll()
            settledCounter += 1; phaseBeforeWaiting = .idle; phase = interactions.isEmpty ? .idle : .waitingInput
            let status: TurnStatus = aborted ? .stopped : (activeTurnHadFailure ? .failed : .completed)
            finishRound(status: status, confirmedEndTime: true)
            interruptUnfinished(); scheduleUsage()
        case .recoveredDrafts(let operation, let drafts):
            if recoveredOperations.insert(operation).inserted {
                recoveredDrafts.append(contentsOf: recoverQueuedDrafts(drafts))
            }
        case .notice(let text): notice = text
        case .failure(let failure):
            self.failure = failure
            activeTurnHadFailure = true
            if failure.kind.leavesTurnOutcomeUnknown {
                phase = .uncertain
                awaitingUserStarts.removeAll()
                finishRound(status: .uncertain, confirmedEndTime: false)
                interruptUnfinished()
            }
        case .disconnected(let confirmed):
            markPendingHandoffUnknown()
            awaitingUserStarts.removeAll()
            connection = confirmed ? .disconnected : .blocked
            phase = .uncertain; queueIsKnown = false; interactions = []; usageStale = true; usageGeneration = UUID(); usageLoading = false
            finishRound(status: .uncertain, confirmedEndTime: false)
            interruptUnfinished()
        case .interaction(let request):
            guard request.instanceID == instance, !interactions.contains(where: { $0.id == request.id }) else { return }
            if interactions.isEmpty { phaseBeforeWaiting = phase }
            interactions.append(request)
            if phase != .stopping {
                phase = .waitingInput
                if request.isPermissionApproval { onApprovalRequested?(request) }
            }
        case .interactionUpdated(let request):
            guard request.instanceID == instance, request.isPermissionApproval,
                  let index = interactions.firstIndex(where: { $0.id == request.id }),
                  interactions[index].permissionContext?.awaitingToolDetails == true else { return }
            interactions[index] = request
        case .interactionEnded(let id, let reason):
            if reason == .expired, let request = interactions.first(where: { $0.id == id }) {
                // Record the request, not any prefilled or user-entered reply.
                let expired = RuntimeInteraction(instanceID: request.instanceID, requestID: request.requestID,
                                                 kind: request.kind, title: request.title, message: request.message,
                                                 options: request.options, expiresAt: request.expiresAt,
                                                 createdAt: request.createdAt,
                                                 toolApproval: request.toolApproval,
                                                 permissionOptions: request.permissionOptions,
                                                 permissionContext: request.permissionContext)
                let summary = Self.expiredInteractionNotice
                append(.init(id: Self.expiryRowID(id), kind: .notice, text: "\(summary) \(request.title)",
                             turn: activeTurn, expiredInteraction: expired))
                notice = summary
            }
            interactions.removeAll { $0.id == id }
            if interactions.isEmpty && phase == .waitingInput { phase = phaseBeforeWaiting }
        case .suggestedDraft(let text):
            recoveredDrafts.append(.init(text: text, mode: .steer)); notice = String(localized: "扩展提供的输入已保留为草稿，没有覆盖编辑框。", bundle: #bundle)
        case .extensionStatus(let key, let value):
            if value == nil { extensionStatus.removeValue(forKey: key) }
            else if extensionStatus.count < 32 || extensionStatus[key] != nil { extensionStatus[key] = value }
        case .sessionUpdated(let updated):
            session = updated
        case .historyReplayed(let items):
            // Replay from session/load replaces any offline display cache without triggering live turn notifications.
            guard !receivedHistoryReplay, activeTurn == nil, !items.isEmpty else { return }
            receivedHistoryReplay = true
            let rows = historyRows(items, defaultFallbackStatus: .completed)
            if let cached = pendingReplayMetadata {
                Self.restoreReplayMetadata(from: cached, recordedMessages: pendingReplayRecordedMessages, onto: rows)
                pendingReplayMetadata = nil
            }
            Self.applyRecordedMetadata(recordedTurns: pendingReplayRecordedTurns,
                                       recordedMessages: pendingReplayRecordedMessages,
                                       onto: rows)
            pendingReplayRecordedTurns = []
            pendingReplayRecordedMessages = []
            rowsByID = [:]
            for row in rows { rowsByID[row.id] = row }
            transcript = rows
            transcriptTurnStarts = []
            toolFailureTurnID = nil
            dismissedToolFailureIDs.removeAll()
            showingCachedHistory = false
            cachedHistoryNotice = nil
        case .usageUpdated(let updated):
            if session == nil || updated.sessionID == session?.id {
                usage = updated
                usageStale = phase != .idle
                usageNotice = nil
            }
        }
        switch envelope.event {
        case .phase, .queue, .settled, .recoveredDrafts, .failure, .disconnected, .interaction, .interactionUpdated, .interactionEnded, .suggestedDraft, .sessionUpdated, .historyReplayed: onControlChanged?()
        default: break
        }
    }

    private static func replaySegments(from rows: [TranscriptItem]) -> [ReplaySegmentMetadata] {
        var segments: [ReplaySegmentMetadata] = []
        var currentUserText: String?
        var currentSubmissionID: UUID?
        var currentSentAt: Date?
        var currentFiles: [URL] = []
        var currentOriginalText: String?
        var currentTurn: TurnRecord?
        var hasContent = false

        func flush() {
            guard hasContent else { return }
            segments.append(.init(
                userText: currentUserText,
                submissionID: currentSubmissionID,
                sentAt: currentSentAt,
                attachedFiles: currentFiles,
                originalText: currentOriginalText,
                startedAt: currentTurn?.startedAt,
                endedAt: currentTurn?.endedAt,
                durationSeconds: currentTurn?.durationSeconds
            ))
            currentUserText = nil
            currentSubmissionID = nil
            currentSentAt = nil
            currentFiles = []
            currentOriginalText = nil
            currentTurn = nil
            hasContent = false
        }

        for row in rows {
            if row.kind == .user {
                flush()
                currentUserText = row.editableText
                currentSubmissionID = row.submissionID
                currentSentAt = row.sentAt
                currentFiles = row.attachedFiles
                currentOriginalText = row.originalText
                hasContent = true
            } else {
                hasContent = true
                if let turn = row.turn {
                    currentTurn = turn
                }
            }
        }
        flush()
        return segments
    }

    private static func restoreReplayMetadata(from cached: [ReplaySegmentMetadata],
                                              recordedMessages: [RecordedMessageRecord], onto rows: [TranscriptItem]) {
        guard !cached.isEmpty, !rows.isEmpty else { return }
        struct TargetSegment {
            let userText: String?
            let userRow: TranscriptItem?
            var turns: [TurnRecord]
        }
        var targets: [TargetSegment] = []
        var current: TargetSegment?

        func flush() {
            if let current { targets.append(current) }
        }
        for row in rows {
            if row.kind == .user {
                flush()
                current = TargetSegment(userText: row.editableText, userRow: row, turns: [])
            } else {
                if current == nil {
                    current = TargetSegment(userText: nil, userRow: nil, turns: [])
                }
                if let turn = row.turn, !targets.contains(where: { $0.turns.contains { $0 === turn } }),
                   current?.turns.contains(where: { $0 === turn }) != true {
                    current?.turns.append(turn)
                }
            }
        }
        flush()

        let handoffMessages = Dictionary(recordedMessages.compactMap { record in
            record.handoffContext.map { context in
                (record.id, UserPrompt(text: record.text, files: record.files ?? [], handoffContext: context))
            }
        }, uniquingKeysWith: { _, latest in latest })

        func matchesUser(_ source: ReplaySegmentMetadata, _ target: TargetSegment) -> Bool {
            guard let sourceText = source.userText else { return true }
            if let id = target.userRow?.submissionID, let cachedID = source.submissionID, id != cachedID { return false }
            if sourceText == target.userText { return true }
            if let id = source.submissionID, let prompt = handoffMessages[id],
               target.userText == prompt.messageText || target.userText == prompt.runtimeText { return true }
            if !source.attachedFiles.isEmpty {
                let prompt = UserPrompt(text: sourceText, files: source.attachedFiles)
                if prompt.runtimeText == target.userText { return true }
                if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && target.userText == "请查看以下图片。" {
                    return true
                }
            }
            return false
        }

        func apply(_ source: ReplaySegmentMetadata, to target: TargetSegment) {
            if let userRow = target.userRow {
                if userRow.sentAt == nil { userRow.sentAt = source.sentAt }
                if userRow.attachedFiles.isEmpty && !source.attachedFiles.isEmpty {
                    userRow.attachedFiles = source.attachedFiles
                    userRow.originalText = source.originalText ?? source.userText
                }
            }
            for turn in target.turns {
                if turn.startedAt == nil { turn.startedAt = source.startedAt }
                if turn.endedAt == nil { turn.endedAt = source.endedAt }
                if turn.durationSeconds == nil { turn.durationSeconds = source.durationSeconds }
            }
        }

        let cachedUsers = cached.filter { $0.userText != nil }
        let replayedUsers = targets.filter { $0.userRow != nil }
        let overlap = min(cachedUsers.count, replayedUsers.count)
        let cachedStart = cachedUsers.count - overlap
        let replayedStart = replayedUsers.count - overlap
        let cachedTail = cachedUsers.suffix(overlap)
        let replayedTail = replayedUsers.suffix(overlap)
        // Carry confirmed IDs through a unique ordered overlap. A repeated prompt at
        // the clipped boundary can belong to either side, even when the rest aligns.
        if let first = cachedTail.first,
           cachedTail.contains(where: { $0.userText != first.userText }),
           cachedTail.contains(where: { $0.submissionID != nil }),
           zip(cachedTail, replayedTail).allSatisfy({ matchesUser($0, $1) }),
           !(0..<cachedStart).contains(where: { start in
               zip(cachedUsers[start...], replayedTail).allSatisfy { matchesUser($0, $1) }
           }),
           !(0..<replayedStart).contains(where: { start in
               zip(cachedTail, replayedUsers[start...]).allSatisfy { matchesUser($0, $1) }
           }) {
            var ambiguousBoundary = (cachedStart > 0 && matchesUser(cachedUsers[cachedStart - 1], replayedUsers[replayedStart])) ||
                (replayedStart > 0 && matchesUser(first, replayedUsers[replayedStart - 1]))
            for (source, target) in zip(cachedTail, replayedTail) {
                if !matchesUser(first, target) { ambiguousBoundary = false }
                if !ambiguousBoundary, let row = target.userRow, row.submissionID == nil {
                    row.recordedSubmissionID = source.submissionID
                }
            }
        }

        // Cache keeps only the trailing items, so align trailing segments first when user prompts match.
        if cached.count <= targets.count {
            let suffix = Array(targets.suffix(cached.count))
            let aligned = zip(cached, suffix).allSatisfy { matchesUser($0, $1) }
            if aligned {
                for (source, target) in zip(cached, suffix) {
                    apply(source, to: target)
                }
                return
            }
        }

        var cursor = 0
        for source in cached {
            guard let text = source.userText, !text.isEmpty || !source.attachedFiles.isEmpty else { continue }
            if let match = targets[cursor...].firstIndex(where: { matchesUser(source, $0) }) {
                apply(source, to: targets[match])
                cursor = match + 1
            }
        }
    }

    private static func applyRecordedMetadata(recordedTurns: [RecordedTurnRecord],
                                              recordedMessages: [RecordedMessageRecord],
                                              modelTurns: [RecordedTurnRecord]? = nil,
                                              handoffAndModelMessagesOnly: Bool = false,
                                              onto rows: [TranscriptItem]) {
        guard !rows.isEmpty else { return }
        let modelChanges = Dictionary((modelTurns ?? recordedTurns).compactMap { record in
            record.modelSubmissionID.flatMap { id in record.modelChange.map { (id, $0) } }
        }, uniquingKeysWith: { _, latest in latest })
        let messages = handoffAndModelMessagesOnly
            ? recordedMessages.filter { $0.handoffContext != nil || modelChanges[$0.id] != nil }
            : recordedMessages

        if !messages.isEmpty {
            let userRows = rows.filter { $0.kind == .user }
            let knownIDs = Dictionary(uniqueKeysWithValues: userRows.compactMap { row -> (ObjectIdentifier, UUID)? in
                let id = row.submissionID ?? (row.id.hasPrefix("user:") ? UUID(uuidString: String(row.id.dropFirst(5))) : nil)
                return id.map { (ObjectIdentifier(row), $0) }
            })
            func matchesMessage(_ record: RecordedMessageRecord, _ row: TranscriptItem) -> Bool {
                if let localID = knownIDs[ObjectIdentifier(row)] { return localID == record.id }
                if let recordedTime = record.messageTimestampMs, let replayTime = row.messageTimestampMs,
                   recordedTime != replayTime { return false }
                let rowText = row.text
                let files = record.files ?? []
                if let context = record.handoffContext {
                    let prompt = UserPrompt(text: record.text, files: files, handoffContext: context)
                    let message = prompt.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if rowText == prompt.runtimeText || rowText == message ||
                        rowText.hasPrefix(message + "\n\n本地文件引用（按需读取）\n") { return true }
                }
                if rowText == record.text { return true }
                let trimmed = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, rowText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { return true }
                if !files.isEmpty {
                    if UserPrompt(text: record.text, files: files).runtimeText == rowText { return true }
                    if trimmed.isEmpty && rowText == "请查看以下图片。" { return true }
                }
                return false
            }
            func applyMessage(_ record: RecordedMessageRecord, to row: TranscriptItem, alignedSequence: Bool = false) {
                let modelChange = modelChanges[record.id]
                let anchorsEvent = modelChange != nil || record.handoffContext != nil
                // Only persist a replay association backed by an ID, a complete
                // ordered sequence, or an unambiguous match for an event anchor.
                if knownIDs[ObjectIdentifier(row)] == record.id || alignedSequence ||
                    (anchorsEvent && userRows.lazy.filter { matchesMessage(record, $0) }.prefix(2).count == 1 &&
                     recordedMessages.lazy.filter { matchesMessage($0, row) }.prefix(2).count == 1) {
                    row.recordedSubmissionID = record.id
                    if let modelChange { row.modelChange = modelChange }
                }
                if handoffAndModelMessagesOnly, record.handoffContext == nil { return }
                if row.sentAt == nil { row.sentAt = record.sentAt }
                if record.handoffContext != nil { row.originalText = record.text }
                if row.attachedFiles.isEmpty, let files = record.files, !files.isEmpty {
                    row.attachedFiles = files
                    row.originalText = record.text
                }
            }

            if recordedMessages.count == userRows.count,
               zip(recordedMessages, userRows).allSatisfy({ matchesMessage($0, $1) }) {
                for (record, row) in zip(recordedMessages, userRows) {
                    applyMessage(record, to: row, alignedSequence: true)
                }
            } else if messages.count <= userRows.count {
                let suffix = Array(userRows.suffix(messages.count))
                if zip(messages, suffix).allSatisfy({ matchesMessage($0, $1) }) {
                    for (record, row) in zip(messages, suffix) {
                        applyMessage(record, to: row)
                    }
                } else {
                    var cursor = 0
                    for record in messages {
                        if let match = userRows[cursor...].firstIndex(where: { matchesMessage(record, $0) }) {
                            applyMessage(record, to: userRows[match])
                            cursor = match + 1
                        }
                    }
                }
            } else {
                var cursor = 0
                for row in userRows {
                    if let match = messages[cursor...].firstIndex(where: { matchesMessage($0, row) }) {
                        applyMessage(messages[match], to: row)
                        cursor = match + 1
                    }
                }
            }
        }

        guard !recordedTurns.isEmpty else { return }
        struct TurnSegment {
            var toolIDs: Set<String> = []
            var turns: [TurnRecord] = []
        }
        var segments: [TurnSegment] = []
        var current: TurnSegment?
        func flushSegment() {
            if let current, !current.turns.isEmpty { segments.append(current) }
            current = nil
        }
        for row in rows {
            if row.kind == .user {
                flushSegment()
            } else if row.kind == .assistant || row.kind == .tool {
                if current == nil { current = TurnSegment() }
                if let toolID = row.tool?.id { current?.toolIDs.insert(toolID) }
                if let turn = row.turn, current?.turns.contains(where: { $0 === turn }) != true {
                    current?.turns.append(turn)
                }
            }
        }
        flushSegment()
        guard !segments.isEmpty else { return }

        func applyTurn(_ record: RecordedTurnRecord, to segment: TurnSegment) {
            for turn in segment.turns {
                if turn.startedAt == nil { turn.startedAt = record.startedAt }
                if turn.endedAt == nil { turn.endedAt = record.endedAt }
                if turn.durationSeconds == nil { turn.durationSeconds = record.durationSeconds }
                if turn.fileChanges == nil { turn.fileChanges = record.fileChanges }
            }
        }

        var usedSegments = Set<Int>()
        var usedRecords = Set<Int>()
        for (rIndex, record) in recordedTurns.enumerated() {
            guard let anchorTool = record.anchorToolCallID else { continue }
            let matches = segments.indices.filter { !usedSegments.contains($0) && segments[$0].toolIDs.contains(anchorTool) }
            if matches.count == 1, let sIndex = matches.first {
                applyTurn(record, to: segments[sIndex])
                usedSegments.insert(sIndex)
                usedRecords.insert(rIndex)
            }
        }

        let remainingSegments = segments.indices.filter { !usedSegments.contains($0) }
        let remainingRecords = recordedTurns.indices.filter { !usedRecords.contains($0) }
        let count = min(remainingSegments.count, remainingRecords.count)
        if count > 0 {
            for (sIndex, rIndex) in zip(remainingSegments.suffix(count), remainingRecords.suffix(count)) {
                applyTurn(recordedTurns[rIndex], to: segments[sIndex])
            }
        }
    }
}
