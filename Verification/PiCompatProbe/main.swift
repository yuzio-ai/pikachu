import Foundation
import Darwin
import ProcessSupervision

signal(SIGPIPE, SIG_IGN)
// Dedicated host-crash fixture. It deliberately never reaches the verification runner.
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--owner-fixture" {
    let fixture = CommandLine.arguments[2], cwd = URL(fileURLWithPath: CommandLine.arguments[3])
    let ready = URL(fileURLWithPath: CommandLine.arguments[4])
    let child = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", fixture, "--ignore-eof"], cwd: cwd,
                               environment: ProcessInfo.processInfo.environment, supervised: true)
    _ = try child.ok("spawn", ["ignoreTerm": true])
    let data = try JSONSerialization.data(withJSONObject: ["statusPath": child.supervisionStatusURL!.path])
    try data.write(to: ready, options: .atomic)
    while true { Thread.sleep(forTimeInterval: 1) }
}
let fm = FileManager.default
let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return fallback }
    return args[i + 1]
}
let suite = option("--suite", "local")
try require(["local", "extended", "real", "continuation", "agent-crash", "supervision", "all"].contains(suite), "Unknown suite")
let pi = option("--pi", fm.homeDirectoryForCurrentUser.appendingPathComponent("bin/pi").path)
let node = option("--node", fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node/v24.12.0/bin/node").path)
let provider = option("--provider", "openai"), model = option("--model", "gpt-6.1-sol")
let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + suite
let output = URL(fileURLWithPath: option("--output", projectRoot.appendingPathComponent(".verification-runs/pi-compat-probe/\(runID)").path))
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let work = fm.temporaryDirectory.appendingPathComponent("Pikachu-pi-compat-probe-\(UUID().uuidString)")
try fm.createDirectory(at: work, withIntermediateDirectories: true)
var results: [Record] = []
var clients: [RPCProcess] = []
let privateConfig = work.appendingPathComponent("private-config")
try fm.createDirectory(at: privateConfig, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let existingAuth = fm.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/auth.json")
if fm.fileExists(atPath: existingAuth.path) {
    let target = privateConfig.appendingPathComponent("auth.json")
    try fm.copyItem(at: existingAuth, to: target)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
}
var env = ProcessInfo.processInfo.environment
env["PI_CODING_AGENT_DIR"] = privateConfig.path
let proxy = option("--proxy", "")
if !proxy.isEmpty {
    env["HTTP_PROXY"] = proxy
    env["HTTPS_PROXY"] = proxy
    env["NODE_USE_ENV_PROXY"] = "1"
}

func save(_ value: Any, _ name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
}
@MainActor @discardableResult func command(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil) throws -> (Int32, String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    p.currentDirectoryURL = cwd; p.environment = environment ?? env
    p.standardOutput = out; p.standardError = out
    try p.run()
    let bytes = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: bytes, as: UTF8.self))
}
func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
@MainActor func test(_ id: String, _ body: () throws -> Record) {
    let start = Date()
    do {
        let evidence = try body()
        results.append(["case": id, "status": "pass", "seconds": Date().timeIntervalSince(start), "evidence": evidence])
        try? FileHandle.standardOutput.write(contentsOf: Data("PASS \(id)\n".utf8))
    } catch {
        results.append(["case": id, "status": "fail", "seconds": Date().timeIntervalSince(start), "error": String(describing: error)])
        try? FileHandle.standardOutput.write(contentsOf: Data("FAIL \(id): \(error)\n".utf8))
    }
    try? save(results, "results.json")
    try? FileHandle.standardOutput.synchronize()
}
@MainActor func make(_ name: String, extensionUI: Bool = false, customEnv: [String: String]? = nil, executable: String? = nil) throws -> RPCProcess {
    let cwd = work.appendingPathComponent(name)
    try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let sessions = cwd.appendingPathComponent("sessions")
    var flags = ["--mode", "rpc", "--provider", provider, "--model", model, "--thinking", "off",
                 "--session-dir", sessions.path, "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"]
    if extensionUI { flags += ["-e", projectRoot.appendingPathComponent("Verification/Fixtures/dialog-extension.ts").path] }
    var runtimeEnv = customEnv ?? env
    runtimeEnv["PI_CODING_AGENT_DIR"] = privateConfig.path
    let p = try RPCProcess(executable: executable ?? pi, arguments: flags, cwd: cwd, environment: runtimeEnv, supervised: !args.contains("--unsupervised"))
    clients.append(p)
    _ = try p.ok("get_state", timeout: 15)
    return p
}
func settled(_ p: RPCProcess, after: Int, timeout: Double = 180) throws {
    _ = try p.event("agent_settled", after: after, timeout: timeout)
    let failed = p.allRecords.dropFirst(after).contains {
        guard $0["type"] as? String == "message_end", let m = $0["message"] as? Record else { return false }
        return m["stopReason"] as? String == "error"
    }
    try require(!failed, "Provider/assistant error after acceptance (see sanitized message error)")
}
func assistantErrors(_ p: RPCProcess) -> [String] {
    p.allRecords.compactMap { r in
        guard r["type"] as? String == "message_end", let m = r["message"] as? Record,
              m["stopReason"] as? String == "error" else { return nil }
        // Never emit provider response bodies, headers, or credentials.
        let text = m["errorMessage"] as? String ?? "error"
        if text.contains("401") { return "authentication/401" }
        if text.contains("429") { return "rate-limit/429" }
        if text.lowercased().contains("api key") { return "credential unavailable" }
        return "provider error (detail omitted from diagnostics)"
    }
}

test("pi-compat/version") {
    let version = try command(pi, ["--version"])
    let piVersion = version.1.trimmingCharacters(in: .whitespacesAndNewlines)
    try require(version.0 == 0 && !piVersion.isEmpty, "Could not read Pi version")
    let swift = try command("/usr/bin/swift", ["--version"])
    let os = try command("/usr/bin/sw_vers", [])
    return ["piVersion": piVersion, "swift": swift.1, "os": os.1,
            "piEntry": pi, "nodeEntry": node, "temporaryWorkspace": work.path]
}

if suite == "local" || suite == "all" {
    test("pi-compat/launch-environments") {
        let normal = try make("normal")
        let a = try normal.ok("get_state")
        try normal.close()
        let minimal = ["HOME": fm.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        var missingNode = false
        do { _ = try make("space path minimal", customEnv: minimal) }
        catch {
            let diagnostic = String(describing: error) + " " + (clients.last?.diagnosticText ?? "")
            missingNode = diagnostic.contains("Runtime dependency missing: node") || (diagnostic.contains("node") && diagnostic.contains("No such file"))
        }
        try require(missingNode, "Expected missing node under GUI-like PATH")
        var configured = minimal
        configured["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let p = try make("space path configured", customEnv: configured)
        _ = try p.ok("get_state"); try p.close()
        do {
            _ = try RPCProcess(executable: "/nonexistent/pi", arguments: [], cwd: work, environment: env)
            throw ProbeError.failure("Missing executable unexpectedly launched")
        } catch let error as ProbeError { throw error } catch { }
        // Invoke the installed node entry directly with no node on PATH to prove dependency classification.
        let broken = try command("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin", "node", "--version"])
        try require(broken.0 != 0, "Missing-node fixture should fail")
        return ["model": (a["model"] as? Record)?["id"] ?? NSNull(), "normal": normal.summary(), "configuredGUIPath": p.summary(), "bareGUIPathMissingNode": missingNode, "missingDependencyExit": broken.0]
    }
    test("pi-compat/real-correlation-and-parse-error") {
        let p = try make("correlation")
        defer { try? p.close() }
        let ids = try (0..<20).map { _ in try p.submit("get_state") }
        for id in ids.reversed() { _ = try p.response(id) }
        let offset = p.count
        try p.raw(Data("{not json}\n".utf8))
        let parsed = try p.wait(after: offset) { $0["command"] as? String == "parse" }
        try require(parsed["success"] as? Bool == false, "Malformed input must fail")
        _ = try p.ok("get_state")
        return ["requests": ids.count, "parseRejected": true, "summary": p.summary()]
    }
    test("pi-compat/configuration-and-empty-stats") {
        let p = try make("configuration"); defer { try? p.close() }
        let models = try p.ok("get_available_models")
        let available = models["models"] as? [Record] ?? []
        try require(available.contains { $0["provider"] as? String == provider && $0["id"] as? String == model }, "Configured model missing")
        _ = try p.ok("set_model", ["provider": provider, "modelId": model])
        let levels = try p.ok("get_available_thinking_levels")
        guard let selectedLevel = (levels["levels"] as? [String])?.first else { throw ProbeError.failure("No thinking levels returned") }
        _ = try p.ok("set_thinking_level", ["level": selectedLevel])
        let before = try p.ok("get_state")
        try require(before["thinkingLevel"] as? String == selectedLevel, "Thinking level readback mismatch")
        let bad = try p.request("set_model", ["provider": "fixture-invalid", "modelId": "fixture-invalid"])
        try require(bad["success"] as? Bool == false, "Invalid model accepted")
        let after = try p.ok("get_state")
        try require((before["model"] as? Record)?["id"] as? String == (after["model"] as? Record)?["id"] as? String, "Rejected model changed state")
        let stats = try p.ok("get_session_stats")
        return ["modelCount": available.count, "thinkingLevels": levels, "effectiveThinkingLevel": before["thinkingLevel"] ?? NSNull(), "stats": stats, "invalidModelRejected": true]
    }
    test("pi-compat/dialogs-handled-timeout-switch-cancel") {
        let p = try make("dialogs", extensionUI: true); defer { try? p.close() }
        let offset = p.count
        let id = try p.submit("prompt", ["message": "/fixture-dialogs"])
        var cursor = offset, methods: [String] = []
        for expected in ["select", "confirm", "input", "editor"] {
            let r = try p.wait(after: cursor) { $0["type"] as? String == "extension_ui_request" && $0["method"] as? String == expected }
            cursor = p.count
            methods.append(expected)
            try p.send(["type": "extension_ui_response", "id": r["id"]!, "cancelled": true])
        }
        let response = try p.response(id)
        try require((response["data"] as? Record)?["disposition"] as? String == "handled", "Extension must be handled")
        let timeout = try p.ok("prompt", ["message": "/fixture-timeout"])
        try require(timeout["disposition"] as? String == "handled", "Timed dialog not handled")
        let before = try p.ok("get_state")
        let switchOffset = p.count
        let switchID = try p.submit("new_session")
        let r = try p.wait(after: switchOffset) { $0["method"] as? String == "confirm" }
        try p.send(["type": "extension_ui_response", "id": r["id"]!, "cancelled": true])
        let cancelled = try p.response(switchID)
        try require((cancelled["data"] as? Record)?["cancelled"] as? Bool == true, "Switch cancellation missing")
        let after = try p.ok("get_state")
        try require(before["sessionId"] as? String == after["sessionId"] as? String, "Cancelled switch changed session")
        return ["methodsCancelled": methods, "handled": true, "agentSideTimeout": true, "switchCancelled": true, "summary": p.summary()]
    }
    test("pi-compat/late-response-deadline-and-instance") {
        let p = try make("late", extensionUI: true)
        let id = try p.submit("prompt", ["message": "/fixture-delay"])
        var timedOut = false
        do { _ = try p.response(id, timeout: 0.02) } catch { timedOut = true }
        try require(timedOut, "Deadline fixture did not time out")
        _ = try p.response(id)
        let oldInstance = p.instanceID; try p.close()
        let q = try make("late replacement"); defer { try? q.close() }
        try require(q.instanceID != oldInstance && !q.allRecords.contains { $0["id"] as? String == id }, "Old response polluted new instance")
        return ["deadlineUnknown": timedOut, "lateResponseRecoveredWithoutResend": true, "isolatedInstances": true]
    }
    for iteration in 1...3 {
        test("pi-compat/direct-bash-stop-\(iteration)") {
            let p = try make("direct stop \(iteration)"); defer { try? p.close() }
            let cwd = p.process.currentDirectoryURL!
            try write("const fs=require('node:fs');setInterval(()=>fs.appendFileSync('heartbeat','x'),50);", cwd.appendingPathComponent("heartbeat.cjs"))
            let offset = p.count
            let id = try p.submit("bash", ["command": "'\(node)' heartbeat.cjs"])
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path) && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            try require(fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path), "Tool did not start")
            _ = try p.ok("abort_bash", timeout: 15)
            let response = try p.response(id, timeout: 15)
            let data = response["data"] as? Record ?? [:]
            try require(data["cancelled"] as? Bool == true, "Direct bash not cancelled")
            let first = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.3)
            let last = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            try require(first == last, "Heartbeat continued after abort_bash")
            return ["heartbeatStable": true, "records": p.count - offset, "note": "Direct RPC bash uses abort_bash, not agent abort"]
        }
        test("pi-compat/crash-idle-and-reconnect-\(iteration)") {
            let p = try make("crash \(iteration)", extensionUI: true)
            let id = try p.submit("prompt", ["message": "/fixture-delay"])
            p.crash()
            var ended = false
            do { _ = try p.response(id) } catch { ended = true }
            try require(ended, "Pending request did not end after crash")
            try? p.close()
            let q = try make("crash replacement \(iteration)"); defer { try? q.close() }
            try require(!q.allRecords.contains { $0["type"] as? String == "agent_start" }, "Reconnect started work")
            return ["pendingEnded": true, "newInstance": q.instanceID, "automaticReplay": false]
        }
    }
}

if suite == "supervision" || suite == "all" {
    let fixture = projectRoot.appendingPathComponent("Verification/Fixtures/process-tree.py").path
    func fixturePIDs(_ cwd: URL) throws -> [ProcessIdentity] {
        try ["child", "leaf"].compactMap { name in
            let text = try String(contentsOf: cwd.appendingPathComponent(name + ".pid"), encoding: .utf8)
            return ProcessIdentity.read(Int32(text)!)
        }
    }
    func fixtureStopped(_ cwd: URL, _ known: [ProcessIdentity]) throws -> Bool {
        let before = try ["child", "leaf"].map { try Data(contentsOf: cwd.appendingPathComponent($0 + ".heartbeat")).count }
        Thread.sleep(forTimeInterval: 0.3)
        let after = try ["child", "leaf"].map { try Data(contentsOf: cwd.appendingPathComponent($0 + ".heartbeat")).count }
        return before == after && known.allSatisfy { identity in
            guard let current = ProcessIdentity.read(identity.pid), identity.sameProcess(as: current) else { return true }
            return !current.live
        }
    }
    func fixtureRuntime(_ name: String, ignoreTerm: Bool = false) throws -> RPCProcess {
        let cwd = work.appendingPathComponent(name)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", fixture], cwd: cwd, environment: env, supervised: true)
        clients.append(p)
        _ = try p.ok("spawn", ["ignoreTerm": ignoreTerm])
        return p
    }
    for i in 1...3 {
        test("pi-compat/supervision/nested-detached-crash-\(i)") {
            let p = try fixtureRuntime("nested \(i)", ignoreTerm: true), cwd = p.process.currentDirectoryURL!
            let known = try fixturePIDs(cwd)
            defer { known.forEach { _ = $0.signal(SIGKILL) }; try? p.close() }
            p.crash(); try p.close()
            try require(try fixtureStopped(cwd, known), "Detached descendants survived watchdog")
            return ["nestedDescendantsStopped": true, "supervision": p.supervisionStatus]
        }
        test("pi-compat/supervision/host-SIGKILL-\(i)") {
            let cwd = work.appendingPathComponent("host crash \(i)")
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            let ready = cwd.appendingPathComponent("ready.json"), host = Process()
            host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            host.arguments = ["--owner-fixture", fixture, cwd.path, ready.path]
            host.environment = env; host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
            try host.run()
            defer { if host.isRunning { host.terminate() } }
            let deadline = Date().addingTimeInterval(8)
            while !fm.fileExists(atPath: ready.path) && host.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! Record
            let statusURL = URL(fileURLWithPath: info["statusPath"] as! String)
            let known = try fixturePIDs(cwd)
            defer { known.forEach { _ = $0.signal(SIGKILL) } }
            kill(host.processIdentifier, SIGKILL)
            let cleanupDeadline = Date().addingTimeInterval(5)
            var status: Record = [:]
            repeat {
                if let bytes = try? Data(contentsOf: statusURL), let r = try? JSONSerialization.jsonObject(with: bytes) as? Record { status = r }
                if status["state"] as? String == "clean" { break }
                Thread.sleep(forTimeInterval: 0.02)
            } while Date() < cleanupDeadline
            try require(status["state"] as? String == "clean" && status["reason"] as? String == "ownerExited", "Independent watchdog did not clean host crash")
            try require(try fixtureStopped(cwd, known), "Host crash left descendants")
            return ["hostSIGKILL": true, "supervision": status]
        }
    }
    test("pi-compat/supervision/retains-lineage-after-reparenting") {
        let cwd = work.appendingPathComponent("lineage only")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let p = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", fixture], cwd: cwd, environment: env, supervised: true)
        clients.append(p)
        defer { try? p.close() }
        _ = try p.ok("spawn_lineage_only")
        let pidText = try String(contentsOf: cwd.appendingPathComponent("leaf.pid"), encoding: .utf8)
        guard let pid = Int32(pidText), pid > 0, let leaf = ProcessIdentity.read(pid), leaf.live else {
            throw ProbeError.failure("Lineage-only leaf did not survive reparenting")
        }
        defer { _ = leaf.signal(SIGKILL) } // Rescue only, after the independent assertion.
        p.crash(); try p.close()
        let surviving = ProcessIdentity.read(pid).map { $0.sameProcess(as: leaf) && $0.live } ?? false
        try require(!surviving && p.supervisionStatus["state"] as? String == "clean", "Unmarked reparented leaf escaped cleanup")
        return ["lineageOnlyLeafStopped": true, "supervision": p.supervisionStatus]
    }
    test("pi-compat/supervision/unrelated-and-second-instance-survive") {
        let a = try fixtureRuntime("instance A"), b = try fixtureRuntime("instance B")
        let identitiesA = try fixturePIDs(a.process.currentDirectoryURL!), identitiesB = try fixturePIDs(b.process.currentDirectoryURL!)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]; try unrelated.run()
        defer {
            try? b.close(); identitiesA.forEach { _ = $0.signal(SIGKILL) }; identitiesB.forEach { _ = $0.signal(SIGKILL) }
            if unrelated.isRunning { unrelated.terminate() }
        }
        a.crash(); try a.close()
        try require(try fixtureStopped(a.process.currentDirectoryURL!, identitiesA), "A descendants survived")
        try require(unrelated.isRunning && identitiesB.allSatisfy { ProcessIdentity.read($0.pid)?.live == true }, "Cleanup killed another instance or unrelated process")
        _ = try b.ok("get_state")
        try b.close()
        try require(try fixtureStopped(b.process.currentDirectoryURL!, identitiesB), "Normal close did not clean detached descendants")
        return ["unrelatedSurvived": true, "secondInstanceSurvived": true, "normalCloseClean": true]
    }
    test("pi-compat/supervision/supervision-unavailable-fails-closed") {
        var failing = env; failing["PIKACHU_SUPERVISION_FAIL_SCAN"] = "1"
        let cwd = work.appendingPathComponent("failed supervision"); try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        var rejected = false
        do { _ = try RPCProcess(executable: "/usr/bin/python3", arguments: ["-u", fixture], cwd: cwd, environment: failing, supervised: true) }
        catch { rejected = true }
        try require(rejected && !fm.fileExists(atPath: cwd.appendingPathComponent("child.pid").path), "Supervision failure allowed work")
        return ["startupRejected": true, "taskNotStarted": true]
    }
    test("pi-compat/supervision/watchdog-loss-blocks-release") {
        let p = try fixtureRuntime("watchdog loss")
        let known = try fixturePIDs(p.process.currentDirectoryURL!)
        defer { p.crash(); known.forEach { _ = $0.signal(SIGKILL) } }
        kill(p.process.processIdentifier, SIGKILL)
        let until = Date().addingTimeInterval(2)
        while p.process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        var closeRejected = false, sendRejected = false
        do { try p.close() } catch { closeRejected = true }
        do { _ = try p.ok("get_state") } catch { sendRejected = true }
        try require(closeRejected && sendRejected && p.supervisionStatus["state"] as? String != "clean", "Watchdog loss falsely released slot")
        return ["slotReleaseRejected": true, "newCommandsRejected": true, "testOnlyEmergencyCleanup": true]
    }
    test("pi-compat/supervision/watchdog-SIGTERM-cleans-tree") {
        let p = try fixtureRuntime("watchdog TERM", ignoreTerm: true)
        let known = try fixturePIDs(p.process.currentDirectoryURL!)
        defer { known.forEach { _ = $0.signal(SIGKILL) }; try? p.close() }
        p.process.terminate()
        try p.close()
        try require(try fixtureStopped(p.process.currentDirectoryURL!, known), "Watchdog TERM left descendants")
        return ["signalHandled": true, "supervision": p.supervisionStatus]
    }
}

if suite == "extended" || suite == "all" {
    test("pi-compat/branch-compaction-file-read") {
        let p = try make("history"); defer { try? p.close() }
        let file = work.appendingPathComponent("history-v3.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let records: [Record] = [
            ["type": "session", "version": 3, "id": UUID().uuidString, "timestamp": timestamp, "cwd": p.process.currentDirectoryURL!.path],
            ["type": "message", "id": "a", "parentId": NSNull(), "timestamp": timestamp, "message": ["role": "user", "content": "ROOT_SUMMARIZED", "timestamp": 1]],
            ["type": "message", "id": "b", "parentId": "a", "timestamp": timestamp, "message": ["role": "user", "content": "ABANDONED_BRANCH", "timestamp": 2]],
            ["type": "message", "id": "c", "parentId": "a", "timestamp": timestamp, "message": ["role": "user", "content": "KEPT_BRANCH", "timestamp": 3]],
            ["type": "compaction", "id": "d", "parentId": "c", "timestamp": timestamp, "summary": "PROBE SUMMARY", "firstKeptEntryId": "c", "tokensBefore": 100]
        ]
        var bytes = Data()
        for r in records { bytes.append(try JSONSerialization.data(withJSONObject: r)); bytes.append(10) }
        try bytes.write(to: file)
        let history = try HistoryProbe.read(bytes)
        try require(history.branch.compactMap { $0["id"] as? String } == ["a", "c", "d"], "Active branch flattened")
        try require(try Data(contentsOf: file) == bytes, "Read-only history probe modified fixture")
        _ = try p.ok("switch_session", ["sessionPath": file.path])
        let messages = try p.ok("get_messages")
        let context = String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
        try require(context.contains("PROBE SUMMARY") && context.contains("KEPT_BRANCH") && !context.contains("ABANDONED_BRANCH") && !context.contains("ROOT_SUMMARIZED"), "Compacted context differs from expected branch")
        let afterRestore = try Data(contentsOf: file)
        try require(afterRestore.starts(with: bytes), "Restore rewrote existing entries")
        let entries = try p.ok("get_entries"), tree = try p.ok("get_tree")
        try save(["context": messages, "entries": entries, "tree": tree], "branch-compaction.json")
        // Partial and corrupt copies must never be used as writable execution sessions.
        let partial = try HistoryProbe.read(bytes + Data("{partial".utf8))
        try require(partial.incompleteTail, "Incomplete tail not reported")
        var badRejected = false
        do { _ = try HistoryProbe.read(bytes + Data("bad\n".utf8)) } catch { badRejected = true }
        try require(badRejected, "Corrupt complete record accepted")
        return ["activeBranch": ["a", "c", "d"], "compactionContextVerifiedWithPi": true, "readOnlyProbeUnchanged": true, "restoreAppendedConfiguration": afterRestore.count > bytes.count, "partialTailDetected": true]
    }
    for iteration in 1...3 {
        test("pi-compat/EOF-active-tool-\(iteration)") {
            let p = try make("EOF active \(iteration)")
            let cwd = p.process.currentDirectoryURL!
            try write("const fs=require('node:fs');fs.writeFileSync('pid',String(process.pid));setInterval(()=>fs.appendFileSync('heartbeat','x'),50);", cwd.appendingPathComponent("heartbeat.cjs"))
            _ = try p.submit("bash", ["command": "'\(node)' heartbeat.cjs"])
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path) && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            let pid = Int32(try String(contentsOf: cwd.appendingPathComponent("pid"), encoding: .utf8))!
            let fixtureIdentity = ProcessIdentity.read(pid)
            defer { _ = fixtureIdentity?.signal(SIGKILL) }
            try p.close()
            let first = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.3)
            try require(first == (try Data(contentsOf: cwd.appendingPathComponent("heartbeat"))).count, "EOF left active descendant")
            return ["EOFStoppedTool": true, "summary": p.summary()]
        }
        test("pi-compat/crash-active-tool-\(iteration)") {
            let p = try make("crash active \(iteration)")
            let cwd = p.process.currentDirectoryURL!
            try write("const fs=require('node:fs');fs.writeFileSync('pid',String(process.pid));setInterval(()=>fs.appendFileSync('heartbeat','x'),50);", cwd.appendingPathComponent("heartbeat.cjs"))
            let id = try p.submit("bash", ["command": "'\(node)' heartbeat.cjs"])
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path) && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            let pid = Int32(try String(contentsOf: cwd.appendingPathComponent("pid"), encoding: .utf8))!
            let fixtureIdentity = ProcessIdentity.read(pid)
            defer { _ = fixtureIdentity?.signal(SIGKILL); try? p.close() }
            p.crash()
            var pendingEnded = false
            do { _ = try p.response(id, timeout: 2) } catch { pendingEnded = true }
            let first = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.3)
            let last = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            let survived = last > first
            _ = fixtureIdentity?.signal(SIGKILL)
            Thread.sleep(forTimeInterval: 0.15)
            let stopped = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.2)
            let cleaned = stopped == (try Data(contentsOf: cwd.appendingPathComponent("heartbeat"))).count
            try save(["pendingEnded": pendingEnded, "descendantSurvivedPiSIGKILL": survived, "fixtureFallbackUsed": survived, "heartbeatStopped": cleaned, "hostSupervision": p.supervisionStatus, "summary": p.summary()], "crash-active-\(iteration).json")
            try require(cleaned, "Fixture process cleanup failed")
            try require(pendingEnded && !survived && p.supervisionStatus["state"] as? String == "clean", "Pi SIGKILL cleanup unconfirmed")
            return ["pendingEnded": pendingEnded, "descendantSurvived": survived]
        }
    }
    test("pi-compat/large-real-bash-output") {
        let p = try make("large output"); defer { try? p.close() }
        let offset = p.count
        let data = try p.ok("bash", ["command": "'\(node)' -e \"process.stdout.write('x'.repeat(10*1024*1024))\""], timeout: 15)
        _ = try p.ok("get_state")
        return ["responseTruncated": data["truncated"] ?? NSNull(), "streamChunks": p.allRecords.dropFirst(offset).filter { $0["type"] as? String == "bash_execution_update" }.count,
                "responsiveAfterOutput": true, "summary": p.summary()]
    }
}

if suite == "agent-crash" || suite == "all" {
    for iteration in 1...3 {
        test("pi-compat/agent-crash-active-tool-\(iteration)") {
            let p = try make("agent crash active \(iteration)")
            let cwd = p.process.currentDirectoryURL!
            try write("const fs=require('node:fs');fs.writeFileSync('pid',String(process.pid));setInterval(()=>fs.appendFileSync('heartbeat','x'),50);", cwd.appendingPathComponent("heartbeat.cjs"))
            let offset = p.count
            _ = try p.ok("prompt", ["message": "Crash fixture: run exactly '\(node)' heartbeat.cjs with bash timeout 60 seconds. Do not use any other tool. Reply DONE only after bash finishes."], timeout: 15)
            _ = try p.event("tool_execution_start", after: offset, timeout: 90)
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path) && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            let pid = Int32(try String(contentsOf: cwd.appendingPathComponent("pid"), encoding: .utf8))!
            let fixtureIdentity = ProcessIdentity.read(pid)
            defer { _ = fixtureIdentity?.signal(SIGKILL); try? p.close() }
            p.crash()
            let exitDeadline = Date().addingTimeInterval(5)
            while p.process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
            let first = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.3)
            let survived = first != (try Data(contentsOf: cwd.appendingPathComponent("heartbeat"))).count
            _ = fixtureIdentity?.signal(SIGKILL)
            Thread.sleep(forTimeInterval: 0.15)
            let stopped = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.2)
            let cleaned = stopped == (try Data(contentsOf: cwd.appendingPathComponent("heartbeat"))).count
            try save(["agentTool": true, "piExited": !p.process.isRunning, "descendantSurvivedPiSIGKILL": survived, "fixtureFallbackUsed": survived, "heartbeatStopped": cleaned, "hostSupervision": p.supervisionStatus, "summary": p.summary()], "agent-crash-active-\(iteration).json")
            try require(cleaned, "Agent fixture cleanup failed")
            try require(!survived && p.supervisionStatus["state"] as? String == "clean", "Agent descendant cleanup unconfirmed")
            return ["agentTool": true, "descendantSurvived": survived]
        }
    }
}

if suite == "continuation" || suite == "all" {
    test("pi-compat/follow-up-delivery-and-settled") {
        let p = try make("continuation"); defer { try? p.close() }
        let offset = p.count
        _ = try p.ok("prompt", ["message": "Continuation fixture: use bash to run sleep 3, then reply INITIAL. No other tools."], timeout: 15)
        _ = try p.event("tool_execution_start", after: offset, timeout: 90)
        _ = try p.ok("prompt", ["message": "PROBE_STEER: Reply STEER in your next reply.", "streamingBehavior": "steer"])
        _ = try p.ok("prompt", ["message": "PROBE_FOLLOW: Reply FOLLOW only.", "streamingBehavior": "followUp"])
        try settled(p, after: offset)
        let events = Array(p.allRecords.dropFirst(offset))
        let messages = try p.ok("get_messages")["messages"] as? [Record] ?? []
        let users = messages.filter { $0["role"] as? String == "user" }
        let encoded = try users.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        guard let steerIndex = encoded.firstIndex(where: { $0.contains("PROBE_STEER") }), let followIndex = encoded.firstIndex(where: { $0.contains("PROBE_FOLLOW") }) else { throw ProbeError.failure("Queued messages not delivered") }
        try require(steerIndex < followIndex, "follow-up delivered before steering")
        let types = events.compactMap { $0["type"] as? String }
        try require(types.lastIndex(of: "agent_end")! < types.lastIndex(of: "agent_settled")!, "Settled before final low-level end")
        try save(events, "continuation-protocol.json")
        return ["steeringBeforeFollowUp": true, "agentEndCount": types.filter { $0 == "agent_end" }.count, "settledCount": types.filter { $0 == "agent_settled" }.count, "summary": p.summary()]
    }
}

if suite == "real" || suite == "all" {
    for iteration in 1...3 {
        test("pi-compat/coding-\(iteration)") {
            let p = try make("coding \(iteration)"); defer { try? p.close() }
            let cwd = p.process.currentDirectoryURL!
            _ = try command("/usr/bin/git", ["init", "-q"], cwd: cwd)
            try write("exports.add = (a,b) => a-b;\n", cwd.appendingPathComponent("sum.cjs"))
            let fixtureTest = "const {test}=require('node:test');const assert=require('node:assert/strict');const {add}=require('./sum.cjs');test('adds',()=>{assert.equal(add(2,3),5);assert.equal(add(-1,1),0)});\n"
            try write(fixtureTest, cwd.appendingPathComponent("sum.test.cjs"))
            let baseline = try command(node, ["--test", "sum.test.cjs"], cwd: cwd)
            try require(baseline.0 != 0, "Fixture must fail before task")
            let offset = p.count
            let accepted = try p.ok("prompt", ["message": "Isolated coding fixture. Only work in the current directory. Read sum.cjs and sum.test.cjs, fix the add function, then run '\(node)' --test sum.test.cjs using bash. Do not change the test. Reply briefly with the result."], timeout: 15)
            try require(accepted["disposition"] as? String == "started", "Prompt not started")
            do { try settled(p, after: offset) } catch {
                try save(["summary": p.summary(), "errors": assistantErrors(p)], "coding-\(iteration)-failure.json")
                throw error
            }
            let verified = try command(node, ["--test", "sum.test.cjs"], cwd: cwd)
            try require(verified.0 == 0, "Independent test failed after task")
            try require(try String(contentsOf: cwd.appendingPathComponent("sum.test.cjs"), encoding: .utf8) == fixtureTest, "Agent modified protected test fixture")
            let events = Array(p.allRecords.dropFirst(offset))
            try require(events.contains { $0["type"] as? String == "tool_execution_start" } && events.contains { $0["type"] as? String == "message_update" }, "Missing actual tool/stream events")
            var projection = MessageProjection()
            events.forEach { projection.apply($0) }
            try require(!projection.messages.isEmpty, "No completed messages")
            _ = try p.ok("set_session_name", ["name": "Compat coding \(iteration)"])
            let state = try p.ok("get_state"), stats = try p.ok("get_session_stats")
            guard let sessionFile = state["sessionFile"] as? String else { throw ProbeError.failure("No persisted session file") }
            let original = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
            try p.close()
            let q = try make("coding \(iteration)"); defer { try? q.close() }
            _ = try q.ok("switch_session", ["sessionPath": sessionFile])
            let restored = try q.ok("get_state")
            try require(restored["sessionId"] as? String == state["sessionId"] as? String, "Wrong restored session")
            let messages = try q.ok("get_messages")
            try require(!(messages["messages"] as? [Record] ?? []).isEmpty, "Restored history empty")
            try require(!q.allRecords.contains { $0["type"] as? String == "agent_start" }, "Restore triggered inference")
            try save(events, "coding-\(iteration)-protocol.json")
            try original.write(to: output.appendingPathComponent("coding-\(iteration)-session.jsonl"))
            try write(verified.1, output.appendingPathComponent("coding-\(iteration)-test.txt"))
            return ["beforeTestExit": baseline.0, "afterTestExit": verified.0, "stats": stats,
                    "sessionRestored": true, "summary": p.summary()]
        }
        test("pi-compat/agent-stop-queue-\(iteration)") {
            let p = try make("agent stop \(iteration)"); defer { try? p.close() }
            let cwd = p.process.currentDirectoryURL!
            try write("const fs=require('node:fs');setInterval(()=>fs.appendFileSync('heartbeat','x'),50);", cwd.appendingPathComponent("heartbeat.cjs"))
            let offset = p.count
            _ = try p.ok("prompt", ["message": "Stop fixture. Run exactly '\(node)' heartbeat.cjs with bash timeout 60 seconds. Do not run any other tool. After it finishes reply DONE."], timeout: 15)
            _ = try p.event("tool_execution_start", after: offset, timeout: 90)
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path) && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            try require(fm.fileExists(atPath: cwd.appendingPathComponent("heartbeat").path), "Agent heartbeat tool not started")
            let steer = "Probe steer \(iteration): say STEER after this tool."
            let follow = "Probe follow \(iteration): say FOLLOW only when current task ends."
            let a = try p.ok("prompt", ["message": steer, "streamingBehavior": "steer"])
            let b = try p.ok("prompt", ["message": follow, "streamingBehavior": "followUp"])
            try require(a["disposition"] as? String == "queued" && b["disposition"] as? String == "queued", "Expected queued messages")
            let cleared = try p.ok("clear_queue")
            try require(cleared["steering"] as? [String] == [steer] && cleared["followUp"] as? [String] == [follow], "Cleared queue mismatch")
            let stopStart = Date()
            _ = try p.ok("abort", timeout: 15)
            _ = try p.event("agent_settled", after: offset, timeout: 15)
            let first = try Data(contentsOf: cwd.appendingPathComponent("heartbeat")).count
            Thread.sleep(forTimeInterval: 0.5)
            try require(first == (try Data(contentsOf: cwd.appendingPathComponent("heartbeat"))).count, "Agent tool continued after abort")
            let state = try p.ok("get_state")
            try require(state["isStreaming"] as? Bool == false && state["pendingMessageCount"] as? Int == 0, "Not idle with empty queue")
            try save(Array(p.allRecords.dropFirst(offset)), "agent-stop-\(iteration)-protocol.json")
            return ["cleared": cleared, "stopSeconds": Date().timeIntervalSince(stopStart), "heartbeatStable": true, "summary": p.summary()]
        }
    }
}

for p in clients where p.process.isRunning { try? p.close() }
try? fm.removeItem(at: privateConfig)
try save(clients.map { $0.trace() }, "timelines.json")
try save(["runID": runID, "suite": suite, "pi": pi, "provider": provider, "model": model,
          "workspace": work.path, "results": results], "run.json")
print("Evidence: \(output.path)")
exit(results.contains { $0["status"] as? String == "fail" } ? 1 : 0)
