import XCTest
import Foundation
import AgentRuntimeCore
import OrchestrationCore
@testable import Zivvi

private final class ControlledRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let sink: AsyncStream<RuntimeEnvelope>.Continuation
    let disposition: PromptDisposition
    let closeFailure: Bool
    let stopFailure: Bool
    init(_ disposition: PromptDisposition = .started, closeFailure: Bool = false, stopFailure: Bool = false) {
        self.disposition = disposition; self.closeFailure = closeFailure; self.stopFailure = stopFailure
        let pair = AsyncStream<RuntimeEnvelope>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func connect() async throws -> RuntimeSession { .init(id: "test", model: "test", thinking: "low", capabilities: [.streaming, .tools, .interruption, .queuedPrompts]) }
    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { disposition }
    func stop() async throws {
        emit(.recoveredDrafts(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, [.init(text: "已清出", mode: .followUp)]))
        if stopFailure { throw RuntimeFailure(.outcomeUnknown, "abort timed out") }
        emit(.settled(aborted: true))
    }
    func close(force: Bool) async throws {
        if closeFailure { throw RuntimeFailure(.supervision, "unknown cleanup") }
        emit(.disconnected(cleanupConfirmed: true)); sink.finish()
    }
    func emit(_ event: AgentEvent) { sink.yield(.init(instanceID: instanceID, event: event)) }
}

@MainActor final class RuntimeTests: XCTestCase {





    private func drain() async { try? await Task.sleep(for: .milliseconds(30)) }
    func testHandledPromptDoesNotBecomeRunning() async {
        let store = SessionController(), runtime = ControlledRuntime(.handled)
        await store.connect(runtime); store.draft = "/handled"; await store.sendDraft()
        XCTAssertEqual(store.phase, .idle); XCTAssertEqual(store.transcript.first?.delivery, .handled)
        _ = await store.disconnect()
    }
    func testUnexpectedStreamEndBlocksExecution() async {
        let store = SessionController(), runtime = ControlledRuntime()
        await store.connect(runtime); runtime.sink.finish(); await drain()
        XCTAssertEqual(store.connection, .blocked); XCTAssertFalse(store.canConnect)
        _ = await store.disconnect(force: true)
    }
    func testReconnectAfterCleanedCrashIgnoresOldCloseEvents() async {
        let store = SessionController(), old = ControlledRuntime()
        await store.connect(old)
        store.receive(.init(instanceID: old.instanceID, event: .disconnected(cleanupConfirmed: true)))
        let replacement = ControlledRuntime()
        await store.connect(replacement)
        XCTAssertEqual(store.connection, .connected)
        _ = await store.disconnect()
    }
    func testOldInstanceCannotMutateCurrentConversation() async {
        let store = SessionController(), runtime = ControlledRuntime()
        await store.connect(runtime)
        store.receive(.init(instanceID: UUID(), event: .assistantCompleted(UUID(), "stale")))
        XCTAssertTrue(store.transcript.isEmpty)
        _ = await store.disconnect()
    }
    func testFinalMessageOverridesDeltasAndBlocksArePerMessage() async {
        let store = SessionController(), runtime = ControlledRuntime()
        await store.connect(runtime)
        let a = UUID(), b = UUID()
        for id in [a,b] {
            store.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(id)))
            store.receive(.init(instanceID: runtime.instanceID, event: .textDelta(id, 0, "wrong")))
            store.receive(.init(instanceID: runtime.instanceID, event: .textDelta(id, 1, "block")))
            store.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(id, id == a ? "first" : "second")))
        }
        XCTAssertEqual(store.transcript.map(\.text), ["first","second"])
        _ = await store.disconnect()
    }
    func testClearQueueResultSurvivesAbortFailureAndKeepsEditor() async {
        let store = SessionController(), runtime = ControlledRuntime(stopFailure: true)
        await store.connect(runtime); store.draft = "run"; await store.sendDraft()
        store.draft = "仍在编辑"; await store.stop(); await drain()
        XCTAssertEqual(store.draft, "仍在编辑"); XCTAssertEqual(store.recoveredDrafts.map(\.text), ["已清出"])
        XCTAssertEqual(store.phase, .uncertain)
        let id = store.recoveredDrafts[0].id; store.restoreDraft(id)
        XCTAssertEqual(store.draft, "仍在编辑\n\n已清出")
        _ = await store.disconnect(force: true)
    }
    func testRepeatedRecoveryEventIsDeduplicated() async {
        let store = SessionController(), runtime = ControlledRuntime()
        await store.connect(runtime)
        let operation = UUID(), drafts = [PendingPrompt(text: "a", mode: .steer)]
        for _ in 0..<2 { store.receive(.init(instanceID: runtime.instanceID, event: .recoveredDrafts(operation,drafts))) }
        XCTAssertEqual(store.recoveredDrafts.count, 1)
        _ = await store.disconnect()
    }
    func testClearedDuplicateQueueRowsAreReturnedToDrafts() async {
        let store = SessionController(), runtime = ControlledRuntime(.queued)
        await store.connect(runtime)
        for _ in 0..<2 {
            store.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(steering: [], followUp: ["same", "same"]))))
            store.draft = "same"; await store.sendDraft()
        }
        store.receive(.init(instanceID: runtime.instanceID, event: .phase(.stopping)))
        store.receive(.init(instanceID: runtime.instanceID, event: .queue(.init())))
        XCTAssertTrue(store.transcript.allSatisfy { $0.delivery == .queued })
        let operation = UUID(), drafts = (0..<2).map { _ in PendingPrompt(text: "same", mode: .followUp) }
        for _ in 0..<2 { store.receive(.init(instanceID: runtime.instanceID, event: .recoveredDrafts(operation, drafts))) }
        XCTAssertEqual(store.transcript.map(\.delivery), [.recovered, .recovered])
        XCTAssertEqual(store.recoveredDrafts.count, 2)
        _ = await store.disconnect(force: true)
    }
    func testQueueRecoveryRestoresStructuredFileReferences() async {
        let controller = SessionController(), runtime = ControlledRuntime(.queued)
        let file = URL(fileURLWithPath: "/tmp/example file.txt")
        await controller.connect(runtime)
        controller.draft = "Read this"
        controller.draftFiles = [file]
        let prompt = controller.draftPrompt
        await controller.sendDraft(prompt)
        XCTAssertEqual(controller.transcript.last?.delivery, .queued)
        XCTAssertTrue(controller.draftFiles.isEmpty)
        controller.draft = "New draft"
        controller.receive(.init(instanceID: runtime.instanceID,
                                 event: .recoveredDrafts(UUID(), [.init(text: prompt.runtimeText, mode: .steer)])))
        XCTAssertEqual(controller.recoveredDrafts.first?.files, [file])
        controller.restoreDraft(prompt.id)
        XCTAssertEqual(controller.draft, "New draft\n\nRead this")
        XCTAssertEqual(controller.draftFiles, [file])
        _ = await controller.disconnect(force: true)
    }
    func testQueuedAcknowledgementDoesNotUseOlderEmptySnapshot() async {
        let store = SessionController(), runtime = ControlledRuntime(.queued)
        await store.connect(runtime)
        store.receive(.init(instanceID: runtime.instanceID, event: .queue(.init())))
        store.draft = "late snapshot"; await store.sendDraft()
        XCTAssertEqual(store.transcript.first?.delivery, .queued)
        store.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(steering: ["late snapshot"], followUp: []))))
        XCTAssertEqual(store.transcript.first?.delivery, .queued)
        store.receive(.init(instanceID: runtime.instanceID, event: .queue(.init())))
        XCTAssertEqual(store.transcript.first?.delivery, .accepted)
        _ = await store.disconnect(force: true)
    }
    func testUnknownCleanupBlocksNewConnectionAndSending() async {
        let store = SessionController(), runtime = ControlledRuntime(closeFailure: true)
        await store.connect(runtime)
        let closed = await store.disconnect(force: true)
        XCTAssertFalse(closed); XCTAssertEqual(store.connection, .blocked)
        store.draft = "must not send"; XCTAssertFalse(store.canSend); XCTAssertFalse(store.canConnect)
    }
    func testSettledInterruptsUnfinishedToolsWithoutClaimingSuccess() async {
        let store = SessionController(), runtime = ControlledRuntime()
        await store.connect(runtime)
        store.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "a", name: "bash"))))
        store.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        XCTAssertEqual(store.transcript.first?.tool?.state, .interrupted)
        _ = await store.disconnect()
    }
    func testFakeRuntimeUsesSameControllerAndRetainsStoppedQueue() async {
        let store = SessionController(), runtime = FakeRuntime()
        await store.connect(runtime)
        store.draft = "initial"; await store.sendDraft()
        store.draft = "follow"; store.mode = .followUp; await store.sendDraft(); await drain()
        XCTAssertEqual(store.queue.followUp, ["follow"])
        await store.stop(); await drain()
        XCTAssertEqual(store.recoveredDrafts.map(\.text), ["follow"])
        _ = await store.disconnect()
    }
    func testMarkdownKeepsCodeAndUnicode() {
        let blocks = MarkdownBlocks.parse("# 标题\n\n**正文** 😺\n\n```swift\nlet x = 1\n```\n")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.last?.text, "let x = 1")
        if case .code(let language) = blocks.last!.kind { XCTAssertEqual(language, "swift") } else { XCTFail("Missing code block") }
    }


    func testConfirmedModelFailureOffersOriginalInputForRetry() async {
        let runtime = ControlledRuntime(), store = SessionController()
        await store.connect(runtime)
        let input = UserPrompt(text: "Original task", mode: .steer)
        await store.sendDraft(input)
        func receive(_ event: AgentEvent) { store.receive(.init(instanceID: runtime.instanceID, event: event)) }
        receive(.failure(.init(.model, "Rate limited")))
        XCTAssertNil(store.retryableModelPrompt)
        receive(.settled(aborted: false))
        XCTAssertEqual(store.retryableModelPrompt?.id, input.id)
        XCTAssertEqual(store.retryableModelPrompt?.text, input.text)
        receive(.phase(.running))
        XCTAssertNil(store.retryableModelPrompt)
        _ = await store.disconnect()
    }





}
