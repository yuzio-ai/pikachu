import Foundation
import Observation
import AgentRuntimeCore

public enum ConnectionState: String, Sendable { case disconnected, connecting, connected, closing, blocked }
public enum TranscriptKind: Sendable { case user, assistant, tool, notice }
public enum DeliveryState: String, Sendable, Codable { case pending, accepted, queued, recovered, handled, rejected, unknown }

@MainActor @Observable public final class TurnRecord: Identifiable {
    public let id: UUID
    public var status: TurnStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: TimeInterval?
    public var anchorAssistantTimestampMs: Int64?
    public var endAssistantTimestampMs: Int64?
    public var anchorToolCallID: String?
    public var anchorUserTimestampMs: Int64?
    @ObservationIgnored var monotonicStart: ContinuousClock.Instant?

    public init(id: UUID = UUID(), status: TurnStatus = .running, startedAt: Date? = nil, endedAt: Date? = nil,
                durationSeconds: TimeInterval? = nil, anchorAssistantTimestampMs: Int64? = nil,
                endAssistantTimestampMs: Int64? = nil, anchorToolCallID: String? = nil,
                anchorUserTimestampMs: Int64? = nil, monotonicStart: ContinuousClock.Instant? = nil) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.anchorAssistantTimestampMs = anchorAssistantTimestampMs
        self.endAssistantTimestampMs = endAssistantTimestampMs
        self.anchorToolCallID = anchorToolCallID
        self.anchorUserTimestampMs = anchorUserTimestampMs
        self.monotonicStart = monotonicStart
    }
}

@MainActor @Observable public final class TranscriptItem: Identifiable {
    public let id: String
    public let kind: TranscriptKind
    public var text: String
    public var delivery: DeliveryState
    public var streaming: Bool
    public var sentAt: Date?
    public var messageTimestampMs: Int64?
    public var turn: TurnRecord?
    public let originalText: String?
    public let attachedFiles: [URL]
    let submission: UserPrompt?
    public var editableText: String { originalText ?? submission?.text ?? text }
    public var editableFiles: [URL] { attachedFiles.isEmpty ? (submission?.files ?? []) : attachedFiles }
    public var tool: RuntimeTool? {
        didSet {
            let completed = tool?.state == .completed
            if completed != isCompletedTool { isCompletedTool = completed }
        }
    }
    // Grouping observes completion without reacting to every tool-output update.
    public private(set) var isCompletedTool: Bool
    @ObservationIgnored private var blocks: [Int: String] = [:]
    public init(id: String, kind: TranscriptKind, text: String = "", delivery: DeliveryState = .accepted, streaming: Bool = false, tool: RuntimeTool? = nil, sentAt: Date? = nil, messageTimestampMs: Int64? = nil, turn: TurnRecord? = nil, submission: UserPrompt? = nil, originalText: String? = nil, attachedFiles: [URL] = []) {
        self.id = id; self.kind = kind; self.text = text; self.delivery = delivery; self.streaming = streaming; self.tool = tool
        self.sentAt = sentAt; self.messageTimestampMs = messageTimestampMs; self.turn = turn
        self.originalText = originalText; self.attachedFiles = attachedFiles
        isCompletedTool = tool?.state == .completed
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
    public private(set) var queue = RuntimeQueue()
    public private(set) var queueIsKnown = true
    public private(set) var recoveredDrafts: [PendingPrompt] = []
    public private(set) var failure: RuntimeFailure?
    public private(set) var notice: String?
    private var regularPending = false
    private var stopPending = false
    public var commandPending: Bool { regularPending || stopPending }
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
    public var draft = "" { didSet { if draft != oldValue { (onDraftEdited ?? onControlChanged)?() } } }
    public var draftFiles: [URL] = [] { didSet { if draftFiles != oldValue { (onDraftEdited ?? onControlChanged)?() } } }
    public var mode: SendMode = .steer { didSet { onControlChanged?() } }
    @ObservationIgnored public var onControlChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onDraftEdited: (@MainActor () -> Void)?
    @ObservationIgnored public var prepareSubmission: (@MainActor (UserPrompt) async throws -> Void)?
    @ObservationIgnored public var resolveSubmission: (@MainActor (UUID, DeliveryState) async -> Void)?
    @ObservationIgnored public var onTurnFinished: (@MainActor (TurnRecord) -> Void)?
    @ObservationIgnored public var onUserMessageTimestamp: (@MainActor (UUID?, Int64) -> Void)?
    @ObservationIgnored private var runtime: (any AgentRuntime)?
    @ObservationIgnored private var instance: UUID?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var recoveredOperations = Set<UUID>()
    @ObservationIgnored private var settledCounter = 0
    @ObservationIgnored private var queueCounter = 0
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
            catch { failure = .init(.supervision, "上一执行实例的清理未确认，不能建立新连接。"); connection = .blocked; regularPending = false; return }
        }
        consumer?.cancel()
        runtime = newRuntime; instance = newRuntime.instanceID
        transcript = []; rowsByID = [:]; queue = .init(); queueIsKnown = true; phase = .idle; session = nil
        activeTurn = nil; activeTurnHadFailure = false; activeTurnHasVisibleOutput = false
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
            self.failure = .init(.connection, "运行时事件流意外结束，进程清理尚未确认。")
            self.connection = .blocked; self.phase = .uncertain; self.finishRound(status: .uncertain, confirmedEndTime: false); self.interruptUnfinished()
            self.onControlChanged?()
        }
        do {
            let opened = try await newRuntime.connect()
            guard connection == .connecting else { throw RuntimeFailure(.connection, "连接在启动期间中断。") }
            session = opened; connection = .connected
        } catch {
            failure = (error as? RuntimeFailure) ?? .init(.setup, "连接失败，请检查项目与运行时配置。")
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
            failure = .init(.setup, "发送状态未能持久化，没有发送任务。请先修复本地存储。")
            regularPending = false; onControlChanged?(); return
        }
        let item = TranscriptItem(id: "user:\(prompt.id)", kind: .user, text: text, delivery: .pending, sentAt: clock.now(), submission: prompt, originalText: prompt.text, attachedFiles: prompt.files)
        append(item)
        if matchesDraft(prompt) { draft = ""; draftFiles = [] }
        failure = nil
        let before = settledCounter, queueBefore = queueCounter
        do {
            let disposition = try await runtime.send(prompt)
            switch disposition {
            case .started:
                item.delivery = .accepted
                if instance == origin && phase == .idle && settledCounter == before { phase = .running }
            case .queued:
                // The acknowledgement may overtake the reader's queue event.
                // An older snapshot cannot establish that this input was consumed.
                item.delivery = queueCounter == queueBefore || queue.steering.contains(text) || queue.followUp.contains(text) ? .queued : .accepted
            case .handled: item.delivery = .handled
            }
        } catch {
            let problem = (error as? RuntimeFailure) ?? .init(.outcomeUnknown, "发送结果尚未确认，不会自动重发。")
            item.delivery = [.outcomeUnknown, .connection, .protocolError, .supervision].contains(problem.kind) ? .unknown : .rejected
            if instance == origin {
                if connection != .blocked || failure == nil { failure = problem }
                if item.delivery == .unknown { phase = .uncertain }
            }
            // A rejected input can be restored without overwriting new typing.
            if item.delivery == .rejected { recoveredDrafts.append(.init(id: prompt.id, text: prompt.text, mode: prompt.mode, files: prompt.files)) }
        }
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
            while regularPending && Date() < until { try? await Task.sleep(for: .milliseconds(10)) }
            guard !regularPending else { throw RuntimeFailure(.outcomeUnknown, "仍有未完成的控制请求，不能确认停止。") }
            phase = .idle
        }
        catch { failure = (error as? RuntimeFailure) ?? .init(.outcomeUnknown, "停止结果尚未确认。请结束受管进程。"); phase = .uncertain }
        stopPending = false
        onControlChanged?()
    }
    @discardableResult public func disconnect(force: Bool = false) async -> Bool {
        guard !commandPending || (force && !stopPending) else { notice = "请等待当前控制请求结束。"; return false }
        guard let runtime else { connection = .disconnected; return true }
        regularPending = true; connection = .closing
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
            failure = (error as? RuntimeFailure) ?? .init(.supervision, "进程清理尚未确认，不能继续执行。")
            connection = .blocked; phase = .uncertain; regularPending = false; onControlChanged?(); return false
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
        var activeRecordedTurn: (record: RecordedTurnRecord, turn: TurnRecord)?
        for info in turns {
            if let current = activeRecordedTurn {
                for id in info.itemIDs { turnByItemID[id] = current.turn }
                if let endMs = current.record.endAssistantTimestampMs,
                   info.firstAssistantTimestampMs == endMs {
                    activeRecordedTurn = nil
                }
                continue
            }
            let matched = recordedTurns.first { rec in
                (info.firstToolCallID != nil && rec.anchorToolCallID == info.firstToolCallID) ||
                (info.firstAssistantTimestampMs != nil && rec.anchorAssistantTimestampMs == info.firstAssistantTimestampMs) ||
                (info.firstUserTimestampMs != nil && rec.anchorUserTimestampMs == info.firstUserTimestampMs)
            }
            if let matched {
                let turn = TurnRecord(
                    id: matched.id,
                    status: matched.status,
                    startedAt: matched.startedAt,
                    endedAt: matched.endedAt ?? info.endedAt,
                    durationSeconds: matched.durationSeconds,
                    anchorAssistantTimestampMs: matched.anchorAssistantTimestampMs ?? info.firstAssistantTimestampMs,
                    endAssistantTimestampMs: matched.endAssistantTimestampMs,
                    anchorToolCallID: matched.anchorToolCallID ?? info.firstToolCallID,
                    anchorUserTimestampMs: matched.anchorUserTimestampMs ?? info.firstUserTimestampMs
                )
                for id in info.itemIDs { turnByItemID[id] = turn }
                if let endMs = matched.endAssistantTimestampMs, info.firstAssistantTimestampMs != endMs {
                    activeRecordedTurn = (matched, turn)
                }
            } else {
                let turn = TurnRecord(
                    status: info.status,
                    startedAt: nil,
                    endedAt: info.endedAt,
                    durationSeconds: info.durationSeconds,
                    anchorAssistantTimestampMs: info.firstAssistantTimestampMs,
                    anchorToolCallID: info.firstToolCallID,
                    anchorUserTimestampMs: info.firstUserTimestampMs
                )
                for id in info.itemIDs { turnByItemID[id] = turn }
            }
        }
        var fallbackTurn: TurnRecord?
        return items.map { item in
            let kind: TranscriptKind = switch item.kind { case .user: .user; case .assistant: .assistant; case .tool: .tool; case .notice: .notice }
            if kind == .user {
                fallbackTurn = nil
                let matchedMessage = item.messageTimestampMs.flatMap { ts in
                    recordedMessages.first { $0.messageTimestampMs == ts }
                }
                return TranscriptItem(
                    id: item.id,
                    kind: kind,
                    text: item.text,
                    sentAt: item.sentAt ?? matchedMessage?.sentAt,
                    messageTimestampMs: item.messageTimestampMs,
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
                    if fallbackTurn == nil { fallbackTurn = TurnRecord(status: .uncertain) }
                    assignedTurn = fallbackTurn
                }
            } else {
                assignedTurn = nil
            }
            return TranscriptItem(id: item.id, kind: kind, text: item.text, tool: item.tool, turn: assignedTurn)
        }
    }
    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        guard connection == .connected, let runtime else { throw RuntimeFailure(.setup, "会话尚未连接。") }
        let source = runtime.instanceID
        let options = try await runtime.configurationOptions()
        guard connection == .connected, instance == source else { throw RuntimeFailure(.connection, "会话连接已变化，请重试模型查询。") }
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
            failure = error as? RuntimeFailure ?? .init(.outcomeUnknown, "模型配置结果不明，请重新连接核对。")
            if let confirmed = try? await runtime.currentSession() { session = confirmed }
            if failure?.kind == .outcomeUnknown { phase = .uncertain }
            return false
        }
    }
    public func clearNotice() { notice = nil }
    public func cancelInteractions() async { await runtime?.cancelInteractions() }
    @discardableResult public func reply(_ request: RuntimeInteraction, _ response: InteractionResponse) async -> Bool {
        guard !replying, phase != .stopping, request.instanceID == instance,
              interactions.contains(where: { $0.id == request.id }), let runtime else { return false }
        replying = true; defer { replying = false }
        do { try await runtime.respond(to: request, with: response); return true }
        catch let problem as RuntimeFailure where problem.kind == .unsupportedInteraction { notice = problem.detail }
        catch { failure = .init(.outcomeUnknown, "交互回复结果不明，请停止任务并核对运行时状态。"); phase = .uncertain }
        return false
    }
    public func refreshUsage() async {
        guard connection == .connected, !usageLoading, let runtime else { return }
        let generation = usageGeneration; usageLoading = true
        defer { if generation == usageGeneration { usageLoading = false } }
        do {
            let value = try await runtime.usage()
            guard generation == usageGeneration, instance == runtime.instanceID, value.sessionID == session?.id else { return }
            usage = value; usageStale = phase != .idle; usageNotice = nil
        } catch { if generation == usageGeneration { usageNotice = "运行时统计暂不可用，未将缺失数据计作零。" } }
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
    private func startRound() {
        guard activeTurn == nil else { return }
        let turn = TurnRecord(id: UUID(), status: .running, startedAt: clock.now(), monotonicStart: clock.monotonicNow())
        if let pendingUser = transcript.last(where: { $0.kind == .user && ($0.delivery == .accepted || $0.delivery == .pending) }),
           turn.anchorUserTimestampMs == nil {
            turn.anchorUserTimestampMs = pendingUser.messageTimestampMs
        }
        activeTurn = turn
        activeTurnHadFailure = false
        activeTurnHasVisibleOutput = false
    }
    private func finishRound(status: TurnStatus, confirmedEndTime: Bool) {
        guard let turn = activeTurn else { return }
        turn.status = status
        if confirmedEndTime {
            turn.endedAt = clock.now()
            if let start = turn.monotonicStart {
                let elapsed = clock.monotonicNow() - start
                turn.durationSeconds = max(0, TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
            }
        } else {
            turn.endedAt = nil
            turn.durationSeconds = nil
        }
        activeTurn = nil
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
        case .userMessageTimestamp(let ts):
            if let item = transcript.last(where: { $0.kind == .user && $0.messageTimestampMs == nil && $0.delivery != .rejected && $0.delivery != .recovered }) {
                item.messageTimestampMs = ts
                onUserMessageTimestamp?(item.submission?.id, ts)
                if let activeTurn, activeTurn.anchorUserTimestampMs == nil {
                    activeTurn.anchorUserTimestampMs = ts
                }
            }
        case .assistantStarted(let id):
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
            let key = "assistant:\(id)"
            if text.isEmpty { transcript.removeAll { $0.id == key }; rowsByID.removeValue(forKey: key) }
            else if let item = rowsByID[key] { item.text = text; item.streaming = false; activeTurnHasVisibleOutput = true }
            else {
                startRound()
                append(.init(id: key, kind: .assistant, text: text, turn: activeTurn))
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
            self.queue = queue; queueIsKnown = true; queueCounter += 1
            var dequeuedSteer = false
            var dequeuedFollowUp = false
            for item in transcript where item.delivery == .queued && phase != .stopping {
                if !queue.steering.contains(item.text) && !queue.followUp.contains(item.text) {
                    item.delivery = .accepted
                    if item.submission?.mode == .followUp { dequeuedFollowUp = true }
                    else { dequeuedSteer = true }
                }
            }
            if dequeuedFollowUp && !dequeuedSteer && activeTurn != nil && activeTurnHasVisibleOutput {
                finishRound(status: activeTurnHadFailure ? .failed : .completed, confirmedEndTime: true)
                startRound()
            }
        case .settled(let aborted):
            settledCounter += 1; phaseBeforeWaiting = .idle; phase = interactions.isEmpty ? .idle : .waitingInput
            let status: TurnStatus = aborted ? .stopped : (activeTurnHadFailure ? .failed : .completed)
            finishRound(status: status, confirmedEndTime: true)
            interruptUnfinished(); scheduleUsage()
        case .recoveredDrafts(let operation, let drafts):
            if recoveredOperations.insert(operation).inserted {
                for draft in drafts {
                    // Queue snapshots contain text, not the local prompt IDs. Consume one
                    // queued row per returned input, including repeated identical inputs.
                    let matchingRows = transcript.lazy.filter { $0.kind == .user && $0.delivery == .queued && $0.text == draft.text }
                    let row = matchingRows.first { $0.submission?.mode == draft.mode } ?? matchingRows.first
                    row?.delivery = .recovered
                    if let prompt = row?.submission {
                        recoveredDrafts.append(.init(id: prompt.id, text: prompt.text, mode: draft.mode, files: prompt.files))
                    } else { recoveredDrafts.append(draft) }
                }
            }
        case .notice(let text): notice = text
        case .failure(let failure):
            self.failure = failure
            activeTurnHadFailure = true
            if [.outcomeUnknown, .connection, .protocolError, .supervision, .unsupportedInteraction].contains(failure.kind) {
                phase = .uncertain
                finishRound(status: .uncertain, confirmedEndTime: false)
            }
        case .disconnected(let confirmed):
            connection = confirmed ? .disconnected : .blocked
            phase = .uncertain; queueIsKnown = false; interactions = []; usageStale = true; usageGeneration = UUID(); usageLoading = false
            finishRound(status: .uncertain, confirmedEndTime: false)
            interruptUnfinished()
        case .interaction(let request):
            guard request.instanceID == instance, !interactions.contains(where: { $0.id == request.id }) else { return }
            if interactions.isEmpty { phaseBeforeWaiting = phase }
            interactions.append(request)
            if phase != .stopping { phase = .waitingInput }
        case .interactionEnded(let id, let reason):
            interactions.removeAll { $0.id == id }
            if interactions.isEmpty && phase == .waitingInput { phase = phaseBeforeWaiting }
            if reason == .expired { notice = "扩展交互已过期，未提交过期回复。" }
        case .suggestedDraft(let text):
            recoveredDrafts.append(.init(text: text, mode: .steer)); notice = "扩展提供的输入已保留为草稿，没有覆盖编辑框。"
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
