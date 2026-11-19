import XCTest
import Foundation
import AgentRuntimeCore
import OrchestrationCore
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
