import XCTest
import Foundation
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

@MainActor final class WorkspaceTests: XCTestCase {
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
        XCTAssertEqual(workspace.state.sessions.first?.activity.date, legacyTime)
        XCTAssertEqual(workspace.state.sessions.first?.activity.isEstimate, true)
        XCTAssertEqual(workspace.state.sessions.last?.submissions.first?.needsReview, true)
        XCTAssertNil(workspace.activeID)
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
        XCTAssertEqual(workspace.active?.phase, .running)
        let other = await workspace.createSession(in: projectID)
        XCTAssertEqual(workspace.state.selectedSessionID, other)
        XCTAssertEqual(workspace.activeID, id)
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)

        let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "review", kind: .confirm, title: "确认操作")
        workspace.active?.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
        workspace.active?.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)
        workspace.active?.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(request.id, .answered)))
        XCTAssertEqual(workspace.active?.phase, .idle)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .open)
        await workspace.markSessionSettled(id)
        XCTAssertEqual(workspace.state.sessions.first(where: { $0.id == id })?.sidebarStatus, .settled)
        XCTAssertEqual(workspace.state.selectedSessionID, other)
        _ = await workspace.disconnect()
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
        XCTAssertTrue(workspace.notice?.contains("多个项目") == true)
        XCTAssertNil(workspace.activeID)
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
        XCTAssertEqual(host.active?.session?.thinking, "high")
        await host.send(session)
        XCTAssertTrue(host.active?.transcript.first?.text.contains(file.path) == true)
        XCTAssertTrue(host.active?.draftFiles.isEmpty == true)

        await host.createSession(in: try XCTUnwrap(project))
        let other = try XCTUnwrap(host.selected?.id)
        _ = try await host.configurationOptions(for: other)
        XCTAssertEqual(host.activeID, session)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(catalogRequests, 3)
        _ = await host.disconnect()
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
        await host.createSession(in: project.id)
        let session = try XCTUnwrap(host.selected?.id)
        XCTAssertEqual(host.selected?.executionMode, .interactive)
        await host.setAgentMode(.plan, for: session)
        let file = root.appendingPathComponent("引用文件.txt")
        host.viewed?.controller.draftFiles = [file]
        let flushed = await host.flush()
        XCTAssertTrue(flushed)

        let reopened = WorkspaceController(store: store, reader: reader) { _, _ in FakeRuntime() }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.id, session)
        XCTAssertEqual(reopened.selected?.executionMode, .plan)
        XCTAssertEqual(reopened.viewed?.controller.draftFiles, [file])
        XCTAssertTrue(reopened.viewed?.controller.draftPrompt.hasContent == true)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-M2-Test-\(UUID())")
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
        _ = await host.disconnect()
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
        XCTAssertTrue(history.items.first?.text.contains("认证失败") == true)
        XCTAssertFalse(history.items.contains { $0.text.contains("fixture-secret") })
    }
    func testMovedHistoryIsRejectedBeforeAnyExecutableStarts() async throws {
        let root = try directory(), moved = try directory(), file = try historyFile(root, records: [user("a",nil,"old")])
        let config = PiConfiguration(executable: root.appendingPathComponent("nonexistent"), nodeDirectory: root, workspace: moved, agentDirectory: root, sessionDirectory: root.appendingPathComponent("sessions"), resumeFile: file, expectedSessionID: "fixture")
        let runtime = PiRuntime(configuration: config)
        do { _ = try await runtime.connect(); XCTFail("Executed moved history") }
        catch let error as RuntimeFailure { XCTAssertTrue(error.detail.contains("当前位置")) }
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
        _ = await workspace.disconnect()
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
        _ = await workspace.disconnect(); await workspace.refreshHistory(session.id)
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
        _ = await workspace.disconnect()
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
        XCTAssertEqual(runtimes.count, 1); XCTAssertEqual(runtimes[0].stopCount, 0); XCTAssertEqual(workspace.activeID, first)
        await workspace.select(first); XCTAssertTrue(workspace.viewed!.controller.draft.isEmpty)
        await workspace.select(second); XCTAssertEqual(workspace.viewed!.controller.draft, "second draft")
        _ = await workspace.disconnect()
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
    func testSwitchRequiresExplicitStopAndDoesNotSendOnFailedCleanup() async throws {
        let root = try directory(), store = MemoryWorkspaceStore()
        var runtimes: [WorkspaceTestRuntime] = []
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in let value = WorkspaceTestRuntime(closeFails: true); runtimes.append(value); return value }
        await workspace.start(); let project = await workspace.addProject(root)!
        let first = workspace.selected!.id; workspace.viewed!.controller.draft = "run"; await workspace.send(first)
        await workspace.createSession(in: project); let second = workspace.selected!.id; workspace.viewed!.controller.draft = "keep target"
        await workspace.send(second); XCTAssertEqual(runtimes.count, 1); XCTAssertEqual(runtimes[0].stopCount, 0)
        await workspace.send(second, stopCurrent: true)
        XCTAssertEqual(runtimes.count, 1); XCTAssertEqual(workspace.activeID, first); XCTAssertEqual(workspace.viewed!.controller.draft, "keep target")
        XCTAssertEqual(workspace.active?.connection, .blocked)
    }
    func testStorageFailurePreventsPromptAndPreservesEditor() async throws {
        let root = try directory(), store = MemoryWorkspaceStore(), runtime = WorkspaceTestRuntime()
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _,_ in runtime }
        await workspace.start(); _ = await workspace.addProject(root)
        let id = workspace.selected!.id; _ = await workspace.activate(id)
        workspace.viewed!.controller.draft = "must stay"
        await store.setFailure(true); await workspace.send(id)
        XCTAssertEqual(runtime.sendCount, 0); XCTAssertEqual(workspace.viewed!.controller.draft, "must stay")
        await store.setFailure(false); _ = await workspace.disconnect()
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
        workspace.viewed!.controller.draft = "second"; await workspace.send(second, stopCurrent: true)
        workspace.viewed!.controller.receive(.init(instanceID: runtimes[0].instanceID, event: .assistantCompleted(UUID(), "STALE")))
        XCTAssertEqual(runtimes.count, 2); XCTAssertFalse(workspace.viewed!.controller.transcript.contains { $0.text == "STALE" })
        XCTAssertEqual(workspace.activeID, second); _ = await workspace.disconnect()
    }
}
