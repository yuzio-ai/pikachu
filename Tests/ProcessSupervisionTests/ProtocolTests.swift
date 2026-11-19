import XCTest
import Foundation
@testable import ProcessSupervision

final class ProtocolTests: XCTestCase {
    func testProductionStreamingPipeReturnsSmallResponsesAndDrainsBoundedEvents() async throws {
        let source = """
        import json,sys
        c=json.loads(sys.stdin.readline())
        for i in range(5000): print(json.dumps({'type':'notice','number':i}),flush=True)
        print(json.dumps({'type':'response','id':c['id'],'success':True}),flush=True)
        sys.stdin.read()
        """
        let p = try RPCProcess(executable:"/usr/bin/python3",arguments:["-u","-c",source],cwd:FileManager.default.temporaryDirectory,environment:ProcessInfo.processInfo.environment,streaming:true)
        defer { try? p.close() }
        let id = try p.submit("fixture")
        let response = Task.detached { try p.response(id,timeout:10)["id"] as? String }
        var received = 0, cursor = 0
        let deadline = Date().addingTimeInterval(10)
        while received < 5000 && Date() < deadline {
            XCTAssertLessThanOrEqual(p.bufferStatus.events,128)
            let observation = p.observation(after:cursor); cursor = observation.nextCursor; received += observation.records.count
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTAssertEqual(received,5000)
        let result = try await response.value
        XCTAssertEqual(result,id)
        XCTAssertEqual(p.bufferStatus.responses,0)
    }
    func testProductionRecordLimitRejectsWholeRecord() throws {
        var decoder = JSONLDecoder(maximumRecordBytes:32)
        XCTAssertThrowsError(try decoder.feed(Data(String(repeating:"x",count:33).utf8)))
    }
    func testReusedPIDIdentityCannotBeSignalled() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let identity = try XCTUnwrap(ProcessIdentity.read(child.processIdentifier))
        let wrongBirth = ProcessIdentity(pid: identity.pid, parent: identity.parent, seconds: identity.seconds + 1,
                                         microseconds: identity.microseconds, status: identity.status)
        XCTAssertFalse(wrongBirth.signal(SIGKILL))
        XCTAssertTrue(child.isRunning)
    }
    func testOutOfOrderAndEventInterleavingOverRealPipes() throws {
        let source = """
        import json,sys
        a=json.loads(sys.stdin.readline()); b=json.loads(sys.stdin.readline())
        for r in [{'type':'response','id':b['id'],'success':True}, {'type':'agent_start'}, {'type':'response','id':a['id'],'success':True}]:
            print(json.dumps(r),flush=True)
        sys.stdin.read()
        """
        let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", source], cwd: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
        defer { try? p.close() }
        let a = try p.submit("first"), b = try p.submit("second")
        XCTAssertEqual(try p.response(a)["id"] as? String, a)
        XCTAssertEqual(try p.response(b)["id"] as? String, b)
        XCTAssertEqual(p.allRecords.first?["id"] as? String, b)
        XCTAssertEqual(try p.event("agent_start")["type"] as? String, "agent_start")
    }
    func testMalformedOutputAndEOFEndPendingCalls() throws {
        for source in ["print('{bad}',flush=True)", "pass"] {
            let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", source], cwd: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
            defer { try? p.close() }
            XCTAssertThrowsError(try p.response("unresolved", timeout: 2))
        }
    }
    func testEveryByteBoundaryAndUnicodeSeparators() throws {
        let text = "猫😺\u{2028}line\u{2029}paragraph"
        let record: Record = ["type": "message", "text": text]
        var bytes = try JSONSerialization.data(withJSONObject: record)
        bytes.append(contentsOf: [13, 10])
        for cut in 0...bytes.count {
            var decoder = JSONLDecoder()
            let a = try decoder.feed(Data(bytes.prefix(cut)))
            let b = try decoder.feed(Data(bytes.dropFirst(cut)))
            XCTAssertEqual((a + b).count, 1)
            XCTAssertEqual((a + b)[0]["text"] as? String, text)
            XCTAssertTrue(decoder.pending.isEmpty)
        }
    }
    func testPartialAndMultipleRecords() throws {
        var decoder = JSONLDecoder()
        XCTAssertEqual(try decoder.feed(Data("{\"n\":1}\n{\"n\":2}".utf8)).count, 1)
        XCTAssertFalse(decoder.pending.isEmpty)
        XCTAssertEqual(try decoder.feed(Data("\n".utf8))[0]["n"] as? Int, 2)
    }
    func testMalformedAndNonObjectFail() {
        for text in ["{bad}\n", "[]\n", "null\n", "\"text\"\n"] {
            var decoder = JSONLDecoder()
            XCTAssertThrowsError(try decoder.feed(Data(text.utf8)))
        }
    }
    func testMessageIndexesResetAndFinalOverrides() {
        var projection = MessageProjection()
        for name in ["first", "second"] {
            projection.apply(["type": "message_start"])
            projection.apply(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "wrong"]])
            projection.apply(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 1, "delta": " block"]])
            XCTAssertEqual(projection.currentText, "wrong block")
            projection.apply(["type": "message_end", "message": ["role": "assistant", "content": [["type": "text", "text": name]]]])
            XCTAssertEqual(projection.currentText, name)
        }
        XCTAssertEqual(projection.messages.count, 2)
    }
    func testHistoryBranchTailAndCorruption() throws {
        let fixture = """
        {"type":"session","version":3,"id":"test"}
        {"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"root"}}
        {"type":"message","id":"b","parentId":"a","message":{"role":"assistant","content":[]}}
        {"type":"message","id":"c","parentId":"a","message":{"role":"user","content":"other branch"}}

        """
        let history = try HistoryProbe.read(Data(fixture.utf8))
        XCTAssertEqual(history.branch.compactMap { $0["id"] as? String }, ["a", "c"])
        let partial = try HistoryProbe.read(Data((fixture + "{unfinished").utf8))
        XCTAssertTrue(partial.incompleteTail)
        XCTAssertEqual(partial.branch.count, 2)
        XCTAssertThrowsError(try HistoryProbe.read(Data((fixture + "bad\n").utf8)))
        XCTAssertThrowsError(try HistoryProbe.read(Data(fixture.replacingOccurrences(of: "\"version\":3", with: "\"version\":99").utf8)))
        XCTAssertThrowsError(try HistoryProbe.read(Data(fixture.replacingOccurrences(of: "\"parentId\":\"a\"", with: "\"parentId\":\"missing\"").utf8)))
    }
    func testLargeOutputAndLongHistory() throws {
        let text = String(repeating: "x", count: 10 * 1024 * 1024)
        var bytes = try JSONSerialization.data(withJSONObject: ["text": text]); bytes.append(10)
        var decoder = JSONLDecoder(), records: [Record] = []
        for offset in stride(from: 0, to: bytes.count, by: 8192) {
            records += try decoder.feed(Data(bytes[offset..<min(offset+8192, bytes.count)]))
        }
        XCTAssertEqual((records.first?["text"] as? String)?.count, text.count)
        var lines = "{\"type\":\"session\",\"version\":3,\"id\":\"large\"}\n"
        for i in 0..<5000 {
            let parent = i == 0 ? "null" : "\"\(i-1)\""
            lines += "{\"type\":\"message\",\"id\":\"\(i)\",\"parentId\":\(parent),\"message\":{\"role\":\"user\",\"content\":\"fixture\"}}\n"
        }
        XCTAssertEqual(try HistoryProbe.read(Data(lines.utf8)).branch.count, 5000)
    }
}
