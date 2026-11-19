import Foundation
import AgentRuntimeCore
import PiRuntimeAdapter
import OrchestrationCore
import WorkspacePersistence
import Darwin

let fm = FileManager.default
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let output = repo.appendingPathComponent(".m2-runs/\(runID)")
let work = fm.temporaryDirectory.appendingPathComponent("Pikachu M2 \(UUID())")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let real = CommandLine.arguments.contains("--real"), paths = PiConfiguration.detectedPaths()
let auth = work.appendingPathComponent("agent"), sessions = work.appendingPathComponent("sessions")
try fm.createDirectory(at: auth, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let original = fm.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("settings.json"))) as? [String: Any] ?? [:]
try JSONSerialization.data(withJSONObject: settings.filter { ["defaultProvider","defaultModel","defaultThinkingLevel"].contains($0.key) }).write(to: auth.appendingPathComponent("settings.json"))
if real {
    try fm.copyItem(at: original.appendingPathComponent("auth.json"), to: auth.appendingPathComponent("auth.json"))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.appendingPathComponent("auth.json").path)
}
let projectA = work.appendingPathComponent("Project A"), projectB = work.appendingPathComponent("Project B")
for project in [projectA,projectB] { try fm.createDirectory(at: project, withIntermediateDirectories: true) }
let storeURL = work.appendingPathComponent("workspace.store")
let reader = PiHistoryReader(roots: [sessions])
var instances: [PiRuntime] = []
@MainActor func workspace() throws -> WorkspaceController {
    let store = try SwiftDataWorkspaceStore(url: storeURL)
    return WorkspaceController(store: store, reader: reader) { project, reference in
        let runtime = PiRuntime(configuration: .init(executable: URL(fileURLWithPath: paths.pi), nodeDirectory: URL(fileURLWithPath: paths.node),
            workspace: URL(fileURLWithPath: project.path), agentDirectory: auth, sessionDirectory: sessions.appendingPathComponent(project.id.uuidString), proxy: paths.proxy,
            extensionFixture: repo.appendingPathComponent("Tools/M2Verification/Fixtures/control.ts"), resumeFile: reference.file, expectedSessionID: reference.runtimeSessionID))
        instances.append(runtime); return runtime
    }
}
enum CheckError: Error { case failed(String) }
func check(_ value: Bool, _ text: String) throws { if !value { throw CheckError.failed(text) } }
func save(_ value: Any, _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent(name)) }
@MainActor func wait(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
    let until = Date().addingTimeInterval(seconds)
    while !condition() && Date() < until { try await Task.sleep(for: .milliseconds(10)) }
    try check(condition(), "Expected state did not arrive")
}
var results: [[String: Any]] = []
let onlyCase: String? = CommandLine.arguments.firstIndex(of: "--case").flatMap { index in
    CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
}
@MainActor func test(_ name: String, _ body: () async throws -> [String: Any]) async {
    if let onlyCase, onlyCase != name { return }
    do { let evidence = try await body(); results.append(["case":name,"status":"pass","evidence":evidence]); print("PASS \(name)") }
    catch { results.append(["case":name,"status":"fail","error":String(describing:error)]); print("FAIL \(name): \(error)") }
    try? save(results,"results.json")
}
var app = try workspace()
var a: UUID!, b: UUID!, aSession: UUID!, bSession: UUID!, codingSession: UUID!
await test("M2/local-drafts-and-restart") {
    await app.start(); a = await app.addProject(projectA); aSession = app.selected!.id
    app.viewed!.controller.draft = "项目 A 草稿 😺"; app.viewed!.controller.mode = .followUp
    app.viewed!.controller.restoreLocalState(draft: "项目 A 草稿 😺", mode: .followUp, recovered: [.init(text: "已清出的 A 后续任务", mode: .followUp)])
    // restoreLocalState is a seeding operation; exercise the normal edit checkpoint.
    app.viewed!.controller.draft += "。"
    b = await app.addProject(projectB); bSession = app.selected!.id; app.viewed!.controller.draft = "项目 B 草稿"
    try check(await app.flush(), "Initial drafts did not save")
    app = try workspace(); await app.start()
    try check(instances.isEmpty && app.activeID == nil, "Restart started a runtime")
    try check(app.selected?.id == bSession && app.viewed!.controller.draft == "项目 B 草稿", "Selected draft not restored")
    await app.select(aSession)
    try check(app.viewed!.controller.draft == "项目 A 草稿 😺。" && app.viewed!.controller.recoveredDrafts.count == 1, "A draft or recovered queue lost")
    return ["projectIDsStable":app.state.projects.contains { $0.id == a },"runtimeStarts":instances.count,"independentDrafts":true]
}
await test("M2/unopened-session-reconnect") {
    try check(await app.activate(aSession), "Pi did not connect")
    try check(app.selected?.file == nil, "Unmaterialized file treated as persisted history")
    try check(await app.disconnect(), "Unopened runtime did not cleanly close")
    let starts = instances.count; app = try workspace(); await app.start()
    try check(instances.count == starts, "Startup reconnected automatically")
    try check(await app.activate(aSession), "Unopened session became a missing-file dead end")
    try check(await app.disconnect(), "Reopened runtime did not cleanly close")
    return ["unopenedSessionStillLocal":true,"noAutomaticReconnect":true]
}
var fixtureID: UUID!
await test("M2/history-branch-compaction-and-read-only-discovery") {
    try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("branch.jsonl"), id = UUID().uuidString
    let records: [[String: Any]] = [
        ["type":"session","version":3,"id":id,"cwd":projectA.path,"timestamp":"2026-11-18T00:00:00Z"],
        ["type":"message","id":"a","parentId":NSNull(),"timestamp":"2026-11-18T00:00:01Z","message":["role":"user","content":"ROOT","timestamp":1]],
        ["type":"message","id":"b","parentId":"a","timestamp":"2026-11-18T00:00:02Z","message":["role":"user","content":"ABANDONED","timestamp":2]],
        ["type":"message","id":"c","parentId":"a","timestamp":"2026-11-18T00:00:03Z","message":["role":"user","content":"KEPT","timestamp":3]],
        ["type":"compaction","id":"d","parentId":"c","timestamp":"2026-11-18T00:00:04Z","summary":"SUMMARY","firstKeptEntryId":"c","tokensBefore":100]]
    var bytes = Data(); for record in records { bytes += try JSONSerialization.data(withJSONObject: record); bytes.append(10) }; try bytes.write(to:file)
    let starts = instances.count; await app.discover(a)
    fixtureID = app.state.sessions.first { $0.runtimeSessionID == id }!.id; await app.select(fixtureID)
    try check(instances.count == starts && app.viewed!.controller.transcript.filter { $0.kind == .user }.map(\.text) == ["ROOT","KEPT"], "History flattened or started a runtime")
    try check(try Data(contentsOf:file) == bytes, "Browsing mutated Pi history")
    try check(await app.activate(fixtureID), "Valid history did not resume")
    try check(app.active?.session?.id == id, "Restored runtime ID mismatch")
    try check(await app.disconnect(), "Restored runtime cleanup failed")
    return ["readOnly":true,"abandonedBranchExcluded":true,"runtimeIDConfirmed":true]
}
await test("M2/partial-and-corrupt-history-block-execution") {
    let file = sessions.appendingPathComponent("partial.jsonl"), id = UUID().uuidString
    let header: [String:Any] = ["type":"session","version":3,"id":id,"cwd":projectA.path,"timestamp":"2026-11-18T00:00:00Z"]
    var bytes = try JSONSerialization.data(withJSONObject:header); bytes.append(10); bytes += Data("{partial".utf8); try bytes.write(to:file)
    await app.discover(a); let local = app.state.sessions.first { $0.runtimeSessionID == id }!.id; await app.select(local)
    let starts = instances.count
    let partialActivated = await app.activate(local)
    try check(app.viewed!.history?.incompleteTail == true && !partialActivated && instances.count == starts, "Partial history was executed")
    try Data("bad\n".utf8).write(to:file); await app.refreshHistory(local)
    let corruptActivated = await app.activate(local)
    try check(app.viewed!.loadError != nil && !corruptActivated, "Corrupt history was silently treated as empty")
    return ["partialVisible":true,"corruptExplicit":true,"noRuntimeStarted":true]
}
await test("M2/resume-cancellation-is-not-success") {
    let file = work.appendingPathComponent("cancelled.jsonl"), id = UUID().uuidString
    let header: [String:Any] = ["type":"session", "version":3, "id":id, "cwd":projectA.path, "timestamp":"2026-11-18T00:00:00Z"]
    var bytes = try JSONSerialization.data(withJSONObject:header); bytes.append(10); try bytes.write(to:file)
    let runtime = PiRuntime(configuration:.init(executable:URL(fileURLWithPath:paths.pi),nodeDirectory:URL(fileURLWithPath:paths.node),workspace:projectA,agentDirectory:auth,sessionDirectory:sessions,
        extensionFixture:repo.appendingPathComponent("Tools/M0Validation/Fixtures/control.ts"),resumeFile:file,expectedSessionID:id))
    let controller = SessionController(); await controller.connect(runtime)
    try check(controller.connection == .disconnected && controller.failure?.detail.contains("取消") == true,"Cancelled resume treated as connected")
    try check(try Data(contentsOf:file) == bytes,"Cancelled resume modified history")
    try check(await controller.disconnect(force:true),"Cancelled resume cleanup unconfirmed")
    return ["cancelledResponseRejected":true,"sourceUnchanged":true,"cleanupConfirmed":true]
}
if real {
    await test("M2/model-configuration-and-effective-readback") {
        await app.select(aSession); try check(await app.activate(aSession), "Configuration session did not connect")
        let options = try await app.configurationOptions(for: aSession)
        guard let actual = app.active?.session, let provider = actual.provider, let model = actual.modelID, let level = options.thinkingLevels.first else { throw CheckError.failed("Missing model metadata") }
        await app.saveSelection(.init(provider:provider,modelID:model,thinking:level), for:aSession)
        try check(app.active?.session?.thinking == level, "Thinking level did not read back")
        await app.saveSelection(.init(provider:"invalid-provider",modelID:"invalid-model"),for:aSession)
        try check(app.active?.session?.modelID == model && app.active?.failure != nil, "Invalid model changed configuration silently")
        try check(await app.disconnect(), "Configuration runtime cleanup failed")
        return ["modelCount":options.models.count,"thinkingReadBack":level,"invalidModelRejected":true]
    }
    await test("M2/real-coding-and-history-recovery") {
        await app.createSession(in:a); codingSession = app.selected!.id
        try "exports.add=(a,b)=>a-b;\n".write(to:projectA.appendingPathComponent("sum.cjs"),atomically:true,encoding:.utf8)
        let source = "const {test}=require('node:test');const a=require('node:assert/strict');test('addition',()=>a.equal(require('./sum.cjs').add(2,3),5));\n"
        try source.write(to:projectA.appendingPathComponent("sum.test.cjs"),atomically:true,encoding:.utf8)
        app.viewed!.controller.draft = "M2 isolated fixture. Only this directory. Read sum.cjs and sum.test.cjs, fix sum.cjs addition, run '\(paths.node)/node' --test sum.test.cjs. Do not modify tests. Reply briefly."
        await app.send(codingSession)
        try await wait(180) { app.active?.phase == .idle || app.active?.connection != .connected }
        try check(app.active?.failure == nil,"Coding task failed")
        let test = Process(); test.executableURL = URL(fileURLWithPath:paths.node + "/node"); test.arguments = ["--test","sum.test.cjs"]; test.currentDirectoryURL = projectA
        test.standardOutput = FileHandle.nullDevice; test.standardError = FileHandle.nullDevice; try test.run(); test.waitUntilExit()
        try check(test.terminationStatus == 0 && String(contentsOf:projectA.appendingPathComponent("sum.test.cjs"),encoding:.utf8) == source,"Independent coding verification failed")
        let id = app.selected!.runtimeSessionID, file = app.selected!.file
        try check(id != nil && file != nil,"Durable runtime reference missing")
        try check(await app.disconnect(),"Coding process cleanup failed")
        let starts = instances.count; app = try workspace(); await app.start(); await app.select(codingSession)
        try check(instances.count == starts && app.viewed!.controller.transcript.contains { $0.tool?.state == .completed },"History restore lost tools or started runtime")
        try check(app.selected!.runtimeSessionID == id,"Local/runtime identity changed")
        return ["independentTestExit":test.terminationStatus,"protectedTestUnchanged":true,"readOnlyRecovery":true,"runtimeSessionID":id!]
    }
    await test("M2/browse-running-stop-switch-and-draft-consistency") {
        await app.select(codingSession)
        try "const fs=require('node:fs');fs.writeFileSync('worker.pid',String(process.pid));setInterval(()=>fs.appendFileSync('heartbeat','x'),50);".write(to:projectA.appendingPathComponent("heartbeat.cjs"),atomically:true,encoding:.utf8)
        app.viewed!.controller.draft = "Run only '\(paths.node)/node' heartbeat.cjs in bash, timeout 120 seconds. Wait for completion."
        await app.send(codingSession)
        let heartbeat = projectA.appendingPathComponent("heartbeat")
        try await wait(90) { fm.fileExists(atPath:heartbeat.path) }
        let starts = instances.count, runtime = app.active!
        await app.select(fixtureID)
        let first = try Data(contentsOf:heartbeat); try await Task.sleep(for:.milliseconds(200))
        try check(first != Data(contentsOf:heartbeat) && instances.count == starts && runtime.phase.isActive,"Browsing interrupted active tool")
        await app.select(codingSession); app.viewed!.controller.mode = .followUp; app.viewed!.controller.draft = "Keep this queued input after stop"; await app.send(codingSession)
        app.viewed!.controller.draft = "Editor A remains"
        await app.select(bSession); app.viewed!.controller.draft = "/m2-noop"
        await app.send(bSession)
        try check(instances.count == starts && app.activeID == codingSession && app.viewed!.controller.draft == "/m2-noop","Unconfirmed target was sent")
        await app.send(bSession,stopCurrent:true)
        try check(app.activeID == bSession && instances.count == starts + 1,"Confirmed switch failed")
        let aRecord = app.state.sessions.first { $0.id == codingSession }!
        try check(aRecord.draft == "Editor A remains" && aRecord.recovered.map(\.text) == ["Keep this queued input after stop"],"Switch lost old drafts")
        let stopped = try Data(contentsOf:heartbeat); try await Task.sleep(for:.milliseconds(250)); try check(stopped == Data(contentsOf:heartbeat),"Old tool survived clean switch")
        try check(await app.disconnect(),"Target cleanup failed")
        app = try workspace(); await app.start(); await app.select(codingSession)
        try check(app.viewed!.controller.draft == "Editor A remains" && app.viewed!.controller.recoveredDrafts.count == 1,"Stopped drafts did not survive restart")
        return ["runningHistoryBrowse":true,"explicitSwitchOnly":true,"oldToolStopped":true,"draftsSurvivedRestart":true]
    }
    await test("M2/relocation-read-only-boundary-and-new-cwd") {
        try check(await app.disconnect(),"Pre-move cleanup failed")
        let moved = work.appendingPathComponent("Project A moved"); try fm.moveItem(at:projectA,to:moved)
        await app.relocateProject(a,to:moved); await app.select(codingSession)
        let starts = instances.count
        let movedActivated = await app.activate(codingSession)
        try check(app.selectedProject?.id == a && app.viewed!.executionIssue != nil && !movedActivated && instances.count == starts,"Old history ran in wrong location")
        await app.createSession(in:a); let fresh = app.selected!.id
        try "require('node:fs').writeFileSync('actual-cwd',process.cwd());".write(to:moved.appendingPathComponent("cwd.cjs"),atomically:true,encoding:.utf8)
        app.viewed!.controller.draft = "Run only '\(paths.node)/node' cwd.cjs in bash. Reply briefly."
        await app.send(fresh); try await wait(90) { app.active?.phase == .idle || app.active?.connection != .connected }
        let actual = try String(contentsOf:moved.appendingPathComponent("actual-cwd"),encoding:.utf8)
        try check(URL(fileURLWithPath:actual).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath(),"Tool used old cwd")
        try check(await app.disconnect(),"Moved project cleanup failed")
        return ["stableProjectID":true,"oldHistoryNotRewritten":true,"wrongCwdBlocked":true,"newSessionToolCwd":actual]
    }
}
for mode in ["timeout","crash"] {
    await test("M2/\(mode)-restart-no-replay") {
        let isolated = work.appendingPathComponent(mode); try fm.createDirectory(at:isolated,withIntermediateDirectories:true)
        let executable = isolated.appendingPathComponent("fake-pi"); try fm.copyItem(at:repo.appendingPathComponent("Tools/M1Verification/Fixtures/fake-pi.py"),to:executable)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let url = isolated.appendingPathComponent("state/workspace.store")
        var runtime: PiRuntime?, starts = 0
        @MainActor func make() throws -> WorkspaceController {
            WorkspaceController(store:try SwiftDataWorkspaceStore(url:url),reader:PiHistoryReader(roots:[])) { project,_ in
                let value = PiRuntime(configuration:.init(executable:executable,nodeDirectory:URL(fileURLWithPath:paths.node),workspace:URL(fileURLWithPath:project.path),agentDirectory:auth,sessionDirectory:isolated.appendingPathComponent("sessions"),extensionFixture:URL(fileURLWithPath:mode)))
                runtime = value; starts += 1; return value
            }
        }
        var host = try make(); await host.start(); _ = await host.addProject(isolated); let id = host.selected!.id
        host.viewed!.controller.draft = "Uncertain input"; await host.send(id)
        if mode == "crash" {
            try await wait { fm.fileExists(atPath:isolated.appendingPathComponent("heartbeat").path) }
            await runtime!.terminateRuntimeForVerification(); try await wait { host.active?.connection == .disconnected }
        }
        try check(await host.disconnect(force:true),"Fault runtime cleanup failed")
        host = try make(); await host.start()
        try check(starts == 1 && host.activeID == nil && host.selected?.submissions.first?.needsReview == true,"Restart hid unknown input or reconnected")
        try check(try String(contentsOf:isolated.appendingPathComponent("prompt-count"),encoding:.utf8) == "x","Prompt automatically replayed")
        await host.send(id); try check(starts == 1,"Unreviewed record did not block sending")
        return ["runtimeStarts":starts,"promptCount":1,"unknownMarked":true,"noAutomaticReplay":true]
    }
}
_ = await app.disconnect(force:true)
try? fm.removeItem(at:auth)
try save(["runID":runID,"workspace":work.path,"realModelCalls":real,"results":results],"run.json")
print("Evidence: \(output.path)")
exit(results.contains { $0["status"] as? String == "fail" } ? 1 : 0)
