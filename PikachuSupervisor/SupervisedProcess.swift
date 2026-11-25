import Foundation
import Darwin
import CProcessInspection

/// Keeps the login child in the foreground PTY process group. Foundation.Process
/// is used for the existing pipe-based runtimes.
final class SupervisedProcess {
    private let process = Process()
    private let terminalLogin: Bool
    private var terminalPID: Int32 = 0
    private var terminalExit: (code: Int32, bySignal: Bool)?

    init(terminalLogin: Bool, executable: String, arguments: [String], environment: [String: String]) {
        self.terminalLogin = terminalLogin
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    }

    var processIdentifier: Int32 { terminalLogin ? terminalPID : process.processIdentifier }
    var isRunning: Bool {
        if !terminalLogin { return process.isRunning }
        guard terminalPID > 0, terminalExit == nil else { return false }
        var code: Int32 = 0
        var bySignal: Int32 = 0
        switch pk_poll_terminal_child(terminalPID, &code, &bySignal) {
        case 0: return true
        case 1: terminalExit = (code, bySignal != 0)
        default: break
        }
        return false
    }
    var termination: (code: Int32, bySignal: Bool)? {
        if terminalLogin { return terminalExit }
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal)
    }

    func run(environment: [String: String]? = nil) throws {
        if !terminalLogin {
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
        let result = pk_spawn_terminal_child(&terminalPID, executable, &argv, &envp)
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    func terminate() {
        if terminalLogin {
            if isRunning { _ = kill(terminalPID, SIGTERM) }
        } else {
            process.terminate()
        }
    }
}
