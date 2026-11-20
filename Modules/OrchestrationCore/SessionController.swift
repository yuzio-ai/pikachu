import Foundation
import Observation
import AgentRuntimeCore

public enum ConnectionState: String, Sendable { case disconnected, connecting, connected, closing, blocked }
public enum TranscriptKind: Sendable { case user, assistant, tool, notice }
public enum DeliveryState: String, Sendable, Codable { case pending, accepted, queued, recovered, handled, rejected, unknown }

@MainActor @Observable public final class TurnRecord: Identifiable {
    public let id: UUID
    let displayID: String
    public var status: TurnStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: TimeInterval?
    public var anchorAssistantTimestampMs: Int64?
    public var endAssistantTimestampMs: Int64?
    public var anchorToolCallID: String?
    public var anchorUserTimestampMs: Int64?
    public var fileChanges: TurnFileChanges?
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
    public let originalText: String?
    public let attachedFiles: [URL]
    public let expiredInteraction: RuntimeInteraction?
    let submission: UserPrompt?
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
    public private(set) var queue = RuntimeQueue()
    public private(set) var queueIsKnown = true
    public private(set) var recoveredDrafts: [PendingPrompt] = []
    public private(set) var failure: RuntimeFailure?
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
    public var draft = "" { didSet { if draft != oldValue { (onDraftEdited ?? onControlChanged)?() } } }
    public var draftFiles: [URL] = [] { didSet { if draftFiles != oldValue { (onDraftEdited ?? onControlChanged)?() } } }
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
    @ObservationIgnored var onApprovalRequested: (@MainActor (RuntimeInteraction) -> Void)?
    @ObservationIgnored public var onUserMessageTimestamp: (@MainActor (UUID?, Int64) -> Void)?
    @ObservationIgnored private var runtime: (any AgentRuntime)?
    @ObservationIgnored private var instance: UUID?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var recoveredOperations = Set<UUID>()
    @ObservationIgnored private var settledCounter = 0
    @ObservationIgnored private var rowsByID: [String: TranscriptItem] = [:]
    private var acceptsInput: Bool {
        connection == .connected && !commandPending && phase != .uncertain && phase != .stopping && phase != .waitingInput
    }
    public var canSend: Bool {
        acceptsInput && draftPrompt.hasContent
    }
    public var draftPrompt: UserPrompt { .init(text: draft, mode: mode, files: draftFiles) }
    func matchesDraft(_ prompt: UserPrompt) -> Bool { draft == prompt.text && draftFiles == prompt.files && mode == prompt.mode }
    public var canStop: Bool { connection == .connected && !stopPending && (!regularPending || !interactions.isEmpty) && (phase.isActive || !queue.isEmpty) }
    public var canConnect: Bool { connection == .disconnected && !commandPending }
    public init(clock: any RuntimeClock = SystemRuntimeClock()) { self.clock = clock }
    public func connect(_ newRuntime: any AgentRuntime, history: [HistoryItem] = [], turns: [HistoryTurnInfo] = [], recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) async {
        guard canConnect else { return }
        regularPending = true; connection = .connecting; failure = nil; notice = nil
        instance = nil
        if let runtime {
            do { try await runtime.close(force: true) }
            catch { failure = .init(.supervision, String(localized: "上一执行实例的清理未确认，不能建立新连接。", bundle: #bundle)); connection = .blocked; regularPending = false; return }
        }
        consumer?.cancel()
        runtime = newRuntime; instance = newRuntime.instanceID
        transcript = []; transcriptTurnStarts = []; rowsByID = [:]; queue = .init(); queueIsKnown = true; phase = .idle; session = nil
        activeTurn = nil; activeTurnUser = nil; startingSubmission = nil
        sendingSubmission = nil; awaitingUserStarts = []
        activeTurnHadFailure = false; activeTurnHasVisibleOutput = false
        interactions = []; extensionStatus = [:]; usage = nil; usageStale = true; usageLoading = false; usageGeneration = UUID()
        seedHistory(history, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        consumer = Task { [weak self] in
            for await envelope in newRuntime.events {
                guard !Task.isCancelled else { return }
                self?.receive(envelope)
                if case .batch = envelope.event { try? await Task.sleep(for: .milliseconds(1)) }
            }
            guard !Task.isCancelled, let self, self.instance == newRuntime.instanceID,
                  self.connection == .connected || self.connection == .connecting else { return }
            self.failure = .init(.connection, String(localized: "运行时事件流意外结束，进程清理尚未确认。", bundle: #bundle))
            self.connection = .blocked; self.phase = .uncertain; self.finishRound(status: .uncertain, confirmedEndTime: false); self.interruptUnfinished()
            self.onControlChanged?()
        }
        do {
            let opened = try await newRuntime.connect()
            guard connection == .connecting else { throw RuntimeFailure(.connection, String(localized: "连接在启动期间中断。", bundle: #bundle)) }
            session = opened; connection = .connected
        } catch {
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
        if phase == .idle && activeTurn == nil && queue.isEmpty { startingSubmission = item }
        if matchesDraft(prompt) { draft = ""; draftFiles = [] }
        failure = nil
        let before = settledCounter
        do {
            let disposition = try await runtime.send(prompt)
            switch disposition {
            case .started where item.delivery != .recovered:
                item.delivery = .accepted
                if instance == origin && settledCounter == before && !isStopping {
                    if phase == .idle { phase = .running }
                    startRound(startingWith: item)
                }
            case .queued:
                // Ordered queue events may already have moved this input on.
                if item.delivery == .pending { item.delivery = .queued }
            case .handled where item.delivery == .pending: item.delivery = .handled
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
        await resolveSubmission?(prompt.id, item.delivery)
        onControlChanged?()
    }
    public func stop() async {
        guard canStop, let runtime else { return }
        stopPending = true; phase = .stopping
        do {
            try await runtime.stop()
            let until = Date().addingTimeInterval(2)
            let receivesFileChanges = session?.capabilities.contains(.turnFileChanges) == true
            // Pi may acknowledge abort before its final checkpoint reaches the controller.
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
            connection = .disconnected; phase = .idle; queue = .init(); queueIsKnown = true
            consumer?.cancel(); self.runtime = nil; instance = nil
            interactions = []; usageTask?.cancel(); usageGeneration = UUID(); usageStale = true
            finishRound(status: .uncertain, confirmedEndTime: false)
            interruptUnfinished()
            regularPending = false; onControlChanged?(); return true
        } catch {
            failure = (error as? RuntimeFailure) ?? .init(.supervision, String(localized: "进程清理尚未确认，不能继续执行。", bundle: #bundle))
            connection = .blocked; phase = .uncertain
            finishRound(status: .uncertain, confirmedEndTime: false)
            regularPending = false; onControlChanged?(); return false
        }
    }
    public func restoreDraft(_ id: UUID) {
        guard let index = recoveredDrafts.firstIndex(where: { $0.id == id }) else { return }
        mergeIntoDraft(recoveredDrafts.remove(at: index))
    }
    func mergeIntoDraft(_ recovered: PendingPrompt) {
        if !recovered.text.isEmpty { draft = draft.isEmpty ? recovered.text : draft + "\n\n" + recovered.text }
        for file in recovered.files ?? [] where !draftFiles.contains(file) { draftFiles.append(file) }
        mode = recovered.mode
        onControlChanged?()
    }
    public func restoreLocalState(draft: String, mode: SendMode, recovered: [PendingPrompt], files: [URL] = []) {
        self.draft = draft; self.mode = mode; recoveredDrafts = recovered; draftFiles = files
        onControlChanged?()
    }
    public func showHistory(_ items: [HistoryItem], usage: RuntimeUsage? = nil, turns: [HistoryTurnInfo] = [],
                            recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) {
        guard connection == .disconnected else { return }
        let rows = historyRows(items, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        rowsByID = [:]
        for row in rows { rowsByID[row.id] = row }
        transcript = rows
        transcriptTurnStarts = []
        self.usage = usage; usageStale = false
    }
    private func seedHistory(_ items: [HistoryItem], turns: [HistoryTurnInfo] = [],
                             recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) {
        let rows = historyRows(items, turns: turns, recordedTurns: recordedTurns, recordedMessages: recordedMessages)
        for row in rows { rowsByID[row.id] = row }
        transcript.append(contentsOf: rows)
    }
    private func historyRows(_ items: [HistoryItem], turns: [HistoryTurnInfo] = [],
                             recordedTurns: [RecordedTurnRecord] = [], recordedMessages: [RecordedMessageRecord] = []) -> [TranscriptItem] {
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
            UserPrompt(text: record.text, files: record.files ?? []).runtimeText == user.text
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
                return TranscriptItem(
                    id: item.id,
                    kind: kind,
                    text: item.text,
                    sentAt: item.sentAt ?? matchedMessage?.sentAt,
                    messageTimestampMs: item.messageTimestampMs,
                    turn: turnByUserID[item.id],
                    originalText: matchedMessage?.text ?? item.text,
                    attachedFiles: matchedMessage?.files ?? []
                )
            }
            let assignedTurn: TurnRecord?
            if kind == .assistant || kind == .tool {
                if let known = turnByItemID[item.id] {
                    assignedTurn = known
                    fallbackTurn = nil
                } else {
                    if fallbackTurn == nil { fallbackTurn = TurnRecord(status: .uncertain, displayID: item.id) }
                    assignedTurn = fallbackTurn
                }
            } else {
                assignedTurn = nil
            }
            return TranscriptItem(id: item.id, kind: kind, text: item.text, tool: item.tool, turn: assignedTurn)
        }
    }
    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        guard connection == .connected, let runtime else { throw RuntimeFailure(.setup, String(localized: "会话尚未连接。", bundle: #bundle)) }
        let source = runtime.instanceID
        runtimeReads += 1; onRuntimeActivityChanged?()
        defer { runtimeReads -= 1; onRuntimeActivityChanged?() }
        let options = try await runtime.configurationOptions()
        guard connection == .connected, instance == source else { throw RuntimeFailure(.connection, String(localized: "会话连接已变化，请重试模型查询。", bundle: #bundle)) }
        return options
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
    public var noticeExcludingExpiredInteraction: String? {
        notice == Self.expiredInteractionNotice ? nil : notice
    }

    public func clearNotice() { notice = nil }

    private static var expiredInteractionNotice: String {
        String(localized: "扩展交互已过期，未提交过期回复。", bundle: #bundle)
    }
    public func didExpire(_ request: RuntimeInteraction) -> Bool {
        // The lookup index itself is not observable; the transcript publishes new rows.
        _ = transcript
        return rowsByID[Self.expiryRowID(request.id)]?.expiredInteraction?.instanceID == request.instanceID
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
        rowsByID[item.id] = item
        transcript.append(item)
    }
    private func interruptUnfinished() {
        for item in transcript {
            item.streaming = false
            if item.tool?.state == .running { item.tool?.state = .interrupted }
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
                    if start.precedingItemID != user.id {
                        transcriptTurnStarts[last] = .init(turn: turn, precedingItemID: user.id)
                    }
                }
            }
            return
        }
        let turn = TurnRecord(id: UUID(), status: .running, startedAt: clock.now(), monotonicStart: clock.monotonicNow())
        turn.anchorUserTimestampMs = user?.messageTimestampMs
        activeTurn = turn
        activeTurnUser = user
        activeTurnHadFailure = false
        activeTurnHasVisibleOutput = false
        // A queued user message may precede more output from the previous turn.
        transcriptTurnStarts.append(.init(turn: turn, precedingItemID: transcript.last?.id))
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
        // Pi dequeues FIFO from the front; clear_queue returns the trailing queued entries.
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
        if confirmedEndTime {
            let endedAt = clock.now()
            turn.endedAt = endedAt
            turn.durationSeconds = turn.elapsedTime(at: endedAt, monotonicNow: clock.monotonicNow())
        } else {
            turn.endedAt = nil
            turn.durationSeconds = nil
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
            else if let item = rowsByID[key] { item.text = text; item.streaming = false; activeTurnHasVisibleOutput = true }
            else {
                startRound()
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
            if let activeTurn, activeTurn.anchorToolCallID == nil { activeTurn.anchorToolCallID = tool.id }
            activeTurnHasVisibleOutput = true
            let key = "tool:\(tool.id)"
            if let row = rowsByID[key] { if row.tool != tool { row.tool = tool } }
            else { append(.init(id: key, kind: .tool, tool: tool, turn: activeTurn)) }
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
            if [.outcomeUnknown, .connection, .protocolError, .supervision, .unsupportedInteraction].contains(failure.kind) {
                phase = .uncertain
                awaitingUserStarts.removeAll()
                finishRound(status: .uncertain, confirmedEndTime: false)
            }
        case .disconnected(let confirmed):
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
                if request.toolApproval != nil { onApprovalRequested?(request) }
            }
        case .interactionEnded(let id, let reason):
            if reason == .expired, let request = interactions.first(where: { $0.id == id }) {
                // Record the request, not any prefilled or user-entered reply.
                let expired = RuntimeInteraction(instanceID: request.instanceID, requestID: request.requestID,
                                                 kind: request.kind, title: request.title, message: request.message,
                                                 options: request.options, expiresAt: request.expiresAt,
                                                 toolApproval: request.toolApproval)
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
        }
        switch envelope.event {
        case .phase, .queue, .settled, .recoveredDrafts, .failure, .disconnected, .interaction, .interactionEnded, .suggestedDraft: onControlChanged?()
        default: break
        }
    }
}
