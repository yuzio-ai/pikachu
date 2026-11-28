import Foundation
import Darwin
import ProcessSupervision

final class ACPClientTerminal: @unchecked Sendable {
    static let maximumOutputBytes = 512 * 1024
    private let process = Process()
    private let condition = NSCondition()
    private let statusDirectory: URL
    private let outputLimit: Int
    private var output = Data()
    private var truncated = false
    private var result: Record?
    private var terminationRequested = false
    private var cleanupConfirmed = false
    private var startupFailure: String?

    init(command: String, args: [String], cwd: URL, environment: [String: String], limit: Int,
         supervisionRoot: URL? = nil) throws {
        outputLimit = min(limit, Self.maximumOutputBytes)
        let manager = FileManager.default
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("zivvi-supervisor")
        guard manager.isExecutableFile(atPath: helper.path),
              let executable = Self.executable(command, cwd: cwd, path: environment["PATH"] ?? "")
        else { throw ProbeError.failure("Terminal executable or process supervisor unavailable") }
        statusDirectory = (supervisionRoot ?? manager.temporaryDirectory)
            .appendingPathComponent("zivvi-terminal-\(UUID().uuidString)")
        try manager.createDirectory(at: statusDirectory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let status = statusDirectory.appendingPathComponent("status.json")
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = [status.path, UUID().uuidString, String(getpid()), "--terminal", executable] + args
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? manager.removeItem(at: statusDirectory)
            throw error
        }
        Thread.detachNewThread { [self] in
            let reader = pipe.fileHandleForReading
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                condition.withLock {
                    output.append(contentsOf: buffer.prefix(count))
                    if output.count > outputLimit {
                        var start = output.count - outputLimit
                        while start < output.count, output[start] & 0xc0 == 0x80 { start += 1 }
                        output = Data(output.dropFirst(start))
                        truncated = true
                    }
                }
            }
            try? reader.close()
            process.waitUntilExit()
            let data = try? Data(contentsOf: status)
            let record = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? Record }
            condition.withLock {
                cleanupConfirmed = record?["state"] as? String == "clean"
                if !cleanupConfirmed { startupFailure = record?["reason"] as? String }
                if cleanupConfirmed, let code = record?["runtimeExitStatus"] as? Int {
                    if record?["runtimeExitBySignal"] as? Bool == true {
                        result = ["exitCode": NSNull(), "signal": Self.signalName(code)]
                    } else {
                        result = ["exitCode": code, "signal": NSNull()]
                    }
                } else {
                    result = ["exitCode": NSNull(), "signal": NSNull()]
                }
                condition.broadcast()
            }
            if supervisionRoot == nil { try? FileManager.default.removeItem(at: statusDirectory) }
        }
        // The supervisor acknowledges startup after installing its stop handler
        // and claiming the child. A kill sent before that point can kill the helper.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try? Data(contentsOf: status),
               let record = (try? JSONSerialization.jsonObject(with: data)) as? Record,
               let stage = record["state"] as? String, ["running", "clean"].contains(stage) {
                return
            }
            if let finished = condition.withLock({ result.map { _ in cleanupConfirmed } }) {
                if finished { return }
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        terminate()
        throw ProbeError.failure("Terminal supervisor startup unconfirmed: " +
                                 (condition.withLock { startupFailure } ?? "no startup status"))
    }

    func snapshot() -> Record {
        condition.withLock {
            ["output": String(decoding: output, as: UTF8.self),
             "truncated": truncated, "exitStatus": result.map { $0 as Any } ?? NSNull()]
        }
    }

    func wait(cancelled: () -> Bool) throws -> Record {
        while !cancelled() {
            if let exit = condition.withLock({ () -> Record? in
                if result == nil { condition.wait(until: Date().addingTimeInterval(0.1)) }
                return result
            }) {
                return exit
            }
        }
        throw CancellationError()
    }

    var didConfirmCleanup: Bool { condition.withLock { cleanupConfirmed } }

    func terminate() {
        let first = condition.withLock {
            guard !terminationRequested, result == nil else { return false }
            terminationRequested = true
            return true
        }
        if first, process.isRunning { process.terminate() }
    }

    private static func executable(_ command: String, cwd: URL, path: String) -> String? {
        guard !command.isEmpty, !command.utf8.contains(0) else { return nil }
        let candidates = command.contains("/") ? [URL(fileURLWithPath: command, relativeTo: cwd).standardizedFileURL.path]
            : path.split(separator: ":").map { String($0) + "/" + command }
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    private static func signalName(_ code: Int) -> String {
        switch Int32(code) {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        case SIGABRT: "SIGABRT"
        case SIGPIPE: "SIGPIPE"
        default: String(code)
        }
    }
}
