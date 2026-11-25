import XCTest
import Foundation
import Observation
import AgentRuntimeCore
import OrchestrationCore

private actor ACPMemoryWorkspaceStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    var fail = false

    init(_ snapshot: WorkspaceSnapshot = .init()) {
        self.snapshot = snapshot
    }

    func load() -> WorkspaceSnapshot { snapshot }

    func setFailure(_ value: Bool) { fail = value }

    func save(_ value: WorkspaceSnapshot) async throws {
        if fail { throw RuntimeFailure(.setup, "injected storage error") }
        if value.revision > snapshot.revision { snapshot = value }
    }
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
        thinkingLevels: [String] = ["off", "low", "high"]
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
        RuntimeConfigurationOptions(models: models, thinkingLevels: thinkingLevelsList)
    }

    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        guard let matched = models.first(where: { $0.provider == selection.provider && $0.modelID == selection.modelID }) else {
            throw RuntimeFailure(.model, "Unknown ACP model")
        }
        lock.withLock {
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
            .appendingPathComponent("Pikachu-ACPWorkspaceTests-\(UUID())", isDirectory: true)
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
        do {
            try await workspace.deleteRemoteHistory(id) { _, _, _ in throw RuntimeFailure(.outcomeUnknown, "Timeout") }
            XCTFail("Expected the first remote deletion to fail")
        } catch let error as RuntimeFailure {
            XCTAssertEqual(error.kind, .outcomeUnknown)
        }
        XCTAssertNil(workspace.selected?.remoteHistoryDeleted)
        try await workspace.deleteRemoteHistory(id) { _, _, _ in }
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
        do {
            try await workspace.deleteRemoteHistory(id) { _, _, _ in throw RuntimeFailure(.outcomeUnknown, "Timeout") }
            XCTFail("An unknown outcome must be reported")
        } catch let error as RuntimeFailure {
            XCTAssertEqual(error.kind, .outcomeUnknown)
        }
        XCTAssertNil(workspace.state.sessions.first?.remoteHistoryDeleted)
        try await workspace.deleteRemoteHistory(id) { actualAgent, _, actualRemoteID in
            XCTAssertEqual(actualAgent, agentID)
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
        _ = await reopened.disconnectAll()
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

    func testACPIdleReapProtectsNonResumableSessionWithHistoryButReapsResumableAndEmptySessions() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var runtimeBySession: [UUID: MockACPRuntime] = [:]
        var nextResumable = false
        let workspace = WorkspaceController(
            store: ACPMemoryWorkspaceStore(),
            idleRuntimeTimeout: .milliseconds(80),
            runtimeFactory: { _, reference, _ in
                let runtime = MockACPRuntime(sessionID: "acp-\(reference.id.uuidString)", resumable: nextResumable)
                runtimeBySession[reference.id] = runtime
                return runtime
            }
        )
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        workspace.setDefaultRuntimeID(RuntimeAgentProfile.antigravityRuntimeID)
        let addedProjectID = await workspace.addProject(root)
        let projectID = try XCTUnwrap(addedProjectID)

        // 1. Non-resumable ACP session with active conversation history MUST NOT be idle-reaped.
        let nonResumableWithHistory = try XCTUnwrap(workspace.selected?.id)
        nextResumable = false
        await workspace.send(nonResumableWithHistory, submitted: UserPrompt(text: "Keep me alive"))
        runtimeBySession[nonResumableWithHistory]?.emit(.settled(aborted: false))
        try await waitUntil { workspace.execution(for: nonResumableWithHistory)?.phase == .idle }
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(workspace.execution(for: nonResumableWithHistory)?.connection, .connected)

        // 2. Non-resumable ACP session with empty transcript CAN be idle-reaped.
        let createdEmptySession = await workspace.createSession(in: projectID)
        let emptySession = try XCTUnwrap(createdEmptySession)
        nextResumable = false
        let emptyActivated = await workspace.activate(emptySession)
        XCTAssertTrue(emptyActivated)
        try await waitUntil { !workspace.isOperating(on: emptySession) && workspace.execution(for: emptySession) == nil }

        // 3. Resumable ACP session with history CAN be idle-reaped because session/load can resume it.
        let createdResumableSession = await workspace.createSession(in: projectID)
        let resumableWithHistory = try XCTUnwrap(createdResumableSession)
        nextResumable = true
        await workspace.send(resumableWithHistory, submitted: UserPrompt(text: "Can resume later"))
        runtimeBySession[resumableWithHistory]?.emit(.settled(aborted: false))
        try await waitUntil { !workspace.isOperating(on: resumableWithHistory) && workspace.execution(for: resumableWithHistory) == nil }

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
