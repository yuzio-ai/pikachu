import XCTest
import AgentRuntimeCore
@testable import PiRuntimeAdapter
@testable import OrchestrationCore
@testable import Pikachu

final class TranscriptRenderingTests: XCTestCase {
    func testMarkdownTableKeepsAlignmentEmptyCellsAndInlineFormatting() throws {
        let blocks = MarkdownBlocks.parse("""
        | 功能 | RPC | 说明 |
        | :--- | :---: | ---: |
        | 发送 | `prompt` | **开始** |
        | 读取\\|状态 | [文档](https://example.com) |
        """)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(table.columns.map(\.alignment), [.left, .center, .right])
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false])
        XCTAssertEqual(table.rows[2].cells.map { String($0.characters) }, ["读取|状态", "文档", ""])
        XCTAssertEqual(table.rows[1].cells[1].runs.first?.inlinePresentationIntent, .code)
        XCTAssertEqual(table.rows[1].cells[2].runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(table.rows[2].cells[1].runs.first?.link?.absoluteString, "https://example.com")
    }

    func testMarkdownListsKeepStartingNumberNestingAndContinuation() throws {
        let blocks = MarkdownBlocks.parse("""
        3. 一项 **说明**
           同一项续行
           - 子项
           - 第二个子项
        4. 另一项

        普通段落。
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .list(ordered: true, let items) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected an ordered list")
        }
        XCTAssertEqual(items.map(\.ordinal), [3, 4])
        let firstItem = try XCTUnwrap(items.first)
        XCTAssertEqual(firstItem.blocks.first?.text, "一项 说明\n同一项续行")
        guard case .list(ordered: false, let subitems) = try XCTUnwrap(firstItem.blocks.last).kind else {
            return XCTFail("Expected a nested unordered list")
        }
        XCTAssertEqual(subitems.flatMap(\.blocks).map(\.text), ["子项", "第二个子项"])
        XCTAssertEqual(blocks.last?.text, "普通段落。")
    }

    func testMarkdownKeepsLiteralHTMLBetweenFormattedBlocks() throws {
        let blocks = MarkdownBlocks.parse("""
        **Run this:**

        <command>

        <div>**Visible text**</div>

        > <example>
        > body

        [After](https://example.com)
        """)

        XCTAssertEqual(blocks.map(\.text), ["Run this:", "<command>", "<div>**Visible text**</div>", "", "After"])
        guard blocks.count == 5 else { return }
        XCTAssertEqual(blocks.first?.content.runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNil(blocks[2].content.runs.first?.inlinePresentationIntent)
        guard case .quote(let quote) = blocks[3].kind else { return XCTFail("Expected a quote") }
        XCTAssertEqual(quote.map(\.text), ["<example>\nbody"])
        XCTAssertEqual(blocks.last?.content.runs.first?.link?.absoluteString, "https://example.com")
    }

    func testMarkdownKeepsCompletelyEmptyTableRows() throws {
        let blocks = MarkdownBlocks.parse("""
        | | |
        | :--- | ---: |
        | 甲 | 乙 |
        | | |
        | 丙 | 丁 |
        | | |

        > | |
        > | --- |
        > | |

        Plain pipes:
        | | |

        ```text
        | | |
        ```
        """)

        XCTAssertEqual(blocks.count, 4)
        guard blocks.count == 4,
              case .table(let table) = try XCTUnwrap(blocks.first).kind,
              case .quote(let quote) = blocks[1].kind,
              case .table(let emptyTable) = try XCTUnwrap(quote.first).kind else {
            return XCTFail("Expected two tables")
        }
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false, false, false])
        XCTAssertEqual(table.rows.map { $0.cells.map { String($0.characters) } },
                       [["", ""], ["甲", "乙"], ["", ""], ["丙", "丁"], ["", ""]])
        XCTAssertEqual(table.columns.map(\.alignment), [.left, .right])
        XCTAssertEqual(emptyTable.rows.map(\.isHeader), [true, false])
        XCTAssertEqual(emptyTable.rows.map { $0.cells.map { String($0.characters) } }, [[""], [""]])
        XCTAssertEqual(blocks[2].text, "Plain pipes:\n| | |")
        XCTAssertEqual(blocks[3].text, "| | |")
    }

    @MainActor func testDuplicateProtocolToolIDsHaveDistinctStableDisplayIDsOnRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        {"type":"session","version":3,"id":"duplicate-tools","cwd":"/tmp"}
        {"type":"message","id":"answer","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"reused","name":"read","arguments":{"path":"first"}},{"type":"toolCall","id":"reused","name":"read","arguments":{"path":"second"}}]}}
        {"type":"message","id":"result","parentId":"answer","message":{"role":"toolResult","toolCallId":"reused","toolName":"read","content":"local fixture","isError":false}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)

        let reader = PiHistoryReader(roots: [])
        let controller = SessionController()
        let initial = try await reader.read(url)
        controller.showHistory(initial.items, turns: initial.turns)
        let previousRows = TranscriptDisplayRow.project(controller.transcript)
        let previousIDs = previousRows.map(\.id)
        XCTAssertEqual(previousIDs.count, 2)
        XCTAssertEqual(Set(previousIDs).count, previousIDs.count)
        XCTAssertEqual(controller.transcript.compactMap { $0.tool?.state }, [.interrupted, .completed])
        XCTAssertEqual(Set(controller.transcript.map(\.id)).count, 2)
        XCTAssertEqual(controller.transcript.last?.tool?.output, "local fixture")

        let refreshed = try await reader.read(url)
        controller.showHistory(refreshed.items, turns: refreshed.turns)
        let refreshedRows = TranscriptDisplayRow.project(controller.transcript)
        XCTAssertEqual(refreshedRows.map(\.id), previousIDs)
        XCTAssertFalse(try XCTUnwrap(previousRows.first).hasSameItems(as: XCTUnwrap(refreshedRows.first)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    @MainActor func testRunningToolsStaySeparateUntilTheyFinishAndMergeInEventOrder() {
        let user = TranscriptItem(id: "user", kind: .user, text: "Question")
        let first = tool("first", state: .completed)
        let second = tool("second", state: .completed)
        let running = tool("running", state: .running)
        let parallel = tool("parallel", state: .running)
        let failed = tool("failed", state: .failed)
        let interrupted = tool("interrupted", state: .interrupted)
        let response = TranscriptItem(id: "response", kind: .assistant, text: "Answer")
        let next = tool("next", state: .completed)
        let items = [user, first, second, running, parallel, failed, interrupted, response, next]

        let before = TranscriptDisplayRow.project(items)
        XCTAssertEqual(before.map(\.id), ["user", "first", "running", "parallel", "failed", "response", "next"])
        guard before.count == 7,
              case .toolCalls(let head) = before[1], case .runningTool(let active) = before[2],
              case .runningTool(let otherActive) = before[3], case .toolCalls(let tail) = before[4] else {
            return XCTFail("Expected separate running tools between terminal groups")
        }
        XCTAssertEqual(head.map(\.id), ["first", "second"])
        XCTAssertTrue(active === running)
        XCTAssertTrue(otherActive === parallel)
        XCTAssertEqual(tail.map(\.id), ["failed", "interrupted"])

        parallel.tool?.state = .completed
        let during = TranscriptDisplayRow.project(items)
        XCTAssertEqual(during.map(\.id), ["user", "first", "running", "parallel", "response", "next"])
        guard during.count == 6, case .toolCalls(let partial) = during[3] else { return XCTFail("Expected a terminal group") }
        XCTAssertEqual(partial.map(\.id), ["parallel", "failed", "interrupted"])
        XCTAssertTrue(during[1].hasSameItems(as: before[1]))
        XCTAssertTrue(during[2].hasSameItems(as: before[2]))
        XCTAssertFalse(during[3].hasSameItems(as: before[3]))

        running.tool?.state = .completed
        let after = TranscriptDisplayRow.project(items)
        XCTAssertEqual(after.map(\.id), ["user", "first", "response", "next"])
        guard after.count == 4, case .toolCalls(let group) = after[1] else { return XCTFail("Expected a merged group") }
        XCTAssertEqual(group.map(\.id), ["first", "second", "running", "parallel", "failed", "interrupted"])
        XCTAssertTrue(after[1].contains("running"))
        XCTAssertEqual(ToolCallsSummary(items: group).statuses.map(\.state), [.failed, .interrupted])
        XCTAssertEqual(group[0].tool?.arguments, "arguments for first")
        XCTAssertEqual(group[0].tool?.output, "output from first")
    }

    @MainActor func testSingleToolExpansionSurvivesAppendingAndClosingItsGroup() {
        let first = tool("first", state: .running)
        let next = tool("next", state: .failed)
        let expansion = ToolCallExpansion()
        let single = expansion.detailBinding(for: first, isSingle: true)
        XCTAssertFalse(single.wrappedValue)
        single.wrappedValue = true

        let group = expansion.groupBinding(for: [first, next])
        let detail = expansion.detailBinding(for: first, isSingle: false)
        XCTAssertTrue(group.wrappedValue)
        XCTAssertTrue(detail.wrappedValue)
        XCTAssertFalse(expansion.detailBinding(for: next, isSingle: false).wrappedValue)
        group.wrappedValue = false
        XCTAssertFalse(single.wrappedValue)
        XCTAssertTrue(detail.wrappedValue)
        group.wrappedValue = true
        XCTAssertTrue(detail.wrappedValue)
    }

    @MainActor func testHistoryUsesUserEntryIDsForToolFirstAndEmptyRoundsWithEqualTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        {"type":"session","version":3,"id":"turn-anchors","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"same text","timestamp":1795000000000}}
        {"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"toolCall","id":"first","name":"read","arguments":{}}],"stopReason":"toolUse","timestamp":1795000001000}}
        {"type":"message","id":"r1","parentId":"a1","message":{"role":"toolResult","toolCallId":"first","toolName":"read","content":"failed","isError":true}}
        {"type":"message","id":"a2","parentId":"r1","message":{"role":"assistant","content":"first response","stopReason":"stop","timestamp":1795000002000}}
        {"type":"message","id":"u2","parentId":"a2","message":{"role":"user","content":"same text","timestamp":1795000000000}}
        {"type":"message","id":"a3","parentId":"u2","message":{"role":"assistant","content":[],"stopReason":"stop","timestamp":1795000003000}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let history = try await PiHistoryReader(roots: []).read(url)
        XCTAssertEqual(history.turns.map(\.firstUserItemID), ["history:u1", "history:u2"])
        let controller = SessionController()
        let first = RecordedTurnRecord(anchorAssistantTimestampMs: 1_795_000_001_000,
                                       endAssistantTimestampMs: 1_795_000_002_000,
                                       endedAt: Date(), durationSeconds: 5, status: .completed)
        controller.showHistory(history.items, turns: history.turns, recordedTurns: [first])
        let rows = TranscriptDisplayRow.project(controller.transcript)
        XCTAssertEqual(rows.map(\.id), [
            "history:u1", "turn-header:turn:a1", "history-tool:0:history:a1", "history:a2",
            "history:u2", "turn-header:turn:a3",
        ])
        guard case .turnHeader(let firstTurn) = rows[1], case .turnHeader(let secondTurn) = rows[5] else {
            return XCTFail("Expected two distinct headers")
        }
        XCTAssertEqual(firstTurn.durationSeconds, 5)
        XCTAssertNil(secondTurn.durationSeconds)
    }

    @MainActor func testLateQueuedAcknowledgementKeepsIdenticalFollowUpsInOrder() async throws {
        let first = UserPrompt(text: "repeat", mode: .followUp)
        let second = UserPrompt(text: "repeat", mode: .followUp)
        let runtime = TranscriptQueueRuntime(delayedPrompt: second.id)
        let controller = SessionController()
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        receive(.assistantCompleted(UUID(), "Initial reply"))
        await controller.sendDraft(first)
        receive(.queue(.init(followUp: ["repeat"])))

        let pending = Task { await controller.sendDraft(second) }
        await runtime.gate.waitForSend()
        receive(.queue(.init(followUp: ["repeat"])))
        XCTAssertEqual(controller.transcript.last?.delivery, .pending)
        receive(.queue(.init(followUp: ["repeat", "repeat"])))
        receive(.queue(.init(followUp: ["repeat"])))
        receive(.userMessageTimestamp(1_795_000_001_000, text: "repeat"))
        receive(.assistantCompleted(UUID(), "First follow-up reply"))
        let users = controller.transcript.filter { $0.kind == .user }
        XCTAssertEqual(users.map(\.delivery), [.accepted, .accepted, .queued])
        XCTAssertEqual(users[1].messageTimestampMs, 1_795_000_001_000)
        XCTAssertNil(users[2].messageTimestampMs)

        await runtime.gate.acknowledge()
        await pending.value
        receive(.queue(.init()))
        receive(.userMessageTimestamp(1_795_000_002_000, text: "repeat"))
        receive(.assistantCompleted(UUID(), "Second follow-up reply"))
        let turns: [TurnRecord] = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts).compactMap { row in
            if case .turnHeader(let turn) = row { return turn }
            return nil
        }
        XCTAssertEqual(turns.map(\.status), [.completed, .completed, .running])
        XCTAssertEqual(Set(turns.map(\.id)).count, 3)
        let replies = controller.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(replies.compactMap { $0.turn?.id }, turns.map(\.id))
        XCTAssertEqual(users[2].messageTimestampMs, 1_795_000_002_000)
        _ = await controller.disconnect()
    }

    @MainActor func testPiUserStartsKeepSteeringAndFollowUpHistoryAttachmentsWithTheirInputs() async throws {
        let steer = UserPrompt(text: "steer", files: [URL(fileURLWithPath: "/tmp/steer.txt")])
        let follow = UserPrompt(text: "follow", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/follow.txt")])
        let runtime = TranscriptQueueRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        var mapper = PiEventMapper()
        func userStart(_ text: String, _ timestamp: Int64) {
            let events = mapper.map(["type": "message_start", "message": [
                "role": "user", "timestamp": timestamp, "content": [["type": "text", "text": text]],
            ]])
            XCTAssertEqual(events.count, 1)
            events.forEach(receive)
        }
        let prompts = [steer.id: steer, follow.id: follow]
        var stored: [RecordedMessageRecord] = []
        controller.onUserMessageTimestamp = { id, timestamp in
            guard let id, let prompt = prompts[id] else { return }
            stored.append(.init(id: id, text: prompt.text, files: prompt.files, sentAt: nil, messageTimestampMs: timestamp))
        }
        await controller.sendDraft(.init(text: "initial"))
        userStart("initial", 1_795_000_000_000)
        receive(.assistantCompleted(UUID(), "Working"))
        await controller.sendDraft(steer)
        receive(.queue(.init(steering: [steer.runtimeText])))
        await controller.sendDraft(follow)
        receive(.queue(.init(steering: [steer.runtimeText], followUp: [follow.runtimeText])))
        userStart(follow.runtimeText, 1_795_000_000_999)
        XCTAssertTrue(stored.isEmpty, "A payload still in the queue cannot acquire a timestamp")

        let steeringTime: Int64 = 1_795_000_001_000
        let followUpTime: Int64 = 1_795_000_002_000
        receive(.queue(.init(followUp: [follow.runtimeText])))
        userStart("Unrelated user message", 1_795_000_001_001)
        userStart(steer.runtimeText, steeringTime)
        receive(.assistantCompleted(UUID(), "Steering reply"))
        receive(.queue(.init()))
        userStart(follow.runtimeText, followUpTime)
        receive(.assistantCompleted(UUID(), "Follow-up reply"))
        receive(.settled(aborted: false))
        XCTAssertEqual(stored.map(\.id), [steer.id, follow.id])
        XCTAssertEqual(stored.map(\.messageTimestampMs), [steeringTime, followUpTime])

        let history = SessionController()
        let items: [HistoryItem] = [
            .init(id: "history:steer", kind: .user, text: steer.runtimeText, messageTimestampMs: steeringTime),
            .init(id: "history:follow", kind: .user, text: follow.runtimeText, messageTimestampMs: followUpTime),
        ]
        history.showHistory(items, recordedMessages: stored)
        XCTAssertEqual(history.transcript.map(\.editableText), [steer.text, follow.text])
        XCTAssertEqual(history.transcript.map(\.editableFiles), [steer.files, follow.files])

        let incorrect = stored.map { record in
            var incorrectRecord = record
            incorrectRecord.messageTimestampMs = record.id == steer.id ? followUpTime : steeringTime
            return incorrectRecord
        }
        history.showHistory(items, recordedMessages: incorrect)
        XCTAssertEqual(history.transcript.map(\.editableText), [steer.runtimeText, follow.runtimeText])
        XCTAssertEqual(history.transcript.map(\.editableFiles), [[], []])
        _ = await controller.disconnect()
    }

    @MainActor func testQueuedAcknowledgementBeforeOlderDequeueKeepsFollowUpIdentity() async {
        for firstMode in [SendMode.followUp, .steer] {
            var userStarts: [Int64: UUID] = [:]
            let replay = await replayAcknowledgementBeforeOlderDequeue(firstMode: firstMode) { id, timestamp in
                userStarts[timestamp] = id
            }
            let controller = replay.controller
            let timestamp: Int64 = 1_795_000_002_000
            controller.receive(.init(instanceID: replay.instanceID, event: .queue(.init())))
            controller.receive(.init(instanceID: replay.instanceID, event: .userMessageTimestamp(timestamp, text: replay.second.runtimeText)))
            controller.receive(.init(instanceID: replay.instanceID, event: .assistantCompleted(UUID(), "Second reply")))
            XCTAssertEqual(replay.secondRow.messageTimestampMs, timestamp)
            XCTAssertEqual(userStarts, [1_795_000_001_000: replay.first.id, timestamp: replay.second.id])
            let turns = controller.transcriptTurnStarts.map(\.turn.id)
            XCTAssertEqual(turns.count, firstMode == .steer ? 2 : 3)
            let replies = controller.transcript.filter { $0.kind == .assistant }.compactMap { $0.turn?.id }
            XCTAssertEqual(replies, firstMode == .steer ? Array(turns.prefix(1)) + turns : turns)
            _ = await controller.disconnect()
        }
    }

    @MainActor func testStopRecoversExactFollowUpAfterAcknowledgementOvertakesOlderDequeue() async {
        let replay = await replayAcknowledgementBeforeOlderDequeue(firstMode: .followUp)
        let controller = replay.controller
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: replay.instanceID, event: event)) }
        receive(.phase(.stopping))
        receive(.queue(.init()))
        receive(.recoveredDrafts(UUID(), [.init(text: replay.second.runtimeText, mode: .followUp)]))
        receive(.settled(aborted: true))
        XCTAssertEqual(replay.secondRow.delivery, .recovered)
        XCTAssertEqual(controller.recoveredDrafts, [
            .init(id: replay.second.id, text: replay.second.text, mode: .followUp, files: replay.second.files),
        ])
        controller.restoreDraft(replay.second.id)
        XCTAssertEqual(controller.draft, replay.second.text)
        XCTAssertEqual(controller.draftFiles, replay.second.files)
        XCTAssertEqual(controller.mode, .followUp)
        _ = await controller.disconnect()
    }

    @MainActor private func replayAcknowledgementBeforeOlderDequeue(
        firstMode: SendMode, onUserStart: (@MainActor (UUID?, Int64) -> Void)? = nil
    ) async -> (controller: SessionController, instanceID: UUID, first: UserPrompt, second: UserPrompt, secondRow: TranscriptItem) {
        let second = UserPrompt(text: "repeat", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/repeat.txt")])
        let first = firstMode == .followUp
            ? UserPrompt(text: second.text, mode: firstMode, files: second.files)
            : UserPrompt(text: "steering", mode: firstMode, files: [URL(fileURLWithPath: "/tmp/steering.txt")])
        let runtime = TranscriptQueueRuntime(delayedPrompt: second.id)
        let controller = SessionController()
        controller.onUserMessageTimestamp = onUserStart
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        receive(.assistantCompleted(UUID(), "Initial reply"))
        await controller.sendDraft(first)
        let firstQueue = firstMode == .steer ? RuntimeQueue(steering: [first.runtimeText]) : RuntimeQueue(followUp: [first.runtimeText])
        receive(.queue(firstQueue))
        let pending = Task { await controller.sendDraft(second) }
        await runtime.gate.waitForSend()
        await runtime.gate.acknowledge()
        await pending.value

        let users = controller.transcript.filter { $0.kind == .user }
        receive(.queue(firstQueue))
        XCTAssertEqual(users.map(\.delivery), [.accepted, .queued, .queued])
        receive(.queue(.init()))
        let timestamp: Int64 = 1_795_000_001_000
        receive(.userMessageTimestamp(timestamp, text: first.runtimeText))
        XCTAssertEqual(users.map(\.delivery), [.accepted, .accepted, .queued])
        XCTAssertEqual(users[1].messageTimestampMs, timestamp)
        XCTAssertNil(users[2].messageTimestampMs)
        receive(.queue(.init(followUp: [second.runtimeText])))
        receive(.assistantCompleted(UUID(), "First reply"))
        return (controller, runtime.instanceID, first, second, users[2])
    }

    @MainActor func testRecoveredInputDoesNotReturnToQueueOnLateAcknowledgement() async {
        let prompt = UserPrompt(text: "keep", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/keep.txt")])
        let controller = SessionController()
        let runtime = TranscriptQueueRuntime(delayedPrompt: prompt.id)
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        let pending = Task { await controller.sendDraft(prompt) }
        await runtime.gate.waitForSend()
        receive(.phase(.stopping))
        receive(.queue(.init()))
        receive(.recoveredDrafts(UUID(), [.init(text: prompt.runtimeText, mode: .followUp)]))
        await runtime.gate.acknowledge()
        await pending.value
        receive(.settled(aborted: true))
        XCTAssertEqual(controller.transcript.last?.delivery, .recovered)
        XCTAssertEqual(controller.recoveredDrafts.first?.id, prompt.id)
        XCTAssertEqual(controller.recoveredDrafts.first?.files, prompt.files)
        XCTAssertEqual(controller.transcriptTurnStarts.count, 1)
        _ = await controller.disconnect()
    }

    @MainActor func testWorkspacePersistsEarlyTimestampOnlyForItsSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = UserPrompt(text: "initial")
        let follow = UserPrompt(text: "follow", mode: .followUp, files: [root.appendingPathComponent("follow.txt")])
        let runtime = TranscriptQueueRuntime(delayedPrompt: follow.id)
        let store = TranscriptWorkspaceStore()
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in runtime }
        await workspace.start()
        _ = await workspace.addProject(root)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        await workspace.send(sessionID, submitted: initial)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        receive(.assistantCompleted(UUID(), "Initial reply without a timestamp"))

        let pending = Task { await workspace.send(sessionID, submitted: follow) }
        await runtime.gate.waitForSend()
        receive(.queue(.init(followUp: [follow.runtimeText])))
        receive(.queue(.init()))
        let timestamp: Int64 = 1_795_000_003_000
        receive(.userMessageTimestamp(timestamp, text: follow.runtimeText))
        XCTAssertNil(workspace.selected?.recordedMessages?.first { $0.id == initial.id }?.messageTimestampMs)
        await runtime.gate.acknowledge()
        await pending.value
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)

        let snapshot = await store.load()
        let messages = try XCTUnwrap(snapshot.sessions.first { $0.id == sessionID }?.recordedMessages)
        XCTAssertNil(messages.first { $0.id == initial.id }?.messageTimestampMs)
        XCTAssertEqual(messages.first { $0.id == follow.id }?.messageTimestampMs, timestamp)
        XCTAssertEqual(messages.first { $0.id == follow.id }?.files, follow.files)
        _ = await controller.disconnect()
    }

    @MainActor func testStopInterleavedWithBufferedDequeuePreservesFirstAndRecoversSecond() async {
        for dequeueBeforeStop in [true, false] {
            let attachment = URL(fileURLWithPath: "/tmp/stop-interleave.txt")
            let first = UserPrompt(text: "repeat", mode: .followUp, files: [attachment])
            let second = UserPrompt(text: "repeat", mode: .followUp, files: [attachment])
            let firstTime: Int64 = 1_795_000_004_000
            let runtime = StopInterleaveRuntime()
            let controller = SessionController()
            var recordedStarts: [Int64: UUID] = [:]
            controller.onUserMessageTimestamp = { id, ts in
                if let id { recordedStarts[ts] = id }
            }
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) {
                controller.receive(.init(instanceID: runtime.instanceID, event: event))
            }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) {
                raw(["type": "queue_update", "steering": [String](), "followUp": followUp])
            }
            func previousDequeue() {
                queue([second.runtimeText])
                raw(["type": "message_start", "message": [
                    "role": "user", "timestamp": firstTime,
                    "content": [["type": "text", "text": first.runtimeText]],
                ]])
            }
            func row(_ prompt: UserPrompt) -> TranscriptItem? {
                controller.transcript.first { $0.id == "user:\(prompt.id)" }
            }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])
            await controller.sendDraft(second)
            queue([first.runtimeText, second.runtimeText])
            if dequeueBeforeStop { previousDequeue() }
            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            if !dequeueBeforeStop { previousDequeue() }
            queue([])
            receive(.recoveredDrafts(UUID(), [.init(text: second.runtimeText, mode: .followUp)]))
            raw(["type": "agent_settled", "aborted": true])
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(row(first)?.delivery, .accepted)
            XCTAssertEqual(row(first)?.messageTimestampMs, firstTime)
            XCTAssertEqual(recordedStarts, [firstTime: first.id])
            XCTAssertEqual(row(second)?.delivery, .recovered)
            XCTAssertEqual(controller.recoveredDrafts, [
                .init(id: second.id, text: second.text, mode: .followUp, files: second.files),
            ])

            await controller.sendDraft(.init(text: "fresh execution"))
            receive(.assistantCompleted(UUID(), "Fresh reply"))
            let freshTurn = controller.activeTurn?.id
            let third = UserPrompt(text: "next queued", mode: .followUp)
            await controller.sendDraft(third)
            queue([third.runtimeText])
            XCTAssertEqual(controller.activeTurn?.id, freshTurn)
            _ = await controller.disconnect(force: true)
        }
    }

    @MainActor func testStopRecoveryOrderAndSingleQueuedDequeueAndAbortFailure() async {
        // 1. recoveredDrafts arrives before buffered queue/user-start events drain.
        do {
            let file1 = URL(fileURLWithPath: "/tmp/first.txt")
            let file2 = URL(fileURLWithPath: "/tmp/second.txt")
            let first = UserPrompt(text: "same", mode: .followUp, files: [file1])
            let second = UserPrompt(text: "same", mode: .followUp, files: [file2])
            let firstTime: Int64 = 1_795_000_005_000
            let runtime = StopInterleaveRuntime()
            let controller = SessionController()
            var recordedStarts: [Int64: UUID] = [:]
            controller.onUserMessageTimestamp = { id, ts in
                if let id { recordedStarts[ts] = id }
            }
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) { raw(["type": "queue_update", "steering": [String](), "followUp": followUp]) }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])
            await controller.sendDraft(second)
            queue([first.runtimeText, second.runtimeText])

            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            receive(.recoveredDrafts(UUID(), [.init(text: second.runtimeText, mode: .followUp)]))
            queue([second.runtimeText])
            raw(["type": "message_start", "message": [
                "role": "user", "timestamp": firstTime,
                "content": [["type": "text", "text": first.runtimeText]],
            ]])
            queue([])
            raw(["type": "agent_settled", "aborted": true])
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.delivery, .accepted)
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.messageTimestampMs, firstTime)
            XCTAssertEqual(recordedStarts, [firstTime: first.id])
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(second.id)" }?.delivery, .recovered)
            XCTAssertEqual(controller.recoveredDrafts, [
                .init(id: second.id, text: second.text, mode: .followUp, files: second.files),
            ])
            _ = await controller.disconnect(force: true)
        }

        // 2. Single queued item dequeued right before stop (empty buffered queue_update) and abort failure.
        for stopFailure in [false, true] {
            let file = URL(fileURLWithPath: "/tmp/single.txt")
            let first = UserPrompt(text: "only", mode: .followUp, files: [file])
            let firstTime: Int64 = 1_795_000_006_000
            let runtime = StopInterleaveRuntime(stopFailure: stopFailure)
            let controller = SessionController()
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) { raw(["type": "queue_update", "steering": [String](), "followUp": followUp]) }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])

            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            queue([])
            raw(["type": "message_start", "message": [
                "role": "user", "timestamp": firstTime,
                "content": [["type": "text", "text": first.runtimeText]],
            ]])
            receive(.recoveredDrafts(UUID(), []))
            if !stopFailure { raw(["type": "agent_settled", "aborted": true]) }
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.delivery, .accepted)
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.messageTimestampMs, firstTime)
            XCTAssertTrue(controller.recoveredDrafts.isEmpty)
            XCTAssertEqual(controller.phase, stopFailure ? .uncertain : .idle)
            _ = await controller.disconnect(force: true)
        }
    }

    @MainActor private func tool(_ id: String, state: ToolState) -> TranscriptItem {
        .init(id: id, kind: .tool, tool: .init(id: id, name: "read", arguments: "arguments for \(id)", output: "output from \(id)", state: state))
    }
}

private actor TranscriptWorkspaceStore: WorkspaceStore {
    private var snapshot = WorkspaceSnapshot()

    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private actor TranscriptAcknowledgementGate {
    private var sender: CheckedContinuation<Void, Never>?
    private var acknowledgement: CheckedContinuation<PromptDisposition, Never>?

    func waitForSend() async {
        if acknowledgement != nil { return }
        await withCheckedContinuation { sender = $0 }
    }

    func suspendSend() async -> PromptDisposition {
        await withCheckedContinuation {
            acknowledgement = $0
            sender?.resume()
            sender = nil
        }
    }

    func acknowledge() {
        acknowledgement?.resume(returning: .queued)
        acknowledgement = nil
    }
}

private final class TranscriptQueueRuntime: AgentRuntime, Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let gate = TranscriptAcknowledgementGate()
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    private let delayedPrompt: UUID?

    init(delayedPrompt: UUID? = nil) {
        self.delayedPrompt = delayedPrompt
        let stream = AsyncStream<RuntimeEnvelope>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: "transcript-queue", model: "fixture", thinking: "none", capabilities: [.queuedPrompts])
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        if prompt.id == delayedPrompt { return await gate.suspendSend() }
        return prompt.text == "initial" ? .started : .queued
    }

    func stop() async throws {}
    func close(force: Bool) async throws { continuation.finish() }
}

private actor StopInterleaveGate {
    private var waitForEntry: CheckedContinuation<Void, Never>?
    private var waitForCompletion: CheckedContinuation<Void, Never>?

    func waitForStop() async {
        if waitForCompletion != nil { return }
        await withCheckedContinuation { waitForEntry = $0 }
    }

    func pauseStop() async {
        await withCheckedContinuation {
            waitForCompletion = $0
            waitForEntry?.resume()
            waitForEntry = nil
        }
    }

    func finishStop() {
        waitForCompletion?.resume()
        waitForCompletion = nil
    }
}

private final class StopInterleaveRuntime: AgentRuntime, Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let gate = StopInterleaveGate()
    private let stopFailure: Bool
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation

    init(stopFailure: Bool = false) {
        self.stopFailure = stopFailure
        let stream = AsyncStream<RuntimeEnvelope>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: "stop-interleave", model: "fixture", thinking: "none", capabilities: [.queuedPrompts])
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        prompt.mode == .followUp ? .queued : .started
    }

    func stop() async throws {
        await gate.pauseStop()
        if stopFailure { throw RuntimeFailure(.outcomeUnknown, "abort timed out") }
    }

    func close(force: Bool) async throws { continuation.finish() }
}
