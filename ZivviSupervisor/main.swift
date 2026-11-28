import Foundation
import Darwin
import ProcessSupervision
import CProcessInspection

// Independent watchdog; survives the RPC host and never consumes protocol stdin.
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--relaunch-app", let parent = Int32(args[2]), parent > 1 {
    // The old instance must release its workspace lock before Launch Services reopens it.
    while getppid() == parent { Thread.sleep(forTimeInterval: 0.05) }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // Request a new instance so Launch Services delivers argv even when
    // another copy of Zivvi owns a different workspace.
    let directory = FileManager.default.currentDirectoryPath
    open.arguments = ["-n", "-a", args[3], "--env", "ZIVVI_RELAUNCH_DIRECTORY=\(directory)"]
    if args.count > 4 { open.arguments?.append(contentsOf: ["--args"] + args.dropFirst(4)) }
    do {
        try open.run()
        open.waitUntilExit()
        exit(open.terminationStatus)
    } catch {
        exit(70)
    }
}
guard args.count >= 6, ["--", "--version-probe", "--one-shot", "--terminal", "--terminal-login", "--quota-probe"].contains(args[4]) else { exit(64) }
let quotaProbe = args[4] == "--quota-probe"
let oneShot = args[4] == "--one-shot" || args[4] == "--version-probe" || quotaProbe
let terminalLogin = args[4] == "--terminal-login"
let terminal = args[4] == "--terminal" || terminalLogin
let statusURL = URL(fileURLWithPath: args[1]), token = args[2]
guard let ownerPID = Int32(args[3]), ownerPID > 1 else { exit(64) }
zv_install_signal_handlers()
let owner = ProcessIdentity.read(ownerPID)
var environment = ProcessInfo.processInfo.environment
environment["ZIVVI_EXECUTION_TOKEN"] = token
let rootMode: SupervisedProcess.SpawnMode = terminalLogin ? .terminalLogin : (quotaProbe ? .ownProcessGroup : .standard)
let root = SupervisedProcess(mode: rootMode, executable: args[5],
                            arguments: Array(args.dropFirst(6)), environment: environment)
var owned: [Int32: ProcessIdentity] = [:]
var signalsSent = 0, sweepCount = 0
@MainActor func status(_ state: String, _ reason: String = "", _ remaining: Int? = nil) {
    var record: Record = ["state": state, "reason": reason, "runtimePID": root.processIdentifier,
                          "supervisionID": statusURL.deletingLastPathComponent().lastPathComponent,
                          "supervisorPID": getpid(), "ownedIdentities": owned.count,
                          "signalsSent": signalsSent, "sweeps": sweepCount, "remaining": remaining ?? -1]
    if state == "clean", !root.isRunning, terminal || (oneShot && reason == "runtimeExited"),
       let result = root.termination {
        record["runtimeExitStatus"] = result.code
        if terminal { record["runtimeExitBySignal"] = result.bySignal }
    }
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        try? data.write(to: statusURL, options: .atomic)
    }
}
@MainActor func sweep() throws -> [ProcessIdentity] {
    if environment["ZIVVI_SUPERVISION_FAIL_SCAN"] == "1" { throw ProbeError.failure("Injected enumeration failure") }
    var snapshot = try ProcessIdentity.snapshot()
    let snapshotPIDs = Set(snapshot.map(\.pid))
    var unresolved: [ProcessIdentity] = []
    for known in owned.values where !snapshotPIDs.contains(known.pid) {
        // Enumeration and per-PID reads are not atomic. Re-read identities rather
        // than treating a normal exit/reap between the two operations as failure.
        if let current = ProcessIdentity.read(known.pid) { snapshot.append(current) }
        else if known.pid == root.processIdentifier && !root.isRunning { continue }
        else if kill(known.pid, 0) == 0 || errno != ESRCH { unresolved.append(known) }
    }
    for entry in try ProcessIdentity.marked(snapshot, token: token) { owned[entry.pid] = entry }
    if let group = root.processGroupID {
        for entry in snapshot where entry.live && getpgid(entry.pid) == group {
            owned[entry.pid] = entry
        }
    }
    // Also retain observed lineage if a child later clears its environment.
    var changed = true
    while changed {
        changed = false
        for entry in snapshot where owned[entry.pid] == nil {
            if let parent = owned[entry.parent], let currentParent = ProcessIdentity.read(parent.pid), parent.sameProcess(as: currentParent) {
                owned[entry.pid] = entry; changed = true
            }
        }
    }
    sweepCount += 1
    return snapshot.filter { entry in entry.live && owned[entry.pid]?.sameProcess(as: entry) == true } + unresolved
}
do {
    if terminalLogin {
        do {
            var agentEnvironment = try TerminalLoginEnvironment.receive(in: statusURL.deletingLastPathComponent()) {
                zv_stop_requested() == 0 && getppid() == ownerPID
                    && ProcessIdentity.read(ownerPID).map { owner?.sameProcess(as: $0) == true } == true
            }
            agentEnvironment["ZIVVI_EXECUTION_TOKEN"] = token
            guard zv_stop_requested() == 0 else { throw CancellationError() }
            try root.run(environment: agentEnvironment)
        } catch {
            // No terminal child was spawned if transfer or posix_spawn failed.
            status("clean", error is CancellationError ? "supervisorStopRequested" : "terminalLaunchFailed", 0)
            exit(error is CancellationError ? 0 : 70)
        }
    } else {
        try root.run()
    }
    guard owner != nil else {
        if root.isRunning { root.terminate() }
        throw ProbeError.failure("Cannot establish owner identity")
    }
    if let identity = ProcessIdentity.read(root.processIdentifier) {
        owned[identity.pid] = identity
    } else if !(oneShot || terminal) || root.isRunning {
        if root.isRunning { root.terminate() }
        throw ProbeError.failure("Cannot establish runtime identity")
    }
    _ = try sweep()
    status("running")
    var reason = "runtimeExited"
    while root.isRunning {
        _ = try sweep()
        if zv_stop_requested() != 0 { reason = "supervisorStopRequested"; break }
        if getppid() != ownerPID || ProcessIdentity.read(ownerPID).map({ owner!.sameProcess(as: $0) }) != true {
            reason = "ownerExited"; break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    status("cleaning", reason)
    let deadline = Date().addingTimeInterval(3)
    let escalate = Date().addingTimeInterval(0.3)
    var emptySince: Date?
    var remaining: [ProcessIdentity] = []
    repeat {
        remaining = try sweep()
        if remaining.isEmpty {
            if emptySince == nil { emptySince = Date() }
            if Date().timeIntervalSince(emptySince!) >= 0.2 { break }
        } else {
            emptySince = nil
            for process in remaining where process.signal(Date() >= escalate ? SIGKILL : SIGTERM) { signalsSent += 1 }
        }
        Thread.sleep(forTimeInterval: 0.025)
    } while Date() < deadline
    remaining = try sweep()
    status(remaining.isEmpty ? "clean" : "unknown", reason, remaining.count)
    if root.isRunning { _ = owned[root.processIdentifier]?.signal(SIGKILL) }
    root.reapGroupLeader()
    exit(remaining.isEmpty ? 0 : 70)
} catch {
    // Failure is explicit; the host must not release its execution slot.
    if let group = root.processGroupID { _ = kill(-group, SIGKILL) }
    for process in owned.values { _ = process.signal(SIGKILL) }
    status("unknown", "supervisionFailure: \(error)")
    root.reapGroupLeader()
    exit(70)
}
