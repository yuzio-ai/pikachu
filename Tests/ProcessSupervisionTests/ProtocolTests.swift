import XCTest
import Foundation
@testable import ProcessSupervision

final class ProtocolTests: XCTestCase {
    func testProductionStreamingPipeReturnsSmallResponsesAndDrainsBoundedEvents() async throws {
        let source = """
        import json,sys
        c=json.loads(sys.stdin.readline())
        for i in range(5000): print(json.dumps({'type':'notice','number':i}),flush=True)
        print(json.dumps({'id':c['id'],'result':{}}),flush=True)
        sys.stdin.read()
        """
        let p = try RPCProcess(executable:"/usr/bin/python3",arguments:["-u","-c",source],cwd:FileManager.default.temporaryDirectory,environment:ProcessInfo.processInfo.environment,streaming:true)
        defer { try? p.close() }
        try p.send(["id": 1, "method": "fixture"])
        var responseID: Int?
        var received = 0, cursor = 0
        let deadline = Date().addingTimeInterval(10)
        while responseID == nil && Date() < deadline {
            XCTAssertLessThanOrEqual(p.bufferStatus.events,128)
            let observation = p.observation(after:cursor); cursor = observation.nextCursor
            received += observation.records.filter { $0["type"] as? String == "notice" }.count
            responseID = observation.records.compactMap { $0["id"] as? Int }.first
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTAssertEqual(received,5000)
        XCTAssertEqual(responseID, 1)
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
        for r in [{'id':b['id'],'result':{}}, {'method':'notice'}, {'id':a['id'],'result':{}}]:
            print(json.dumps(r),flush=True)
        sys.stdin.read()
        """
        let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", source], cwd: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
        defer { try? p.close() }
        try p.send(["id": 1, "method": "first"])
        try p.send(["id": 2, "method": "second"])
        XCTAssertEqual(try p.wait { $0["id"] as? Int == 1 }["id"] as? Int, 1)
        XCTAssertEqual(try p.wait { $0["id"] as? Int == 2 }["id"] as? Int, 2)
        XCTAssertEqual(p.allRecords.first?["id"] as? Int, 2)
        XCTAssertEqual(try p.wait { $0["method"] as? String == "notice" }["method"] as? String, "notice")
    }
    func testMalformedOutputAndEOFEndPendingCalls() throws {
        for source in ["print('{bad}',flush=True)", "pass"] {
            let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", source], cwd: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
            defer { try? p.close() }
            XCTAssertThrowsError(try p.wait(timeout: 2) { $0["id"] as? Int == 1 })
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
}
