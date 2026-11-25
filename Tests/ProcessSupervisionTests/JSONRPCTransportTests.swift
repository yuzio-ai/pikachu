import XCTest
import Foundation
@testable import ProcessSupervision

final class JSONRPCTransportTests: XCTestCase {
    private struct SamplePayload: Codable, Equatable, Sendable {
        let stopReason: String
        let count: Int
    }

    func testJSONRPCIDPreservesTypeAndRejectsBooleansAndFloats() throws {
        XCTAssertEqual(JSONRPCID(jsonValue: 42), .int(42))
        XCTAssertEqual(JSONRPCID(jsonValue: "42"), .string("42"))
        XCTAssertNotEqual(JSONRPCID.int(42), JSONRPCID.string("42"))

        XCTAssertNil(JSONRPCID(jsonValue: true))
        XCTAssertNil(JSONRPCID(jsonValue: false))
        XCTAssertNil(JSONRPCID(jsonValue: NSNumber(value: true)))
        XCTAssertNil(JSONRPCID(jsonValue: NSNumber(value: 3.14)))
        XCTAssertNil(JSONRPCID(jsonValue: NSNull()))
        XCTAssertNil(JSONRPCID(jsonValue: nil))
        XCTAssertNil(JSONRPCID(jsonValue: ["nested": 1]))

        // Verify JSONSerialization boolean vs integer distinction on Darwin.
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{\"boolId\":true,\"intId\":1,\"strId\":\"1\",\"floatId\":1.5}".utf8)) as? Record
        )
        XCTAssertNil(JSONRPCID(jsonValue: parsed["boolId"]))
        XCTAssertEqual(JSONRPCID(jsonValue: parsed["intId"]), .int(1))
        XCTAssertEqual(JSONRPCID(jsonValue: parsed["strId"]), .string("1"))
        XCTAssertNil(JSONRPCID(jsonValue: parsed["floatId"]))

        // Verify Codable round-trip preserves exact JSON type.
        let encodedInt = try JSONEncoder().encode(JSONRPCID.int(7))
        let encodedStr = try JSONEncoder().encode(JSONRPCID.string("7"))
        XCTAssertEqual(String(decoding: encodedInt, as: UTF8.self), "7")
        XCTAssertEqual(String(decoding: encodedStr, as: UTF8.self), "\"7\"")
        XCTAssertEqual(try JSONDecoder().decode(JSONRPCID.self, from: encodedInt), .int(7))
        XCTAssertEqual(try JSONDecoder().decode(JSONRPCID.self, from: encodedStr), .string("7"))
    }

    func testClassifyAllThreeInboundShapesAndRejectsMalformedFrames() throws {
        // 1. Success response (int ID)
        let successRecord: Record = [
            "jsonrpc": "2.0",
            "id": 10,
            "result": ["stopReason": "end_turn", "count": 3]
        ]
        if case .response(let response) = try JSONRPCProcess.classify(successRecord) {
            XCTAssertEqual(response.id, .int(10))
            XCTAssertFalse(response.isError)
            let decoded = try response.decodeResult(SamplePayload.self)
            XCTAssertEqual(decoded, SamplePayload(stopReason: "end_turn", count: 3))
        } else {
            XCTFail("Expected response frame")
        }

        // 2. Error response (string ID)
        let errorRecord: Record = [
            "jsonrpc": "2.0",
            "id": "req-auth",
            "error": ["code": -32000, "message": "Authentication required", "data": ["hint": "agy acp --login"]]
        ]
        if case .response(let response) = try JSONRPCProcess.classify(errorRecord) {
            XCTAssertEqual(response.id, .string("req-auth"))
            XCTAssertTrue(response.isError)
            XCTAssertEqual(response.error?.code, -32000)
            XCTAssertEqual(response.error?.message, "Authentication required")
            let dataDict = response.error?.dataObject as? Record
            XCTAssertEqual(dataDict?["hint"] as? String, "agy acp --login")
        } else {
            XCTFail("Expected error response frame")
        }

        // 3. Agent -> Client Request (string ID & int ID)
        let requestRecord: Record = [
            "jsonrpc": "2.0",
            "id": "perm-1",
            "method": "session/request_permission",
            "params": ["sessionId": "s1"]
        ]
        if case .request(let request) = try JSONRPCProcess.classify(requestRecord) {
            XCTAssertEqual(request.id, .string("perm-1"))
            XCTAssertEqual(request.method, "session/request_permission")
            XCTAssertEqual(request.params["sessionId"] as? String, "s1")
        } else {
            XCTFail("Expected inbound request frame")
        }

        // 4. Notification (no ID)
        let notificationRecord: Record = [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": ["sessionId": "s1", "update": ["sessionUpdate": "agent_message_chunk"]]
        ]
        if case .notification(let notification) = try JSONRPCProcess.classify(notificationRecord) {
            XCTAssertEqual(notification.method, "session/update")
            XCTAssertEqual(notification.params["sessionId"] as? String, "s1")
        } else {
            XCTFail("Expected notification frame")
        }

        // 5. Malformed frames
        let malformed: [Record] = [
            ["jsonrpc": "1.0", "id": 1, "result": [:]],
            ["jsonrpc": "2.0", "id": 1],
            ["jsonrpc": "2.0", "method": ""],
            ["jsonrpc": "2.0", "id": NSNumber(value: true), "method": "session/request_permission"],
            ["jsonrpc": "2.0", "id": NSNull(), "method": "session/request_permission"],
            ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
        ]
        for frame in malformed {
            XCTAssertThrowsError(try JSONRPCProcess.classify(frame))
        }
    }

    func testConcurrentLongPromptInterleavedWithControlRequestsPermissionsAndNotifications() async throws {
        let script = """
        import json, sys

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        prompt_req = json.loads(sys.stdin.readline())
        assert prompt_req["jsonrpc"] == "2.0" and prompt_req["method"] == "session/prompt"
        prompt_id = prompt_req["id"]

        # Emit streaming notification while prompt is in flight.
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"seq": 1, "text": "hello"}})

        # Agent->Client request with STRING id.
        send({"jsonrpc": "2.0", "id": "perm-str-1", "method": "session/request_permission", "params": {"tool": "bash"}})

        # Agent->Client request with INT id.
        send({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission", "params": {"tool": "edit"}})

        # Read control request, string-id permission reply, and int-id permission error reply in any order.
        got_control = False
        got_str_reply = False
        got_int_error = False
        while not (got_control and got_str_reply and got_int_error):
            msg = json.loads(sys.stdin.readline())
            if msg.get("method") == "session/set_mode":
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"applied": msg["params"]["modeId"]}})
                got_control = True
            elif "result" in msg and msg.get("id") == "perm-str-1":
                assert isinstance(msg["id"], str), f"expected str id, got {type(msg['id'])}"
                got_str_reply = (msg["result"]["outcome"]["optionId"] == "allow_once")
            elif "error" in msg and msg.get("id") == 99:
                assert isinstance(msg["id"], int) and not isinstance(msg["id"], bool)
                got_int_error = (msg["error"]["code"] == -32001)

        # Emit final notification and complete the long-running prompt request.
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"seq": 2, "text": "world"}})
        send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn", "count": 2}})
        sys.stdin.read()
        """

        let transport = try JSONRPCProcess(
            executable: "/usr/bin/python3",
            arguments: ["-u", "-c", script],
            cwd: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        defer { try? transport.close() }

        // Start long-running prompt request without blocking.
        let promptID = try transport.sendRequest(method: "session/prompt", params: ["text": "run"])
        let promptTask = Task { try await transport.awaitResponse(id: promptID, timeout: 10) }

        // Issue concurrent short control request while prompt is still running.
        let controlID = try transport.sendRequest(method: "session/set_mode", params: ["modeId": "plan"])
        let controlResponse = try await transport.awaitResponse(id: controlID, timeout: 10)
        XCTAssertEqual(controlResponse.id, controlID)
        XCTAssertEqual(controlResponse.resultRecord?["applied"] as? String, "plan")

        // Consume inbound notifications and Agent->Client requests via inboundStream.
        var notificationSeqs: [Int] = []
        var handledRequests: [JSONRPCID] = []
        let deadline = Date().addingTimeInterval(10)

        for await inbound in transport.inboundStream() {
            switch inbound {
            case .notification(let note):
                XCTAssertEqual(note.method, "session/update")
                if let seq = note.params["seq"] as? Int {
                    notificationSeqs.append(seq)
                }
            case .request(let request):
                XCTAssertEqual(request.method, "session/request_permission")
                handledRequests.append(request.id)
                switch request.id {
                case .string("perm-str-1"):
                    try transport.sendResponse(
                        id: request.id,
                        result: ["outcome": ["outcome": "selected", "optionId": "allow_once"]]
                    )
                case .int(99):
                    try transport.sendErrorResponse(id: request.id, code: -32001, message: "Denied", data: ["reason": "test"])
                default:
                    XCTFail("Unexpected inbound request ID: \(request.id)")
                }
            }
            if notificationSeqs.count == 2 || Date() >= deadline {
                break
            }
        }

        let promptResponse = try await promptTask.value
        XCTAssertEqual(promptResponse.id, promptID)
        XCTAssertEqual(try promptResponse.decodeResult(SamplePayload.self), SamplePayload(stopReason: "end_turn", count: 2))
        XCTAssertEqual(notificationSeqs, [1, 2])
        XCTAssertEqual(handledRequests, [.string("perm-str-1"), .int(99)])
    }

    func testBackpressureBoundsInboundQueueWithoutBlockingResponses() async throws {
        let script = """
        import json, sys
        req = json.loads(sys.stdin.readline())
        for i in range(1500):
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"n": i}}) + "\\n")
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {"done": True}}) + "\\n")
        sys.stdout.flush()
        sys.stdin.read()
        """

        let transport = try JSONRPCProcess(
            executable: "/usr/bin/python3",
            arguments: ["-u", "-c", script],
            cwd: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            maximumQueueCount: 64
        )
        defer { try? transport.close() }

        let reqID = try transport.sendRequest(method: "session/prompt", params: ["burst": true])
        let responseTask = Task.detached { try transport.waitResponse(id: reqID, timeout: 10) }

        var received = 0
        let deadline = Date().addingTimeInterval(10)
        while received < 1500 && Date() < deadline {
            XCTAssertLessThanOrEqual(transport.bufferStatus.inbound, 64)
            let batch = transport.waitInbound(timeout: 0.05)
            received += batch.messages.count
            if batch.ended && batch.messages.isEmpty { break }
        }

        XCTAssertEqual(received, 1500)
        let response = try await responseTask.value
        XCTAssertEqual(response.resultRecord?["done"] as? Bool, true)
        XCTAssertEqual(transport.bufferStatus.bufferedResponses, 0)
        XCTAssertEqual(transport.bufferStatus.pendingRequests, 0)
    }

    func testClientRequestIDsPreserveTypeAndExactStringBytes() throws {
        let script = """
        import json, sys
        requests = [json.loads(sys.stdin.readline()) for _ in range(4)]
        for request in reversed(requests):
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": request["method"]}) + "\\n")
        sys.stdout.flush()
        sys.stdin.read()
        """

        let transport = try JSONRPCProcess(
            executable: "/usr/bin/python3",
            arguments: ["-u", "-c", script],
            cwd: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        defer { try? transport.close() }

        let requests: [(JSONRPCID, String)] = [
            (.int(1), "int"), (.string("1"), "string"),
            (.string("caf\u{00E9}"), "composed"), (.string("cafe\u{0301}"), "decomposed")
        ]
        for (id, method) in requests {
            XCTAssertEqual(try transport.sendRequest(id: id, method: method), id)
        }
        for (id, method) in requests {
            let response = try transport.waitResponse(id: id, timeout: 5)
            XCTAssertEqual(response.id, id)
            XCTAssertEqual(response.result as? String, method)
        }
    }

    func testMalformedJSONIncompleteEOFAndOversizedRecordFailPendingCalls() throws {
        let cases: [(String, Int)] = [
            ("print('{bad-json}', flush=True)", 16 * 1_024 * 1_024),
            ("import sys; sys.stdout.write('{\"jsonrpc\":\"2.0\",\"id\":1}'); sys.stdout.flush()", 16 * 1_024 * 1_024),
            ("pass", 16 * 1_024 * 1_024),
            ("import json, sys; print(json.dumps({'jsonrpc':'2.0','method':'x','params':{'d':'a'*2048}}), flush=True)", 256)
        ]

        for (source, limit) in cases {
            let transport = try JSONRPCProcess(
                executable: "/usr/bin/python3",
                arguments: ["-u", "-c", source],
                cwd: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment,
                maximumRecordBytes: limit
            )
            defer { try? transport.close() }
            let id = try transport.sendRequest(method: "initialize")
            XCTAssertThrowsError(try transport.waitResponse(id: id, timeout: 3))
        }
    }

    func testCloseEscalatesWhenChildIgnoresStdinEOF() throws {
        let script = """
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(30)
        """
        let transport = try JSONRPCProcess(
            executable: "/usr/bin/python3",
            arguments: ["-u", "-c", script],
            cwd: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        XCTAssertThrowsError(try transport.close(timeout: 0.2))
    }
}
