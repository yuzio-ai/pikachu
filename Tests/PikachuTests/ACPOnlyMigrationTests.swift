import Foundation
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore

private actor MigrationStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    var histories: [UUID: SessionHistorySnapshot]
    private var rejectSave = true

    init(snapshot: WorkspaceSnapshot, histories: [UUID: SessionHistorySnapshot]) {
        self.snapshot = snapshot
        self.histories = histories
    }

    func load() -> WorkspaceSnapshot { snapshot }
    func allowSave() { rejectSave = false }
    func save(_ next: WorkspaceSnapshot) throws {
        if rejectSave { throw CocoaError(.fileWriteOutOfSpace) }
        snapshot = next
    }
    func loadSessionHistory(segmentID: UUID) async throws -> SessionHistorySnapshot {
        guard let history = histories[segmentID] else { throw CocoaError(.fileReadNoSuchFile) }
        return history
    }
    func pruneSessionHistory(retaining ids: Set<UUID>) async throws {
        histories = histories.filter { ids.contains($0.key) }
    }
}

@MainActor final class ACPOnlyMigrationTests: XCTestCase {
    func testFailedUpgradeAndRetryPreserveFilesAndPreviouslyFrozenSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let bytes = Data("original history".utf8)
        try bytes.write(to: file)
        let project = ProjectRecord(path: root.path)
        var old = SessionReference(projectID: project.id, runtimeID: "pi")
        old.file = file
        old.archivedAt = .now
        old.draft = "obsolete draft"
        let frozen = FrozenSessionSegment(id: UUID(), runtimeID: "pi", runtimeSessionID: "previous",
                                          file: file, modelName: nil, selection: nil, modeID: nil,
                                          coverage: .available, incomingHandoff: nil)
        var acp = SessionReference(projectID: project.id, runtimeID: "acp:removed")
        acp.draft = "keep draft"
        acp.mode = .followUp
        acp.frozenSegments = [frozen]
        var archived = SessionReference(projectID: project.id, runtimeID: "acp:disabled")
        archived.archivedAt = .now
        var original = WorkspaceSnapshot()
        original.projects = [project]
        var indexOnlyDraft = SessionReference(projectID: project.id, runtimeID: "pi")
        indexOnlyDraft.draft = "Unsent"
        original.sessions = [old, indexOnlyDraft, acp, archived]
        original.selectedSessionID = old.id
        original.preferences.defaultRuntimeID = "pi"
        original.runtimeEnvironments = ["pi": ["sample": "old"], acp.runtimeID: ["sample": "kept"]]
        let history = SessionHistorySnapshot(transcript: [.init(id: "prior", kind: .notice, text: "saved excerpt")],
                                             coverage: .available)
        let orphan = UUID()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload["preferences"] = ["piPath": "/old/pi", "nodeDirectory": "/old/node", "defaultRuntimeID": "pi"]
        payload["defaultFollowUpMode"] = "followUp"
        var legacySessions = try XCTUnwrap(payload["sessions"] as? [[String: Any]])
        legacySessions[2]["agentMode"] = "interactive"
        legacySessions[2]["agentModeSource"] = "session"
        legacySessions[2]["approvalPolicies"] = ["interactive", "everyCall"]
        payload["sessions"] = legacySessions
        payload["trustedPiConfigDirectories"] = [root.path]
        payload["sessionTitleSettings"] = ["mode": "specified", "rules": "short",
                                           "model": ["provider": "old", "modelID": "old", "name": "Previous model"]]
        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        let store = MigrationStore(snapshot: legacy, histories: [frozen.id: history, orphan: history])
        func reopen() async -> WorkspaceController {
            let workspace = WorkspaceController(store: store) { _, _ in
                XCTFail("Upgrade must not launch an agent")
                return FakeRuntime()
            }
            await workspace.start()
            return workspace
        }
        let failed = await reopen()
        XCTAssertFalse(failed.initialized)
        let unchanged = await store.load()
        XCTAssertEqual(unchanged.sessions, original.sessions)
        let before = await store.histories
        XCTAssertNotNil(before[orphan])

        await store.allowSave()
        for launch in 0..<2 {
            let workspace = await reopen()
            XCTAssertTrue(workspace.initialized)
            XCTAssertEqual(workspace.selected?.id, launch == 0 ? nil : acp.id)
            XCTAssertNil(workspace.defaultRuntimeID)
            XCTAssertEqual(workspace.sessionTitleSettings, .init(rules: "short"))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.state)) as? [String: Any])
            XCTAssertNil(saved["trustedPiConfigDirectories"])
            XCTAssertNil(saved["defaultFollowUpMode"])
            let migrated = try XCTUnwrap((saved["sessions"] as? [[String: Any]])?.first)
            XCTAssertNil(migrated["approvalPolicies"])
            XCTAssertNil(migrated["agentMode"])
            XCTAssertEqual(workspace.state.sessions.first?.mode, .followUp)
            XCTAssertNil((saved["preferences"] as? [String: Any])?["piPath"])
            XCTAssertEqual(workspace.state.sessions.map(\.id), [acp.id, archived.id])
            XCTAssertEqual(workspace.state.sessions.last?.archivedAt, archived.archivedAt)
            XCTAssertEqual(workspace.state.runtimeEnvironments, [acp.runtimeID: ["sample": "kept"]])
            await workspace.select(acp.id)
            XCTAssertEqual(workspace.viewed?.controller.draft, "keep draft")
            XCTAssertTrue(workspace.viewed?.frozenTranscript.contains { $0.text == "saved excerpt" } == true)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            _ = await workspace.flush()
            let remaining = await store.histories
            XCTAssertEqual(Set(remaining.keys), [frozen.id])
        }
    }

    func testChangingWorktreeUsesAnEnabledDefaultAndPreservesBoundSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(path: root.path)
        let disabled = RuntimeAgentProfile(id: "acp:old", name: "Old", executablePath: "/unused", enabled: false)
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let preferred = RuntimeAgentProfile(id: "acp:preferred", name: "Preferred", executablePath: "/unused")
        var original = SessionReference(projectID: project.id, runtimeID: disabled.id)
        original.runtimeSessionID = "bound"
        original.draft = "Carry the draft"
        original.draftFiles = [root.appendingPathComponent("notes.md")]
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [original]
        snapshot.selectedSessionID = original.id
        snapshot.preferences.acpAgents = [disabled]
        let store = MigrationStore(snapshot: snapshot, histories: [:])
        await store.allowSave()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        let unavailable = await workspace.chooseWorkingDirectory(worktree: tree.path, for: original.id)
        XCTAssertFalse(unavailable)
        XCTAssertEqual(workspace.state.sessions.map(\.id), [original.id])
        XCTAssertEqual(workspace.selected?.id, original.id)
        for agents in [[disabled, first], [first, preferred]] {
            workspace.setACPAgents(agents)
            workspace.setDefaultRuntimeID(preferred.id)
            await workspace.select(original.id)
            let changed = await workspace.chooseWorkingDirectory(worktree: tree.path, for: original.id)
            XCTAssertTrue(changed)
            XCTAssertEqual(workspace.selected?.runtimeID, agents.last?.id)
            XCTAssertEqual(workspace.selected?.draftFiles, original.draftFiles)
            XCTAssertEqual(workspace.selected?.draft, original.draft)
            XCTAssertEqual(workspace.state.sessions.first?.runtimeID, disabled.id)
            XCTAssertEqual(workspace.state.sessions.first?.runtimeSessionID, "bound")
            XCTAssertEqual(workspace.state.sessions.first?.draft, original.draft)
        }
    }

    func testUnavailableDraftAgentCanBeReplacedByTheOnlyEnabledAgent() async throws {
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        var draft = SessionReference(projectID: project.id, runtimeID: "acp:removed")
        draft.draft = "Keep typing"
        draft.draftFiles = [URL(fileURLWithPath: "/tmp/notes.txt")]
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [draft]
        snapshot.selectedSessionID = draft.id
        let agent = RuntimeAgentProfile.antigravityPreset()
        snapshot.preferences.acpAgents = [agent]
        let store = MigrationStore(snapshot: snapshot, histories: [:])
        await store.allowSave()
        var launched: [String] = []
        let workspace = WorkspaceController(store: store) { _, ref in
            launched.append(ref.runtimeID)
            return FakeRuntime()
        }
        await workspace.start()
        XCTAssertTrue(workspace.canSwitchDraftAgent(for: draft))
        XCTAssertEqual(workspace.selected?.runtimeID, draft.runtimeID)
        let switched = await workspace.setSessionRuntime(agent.id, for: draft.id)
        XCTAssertTrue(switched)
        XCTAssertEqual(workspace.selected?.draftFiles, draft.draftFiles)
        XCTAssertEqual(workspace.selected?.draft, draft.draft)
        await workspace.send(draft.id, submitted: .init(text: "Continue"))
        XCTAssertEqual(launched, [agent.id])
        _ = await workspace.disconnectAll()
    }

    func testNewSessionRequiresEnabledAgentAndRetainsOriginalBinding() async throws {
        let store = MigrationStore(snapshot: .init(), histories: [:])
        await store.allowSave()
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()
        let added = await workspace.addProject(FileManager.default.temporaryDirectory)
        let project = try XCTUnwrap(added)
        let empty = await workspace.createSession(in: project)
        XCTAssertNil(empty)
        XCTAssertTrue(workspace.state.sessions.isEmpty)
        var first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let second = RuntimeAgentProfile(id: "older-custom-agent", name: "Second", executablePath: "/unused")
        workspace.setACPAgents([first, second])
        XCTAssertEqual(workspace.defaultRuntimeID, first.id)
        workspace.setDefaultRuntimeID(second.id)
        XCTAssertEqual(workspace.defaultRuntimeID, second.id)
        _ = await workspace.createSession(in: project, runtimeID: first.id)
        workspace.setDefaultRuntimeID(first.id)
        first.enabled = false
        workspace.setACPAgents([first, second])
        XCTAssertEqual(workspace.defaultRuntimeID, second.id)
        XCTAssertEqual(workspace.selected?.runtimeID, first.id)
    }
}
