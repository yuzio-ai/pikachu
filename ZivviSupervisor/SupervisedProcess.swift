import Foundation
import Darwin
import CProcessInspection

/// Keeps the login child in the foreground PTY process group. Foundation.Process
/// is used for the existing pipe-based runtimes.
final class SupervisedProcess {
    enum SpawnMode {
        case standard, terminalLogin, ownProcessGroup
    }

    private let process = Process()
    private let mode: SpawnMode
    private var spawnedPID: Int32 = 0
    private var spawnedExit: (code: Int32, bySignal: Bool)?

    init(mode: SpawnMode, executable: String, arguments: [String], environment: [String: String]) {
        self.mode = mode
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    }

    var processIdentifier: Int32 { mode == .standard ? process.processIdentifier : spawnedPID }
    var processGroupID: Int32? { mode == .ownProcessGroup && spawnedPID > 1 ? spawnedPID : nil }

    var isRunning: Bool {
        if mode == .standard { return process.isRunning }
        guard spawnedPID > 0, spawnedExit == nil else { return false }
        var code: Int32 = 0
        var bySignal: Int32 = 0
        let result = mode == .terminalLogin
            ? zv_poll_terminal_child(spawnedPID, &code, &bySignal)
            : zv_observe_group_child_exit(spawnedPID, &code, &bySignal)
        switch result {
        case 0: return true
        case 1: spawnedExit = (code, bySignal != 0)
        default: break
        }
        return false
    }
    var termination: (code: Int32, bySignal: Bool)? {
        if mode != .standard { return spawnedExit }
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal)
    }

    func run(environment: [String: String]? = nil) throws {
        if mode == .standard {
            try process.run()
            return
        }

        guard let executable = process.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
        var argv = ([executable] + (process.arguments ?? [])).map { strdup($0) }
        var envp = (environment ?? process.environment ?? [:]).map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        argv.append(nil)
        envp.append(nil)
        let result = mode == .terminalLogin
            ? zv_spawn_terminal_child(&spawnedPID, executable, &argv, &envp)
            : zv_spawn_group_child(&spawnedPID, executable, &argv, &envp)
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    func terminate() {
        if mode != .standard {
            if isRunning { _ = kill(spawnedPID, SIGTERM) }
        } else {
            process.terminate()
        }
    }

    func reapGroupLeader() {
        guard let leader = processGroupID, spawnedExit != nil else { return }
        var code: Int32 = 0
        var bySignal: Int32 = 0
        _ = zv_poll_terminal_child(leader, &code, &bySignal)
    }
}
