import XCTest
import Foundation
import Observation
import AgentRuntimeCore
import OrchestrationCore
import WorkspacePersistence
@testable import Pikachu

private actor MemoryWorkspaceStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    var fail = false
    private var deletionBegan: XCTestExpectation?
    private var resumeDeletion: CheckedContinuation<Void, Never>?
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func setFailure(_ value: Bool) { fail = value }
    func pauseNextDeletion(began: XCTestExpectation) { deletionBegan = began }
    func releaseDeletion() {
        resumeDeletion?.resume()
        resumeDeletion = nil
    }
    func save(_ value: WorkspaceSnapshot) async throws {
        if let began = deletionBegan,
           value.projects.count < snapshot.projects.count || value.sessions.count < snapshot.sessions.count {
            deletionBegan = nil
            await withCheckedContinuation { continuation in
                resumeDeletion = continuation
                began.fulfill()
            }
        }
        if fail { throw RuntimeFailure(.setup, "injected storage error") }
        if value.revision > snapshot.revision { snapshot = value }
    }
}
private actor DirectoryFailureStore: WorkspaceStore {
    private var snapshot = WorkspaceSnapshot()
    private var failure: (path: String, began: XCTestExpectation)?
    private var resumeWrite: CheckedContinuation<Void, Never>?

    func load() -> WorkspaceSnapshot { snapshot }

    func pauseAndFailChoice(of path: String, began: XCTestExpectation) {
        failure = (path, began)
    }

    func finishFailedChoice() {
        failure = nil
        resumeWrite?.resume()
        resumeWrite = nil
    }

    func save(_ value: WorkspaceSnapshot) async throws {
        if let failure, value.sessions.contains(where: { $0.worktreePath == failure.path }) {
            self.failure = nil
            await withCheckedContinuation { continuation in
                resumeWrite = continuation
                failure.began.fulfill()
            }
            throw RuntimeFailure(.setup, "directory write failed")
        }
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private final class WorkspaceTestRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let sink: AsyncStream<RuntimeEnvelope>.Continuation
    let lock = NSLock()
    private var sends = 0
    private var stops = 0
    private var promptTexts: [String] = []
    var sendCount: Int { lock.withLock { sends } }
    var stopCount: Int { lock.withLock { stops } }
    var submittedTexts: [String] { lock.withLock { promptTexts } }
    let closeFails: Bool
    let resumable: Bool
    let onConnect: @Sendable () async -> Void
    let identity: String
    let file: URL?
    init(closeFails: Bool = false, identity: String = UUID().uuidString, file: URL? = nil, resumable: Bool = false,
         onConnect: @escaping @Sendable () async -> Void = {}) {
        self.onConnect = onConnect
        self.resumable = resumable
        self.closeFails = closeFails
        self.identity = identity; self.file = file
        let pair = AsyncStream<RuntimeEnvelope>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func connect() async throws -> RuntimeSession {
        await onConnect()
        return .init(id: identity, model: "test", thinking: "low", capabilities: [.streaming, .interruption], file: file, resumable: resumable)
    }
    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { lock.withLock { sends += 1; promptTexts.append(prompt.text) }; emit(.phase(.running)); return .started }
    func stop() async throws { lock.withLock { stops += 1 }; emit(.settled(aborted: true)) }
    func close(force: Bool) async throws {
        if closeFails { throw RuntimeFailure(.supervision, "injected unknown cleanup") }
        emit(.disconnected(cleanupConfirmed: true)); sink.finish()
    }
    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {
        emit(.interactionEnded(request.id, .answered))
    }
    func configurationOptions() async throws -> RuntimeConfigurationOptions { .init(models: [], thinkingLevels: []) }
    func emit(_ event: AgentEvent) { sink.yield(.init(instanceID: instanceID, event: event)) }
}
@MainActor final class WorkspaceTests: XCTestCase {

    func testRuntimeEnvironmentsPersistIndependentlyAndRemovalIsAtomic() async throws {
        let store = MemoryWorkspaceStore()
        func controller() -> WorkspaceController {
            WorkspaceController(store: store) { _, _ in FakeRuntime() }
        }

        let workspace = controller()
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/usr/bin/true")
        let second = RuntimeAgentProfile(id: "acp:second", name: "Second", executablePath: "/usr/bin/true")
        workspace.setACPAgents([first, second])

        let savedFirst = await workspace.setRuntimeEnvironment(["SAMPLE": "one"], for: first.id)
        let savedSecond = await workspace.setRuntimeEnvironment(["SAMPLE": "two"], for: second.id)
        XCTAssertTrue(savedFirst && savedSecond)

        let reopened = controller()
        await reopened.start()
        XCTAssertEqual(reopened.runtimeEnvironment(for: first.id), ["SAMPLE": "one"])
        XCTAssertEqual(reopened.runtimeEnvironment(for: second.id), ["SAMPLE": "two"])

        await store.setFailure(true)
        let savedOnFailure = await reopened.setRuntimeEnvironment(["SAMPLE": "new"], for: first.id)
        let removedOnFailure = await reopened.removeACPAgent(id: first.id)
        XCTAssertFalse(savedOnFailure)
        XCTAssertFalse(removedOnFailure)
        XCTAssertEqual(reopened.runtimeEnvironment(for: first.id), ["SAMPLE": "one"])
        XCTAssertEqual(reopened.acpAgents.map(\.id), [first.id, second.id])

        await store.setFailure(false)
        let removed = await reopened.removeACPAgent(id: first.id)
        XCTAssertTrue(removed)
        let durable = await store.load()
        XCTAssertEqual(durable.preferences.acpAgents?.map(\.id), [second.id])
        XCTAssertNil(durable.runtimeEnvironments?[first.id])
        XCTAssertEqual(durable.runtimeEnvironments?[second.id], ["SAMPLE": "two"])
    }


    func testDraftDeletionRequiresUnboundSessionAndSuccessfulSave() async throws {
        let project = ProjectRecord(path: FileManager.default.currentDirectoryPath)
        var draft = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        draft.draft = "Keep until saved"
        var bound = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        bound.runtimeSessionID = "agent-session"
        bound.resumableSession = true
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [draft, bound]
        snapshot.selectedSessionID = draft.id
        let store = MemoryWorkspaceStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])

        let deletedBound = await workspace.deleteDraft(bound.id, discardContents: true)
        XCTAssertFalse(deletedBound)
        let deletedWithoutConfirmation = await workspace.deleteDraft(draft.id)
        XCTAssertFalse(deletedWithoutConfirmation)
        await store.setFailure(true)
        let failed = await workspace.deleteDraft(draft.id, discardContents: true)
        XCTAssertFalse(failed)
        XCTAssertEqual(workspace.viewed?.controller.draft, draft.draft)
        XCTAssertEqual(workspace.state.selectedSessionID, draft.id)

        await store.setFailure(false)
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        let deleted = await workspace.deleteDraft(draft.id, discardContents: true)
        XCTAssertTrue(deleted)
        let persisted = await store.load()
        XCTAssertEqual(persisted.sessions.map(\.id), [bound.id])
        XCTAssertNil(persisted.selectedSessionID)
        XCTAssertNil(workspace.viewed)
        XCTAssertNil(workspace.presentations[draft.id])
    }

    func testDeletingEmptyDraftRejectsEditsUntilFailedWriteReturns() async throws {
        let project = ProjectRecord(path: FileManager.default.currentDirectoryPath)
        let draft = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [draft]
        snapshot.selectedSessionID = draft.id
        let store = MemoryWorkspaceStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        let began = expectation(description: "Draft deletion snapshot write started")
        await store.pauseNextDeletion(began: began)
        let deletion = Task { await workspace.deleteDraft(draft.id) }
        await fulfillment(of: [began], timeout: 2)

        XCTAssertTrue(controller.isDraftEditingLocked)
        controller.draft = "Late keystrokes"
        controller.draftFiles.append(URL(fileURLWithPath: "/late-attachment"))
        XCTAssertTrue(controller.draft.isEmpty)
        XCTAssertTrue(controller.draftFiles.isEmpty)

        await store.setFailure(true)
        await store.releaseDeletion()
        let deleted = await deletion.value
        XCTAssertFalse(deleted)
        XCTAssertFalse(controller.isDraftEditingLocked)
        controller.draft = "Editing resumed"
        XCTAssertEqual(controller.draft, "Editing resumed")
        XCTAssertEqual(workspace.state.selectedSessionID, draft.id)
    }

    func testModelPreferencesPersistAndDefaultAppliesOnlyToNewSessions() async throws {
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store,
                                            inspectModels: { FakeRuntime.options(for: $0) }) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let added = await workspace.addProject(directory, createInitialSession: true)
        let project = try XCTUnwrap(added)
        let existing = try XCTUnwrap(workspace.selected?.id)
        let catalogue = try await workspace.modelCatalogue(forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let defaultModel = try XCTUnwrap(catalogue.first { $0.modelID == "demo-reasoning" })
        let otherModel = try XCTUnwrap(catalogue.first { $0.id != defaultModel.id })

        let defaultSaved = await workspace.setDefaultModel(defaultModel, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let favoriteSaved = await workspace.setFavoriteModel(defaultModel, isFavorite: true, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let visibilitySaved = await workspace.setModelVisible(otherModel, isVisible: false, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertTrue(defaultSaved && favoriteSaved && visibilitySaved)
        XCTAssertNil(workspace.state.sessions.first { $0.id == existing }?.pendingSelection)

        let snapshot = await store.load()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        let reopened = WorkspaceController(store: MemoryWorkspaceStore(decoded)) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.state.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID]?.defaultModel, defaultModel)
        XCTAssertEqual(reopened.state.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID]?.favorites, [defaultModel])
        XCTAssertEqual(reopened.state.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID]?.hiddenModelIDs, [otherModel.id])
        let created = await reopened.createSession(in: project)
        let session = try XCTUnwrap(created)
        XCTAssertEqual(reopened.selected?.pendingModelName, defaultModel.name)
        XCTAssertEqual(reopened.selected?.pendingSelection?.modelID, defaultModel.modelID)
        XCTAssertTrue(reopened.executionIDs.isEmpty)

        let prompt = UserPrompt(text: "/handled")
        await reopened.send(session, submitted: prompt)
        let execution = reopened.execution(for: session)
        XCTAssertEqual(execution?.session?.modelID, defaultModel.modelID)
        XCTAssertEqual(execution?.transcript.first { $0.id == "user:\(prompt.id)" }?.delivery, .handled)
        XCTAssertNil(reopened.selected?.pendingSelection)

        let cleared = await reopened.setDefaultModel(nil, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertTrue(cleared)
        let next = await reopened.createSession(in: project)
        XCTAssertNotNil(next)
        XCTAssertNil(reopened.selected?.pendingSelection)
        XCTAssertEqual(reopened.state.sessions.first { $0.id == session }?.selection?.modelID, defaultModel.modelID)
        _ = await reopened.disconnectAll(force: true)
    }

    func testModelPickerFiltersFavoritesAndHiddenModelsButKeepsCurrentModel() {
        let favorite = RuntimeModel(provider: "one", modelID: "model", name: "Favorite")
        let ordinary = RuntimeModel(provider: "two", modelID: "model", name: "Ordinary")
        let hidden = RuntimeModel(provider: "two", modelID: "hidden", name: "Hidden and starred")
        let current = RuntimeModel(provider: "two", modelID: "current", name: "Current and hidden")
        let catalogue = [ordinary, favorite, hidden, current]
        var preferences = WorkspaceModelPreferences()
        preferences.favorites = [favorite, hidden]
        preferences.hiddenModelIDs = [hidden.id, current.id]
        XCTAssertEqual(preferences.pickerModels(from: catalogue, keeping: [current.id], showAll: false), [favorite, current])
        XCTAssertEqual(preferences.pickerModels(from: catalogue, keeping: [current.id], showAll: true), [ordinary, favorite, current])
        XCTAssertEqual(preferences.pickerModels(from: [ordinary, hidden], keeping: [], showAll: false), [ordinary])
        XCTAssertTrue(preferences.pickerModels(from: [hidden], keeping: [], showAll: true).isEmpty)
    }

    func testOlderWorkspaceHasNoModelPreferencesAndFailedSaveDoesNotPublishThem() async throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceSnapshot())) as? [String: Any])
        legacy.removeValue(forKey: "modelPreferences")
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertNil(snapshot.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID])
        let store = MemoryWorkspaceStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        await store.setFailure(true)
        let saved = await workspace.setDefaultModel(FakeRuntime.models[0], forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertFalse(saved)
        XCTAssertNil(workspace.state.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID])
        XCTAssertNotNil(workspace.storageError)
    }

    func testFailedSessionModelSavePreservesPreviousSelectionAndDraft() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let first = RuntimeSelection(provider: "pi", modelID: "first", thinking: "low")
        let second = RuntimeSelection(provider: "pi", modelID: "second", thinking: "high")
        let savedFirst = await workspace.saveSelection(first, name: "First", for: id)
        XCTAssertTrue(savedFirst)
        workspace.viewed?.controller.draft = "Unsent draft"
        await store.setFailure(true)
        let failed = await workspace.saveSelection(second, name: "Second", for: id)
        XCTAssertFalse(failed)
        XCTAssertEqual(workspace.selected?.pendingSelection, first)
        XCTAssertEqual(workspace.selected?.pendingModelName, "First")
        XCTAssertEqual(workspace.viewed?.controller.draft, "Unsent draft")
        await store.setFailure(false)
        let retried = await workspace.saveSelection(second, name: "Second", for: id)
        XCTAssertTrue(retried)
        XCTAssertEqual(workspace.selected?.pendingSelection, second)
        let persisted = await store.load()
        XCTAssertEqual(persisted.sessions.first?.pendingSelection, second)
        XCTAssertEqual(persisted.sessions.first?.draft, "Unsent draft")
    }


    func testSettingsProjectOperationsPreserveSelectedSession() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let added = root.appendingPathComponent("second")
        let moved = root.appendingPathComponent("moved")
        for path in [first, added, moved] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        }
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(first)
        let selected = try XCTUnwrap(workspace.state.selectedSessionID)
        let opened = await workspace.addProject(added, createInitialSession: false)
        let projectID = try XCTUnwrap(opened)
        XCTAssertFalse(workspace.state.sessions.contains { $0.projectID == projectID })

        let conflict = await workspace.relocateProject(projectID, to: first)
        XCTAssertEqual(conflict?.warning, true)
        let relocated = await workspace.relocateProject(projectID, to: moved)
        XCTAssertEqual(relocated?.warning, false)
        XCTAssertEqual(workspace.state.selectedSessionID, selected)
        let project = try XCTUnwrap(workspace.state.projects.first { $0.id == projectID })
        XCTAssertEqual(project.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(project.previousPaths, [added.resolvingSymlinksInPath().path])
    }

    func testProjectDisplayNamePreservesCaseAndIdentityAcrossRelocationAndRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("current")
        let moved = root.appendingPathComponent("after")
        for path in [original, moved] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(original)
        let id = try XCTUnwrap(added)
        let before = try XCTUnwrap(workspace.selected)
        let legacy = try JSONDecoder().decode(ProjectRecord.self, from: JSONEncoder().encode(workspace.state.projects[0]))
        XCTAssertNil(legacy.customDisplayName)
        XCTAssertEqual(legacy.displayName, "Current")
        let invalid = await workspace.setProjectDisplayName("a\nb", for: id)
        XCTAssertFalse(invalid)
        await store.setFailure(true)
        let failed = await workspace.setProjectDisplayName("unsaved", for: id)
        XCTAssertFalse(failed)
        XCTAssertNil(workspace.state.projects[0].customDisplayName)
        await store.setFailure(false)
        let renamed = await workspace.setProjectDisplayName("  pIKachu  ", for: id)
        XCTAssertTrue(renamed)
        let relocated = await workspace.relocateProject(id, to: moved)
        XCTAssertEqual(relocated?.warning, false)
        let reopened = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.state.projects[0].displayName, "pIKachu")
        XCTAssertEqual(reopened.selected?.id, before.id)
        XCTAssertEqual(reopened.selected?.displayTitle, before.displayTitle)
        let restored = await reopened.setProjectDisplayName("  ", for: id)
        XCTAssertTrue(restored)
        XCTAssertEqual(reopened.state.projects[0].displayName, "After")
    }


    func testDeleteProjectRejectsStaleConfirmationAndPreservesStateOnFailedWrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(root)
        let id = try XCTUnwrap(added)
        let session = try XCTUnwrap(workspace.selected?.id)
        let otherProject = await workspace.addProject(other)
        let otherSession = try XCTUnwrap(workspace.selected?.id)
        let stale = try XCTUnwrap(workspace.projectDeletionSummary(for: id))
        await workspace.select(session)
        workspace.viewed?.controller.draft = "preserved"
        let declined = await workspace.deleteProject(stale)
        XCTAssertEqual(declined?.warning, true)

        let began = expectation(description: "Deletion snapshot write started")
        await store.pauseNextDeletion(began: began)
        let current = try XCTUnwrap(workspace.projectDeletionSummary(for: id))
        let deletion = Task { await workspace.deleteProject(current) }
        await fulfillment(of: [began], timeout: 2)
        let created = await workspace.createSession(in: id)
        let connected = await workspace.activate(session)
        XCTAssertNil(created)
        XCTAssertFalse(connected)
        await workspace.select(otherSession)
        await store.setFailure(true)
        await store.releaseDeletion()
        let failed = await deletion.value
        XCTAssertEqual(failed?.warning, true)
        XCTAssertEqual(workspace.state.projects.count, 2)
        XCTAssertEqual(workspace.presentations[session]?.controller.draft, "preserved")
        XCTAssertEqual(workspace.selected?.id, otherSession)
        await store.setFailure(false)
        let recovered = await workspace.flush()
        XCTAssertTrue(recovered)
        let retried = await workspace.deleteProject(current)
        XCTAssertNil(retried)
        XCTAssertEqual(workspace.state.projects.map(\.id), [try XCTUnwrap(otherProject)])
        XCTAssertEqual(workspace.selected?.id, otherSession)
    }

    func testLiveTurnHookReceivesEachRecordedTurnOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, _ in runtime }
        var received: [TurnRecord] = []
        var notificationSessions: [UUID] = []
        workspace.onLiveTurnFinished = { id, turn in
            notificationSessions.append(id)
            received.append(turn)
        }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let projectID = await workspace.addProject(root)
        XCTAssertTrue(received.isEmpty)

        let session = try XCTUnwrap(workspace.state.selectedSessionID)
        let activated = await workspace.activate(session)
        XCTAssertTrue(activated)
        let controller = try XCTUnwrap(workspace.execution(for: session))
        let project = try XCTUnwrap(projectID)
        let other = await workspace.createSession(in: project)
        XCTAssertEqual(workspace.state.selectedSessionID, other)
        for aborted in [false, true] {
            controller.receive(.init(instanceID: runtime.instanceID, event: .phase(.running)))
            let finished = RuntimeEnvelope(instanceID: runtime.instanceID, event: .settled(aborted: aborted))
            controller.receive(finished)
            controller.receive(finished)
        }
        XCTAssertEqual(notificationSessions, [session, session])
        XCTAssertEqual(received.map(\.status), [.completed, .stopped])
        XCTAssertEqual(Set(received.map(\.id)).count, 2)
        XCTAssertTrue(received.allSatisfy { $0.endedAt != nil })
        XCTAssertEqual(workspace.state.sessions.first?.recordedTurns?.map(\.id), received.map(\.id))
        _ = await workspace.disconnectAll()
    }

    func testMenuBarCountsTrackApprovalCompletionAndReview() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(id)
        XCTAssertTrue(activated)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        XCTAssertTrue(TaskStatusSnapshot(workspace: workspace).running.isEmpty, "Idle allocations are not running tasks")

        controller.receive(.init(instanceID: runtime.instanceID, event: .phase(.running)))
        XCTAssertEqual(TaskStatusSnapshot(workspace: workspace).running.map(\.id), [id])
        let tool = RuntimeToolApproval(workingDirectory: root.path, operation: .command(text: "printf test", timeoutSeconds: 10))
        let requests = ["first", "second"].map {
            RuntimeInteraction(instanceID: runtime.instanceID, requestID: $0, kind: .confirm,
                               title: "Run command?", toolApproval: tool)
        }
        for request in requests {
            controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
        }
        let pending = TaskStatusSnapshot(workspace: workspace)
        XCTAssertTrue(pending.running.isEmpty)
        XCTAssertEqual(pending.awaitingApproval.map(\.id), [id], "Count sessions, not individual approval prompts")
        for request in requests {
            controller.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(request.id, .answered)))
        }
        XCTAssertTrue(TaskStatusSnapshot(workspace: workspace).awaitingApproval.isEmpty)
        XCTAssertEqual(TaskStatusSnapshot(workspace: workspace).running.map(\.id), [id])

        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        XCTAssertTrue(TaskStatusSnapshot(workspace: workspace).running.isEmpty)
        XCTAssertEqual(TaskStatusSnapshot(workspace: workspace).unreadCompletions.map(\.id), [id])
        await workspace.select(id)
        XCTAssertEqual(TaskStatusSnapshot(workspace: workspace).unreadCompletions.map(\.id), [id])
        await workspace.openSessionForReview(id)
        XCTAssertTrue(TaskStatusSnapshot(workspace: workspace).unreadCompletions.isEmpty)
        _ = await workspace.disconnectAll()
    }

    func testSidebarCompletionStaysUnreadUntilCardOpens() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let projectID = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(id)
        XCTAssertTrue(activated)
        let controller = try XCTUnwrap(workspace.execution(for: id))

        func finish(aborted: Bool) {
            controller.receive(.init(instanceID: runtime.instanceID, event: .phase(.running)))
            controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: aborted)))
        }

        finish(aborted: true)
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, false)
        finish(aborted: false)
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)
        let firstCompletion = try XCTUnwrap(workspace.selected?.recordedTurns?.last?.id)
        await workspace.openSessionForReview(id) // Clicking an already selected card also acknowledges it.
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, false)

        let group = try XCTUnwrap(projectID)
        let other = await workspace.createSession(in: group)
        XCTAssertNotEqual(workspace.state.selectedSessionID, id)
        finish(aborted: false)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.hasUnreadCompletion, true)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == other })?.hasUnreadCompletion, false)
        await workspace.select(id) // Restoring a selection is not an explicit card open.
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)
        await workspace.openSessionForReview(id, acknowledging: firstCompletion)
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true, "An old notification must not clear a newer completion")
        await workspace.openSessionForReview(id, acknowledging: nil)
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true, "An approval must not clear a completion")
        _ = await workspace.disconnectAll()
        let saved = await workspace.flush()
        XCTAssertTrue(saved)

        let reopened = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.hasUnreadCompletion, true)
        await reopened.openSessionForReview(id)
        XCTAssertEqual(reopened.selected?.hasUnreadCompletion, false)
        let acknowledged = await reopened.flush()
        XCTAssertTrue(acknowledged)
        let persisted = await store.load()
        XCTAssertEqual(persisted.sessions.first(where: { $0.id == id })?.hasUnreadCompletion, false)
    }


    func testSidebarSnoozeFollowsDeadlineAndSettledStateSurvivesSaveRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let activity = workspace.selected?.activity
        let deadline = Date.now.addingTimeInterval(120)
        await workspace.setSessionReminder(id, until: deadline)
        XCTAssertEqual(workspace.selected?.reminderState(at: deadline.addingTimeInterval(-1)), .snoozed(until: deadline))
        XCTAssertEqual(workspace.selected?.reminderState(at: deadline), .due)
        await store.setFailure(true)
        await workspace.markSessionSettled(id)
        let beforeRetry = await store.load()
        XCTAssertEqual(beforeRetry.sessions.first?.sidebarStatus, .open)
        XCTAssertEqual(beforeRetry.sessions.first?.reminderState(at: deadline), .due)
        XCTAssertNotNil(workspace.storageError)
        await store.setFailure(false)
        let retry = await workspace.flush()
        XCTAssertTrue(retry)

        let reopened = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.sidebarStatus, .settled)
        XCTAssertEqual(reopened.selected?.reminderState(at: deadline), SessionReminderState.none)
        XCTAssertEqual(reopened.selected?.id, id)
        XCTAssertEqual(reopened.selected?.activity, activity)
        reopened.viewed?.controller.draftFiles = [root.appendingPathComponent("draft")]
        XCTAssertEqual(reopened.selected?.sidebarStatus, .open)
        if let session = reopened.selected { XCTAssertNotNil(reopened.settleBlockReason(for: session)) }
        await reopened.markSessionSettled(id)
        XCTAssertEqual(reopened.selected?.sidebarStatus, .open)
        _ = await reopened.flush()
    }

    func testSidebarSeparatesSelectionRunningAndWaitingFromProcessingStatus() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let project = await workspace.addProject(root)
        let projectID = try XCTUnwrap(project)
        let id = try XCTUnwrap(workspace.selected?.id)
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.selected?.sidebarStatus, .settled)
        await workspace.send(id, submitted: .init(text: "继续处理"))
        XCTAssertEqual(workspace.selected?.sidebarStatus, .open)
        XCTAssertEqual(workspace.execution(for: id)?.phase, .running)
        let other = await workspace.createSession(in: projectID)
        XCTAssertEqual(workspace.state.selectedSessionID, other)
        XCTAssertEqual(workspace.executionIDs, [id])
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)

        let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "review", kind: .confirm, title: "确认操作")
        workspace.execution(for: id)?.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
        workspace.execution(for: id)?.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)
        workspace.execution(for: id)?.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(request.id, .answered)))
        XCTAssertEqual(workspace.execution(for: id)?.phase, .idle)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .settled)
        XCTAssertEqual(workspace.state.selectedSessionID, other)
        _ = await workspace.disconnectAll()
    }



    func testCatalogDoesNotStartAnExecutionAndFailedSelectionKeepsAttachmentDraft() async throws {
        let root = try directory()
        let store = MemoryWorkspaceStore()
        var starts: [String] = []
        var catalogRequests = 0
        let host = WorkspaceController(store: store, inspectModels: { model in
            catalogRequests += 1
            return FakeRuntime.options(for: model)
        }) { _, reference in
            starts.append(reference.runtimeID)
            return FakeRuntime()
        }
        await host.start(); host.setACPAgents([.antigravityPreset()])
        let project = await host.addProject(root)
        let session = try XCTUnwrap(host.selected?.id)
        let model = FakeRuntime.models[1]
        let catalogue = try await host.modelCatalogue(for: session)
        let levels = try await host.thinkingLevels(for: session, model: model)
        XCTAssertEqual(catalogue, FakeRuntime.models)
        XCTAssertTrue(levels.contains("high"))
        XCTAssertTrue(starts.isEmpty)

        let file = root.appendingPathComponent("draft reference.txt")
        host.viewed?.controller.draft = "Keep this draft"
        host.viewed?.controller.draftFiles = [file]
        let selection = RuntimeSelection(provider: model.provider, modelID: model.modelID, thinking: "invalid")
        let saved = await host.saveSelection(selection, name: model.name, for: session)
        XCTAssertTrue(saved)
        await host.send(session)
        XCTAssertEqual(starts, [RuntimeAgentProfile.antigravityRuntimeID])
        XCTAssertEqual(host.selected?.pendingSelection, selection)
        XCTAssertEqual(host.viewed?.controller.draft, "Keep this draft")
        XCTAssertEqual(host.viewed?.controller.draftFiles, [file])
        XCTAssertTrue(host.viewed?.controller.transcript.isEmpty == true)
        XCTAssertEqual(catalogRequests, 2)

        let valid = await host.saveSelection(.init(provider: model.provider, modelID: model.modelID, thinking: "high"), for: session)
        XCTAssertTrue(valid)
        XCTAssertNil(host.selected?.pendingSelection)
        XCTAssertEqual(host.execution(for: session)?.session?.thinking, "high")
        await host.send(session)
        XCTAssertTrue(host.execution(for: session)?.transcript.first?.text.contains(file.path) == true)
        XCTAssertTrue(host.execution(for: session)?.draftFiles.isEmpty == true)

        await host.createSession(in: try XCTUnwrap(project))
        let other = try XCTUnwrap(host.selected?.id)
        _ = try await host.modelCatalogue(for: other)
        XCTAssertEqual(host.executionIDs, [session])
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(catalogRequests, 3)
        _ = await host.disconnectAll()
    }




    func testFileReferencesAndACPModeSurviveRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let attachment = root.appendingPathComponent("notes.txt")
        workspace.viewed?.controller.draftFiles = [attachment]
        let changed = await workspace.setACPMode("plan", for: id)
        XCTAssertTrue(changed)
        let reopened = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.runtimeModeID, "plan")
        XCTAssertEqual(reopened.viewed?.controller.draftFiles, [attachment])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-WorkspaceTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testSwiftDataReopenRestoresIDsDraftsAndRejectsStaleSave() async throws {
        let root = try directory(), url = root.appendingPathComponent("workspace.store")
        var snapshot = WorkspaceSnapshot(); let project = ProjectRecord(path: root.path)
        var session = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID); session.draft = "未发送"; session.recovered = [.init(text: "清出的内容", mode: .followUp)]
        snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id; snapshot.revision = 5
        let first = try SwiftDataWorkspaceStore(url: url); try await first.save(snapshot)
        var stale = snapshot; stale.revision = 4; stale.sessions[0].draft = "stale"; try await first.save(stale)
        let second = try SwiftDataWorkspaceStore(url: url), restored = try await second.load()
        XCTAssertEqual(restored.sessions[0], session); XCTAssertEqual(restored.selectedSessionID, session.id)
        XCTAssertEqual(restored.projects[0].id, project.id)
    }
    func testTypingAndSecondActivationWhileACPConnectsKeepTheSubmissionAndOriginalRuntime() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connecting = expectation(description: "Agent is opening the session")
        let gate = AsyncStream<Void>.makeStream()
        let runtime = WorkspaceTestRuntime {
            connecting.fulfill()
            for await _ in gate.stream {}
        }
        var starts = 0
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, _ in
            starts += 1
            return runtime
        }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let session = try XCTUnwrap(workspace.selected)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.draft = "clicked send"
        let sending = Task { await workspace.send(session.id) }
        await fulfillment(of: [connecting], timeout: 3)
        controller.draft = "new typing"
        let second = await workspace.activate(session.id)
        gate.continuation.finish()
        await sending.value
        XCTAssertFalse(second)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(runtime.submittedTexts, ["clicked send"])
        XCTAssertEqual(controller.draft, "new typing")
        _ = await workspace.disconnectAll()
    }

    func testBrowseAndDraftsDoNotCreateRuntimeOrStopCurrentTask() async throws {
        let root = try directory(), store = MemoryWorkspaceStore()
        var runtimes: [WorkspaceTestRuntime] = []
        let workspace = WorkspaceController(store: store) { _,_ in let value = WorkspaceTestRuntime(); runtimes.append(value); return value }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()]); let project = await workspace.addProject(root)!
        let first = workspace.selected!.id
        workspace.viewed!.controller.draft = "run"; await workspace.send(first)
        await workspace.createSession(in: project); let second = workspace.selected!.id
        workspace.viewed!.controller.draft = "second draft"
        XCTAssertEqual(runtimes.count, 1); XCTAssertEqual(runtimes[0].stopCount, 0); XCTAssertEqual(workspace.executionIDs, [first])
        await workspace.select(first); XCTAssertTrue(workspace.viewed!.controller.draft.isEmpty)
        await workspace.select(second); XCTAssertEqual(workspace.viewed!.controller.draft, "second draft")
        _ = await workspace.disconnectAll()
    }
    func testRenamePersistsForTargetSessionAndTakesPriorityOverAutomaticTitle() async throws {
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(try directory())
        let project = try XCTUnwrap(added)
        let first = try XCTUnwrap(workspace.selected)
        let created = await workspace.createSession(in: project)
        let second = try XCTUnwrap(created)
        let secondTitle = try XCTUnwrap(workspace.selected?.displayTitle)

        let renamed = await workspace.renameSession(first.id, to: "  Release notes \n")
        XCTAssertTrue(renamed)
        XCTAssertEqual(workspace.state.sessions.first { $0.id == first.id }?.displayTitle, "Release notes")
        XCTAssertEqual(workspace.selected?.id, second)
        XCTAssertEqual(workspace.selected?.displayTitle, secondTitle)
        XCTAssertTrue(workspace.executionIDs.isEmpty)

        let snapshot = await store.load()
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let reopened = WorkspaceController(store: MemoryWorkspaceStore(decoded)) { _, _ in FakeRuntime() }
        await reopened.start()
        await reopened.select(first.id)
        XCTAssertEqual(reopened.selected?.displayTitle, "Release notes")
        await reopened.send(first.id, submitted: UserPrompt(text: "/handled"))
        XCTAssertEqual(reopened.selected?.title, "/handled")
        XCTAssertEqual(reopened.selected?.displayTitle, "Release notes")
        _ = await reopened.disconnectAll()
    }




    func testRenameRejectsBlankTitleAndDoesNotPublishOnSaveFailure() async throws {
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(try directory())
        let original = try XCTUnwrap(workspace.selected)

        let blank = await workspace.renameSession(original.id, to: " \t\n")
        XCTAssertFalse(blank)
        XCTAssertEqual(workspace.selected?.displayTitle, original.displayTitle)
        XCTAssertNil(workspace.storageError)

        await store.setFailure(true)
        let failed = await workspace.renameSession(original.id, to: "Renamed")
        XCTAssertFalse(failed)
        XCTAssertEqual(workspace.selected?.displayTitle, original.displayTitle)
        XCTAssertNotNil(workspace.storageError)

        await store.setFailure(false)
        let retried = await workspace.renameSession(original.id, to: "Renamed")
        XCTAssertTrue(retried)
        XCTAssertEqual(workspace.selected?.displayTitle, "Renamed")
        XCTAssertNil(workspace.storageError)
    }

    func testFlushPersistsDraftEditedBeforeChangingSelection() async throws {
        let store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _, _ in WorkspaceTestRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let project = await workspace.addProject(try directory())!
        let first = workspace.selected!
        await workspace.createSession(in: project)
        let second = workspace.selected!.id
        await workspace.select(first.id)
        workspace.viewed!.controller.draft = "a"
        workspace.viewed!.controller.draft = "a revised draft"
        XCTAssertTrue(workspace.hasDraft(first))
        await workspace.select(second)
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        let snapshot = await store.load()
        XCTAssertEqual(snapshot.sessions.first { $0.id == first.id }?.draft, "a revised draft")
        XCTAssertEqual(snapshot.selectedSessionID, second)
    }
    func testSameDirectorySessionsKeepPendingRequestsAndStopsIndependent() async throws {
        let root = try directory()
        var runtimes: [WorkspaceTestRuntime] = []
        var directories: [String] = []
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { project, reference in
            let runtime = WorkspaceTestRuntime()
            directories.append(reference.workingDirectory(in: project))
            runtimes.append(runtime)
            return runtime
        }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let project = await workspace.addProject(root)!
        let first = workspace.selected!.id
        await workspace.send(first, submitted: .init(text: "A"))
        let a = try XCTUnwrap(workspace.execution(for: first))
        let request = RuntimeInteraction(instanceID: runtimes[0].instanceID, requestID: "shared-request-id", kind: .confirm, title: "A")
        a.receive(.init(instanceID: runtimes[0].instanceID, event: .interaction(request)))
        XCTAssertEqual(a.phase, .waitingInput)

        let second = await workspace.createSession(in: project)!
        await workspace.send(second, submitted: .init(text: "B"))
        XCTAssertEqual(directories, [root.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path])
        let b = try XCTUnwrap(workspace.execution(for: second))
        XCTAssertNotEqual(runtimes[0].instanceID, runtimes[1].instanceID)
        b.receive(.init(instanceID: runtimes[1].instanceID, event: .settled(aborted: false)))
        XCTAssertEqual(b.phase, .idle)
        XCTAssertEqual(a.interactions.map(\.id), [request.id])

        await workspace.send(second, submitted: .init(text: "B again"))
        await workspace.stopViewedSession()
        XCTAssertEqual(runtimes[0].stopCount, 0)
        XCTAssertEqual(runtimes[1].stopCount, 1)
        XCTAssertEqual(a.phase, .waitingInput)
        let mismatchedReply = await b.reply(request, .confirmed(true))
        XCTAssertFalse(mismatchedReply)
        XCTAssertEqual(a.interactions.map(\.id), [request.id])
        XCTAssertTrue(b.interactions.isEmpty)

        let interactionEnded = expectation(description: "First session consumes its interaction-ended event")
        withObservationTracking {
            _ = a.interactions
        } onChange: {
            interactionEnded.fulfill()
        }
        let answered = await a.reply(request, .confirmed(true))
        XCTAssertTrue(answered)
        await fulfillment(of: [interactionEnded], timeout: 1)
        XCTAssertEqual(a.interactions.count, 0)
        XCTAssertEqual(a.phase, .running)
        await a.stop()
        XCTAssertEqual(runtimes[0].stopCount, 1)
        XCTAssertEqual(runtimes[1].stopCount, 1)
        let clean = await workspace.disconnectAll()
        XCTAssertTrue(clean)
        XCTAssertTrue(workspace.executionIDs.isEmpty)
    }

    private func waitForIdleReclaim(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Timed out waiting for idle reclaim")
    }


    func testIdleRuntimeReclaimWaitsForWorkQueueAndInteraction() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime(resumable: true)
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), idleRuntimeTimeout: .milliseconds(80)) { _, _ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(id)
        XCTAssertTrue(activated)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        func emit(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        emit(.phase(.running))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.connection, .connected)
        emit(.queue(.init(followUp: ["pending"])))
        emit(.assistantCompleted(UUID(), "Completed turn"))
        emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.connection, .connected)
        let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "keep-alive", kind: .confirm, title: "Confirm")
        emit(.interaction(request))
        emit(.queue(.init()))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.connection, .connected)
        emit(.interactionEnded(request.id, .answered))
        try await waitForIdleReclaim { !workspace.isOperating(on: id) && workspace.execution(for: id) == nil }
    }

    func testIdleRuntimeReclaimKeepsUnconfirmedCleanupBlocked() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime(closeFails: true)
        var starts = 0
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), idleRuntimeTimeout: .milliseconds(80)) { _, _ in
            starts += 1
            return runtime
        }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        _ = await workspace.addProject(root)
        let id = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(id)
        XCTAssertTrue(activated)
        try await waitForIdleReclaim { !workspace.isOperating(on: id) && workspace.execution(for: id)?.connection == .blocked }
        await workspace.send(id, submitted: .init(text: "Must not send"))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(runtime.sendCount, 0)
        XCTAssertEqual(workspace.executionIDs, [id])
    }

    func testMoreThanTwoSessionsRunWithoutEvictionAndCleanupRemainsIsolated() async throws {
        var failedID: UUID?
        var runtimes: [UUID: WorkspaceTestRuntime] = [:]
        let workspace = WorkspaceController(store: MemoryWorkspaceStore()) { _, reference in
            let runtime = WorkspaceTestRuntime(closeFails: reference.id == failedID)
            runtimes[reference.id] = runtime
            return runtime
        }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let project = await workspace.addProject(try directory())!
        let first = try XCTUnwrap(workspace.selected?.id)
        failedID = first
        let second = await workspace.createSession(in: project)!
        let third = await workspace.createSession(in: project)!
        async let a: Void = workspace.send(first, submitted: .init(text: "A"))
        async let b: Void = workspace.send(second, submitted: .init(text: "B"))
        async let c: Void = workspace.send(third, submitted: .init(text: "C"))
        _ = await (a, b, c)

        XCTAssertEqual(Set(workspace.executionIDs), Set([first, second, third]))
        XCTAssertEqual(runtimes.count, 3)
        for id in [first, second, third] { XCTAssertEqual(workspace.execution(for: id)?.phase, .running) }
        XCTAssertEqual(runtimes[third]?.submittedTexts, ["C"])

        let failedClose = await workspace.disconnect(first, force: true)
        XCTAssertFalse(failedClose)
        XCTAssertEqual(workspace.execution(for: first)?.connection, .blocked)
        await workspace.stop(second)
        let fourth = await workspace.createSession(in: project)!
        await workspace.send(fourth, submitted: .init(text: "D"))
        XCTAssertEqual(Set(workspace.executionIDs), Set([first, second, third, fourth]))
        XCTAssertEqual(workspace.execution(for: second)?.connection, .connected)
        XCTAssertEqual(workspace.execution(for: third)?.phase, .running)
        XCTAssertEqual(runtimes[fourth]?.submittedTexts, ["D"])

        let fifth = await workspace.createSession(in: project)!
        workspace.beginShutdown()
        await workspace.send(fifth, submitted: .init(text: "No new starts during quit"))
        XCTAssertNil(runtimes[fifth])
        let allClean = await workspace.disconnectAll(force: true)
        XCTAssertFalse(allClean)
        XCTAssertEqual(workspace.executionIDs, [first])
        workspace.cancelShutdown()
    }

    func testFailedDirectoryChangeDoesNotLeakIntoConcurrentSubmission() async throws {
        try await checkFailedDirectoryChoice(sourceIsBound: false)
    }

    func testFailedDirectoryForkDoesNotLeaveASessionAfterConcurrentSubmission() async throws {
        try await checkFailedDirectoryChoice(sourceIsBound: true)
    }

    private func checkFailedDirectoryChoice(sourceIsBound: Bool) async throws {
        let root = try directory().resolvingSymlinksInPath()
        let worktree = try directory().resolvingSymlinksInPath()
        let store = DirectoryFailureStore()
        let workspace = WorkspaceController(store: store) { _, _ in WorkspaceTestRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        let projectID = await workspace.addProject(root)!
        let sourceID = workspace.selected!.id
        if sourceIsBound {
            await workspace.send(sourceID, submitted: .init(text: "bind A"))
            await workspace.stop(sourceID)
        }
        let source = try XCTUnwrap(workspace.viewed?.controller)
        source.draft = "keep A"
        source.draftFiles = [root.appendingPathComponent("notes.txt")]
        let otherID = await workspace.createSession(in: projectID)!
        // Activate B before pausing storage so sending goes through the normal journal write.
        let activated = await workspace.activate(otherID)
        XCTAssertTrue(activated)
        let other = try XCTUnwrap(workspace.execution(for: otherID))
        XCTAssertEqual(workspace.selected?.id, otherID)

        let began = expectation(description: "Directory snapshot reached the store")
        await store.pauseAndFailChoice(of: worktree.path, began: began)
        let choice = Task { await workspace.chooseWorkingDirectory(worktree: worktree.path, for: sourceID) }
        await fulfillment(of: [began], timeout: 2)

        let pending = expectation(description: "Other session started a submission")
        withObservationTracking {
            _ = other.commandPending
        } onChange: {
            pending.fulfill()
        }
        let send = Task { await workspace.send(otherID, submitted: .init(text: "save B")) }
        await fulfillment(of: [pending], timeout: 2)
        XCTAssertEqual(workspace.workingDirectory(for: sourceID), root.path)
        XCTAssertEqual(workspace.state.sessions.count, 2)
        XCTAssertFalse(other.transcript.contains { $0.text == "save B" && $0.delivery == .accepted })

        await store.finishFailedChoice()
        let chosen = await choice.value
        await send.value
        XCTAssertFalse(chosen)
        XCTAssertTrue(other.transcript.contains { $0.text == "save B" && $0.delivery == .accepted })
        XCTAssertNil(workspace.storageError)

        let snapshot = await store.load()
        XCTAssertEqual(Set(snapshot.sessions.map(\.id)), Set([sourceID, otherID]))
        let original = try XCTUnwrap(snapshot.sessions.first { $0.id == sourceID })
        XCTAssertNil(original.worktreePath)
        XCTAssertEqual(original.draft, "keep A")
        XCTAssertEqual(original.draftFiles, [root.appendingPathComponent("notes.txt")])
        XCTAssertTrue(snapshot.sessions.first { $0.id == otherID }?.recordedMessages?.contains { $0.text == "save B" } == true)
        await workspace.stop(otherID)
        let clean = await workspace.disconnectAll()
        XCTAssertTrue(clean)

        let reopened = WorkspaceController(store: store) { _, _ in WorkspaceTestRuntime() }
        await reopened.start()
        XCTAssertEqual(Set(reopened.state.sessions.map(\.id)), Set([sourceID, otherID]))
        XCTAssertEqual(reopened.workingDirectory(for: sourceID), root.path)
        await reopened.select(sourceID)
        XCTAssertEqual(reopened.viewed?.controller.draft, "keep A")
    }


    func testStorageFailurePreventsPromptAndPreservesEditor() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(), runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: store) { _,_ in runtime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()]); _ = await workspace.addProject(root)
        let id = workspace.selected!.id; _ = await workspace.activate(id)
        workspace.viewed!.controller.draft = "must stay"
        await store.setFailure(true); await workspace.send(id)
        XCTAssertEqual(runtime.sendCount, 0); XCTAssertEqual(workspace.viewed!.controller.draft, "must stay")
        await store.setFailure(false); _ = await workspace.disconnectAll()
    }
    func testRestartMarksPendingUnknownWithoutStartingRuntime() async throws {
        let root = try directory(), store = MemoryWorkspaceStore()
        var state = WorkspaceSnapshot(); let project = ProjectRecord(path: root.path); var session = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        session.draft = "editor"; session.submissions = [.init(.init(text: "may have executed"))]; session.wasExecuting = true
        state.projects = [project]; state.sessions = [session]; state.selectedSessionID = session.id
        try await store.save({ var value = state; value.revision = 1; return value }())
        var creations = 0
        let workspace = WorkspaceController(store: store) { _,_ in creations += 1; return WorkspaceTestRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        XCTAssertEqual(creations, 0); XCTAssertEqual(workspace.selected?.submissions.first?.delivery, .unknown)
        XCTAssertTrue(workspace.selected?.submissions.first?.needsReview == true)
        XCTAssertEqual(workspace.viewed?.controller.draft, "editor")
        await workspace.send(session.id); XCTAssertEqual(creations, 0)
    }
    func testRelocationKeepsProjectAndSessionIdentity() async throws {
        let root = try directory(), relocated = try directory(), store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store) { _,_ in WorkspaceTestRuntime() }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()]); let project = await workspace.addProject(root)!, session = workspace.selected!.id
        await workspace.relocateProject(project, to: relocated)
        XCTAssertEqual(workspace.selected?.id, session); XCTAssertEqual(workspace.selectedProject?.id, project)
        XCTAssertEqual(workspace.selectedProject?.path, relocated.resolvingSymlinksInPath().path)
        XCTAssertTrue(workspace.selectedProject!.previousPaths.contains(root.resolvingSymlinksInPath().path))
    }
    func testLateOldRuntimeEventCannotPolluteNewTarget() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(); var runtimes: [WorkspaceTestRuntime] = []
        let workspace = WorkspaceController(store: store) { _,_ in let value = WorkspaceTestRuntime(); runtimes.append(value); return value }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()]); let project = await workspace.addProject(root)!
        let first = workspace.selected!.id; workspace.viewed!.controller.draft = "first"; await workspace.send(first)
        await workspace.createSession(in: project); let second = workspace.selected!.id
        workspace.viewed!.controller.draft = "second"; await workspace.send(second)
        workspace.viewed!.controller.receive(.init(instanceID: runtimes[0].instanceID, event: .assistantCompleted(UUID(), "STALE")))
        XCTAssertEqual(runtimes.count, 2); XCTAssertFalse(workspace.viewed!.controller.transcript.contains { $0.text == "STALE" })
        XCTAssertEqual(Set(workspace.executionIDs), Set([first, second])); _ = await workspace.disconnectAll()
    }



    private func isGitWorktree(_ worktreePath: String, of projectPath: String) -> Bool {
        guard let output = try? runGit(["worktree", "list", "--porcelain"], cwd: URL(fileURLWithPath: projectPath)) else {
            return false
        }
        let target = WorkspaceController.canonicalPath(worktreePath)
        let topLevel = try? runGit(["rev-parse", "--show-toplevel"], cwd: URL(fileURLWithPath: target))
        let resolvedTopLevel = topLevel.map { WorkspaceController.canonicalPath($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let listed = output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("worktree ") else { return nil }
            return WorkspaceController.canonicalPath(String(line.dropFirst("worktree ".count)))
        }
        return resolvedTopLevel == target && listed.contains(target)
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "WorkspaceGitTest", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
