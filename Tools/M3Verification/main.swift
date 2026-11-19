import Foundation
import AgentRuntimeCore
import PiRuntimeAdapter
import OrchestrationCore
import WorkspacePersistence
import M0Support
import Darwin

if CommandLine.arguments.contains("--verify-broken-pipe") {
    signal(SIGPIPE,SIG_DFL)
    let source = "import sys,json,os,time; c=json.loads(sys.stdin.readline()); os.close(0); print(json.dumps({'type':'response','id':c['id'],'success':True}),flush=True); time.sleep(1)"
    let peer = try RPCProcess(executable:"/usr/bin/python3",arguments:["-u","-c",source],cwd:FileManager.default.temporaryDirectory,environment:ProcessInfo.processInfo.environment,streaming:true)
    _ = try peer.ok("ready")
    do { _ = try peer.submit("after-stdin-closed"); exit(2) }
    catch { try peer.close(); exit(0) }
}

let fm = FileManager.default
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let output = repo.appendingPathComponent(".m3-runs/\(stamp)")
let work = fm.temporaryDirectory.appendingPathComponent("Pikachu-M3-\(UUID())")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
let paths = PiConfiguration.detectedPaths()
let agent = work.appendingPathComponent("agent"), sessions = work.appendingPathComponent("sessions")
try fm.createDirectory(at: agent, withIntermediateDirectories: true)
try Data("{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-6.1-sol\"}".utf8).write(to: agent.appendingPathComponent("settings.json"))
func json(_ value: Any, _ file: URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:file) }
func check(_ value: Bool, _ detail: String) throws { if !value { throw RuntimeFailure(.setup,detail) } }
@MainActor func wait(_ seconds: Double = 10, _ predicate: () -> Bool) async throws {
    let limit = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < limit { try await Task.sleep(for:.milliseconds(10)) }
    try check(predicate(),"State deadline exceeded")
}
@MainActor func make(_ root: URL, executable: String? = nil, fixture: URL? = nil) async -> (SessionController,PiRuntime) {
    try! fm.createDirectory(at:root,withIntermediateDirectories:true)
    var program = executable ?? paths.pi
    if let executable {
        let copy = root.appendingPathComponent("fixture-pi")
        try! fm.copyItem(at:URL(fileURLWithPath:executable),to:copy)
        try! fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:copy.path); program = copy.path
    }
    let runtime = PiRuntime(configuration:.init(executable:URL(fileURLWithPath:program),nodeDirectory:URL(fileURLWithPath:paths.node),workspace:root,agentDirectory:agent,sessionDirectory:sessions,
        proxy:paths.proxy,extensionFixture:fixture ?? repo.appendingPathComponent("Tools/M3Verification/Fixtures/control.ts"),nativeDialogs:true))
    let host = SessionController(); await host.connect(runtime); return (host,runtime)
}
var results: [[String:Any]] = []
@MainActor func test(_ name: String, _ body: () async throws -> [String:Any]) async {
    do { let evidence = try await body(); results.append(["case":name,"status":"pass","evidence":evidence]); print("PASS \(name)") }
    catch { results.append(["case":name,"status":"fail","error":String(describing:error)]); print("FAIL \(name): \(error)") }
    try? json(results,output.appendingPathComponent("results.json"))
}

if let index = CommandLine.arguments.firstIndex(of:"--history-benchmark"), CommandLine.arguments.indices.contains(index+1) {
    let root = URL(fileURLWithPath:CommandLine.arguments[index+1]), reader = PiHistoryReader(roots:[])
    for name in ["ordinary","long"] { for _ in 0..<3 {
        let start = Date(); let value = try await reader.read(root.appendingPathComponent(name+".jsonl"))
        print("\(name) rows=\(value.items.count) readMS=\(Date().timeIntervalSince(start)*1000)")
    }}; exit(0)
}

// Reproducible native dataset/store. Only the separately identified diagnostic app reads it.
if let index = CommandLine.arguments.firstIndex(of:"--prepare-native"), CommandLine.arguments.indices.contains(index+1) {
    let root = URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL.resolvingSymlinksInPath(); try fm.createDirectory(at:root,withIntermediateDirectories:true)
    try check(try fm.contentsOfDirectory(atPath:root.path).isEmpty,"Use a new empty native fixture directory")
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
    let fixtures = root.appendingPathComponent("fixtures"); try fm.createDirectory(at:fixtures,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let control = fixtures.appendingPathComponent("control.ts"), loadPeer = fixtures.appendingPathComponent("stream-pi")
    try fm.copyItem(at:repo.appendingPathComponent("Tools/M3Verification/Fixtures/control.ts"),to:control)
    try fm.copyItem(at:repo.appendingPathComponent("Tools/M3Verification/Fixtures/stream-pi.py"),to:loadPeer)
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:loadPeer.path)
    let project = root.appendingPathComponent("Native M3"), history = root.appendingPathComponent("sessions")
    try fm.createDirectory(at:project,withIntermediateDirectories:true)
    let generator = Process(); generator.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    generator.arguments = [repo.appendingPathComponent("Tools/M0Validation/Fixtures/generate-history.py").path,history.path]
    try generator.run(); generator.waitUntilExit(); try check(generator.terminationStatus == 0,"Dataset generation failed")
    var snapshot = WorkspaceSnapshot(); let p = ProjectRecord(path:project.path); snapshot.projects = [p]
    let interactive = SessionReference(projectID:p.id,title:"M3 交互验证"); snapshot.sessions.append(interactive)
    for name in ["ordinary","long"] {
        let file = history.appendingPathComponent(name+".jsonl")
        var lines = try String(contentsOf:file,encoding:.utf8).split(separator:"\n").map(String.init)
        var header = try JSONSerialization.jsonObject(with:Data(lines[0].utf8)) as! [String:Any]; header["cwd"] = project.path
        lines[0] = String(decoding:try JSONSerialization.data(withJSONObject:header,options:.sortedKeys),as:UTF8.self)
        try (lines.joined(separator:"\n")+"\n").write(to:file,atomically:true,encoding:.utf8)
        var ref = SessionReference(projectID:p.id,title:name == "long" ? "M0 长历史 5000" : "M0 普通历史 100")
        ref.runtimeSessionID = "m0-"+name; ref.file = file; ref.historyConfirmed = true; snapshot.sessions.append(ref)
    }
    snapshot.selectedSessionID = interactive.id; snapshot.revision = 1
    let auth = root.appendingPathComponent("agent"); try fm.createDirectory(at:auth,withIntermediateDirectories:true)
    try Data("{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-6.1-sol\"}".utf8).write(to:auth.appendingPathComponent("settings.json"))
    let store = try SwiftDataWorkspaceStore(url:root.appendingPathComponent("state/workspace.store")); try await store.save(snapshot)
    var config: [String:String] = ["--pi":paths.pi,"--node-dir":paths.node,"--agent-dir":auth.path,"--proxy":paths.proxy,"--sessions":history.path,"--state-dir":root.appendingPathComponent("state").path,"--extension-fixture":control.path,"--metrics":root.appendingPathComponent("metrics.jsonl").path]
    try json(config,root.appendingPathComponent("M3Diagnostics.json"))
    config["--pi"] = loadPeer.path
    try json(config,root.appendingPathComponent("M3LoadDiagnostics.json"))
    print("Native fixture: \(root.path)"); exit(0)
}

await test("M3/on-demand-model-catalog-and-plan-recovery") {
    let root = work.appendingPathComponent("composer"), project = root.appendingPathComponent("project")
    let fixtureAgent = root.appendingPathComponent("agent"), fixtureSessions = root.appendingPathComponent("sessions")
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    try fm.createDirectory(at: fixtureAgent, withIntermediateDirectories: true)
    try json(["providers": ["fixture": ["baseUrl": "http://127.0.0.1:1/v1", "api": "openai-completions",
        "apiKey": "fixture-key", "models": [["id": "fixture-basic"], ["id": "fixture-reasoning", "reasoning": true]]]]],
        fixtureAgent.appendingPathComponent("models.json"))
    var config = PiConfiguration(executable: URL(fileURLWithPath: paths.pi), nodeDirectory: URL(fileURLWithPath: paths.node),
                                 workspace: project, agentDirectory: fixtureAgent, sessionDirectory: fixtureSessions,
                                 nativeDialogs: true, agentMode: .plan)
    let catalog = try await PiRuntime.inspectModels(config, model: nil)
    guard let model = catalog.models.first(where: { $0.provider == "fixture" && $0.modelID == "fixture-reasoning" }) else {
        throw RuntimeFailure(.setup, "The temporary catalog missed the configured model")
    }
    let levels = try await PiRuntime.inspectModels(config, model: model)
    try check(levels.thinkingLevels.contains("low"), "The probe did not select the requested model")
    try check(!fm.fileExists(atPath: fixtureSessions.path), "The probe created an execution session directory")

    let history = project.appendingPathComponent("history.jsonl"), historyID = UUID().uuidString
    let header = try JSONSerialization.data(withJSONObject: ["type": "session", "version": 3, "id": historyID,
                                                                "cwd": project.path, "timestamp": "2026-11-19T00:00:00Z"])
    try (header + Data([10])).write(to: history)
    config.resumeFile = history
    config.expectedSessionID = historyID
    let runtime = PiRuntime(configuration: config)
    do {
        let connected = try await runtime.connect()
        try check(connected.id == historyID, "The plan session did not restore its original history")
        try await runtime.close(force: false)
    } catch {
        try? await runtime.close(force: true)
        throw error
    }
    return ["temporaryCatalog": true, "modelSpecificLevels": true, "planHistoryRestored": true]
}
await test("M3/closed-peer-stdin-does-not-kill-host") {
    let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
    child.arguments = ["--verify-broken-pipe"]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run(); while child.isRunning { try await Task.sleep(for:.milliseconds(10)) }
    try check(child.terminationStatus == 0,"Host died or accepted a write after peer closed stdin")
    return ["defaultSIGPIPEHandler":true,"hostExit":child.terminationStatus,"writeRejected":true]
}

await test("M3/real-pi-four-dialogs-and-once-only-replies") {
    let root = work.appendingPathComponent("dialogs"), (host,_) = await make(root)
    defer { Task { _ = await host.disconnect(force:true) } }
    try check(host.connection == .connected,"Pi did not connect")
    host.draft = "/m3-dialogs"; let task = Task { await host.sendDraft() }
    var old: RuntimeInteraction?
    for (kind,response) in [(InteractionKind.select,InteractionResponse.value("Beta")),(.confirm,.confirmed(false)),(.input,.value("单行 😺")),(.editor,.value("第一行\n修改第二行"))] {
        try await wait { host.interactions.first?.kind == kind }
        let request = host.interactions[0]; old = request
        try check(host.phase == .waitingInput && host.canStop && !host.canSend,"Waiting controls inconsistent")
        try check(await host.reply(request,response),"Native reply rejected")
        try check(!(await host.reply(request,response)),"Duplicate reply accepted")
    }
    await task.value
    try await wait { host.interactions.isEmpty && !host.commandPending }
    let data = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("dialog-result.json"))) as! [String:Any]
    try check(data["choice"] as? String == "Beta" && data["confirmed"] as? Bool == false && data["input"] as? String == "单行 😺" && data["editor"] as? String == "第一行\n修改第二行","Pi received incorrect values")
    try check(await host.disconnect(),"Supervisor cleanup failed")
    try check(!(await host.reply(old!,.cancelled)),"Disconnected request accepted")
    return ["fourMethods":true,"negativeConfirmationPreserved":true,"duplicateAndDisconnectedRejected":true,"cleanupConfirmed":true]
}
await test("M3/stop-cancels-dialog-with-pending-command") {
    let root = work.appendingPathComponent("stop"), (host,_) = await make(root)
    host.draft = "/m3-wait"; let task = Task { await host.sendDraft() }
    try await wait { !host.interactions.isEmpty }
    host.draft = "Existing editor draft"; await host.stop(); await task.value
    try check(host.phase == .idle && host.interactions.isEmpty && host.draft == "Existing editor draft" && host.failure == nil,"Stop lost draft or stayed waiting")
    let result = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("wait-result.json"))) as! [String:Any]
    try check(result["value"] is NSNull,"Stop did not cancel Pi UI")
    try check(await host.disconnect(),"Stop cleanup failed")
    return ["pendingCommandStopped":true,"draftPreserved":true,"cancelDelivered":true]
}
await test("M3/expiry-and-unsupported-cost") {
    let root = work.appendingPathComponent("expire"), (host,_) = await make(root)
    host.draft = "/m3-expire"; await host.sendDraft()
    try await wait { host.interactions.isEmpty && host.phase == .idle }
    await host.refreshUsage()
    try check(host.usage?.sessionID == host.session?.id && host.usage?.estimatedCostUSD == nil,"Unknown cost reported as priced")
    try check(host.notice?.contains("过期") == true,"Expiry not explained")
    try check(await host.disconnect(),"Expiry cleanup failed")
    return ["expiryRetired":true,"unknownCostExplicit":true,"noInference":true]
}
await test("M3/nonmodal-ui-preserves-draft") {
    let root = work.appendingPathComponent("status"), (host,_) = await make(root)
    host.draft = "/m3-status"; await host.sendDraft(); host.draft = "Keep my new draft"
    try await wait { host.recoveredDrafts.contains { $0.text == "扩展建议草稿" } && host.extensionStatus.count == 3 }
    try check(host.draft == "Keep my new draft","Extension overwrote editor")
    try check(await host.disconnect(),"Status cleanup failed")
    return ["threeStatusSurfaces":true,"suggestionRecovered":true,"draftPreserved":true]
}
await test("M3/disconnect-retires-open-dialog") {
    let root = work.appendingPathComponent("disconnect"), (host,runtime) = await make(root)
    host.draft = "/m3-wait"; let task = Task { await host.sendDraft() }
    try await wait { !host.interactions.isEmpty }; let stale = host.interactions[0]
    await runtime.terminateRuntimeForVerification(); await task.value
    try await wait { host.connection == .disconnected }
    let lateAccepted = await host.reply(stale,.value("late"))
    try check(host.interactions.isEmpty && !lateAccepted,"Stale dialog survived crash")
    try check(await host.disconnect(force:true),"Crash descendant cleanup unconfirmed")
    return ["lateReplyRejected":true,"cleanupConfirmed":true,"noReplay":true]
}
await test("M3/native-mode-no-dialog-ack-timeout-remains-five-seconds") {
    let root = work.appendingPathComponent("timeout"), (host,_) = await make(root,executable:repo.appendingPathComponent("Tools/M1Verification/Fixtures/fake-pi.py").path,fixture:URL(fileURLWithPath:"timeout"))
    host.draft = "No automatic replay"; let start = Date(); await host.sendDraft(); let elapsed = Date().timeIntervalSince(start)
    try check(host.failure?.kind == .outcomeUnknown && elapsed >= 4.9 && elapsed < 8,"Ordinary timeout changed")
    try check(await host.disconnect(force:true),"Timeout cleanup failed")
    return ["ackSeconds":elapsed,"unknownOutcome":true]
}
await test("M3/large-output-stream-and-main-actor-responsiveness") {
    let root = work.appendingPathComponent("stream"), (host,_) = await make(root,executable:repo.appendingPathComponent("Tools/M3Verification/Fixtures/stream-pi.py").path)
    try check(host.connection == .connected,"Load peer did not connect")
    host.draft = "Load fixture"; await host.sendDraft()
    var samples: [Double] = [], peakRSS = 0
    let before = residentMemory(), deadline = Date().addingTimeInterval(90)
    repeat {
        let start = ContinuousClock.now; host.draft = "Input remains responsive \(samples.count)"; await Task.yield()
        let duration = start.duration(to:.now); samples.append(Double(duration.components.seconds)*1e3+Double(duration.components.attoseconds)/1e15)
        peakRSS = max(peakRSS,residentMemory()); try await Task.sleep(for:.milliseconds(10))
    } while host.phase != .idle && host.connection == .connected && Date() < deadline
    try check(host.phase == .idle && host.failure == nil,"Load did not settle cleanly")
    let tool = host.transcript.first { $0.tool != nil }?.tool
    try check(tool?.state == .completed && tool?.truncated == true && (tool?.output.count ?? Int.max) <= 65_537,"Large output retention not bounded")
    try check(host.transcript.contains { $0.text == "canonical load result" },"Canonical final message lost")
    try await Task.sleep(for:.milliseconds(500)); let after = residentMemory()
    let p95 = samples.sorted()[min(samples.count-1,Int(Double(samples.count)*0.95))]
    try check(after-before <= 200*1_024*1_024 && p95 <= 5,"Retained RSS or domain responsiveness exceeded budget")
    try check(await host.disconnect(),"Load process cleanup failed")
    return ["toolPayloadBytes":10*1_024*1_024,"retainedCharacters":tool!.output.count,"retainedRSSDeltaBytes":after-before,"peakRSSDeltaBytes":peakRSS-before,"mainActorYieldP95MS":p95,"samples":samples.count,"pixelLatencyMeasured":false]
}
func residentMemory() -> Int {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
    return status == KERN_SUCCESS ? Int(info.resident_size) : 0
}
try json(["runID":stamp,"work":work.path,"results":results,"modelCalls":0],output.appendingPathComponent("run.json"))
print("Evidence: \(output.path)")
exit(results.contains { $0["status"] as? String == "fail" } ? 1 : 0)
