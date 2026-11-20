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
    // another copy of Pikachu owns a different workspace.
    let directory = FileManager.default.currentDirectoryPath
    open.arguments = ["-n", "-a", args[3], "--env", "PIKACHU_RELAUNCH_DIRECTORY=\(directory)"]
    if args.count > 4 { open.arguments?.append(contentsOf: ["--args"] + args.dropFirst(4)) }
    do {
        try open.run()
        open.waitUntilExit()
        exit(open.terminationStatus)
    } catch {
        exit(70)
    }
}
guard args.count >= 6, args[4] == "--" else { exit(64) }
let statusURL = URL(fileURLWithPath: args[1]), token = args[2]
let ownerPID = Int32(args[3])!
pk_install_signal_handlers()
let owner = ProcessIdentity.read(ownerPID)
let root = Process()
root.executableURL = URL(fileURLWithPath: args[5]); root.arguments = Array(args.dropFirst(6))
var environment = ProcessInfo.processInfo.environment
environment["PIKACHU_EXECUTION_TOKEN"] = token
root.environment = environment
root.standardInput = FileHandle.standardInput
root.standardOutput = FileHandle.standardOutput
root.standardError = FileHandle.standardError
var owned: [Int32: ProcessIdentity] = [:]
var signalsSent = 0, sweepCount = 0
@MainActor func status(_ state: String, _ reason: String = "", _ remaining: Int? = nil) {
    let record: Record = ["state": state, "reason": reason, "runtimePID": root.processIdentifier,
                          "supervisorPID": getpid(), "ownedIdentities": owned.count,
                          "signalsSent": signalsSent, "sweeps": sweepCount, "remaining": remaining ?? -1]
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        try? data.write(to: statusURL, options: .atomic)
    }
}
@MainActor func sweep() throws -> [ProcessIdentity] {
    if environment["PIKACHU_SUPERVISION_FAIL_SCAN"] == "1" { throw ProbeError.failure("Injected enumeration failure") }
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
    try root.run()
    guard let identity = ProcessIdentity.read(root.processIdentifier), owner != nil else {
        root.terminate(); throw ProbeError.failure("Cannot establish runtime/owner identity")
    }
    owned[identity.pid] = identity
    _ = try sweep()
    status("running")
    var reason = "runtimeExited"
    while root.isRunning {
        _ = try sweep()
        if pk_stop_requested() != 0 { reason = "supervisorStopRequested"; break }
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
    exit(remaining.isEmpty ? 0 : 70)
} catch {
    // Failure is explicit; the host must not release its execution slot.
    for process in owned.values { _ = process.signal(SIGKILL) }
    status("unknown", "supervisionFailure: \(error)")
    exit(70)
}
