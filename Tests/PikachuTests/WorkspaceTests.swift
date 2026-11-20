import XCTest
import Foundation
import Observation
import AgentRuntimeCore
import OrchestrationCore
import PiRuntimeAdapter
import WorkspacePersistence

private actor MemoryWorkspaceStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    var fail = false
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func setFailure(_ value: Bool) { fail = value }
    func save(_ value: WorkspaceSnapshot) throws {
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
    let identity: String
    let file: URL?
    init(closeFails: Bool = false, identity: String = UUID().uuidString, file: URL? = nil) {
        self.closeFails = closeFails
        self.identity = identity; self.file = file
        let pair = AsyncStream<RuntimeEnvelope>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func connect() async throws -> RuntimeSession { .init(id: identity, model: "test", thinking: "low", capabilities: [.streaming, .interruption], file: file) }
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
private actor SlowHistoryReader: RuntimeHistoryReader {
    let reader = PiHistoryReader(roots: [])
    func read(_ file: URL) async throws -> RuntimeHistory {
        try await Task.sleep(for: .milliseconds(80)); return try await reader.read(file)
    }
    func discover(locations: [String]) async throws -> HistoryDiscovery { .init(sessions: [], issues: []) }
}

private actor SidebarHistoryReader: RuntimeHistoryReader {
    private var requests: [[String]] = []
    private var histories: [RuntimeHistory] = []
    private var issues: [String] = []
    private var interrupted = false
    private var pause: CheckedContinuation<Void, Never>?

    func set(_ histories: [RuntimeHistory], issues: [String] = [], interrupted: Bool = false) {
        self.histories = histories
        self.issues = issues
        self.interrupted = interrupted
    }
    func read(_ file: URL) throws -> RuntimeHistory {
        guard let history = histories.first(where: { $0.file == file }) else { throw RuntimeFailure(.protocolError, "missing") }
        return history
    }
    func discover(locations: [String]) async throws -> HistoryDiscovery {
        requests.append(locations)
        if interrupted { throw RuntimeFailure(.connection, "interrupted") }
        if requests.count == 1 { await withCheckedContinuation { pause = $0 } }
        return .init(sessions: histories, issues: issues)
    }
    func pausedRequests() -> [[String]]? { pause == nil ? nil : requests }
    func requestCount() -> Int { requests.count }
    func resume() {
        pause?.resume()
        pause = nil
    }
}

private actor DelayedProjectConfigStore: WorkspaceStore {
    private var snapshot = WorkspaceSnapshot()
    private var pauseBegan: XCTestExpectation?
    private var resumeWrite: CheckedContinuation<Void, Never>?
    private var shouldFailPausedWrite = false

    func load() -> WorkspaceSnapshot { snapshot }

    func pauseNextConfigWrite(began: XCTestExpectation, shouldFail: Bool) {
        pauseBegan = began
        shouldFailPausedWrite = shouldFail
    }

    func finishPausedConfigWrite() {
        resumeWrite?.resume()
        resumeWrite = nil
    }

    func save(_ value: WorkspaceSnapshot) async throws {
        if let began = pauseBegan, value.trustedPiConfigDirectories != snapshot.trustedPiConfigDirectories {
            pauseBegan = nil
            await withCheckedContinuation { continuation in
                resumeWrite = continuation
                began.fulfill()
            }
            if shouldFailPausedWrite {
                shouldFailPausedWrite = false
                throw RuntimeFailure(.setup, "injected config save failure")
            }
        }
        if value.revision > snapshot.revision { snapshot = value }
    }
}

@MainActor final class WorkspaceTests: XCTestCase {
    func testModelPreferencesPersistAndDefaultAppliesOnlyToNewSessions() async throws {
        let store = MemoryWorkspaceStore()
        let reader = PiHistoryReader(roots: [])
        let workspace = WorkspaceController(store: store, reader: reader,
                                            inspectModels: { FakeRuntime.options(for: $0) }) { _, _ in FakeRuntime() }
        await workspace.start()
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let added = await workspace.addProject(directory, createInitialSession: true)
        let project = try XCTUnwrap(added)
        let existing = try XCTUnwrap(workspace.selected?.id)
        let catalogue = try await workspace.modelCatalogue()
        let defaultModel = try XCTUnwrap(catalogue.first { $0.modelID == "demo-reasoning" })
        let otherModel = try XCTUnwrap(catalogue.first { $0.id != defaultModel.id })

        let defaultSaved = await workspace.setDefaultModel(defaultModel)
        let favoriteSaved = await workspace.setFavoriteModel(defaultModel, isFavorite: true)
        let visibilitySaved = await workspace.setModelVisible(otherModel, isVisible: false)
        XCTAssertTrue(defaultSaved && favoriteSaved && visibilitySaved)
        XCTAssertNil(workspace.state.sessions.first { $0.id == existing }?.pendingSelection)

        let snapshot = await store.load()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        let reopened = WorkspaceController(store: MemoryWorkspaceStore(decoded), reader: reader) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.state.modelPreferences?.defaultModel, defaultModel)
        XCTAssertEqual(reopened.state.modelPreferences?.favorites, [defaultModel])
        XCTAssertEqual(reopened.state.modelPreferences?.hiddenModelIDs, [otherModel.id])
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

        let cleared = await reopened.setDefaultModel(nil)
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
        XCTAssertNil(snapshot.modelPreferences)
        let store = MemoryWorkspaceStore(snapshot)
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await workspace.start()
        await store.setFailure(true)
        let saved = await workspace.setDefaultModel(FakeRuntime.models[0])
        XCTAssertFalse(saved)
        XCTAssertNil(workspace.state.modelPreferences)
        XCTAssertNotNil(workspace.storageError)
    }

    func testToolSearchPathsRoundTripAndOlderPreferencesRemainReadable() throws {
        let legacy = Data(#"{"piPath":"/pi","nodeDirectory":"/node","proxy":""}"#.utf8)
        var preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: legacy)
        XCTAssertNil(preferences.toolSearchPaths)
        preferences.toolSearchPaths = ["/opt/homebrew/bin", "/My Tools/bin"]
        let encoded = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: encoded), preferences)
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
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await workspace.start()
        _ = await workspace.addProject(first)
        let selected = try XCTUnwrap(workspace.state.selectedSessionID)
        let opened = await workspace.addProject(added, createInitialSession: false)
        let projectID = try XCTUnwrap(opened)
        XCTAssertFalse(workspace.state.sessions.contains { $0.projectID == projectID })

        let refreshed = await workspace.discover(projectID)
        XCTAssertEqual(refreshed?.warning, false)
        let conflict = await workspace.relocateProject(projectID, to: first)
        XCTAssertEqual(conflict?.warning, true)
        let relocated = await workspace.relocateProject(projectID, to: moved)
        XCTAssertEqual(relocated?.warning, false)
        XCTAssertEqual(workspace.state.selectedSessionID, selected)
        let project = try XCTUnwrap(workspace.state.projects.first { $0.id == projectID })
        XCTAssertEqual(project.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(project.previousPaths, [added.resolvingSymlinksInPath().path])
    }

    func testLiveTurnHookReceivesEachRecordedTurnOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: PiHistoryReader(roots: [])) { _, _ in runtime }
        var received: [TurnRecord] = []
        var notificationSessions: [UUID] = []
        workspace.onLiveTurnFinished = { id, turn in
            notificationSessions.append(id)
            received.append(turn)
        }
        await workspace.start()
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

    func testSidebarCompletionStaysUnreadUntilCardOpens() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WorkspaceTestRuntime()
        let store = MemoryWorkspaceStore()
        let reader = PiHistoryReader(roots: [])
        let workspace = WorkspaceController(store: store, reader: reader) { _, _ in runtime }
        await workspace.start()
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

        let reopened = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.hasUnreadCompletion, true)
        await reopened.openSessionForReview(id)
        XCTAssertEqual(reopened.selected?.hasUnreadCompletion, false)
        let acknowledged = await reopened.flush()
        XCTAssertTrue(acknowledged)
        let persisted = await store.load()
        XCTAssertEqual(persisted.sessions.first(where: { $0.id == id })?.hasUnreadCompletion, false)
    }

    func testLegacySidebarFieldsDecodeAndMigrationPreservesInterruptedWork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        let history = try historyFile(root)
        let legacyTime = Date(timeIntervalSince1970: 1_000)
        var pure = SessionReference(projectID: project.id, title: "历史")
        pure.historyConfirmed = true
        pure.file = history
        pure.lastViewed = legacyTime
        var interrupted = pure
        interrupted.id = UUID()
        interrupted.wasExecuting = true
        var draft = pure
        draft.id = UUID()
        draft.draftFiles = [root.appendingPathComponent("attachment")]
        var unresolved = pure
        unresolved.id = UUID()
        unresolved.submissions = [.init(.init(text: "等待确认"))]
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [pure, interrupted, draft, unresolved]
        let legacy = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("processingStatus"))
        let store = MemoryWorkspaceStore(try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy))
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await workspace.start()
        XCTAssertEqual(workspace.state.sessions.map(\.sidebarStatus), [.settled, .open, .open, .open])
        XCTAssertFalse(workspace.state.sessions.contains(where: \.hasUnreadCompletion))
        XCTAssertEqual(workspace.state.sessions.first?.activity.date, legacyTime)
        XCTAssertEqual(workspace.state.sessions.first?.activity.isEstimate, true)
        XCTAssertEqual(workspace.state.sessions.last?.submissions.first?.needsReview, true)
        XCTAssertTrue(workspace.executionIDs.isEmpty)
        let reopened = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.state.sessions.map(\.sidebarStatus), [.settled, .open, .open, .open])
    }

    func testSidebarSnoozeFollowsDeadlineAndSettledStateSurvivesSaveRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryWorkspaceStore()
        let reader = PiHistoryReader(roots: [])
        let workspace = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await workspace.start()
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

        let reopened = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
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
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: PiHistoryReader(roots: [])) { _, _ in runtime }
        await workspace.start()
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

    func testWorkspaceRefreshMergesOneScanWithSelectionAndPreservesAmbiguousHistory() async throws {
        let firstRoot = try directory()
        let secondRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        var first = ProjectRecord(path: firstRoot.path)
        let second = ProjectRecord(path: secondRoot.path)
        first.previousPaths = [second.path]
        let initial = SessionReference(projectID: first.id, title: "当前")
        let other = SessionReference(projectID: second.id, title: "另一个")
        let storedFile = firstRoot.appendingPathComponent("bound.jsonl")
        var known = SessionReference(projectID: first.id, title: "已有历史")
        known.runtimeSessionID = "known"
        known.file = storedFile
        known.historyConfirmed = true
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [first, second]
        snapshot.sessions = [initial, other, known]
        snapshot.selectedSessionID = initial.id
        let reader = SidebarHistoryReader()
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(snapshot), reader: reader) { _, _ in FakeRuntime() }
        await workspace.start()
        await reader.set([
            .init(sessionID: "known", file: secondRoot.appendingPathComponent("other-binding.jsonl"), cwd: second.path,
                  title: "冲突", items: [], incompleteTail: false, warnings: [], selection: nil),
            .init(sessionID: "independent", file: firstRoot.appendingPathComponent("new.jsonl"), cwd: first.path,
                  title: "新发现的历史", items: [], incompleteTail: false, warnings: [], selection: nil),
        ], issues: ["部分历史不可读"])
        let refresh = Task { await workspace.refreshWorkspaceHistory() }
        var requests: [[String]]?
        for _ in 0..<100 {
            requests = await reader.pausedRequests()
            if requests != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(requests, [[first.path, second.path].sorted()])
        XCTAssertTrue(workspace.refreshingHistoryIndex)
        await workspace.refreshWorkspaceHistory()
        await workspace.select(other.id)
        await reader.resume()
        await refresh.value
        let requestCount = await reader.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(workspace.refreshingHistoryIndex)
        XCTAssertEqual(workspace.state.selectedSessionID, other.id)
        XCTAssertEqual(workspace.state.sessions.first { $0.id == known.id }?.file, storedFile)
        XCTAssertEqual(workspace.state.sessions.filter { $0.runtimeSessionID == "known" }.count, 1)
        XCTAssertEqual(workspace.state.sessions.first { $0.runtimeSessionID == "independent" }?.sidebarStatus, .settled)
        let ambiguity = String(localized: "部分会话的工作目录对应多个项目，已保留现有绑定。", bundle: Bundle(for: WorkspaceController.self))
        XCTAssertTrue(workspace.notice?.split(separator: "\n").contains(Substring(ambiguity)) == true)
        XCTAssertTrue(workspace.executionIDs.isEmpty)
        let previousIDs = workspace.state.sessions.map(\.id)
        await reader.set([], interrupted: true)
        await workspace.refreshWorkspaceHistory()
        XCTAssertNotNil(workspace.error)
        XCTAssertEqual(workspace.state.sessions.map(\.id), previousIDs)
        await reader.set([])
        await workspace.refreshWorkspaceHistory()
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.state.sessions.map(\.id), previousIDs)
        XCTAssertEqual(workspace.state.selectedSessionID, other.id)
    }

    func testSidebarImportsConfirmedModelAndLastActivityWithoutMarkingInterruptedHistorySettled() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = user("a", nil, "请求")
        let first: [String: Any] = ["type": "message", "id": "b", "parentId": "a",
                                    "message": ["role": "assistant", "content": "之前回复", "provider": "openai", "model": "previous"]]
        let last: [String: Any] = ["type": "message", "id": "c", "parentId": "b", "timestamp": "2026-11-18T00:00:12.500Z",
                                   "message": ["role": "assistant", "content": "部分回复", "provider": "anthropic", "model": "observed", "stopReason": "aborted"]]
        let file = try historyFile(root, records: [asked, first, last], id: "interrupted")
        let reader = PiHistoryReader(roots: [root])
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: reader) { _, _ in FakeRuntime() }
        await workspace.start()
        _ = await workspace.addProject(root)
        let imported = try XCTUnwrap(workspace.state.sessions.first { $0.runtimeSessionID == "interrupted" })
        XCTAssertEqual(imported.file?.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.file)), try Data(contentsOf: file))
        XCTAssertEqual(imported.sidebarStatus, .open)
        XCTAssertEqual(imported.historicalModel?.provider, "anthropic")
        XCTAssertEqual(imported.historicalModel?.modelID, "observed")
        XCTAssertEqual(imported.activity.date, try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-18T00:00:12.500Z"))
        XCTAssertFalse(imported.activity.isEstimate)
        await workspace.select(imported.id)
        XCTAssertEqual(workspace.selected?.activity, imported.activity)
        await workspace.markSessionSettled(imported.id)
        await workspace.refreshWorkspaceHistory()
        XCTAssertEqual(workspace.selected?.sidebarStatus, .settled)
    }

    func testCatalogDoesNotStartAnExecutionAndFailedSelectionKeepsAttachmentDraft() async throws {
        let root = try directory()
        let store = MemoryWorkspaceStore()
        var starts: [AgentMode] = []
        var catalogRequests = 0
        let host = WorkspaceController(store: store, reader: PiHistoryReader(roots: []), inspectModels: { model in
            catalogRequests += 1
            return FakeRuntime.options(for: model)
        }) { _, reference in
            starts.append(reference.executionMode)
            return FakeRuntime()
        }
        await host.start()
        let project = await host.addProject(root)
        let session = try XCTUnwrap(host.selected?.id)
        let model = FakeRuntime.models[1]
        let catalog = try await host.configurationOptions(for: session)
        let levels = try await host.configurationOptions(for: session, model: model)
        XCTAssertEqual(catalog.models, FakeRuntime.models)
        XCTAssertTrue(levels.thinkingLevels.contains("high"))
        XCTAssertTrue(starts.isEmpty)

        let file = root.appendingPathComponent("draft reference.txt")
        host.viewed?.controller.draft = "Keep this draft"
        host.viewed?.controller.draftFiles = [file]
        let selection = RuntimeSelection(provider: model.provider, modelID: model.modelID, thinking: "invalid")
        let saved = await host.saveSelection(selection, name: model.name, for: session)
        XCTAssertTrue(saved)
        await host.send(session)
        XCTAssertEqual(starts, [.interactive])
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
        _ = try await host.configurationOptions(for: other)
        XCTAssertEqual(host.executionIDs, [session])
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(catalogRequests, 3)
        _ = await host.disconnectAll()
    }

    func testFileReferencesAndModeSurviveRestartWithOldSessionDefaults() async throws {
        let root = try directory()
        let project = ProjectRecord(path: root.path)
        let oldSession = SessionReference(projectID: project.id)
        var initial = WorkspaceSnapshot()
        initial.projects = [project]
        initial.sessions = [oldSession]
        initial.selectedSessionID = oldSession.id
        let store = MemoryWorkspaceStore(initial)
        let reader = PiHistoryReader(roots: [])
        let host = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await host.start()
        XCTAssertEqual(host.selected?.executionMode, .automatic)
        XCTAssertEqual(host.selected?.executionPolicy.approval, .never)
        await host.createSession(in: project.id)
        let session = try XCTUnwrap(host.selected?.id)
        XCTAssertEqual(host.selected?.executionMode, .interactive)
        XCTAssertEqual(host.selected?.executionPolicy.approval, .mutations)
        await host.setToolApproval(.never, for: session)
        await host.setAgentMode(.plan, for: session)
        XCTAssertEqual(host.selected?.executionPolicy.approval, .never)
        await host.setToolApproval(.mutations, for: session)
        XCTAssertEqual(host.selected?.executionPolicy.approval, .never)
        await host.setToolApproval(.everyCall, for: session)
        let file = root.appendingPathComponent("引用文件.txt")
        host.viewed?.controller.draftFiles = [file]
        let flushed = await host.flush()
        XCTAssertTrue(flushed)

        let reopened = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.id, session)
        XCTAssertEqual(reopened.selected?.executionMode, .plan)
        XCTAssertEqual(reopened.selected?.executionPolicy.approval, .everyCall)
        XCTAssertEqual(reopened.viewed?.controller.draftFiles, [file])
        XCTAssertTrue(reopened.viewed?.controller.draftPrompt.hasContent == true)
        await reopened.setAgentMode(.automatic, for: session)
        await reopened.setToolApproval(.everyCall, for: session)
        XCTAssertEqual(reopened.selected?.executionPolicy.approval, .never)
        await reopened.setAgentMode(.interactive, for: session)
        XCTAssertEqual(reopened.selected?.executionPolicy.approval, .never)

        let connected = await reopened.activate(session)
        XCTAssertTrue(connected)
        let firstRuntimeSession = try XCTUnwrap(reopened.execution(for: session)?.session?.id)
        await reopened.setToolApproval(.everyCall, for: session)
        XCTAssertEqual(reopened.runningPolicy(for: session)?.approval, .never)
        await reopened.send(session, submitted: .init(text: "/handled", mode: .steer))
        XCTAssertEqual(reopened.runningPolicy(for: session)?.approval, .everyCall)
        XCTAssertNotEqual(reopened.execution(for: session)?.session?.id, firstRuntimeSession)
        _ = await reopened.disconnectAll()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-WorkspaceTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func historyFile(_ root: URL, records: [[String: Any]] = [], tail: String = "", version: Int = 3, id: String = "fixture") throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".jsonl")
        let header: [String: Any] = ["type":"session", "version":version, "id":id, "cwd":root.path, "timestamp":"2026-11-18T00:00:00Z"]
        let bytes = try ([header] + records).reduce(into: Data()) { value, record in value.append(try JSONSerialization.data(withJSONObject: record)); value.append(10) } + Data(tail.utf8)
        try bytes.write(to: file); return file
    }
    private func user(_ id: String, _ parent: String?, _ text: String) -> [String: Any] {
        ["type":"message", "id":id, "parentId":parent as Any? ?? NSNull(), "message":["role":"user", "content":text]]
    }
    func testHandledCommandWithoutMaterializedHistoryCanReconnectAfterRestart() async throws {
        let root = try directory(), project = ProjectRecord(path:try directory().path)
        var session = SessionReference(projectID:project.id)
        session.runtimeSessionID = "allocated-only"; session.file = root.appendingPathComponent("never-created.jsonl")
        var submission = SubmissionRecord(.init(text:"/extension-command")); submission.delivery = .handled; submission.acknowledged = true
        session.submissions = [submission]; session.draft = "Keep draft"
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id
        var starts = 0
        let host = WorkspaceController(store:MemoryWorkspaceStore(snapshot),reader:PiHistoryReader(roots:[])) { _,_ in starts += 1; return WorkspaceTestRuntime() }
        await host.start()
        XCTAssertEqual(starts,0); XCTAssertNil(host.selected?.file); XCTAssertNil(host.selected?.runtimeSessionID)
        XCTAssertEqual(host.selected?.submissions,[submission]); XCTAssertEqual(host.viewed?.controller.draft,"Keep draft")
        let activated = await host.activate(session.id)
        XCTAssertTrue(activated); XCTAssertEqual(starts,1)
        _ = await host.disconnectAll()
    }
    func testHistoryPreservesActiveBranchAndCompactionHistoryWithoutMutation() async throws {
        let root = try directory()
        let entries: [[String: Any]] = [user("a",nil,"ROOT"), user("b","a","ABANDONED"), user("c","a","KEPT"),
            ["type":"compaction","id":"d","parentId":"c","summary":"SUMMARY","firstKeptEntryId":"c"],
            ["type":"context_edit","id":"e","parentId":"d","targetId":"c","replacement":NSNull()]]
        let file = try historyFile(root, records: entries), before = try Data(contentsOf: file)
        let history = try await PiHistoryReader(roots: []).read(file)
        XCTAssertEqual(history.items.filter { $0.kind == .user }.map(\.text), ["ROOT","KEPT"])
        XCTAssertEqual(history.items.filter { $0.kind == .notice }.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testRepeatedHistoryReadDetectsSameSizeRewriteAndPartialTail() async throws {
        let root = try directory(), reader = PiHistoryReader(roots: [])
        let file = try historyFile(root, records: [user("a", nil, "first")])
        let first = try await reader.read(file)
        let repeated = try await reader.read(file)
        XCTAssertEqual(first.items.first?.text, "first")
        XCTAssertEqual(repeated.items.first?.text, "first")

        let original = try String(contentsOf: file, encoding: .utf8)
        let replacement = original.replacingOccurrences(of: "first", with: "later")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate])
        XCTAssertEqual(original.utf8.count, replacement.utf8.count)
        try replacement.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)
        let rewritten = try await reader.read(file)
        XCTAssertEqual(rewritten.items.first?.text, "later")

        try (replacement + "{partial").write(to: file, atomically: false, encoding: .utf8)
        let partial = try await reader.read(file)
        XCTAssertTrue(partial.incompleteTail)
        XCTAssertEqual(partial.items.first?.text, "later")

        try replacement.write(to: file, atomically: false, encoding: .utf8)
        let recovered = try await reader.read(file)
        XCTAssertFalse(recovered.incompleteTail)
        XCTAssertEqual(recovered.items.first?.text, "later")
    }

    func testHistoryPartialTailVisibleAndUnknownVersionRejected() async throws {
        let root = try directory(), reader = PiHistoryReader(roots: [])
        let partial = try historyFile(root, records: [user("a", nil, "kept")], tail: "{partial")
        let history = try await reader.read(partial)
        XCTAssertTrue(history.incompleteTail); XCTAssertEqual(history.items.first?.text, "kept")
        let invalid = try historyFile(root, version: 99), before = try Data(contentsOf: invalid)
        do { _ = try await reader.read(invalid); XCTFail("Accepted unknown version") } catch {}
        XCTAssertEqual(try Data(contentsOf: invalid), before)
    }
    func testCorruptAndBrokenParentAreRejectedRatherThanEmptyHistory() async throws {
        let root = try directory(), reader = PiHistoryReader(roots: [])
        for file in [try historyFile(root, tail: "bad\n"), try historyFile(root, records: [user("a","missing","bad")])] {
            do { _ = try await reader.read(file); XCTFail("Accepted corrupt history") } catch {}
        }
    }
    func testHistoryUnfinishedToolIsInterruptedAndResultReplacesIt() async throws {
        let root = try directory(), reader = PiHistoryReader(roots: [])
        let call: [String: Any] = ["type":"message","id":"a","parentId":NSNull(),"message":["role":"assistant","content":[["type":"toolCall","id":"call","name":"bash","arguments":["command":"test"]]]]]
        let unfinished = try await reader.read(historyFile(root, records: [call]))
        XCTAssertEqual(unfinished.items.first?.tool?.state, .interrupted)
        let result: [String: Any] = ["type":"message","id":"b","parentId":"a","message":["role":"toolResult","toolCallId":"call","toolName":"bash","content":[["type":"text","text":"done"]],"isError":false]]
        let complete = try await reader.read(historyFile(root, records: [call,result]))
        XCTAssertEqual(complete.items.count, 1); XCTAssertEqual(complete.items.first?.tool?.state, .completed)
        XCTAssertTrue(complete.items.first?.tool?.arguments.contains("test") == true)
    }
    func testHistoricalErrorsAreVisibleWithoutCredentialDetail() async throws {
        let root = try directory()
        let record: [String: Any] = ["type":"message", "id":"a", "parentId":NSNull(), "message":["role":"assistant", "content":[], "stopReason":"error", "errorMessage":"401 unauthorized sk-history-fixture-secret"]]
        let history = try await PiHistoryReader(roots: []).read(historyFile(root, records: [record]))
        XCTAssertEqual(history.items.first?.kind, .notice)
        XCTAssertEqual(history.items.first?.text, String(localized: "模型认证失败，请检查 Pi 的认证配置。", bundle: Bundle(for: PiRuntime.self)))
        XCTAssertFalse(history.items.contains { $0.text.contains("fixture-secret") })
    }
    func testMovedHistoryIsRejectedBeforeAnyExecutableStarts() async throws {
        let root = try directory(), moved = try directory(), file = try historyFile(root, records: [user("a",nil,"old")])
        let config = PiConfiguration(executable: root.appendingPathComponent("nonexistent"), nodeDirectory: root, workspace: moved, agentDirectory: root, sessionDirectory: root.appendingPathComponent("sessions"), resumeFile: file, expectedSessionID: "fixture")
        let runtime = PiRuntime(configuration: config)
        do { _ = try await runtime.connect(); XCTFail("Executed moved history") }
        catch let error as RuntimeFailure { XCTAssertEqual(error.kind, .setup); XCTAssertEqual(error.detail, String(localized: "历史工作目录与项目当前位置不同。请只读查看旧会话，或在当前位置新建会话；不会在旧目录执行。", bundle: Bundle(for: PiRuntime.self))) }
        try await runtime.close(force: true)
    }
    func testSwiftDataReopenRestoresIDsDraftsAndRejectsStaleSave() async throws {
        let root = try directory(), url = root.appendingPathComponent("workspace.store")
        var snapshot = WorkspaceSnapshot(); let project = ProjectRecord(path: root.path)
        var session = SessionReference(projectID: project.id); session.draft = "未发送"; session.recovered = [.init(text: "清出的内容", mode: .followUp)]
        snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id; snapshot.revision = 5
        let first = try SwiftDataWorkspaceStore(url: url); try await first.save(snapshot)
        var stale = snapshot; stale.revision = 4; stale.sessions[0].draft = "stale"; try await first.save(stale)
        let second = try SwiftDataWorkspaceStore(url: url), restored = try await second.load()
        XCTAssertEqual(restored.sessions[0], session); XCTAssertEqual(restored.selectedSessionID, session.id)
        XCTAssertEqual(restored.projects[0].id, project.id)
    }
    func testConcurrentActivationCannotCreateTwoExecutionInstances() async throws {
        let root = try directory(), file = try historyFile(root, records: [user("a",nil,"history")])
        var snapshot = WorkspaceSnapshot(); let project = ProjectRecord(path: root.resolvingSymlinksInPath().path)
        var session = SessionReference(projectID: project.id); session.runtimeSessionID = "fixture"; session.file = file; session.historyConfirmed = true
        snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id
        let store = MemoryWorkspaceStore(snapshot); var starts = 0
        let workspace = WorkspaceController(store: store, reader: SlowHistoryReader()) { _,_ in starts += 1; return WorkspaceTestRuntime(identity: "fixture", file: file) }
        await workspace.start()
        let first = Task { await workspace.activate(session.id) }
        try await Task.sleep(for: .milliseconds(10))
        let second = await workspace.activate(session.id)
        XCTAssertFalse(second); let connected = await first.value; XCTAssertTrue(connected); XCTAssertEqual(starts, 1)
        _ = await workspace.disconnectAll()
    }
    func testMissingMaterializedHistoryDoesNotBecomeANewEmptySession() async throws {
        let root = try directory(), file = try historyFile(root, records: [user("a",nil,"history")])
        var snapshot = WorkspaceSnapshot(); let project = ProjectRecord(path: root.resolvingSymlinksInPath().path)
        var session = SessionReference(projectID: project.id); session.runtimeSessionID = "fixture"; session.file = file; session.historyConfirmed = true
        snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id
        let runtime = WorkspaceTestRuntime(identity: "fixture", file: file)
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(snapshot), reader: PiHistoryReader(roots: [])) { _,_ in runtime }
        await workspace.start(); let connected = await workspace.activate(session.id); XCTAssertTrue(connected)
        try FileManager.default.removeItem(at: file)
        runtime.emit(.settled(aborted: false)); try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(workspace.selected?.file, file); XCTAssertEqual(workspace.selected?.runtimeSessionID, "fixture")
        workspace.viewed!.controller.draft = "do not send"
        await workspace.send(session.id); XCTAssertEqual(runtime.sendCount, 0)
        _ = await workspace.disconnectAll(); await workspace.refreshHistory(session.id)
        XCTAssertNotNil(workspace.viewed?.loadError)
    }
    func testTypingDuringActivationDoesNotReplaceSubmittedContent() async throws {
        let root = try directory(), file = try historyFile(root, records: [user("a",nil,"history")])
        var snapshot = WorkspaceSnapshot(); let project = ProjectRecord(path: root.resolvingSymlinksInPath().path)
        var session = SessionReference(projectID: project.id); session.runtimeSessionID = "fixture"; session.file = file; session.historyConfirmed = true
        snapshot.projects = [project]; snapshot.sessions = [session]; snapshot.selectedSessionID = session.id
        let runtime = WorkspaceTestRuntime(identity: "fixture", file: file)
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(snapshot), reader: SlowHistoryReader()) { _,_ in runtime }
        await workspace.start(); workspace.viewed!.controller.draft = "clicked send"
        let sending = Task { await workspace.send(session.id) }
        try await Task.sleep(for: .milliseconds(10)); workspace.viewed!.controller.draft = "new typing"
        await sending.value
        XCTAssertEqual(runtime.submittedTexts, ["clicked send"])
        XCTAssertEqual(workspace.viewed!.controller.draft, "new typing")
        _ = await workspace.disconnectAll()
    }
    func testBrowseAndDraftsDoNotCreateRuntimeOrStopCurrentTask() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(), reader = PiHistoryReader(roots: [])
        var runtimes: [WorkspaceTestRuntime] = []
        let workspace = WorkspaceController(store: store, reader: reader) { _,_ in let value = WorkspaceTestRuntime(); runtimes.append(value); return value }
        await workspace.start(); let project = await workspace.addProject(root)!
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
        let reader = PiHistoryReader(roots: [])
        let workspace = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await workspace.start()
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
        let reopened = WorkspaceController(store: MemoryWorkspaceStore(decoded), reader: reader) { _, _ in FakeRuntime() }
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
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await workspace.start()
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
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in WorkspaceTestRuntime() }
        await workspace.start()
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
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: PiHistoryReader(roots: [])) { project, reference in
            let runtime = WorkspaceTestRuntime()
            directories.append(reference.workingDirectory(in: project))
            runtimes.append(runtime)
            return runtime
        }
        await workspace.start()
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

    func testMoreThanTwoSessionsRunWithoutEvictionAndCleanupRemainsIsolated() async throws {
        var failedID: UUID?
        var runtimes: [UUID: WorkspaceTestRuntime] = [:]
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(), reader: PiHistoryReader(roots: [])) { _, reference in
            let runtime = WorkspaceTestRuntime(closeFails: reference.id == failedID)
            runtimes[reference.id] = runtime
            return runtime
        }
        await workspace.start()
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
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in WorkspaceTestRuntime() }
        await workspace.start()
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

        let reopened = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in WorkspaceTestRuntime() }
        await reopened.start()
        XCTAssertEqual(Set(reopened.state.sessions.map(\.id)), Set([sourceID, otherID]))
        XCTAssertEqual(reopened.workingDirectory(for: sourceID), root.path)
        await reopened.select(sourceID)
        XCTAssertEqual(reopened.viewed?.controller.draft, "keep A")
    }

    func testWorktreeDirectoryPersistsAndBoundSessionCanCopyDraftIntoAnotherDirectory() async throws {
        let root = try directory().resolvingSymlinksInPath()
        let worktree = try directory().resolvingSymlinksInPath()
        let store = MemoryWorkspaceStore()
        var startedPaths: [String] = []
        func makeWorkspace() -> WorkspaceController {
            WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { project, reference in
                startedPaths.append(reference.workingDirectory(in: project))
                return WorkspaceTestRuntime()
            }
        }
        var workspace = makeWorkspace()
        await workspace.start()
        _ = await workspace.addProject(root)
        let first = workspace.selected!.id
        workspace.viewed!.controller.draft = "use checkout"
        workspace.viewed!.controller.draftFiles = [root.appendingPathComponent("notes.txt")]
        let selected = await workspace.chooseWorkingDirectory(worktree: worktree.path, for: first)
        XCTAssertTrue(selected)
        XCTAssertEqual(workspace.viewed?.controller.draft, "use checkout")
        await workspace.send(first)
        XCTAssertEqual(startedPaths, [worktree.path])
        XCTAssertTrue(workspace.selected?.hasBoundWorkingDirectory == true)
        workspace.viewed!.controller.draft = "copy this draft"
        workspace.viewed!.controller.draftFiles = [root.appendingPathComponent("notes.txt")]
        let forked = await workspace.chooseWorkingDirectory(worktree: nil, for: first)
        XCTAssertTrue(forked)
        let second = workspace.selected!.id
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(workspace.workingDirectory(for: first), worktree.path)
        XCTAssertEqual(workspace.workingDirectory(for: second), root.path)
        XCTAssertEqual(workspace.viewed?.controller.draft, "copy this draft")
        XCTAssertEqual(workspace.viewed?.controller.draftFiles.count, 1)
        await workspace.stop(first)
        let closed = await workspace.disconnectAll()
        XCTAssertTrue(closed)

        workspace = makeWorkspace()
        await workspace.start()
        XCTAssertEqual(workspace.workingDirectory(for: first), worktree.path)
        XCTAssertEqual(workspace.workingDirectory(for: second), root.path)
        let restored = try XCTUnwrap(workspace.state.sessions.first { $0.id == first })
        XCTAssertFalse(restored.submissions.contains(where: \.needsReview))
        try FileManager.default.removeItem(at: worktree)
        await workspace.send(first, submitted: .init(text: "do not fall back"))
        XCTAssertEqual(startedPaths, [worktree.path])
        XCTAssertTrue(workspace.presentations[first]?.executionError?.contains(worktree.path) == true)
    }
    func testAliasedPiHistoryCannotBeWrittenByTwoSessions() async throws {
        let root = try directory().resolvingSymlinksInPath()
        let file = try historyFile(root, records: [user("a", nil, "history")])
        let alias = root.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let firstProject = ProjectRecord(path: root.path)
        let secondProject = ProjectRecord(path: root.path)
        var first = SessionReference(projectID: firstProject.id)
        first.runtimeSessionID = "fixture"
        first.file = file
        first.historyConfirmed = true
        var second = SessionReference(projectID: secondProject.id)
        second.runtimeSessionID = "fixture"
        second.file = alias
        second.historyConfirmed = true
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [firstProject, secondProject]
        snapshot.sessions = [first, second]
        snapshot.selectedSessionID = first.id
        var starts = 0
        let workspace = WorkspaceController(store: MemoryWorkspaceStore(snapshot), reader: PiHistoryReader(roots: [])) { _, reference in
            starts += 1
            return WorkspaceTestRuntime(identity: "fixture", file: reference.file)
        }
        await workspace.start()
        await workspace.send(first.id, submitted: .init(text: "first"))
        await workspace.send(second.id, submitted: .init(text: "second"))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(workspace.executionIDs, [first.id])
        XCTAssertNotNil(workspace.presentations[second.id]?.executionError)
        _ = await workspace.disconnectAll()
    }

    func testStorageFailurePreventsPromptAndPreservesEditor() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(), runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in runtime }
        await workspace.start(); _ = await workspace.addProject(root)
        let id = workspace.selected!.id; _ = await workspace.activate(id)
        workspace.viewed!.controller.draft = "must stay"
        await store.setFailure(true); await workspace.send(id)
        XCTAssertEqual(runtime.sendCount, 0); XCTAssertEqual(workspace.viewed!.controller.draft, "must stay")
        await store.setFailure(false); _ = await workspace.disconnectAll()
    }
    func testRestartMarksPendingUnknownWithoutStartingRuntime() async throws {
        let root = try directory(), store = MemoryWorkspaceStore()
        var state = WorkspaceSnapshot(); let project = ProjectRecord(path: root.path); var session = SessionReference(projectID: project.id)
        session.draft = "editor"; session.submissions = [.init(.init(text: "may have executed"))]; session.wasExecuting = true
        state.projects = [project]; state.sessions = [session]; state.selectedSessionID = session.id
        try await store.save({ var value = state; value.revision = 1; return value }())
        var creations = 0
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in creations += 1; return WorkspaceTestRuntime() }
        await workspace.start()
        XCTAssertEqual(creations, 0); XCTAssertEqual(workspace.selected?.submissions.first?.delivery, .unknown)
        XCTAssertTrue(workspace.selected?.submissions.first?.needsReview == true)
        XCTAssertEqual(workspace.viewed?.controller.draft, "editor")
        await workspace.send(session.id); XCTAssertEqual(creations, 0)
    }
    func testRelocationKeepsProjectAndSessionIdentity() async throws {
        let root = try directory(), relocated = try directory(), store = MemoryWorkspaceStore()
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in WorkspaceTestRuntime() }
        await workspace.start(); let project = await workspace.addProject(root)!, session = workspace.selected!.id
        await workspace.relocateProject(project, to: relocated)
        XCTAssertEqual(workspace.selected?.id, session); XCTAssertEqual(workspace.selectedProject?.id, project)
        XCTAssertEqual(workspace.selectedProject?.path, relocated.resolvingSymlinksInPath().path)
        XCTAssertTrue(workspace.selectedProject!.previousPaths.contains(root.resolvingSymlinksInPath().path))
    }
    func testLateOldRuntimeEventCannotPolluteNewTarget() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(); var runtimes: [WorkspaceTestRuntime] = []
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in let value = WorkspaceTestRuntime(); runtimes.append(value); return value }
        await workspace.start(); let project = await workspace.addProject(root)!
        let first = workspace.selected!.id; workspace.viewed!.controller.draft = "first"; await workspace.send(first)
        await workspace.createSession(in: project); let second = workspace.selected!.id
        workspace.viewed!.controller.draft = "second"; await workspace.send(second)
        workspace.viewed!.controller.receive(.init(instanceID: runtimes[0].instanceID, event: .assistantCompleted(UUID(), "STALE")))
        XCTAssertEqual(runtimes.count, 2); XCTAssertFalse(workspace.viewed!.controller.transcript.contains { $0.text == "STALE" })
        XCTAssertEqual(Set(workspace.executionIDs), Set([first, second])); _ = await workspace.disconnectAll()
    }

    func testProjectPiConfigTrustDefaultsOffDecodesLegacyAndPersistsPerCanonicalDirectory() async throws {
        let legacyJSON = Data(#"{"version":1,"revision":1,"projects":[],"sessions":[],"preferences":{"piPath":"","nodeDirectory":"","proxy":""}}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyJSON)
        XCTAssertNil(decodedLegacy.trustedPiConfigDirectories)

        let sandbox = try directory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = sandbox.appendingPathComponent("repo")
        let wt1 = sandbox.appendingPathComponent("wt1")
        let wt2 = sandbox.appendingPathComponent("wt2")
        let moved = sandbox.appendingPathComponent("moved")
        let foreign = sandbox.appendingPathComponent("foreign")
        let symlinkRoot = sandbox.appendingPathComponent("repo-link")
        for path in [repo, moved, foreign] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["-c", "user.email=test@example.test", "-c", "user.name=Test", "commit", "--allow-empty", "-m", "init"], cwd: repo)
        try runGit(["worktree", "add", "-b", "wt1", wt1.path], cwd: repo)
        try runGit(["worktree", "add", "-b", "wt2", wt2.path], cwd: repo)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: repo)

        let storeURL = sandbox.appendingPathComponent("workspace.store")
        var launches: [WorkspaceRuntimeLaunch] = []
        @MainActor func makeWorkspace() throws -> WorkspaceController {
            let store = try SwiftDataWorkspaceStore(url: storeURL)
            return WorkspaceController(store: store, reader: PiHistoryReader(roots: []), validateWorktree: { projectPath, worktreePath in
                self.isGitWorktree(worktreePath, of: projectPath)
            }) { _, _, launch in
                launches.append(launch)
                return WorkspaceTestRuntime()
            }
        }

        var workspace = try makeWorkspace()
        await workspace.start()
        let addedProjectID = await workspace.addProject(repo)
        let projectID = try XCTUnwrap(addedProjectID)
        let sessionID = try XCTUnwrap(workspace.selected?.id)

        // Default off across root, worktrees, parent, and child directories.
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: repo.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: symlinkRoot.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt1.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt2.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: sandbox.path))

        // Invalid / non-owned directory is rejected and not recorded.
        let invalidFeedback = await workspace.setProjectPiConfigTrusted(true, forProject: projectID, directory: foreign.path)
        XCTAssertEqual(invalidFeedback?.warning, true)
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: foreign.path))

        // Enable via symlink path -> canonicalized exact match only.
        let symlinkFeedback = await workspace.setProjectPiConfigTrusted(true, forProject: projectID, directory: symlinkRoot.path)
        XCTAssertNil(symlinkFeedback)
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: repo.path))
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: symlinkRoot.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt1.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt2.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: sandbox.path))

        // Enable wt1, disable root -> root record removed, wt1 preserved.
        let wt1Feedback = await workspace.setProjectPiConfigTrusted(true, forProject: projectID, directory: wt1.path)
        XCTAssertNil(wt1Feedback)
        let disableRootFeedback = await workspace.setProjectPiConfigTrusted(false, forProject: projectID, directory: repo.path)
        XCTAssertNil(disableRootFeedback)
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: repo.path))
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: wt1.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt2.path))
        XCTAssertEqual(workspace.state.trustedPiConfigDirectories, [wt1.path])

        // Reopen from SwiftData store -> persisted state matches.
        workspace = try makeWorkspace()
        await workspace.start()
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: repo.path))
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: wt1.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: wt2.path))

        // Launch in root (false), fork bound session to wt1 (true), and launch wt2 (false).
        await workspace.send(sessionID, submitted: .init(text: "run root"))
        XCTAssertEqual(launches.last, .init(workingDirectory: repo.path, canonicalDirectory: repo.path, approveProjectConfiguration: false))
        await workspace.stop(sessionID)

        let forkedToWT1 = await workspace.chooseWorkingDirectory(worktree: wt1.path, for: sessionID)
        XCTAssertTrue(forkedToWT1)
        let wt1SessionID = try XCTUnwrap(workspace.selected?.id)
        XCTAssertNotEqual(wt1SessionID, sessionID)
        await workspace.send(wt1SessionID, submitted: .init(text: "run wt1"))
        XCTAssertEqual(launches.last, .init(workingDirectory: wt1.path, canonicalDirectory: wt1.path, approveProjectConfiguration: true))
        await workspace.stop(wt1SessionID)

        let createdWT2 = await workspace.createSession(in: projectID)
        let wt2SessionID = try XCTUnwrap(createdWT2)
        let choseWT2 = await workspace.chooseWorkingDirectory(worktree: wt2.path, for: wt2SessionID)
        XCTAssertTrue(choseWT2)
        await workspace.send(wt2SessionID, submitted: .init(text: "run wt2"))
        XCTAssertEqual(launches.last, .init(workingDirectory: wt2.path, canonicalDirectory: wt2.path, approveProjectConfiguration: false))
        await workspace.stop(wt2SessionID)
        let disconnectedBeforeRelocate = await workspace.disconnectAll()
        XCTAssertTrue(disconnectedBeforeRelocate)

        // Relocate project: target uses its own setting; source retains its own record.
        let enableRootBeforeRelocate = await workspace.setProjectPiConfigTrusted(true, forProject: projectID, directory: repo.path)
        XCTAssertNil(enableRootBeforeRelocate)
        let relocated = await workspace.relocateProject(projectID, to: moved)
        XCTAssertEqual(relocated?.warning, false)
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: moved.path))
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: repo.path))

        let createdMoved = await workspace.createSession(in: projectID)
        let movedSessionID = try XCTUnwrap(createdMoved)
        await workspace.send(movedSessionID, submitted: .init(text: "run moved"))
        XCTAssertEqual(launches.last, .init(workingDirectory: moved.path, canonicalDirectory: moved.path, approveProjectConfiguration: false))
        await workspace.stop(movedSessionID)
        let disconnectedMoved = await workspace.disconnectAll()
        XCTAssertTrue(disconnectedMoved)

        // Relocate back to repo -> repo's saved true record is restored.
        let relocatedBack = await workspace.relocateProject(projectID, to: repo)
        XCTAssertEqual(relocatedBack?.warning, false)
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: repo.path))
        let createdBack = await workspace.createSession(in: projectID)
        let backSessionID = try XCTUnwrap(createdBack)
        await workspace.send(backSessionID, submitted: .init(text: "run back"))
        XCTAssertEqual(launches.last, .init(workingDirectory: repo.path, canonicalDirectory: repo.path, approveProjectConfiguration: true))
        await workspace.stop(backSessionID)
        let disconnectedBack = await workspace.disconnectAll()
        XCTAssertTrue(disconnectedBack)
    }

    func testProjectPiConfigConcurrencySaveLockAndIdleReconnect() async throws {
        let sandbox = try directory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("root")
        let other = sandbox.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)

        let store = DelayedProjectConfigStore()
        var launches: [WorkspaceRuntimeLaunch] = []
        var runtimes: [WorkspaceTestRuntime] = []
        var nextCloseFails = false

        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _, launch in
            launches.append(launch)
            let runtime = WorkspaceTestRuntime(closeFails: nextCloseFails)
            runtimes.append(runtime)
            return runtime
        }
        await workspace.start()
        let addedRoot = await workspace.addProject(root)
        let rootProjectID = try XCTUnwrap(addedRoot)
        let rootSessionID = try XCTUnwrap(workspace.selected?.id)
        let addedOther = await workspace.addProject(other, createInitialSession: false)
        let otherProjectID = try XCTUnwrap(addedOther)
        let createdOther = await workspace.createSession(in: otherProjectID)
        let otherSessionID = try XCTUnwrap(createdOther)

        // Running session in root locks root toggle, while other directory remains editable.
        await workspace.select(rootSessionID)
        await workspace.send(rootSessionID, submitted: .init(text: "running"))
        let rootController = try XCTUnwrap(workspace.execution(for: rootSessionID))
        XCTAssertEqual(rootController.phase, .running)
        XCTAssertFalse(workspace.canChangeProjectPiConfig(for: root.path))
        XCTAssertTrue(workspace.canChangeProjectPiConfig(for: other.path))
        let busyAttempt = await workspace.setProjectPiConfigTrusted(true, forProject: rootProjectID, directory: root.path)
        XCTAssertEqual(busyAttempt?.warning, true)
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: root.path))

        // Waiting for interaction still locks root toggle.
        let interaction = RuntimeInteraction(instanceID: runtimes[0].instanceID, requestID: "req-1", kind: .confirm, title: "Confirm")
        rootController.receive(.init(instanceID: runtimes[0].instanceID, event: .interaction(interaction)))
        XCTAssertEqual(rootController.phase, .waitingInput)
        XCTAssertFalse(workspace.canChangeProjectPiConfig(for: root.path))
        let interactionEnded = expectation(description: "Interaction ended")
        withObservationTracking {
            _ = rootController.interactions
        } onChange: {
            interactionEnded.fulfill()
        }
        _ = await rootController.reply(interaction, .confirmed(true))
        await fulfillment(of: [interactionEnded], timeout: 1)

        // Queued prompt still locks root toggle.
        rootController.receive(.init(instanceID: runtimes[0].instanceID, event: .queue(.init(steering: [], followUp: ["queued"]))))
        XCTAssertFalse(workspace.canChangeProjectPiConfig(for: root.path))

        // Settling queue & run makes root idle and editable without disconnecting yet.
        rootController.receive(.init(instanceID: runtimes[0].instanceID, event: .queue(.init())))
        rootController.receive(.init(instanceID: runtimes[0].instanceID, event: .settled(aborted: false)))
        XCTAssertEqual(rootController.phase, .idle)
        XCTAssertTrue(workspace.canChangeProjectPiConfig(for: root.path))

        // Enable trust while idle -> idle connection stays until next send/activate, then reconnects.
        let enabledWhileIdle = await workspace.setProjectPiConfigTrusted(true, forProject: rootProjectID, directory: root.path)
        XCTAssertNil(enabledWhileIdle)
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: root.path))
        XCTAssertEqual(runtimes.count, 1)

        await workspace.send(rootSessionID, submitted: .init(text: "after trust enabled"))
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(launches.last, .init(workingDirectory: root.path, canonicalDirectory: root.path, approveProjectConfiguration: true))
        let secondRuntime = try XCTUnwrap(runtimes.dropFirst().first)
        workspace.execution(for: rootSessionID)?.receive(.init(instanceID: secondRuntime.instanceID, event: .settled(aborted: false)))

        // Next idle reconnect where old runtime cleanup fails -> preserves draft, blocks execution, keeps old connection blocked.
        await workspace.stop(rootSessionID)
        let closedClean = await workspace.disconnect(rootSessionID)
        XCTAssertTrue(closedClean)
        nextCloseFails = true
        await workspace.activate(rootSessionID) // launches runtime[2] with closeFails = true
        XCTAssertEqual(runtimes.count, 3)
        let disabledWhileIdle = await workspace.setProjectPiConfigTrusted(false, forProject: rootProjectID, directory: root.path)
        XCTAssertNil(disabledWhileIdle)
        workspace.presentations[rootSessionID]?.controller.draft = "keep my draft on cleanup failure"
        await workspace.send(rootSessionID)
        XCTAssertEqual(runtimes.count, 3)
        XCTAssertEqual(workspace.presentations[rootSessionID]?.controller.draft, "keep my draft on cleanup failure")
        XCTAssertNotNil(workspace.presentations[rootSessionID]?.executionError)

        // Reset runtime[2] slot via stop/disconnect won't clear blocked, so test save-in-progress & failure on `other`.
        nextCloseFails = false
        let saveBegan = expectation(description: "Config save reached store")
        await store.pauseNextConfigWrite(began: saveBegan, shouldFail: true)
        let saveTask = Task {
            await workspace.setProjectPiConfigTrusted(true, forProject: otherProjectID, directory: other.path)
        }
        await fulfillment(of: [saveBegan], timeout: 2)

        // While saving `other`: toggle locked, activate/send for `other` blocked with draft preserved.
        XCTAssertTrue(workspace.isSavingProjectPiConfig(for: other.path))
        XCTAssertFalse(workspace.canChangeProjectPiConfig(for: other.path))
        workspace.presentations[otherSessionID]?.controller.draft = "draft during save"
        await workspace.send(otherSessionID)
        XCTAssertEqual(runtimes.count, 3)
        XCTAssertEqual(workspace.presentations[otherSessionID]?.controller.draft, "draft during save")
        XCTAssertNotNil(workspace.presentations[otherSessionID]?.executionError)

        await store.finishPausedConfigWrite()
        let saveFailure = await saveTask.value
        XCTAssertEqual(saveFailure?.warning, true)
        XCTAssertNotNil(workspace.storageError)
        // Saved value remains false in memory.
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: other.path))
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
