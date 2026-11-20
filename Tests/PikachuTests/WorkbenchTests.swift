import XCTest
import Foundation
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import PiRuntimeAdapter

private final class BrokerRecorder: @unchecked Sendable {
    let lock = NSLock()
    var writes: [[String: Any]] = []
    var events: [AgentEvent] = []
    func write(_ value: [String: Any]) { lock.withLock { writes.append(value) } }
    func emit(_ value: AgentEvent) { lock.withLock { events.append(value) } }
}

final class WorkbenchTests: XCTestCase {
    func testEventBatchCannotRelabelForeignInstance() async {
        let channel = RuntimeEventChannel(), first = UUID(), second = UUID()
        channel.send(.init(instanceID:first,event:.notice("first")))
        channel.send(.init(instanceID:second,event:.notice("foreign"))); channel.finish()
        var instances: [UUID] = []
        for await event in channel.stream() { instances.append(event.instanceID) }
        XCTAssertEqual(instances,[first,second])
    }
    func testBrokerDoesNotRetainOversizedRequestIDs() throws {
        let recorder = BrokerRecorder(), broker = PiInteractionBroker(instanceID:UUID(),native:true,write:recorder.write,emit:recorder.emit)
        XCTAssertThrowsError(try broker.accept(["method":"input","id":String(repeating:"x",count:4097)]))
        XCTAssertTrue(recorder.events.isEmpty); XCTAssertTrue(recorder.writes.isEmpty)
    }
    func testOrdinaryRequestDeadlineExtendsOnlyForNewInteractions() throws {
        let recorder = BrokerRecorder(), broker = PiInteractionBroker(instanceID:UUID(),native:true,write:recorder.write,emit:recorder.emit)
        let start = broker.interactionRevision
        XCTAssertNil(broker.acknowledgementDeadline(since:start))
        try broker.accept(["method":"input","id":"dialog","timeout":10000])
        let deadline = try XCTUnwrap(broker.acknowledgementDeadline(since:start))
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow,10)
        guard case .interaction(let request) = recorder.events.first else { return XCTFail() }
        try broker.respond(request,.cancelled)
        XCTAssertLessThan(broker.acknowledgementDeadline(since:start)!.timeIntervalSinceNow,6)
        XCTAssertNil(broker.acknowledgementDeadline(since:broker.interactionRevision))
    }
    @MainActor func testWaitingInputCompactionAndForeignRequestIsolation() async {
        let runtime = FakeRuntime(), host = SessionController(); await host.connect(runtime)
        let request = RuntimeInteraction(instanceID:runtime.instanceID,requestID:"one",kind:.input,title:"Fixture")
        host.receive(.init(instanceID:runtime.instanceID,event:.phase(.running)))
        host.receive(.init(instanceID:UUID(),event:.interaction(request)))
        XCTAssertTrue(host.interactions.isEmpty)
        host.receive(.init(instanceID:runtime.instanceID,event:.interaction(request)))
        XCTAssertEqual(host.phase,.waitingInput); XCTAssertTrue(host.canStop)
        host.receive(.init(instanceID:runtime.instanceID,event:.phase(.compacting)))
        XCTAssertEqual(host.phase,.waitingInput)
        host.receive(.init(instanceID:runtime.instanceID,event:.interactionEnded(request.id,.cancelled)))
        XCTAssertEqual(host.phase,.compacting)
        host.receive(.init(instanceID:runtime.instanceID,event:.disconnected(cleanupConfirmed:true)))
        let replied = await host.reply(request,.value("late"))
        XCTAssertFalse(replied); XCTAssertTrue(host.interactions.isEmpty)
        _ = await host.disconnect(force:true)
    }
    @MainActor func testOnlyNewLocalToolApprovalsTriggerApprovalCallback() async {
        let runtime = FakeRuntime(), host = SessionController()
        await host.connect(runtime)
        var approvals: [String] = []
        host.onApprovalRequested = { approvals.append($0.id) }
        let confirmation = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "confirm", kind: .confirm, title: "Confirm?")
        let tool = RuntimeToolApproval(workingDirectory: "/fixture", operation: .command(text: "printf test", timeoutSeconds: 10))
        let approval = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "approval", kind: .confirm,
                                          title: "Run command?", toolApproval: tool)
        host.receive(.init(instanceID: runtime.instanceID, event: .interaction(confirmation)))
        host.receive(.init(instanceID: UUID(), event: .interaction(approval)))
        XCTAssertTrue(approvals.isEmpty)
        host.receive(.init(instanceID: runtime.instanceID, event: .interaction(approval)))
        host.receive(.init(instanceID: runtime.instanceID, event: .interaction(approval)))
        XCTAssertEqual(approvals, [approval.id])
        _ = await host.disconnect(force: true)
    }

    @MainActor func testExpiredRequestKeepsReadOnlyDetailsInTranscript() async throws {
        let runtime = FakeRuntime(), host = SessionController()
        await host.connect(runtime)
        let deadline = Date(timeIntervalSince1970: 100)
        let approval = RuntimeToolApproval(workingDirectory: "/fixture", operation: .command(text: "printf test", timeoutSeconds: 10))
        let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "approval", kind: .confirm,
                                         title: "Run command?", message: "Request details", prefill: "private draft",
                                         expiresAt: deadline, toolApproval: approval)
        host.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
        XCTAssertFalse(host.didExpire(request))
        host.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(request.id, .expired)))
        host.receive(.init(instanceID: runtime.instanceID, event: .interactionEnded(request.id, .expired)))
        XCTAssertTrue(host.interactions.isEmpty)
        XCTAssertTrue(host.didExpire(request))
        XCTAssertNotNil(host.notice)
        XCTAssertNil(host.noticeExcludingExpiredInteraction, "The composer shows an expiry pill instead of a duplicate banner")
        let records = host.transcript.compactMap(\.expiredInteraction)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.title, request.title)
        XCTAssertEqual(record.message, request.message)
        XCTAssertEqual(record.toolApproval, approval)
        XCTAssertEqual(record.expiresAt, deadline)
        XCTAssertTrue(record.prefill.isEmpty)
        let acceptedLateReply = await host.reply(request, .confirmed(true))
        XCTAssertFalse(acceptedLateReply)
        _ = await host.disconnect(force: true)
    }

    func testAllFourDialogRepliesAndDuplicateAreBoundToInstance() throws {
        let recorder = BrokerRecorder(), instance = UUID()
        let broker = PiInteractionBroker(instanceID: instance, native: true, write: recorder.write, emit: recorder.emit)
        for method in ["select", "confirm", "input", "editor"] {
            let raw: [String: Any] = ["method":method,"id":method,"title":"Fixture", "options":["A","B"],"prefill":"one\ntwo"]
            try broker.accept(raw); try broker.accept(raw)
        }
        let requests = recorder.events.compactMap { if case .interaction(let value) = $0 { value } else { nil } }
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            let response: InteractionResponse = request.kind == .confirm ? .confirmed(false) : .value(request.kind == .select ? "B" : "中文\nreply")
            try broker.respond(request, response)
            XCTAssertThrowsError(try broker.respond(request, response))
        }
        XCTAssertEqual(recorder.writes.count, 4)
        XCTAssertEqual(recorder.writes.first?["value"] as? String, "B")
        XCTAssertEqual(recorder.writes[1]["confirmed"] as? Bool, false)
    }
    func testDialogExpirationAndStopCannotReplyTwice() throws {
        let recorder = BrokerRecorder(), instance = UUID(), started = Date()
        let broker = PiInteractionBroker(instanceID: instance, native: true, write: recorder.write, emit: recorder.emit)
        try broker.accept(["method":"input", "id":"timeout", "title":"Fixture", "timeout":200], now:started)
        guard case .interaction(let request) = recorder.events[0] else { return XCTFail() }
        try broker.expire(now:started.addingTimeInterval(1)); broker.cancelAll()
        XCTAssertThrowsError(try broker.respond(request,.value("late"),now:started.addingTimeInterval(1)))
        XCTAssertEqual(recorder.writes.count,1); XCTAssertEqual(recorder.writes[0]["cancelled"] as? Bool,true)
    }
    func testInvalidSelectionKeepsRequestAndOldInstanceCannotReply() throws {
        let recorder = BrokerRecorder(), instance = UUID()
        let broker = PiInteractionBroker(instanceID: instance, native: true, write: recorder.write, emit: recorder.emit)
        try broker.accept(["method":"select", "id":"one", "title":"Fixture", "options":["A"]])
        guard case .interaction(let request) = recorder.events[0] else { return XCTFail() }
        XCTAssertThrowsError(try broker.respond(request,.value("B")))
        let old = RuntimeInteraction(instanceID:UUID(),requestID:"one",kind:.select,title:"Fixture",options:["A"])
        XCTAssertThrowsError(try broker.respond(old,.value("A")))
        try broker.respond(request,.value("A")); XCTAssertEqual(recorder.writes.count,1)
    }
    func testOversizedConfirmationIsCancelledRatherThanTruncated() throws {
        let recorder = BrokerRecorder(), broker = PiInteractionBroker(instanceID:UUID(),native:true,write:recorder.write,emit:recorder.emit)
        try broker.accept(["method":"confirm", "id":"huge", "title":"Fixture", "message":String(repeating:"x",count:70_000)])
        XCTAssertEqual(recorder.writes.first?["cancelled"] as? Bool,true)
        XCTAssertFalse(recorder.events.contains { if case .interaction = $0 { true } else { false } })
    }
    func testBundledCommandApprovalPreservesOriginalCommandAndScope() throws {
        let command = "  printf '%s\\n' \"a; b\"\r\n\t# e\u{301} 🐈\n"
        let directory = "/tmp/Project With \"Quotes\""
        let payload = try JSONSerialization.data(withJSONObject: [
            "tool": "bash",
            "workingDirectory": directory,
            "parameters": ["command": command, "timeout": 1.5]
        ])
        let message = "pikachu.tool-approval.v1\n" + String(decoding: payload, as: UTF8.self)
        let raw: [String: Any] = ["method": "confirm", "id": "shell", "message": message, "timeout": 120_000]

        for isBundledPolicy in [true, false] {
            let recorder = BrokerRecorder()
            let broker = PiInteractionBroker(instanceID: UUID(), native: true, toolApprovals: isBundledPolicy,
                                             write: recorder.write, emit: recorder.emit)
            try broker.accept(raw)
            guard case .interaction(let request) = try XCTUnwrap(recorder.events.first) else { return XCTFail() }
            if isBundledPolicy {
                let approval = try XCTUnwrap(request.toolApproval)
                guard case .command(let text, let timeout) = approval.operation else { return XCTFail() }
                XCTAssertEqual(Array(text.utf8), Array(command.utf8))
                XCTAssertEqual(approval.workingDirectory, directory)
                XCTAssertEqual(timeout, 1.5)
            } else {
                XCTAssertNil(request.toolApproval)
                XCTAssertEqual(request.message, message)
            }
            try broker.respond(request, .confirmed(false))
            XCTAssertEqual(recorder.writes.first?["confirmed"] as? Bool, false)
        }
    }
    func testBundledFileApprovalsDecodeContentAndOrderedReplacements() throws {
        let recorder = BrokerRecorder()
        let broker = PiInteractionBroker(instanceID: UUID(), native: true, toolApprovals: true,
                                         write: recorder.write, emit: recorder.emit)
        let path = "Sources/File \"A\".swift"
        let content = "import Foundation\r\n\tlet literal = \"\\n\"\n"
        let replacement = "e\u{301}\t🐈\n"
        let edits = [
            ["oldText": content, "newText": ""],
            ["oldText": "unchanged", "newText": replacement]
        ]
        let cases: [(String, [String: Any])] = [
            ("write", ["path": path, "content": content]),
            ("edit", ["path": path, "edits": edits])
        ]
        for (tool, parameters) in cases {
            let payload = try JSONSerialization.data(withJSONObject: [
                "tool": tool, "workingDirectory": "/tmp/Project", "parameters": parameters
            ])
            let message = "pikachu.tool-approval.v1\n" + String(decoding: payload, as: UTF8.self)
            try broker.accept(["method": "confirm", "id": tool, "message": message])
        }
        let approvals = recorder.events.compactMap { event -> RuntimeToolApproval? in
            guard case .interaction(let request) = event else { return nil }
            return request.toolApproval
        }
        XCTAssertEqual(approvals.count, 2)
        guard case .write(let writePath, let writeText) = try XCTUnwrap(approvals.first).operation,
              case .edit(let editPath, let replacements) = try XCTUnwrap(approvals.last).operation else { return XCTFail() }
        XCTAssertEqual(writePath, path)
        XCTAssertEqual(Array(writeText.utf8), Array(content.utf8))
        XCTAssertEqual(editPath, path)
        XCTAssertEqual(replacements.map(\.oldText), [content, "unchanged"])
        XCTAssertEqual(replacements.map { Array($0.newText.utf8) }, [[], Array(replacement.utf8)])
    }
    func testBundledSearchApprovalDecodesArguments() throws {
        let recorder = BrokerRecorder()
        let broker = PiInteractionBroker(instanceID: UUID(), native: true, toolApprovals: true,
                                         write: recorder.write, emit: recorder.emit)
        let payload = try JSONSerialization.data(withJSONObject: [
            "tool": "grep", "workingDirectory": "/tmp/Project",
            "parameters": ["path": "Sources", "pattern": "a\\nb", "limit": 40, "literal": true]
        ])
        let message = "pikachu.tool-approval.v1\n" + String(decoding: payload, as: UTF8.self)
        try broker.accept(["method": "confirm", "id": "search", "message": message])
        guard case .interaction(let request) = try XCTUnwrap(recorder.events.first),
              case .inspect(.grep, let arguments) = request.toolApproval?.operation else { return XCTFail() }
        XCTAssertEqual(arguments, [
            .init(name: "path", value: "Sources"),
            .init(name: "pattern", value: "a\\nb"),
            .init(name: "limit", value: "40"),
            .init(name: "literal", value: "true")
        ])
    }
    func testUsageUnknownPriceAndCompactedContextStayUnknown() throws {
        let stats: [String:Any] = ["sessionId":"s","tokens":["input":2,"output":3,"cacheRead":4,"cacheWrite":5,"total":14],"cost":0,"contextUsage":["tokens":NSNull(),"contextWindow":200_000,"percent":NSNull()]]
        let value = try PiUsageMapper.live(stats,model:["cost":["input":0,"output":0]],coverage:nil)
        XCTAssertEqual(value.tokens.total,14); XCTAssertNil(value.estimatedCostUSD)
        XCTAssertNil(value.context?.tokens); XCTAssertEqual(value.context?.window,200_000); XCTAssertNil(value.context?.percent)
    }
    func testHistoryUsageCountsAbandonedBranchesAndCompactionButRejectsMissingCosts() {
        var accumulator = UsageAccumulator()
        let usage: [String:Any] = ["input":10,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":12,"cost":["total":0.01]]
        accumulator.add(["type":"message","message":["role":"assistant","usage":usage]])
        accumulator.add(["type":"compaction","usage":usage]); accumulator.add(["type":"usage","usage":usage])
        let snapshot = accumulator.snapshot(id:"s")
        XCTAssertEqual(snapshot.tokens.total,36); XCTAssertEqual(snapshot.estimatedCostUSD!,0.03,accuracy:0.0001)
        accumulator.add(["type":"message","message":["role":"assistant","content":[]]])
        XCTAssertNil(accumulator.snapshot(id:"s").estimatedCostUSD); XCTAssertNil(accumulator.snapshot(id:"s").tokens.total)
    }
    func testUsageRejectsBooleansNegativeAndNonfiniteValues() {
        XCTAssertNil(PiUsageMapper.integer(true)); XCTAssertNil(PiUsageMapper.integer(-1)); XCTAssertNil(PiUsageMapper.number(Double.infinity))
        XCTAssertEqual(PiUsageMapper.integer(0),0)
    }
    func testBoundedEventChannelPreservesLifecycleAndFinalText() async {
        let channel = RuntimeEventChannel(capacity:4), instance = UUID(), message = UUID()
        let producer = Task.detached {
            channel.send(.init(instanceID:instance,event:.phase(.running)))
            channel.send(.init(instanceID:instance,event:.assistantStarted(message)))
            for _ in 0..<1_000 { channel.send(.init(instanceID:instance,event:.textDelta(message,0,"x"))) }
            channel.send(.init(instanceID:instance,event:.assistantCompleted(message,"canonical")))
            channel.send(.init(instanceID:instance,event:.settled(aborted:false))); channel.finish()
        }
        var events: [AgentEvent] = []
        for await envelope in channel.stream() {
            if case .batch(let batch) = envelope.event { events += batch } else { events.append(envelope.event) }
            XCTAssertLessThanOrEqual(channel.bufferedCount,4)
        }
        await producer.value
        let text = events.compactMap { if case .textDelta(_,_,let text) = $0 { text } else { nil } }.joined()
        XCTAssertEqual(text.count,1_000)
        if case .phase(.running) = events.first! {} else { XCTFail() }
        if case .settled(false) = events.last! {} else { XCTFail() }
        XCTAssertTrue(events.contains { if case .assistantCompleted(_,"canonical") = $0 { true } else { false } })
    }
}
