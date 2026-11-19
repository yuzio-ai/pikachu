import Foundation
import AgentRuntimeCore
import PiRuntimeAdapter
import OrchestrationCore
import Darwin

if CommandLine.arguments.contains("--baseline") {
    try await measureProjectionBaseline()
    exit(0)
}

let fm = FileManager.default
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let output = project.appendingPathComponent(".m1-runs/\(runID)")
let work = fm.temporaryDirectory.appendingPathComponent("Pikachu M1 \(UUID().uuidString)")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let paths = PiConfiguration.detectedPaths()
let auth = work.appendingPathComponent("agent")
try fm.createDirectory(at: auth, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let real = CommandLine.arguments.contains("--real")
if real {
    let original = fm.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
    try fm.copyItem(at: original.appendingPathComponent("auth.json"), to: auth.appendingPathComponent("auth.json"))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.appendingPathComponent("auth.json").path)
    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("settings.json"))) as? [String: Any] ?? [:]
    let subset = settings.filter { ["defaultProvider", "defaultModel", "defaultThinkingLevel"].contains($0.key) }
    try JSONSerialization.data(withJSONObject: subset).write(to: auth.appendingPathComponent("settings.json"))
}
var results: [[String: Any]] = []
enum VerificationError: Error { case failed(String) }
func check(_ value: Bool, _ text: String) throws { if !value { throw VerificationError.failed(text) } }
func save(_ data: Any, _ name: String) throws {
    try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic)
}
@MainActor func wait(_ seconds: Double = 8, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try check(condition(), "Timed out waiting for expected domain state")
}
@MainActor func test(_ name: String, _ body: () async throws -> [String: Any]) async {
    let started = Date()
    do { let evidence = try await body(); results.append(["case": name, "status": "pass", "seconds": Date().timeIntervalSince(started), "evidence": evidence]); print("PASS \(name)") }
    catch { results.append(["case": name, "status": "fail", "seconds": Date().timeIntervalSince(started), "error": String(describing: error)]); print("FAIL \(name): \(error)") }
    try? FileHandle.standardOutput.synchronize(); try? save(results, "results.json")
}
@MainActor func configuration(_ name: String, fakeMode: String? = nil, fixture: URL? = nil) throws -> PiConfiguration {
    let cwd = work.appendingPathComponent(name)
    try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    var executable = URL(fileURLWithPath: paths.pi)
    if fakeMode != nil {
        executable = cwd.appendingPathComponent("fake-pi")
        try fm.copyItem(at: project.appendingPathComponent("Tools/M1Verification/Fixtures/fake-pi.py"), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    return .init(executable: executable, nodeDirectory: URL(fileURLWithPath: paths.node), workspace: cwd,
                 agentDirectory: auth, sessionDirectory: cwd.appendingPathComponent("sessions"), proxy: real ? paths.proxy : "",
                 extensionFixture: fakeMode.map { URL(fileURLWithPath: $0) } ?? fixture)
}
@MainActor func snapshot(_ store: SessionController) -> [String: Any] {
    ["connection": store.connection.rawValue, "phase": store.phase.rawValue, "recoveredDrafts": store.recoveredDrafts.map(\.text),
     "failureKind": store.failure?.kind.rawValue ?? "none", "transcript": store.transcript.map { item -> [String: Any] in
         ["id": item.id, "text": item.text, "delivery": item.delivery.rawValue,
          "tool": item.tool.map { ["name": $0.name, "state": $0.state.rawValue, "output": $0.output] } ?? [:]]
     }]
}

await test("M1/fake-runtime-contract") {
    let store = SessionController(); await store.connect(FakeRuntime())
    store.draft = "demo"; await store.sendDraft()
    try await wait { store.transcript.contains { $0.tool != nil } }
    store.draft = "keep follow-up"; store.mode = .followUp; await store.sendDraft()
    store.draft = "editor remains"; await store.stop()
    try await wait { store.recoveredDrafts.count == 1 }
    try check(store.draft == "editor remains" && store.recoveredDrafts[0].text == "keep follow-up", "Draft loss on stop")
    let result = snapshot(store); let closed = await store.disconnect(); try check(closed, "Fake runtime close failed"); return result
}

for mode in ["normal", "rejected", "authentication", "timeout", "malformed", "crash"] {
    await test("M1/wire-\(mode)") {
        let config = try configuration(mode, fakeMode: mode), runtime = PiRuntime(configuration: config), store = SessionController()
        await store.connect(runtime); try check(store.connection == .connected, "Fault peer failed to connect")
        store.draft = "Synthetic fixture prompt"; await store.sendDraft()
        switch mode {
        case "normal":
            try await wait { store.phase == .idle && store.transcript.contains { $0.text == "canonical fixture result" } }
        case "rejected": try check(store.transcript.first?.delivery == .rejected, "Rejected prompt not distinguished")
        case "authentication":
            try await wait { store.failure?.kind == .authentication }
            try check(!(store.failure?.detail.contains("secret") ?? false), "Authentication detail leaked")
        case "timeout":
            try check(store.transcript.first?.delivery == .unknown && !store.canSend, "Unknown submission was treated as accepted")
            let count = try String(contentsOf: config.workspace.appendingPathComponent("prompt-count"), encoding: .utf8)
            try check(count.count == 1, "Prompt was automatically retried")
        case "malformed":
            try await wait { store.connection == .blocked }
            try check(store.failure?.kind == .protocolError, "Protocol failure was hidden by a later request timeout")
        case "crash":
            try await wait { fm.fileExists(atPath: config.workspace.appendingPathComponent("heartbeat").path) }
            await runtime.terminateRuntimeForVerification()
            try await wait { store.connection == .disconnected || store.connection == .blocked }
            try check(store.connection == .disconnected && store.failure != nil, "Process crash did not report cleaned disconnection")
            let a = try Data(contentsOf: config.workspace.appendingPathComponent("heartbeat"))
            try await Task.sleep(for: .milliseconds(300))
            try check(a == Data(contentsOf: config.workspace.appendingPathComponent("heartbeat")), "Heartbeat survived supervision")
        default: break
        }
        let result = snapshot(store)
        let closed = await store.disconnect(force: true); try check(closed, "Fault peer cleanup unconfirmed")
        return result
    }
}

await test("M1/unsupported-version") {
    var config = try configuration("version", fakeMode: "normal")
    let executable = config.workspace.appendingPathComponent("wrong-version")
    try "#!/bin/sh\nprintf '99.0.0\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path); config.executable = executable
    let store = SessionController(); await store.connect(PiRuntime(configuration: config))
    try check(store.failure?.kind == .unsupportedVersion && !store.canSend, "Unverified version was allowed")
    return snapshot(store)
}
await test("M1/connection-timeout") {
    let config = try configuration("connect timeout", fakeMode: "connect-timeout"), store = SessionController()
    await store.connect(PiRuntime(configuration: config))
    try check(store.connection == .disconnected && store.failure != nil, "Startup timeout not handled")
    return snapshot(store)
}

if real {
    await test("M1/real-extension-cancellation") {
        let fixture = project.appendingPathComponent("Tools/M0Validation/Fixtures/control.ts")
        let config = try configuration("extensions", fixture: fixture), store = SessionController()
        await store.connect(PiRuntime(configuration: config)); try check(store.connection == .connected, "Pi did not connect")
        store.draft = "/m0-dialogs"; await store.sendDraft()
        try await wait { store.notice != nil }
        try check(store.transcript.first?.delivery == .handled && store.phase == .idle, "Extension blocked or incorrectly started a run")
        try await wait { store.notice == "[null,false,null,null]" }
        let result = snapshot(store); let closed = await store.disconnect(); try check(closed, "Extension process cleanup failed"); return result
    }
    for i in 1...2 {
        await test("M1/real-coding-\(i)") {
            let config = try configuration("coding \(i)"), runtime = PiRuntime(configuration: config), store = SessionController()
            let node = config.nodeDirectory.appendingPathComponent("node").path
            try "exports.add=(a,b)=>a-b;\n".write(to: config.workspace.appendingPathComponent("sum.cjs"), atomically: true, encoding: .utf8)
            let source = "const {test}=require('node:test');const a=require('node:assert/strict');test('addition',()=>a.equal(require('./sum.cjs').add(2,3),5));\n"
            try source.write(to: config.workspace.appendingPathComponent("sum.test.cjs"), atomically: true, encoding: .utf8)
            func nodeTest() throws -> Int32 {
                let p = Process(); p.executableURL = URL(fileURLWithPath: node); p.arguments = ["--test", "sum.test.cjs"]; p.currentDirectoryURL = config.workspace
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit(); return p.terminationStatus
            }
            try check(try nodeTest() != 0, "Test fixture should fail initially")
            await store.connect(runtime); try check(store.connection == .connected, "Pi did not connect")
            store.draft = "M1 isolated fixture: only work in this directory. Read sum.cjs and sum.test.cjs, fix addition in sum.cjs, run '\(node)' --test sum.test.cjs. Do not change the test. Reply briefly."
            await store.sendDraft()
            try await wait(180) { store.phase == .idle || store.connection != .connected }
            try check(store.failure == nil && store.transcript.contains { $0.tool?.state == .completed }, "Real task failed or tools missing")
            try check(try nodeTest() == 0 && String(contentsOf: config.workspace.appendingPathComponent("sum.test.cjs"), encoding: .utf8) == source, "Independent task verification failed")
            let result = snapshot(store); let closed = await store.disconnect(); try check(closed, "Real task cleanup failed"); return result
        }
    }
    await test("M1/real-stop-and-crash") {
        let config = try configuration("real stop"), runtime = PiRuntime(configuration: config), store = SessionController()
        let node = config.nodeDirectory.appendingPathComponent("node").path
        try "const fs=require('node:fs');setInterval(()=>fs.appendFileSync('heartbeat','x'),50);".write(to: config.workspace.appendingPathComponent("heartbeat.cjs"), atomically: true, encoding: .utf8)
        await store.connect(runtime); try check(store.connection == .connected, "Pi did not connect")
        store.draft = "Run exactly '\(node)' heartbeat.cjs in bash with timeout 60 seconds. No other tools. Reply DONE after completion."
        await store.sendDraft()
        try await wait(90) { fm.fileExists(atPath: config.workspace.appendingPathComponent("heartbeat").path) }
        store.draft = "M1 follow-up retained"; store.mode = .followUp; await store.sendDraft()
        store.draft = "editing stays"; await store.stop()
        try await wait { !store.recoveredDrafts.isEmpty }
        try check(store.recoveredDrafts[0].text == "M1 follow-up retained" && store.draft == "editing stays", "Real stopped drafts lost")
        try check(store.transcript.last(where: { $0.kind == .user })?.delivery == .recovered, "Cleared input still shown as delivered")
        let a = try Data(contentsOf: config.workspace.appendingPathComponent("heartbeat")); try await Task.sleep(for: .milliseconds(300))
        try check(a == Data(contentsOf: config.workspace.appendingPathComponent("heartbeat")), "Real stopped tool kept running")
        await runtime.terminateRuntimeForVerification()
        try await wait { store.connection == .disconnected }
        let result = snapshot(store); let closed = await store.disconnect(force: true); try check(closed, "Crashed Pi cleanup failed"); return result
    }
}
try? fm.removeItem(at: auth)
try save(["runID": runID, "realModelCalls": real, "workspace": work.path, "results": results], "run.json")
print("Evidence: \(output.path)")
exit(results.contains { $0["status"] as? String == "fail" } ? 1 : 0)
