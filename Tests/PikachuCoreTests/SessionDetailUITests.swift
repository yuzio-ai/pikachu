import Foundation
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import PiRuntimeAdapter
@testable import PikachuApp

private final class TestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var mono: ContinuousClock.Instant

    init(wall: Date = Date(timeIntervalSince1970: 1_795_000_000), mono: ContinuousClock.Instant = ContinuousClock.now) {
        self.wall = wall
        self.mono = mono
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            mono = mono.advanced(by: .milliseconds(Int64((seconds * 1000).rounded())))
        }
    }

    func now() -> Date { lock.withLock { wall } }
    func monotonicNow() -> ContinuousClock.Instant { lock.withLock { mono } }
}

private actor MemoryStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private final class StubSessionRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    let sessionID: String
    let file: URL?
    var usageResponses: [Result<RuntimeUsage, Error>] = []
    private let lock = NSLock()

    init(sessionID: String = "stub-session", file: URL? = nil) {
        self.sessionID = sessionID
        self.file = file
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: sessionID, model: "GPT-5.4", thinking: "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: "openai", modelID: "gpt-5.4")
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { .started }
    func stop() async throws { emit(.settled(aborted: true)) }
    func close(force: Bool) async throws { emit(.disconnected(cleanupConfirmed: true)); continuation.finish() }
    func configurationOptions() async throws -> RuntimeConfigurationOptions {
        .init(models: [.init(provider: "openai", modelID: "gpt-5.4", name: "GPT-5.4")], thinkingLevels: ["low", "high"])
    }
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        .init(id: sessionID, model: selection.modelID, thinking: selection.thinking ?? "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: selection.provider, modelID: selection.modelID)
    }
    func enqueueUsage(_ result: Result<RuntimeUsage, Error>) {
        lock.withLock { usageResponses.append(result) }
    }
    func usage() async throws -> RuntimeUsage {
        let next = lock.withLock { usageResponses.isEmpty ? nil : usageResponses.removeFirst() }
        if let next { return try next.get() }
        return RuntimeUsage(sessionID: sessionID)
    }
    func emit(_ event: AgentEvent) { continuation.yield(.init(instanceID: instanceID, event: event)) }
}

final class SessionDetailUITests: XCTestCase {
    func testGitInspectorCoversUnbornDetachedUpstreamChangesAndDeduplication() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Pikachu-Git-Test-\(UUID())")
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        let nonRepo = root.appendingPathComponent("plain")
        let missing = root.appendingPathComponent("does-not-exist")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let missingState = await GitRepositoryInspector.inspect(directory: missing, now: fixedNow)
        XCTAssertEqual(missingState, .directoryMissing(directoryPath: GitRepositoryInspector.normalizedPath(missing.path), reason: "工作目录不存在或已移动。", updatedAt: fixedNow))
        if case .notRepository = GitRepositoryInspector.inspectSync(directoryPath: nonRepo.path) {} else {
            XCTFail("Expected non-repository state")
        }

        try runGit(["init", "--bare", "-q"], cwd: remote)
        try runGit(["init", "-q", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test"], cwd: repo)

        // Unborn repo keeps branch name and marks ahead unavailable.
        let unbornState = GitRepositoryInspector.inspectSync(directoryPath: repo.path)
        let unbornSnap = try XCTUnwrap(unbornState.snapshot)
        XCTAssertEqual(unbornSnap.branch, .branch(name: "main", hasCommits: false))
        if case .unavailable = unbornSnap.ahead {} else { XCTFail("Unborn repo should have unavailable ahead count") }

        try "keep\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "del\n".write(to: repo.appendingPathComponent("del.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "rename line\n", count: 8).write(to: repo.appendingPathComponent("ren.txt"), atomically: true, encoding: .utf8)
        try "recreate\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)
        try "*.ignored\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-q", "-m", "initial"], cwd: repo)

        // No upstream yet.
        let noUpstream = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(noUpstream.branch, .branch(name: "main", hasCommits: true))
        XCTAssertEqual(noUpstream.ahead.displayText, "—")
        XCTAssertEqual(noUpstream.changes.totalCount, 0)

        // Configure local bare upstream: 0 ahead, then 2 ahead.
        try runGit(["remote", "add", "origin", remote.path], cwd: repo)
        try runGit(["push", "-q", "-u", "origin", "main"], cwd: repo)
        let zeroAhead = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(zeroAhead.ahead, .count(0, upstream: "origin/main"))

        try "c1\n".write(to: repo.appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c1.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c1"], cwd: repo)
        try "c2\n".write(to: repo.appendingPathComponent("c2.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c2.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c2"], cwd: repo)

        // Staged + unstaged duplicate modification on keep.txt -> 1 modified.
        try "keep staged\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "keep.txt"], cwd: repo)
        try "keep worktree\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        // Deleted del.txt -> 1 deleted.
        try fm.removeItem(at: repo.appendingPathComponent("del.txt"))

        // Renamed ren.txt -> ren2.txt -> 1 renamed.
        try runGit(["mv", "ren.txt", "ren2.txt"], cwd: repo)

        // Staged delete + recreated untracked at same path -> 1 modified (deduplicated).
        try runGit(["rm", "-q", "recreate.txt"], cwd: repo)
        try "recreated\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)

        // Staged add + unstaged modify -> 1 added; untracked -> 1 added; ignored -> excluded.
        try "new staged\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "new_staged.txt"], cwd: repo)
        try "new staged edited\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: repo.appendingPathComponent("skip.ignored"), atomically: true, encoding: .utf8)

        let dirty = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(dirty.ahead, .count(2, upstream: "origin/main"))
        XCTAssertEqual(dirty.changes.addedCount, 2) // new_staged.txt, untracked.txt
        XCTAssertEqual(dirty.changes.deletedCount, 1) // del.txt
        XCTAssertEqual(dirty.changes.modifiedCount, 2) // keep.txt, recreate.txt
        XCTAssertEqual(dirty.changes.renamedCount, 1) // ren.txt -> ren2.txt
        XCTAssertEqual(dirty.changes.totalCount, 6)

        // Detached HEAD shows short SHA and unavailable ahead.
        try runGit(["checkout", "-q", "--detach", "HEAD"], cwd: repo)
        let detached = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        if case .detached(let sha) = detached.branch {
            XCTAssertFalse(sha.isEmpty)
        } else {
            XCTFail("Expected detached HEAD")
        }
        if case .unavailable = detached.ahead {} else { XCTFail("Detached HEAD should have unavailable ahead count") }
    }

    @MainActor func testGitStoreDiscardsStaleResponsesAndNeverBorrowsOtherProjectOnFailure() async throws {
        let dirA = "/tmp/git-store-a-\(UUID().uuidString)"
        let dirB = "/tmp/git-store-b-\(UUID().uuidString)"
        let snapA = GitRepositorySnapshot(
            directoryPath: GitRepositoryInspector.normalizedPath(dirA),
            checkoutRoot: GitRepositoryInspector.normalizedPath(dirA),
            branch: .branch(name: "main", hasCommits: true),
            ahead: .count(2, upstream: "origin/main"),
            changes: .init(addedFiles: ["a.swift"], deletedFiles: [], modifiedFiles: [], renamedFiles: []),
            updatedAt: Date()
        )
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
        }
        let counter = Counter()
        let store = GitStatusStore { url in
            let path = url.path
            if path.hasSuffix(URL(fileURLWithPath: dirA).lastPathComponent) {
                let step = counter.next()
                if step == 1 {
                    try? await Task.sleep(for: .milliseconds(60))
                    return .loaded(snapA, isStale: false, refreshError: nil)
                }
                return .notRepository(directoryPath: path, reason: "不再是仓库", updatedAt: Date())
            }
            return .failed(directoryPath: path, reason: "读取失败", updatedAt: Date())
        }

        store.refresh(directory: dirA, force: true)
        store.refresh(directory: dirA, force: true) // supersedes slow generation 1
        store.refresh(directory: dirB, force: true)
        try await Task.sleep(for: .milliseconds(100))

        if case .notRepository = store.state(for: dirA) {} else {
            XCTFail("Expected newer generation result for dirA, got \(store.state(for: dirA))")
        }
        if case .failed = store.state(for: dirB) {} else {
            XCTFail("Expected failed state for dirB without borrowing dirA values")
        }
    }

    @MainActor func testClockRoundsFollowUpSplitAttributionAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-SD03-Test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionFile = root.appendingPathComponent("session.jsonl")
        let userTsMs: Int64 = 1_795_000_000_000
        let assistant1TsMs: Int64 = 1_795_000_002_000
        let assistant2TsMs: Int64 = 1_795_000_138_000

        let clock = TestClock(wall: Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))
        let runtime = StubSessionRuntime(sessionID: "sd03-session", file: sessionFile)
        let store = MemoryStore()
        let reader = PiHistoryReader(roots: [root])
        let workspace = WorkspaceController(store: store, reader: reader, clock: clock) { _, _ in runtime }
        await workspace.start()
        _ = await workspace.addProject(root)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(sessionID)
        XCTAssertTrue(activated)

        let controller = try XCTUnwrap(workspace.active)
        let attachment = root.appendingPathComponent("notes.txt")
        controller.draft = "排查顶栏"
        controller.draftFiles = [attachment]
        await workspace.send(sessionID)
        XCTAssertEqual(controller.transcript.first?.sentAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))

        // Live round 1 with steer + multiple assistant blocks + tool group.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        controller.receive(.init(instanceID: runtime.instanceID, event: .userMessageTimestamp(userTsMs)))
        let a1 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a1)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantTimestamp(a1, assistant1TsMs)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a1, "第一段分析")))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "t1", name: "read", state: .completed))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "t2", name: "grep", state: .completed))))
        let a2 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a2)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantTimestamp(a2, assistant2TsMs)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a2, "第二段结论")))

        clock.advance(by: 138) // 2 min 18 sec
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        try await Task.sleep(for: .milliseconds(30))

        let liveRows = TranscriptDisplayRow.grouped(controller.transcript)
        let liveHeaders = TranscriptDisplayRow.turnHeaders(for: liveRows)
        XCTAssertEqual(liveHeaders.count, 1) // Only once on the first visible assistant row!
        let headerRowIndex = try XCTUnwrap(liveHeaders.keys.first)
        if case .item(let item) = liveRows[headerRowIndex] {
            XCTAssertEqual(item.kind, .assistant)
            XCTAssertEqual(item.text, "第一段分析")
        } else {
            XCTFail("Expected first assistant row to own turn header")
        }
        let round1 = try XCTUnwrap(liveHeaders.values.first)
        XCTAssertEqual(round1.status, .completed)
        XCTAssertEqual(try XCTUnwrap(round1.durationSeconds), 138, accuracy: 0.01)
        XCTAssertEqual(round1.endedAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0 + 138))

        // Persist matching Pi v3 JSONL and reload in a fresh WorkspaceController.
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "sd03-session", "cwd": root.resolvingSymlinksInPath().path, "timestamp": "2026-11-18T12:26:40.000Z"],
            ["type": "message", "id": "u1", "parentId": NSNull(), "timestamp": "2026-11-18T12:26:40.000Z",
             "message": ["role": "user", "content": [["type": "text", "text": UserPrompt(text: "排查顶栏", files: [attachment]).runtimeText]], "timestamp": userTsMs]],
            ["type": "message", "id": "a1", "parentId": "u1", "timestamp": "2026-11-18T12:26:42.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "第一段分析"], ["type": "toolCall", "id": "t1", "name": "read", "arguments": [:]], ["type": "toolCall", "id": "t2", "name": "grep", "arguments": [:]]], "stopReason": "toolUse", "timestamp": assistant1TsMs]],
            ["type": "message", "id": "tr1", "parentId": "a1", "timestamp": "2026-11-18T12:26:43.000Z",
             "message": ["role": "toolResult", "toolCallId": "t1", "toolName": "read", "content": "ok", "isError": false]],
            ["type": "message", "id": "tr2", "parentId": "tr1", "timestamp": "2026-11-18T12:26:44.000Z",
             "message": ["role": "toolResult", "toolCallId": "t2", "toolName": "grep", "content": "ok", "isError": false]],
            ["type": "message", "id": "a2", "parentId": "tr2", "timestamp": "2026-11-18T12:28:58.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "第二段结论"]], "stopReason": "stop", "timestamp": assistant2TsMs]],
        ]
        let jsonl = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        _ = await workspace.disconnect()
        _ = await workspace.flush()

        let reopened = WorkspaceController(store: store, reader: reader, clock: clock) { _, _ in FakeRuntime() }
        await reopened.start()
        let reloadedTranscript = try XCTUnwrap(reopened.viewed?.controller.transcript)
        let reloadedUser = try XCTUnwrap(reloadedTranscript.first(where: { $0.kind == .user }))
        XCTAssertEqual(reloadedUser.editableText, "排查顶栏")
        XCTAssertEqual(reloadedUser.editableFiles, [attachment])
        XCTAssertEqual(reloadedUser.sentAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))

        let reloadedRows = TranscriptDisplayRow.grouped(reloadedTranscript)
        let reloadedHeaders = TranscriptDisplayRow.turnHeaders(for: reloadedRows)
        XCTAssertEqual(reloadedHeaders.count, 1)
        let restoredRound = try XCTUnwrap(reloadedHeaders.values.first)
        XCTAssertEqual(restoredRound.status, .completed)
        XCTAssertEqual(try XCTUnwrap(restoredRound.durationSeconds), 138, accuracy: 0.01)
    }

    @MainActor func testToolOnlyTurnFollowUpSplitStopAndDisconnectUncertainty() async throws {
        let clock = TestClock()
        let controller = SessionController(clock: clock)
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)

        // Tool-only turn -> header attaches to tool group, then disconnects -> uncertain & nil time.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-1", name: "read", state: .completed))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-2", name: "bash", state: .completed))))
        clock.advance(by: 12)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))

        let rows = TranscriptDisplayRow.grouped(controller.transcript)
        let headers = TranscriptDisplayRow.turnHeaders(for: rows)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(try XCTUnwrap(headers[0]?.durationSeconds), 12, accuracy: 0.01)
        XCTAssertEqual(headers[0]?.status, .completed)

        // Stop round records stopped status + duration.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let stoppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(stoppedAssistant)))
        clock.advance(by: 5)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        let stoppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(stoppedTurn.status, .stopped)
        XCTAssertEqual(try XCTUnwrap(stoppedTurn.durationSeconds), 5, accuracy: 0.01)

        // Disconnect mid-round marks uncertain without guessing end time.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let droppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(droppedAssistant)))
        clock.advance(by: 9)
        controller.receive(.init(instanceID: runtime.instanceID, event: .disconnected(cleanupConfirmed: false)))
        let droppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(droppedTurn.status, .uncertain)
        XCTAssertNil(droppedTurn.endedAt)
        XCTAssertNil(droppedTurn.durationSeconds)
    }

    func testTimestampFormattingSameYearAndCrossYearAndDuration() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10, minute: 0))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 46, second: 12))!
        let prevYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 58, second: 0))!

        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(sameDay, relativeTo: now, calendar: cal, timeZone: tz), "11月19日 09:46")
        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(prevYear, relativeTo: now, calendar: cal, timeZone: tz), "2025年12月31日 23:58")
        XCTAssertTrue(TranscriptTimestampFormatter.fullTimeWithZone(sameDay, calendar: cal, timeZone: tz).contains("Asia/Shanghai"))
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(138), "2 分 18 秒")
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(0.4), "不足 1 秒")
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(3665), "1 小时 1 分 5 秒")
    }

    func testComposerPermissionsStatesForEffectiveVsNextRun() {
        let idleSwitched = ComposerPermissionsPresentation(
            selectedMode: .plan,
            activeMode: .interactive,
            isViewedSessionActive: true,
            isConnected: true,
            isActiveRunOrQueue: false,
            isReadOnlyHistory: false
        )
        XCTAssertTrue(idleSwitched.buttonText.contains("仅读工具"))
        XCTAssertTrue(idleSwitched.buttonText.contains("下次执行"))
        XCTAssertEqual(idleSwitched.effectiveMode, .interactive)

        let running = ComposerPermissionsPresentation(
            selectedMode: .plan,
            activeMode: .interactive,
            isViewedSessionActive: true,
            isConnected: true,
            isActiveRunOrQueue: true,
            isReadOnlyHistory: false
        )
        XCTAssertEqual(running.buttonText, "权限 · 需确认")
        XCTAssertEqual(running.effectiveMode, .interactive)

        let automatic = ComposerPermissionsPresentation(
            selectedMode: .automatic,
            activeMode: nil,
            isViewedSessionActive: false,
            isConnected: false,
            isActiveRunOrQueue: false,
            isReadOnlyHistory: true
        )
        XCTAssertEqual(automatic.buttonText, "权限 · 运行时配置")
    }

    @MainActor func testUsagePresentationAndLateResponseRejection() async {
        let usage = RuntimeUsage(
            sessionID: "s1",
            tokens: .init(input: 1_212_641, output: 127_445, cacheRead: 89_359_488, cacheWrite: 0, total: 90_699_574, inputIsUncached: true),
            estimatedCostUSD: nil,
            context: .init(tokens: 285_400, window: 475_000, percent: 60.08),
            observedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
        let normal = UsagePresentationSnapshot(usage: usage, isConnected: true, isStale: false, isLoading: false, isCompacting: false)
        XCTAssertEqual(normal.summaryText, "285k / 475k")
        XCTAssertEqual(normal.totalTokensText, "90.70M")
        XCTAssertEqual(normal.cacheHitRateText, "缓存命中 98.7%")
        XCTAssertEqual(normal.costText, "无法估算")
        XCTAssertFalse(normal.isOverCapacity)

        let zero = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", tokens: .init(total: 0, inputIsUncached: true), context: .init(tokens: 0, window: 475_000, percent: 0)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertEqual(zero.summaryText, "0 / 475k")
        XCTAssertEqual(zero.percentText, "0%")

        let compacted = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: nil, window: 475_000, percent: nil)),
            isConnected: true, isStale: true, isLoading: false, isCompacting: true
        )
        XCTAssertEqual(compacted.summaryText, "待更新")
        XCTAssertNil(compacted.summaryRatio)

        let over = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: 500_000, window: 475_000, percent: 105.3)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertTrue(over.isOverCapacity)
        XCTAssertEqual(over.summaryRatio, 1.0)

        // Late usage response from another session ID is discarded.
        let controller = SessionController()
        let runtime = StubSessionRuntime(sessionID: "real-session")
        await controller.connect(runtime)
        runtime.enqueueUsage(.success(RuntimeUsage(sessionID: "stale-session", tokens: .init(total: 999))))
        await controller.refreshUsage()
        XCTAssertNil(controller.usage?.tokens.total)
        _ = await controller.disconnect()
    }

    @MainActor func testFollowUpStartsNewRoundAndLegacyHistoryPreservesOnlyTrustedFields() async throws {
        // 1. Follow-up dequeuing starts a distinct round.
        let clock = TestClock()
        let runtime = StubSessionRuntime()
        let controller = SessionController(clock: clock)
        await controller.connect(runtime)

        controller.draft = "round 1"
        await controller.sendDraft()
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let a1 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a1)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a1, "first reply")))
        clock.advance(by: 10)

        let followPrompt = UserPrompt(text: "round 2", mode: .followUp)
        controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(steering: [], followUp: [followPrompt.runtimeText]))))
        controller.draft = followPrompt.text
        controller.mode = .followUp
        await controller.sendDraft(followPrompt)
        // Mark the queued item as queued explicitly for deterministic test, then dequeue it.
        if let queuedUser = controller.transcript.last(where: { $0.kind == .user }) {
            queuedUser.delivery = .queued
        }
        clock.advance(by: 5)
        controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(steering: [], followUp: []))))
        let a2 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a2)))
        clock.advance(by: 7)
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a2, "follow-up reply")))
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))

        let rows = TranscriptDisplayRow.grouped(controller.transcript)
        let headers = TranscriptDisplayRow.turnHeaders(for: rows)
        XCTAssertEqual(headers.count, 2)
        let turns = headers.keys.sorted().compactMap { headers[$0] }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(try XCTUnwrap(turns[0].durationSeconds), 15, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(turns[1].durationSeconds), 7, accuracy: 0.01)
        _ = await controller.disconnect()

        // 2. Legacy JSONL with synthetic numeric timestamp=1 falls back to ISO entry timestamp and keeps duration nil.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-Legacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.jsonl")
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "legacy", "cwd": root.path, "timestamp": "2026-11-18T00:00:00Z"],
            ["type": "message", "id": "u1", "parentId": NSNull(), "timestamp": "2026-11-18T00:00:01Z",
             "message": ["role": "user", "content": "hello", "timestamp": 1]],
            ["type": "message", "id": "a1", "parentId": "u1", "timestamp": "2026-11-18T00:01:00Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "world"]], "stopReason": "stop"]]
        ]
        let data = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try data.write(to: file, atomically: true, encoding: .utf8)

        let history = try await PiHistoryReader(roots: []).read(file)
        XCTAssertEqual(history.items.first?.sentAt, try Date.ISO8601FormatStyle().parse("2026-11-18T00:00:01Z"))
        XCTAssertEqual(history.turns.count, 1)
        XCTAssertEqual(history.turns.first?.status, .completed)
        XCTAssertEqual(history.turns.first?.endedAt, try Date.ISO8601FormatStyle().parse("2026-11-18T00:01:00Z"))
        XCTAssertNil(history.turns.first?.durationSeconds)

        let summary = TurnHeaderSummary(turn: TurnRecord(status: .completed, endedAt: history.turns.first?.endedAt, durationSeconds: nil),
                                        relativeTo: try Date.ISO8601FormatStyle().parse("2026-11-18T00:02:00Z"))
        XCTAssertFalse(summary.displayText.contains("执行 "))
        XCTAssertTrue(summary.displayText.contains("结束于"))
    }

    private func runGit(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "GitTest", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}
