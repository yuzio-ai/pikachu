import XCTest
import Foundation
import Observation
import os
import AgentRuntimeCore
@testable import OrchestrationCore

private actor ACPMemoryWorkspaceStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    var fail = false
    private var onPendingSubmission: (@Sendable () async -> Void)?

    init(_ snapshot: WorkspaceSnapshot = .init()) {
        self.snapshot = snapshot
    }

    func load() -> WorkspaceSnapshot { snapshot }

    func setFailure(_ value: Bool) { fail = value }

    func interruptNextSubmission(with action: @escaping @Sendable () async -> Void) {
        onPendingSubmission = action
    }

    func save(_ value: WorkspaceSnapshot) async throws {
        if fail { throw RuntimeFailure(.setup, "injected storage error") }
        if let action = onPendingSubmission,
           value.sessions.contains(where: { $0.submissions.contains { $0.delivery == .pending } }) {
            onPendingSubmission = nil
            await action()
        }
        if value.revision > snapshot.revision { snapshot = value }
    }
}

@MainActor private final class WorktreeRegistration {
    var isValid = true
}

private final class MockACPRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    private let sink: AsyncStream<RuntimeEnvelope>.Continuation
    private let lock = NSLock()

    let sessionID: String
    let runtimeID: String
    let capabilities: Set<RuntimeCapability>
    let resumable: Bool
    let availableModes: [RuntimeModeOption]
    let replayItems: [HistoryItem]
    let models: [RuntimeModel]
    let thinkingLevelsList: [String]
    private let thinkingLevelsByModel: [String: [String]]

    private var currentModeID: String?
    private var currentModel: RuntimeModel
    private var currentThinking: String
    private var sentPrompts: [UserPrompt] = []
    private var modeChanges: [String] = []
    private var responses: [(String, InteractionResponse)] = []
    private var closedCount = 0

    var sendCount: Int { lock.withLock { sentPrompts.count } }
    var submittedTexts: [String] { lock.withLock { sentPrompts.map(\.text) } }
    var appliedModes: [String] { lock.withLock { modeChanges } }
    var receivedResponses: [(String, InteractionResponse)] { lock.withLock { responses } }
    var closeCount: Int { lock.withLock { closedCount } }

    init(
        sessionID: String = "acp-session-1",
        runtimeID: String = RuntimeAgentProfile.antigravityRuntimeID,
        capabilities: Set<RuntimeCapability> = [.streaming, .tools, .interruption, .sessionResume, .modeSelection, .modelConfiguration],
        resumable: Bool = true,
        modeID: String? = "default",
        availableModes: [RuntimeModeOption] = [
            .init(id: "default", name: "Default"),
            .init(id: "plan", name: "Plan"),
            .init(id: "auto", name: "Auto")
        ],
        replayItems: [HistoryItem] = [],
        models: [RuntimeModel] = [
            .init(provider: "antigravity", modelID: "gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            .init(provider: "antigravity", modelID: "claude-sonnet", name: "Claude Sonnet")
        ],
        thinkingLevels: [String] = ["off", "low", "high"],
        thinkingLevelsByModel: [String: [String]] = [:]
    ) {
        self.sessionID = sessionID
        self.runtimeID = runtimeID
        self.capabilities = capabilities
        self.resumable = resumable
        self.currentModeID = modeID
        self.availableModes = availableModes
        self.replayItems = replayItems
        self.models = models
        self.thinkingLevelsList = thinkingLevels
        self.thinkingLevelsByModel = thinkingLevelsByModel
        self.currentModel = models.first ?? RuntimeModel(provider: "acp", modelID: "default", name: "Default")
        self.currentThinking = thinkingLevels.first ?? "off"
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        self.events = pair.stream
        self.sink = pair.continuation
    }

    private func makeSession() -> RuntimeSession {
        lock.withLock {
            RuntimeSession(
                id: sessionID,
                model: currentModel.name,
                thinking: currentThinking,
                capabilities: capabilities,
                file: nil,
                provider: currentModel.provider,
                modelID: currentModel.modelID,
                runtimeID: runtimeID,
                modeID: currentModeID,
                availableModes: availableModes,
                resumable: resumable
            )
        }
    }

    func connect() async throws -> RuntimeSession {
        if !replayItems.isEmpty {
            emit(.historyReplayed(replayItems))
        }
        return makeSession()
    }

    func currentSession() async throws -> RuntimeSession {
        makeSession()
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        lock.withLock { sentPrompts.append(prompt) }
        emit(.phase(.running))
        return .started
    }

    func stop() async throws {
        emit(.settled(aborted: true))
    }

    func close(force: Bool) async throws {
        lock.withLock { closedCount += 1 }
        emit(.disconnected(cleanupConfirmed: true))
        sink.finish()
    }

    func configurationOptions() async throws -> RuntimeConfigurationOptions {
        lock.withLock {
            RuntimeConfigurationOptions(models: models, thinkingLevels: thinkingLevelsByModel[currentModel.modelID] ?? thinkingLevelsList)
        }
    }

    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        guard let matched = models.first(where: { $0.provider == selection.provider && $0.modelID == selection.modelID }) else {
            throw RuntimeFailure(.model, "Unknown ACP model")
        }
        lock.withLock {
            if currentModel != matched, let levels = thinkingLevelsByModel[matched.modelID] {
                currentThinking = levels.first ?? "—"
            }
            currentModel = matched
            if let thinking = selection.thinking { currentThinking = thinking }
        }
        let updated = makeSession()
        emit(.sessionUpdated(updated))
        return updated
    }

    func setMode(_ modeID: String) async throws -> RuntimeSession {
        guard availableModes.isEmpty || availableModes.contains(where: { $0.id == modeID }) else {
            throw RuntimeFailure(.setup, "Unsupported ACP mode")
        }
        lock.withLock {
            currentModeID = modeID
            modeChanges.append(modeID)
        }
        let updated = makeSession()
        emit(.sessionUpdated(updated))
        return updated
    }

    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {
        lock.withLock { responses.append((request.requestID, response)) }
        emit(.interactionEnded(request.id, .answered))
    }

    func emit(_ event: AgentEvent) {
        sink.yield(.init(instanceID: instanceID, event: event))
    }
}

@MainActor
final class ACPWorkspaceTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zivvi-ACPWorkspaceTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }

    func testLegacyV1SnapshotDecodesWithoutACPFieldsAndRoundTripsBoundedCache() throws {
        let legacyJSON = Data(#"""
        {
          "version": 1,
          "revision": 3,
          "projects": [],
          "sessions": [],
          "preferences": {
            "piPath": "/usr/local/bin/pi",
            "nodeDirectory": "/usr/local/bin",
            "proxy": ""
          }
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.preferences.acpAgents)
        XCTAssertNil(decoded.preferences.defaultRuntimeID)
        XCTAssertNil(decoded.modelPreferencesByRuntime)
        XCTAssertEqual(decoded.modelPreferences(forRuntime: "pi"), WorkspaceModelPreferences())
        XCTAssertEqual(decoded.modelPreferences(forRuntime: RuntimeAgentProfile.antigravityRuntimeID), WorkspaceModelPreferences())

        let project = ProjectRecord(path: "/tmp/project")
        var acpRef = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "ACP Task")
        XCTAssertTrue(acpRef.isACPRuntime)
        XCTAssertFalse(acpRef.hasBoundRuntime)
        acpRef.runtimeSessionID = "sess-123"
        acpRef.resumableSession = true
        acpRef.runtimeModeID = "plan"
        XCTAssertTrue(acpRef.hasBoundRuntime)

        let oversizedText = String(repeating: "a", count: CachedTranscriptItem.maximumTextBytes + 512)
        var tool = RuntimeTool(
            id: "tool-1",
            name: "bash",
            arguments: String(repeating: "x", count: CachedTranscriptItem.maximumToolOutputBytes + 256),
            output: String(repeating: "y", count: CachedTranscriptItem.maximumToolOutputBytes + 256),
            state: .running
        )
        tool.outputImage = Data([0x89, 0x50, 0x4E, 0x47])
        let cachedTool = CachedTranscriptItem(id: "tool:tool-1", kind: .tool, text: oversizedText, tool: tool)
        XCTAssertLessThanOrEqual(cachedTool.text.utf8.count, CachedTranscriptItem.maximumTextBytes)
        XCTAssertEqual(cachedTool.tool?.state, .interrupted)
        XCTAssertEqual(cachedTool.tool?.truncated, true)
        XCTAssertNil(cachedTool.tool?.outputImage)
        XCTAssertLessThanOrEqual(cachedTool.tool?.output.utf8.count ?? 0, CachedTranscriptItem.maximumToolOutputBytes)
        acpRef.cachedHistoryItems = [cachedTool]

        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [acpRef]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/opt/homebrew/bin/agy")]
        snapshot.preferences.defaultRuntimeID = RuntimeAgentProfile.antigravityRuntimeID
        var acpModelPrefs = WorkspaceModelPreferences()
        let acpModel = RuntimeModel(provider: "antigravity", modelID: "gemini-2.5-pro", name: "Gemini 2.5 Pro")
        acpModelPrefs.defaultModel = acpModel
        snapshot.modelPreferencesByRuntime = [RuntimeAgentProfile.antigravityRuntimeID: acpModelPrefs]

        let roundTripped = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTripped.preferences.acpAgents?.count, 1)
        XCTAssertEqual(roundTripped.preferences.defaultRuntimeID, RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertEqual(roundTripped.modelPreferences(forRuntime: RuntimeAgentProfile.antigravityRuntimeID).defaultModel, acpModel)
        XCTAssertNil(roundTripped.modelPreferences(forRuntime: "pi").defaultModel)
        XCTAssertEqual(roundTripped.sessions[0].runtimeModeID, "plan")
        XCTAssertEqual(roundTripped.sessions[0].resumableSession, true)
        XCTAssertEqual(roundTripped.sessions[0].cachedHistoryItems, [cachedTool])
    }

    func testSessionControllerBlocksOverlappingPromptWithoutQueuedPromptsCapability() async {
        let runtime = MockACPRuntime(capabilities: [.streaming, .tools, .interruption])
        let controller = SessionController()
        await controller.connect(runtime)

        XCTAssertFalse(controller.supportsQueuedPrompts)
        controller.draft = "First prompt"
        XCTAssertTrue(controller.canSend)

        await controller.sendDraft()
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertEqual(controller.phase, .running)

        controller.draft = "Overlapping prompt"
        XCTAssertFalse(controller.canSend, "Standard ACP v1 session must not accept overlapping input while active")
        await controller.sendDraft()
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertEqual(controller.draft, "Overlapping prompt")

        runtime.emit(.settled(aborted: false))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.canSend)

        _ = await controller.disconnect()
    }

    func testApprovalDetailsRefreshOnlyWhileTheIncomingRequestIsPending() async throws {
        let runtime = MockACPRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        var approvalCallbacks = 0
        controller.onApprovalRequested = { _ in approvalCallbacks += 1 }
        let options = [RuntimePermissionOption(id: "allow", name: "Allow", kind: .allowOnce)]
        let pending = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "permission", kind: .select,
                                         title: "Waiting", permissionOptions: options,
                                         permissionContext: .init(toolTitle: "Waiting", awaitingToolDetails: true))
        let resolved = RuntimeInteraction(instanceID: runtime.instanceID, requestID: pending.requestID, kind: .select,
                                          title: "Ready", permissionOptions: options,
                                          permissionContext: .init(toolTitle: "Ready", awaitingToolDetails: false))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(resolved)))
        XCTAssertTrue(controller.interactions.isEmpty)
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(pending)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(resolved)))
        XCTAssertEqual(controller.interactions, [resolved])
        XCTAssertEqual(approvalCallbacks, 1)

        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(pending.id, .cancelled)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(resolved)))
        XCTAssertTrue(controller.interactions.isEmpty)
        _ = await controller.disconnect()
    }

    func testExpiredApprovalLookupRetainsTheLastPresentedToolDetails() async throws {
        let runtime = MockACPRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        let options = [RuntimePermissionOption(id: "a", name: "Allow", kind: .allowOnce)]
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(300)
        let initial = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "expires-after-details", kind: .select,
                                         title: "Waiting", expiresAt: expiresAt, createdAt: createdAt,
                                         permissionOptions: options,
                                         permissionContext: .init(toolTitle: "Waiting", awaitingToolDetails: true))
        let ready = RuntimeInteraction(instanceID: runtime.instanceID, requestID: initial.requestID, kind: .select,
                                       title: "Edit fixture", expiresAt: expiresAt, createdAt: createdAt,
                                       permissionOptions: options,
                                       permissionContext: .init(toolTitle: "Edit fixture", sessionDirectory: "/fixture",
                                                                rawInputJSON: #"{"patch":true}"#,
                                                                diffs: [.init(path: "/fixture/file", oldText: nil, newText: "new")],
                                                                awaitingToolDetails: false))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(initial)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(ready)))
        XCTAssertNil(controller.expiredInteraction(for: initial))
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(initial.id, .expired)))
        XCTAssertTrue(controller.interactions.isEmpty)
        XCTAssertEqual(controller.expiredInteraction(for: initial), ready)
        XCTAssertEqual(controller.transcript.last { $0.expiredInteraction != nil }?.expiredInteraction, ready)
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(initial)))
        XCTAssertEqual(controller.expiredInteraction(for: initial), ready)
        XCTAssertTrue(controller.interactions.isEmpty)
        _ = await controller.disconnect()
    }

    func testApprovalTimeoutRecoveryRequiresConfirmedCancellationOfTheSameTurn() async throws {
        let runtime = MockACPRuntime()
        let controller = SessionController()
        await controller.connect(runtime)

        func receive(_ event: AgentEvent) {
            controller.receive(.init(instanceID: runtime.instanceID, event: event))
        }

        for (index, permission, aborted) in [(0, true, false), (1, false, true), (2, true, true)] {
            receive(.phase(.running))
            let turn = try XCTUnwrap(controller.activeTurn)
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "timeout-\(index)",
                                             kind: .select, title: "Pending request", permissionOptions: permission
                                                ? [.init(id: "allow", name: "Allow", kind: .allowOnce)] : [])
            receive(.interaction(request))
            receive(.interactionEnded(request.id, .expired))
            XCTAssertNil(controller.approvalTimeoutRecovery)
            receive(.settled(aborted: aborted))

            XCTAssertEqual(turn.interruptedByApprovalTimeout, permission && aborted)
            if permission && aborted {
                XCTAssertEqual(controller.approvalTimeoutRecovery?.turnID, turn.id)
                XCTAssertEqual(controller.approvalTimeoutRecovery?.recordID, controller.transcript.last?.timelineID)
            } else {
                XCTAssertNil(controller.approvalTimeoutRecovery)
            }
        }
        receive(.phase(.running))
        receive(.settled(aborted: true))
        XCTAssertNil(controller.approvalTimeoutRecovery)
        _ = await controller.disconnect()
    }

    func testContinueAfterApprovalTimeoutSendsOneNewPromptAndKeepsDraft() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MockACPRuntime()
        let project = ProjectRecord(path: root.path)
        let session = SessionReference(projectID: project.id, runtimeID: runtime.runtimeID)
        let other = SessionReference(projectID: project.id, runtimeID: runtime.runtimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [session, other]
        snapshot.selectedSessionID = session.id
        let store = ACPMemoryWorkspaceStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        await workspace.send(session.id, submitted: .init(text: "Original task"))
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        try await waitUntil { controller.activeTurn != nil }

        func expire(_ requestID: String) {
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: requestID,
                                             kind: .select, title: "Pending approval",
                                             permissionOptions: [.init(id: "allow", name: "Allow", kind: .allowOnce)])
            let events: [AgentEvent] = [.interaction(request), .interactionEnded(request.id, .expired)]
            for event in events {
                controller.receive(.init(instanceID: runtime.instanceID, event: event))
            }
        }

        expire("first")
        expire("latest")
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        let recovery = try XCTUnwrap(workspace.approvalTimeoutRecovery(for: session.id))
        XCTAssertEqual(recovery.recordID, controller.transcript.last?.timelineID)
        let attachment = root.appendingPathComponent("draft.txt")
        controller.draft = "Unsent follow-up"
        controller.draftFiles = [attachment]

        await workspace.select(other.id)
        await workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        XCTAssertEqual(runtime.sendCount, 1)
        await workspace.select(session.id)
        XCTAssertEqual(workspace.approvalTimeoutRecovery(for: session.id), recovery)

        async let first: Void = workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        async let second: Void = workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        _ = await (first, second)
        XCTAssertEqual(runtime.sendCount, 2)
        XCTAssertNotEqual(runtime.submittedTexts.last, "Original task")
        XCTAssertTrue(runtime.receivedResponses.isEmpty)
        XCTAssertNil(workspace.approvalTimeoutRecovery(for: session.id))
        XCTAssertEqual(controller.draft, "Unsent follow-up")
        XCTAssertEqual(controller.draftFiles, [attachment])
        let saved = await store.load().sessions.first { $0.id == session.id }
        XCTAssertEqual(saved?.draft, controller.draft)
        XCTAssertEqual(saved?.draftFiles, [attachment])

        expire("before-disconnect")
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        let secondRecovery = try XCTUnwrap(workspace.approvalTimeoutRecovery(for: session.id))
        _ = await workspace.disconnect(session.id)
        await workspace.continueAfterApprovalTimeout(secondRecovery, in: session.id)
        XCTAssertNil(workspace.approvalTimeoutRecovery(for: session.id))
        XCTAssertEqual(runtime.sendCount, 2)
    }

    func testContinueAfterApprovalTimeoutRevalidatesContextBeforeSending() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.resolvingSymlinksInPath().appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let runtime = MockACPRuntime()
        let project = ProjectRecord(path: root.path)
        let session = SessionReference(projectID: project.id, runtimeID: runtime.runtimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [session]
        snapshot.selectedSessionID = session.id
        let store = ACPMemoryWorkspaceStore(snapshot)
        let registration = WorktreeRegistration()
        let workspace = WorkspaceController(store: store, validateWorktree: { _, _ in registration.isValid }) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let choseDirectory = await workspace.chooseWorkingDirectory(worktree: directory.path, for: session.id)
        XCTAssertTrue(choseDirectory)
        await workspace.send(session.id, submitted: .init(text: "Original task"))
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        try await waitUntil { controller.activeTurn != nil }
        let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "path-test",
                                         kind: .select, title: "Pending approval",
                                         permissionOptions: [.init(id: "allow", name: "Allow", kind: .allowOnce)])
        let events: [AgentEvent] = [.interaction(request), .interactionEnded(request.id, .expired), .settled(aborted: true)]
        for event in events { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        let recovery = try XCTUnwrap(workspace.approvalTimeoutRecovery(for: session.id))

        registration.isValid = false
        await workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertNotNil(workspace.viewed?.executionError)

        registration.isValid = true
        try FileManager.default.removeItem(at: directory)
        await workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertNotNil(workspace.viewed?.executionError)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        await store.interruptNextSubmission { await MainActor.run { registration.isValid = false } }
        await workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertNotNil(workspace.viewed?.executionError)

        registration.isValid = true
        await store.interruptNextSubmission { await workspace.beginShutdown() }
        await workspace.continueAfterApprovalTimeout(recovery, in: session.id)
        XCTAssertTrue(workspace.isShuttingDown)
        XCTAssertEqual(runtime.sendCount, 1)
        XCTAssertEqual(controller.transcript.filter { $0.kind == .user }.map(\.text), ["Original task"])
        let saved = await store.load().sessions.first { $0.id == session.id }
        XCTAssertEqual(saved?.submissions.isEmpty, true)
        _ = await workspace.disconnectAll()
    }

    func testPendingApprovalPathRefreshIsObservableAndRetainedOnExpiry() async {
        let runtime = MockACPRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        let createdAt = Date()
        let options = [RuntimePermissionOption(id: "a", name: "Allow", kind: .allowOnce)]
        func request(path: String) -> RuntimeInteraction {
            .init(instanceID: runtime.instanceID, requestID: "waiting", kind: .select, title: "Waiting",
                  expiresAt: createdAt.addingTimeInterval(300), createdAt: createdAt, permissionOptions: options,
                  permissionContext: .init(toolTitle: "Waiting", paths: [path], awaitingToolDetails: true))
        }
        let initial = request(path: "caf\u{00E9}.txt")
        let path = "cafe\u{0301}.txt"
        let updated = request(path: path)
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(initial)))
        let refreshed = expectation(description: "The waiting approval publishes the new path")
        withObservationTracking {
            _ = controller.interactions
        } onChange: {
            refreshed.fulfill()
        }
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionUpdated(updated)))
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(controller.interactions.first?.permissionContext?.paths.map { Data($0.utf8) }, [Data(path.utf8)])
        controller.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(initial.id, .expired)))
        XCTAssertTrue(controller.interactions.isEmpty)
        XCTAssertEqual(controller.expiredInteraction(for: initial)?.permissionContext?.paths.map { Data($0.utf8) },
                       [Data(path.utf8)])
        _ = await controller.disconnect()
    }

    func testSessionControllerModeSelectionUsageAndPermissionOptionReply() async {
        let runtime = MockACPRuntime()
        let controller = SessionController()
        var approvalCallbacks: [RuntimeInteraction] = []
        controller.onApprovalRequested = { approvalCallbacks.append($0) }

        await controller.connect(runtime)
        XCTAssertTrue(controller.supportsModeSelection)
        XCTAssertEqual(controller.session?.modeID, "default")

        let changed = await controller.setRuntimeMode("plan")
        XCTAssertTrue(changed)
        XCTAssertEqual(controller.session?.modeID, "plan")
        XCTAssertEqual(runtime.appliedModes, ["plan"])

        let usage = RuntimeUsage(
            sessionID: runtime.sessionID,
            tokens: TokenUsage(input: 120, output: 45, total: 165),
            context: ContextUsage(tokens: 165, window: 100_000, percent: 0.165)
        )
        runtime.emit(.usageUpdated(usage))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.usage?.tokens.total, 165)

        controller.draft = "Run tool"
        await controller.sendDraft()
        let blockedWhileRunning = await controller.setRuntimeMode("auto")
        XCTAssertFalse(blockedWhileRunning)

        let permissionOptions: [RuntimePermissionOption] = [
            .init(id: "allow_once", name: "Allow Once", kind: .allowOnce),
            .init(id: "reject_once", name: "Reject Once", kind: .rejectOnce)
        ]
        let permissionContext = RuntimePermissionContext(
            toolCallID: "call-1",
            toolTitle: "Run tests",
            toolKind: "execute",
            workingDirectory: "/tmp",
            paths: ["/tmp/Package.swift"],
            summary: "swift test"
        )
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "perm-1",
            kind: .select,
            title: "Allow running command?",
            permissionOptions: permissionOptions,
            permissionContext: permissionContext
        )
        runtime.emit(.interaction(request))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.phase, .waitingInput)
        XCTAssertEqual(approvalCallbacks.map(\.requestID), ["perm-1"])

        let replied = await controller.reply(request, .permissionOption("allow_once"))
        XCTAssertTrue(replied)
        XCTAssertEqual(runtime.receivedResponses.first?.0, "perm-1")
        XCTAssertEqual(runtime.receivedResponses.first?.1, .value("allow_once"))

        let expiringRequest = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "perm-expired",
            kind: .select,
            title: "Expired permission",
            permissionOptions: permissionOptions,
            permissionContext: permissionContext
        )
        runtime.emit(.interaction(expiringRequest))
        runtime.emit(.interactionEnded(expiringRequest.id, .expired))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.didExpire(expiringRequest))
        let expiredRow = controller.transcript.first { $0.expiredInteraction?.requestID == "perm-expired" }
        XCTAssertEqual(expiredRow?.expiredInteraction?.permissionOptions, permissionOptions)

        runtime.emit(.settled(aborted: false))
        _ = await controller.disconnect()
    }

    func testAutomaticTitleWaitsForAcceptanceAndPersists() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let runtime = MockACPRuntime()
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        let requested = expectation(description: "Title requested")
        let titles = AsyncStream<String>.makeStream()
        var calls: [String] = []
        workspace.generateSessionTitle = { settings, text in
            XCTAssertEqual(settings.mode, .automatic)
            let stored = await store.load()
            let persisted = try? JSONEncoder().encode(stored)
            XCTAssertNotNil(persisted)
            XCTAssertFalse(persisted.map { String(decoding: $0, as: UTF8.self).contains("\"awaitsAutomaticTitle\":true") } ?? true)
            XCTAssertTrue(persisted.map { String(decoding: $0, as: UTF8.self).contains("\"automaticTitleSubmissionID\"") } ?? false)
            calls.append(text)
            requested.fulfill()
            for await title in titles.stream { return title }
            return nil
        }
        await workspace.start()
        let created = await workspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        let prompt = UserPrompt(text: "Fix sidebar search\nReproduce when empty")
        await workspace.send(id, submitted: prompt)
        XCTAssertTrue(calls.isEmpty)
        runtime.emit(.promptConfirmed(prompt.id))
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(workspace.selected?.displayTitle, "Fix sidebar search")
        titles.continuation.yield("Sidebar · Search fix")
        titles.continuation.finish()
        let deadline = ContinuousClock.now + .seconds(2)
        while workspace.selected?.displayTitle != "Sidebar · Search fix", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await workspace.disconnectAll()
        let persisted = await store.load()
        let reopened = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(reopened.sessions.first?.displayTitle, "Sidebar · Search fix")
        XCTAssertEqual(calls, [prompt.text])
    }

    func testDefinitiveFirstRejectionLetsTheRetrySupplyTheTitle() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let runtime = MockACPRuntime()
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        let requested = expectation(description: "Retry text reached title generator")
        let first = UserPrompt(text: "Rejected first submission")
        let retry = UserPrompt(text: "First accepted submission")
        workspace.generateSessionTitle = { _, text in
            XCTAssertEqual(text, retry.text)
            requested.fulfill()
            return "Generated title"
        }
        await workspace.start()
        let created = await workspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        await workspace.send(id, submitted: first)
        runtime.emit(.promptAcceptance(first.id, .rejected))
        runtime.emit(.settled(aborted: false))
        try await waitUntil {
            workspace.execution(for: id)?.phase == .idle &&
                workspace.execution(for: id)?.transcript.first(where: { $0.id == "user:\(first.id)" })?.delivery == .rejected
        }
        await workspace.send(id, submitted: retry)
        runtime.emit(.promptConfirmed(retry.id))
        await fulfillment(of: [requested], timeout: 2)
        try await waitUntil { workspace.selected?.displayTitle == "Generated title" }
        _ = await workspace.disconnectAll()
    }

    func testRestartDoesNotNameRecoveredConversationUsingNextPrompt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let initialRuntime = MockACPRuntime()
        let initialWorkspace = WorkspaceController(store: store) { _, _ in initialRuntime }
        await initialWorkspace.start()
        let created = await initialWorkspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        let original = UserPrompt(text: "Keep the original title")
        await initialWorkspace.send(id, submitted: original)
        _ = await initialWorkspace.disconnectAll()

        let restartedRuntime = MockACPRuntime()
        let restarted = WorkspaceController(store: store) { _, _ in restartedRuntime }
        let unexpected = expectation(description: "Recovered conversations must not request a title")
        unexpected.isInverted = true
        restarted.generateSessionTitle = { _, _ in
            unexpected.fulfill()
            return nil
        }
        await restarted.start()
        await restarted.reviewSubmission(original.id, in: id)
        let followUp = UserPrompt(text: "Send a different task after restart")
        await restarted.send(id, submitted: followUp)
        XCTAssertEqual(restartedRuntime.submittedTexts, [followUp.text])
        restartedRuntime.emit(.promptConfirmed(followUp.id))
        await fulfillment(of: [unexpected], timeout: 0.25)
        XCTAssertEqual(restarted.selected?.displayTitle, original.text)
        _ = await restarted.disconnectAll()
    }

    func testUnconfirmedCancellationDoesNotRetargetTheTitleToTheFollowUp() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let runtime = MockACPRuntime()
        let workspace = WorkspaceController(store: ACPMemoryWorkspaceStore(snapshot)) { _, _ in runtime }
        let unexpected = expectation(description: "The follow-up must not replace an unconfirmed first prompt")
        unexpected.isInverted = true
        workspace.generateSessionTitle = { _, _ in unexpected.fulfill(); return nil }
        await workspace.start()
        let created = await workspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        let first = UserPrompt(text: "First submitted message")
        await workspace.send(id, submitted: first)
        runtime.emit(.settled(aborted: true))
        try await waitUntil { workspace.execution(for: id)?.phase == .idle && workspace.selected?.submissions.isEmpty == true }
        let second = UserPrompt(text: "Do something else")
        await workspace.send(id, submitted: second)
        XCTAssertEqual(runtime.submittedTexts, [first.text, second.text])
        runtime.emit(.promptConfirmed(second.id))
        await fulfillment(of: [unexpected], timeout: 0.25)
        XCTAssertEqual(workspace.selected?.displayTitle, first.text)
        _ = await workspace.disconnectAll()
    }

    func testRemoteDeletionDiscardsAResultAlreadyInFlight() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let runtime = MockACPRuntime(capabilities: [.streaming, .sessionResume, .sessionDelete])
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        let requested = expectation(description: "Title request is active")
        let returned = expectation(description: "Title request returns after remote deletion")
        var reply: CheckedContinuation<String?, Never>?
        workspace.generateSessionTitle = { _, _ in
            let title = await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
            returned.fulfill()
            return title
        }
        await workspace.start()
        let created = await workspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        let first = UserPrompt(text: "Retain this local title")
        await workspace.send(id, submitted: first)
        runtime.emit(.promptConfirmed(first.id))
        runtime.emit(.settled(aborted: false))
        await fulfillment(of: [requested], timeout: 2)
        defer { reply?.resume(returning: nil) }
        try await waitUntil { workspace.execution(for: id)?.phase == .idle }
        let target = try XCTUnwrap(workspace.remoteHistoryDeletionTarget(for: id))
        do {
            try await workspace.deleteRemoteHistory(target) { _ in throw RuntimeFailure(.outcomeUnknown, "Timeout") }
            XCTFail("Expected the first remote deletion to fail")
        } catch let error as RuntimeFailure {
            XCTAssertEqual(error.kind, .outcomeUnknown)
        }
        XCTAssertNil(workspace.selected?.remoteHistoryDeleted)
        try await workspace.deleteRemoteHistory(target) { _ in }
        reply?.resume(returning: "Late generated title")
        reply = nil
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(workspace.selected?.displayTitle, first.text)
        _ = await workspace.disconnectAll()
        let persisted = await store.load()
        XCTAssertEqual(persisted.sessions.first?.remoteHistoryDeleted, true)
        XCTAssertEqual(persisted.sessions.first?.displayTitle, first.text)
    }

    func testSpecifiedTitleSettingsPersistAndManualTitleWins() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let runtime = MockACPRuntime()
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        let requested = expectation(description: "Title requested")
        let titles = AsyncStream<String>.makeStream()
        let model = SessionTitleModel(runtimeID: "acp:titles", model: .init(provider: "fixture", modelID: "chosen", name: "Chosen"))
        let settings = SessionTitleSettings(mode: .specified, model: model, rules: "Use Module · Topic")
        workspace.generateSessionTitle = { received, _ in
            XCTAssertEqual(received, settings)
            requested.fulfill()
            for await title in titles.stream { return title }
            return nil
        }
        await workspace.start()
        let saved = await workspace.setSessionTitleSettings(settings)
        XCTAssertTrue(saved)
        let created = await workspace.createSession(in: project.id)
        let id = try XCTUnwrap(created)
        let prompt = UserPrompt(text: "Fix session switching")
        await workspace.send(id, submitted: prompt)
        runtime.emit(.promptConfirmed(prompt.id))
        await fulfillment(of: [requested], timeout: 2)
        let renamed = await workspace.renameSession(id, to: "My title")
        XCTAssertTrue(renamed)
        titles.continuation.yield("Late title")
        titles.continuation.finish()
        _ = await workspace.disconnectAll()

        let persisted = await store.load()
        let reopened = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(reopened.sessionTitleSettings, settings)
        XCTAssertEqual(reopened.sessions.first?.displayTitle, "My title")
    }

    func testDisabledAndAttachmentOnlySessionsKeepLocalTitles() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.preferences.acpAgents = [.antigravityPreset(executablePath: "/usr/bin/true")]
        var runtimes: [UUID: MockACPRuntime] = [:]
        let workspace = WorkspaceController(store: ACPMemoryWorkspaceStore(snapshot)) { _, reference in
            let runtime = MockACPRuntime(sessionID: reference.id.uuidString)
            runtimes[reference.id] = runtime
            return runtime
        }
        workspace.generateSessionTitle = { _, _ in
            XCTFail("Disabled generation and a pure attachment should keep local titles")
            return nil
        }
        await workspace.start()
        let saved = await workspace.setSessionTitleSettings(.init(rules: "Keep these rules"))
        XCTAssertTrue(saved)
        let disabled = await workspace.setSessionTitleSettings(.init(mode: .disabled, rules: String(repeating: "x", count: 4097)))
        XCTAssertTrue(disabled)
        XCTAssertEqual(workspace.sessionTitleSettings.rules, "Keep these rules")
        let disabledSession = await workspace.createSession(in: project.id)
        let disabledID = try XCTUnwrap(disabledSession)
        let text = UserPrompt(text: "Local title")
        await workspace.send(disabledID, submitted: text)
        let textRuntime = try XCTUnwrap(runtimes[disabledID])
        workspace.execution(for: disabledID)?.receive(.init(instanceID: textRuntime.instanceID, event: .promptConfirmed(text.id)))
        XCTAssertEqual(workspace.selected?.displayTitle, "Local title")

        let automatic = await workspace.setSessionTitleSettings(.init())
        XCTAssertTrue(automatic)
        let attachmentSession = await workspace.createSession(in: project.id)
        let attachment = root.appendingPathComponent("example.txt")
        try "Example".write(to: attachment, atomically: true, encoding: .utf8)
        let attachmentID = try XCTUnwrap(attachmentSession)
        let attached = UserPrompt(text: "", files: [attachment])
        await workspace.send(attachmentID, submitted: attached)
        let attachedRuntime = try XCTUnwrap(runtimes[attachmentID])
        workspace.execution(for: attachmentID)?.receive(.init(instanceID: attachedRuntime.instanceID, event: .promptConfirmed(attached.id)))
        XCTAssertTrue(workspace.selected?.displayTitle.contains("example.txt") == true)
        _ = await workspace.disconnectAll()
    }

    func testRemoteHistoryImportDeduplicatesAndDeletionKeepsReadOnlyLocalRecord() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        let store = ACPMemoryWorkspaceStore(snapshot)
        let agentID = RuntimeAgentProfile.antigravityRuntimeID
        let remote = RuntimeRemoteSession(id: "remote-1", directory: root.path, title: "Imported history")
        let workspace = WorkspaceController(store: store) { _, _ in
            XCTFail("Remote history operations must not start a conversational runtime")
            return MockACPRuntime()
        }
        await workspace.start()
        let first = await workspace.importRemoteSession(remote, projectID: project.id, agentID: agentID,
                                                        canRestore: true, canDelete: true)
        let id = try XCTUnwrap(first)
        workspace.presentations[id]?.controller.draft = "Keep this draft"
        let duplicate = await workspace.importRemoteSession(remote, projectID: project.id, agentID: agentID,
                                                            canRestore: true, canDelete: true)
        XCTAssertEqual(duplicate, id)
        XCTAssertEqual(workspace.state.sessions.count, 1)
        let target = try XCTUnwrap(workspace.remoteHistoryDeletionTarget(for: id))
        do {
            try await workspace.deleteRemoteHistory(target) { _ in throw RuntimeFailure(.outcomeUnknown, "Timeout") }
            XCTFail("An unknown outcome must be reported")
        } catch let error as RuntimeFailure {
            XCTAssertEqual(error.kind, .outcomeUnknown)
        }
        XCTAssertNil(workspace.state.sessions.first?.remoteHistoryDeleted)
        XCTAssertEqual(target.agentID, agentID)
        try await workspace.deleteRemoteHistory(target) { actualRemoteID in
            XCTAssertEqual(actualRemoteID, remote.id)
        }
        let stored = await store.load()
        XCTAssertEqual(stored.sessions.first?.remoteHistoryDeleted, true)
        XCTAssertEqual(stored.sessions.first?.draft, "Keep this draft")
        let reopened = WorkspaceController(store: store) { _, _ in
            XCTFail("A deleted Agent session must remain read-only after restart")
            return MockACPRuntime()
        }
        await reopened.start()
        let activated = await reopened.activate(id)
        XCTAssertFalse(activated)
    }

    func testResumableFilelessACPSessionPersistsAcrossRestartAndReplaysWithoutLiveTurnNotification() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ACPMemoryWorkspaceStore()
        let firstRuntime = MockACPRuntime(sessionID: "acp-durable-1", resumable: true, modeID: "plan")

        let workspace = WorkspaceController(
            store: store,
            runtimeFactory: { _, _, _ in firstRuntime }
        )
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset(executablePath: "/opt/homebrew/bin/agy")])
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)

        let addedProjectID = await workspace.addProject(root)
        let projectID = try XCTUnwrap(addedProjectID)
        XCTAssertEqual(workspace.selected?.runtimeID, RuntimeAgentProfile.antigravityRuntimeID)
        let sessionID = try XCTUnwrap(workspace.selected?.id)

        await workspace.send(sessionID, submitted: UserPrompt(text: "Explain ACP"))
        let assistantID = UUID()
        firstRuntime.emit(.assistantStarted(assistantID))
        firstRuntime.emit(.assistantCompleted(assistantID, "ACP v1 uses JSON-RPC 2.0 over stdio."))
        firstRuntime.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: sessionID)?.phase == .idle }

        let disconnected = await workspace.disconnect(sessionID)
        XCTAssertTrue(disconnected)

        let persisted = await store.load()
        let savedSession = try XCTUnwrap(persisted.sessions.first { $0.id == sessionID })
        XCTAssertEqual(savedSession.runtimeID, RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertEqual(savedSession.runtimeSessionID, "acp-durable-1")
        XCTAssertNil(savedSession.file)
        XCTAssertEqual(savedSession.resumableSession, true)
        XCTAssertEqual(savedSession.runtimeModeID, "plan")
        XCTAssertEqual(savedSession.cachedHistoryItems?.count, 2)

        // Reopen workspace from disk: file-less resumable ACP session must keep runtimeSessionID and display offline cache.
        let replayedItems: [HistoryItem] = [
            HistoryItem(id: "replayed-u1", kind: .user, text: "Explain ACP"),
            HistoryItem(id: "replayed-a1", kind: .assistant, text: "Authoritative replay from session/load.")
        ]
        var capturedExpectedSessionIDs: [String?] = []
        let secondRuntime = MockACPRuntime(
            sessionID: "acp-durable-1",
            resumable: true,
            modeID: "plan",
            replayItems: replayedItems
        )
        let reopened = WorkspaceController(
            store: store,
            runtimeFactory: { _, reference, _ in
                capturedExpectedSessionIDs.append(reference.runtimeSessionID)
                return secondRuntime
            }
        )
        var liveFinishedTurns = 0
        reopened.onLiveTurnFinished = { _, _ in liveFinishedTurns += 1 }

        await reopened.start()
        XCTAssertEqual(reopened.selected?.runtimeSessionID, "acp-durable-1")
        XCTAssertEqual(reopened.selected?.resumableSession, true)
        XCTAssertNil(reopened.viewed?.loadError)
        XCTAssertEqual(reopened.viewed?.controller.showingCachedHistory, true)
        XCTAssertEqual(reopened.viewed?.controller.transcript.count, 2)
        XCTAssertNotNil(reopened.viewed?.controller.transcript.first?.sentAt)
        XCTAssertNotNil(reopened.viewed?.controller.transcript.last?.turn?.endedAt)
        XCTAssertNotNil(reopened.viewed?.controller.notice)
        XCTAssertEqual(liveFinishedTurns, 0)

        let activated = await reopened.activate(sessionID)
        XCTAssertTrue(activated)
        XCTAssertEqual(capturedExpectedSessionIDs, ["acp-durable-1"])
        try await waitUntil { reopened.viewed?.controller.transcript.last?.text == "Authoritative replay from session/load." }
        XCTAssertEqual(reopened.viewed?.controller.showingCachedHistory, false)
        XCTAssertNotNil(reopened.viewed?.controller.transcript.first?.sentAt)
        XCTAssertNotNil(reopened.viewed?.controller.transcript.last?.turn?.endedAt)
        XCTAssertEqual(liveFinishedTurns, 0, "History replay must not emit live turn completion notifications")

        // Verify projectID is retained across reopen.
        XCTAssertEqual(reopened.selectedProject?.id, projectID)
        _ = await reopened.disconnectAll()
    }

    func testReconnectAppliesOnlySupportedHistoricalConfiguration() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ACPMemoryWorkspaceStore()
        let firstRuntime = MockACPRuntime(sessionID: "acp-cleared-config")
        let workspace = WorkspaceController(store: store, runtimeFactory: { _, _, _ in firstRuntime })
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset(executablePath: "/opt/homebrew/bin/agy")])
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        await workspace.send(id, submitted: .init(text: "Start"))
        try await waitUntil { workspace.execution(for: id)?.phase == .running }
        firstRuntime.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: id)?.phase == .idle }
        let closed = await workspace.disconnect(id)
        XCTAssertTrue(closed)
        let saved = await store.load()
        XCTAssertNotNil(saved.sessions.first { $0.id == id }?.selection)

        let catalogues: [[RuntimeModel]] = [
            [],
            [.init(provider: "antigravity", modelID: "replacement", name: "Replacement")],
        ]
        for catalogue in catalogues {
            let capabilities: Set<RuntimeCapability> = catalogue.isEmpty
                ? [.streaming, .sessionResume] : [.streaming, .sessionResume, .modelConfiguration]
            let restoredRuntime = MockACPRuntime(sessionID: "acp-cleared-config", capabilities: capabilities,
                                                 modeID: nil, availableModes: [], models: catalogue, thinkingLevels: [])
            let restored = WorkspaceController(store: ACPMemoryWorkspaceStore(saved), runtimeFactory: { _, _, _ in restoredRuntime })
            await restored.start()
            await restored.send(id, submitted: .init(text: "Continue with agent defaults"))
            XCTAssertEqual(restoredRuntime.submittedTexts, ["Continue with agent defaults"])
            _ = await restored.disconnectAll()
        }

        let startingModel = RuntimeModel(provider: "antigravity", modelID: "starting", name: "Starting")
        let targetModel = RuntimeModel(provider: "antigravity", modelID: "target", name: "Target")
        var savedTarget = saved
        let index = try XCTUnwrap(savedTarget.sessions.firstIndex { $0.id == id })
        savedTarget.sessions[index].selection = .init(provider: targetModel.provider, modelID: targetModel.modelID, thinking: "high")
        for targetLevels in [["medium", "high"], ["medium"]] {
            let runtime = MockACPRuntime(sessionID: "acp-cleared-config", models: [startingModel, targetModel],
                                         thinkingLevels: ["low"],
                                         thinkingLevelsByModel: [startingModel.modelID: ["low"], targetModel.modelID: targetLevels])
            let restored = WorkspaceController(store: ACPMemoryWorkspaceStore(savedTarget), runtimeFactory: { _, _, _ in runtime })
            await restored.start()
            await restored.send(id, submitted: .init(text: "Continue with the saved model"))
            XCTAssertEqual(runtime.submittedTexts, ["Continue with the saved model"])
            let session = try await runtime.currentSession()
            XCTAssertEqual(session.modelID, targetModel.modelID)
            XCTAssertEqual(session.thinking, targetLevels.contains("high") ? "high" : "medium")
            _ = await restored.disconnectAll()
        }
    }

    func testImageOnlyPartialReplayDoesNotClaimAnUnrelatedLocalAttachment() async throws {
        let controller = SessionController()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousFile = root.appendingPathComponent("first.png")
        let matchingFile = root.appendingPathComponent("second.png")
        let supplementalFile = root.appendingPathComponent("path-only.png")
        let replayedImage = Data([2, 3, 4])
        try Data([1, 2, 3]).write(to: previousFile)
        try replayedImage.write(to: matchingFile)
        let first = UserPrompt(text: "", files: [previousFile])
        let second = UserPrompt(text: "", files: [matchingFile, supplementalFile])
        let sentAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 110)
        let recorded = [first, second].map { RecordedMessageRecord(id: $0.id, text: $0.text, files: $0.files, sentAt: sentAt) }
        var turn = RecordedTurnRecord(startedAt: sentAt, endedAt: endedAt, status: .completed)
        turn.modelSubmissionID = second.id
        controller.showCachedHistory([first, second].map { .init(id: "user:\($0.id)", kind: .user, files: $0.files) })
        let placeholder = "请查看以下图片。"
        let fallbackPrefix = "请查看以下文件。\n\n本地文件引用（按需读取）\n"
        let differentFile = root.appendingPathComponent("different.txt")
        let runtime = MockACPRuntime(replayItems: [
            .init(id: "unknown-image", kind: .user, text: placeholder, images: [Data([9, 9, 9])]),
            .init(id: "unreported-reference", kind: .user, text: placeholder, images: [replayedImage]),
            .init(id: "different-reference", kind: .user, text: fallbackPrefix + differentFile.path.debugDescription, images: [replayedImage]),
            .init(id: "second-image", kind: .user, text: fallbackPrefix + supplementalFile.path.debugDescription, images: [replayedImage]),
            .init(id: "second-reply", kind: .assistant, text: "Done"),
        ])
        await controller.connect(runtime, recordedTurns: [turn], recordedMessages: recorded)
        try await waitUntil {
            controller.transcript.contains { $0.id == "second-image" && $0.canRestoreToDraft }
        }
        for id in ["unknown-image", "unreported-reference", "different-reference"] {
            let unmatched = try XCTUnwrap(controller.transcript.first { $0.id == id })
            XCTAssertNil(unmatched.submissionID)
            XCTAssertTrue(unmatched.attachedFiles.isEmpty)
            XCTAssertFalse(unmatched.canRestoreToDraft)
        }
        let restored = try XCTUnwrap(controller.transcript.first { $0.id == "second-image" })
        XCTAssertEqual(restored.submissionID, second.id)
        XCTAssertEqual(restored.sentAt, sentAt)
        XCTAssertEqual(restored.editableText, "")
        XCTAssertEqual(restored.editableFiles, [matchingFile, supplementalFile])
        XCTAssertEqual(restored.images.map(\.data), [replayedImage])
        let confirmedImageFiles = try XCTUnwrap(restored.confirmedReplayImageFiles)
        XCTAssertEqual(confirmedImageFiles, [matchingFile])
        try Data([8, 7, 6]).write(to: matchingFile)
        try replayedImage.write(to: supplementalFile)
        XCTAssertTrue(TranscriptImageFiles.containsInOrder([replayedImage], in: restored.editableFiles))
        XCTAssertFalse(TranscriptImageFiles.containsInOrder([replayedImage], in: confirmedImageFiles))
        let restoredTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(restoredTurn.status, .completed)
        XCTAssertEqual(restoredTurn.endedAt, endedAt)
        _ = await controller.disconnect()
    }

    func testKnownImageReplayVerifiesReportedPathsAndAcceptsLegacyFullList() async throws {
        let controller = SessionController()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageFile = root.appendingPathComponent("image.png")
        let identicalImageFile = root.appendingPathComponent("same-image.png")
        let otherImageFile = root.appendingPathComponent("other.png")
        let notesFile = root.appendingPathComponent("notes.txt")
        let foreignFile = root.appendingPathComponent("foreign.txt")
        let image = Data([2, 3, 4])
        try image.write(to: imageFile)
        try image.write(to: identicalImageFile)
        try Data([4, 3, 2]).write(to: otherImageFile)
        try Data("notes".utf8).write(to: notesFile)
        let verified = UserPrompt(text: "Review files", files: [imageFile, notesFile, otherImageFile])
        let mismatch = UserPrompt(text: "Review other files", files: [imageFile, notesFile])
        let ambiguous = UserPrompt(text: "Review similar files", files: [imageFile, identicalImageFile])
        let records = [verified, mismatch, ambiguous].map { RecordedMessageRecord(id: $0.id, text: $0.text, files: $0.files) }
        let unexpectedPaths = mismatch.text + "\n\n本地文件引用（按需读取）\n" + foreignFile.path.debugDescription
        let runtime = MockACPRuntime(replayItems: [
            .init(id: "user:\(verified.id)", kind: .user, text: verified.runtimeText, images: [image]),
            .init(id: "user:\(mismatch.id)", kind: .user, text: unexpectedPaths, images: [image]),
            .init(id: "user:\(ambiguous.id)", kind: .user, text: ambiguous.runtimeText, images: [image]),
        ])

        await controller.connect(runtime, recordedMessages: records)
        try await waitUntil {
            controller.transcript.contains { $0.submissionID == verified.id && $0.canRestoreToDraft }
        }
        let accepted = try XCTUnwrap(controller.transcript.first { $0.submissionID == verified.id })
        XCTAssertEqual(accepted.editableFiles, verified.files)
        XCTAssertEqual(accepted.confirmedReplayImageFiles, [imageFile])
        let rejected = try XCTUnwrap(controller.transcript.first { $0.submissionID == mismatch.id })
        XCTAssertFalse(rejected.canRestoreToDraft)
        let unverified = try XCTUnwrap(controller.transcript.first { $0.submissionID == ambiguous.id })
        XCTAssertNil(unverified.confirmedReplayImageFiles)
        XCTAssertFalse(unverified.canRestoreToDraft)
        XCTAssertEqual(unverified.images.map(\.data), [image])
        _ = await controller.disconnect()
    }

    func testImageReplayOnlyClaimsAttachmentsInSubmissionOrder() async throws {
        let controller = SessionController()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        let firstImage = Data([1, 2, 3])
        let secondImage = Data([3, 2, 1])
        try firstImage.write(to: first)
        try secondImage.write(to: second)
        let prompt = UserPrompt(text: "Compare these images", files: [first, second])
        let recorded = RecordedMessageRecord(id: prompt.id, text: prompt.text, files: prompt.files)
        let runtime = MockACPRuntime(replayItems: [
            .init(id: "reversed", kind: .user, text: prompt.text, images: [secondImage, firstImage]),
            .init(id: "ordered", kind: .user, text: prompt.text, images: [firstImage, secondImage]),
        ])

        await controller.connect(runtime, recordedMessages: [recorded])
        try await waitUntil {
            controller.transcript.contains { $0.id == "ordered" && $0.canRestoreToDraft }
        }
        let reversed = try XCTUnwrap(controller.transcript.first { $0.id == "reversed" })
        XCTAssertFalse(reversed.canRestoreToDraft)
        XCTAssertNil(reversed.submissionID)
        XCTAssertTrue(reversed.editableFiles.isEmpty)
        XCTAssertEqual(reversed.images.map(\.data), [secondImage, firstImage])
        let ordered = try XCTUnwrap(controller.transcript.first { $0.id == "ordered" })
        XCTAssertEqual(ordered.submissionID, prompt.id)
        XCTAssertEqual(ordered.editableFiles, prompt.files)
        _ = await controller.disconnect()
    }

    func testOlderSessionSnapshotCannotRestoreWithdrawnConfiguration() async {
        let controller = SessionController()
        let runtime = MockACPRuntime()
        await controller.connect(runtime)
        func notify(revision: Int, modes: [RuntimeModeOption]) {
            let session = RuntimeSession(id: runtime.sessionID, model: "Default", thinking: "—",
                                         capabilities: modes.isEmpty ? [] : [.modeSelection],
                                         availableModes: modes, configurationRevision: revision)
            controller.receive(.init(instanceID: runtime.instanceID, event: .sessionUpdated(session)))
        }
        notify(revision: 2, modes: [])
        notify(revision: 1, modes: [.init(id: "plan", name: "Plan")])
        XCTAssertEqual(controller.session?.configurationRevision, 2)
        XCTAssertEqual(controller.session?.availableModes, [])
        _ = await controller.disconnect()
    }

    func testACPHistoryPreservesAttachedImagesAndTurnEndTimesAcrossRestartAndLegacyCache() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("pasted-screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imageURL)

        let store = ACPMemoryWorkspaceStore()
        let firstRuntime = MockACPRuntime(sessionID: "acp-media-1", resumable: true, modeID: "auto")
        let workspace = WorkspaceController(
            store: store,
            runtimeFactory: { _, _, _ in firstRuntime }
        )
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset(executablePath: "/opt/homebrew/bin/agy")])
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)
        _ = await workspace.addProject(root)
        let sessionID = try XCTUnwrap(workspace.selected?.id)

        // Turn 1: image-only user message + tool + assistant
        await workspace.send(sessionID, submitted: UserPrompt(text: "", files: [imageURL]))
        firstRuntime.emit(.tool(.init(id: "t-img", name: "read", state: .completed)))
        let a1 = UUID()
        firstRuntime.emit(.assistantStarted(a1))
        firstRuntime.emit(.assistantCompleted(a1, "Analyzed screenshot."))
        firstRuntime.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: sessionID)?.phase == .idle }

        // Turn 2: text + image user message + assistant
        await workspace.send(sessionID, submitted: UserPrompt(text: "Why is time unknown?", files: [imageURL]))
        let a2 = UUID()
        firstRuntime.emit(.assistantStarted(a2))
        firstRuntime.emit(.assistantCompleted(a2, "Fixed timestamp persistence."))
        firstRuntime.emit(.failure(.init(.model, "Synthetic model error")))
        firstRuntime.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: sessionID)?.phase == .idle }
        let disconnected = await workspace.disconnect(sessionID)
        XCTAssertTrue(disconnected)

        // Verify new cache persists files and endedAt directly.
        let saved = await store.load()
        let savedSession = try XCTUnwrap(saved.sessions.first { $0.id == sessionID })
        let cachedUsers = (savedSession.cachedHistoryItems ?? []).filter { $0.kind == .user }
        XCTAssertEqual(cachedUsers.count, 2)
        XCTAssertEqual(cachedUsers[0].files, [imageURL])
        XCTAssertEqual(cachedUsers[1].files, [imageURL])
        XCTAssertTrue((savedSession.cachedHistoryItems ?? []).filter { $0.kind == .assistant }.allSatisfy { $0.endedAt != nil })

        // Simulate legacy cache (before files/endedAt were stored on CachedTranscriptItem) while recordedTurns/Messages exist.
        var legacySnapshot = saved
        let idx = try XCTUnwrap(legacySnapshot.sessions.firstIndex { $0.id == sessionID })
        legacySnapshot.sessions[idx].cachedHistoryItems = savedSession.cachedHistoryItems?.map {
            CachedTranscriptItem(id: $0.id, kind: $0.kind, text: $0.text, tool: $0.tool, sentAt: $0.sentAt, endedAt: nil, files: nil)
        }
        try await store.save(legacySnapshot)

        let replayedItems: [HistoryItem] = [
            HistoryItem(id: "r-u1", kind: .user, text: "请查看以下图片。"),
            HistoryItem(id: "r-t1", kind: .tool, tool: .init(id: "t-img", name: "read", state: .completed)),
            HistoryItem(id: "r-a1", kind: .assistant, text: "Analyzed screenshot."),
            HistoryItem(id: "r-u2", kind: .user, text: "Why is time unknown?"),
            HistoryItem(id: "r-a2", kind: .assistant, text: "Fixed timestamp persistence.")
        ]
        let secondRuntime = MockACPRuntime(sessionID: "acp-media-1", resumable: true, modeID: "auto", replayItems: replayedItems)
        let reopened = WorkspaceController(
            store: store,
            runtimeFactory: { _, _, _ in secondRuntime }
        )
        await reopened.start()

        // Offline cache must recover both attachedFiles and endedAt from recordedTurns/recordedMessages.
        let offlineUsers = try XCTUnwrap(reopened.viewed?.controller.transcript.filter { $0.kind == .user })
        let offlineAssistants = try XCTUnwrap(reopened.viewed?.controller.transcript.filter { $0.kind == .assistant })
        XCTAssertEqual(offlineUsers.count, 2)
        XCTAssertEqual(offlineUsers[0].attachedFiles, [imageURL])
        XCTAssertEqual(offlineUsers[1].attachedFiles, [imageURL])
        XCTAssertNotNil(offlineAssistants[0].turn?.endedAt)
        XCTAssertNotNil(offlineAssistants[1].turn?.endedAt)
        XCTAssertEqual(offlineAssistants.compactMap { $0.turn?.status }, [.completed, .failed])
        XCTAssertTrue(offlineAssistants.allSatisfy { $0.turn?.isHistoricalOutcomeMissing == false })

        // After session/load replay, images, empty originalText for image-only message, sentAt, and endedAt must all remain intact.
        let activated = await reopened.activate(sessionID)
        XCTAssertTrue(activated)
        try await waitUntil { reopened.viewed?.controller.showingCachedHistory == false }
        let replayedUsers = try XCTUnwrap(reopened.viewed?.controller.transcript.filter { $0.kind == .user })
        let replayedAssistants = try XCTUnwrap(reopened.viewed?.controller.transcript.filter { $0.kind == .assistant })
        XCTAssertEqual(replayedUsers.count, 2)
        XCTAssertEqual(replayedUsers[0].attachedFiles, [imageURL])
        XCTAssertEqual(replayedUsers[0].editableText, "")
        XCTAssertNotNil(replayedUsers[0].sentAt)
        XCTAssertEqual(replayedUsers[1].attachedFiles, [imageURL])
        XCTAssertEqual(replayedUsers[1].editableText, "Why is time unknown?")
        XCTAssertNotNil(replayedUsers[1].sentAt)
        XCTAssertNotNil(replayedAssistants[0].turn?.endedAt)
        XCTAssertNotNil(replayedAssistants[1].turn?.endedAt)
        XCTAssertEqual(replayedAssistants.compactMap { $0.turn?.status }, [.completed, .failed])
        XCTAssertTrue(replayedAssistants.allSatisfy { $0.turn?.isHistoricalOutcomeMissing == false })
        _ = await reopened.disconnectAll()
    }

    func testACPReplayDoesNotAssignAnUnanchoredOutcomeToTheLastVisibleReply() async throws {
        let runtime = MockACPRuntime(sessionID: "replay", resumable: true, modeID: "auto", replayItems: [
            .init(id: "user", kind: .user, text: "Imported request"),
            .init(id: "tool", kind: .tool, tool: .init(id: "matched", name: "read", state: .completed)),
            .init(id: "assistant-1", kind: .assistant, text: "Tool reply"),
            .init(id: "user-2", kind: .user, text: "Another request"),
            .init(id: "assistant-2", kind: .assistant, text: "The session replay has no outcome"),
        ])
        let controller = SessionController()
        await controller.connect(runtime, recordedTurns: [
            .init(anchorToolCallID: "matched", status: .stopped),
            .init(status: .completed),
        ])
        try await waitUntil { controller.transcript.count == 5 }
        let turns = controller.transcript.filter { $0.kind == .assistant }.compactMap(\.turn)
        XCTAssertEqual(turns.map(\.status), [.stopped, .uncertain])
        XCTAssertEqual(turns.map(\.isHistoricalOutcomeMissing), [false, true])
        _ = await controller.disconnect()
    }

    func testNonResumableACPHistoryRejectsNewExecutionAfterRestart() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        let history = [CachedTranscriptItem(id: "old-reply", kind: .assistant, text: "Past conversation")]

        let originalIDs: [String?] = ["old-session", nil]
        for originalID in originalIDs {
            var reference = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
            reference.runtimeSessionID = originalID
            reference.resumableSession = false
            reference.cachedHistoryItems = history
            reference.draft = "Keep until moved to a new session"
            var snapshot = WorkspaceSnapshot()
            snapshot.projects = [project]
            snapshot.sessions = [reference]
            snapshot.selectedSessionID = reference.id
            let store = ACPMemoryWorkspaceStore(snapshot)
            let reopened = WorkspaceController(store: store) { _, _ in
                XCTFail("A read-only ACP conversation must not launch another runtime")
                return MockACPRuntime(resumable: false)
            }

            await reopened.start()
            XCTAssertNotNil(reopened.viewed?.executionIssue)
            XCTAssertEqual(reopened.viewed?.controller.transcript.last?.text, "Past conversation")
            let activated = await reopened.activate(reference.id)
            XCTAssertFalse(activated)
            await reopened.send(reference.id)
            XCTAssertTrue(reopened.executionIDs.isEmpty)
            XCTAssertEqual(reopened.viewed?.controller.draft, reference.draft)
            let saved = await store.load()
            XCTAssertEqual(saved.sessions.first?.runtimeSessionID, originalID)
            XCTAssertEqual(saved.sessions.first?.cachedHistoryItems, history)
        }
    }

    func testACPIdleSessionsRemainOpenUntilAnOperationReleasesThem() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var runtimeBySession: [UUID: MockACPRuntime] = [:]
        let nextResumable = OSAllocatedUnfairLock(initialState: false)
        let workspace = WorkspaceController(
            store: ACPMemoryWorkspaceStore(),
            runtimeFactory: { _, reference, _ in
                let runtime = MockACPRuntime(sessionID: "acp-\(reference.id.uuidString)",
                                             resumable: nextResumable.withLock { $0 })
                runtimeBySession[reference.id] = runtime
                return runtime
            }
        )
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)
        let addedProjectID = await workspace.addProject(root)
        let projectID = try XCTUnwrap(addedProjectID)

        let nonResumableWithHistory = try XCTUnwrap(workspace.selected?.id)
        await workspace.send(nonResumableWithHistory, submitted: UserPrompt(text: "Keep me alive"))
        runtimeBySession[nonResumableWithHistory]?.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: nonResumableWithHistory)?.phase == .idle }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(workspace.execution(for: nonResumableWithHistory)?.connection, .connected)

        let createdEmptySession = await workspace.createSession(in: projectID)
        let emptySession = try XCTUnwrap(createdEmptySession)
        let emptyActivated = await workspace.activate(emptySession)
        XCTAssertTrue(emptyActivated)

        let createdResumableSession = await workspace.createSession(in: projectID)
        let resumableWithHistory = try XCTUnwrap(createdResumableSession)
        nextResumable.withLock { $0 = true }
        await workspace.send(resumableWithHistory, submitted: UserPrompt(text: "Can resume later"))
        runtimeBySession[resumableWithHistory]?.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: resumableWithHistory)?.phase == .idle }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(workspace.execution(for: emptySession)?.connection, .connected)
        XCTAssertEqual(workspace.execution(for: resumableWithHistory)?.connection, .connected)
        XCTAssertEqual(workspace.execution(for: nonResumableWithHistory)?.connection, .connected)

        _ = await workspace.disconnectAll()
    }

    func testRuntimeSwitchingModelRoutingAndACPModePersistence() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstModel = RuntimeModel(provider: "openai", modelID: "gpt-5", name: "GPT-5")
        let acpModelA = RuntimeModel(provider: "antigravity", modelID: "gemini-pro", name: "Gemini Pro")
        let acpModelB = RuntimeModel(provider: "antigravity", modelID: "claude-opus", name: "Claude Opus")
        var inspectedRuntimes: [String] = []
        var createdACPRuntimes: [MockACPRuntime] = []

        let workspace = WorkspaceController(
            store: ACPMemoryWorkspaceStore(),
            inspectRuntimeModels: { runtimeID, _ in
                inspectedRuntimes.append(runtimeID)
                if runtimeID == "acp:first" {
                    return RuntimeConfigurationOptions(models: [firstModel], thinkingLevels: ["off", "high"])
                }
                return RuntimeConfigurationOptions(models: [acpModelA, acpModelB], thinkingLevels: ["off", "low", "high"])
            },
            runtimeFactory: { _, reference, _ in
                if reference.runtimeID == "acp:first" {
                    return FakeRuntime()
                }
                let runtime = MockACPRuntime(
                    sessionID: "acp-mode-test",
                    runtimeID: reference.runtimeID,
                    resumable: true,
                    modeID: "default",
                    models: [acpModelA, acpModelB]
                )
                createdACPRuntimes.append(runtime)
                return runtime
            }
        )
        await workspace.start()
        workspace.setACPAgents([.customACP(id: "acp:first", name: "First", executablePath: "/unused"), .antigravityPreset(executablePath: "/opt/homebrew/bin/agy")])
        XCTAssertEqual(workspace.availableRuntimes.map(\.id), ["acp:first", RuntimeAgentProfile.antigravityRuntimeID])
        XCTAssertEqual(workspace.runtimeDisplayName(for: "acp:first"), "First")
        XCTAssertEqual(workspace.runtimeDisplayName(for: RuntimeAgentProfile.antigravityRuntimeID), "Antigravity")

        let savedFirstDefault = await workspace.setDefaultModel(firstModel, forRuntime: "acp:first")
        let savedACPDefault = await workspace.setDefaultModel(acpModelA, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let savedACPFav = await workspace.setFavoriteModel(acpModelB, isFavorite: true, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let savedACPHidden = await workspace.setModelVisible(acpModelB, isVisible: false, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertTrue(savedFirstDefault && savedACPDefault && savedACPFav && savedACPHidden)

        XCTAssertEqual(workspace.modelPreferences(forRuntime: "acp:first").defaultModel, firstModel)
        XCTAssertTrue(workspace.modelPreferences(forRuntime: "acp:first").favorites.isEmpty)
        XCTAssertEqual(workspace.modelPreferences(forRuntime: RuntimeAgentProfile.antigravityRuntimeID).defaultModel, acpModelA)
        XCTAssertEqual(workspace.modelPreferences(forRuntime: RuntimeAgentProfile.antigravityRuntimeID).favorites, [acpModelB])
        XCTAssertEqual(workspace.modelPreferences(forRuntime: RuntimeAgentProfile.antigravityRuntimeID).hiddenModelIDs, [acpModelB.id])

        let added = await workspace.addProject(root)
        _ = try XCTUnwrap(added)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        XCTAssertEqual(workspace.selected?.runtimeID, "acp:first")
        XCTAssertEqual(workspace.selected?.pendingSelection?.modelID, firstModel.modelID)

        // Unbound session can switch to an enabled ACP runtime and picks up that runtime's default model.
        let switchedToACP = await workspace.setSessionRuntime(RuntimeAgentProfile.antigravityRuntimeID, for: sessionID)
        XCTAssertTrue(switchedToACP)
        XCTAssertEqual(workspace.selected?.runtimeID, RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertEqual(workspace.selected?.pendingSelection?.modelID, acpModelA.modelID)

        // Model queries route by session's runtimeID.
        let catalogue = try await workspace.modelCatalogue(for: sessionID)
        let levels = try await workspace.thinkingLevels(for: sessionID, model: acpModelA)
        XCTAssertEqual(catalogue, [acpModelA, acpModelB])
        XCTAssertEqual(levels, ["off", "low", "high"])
        XCTAssertEqual(inspectedRuntimes, [RuntimeAgentProfile.antigravityRuntimeID, RuntimeAgentProfile.antigravityRuntimeID])

        // Setting ACP mode while disconnected persists runtimeModeID and applies it upon connecting.
        let modeSavedOffline = await workspace.setACPMode("plan", for: sessionID)
        XCTAssertTrue(modeSavedOffline)
        XCTAssertEqual(workspace.selected?.runtimeModeID, "plan")

        await workspace.send(sessionID, submitted: UserPrompt(text: "Hello ACP"))
        let activeRuntime = try XCTUnwrap(createdACPRuntimes.last)
        XCTAssertEqual(activeRuntime.appliedModes, ["plan"])
        XCTAssertEqual(workspace.execution(for: sessionID)?.session?.modeID, "plan")

        // Bound or connected session cannot switch runtimes.
        let blockedWhileConnected = await workspace.setSessionRuntime("acp:first", for: sessionID)
        XCTAssertFalse(blockedWhileConnected)

        activeRuntime.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: sessionID)?.phase == .idle }

        // Switching ACP mode while connected & idle calls runtime.setMode immediately.
        let switchedLiveMode = await workspace.setACPMode("auto", for: sessionID)
        XCTAssertTrue(switchedLiveMode)
        XCTAssertEqual(activeRuntime.appliedModes, ["plan", "auto"])
        XCTAssertEqual(workspace.selected?.runtimeModeID, "auto")

        _ = await workspace.disconnect(sessionID)
        let blockedAfterBound = await workspace.setSessionRuntime("acp:first", for: sessionID)
        XCTAssertFalse(blockedAfterBound)

        // Disabling the default ACP agent leaves no enabled runtime.
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertEqual(workspace.defaultRuntimeID, RuntimeAgentProfile.antigravityRuntimeID)
        var disabled = RuntimeAgentProfile.antigravityPreset()
        disabled.enabled = false
        workspace.setACPAgents([disabled])
        XCTAssertNil(workspace.defaultRuntimeID)
        XCTAssertEqual(workspace.availableRuntimes.map(\.id), [])
    }
}
