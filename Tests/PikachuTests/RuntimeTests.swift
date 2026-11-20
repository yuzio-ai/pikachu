import XCTest
import Foundation
import AgentRuntimeCore
import OrchestrationCore
@testable import PiRuntimeAdapter

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
    func testPiEnvironmentOverlayHonorsAliasesAndLaunchProxy() throws {
        let directory = URL(fileURLWithPath: "/fixture")
        var config = PiConfiguration(executable: directory, nodeDirectory: directory, workspace: directory,
                                     agentDirectory: directory, sessionDirectory: directory,
                                     proxy: "http://default.example:8080",
                                     environmentOverrides: ["https_proxy": "", "TEST_PI_VALUE": "a=b $literal"])
        let inherited = ["https_proxy": "http://old.example:8080", "PATH": "/bin", "UNRELATED": "inherited"]
        let normal = try config.launchEnvironment(inheriting: inherited)
        XCTAssertNil(normal["https_proxy"])
        XCTAssertEqual(normal["HTTPS_PROXY"], "")
        XCTAssertEqual(normal["HTTP_PROXY"], config.proxy)
        XCTAssertEqual(normal["NODE_USE_ENV_PROXY"], "1")
        XCTAssertEqual(normal["TEST_PI_VALUE"], "a=b $literal")
        XCTAssertEqual(normal["UNRELATED"], "inherited")
        XCTAssertEqual(normal["PATH"], "/fixture:/bin")
        XCTAssertEqual(normal["PI_CODING_AGENT_DIR"], "/fixture")

        config.launchProxyOverride = "http://override.example:8080"
        let explicit = try config.launchEnvironment(inheriting: inherited)
        XCTAssertEqual(explicit["HTTPS_PROXY"], config.launchProxyOverride)
        XCTAssertEqual(explicit["HTTP_PROXY"], config.launchProxyOverride)
        XCTAssertEqual(explicit["TEST_PI_VALUE"], normal["TEST_PI_VALUE"])

        config.launchProxyOverride = ""
        XCTAssertEqual(try config.launchEnvironment(inheriting: inherited)["https_proxy"], inherited["https_proxy"])
        XCTAssertNil(try config.launchEnvironment(inheriting: inherited)["HTTP_PROXY"])

        config.launchProxyOverride = nil
        config.environmentOverrides = [:]
        XCTAssertEqual(try config.launchEnvironment(inheriting: inherited)["HTTPS_PROXY"], config.proxy)
        for invalid in [["HTTP_PROXY": "a", "http_proxy": "b"], ["PATH": "/wrong"], ["A\n": "b"], ["VALID": "a\0b"]] {
            config.environmentOverrides = invalid
            XCTAssertThrowsError(try config.launchEnvironment(inheriting: inherited))
        }
        config.environmentOverrides = nil
        XCTAssertThrowsError(try config.launchEnvironment(inheriting: inherited))
    }

    func testPiToolSearchPathsAreMergedInOrderWithoutDuplicates() throws {
        let directory = URL(fileURLWithPath: "/fixture/node")
        var config = PiConfiguration(executable: directory, nodeDirectory: directory, workspace: directory,
                                     agentDirectory: directory, sessionDirectory: directory,
                                     toolSearchPaths: ["/opt/homebrew/bin", "/My Tools/bin", directory.path, "/opt/homebrew/bin"])
        let environment = try config.launchEnvironment(inheriting: ["PATH": "/usr/bin:/opt/homebrew/bin::/bin"])
        XCTAssertEqual(environment["PATH"], "/fixture/node:/opt/homebrew/bin:/My Tools/bin:/usr/bin:/bin")
        XCTAssertEqual(try config.launchEnvironment(inheriting: [:])["PATH"],
                       "/fixture/node:/opt/homebrew/bin:/My Tools/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        for invalid in ["", "relative/bin", "~/bin", "/opt/bin:/other/bin", "/bin\0bad"] {
            config.toolSearchPaths = [invalid]
            XCTAssertThrowsError(try config.launchEnvironment(inheriting: [:]))
        }
    }

    func testPiVersionProbeModelProbeAndRuntimeReceiveEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-env-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("node"),
                                                  withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let tools = root.appendingPathComponent("Extra Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        let tool = tools.appendingPathComponent("pikachu-fixture-tool")
        try FileManager.default.createSymbolicLink(at: tool, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let executable = root.appendingPathComponent("fake-pi")
        let receipt = root.appendingPathComponent("received")
        let fixture = """
        #!/usr/bin/python3
        import json
        import os
        import shutil
        import sys

        def record(kind):
            with open(os.environ["PIKACHU_TEST_RECEIPT"], "a") as output:
                print(kind + ":" + os.environ["PIKACHU_TEST_VALUE"] + ":" + str(shutil.which("pikachu-fixture-tool")), file=output)

        if "--version" in sys.argv:
            record("version")
            print(os.environ["PIKACHU_TEST_PI_VERSION"])
            sys.exit(0)

        record("models" if "--no-session" in sys.argv else "runtime")
        for line in sys.stdin:
            command = json.loads(line)
            data = {"sessionId": "fixture", "isStreaming": False, "pendingMessageCount": 0}
            print(json.dumps({"type": "response", "id": command["id"], "success": True, "data": data}), flush=True)
        """
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = PiConfiguration(executable: executable, nodeDirectory: root, workspace: root,
                                     agentDirectory: root, sessionDirectory: root.appendingPathComponent("sessions"),
                                     environmentOverrides: ["PIKACHU_TEST_RECEIPT": receipt.path, "PIKACHU_TEST_VALUE": "fixture value",
                                                            "PIKACHU_TEST_PI_VERSION": "1.6.0"],
                                     toolSearchPaths: [tools.path])
        _ = try await PiRuntime.inspectModels(config, model: nil)
        config.environmentOverrides?["PIKACHU_TEST_PI_VERSION"] = "1.5.3"
        let runtime = PiRuntime(configuration: config)
        do {
            let session = try await runtime.connect()
            XCTAssertEqual(session.id, "fixture")
            try await runtime.close(force: false)
        } catch {
            try? await runtime.close(force: true)
            throw error
        }
        let received = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(received.map(String.init), ["version", "models", "version", "runtime"].map { "\($0):fixture value:\(tool.path)" })
    }

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
    func testMapperIgnoresSystemAndUserMessages() {
        var mapper = PiEventMapper()
        for role in ["system","user","toolResult"] { XCTAssertTrue(mapper.map(["type":"message_start","message":["role":role]]).isEmpty) }
    }
    func testAssistantFailureIsOnlyShownWhenRunSettlesWithoutRecovery() async {
        enum Outcome: CaseIterable { case recovered, recoveredWithoutRetryEvent, exhausted, notRetried, cancelled }
        for outcome in Outcome.allCases {
            let runtime = ControlledRuntime(), store = SessionController()
            await store.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ record: [String: Any]) {
                for event in mapper.map(record) {
                    store.receive(.init(instanceID: runtime.instanceID, event: event))
                }
            }
            func endAssistant(stopReason: String, content: String = "", error: String = "") {
                receive(["type": "message_start", "message": ["role": "assistant"]])
                receive(["type": "message_end", "message": ["role": "assistant", "stopReason": stopReason,
                                                            "content": content, "errorMessage": error]])
            }

            receive(["type": "agent_start"])
            endAssistant(stopReason: "error", error: "terminated: other side closed (UND_ERR_SOCKET)")
            XCTAssertNil(store.failure, "\(outcome)")
            XCTAssertTrue(store.transcript.contains { $0.kind == .notice && $0.text.contains("UND_ERR_SOCKET") })
            if outcome == .recoveredWithoutRetryEvent {
                endAssistant(stopReason: "stop", content: "Recovered")
            } else if outcome != .notRetried {
                receive(["type": "auto_retry_start"])
                XCTAssertEqual(store.phase, .retrying)
                XCTAssertNil(store.failure)
                if outcome != .cancelled {
                    receive(["type": "agent_start"])
                    if outcome == .recovered { endAssistant(stopReason: "stop", content: "Recovered") }
                    else { endAssistant(stopReason: "error", error: "429 rate limit") }
                }
                receive(["type": "auto_retry_end", "success": outcome == .recovered])
                XCTAssertNil(store.failure)
            }
            receive(["type": "agent_settled", "aborted": outcome == .cancelled])

            let statuses = TranscriptDisplayRow.project(store.transcript, turnStarts: store.transcriptTurnStarts).compactMap { row in
                if case .turnHeader(let turn) = row { return turn.status }
                return nil as TurnStatus?
            }
            switch outcome {
            case .recovered, .recoveredWithoutRetryEvent:
                XCTAssertEqual(statuses, [.completed])
                XCTAssertNil(store.failure)
            case .exhausted, .notRetried:
                XCTAssertEqual(statuses, [.failed])
                XCTAssertEqual(store.failure?.kind, .model)
                if outcome == .exhausted { XCTAssertEqual(store.failure, PiEventMapper.failure("429 rate limit")) }
            case .cancelled:
                XCTAssertEqual(statuses, [.stopped])
                XCTAssertNil(store.failure)
            }
            _ = await store.disconnect()
        }
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

    func testMapperPartialToolResultReplacesPreviousSnapshot() {
        var mapper = PiEventMapper()
        _ = mapper.map(["type":"tool_execution_start","toolCallId":"id","toolName":"bash","args":["command":"echo hi"]])
        _ = mapper.map(["type":"tool_execution_update","toolCallId":"id","partialResult":["content":[["type":"text","text":"a"]]]])
        let events = mapper.map(["type":"tool_execution_update","toolCallId":"id","partialResult":["content":[["type":"text","text":"ab"]]]])
        if case .tool(let tool) = events[0] { XCTAssertEqual(tool.output,"ab") } else { XCTFail() }
    }
    func testCompletedReadKeepsImageAlongsideTextOutput() throws {
        var mapper = PiEventMapper()
        let bytes = Data([1, 2, 3])
        let text = "Read image file [image/png]"
        let content = [["type": "text", "text": text],
                       ["type": "image", "mimeType": "image/png", "data": bytes.base64EncodedString()]]
        let events = mapper.map(["type": "tool_execution_end", "toolCallId": "read-image", "toolName": "pikachu_read",
                                 "result": ["content": content]])
        guard case .tool(let tool) = try XCTUnwrap(events.first) else { return XCTFail("Missing tool event") }
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(tool.output, text)
        XCTAssertEqual(tool.outputImage, bytes)
        XCTAssertNil(PiEventMapper.readOutputImage(content, name: "read", failed: true))
        XCTAssertNil(PiEventMapper.readOutputImage(content, name: "bash", failed: false))
        XCTAssertNil(PiEventMapper.readOutputImage(text, name: "read", failed: false))
    }

    func testLargeToolOutputHasBoundedPresentationAndNotice() {
        var mapper = PiEventMapper()
        let output = String(repeating: "x", count: 10 * 1_024 * 1_024)
        let events = mapper.map(["type":"tool_execution_end", "toolCallId":"large", "toolName":"bash", "result":["content":[["type":"text", "text":output]]]])
        if case .tool(let tool) = events[0] {
            XCTAssertEqual(tool.output.count, 65_536); XCTAssertTrue(tool.truncated)
        } else { XCTFail("Missing tool event") }
    }

    func testToolOutputKeepsPiTruncationMetadataAndTerminalErrorMarker() throws {
        var mapper = PiEventMapper()
        let short = "retained lines"
        let tail = short + "\n\n[Showing lines 1001-3000 of 3000. Full output: /tmp/pi-fixture.log]\n\nCommand timed out after 2 seconds"
        let filtered = mapper.map(["type": "tool_execution_end", "toolCallId": "metadata", "toolName": "bash",
                                   "result": ["content": short, "details": ["truncation": ["truncated": true]]]])
        guard case .tool(let truncated) = try XCTUnwrap(filtered.first) else { return XCTFail("Missing tool event") }
        XCTAssertTrue(truncated.truncated)
        XCTAssertEqual(truncated.output, short)

        let failed = mapper.map(["type": "tool_execution_end", "toolCallId": "timeout", "toolName": "pikachu_bash",
                                 "isError": true, "result": ["content": tail]])
        guard case .tool(let timedOut) = try XCTUnwrap(failed.first) else { return XCTFail("Missing tool event") }
        XCTAssertTrue(timedOut.truncated)
        XCTAssertEqual(timedOut.output, tail)
        XCTAssertFalse(PiEventMapper.toolOutput(tail, details: nil, name: "bash", failed: false).truncated)
        XCTAssertFalse(PiEventMapper.toolOutput(tail, details: nil, name: "read", failed: true).truncated)
    }
    func testProviderErrorsDoNotExposeCredentials() {
        let error = PiEventMapper.failure("401 Authorization Bearer sk-test-secret-key")
        XCTAssertEqual(error.kind,.authentication); XCTAssertFalse(error.detail.contains("secret"))
    }

    func testPiRuntimePassesApproveFlagByModeAndSkipsInModelProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-approve-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("node"),
                                                  withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let executable = root.appendingPathComponent("fake-pi")
        let receipt = root.appendingPathComponent("argv.jsonl")
        let fixture = """
        #!/usr/bin/python3
        import json
        import os
        import sys

        if "--version" in sys.argv:
            print("1.5.2")
            sys.exit(0)

        with open(os.environ["PIKACHU_ARGV_RECEIPT"], "a") as output:
            output.write(json.dumps(sys.argv[1:]) + "\\n")

        for line in sys.stdin:
            command = json.loads(line)
            kind = command.get("type")
            if kind == "get_commands":
                data = {"commands": [{"name": "pikachu-verify-policy", "source": "extension"}]}
            elif kind == "prompt":
                mode = os.environ.get("PIKACHU_EXECUTION_MODE", "")
                approval = os.environ.get("PIKACHU_TOOL_APPROVAL", "")
                nonce = command.get("message", "").split(" ", 1)[1]
                print(json.dumps({
                    "type": "extension_ui_request",
                    "id": "status",
                    "method": "setStatus",
                    "statusKey": "pikachu-policy",
                    "statusText": f"{mode}:{approval}:{nonce}"
                }), flush=True)
                data = {"disposition": "handled"}
            else:
                data = {"sessionId": "fixture", "isStreaming": False, "pendingMessageCount": 0}
            print(json.dumps({"type": "response", "id": command["id"], "success": True, "data": data}), flush=True)
        """
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let baseConfig = PiConfiguration(
            executable: executable,
            nodeDirectory: root,
            workspace: root,
            agentDirectory: root,
            sessionDirectory: root.appendingPathComponent("sessions"),
            environmentOverrides: ["PIKACHU_ARGV_RECEIPT": receipt.path],
            approveProjectConfiguration: true
        )
        _ = try await PiRuntime.inspectModels(baseConfig, model: nil)

        for mode in [AgentMode.plan, .interactive, .automatic] {
            for approve in [false, true] {
                var config = baseConfig
                config.agentMode = mode
                config.approveProjectConfiguration = approve
                let runtime = PiRuntime(configuration: config)
                do {
                    _ = try await runtime.connect()
                    try await runtime.close(force: false)
                } catch {
                    try? await runtime.close(force: true)
                    throw error
                }
            }
        }

        let lines = try String(contentsOf: receipt, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
        XCTAssertEqual(lines.count, 7)

        let probeArgs = lines[0]
        XCTAssertTrue(probeArgs.contains("--no-session"))
        XCTAssertFalse(probeArgs.contains("--approve"))
        XCTAssertFalse(probeArgs.contains("--no-approve"))

        for (index, pair) in [(1, false), (2, true), (3, false), (4, true), (5, false), (6, true)] {
            let args = lines[index]
            XCTAssertTrue(args.contains("--no-extensions"))
            XCTAssertTrue(args.contains("--no-skills"))
            XCTAssertTrue(args.contains("--no-prompt-templates"))
            XCTAssertTrue(args.contains("--no-themes"))
            XCTAssertTrue(args.contains("--session-dir"))
            XCTAssertEqual(args.contains("--approve"), pair)
            XCTAssertEqual(args.contains("--no-approve"), !pair)
        }
    }
}
