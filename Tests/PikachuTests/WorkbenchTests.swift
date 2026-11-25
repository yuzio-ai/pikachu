import XCTest
import Foundation
import AgentRuntimeCore
@testable import OrchestrationCore

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

    @MainActor func testCachedHistoryNoticeIsExcludedFromBannerWhenShowingCachedHistory() {
        let host = SessionController()
        let cached = [CachedTranscriptItem(id: "u1", kind: .user, text: "Hello")]
        host.showCachedHistory(cached, notice: "当前处于离线状态，展示缓存内容。")
        XCTAssertTrue(host.showingCachedHistory)
        XCTAssertEqual(host.notice, "当前处于离线状态，展示缓存内容。")
        XCTAssertNil(host.noticeExcludingComposerPills, "The composer shows a cached-history pill instead of a duplicate banner")

        host.showHistory([HistoryItem(id: "u1", kind: .user, text: "Hello", messageTimestampMs: 1_000)])
        XCTAssertFalse(host.showingCachedHistory)
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
