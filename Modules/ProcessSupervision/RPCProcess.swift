import Foundation
import Darwin

public typealias Record = [String: Any]
public enum ProbeError: Error, CustomStringConvertible {
    case failure(String)
    public var description: String { switch self { case .failure(let s): return s } }
}
public func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.failure(message) }
}

/// Strict LF framing; retain bytes until a complete UTF-8 record is available.
public struct JSONLDecoder {
    public private(set) var pending = Data()
    private var scanned = 0
    private let maximumRecordBytes: Int?
    public private(set) var decodedSizes: [Int] = []
    public init(maximumRecordBytes: Int? = nil) { self.maximumRecordBytes = maximumRecordBytes }
    public mutating func feed(_ bytes: Data) throws -> [Record] {
        pending.append(bytes)
        var records: [Record] = []
        decodedSizes = []
        while let end = pending.dropFirst(scanned).firstIndex(of: 10) {
            if let maximumRecordBytes, pending.distance(from: pending.startIndex, to: end) > maximumRecordBytes { throw ProbeError.failure("Protocol record exceeds size limit") }
            var line = Data(pending[..<end])
            pending.removeSubrange(...end)
            scanned = 0
            if line.last == 13 { line.removeLast() }
            if line.isEmpty { continue }
            guard let value = try JSONSerialization.jsonObject(with: line) as? Record else {
                throw ProbeError.failure("Protocol record is not an object")
            }
            records.append(value)
            decodedSizes.append(line.count)
        }
        if let maximumRecordBytes, pending.count > maximumRecordBytes { throw ProbeError.failure("Protocol record exceeds size limit") }
        scanned = pending.count
        return records
    }
}

/// Shared RPC transport. Probe mode retains full observations; the
/// adapter opts into bounded streaming. Blocking reads use dedicated threads.
public final class RPCProcess: @unchecked Sendable {
    public let process = Process()
    public let instanceID = UUID().uuidString
    private let input = Pipe(), output = Pipe(), diagnostic = Pipe()
    private let lock = NSCondition(), writeLock = NSLock()
    private var records: [Record] = []
    private var timeline: [Record] = []
    private var protocolFailure: String?
    private var stderrBytes = Data()
    private var stdoutFinished = false
    private var supervisionDirectory: URL?
    public private(set) var supervisionStatusURL: URL?
    private var runtimeIdentity: ProcessIdentity?
    private let streaming: Bool
    private var eventBytes = 0
    private var eventSizes: [Int] = []
    private var receivedCount = 0
    private var streamClosing = false
    public var supervisionStatus: Record {
        guard let url = supervisionStatusURL, let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? Record else { return [:] }
        return record
    }
    public let started = Date()
    public init(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                supervised: Bool = false, streaming: Bool = false, supervisionRoot: URL? = nil,
                oneShot: Bool = false, inputFile: FileHandle? = nil) throws {
        self.streaming = streaming
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if supervised {
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("pikachu-supervisor")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw ProbeError.failure("Supervisor executable missing; build pikachu-supervisor") }
            let directory = (supervisionRoot ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("pikachu-supervision-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            supervisionDirectory = directory
            supervisionStatusURL = directory.appendingPathComponent("status.json")
            process.executableURL = helper
            let mode = oneShot ? "--one-shot" : "--"
            process.arguments = [supervisionStatusURL!.path, UUID().uuidString, String(getpid()), mode, executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        process.currentDirectoryURL = cwd
        process.environment = environment
        if let inputFile { process.standardInput = inputFile }
        else { process.standardInput = input }
        process.standardOutput = output
        process.standardError = diagnostic
        if streaming && inputFile == nil && fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != 0 {
            throw ProbeError.failure("Cannot establish safe protocol writes")
        }
        try process.run()
        Thread.detachNewThread { [self] in
            var decoder = JSONLDecoder(maximumRecordBytes: streaming ? 16 * 1_024 * 1_024 : nil)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let data: Data
                if streaming {
                    // Foundation's length-based read may wait to fill a pipe read.
                    // POSIX read returns available bytes, with a bounded allocation.
                    var size: Int
                    repeat { size = buffer.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) } } while size < 0 && errno == EINTR
                    if size < 0 { lock.withLock { protocolFailure = "Protocol pipe read failed" }; break }
                    data = Data(buffer.prefix(size))
                } else { data = output.fileHandleForReading.availableData }
                if data.isEmpty { break }
                do {
                    let values = try decoder.feed(data)
                    lock.withLock {
                        for (index, value) in values.enumerated() {
                            receivedCount += 1
                            if streaming {
                                if timeline.count >= 1_024 { timeline.removeFirst(512) }
                                let size = decoder.decodedSizes[index]
                                while !streamClosing && !records.isEmpty && (records.count >= 128 || eventBytes + size > 8 * 1_024 * 1_024) { lock.wait() }
                                if streamClosing { continue }
                                eventBytes += size; eventSizes.append(size)
                            }
                            timeline.append(["direction": "receive", "elapsedSeconds": Date().timeIntervalSince(started),
                                             "recordIndex": records.count, "type": value["type"] ?? "unknown",
                                             "id": value["id"] ?? NSNull()])
                            records.append(value)
                        }
                    }
                } catch { lock.withLock { protocolFailure = "Malformed protocol record" }; break }
            }
            lock.withLock {
                if !decoder.pending.isEmpty { protocolFailure = "Incomplete protocol record at EOF" }
                stdoutFinished = true
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                let data = diagnostic.fileHandleForReading.availableData
                if data.isEmpty { break }
                lock.withLock { if stderrBytes.count < 65_536 { stderrBytes.append(data.prefix(65_536 - stderrBytes.count)) } }
            }
        }
        if supervised {
            let until = Date().addingTimeInterval(5)
            func startedOrFinished() -> Bool {
                let status = supervisionStatus
                if oneShot, status["state"] as? String == "clean", status["runtimeExitStatus"] is Int { return true }
                if status["state"] as? String == "running", let pid = status["runtimePID"] as? Int32 {
                    runtimeIdentity = ProcessIdentity.read(pid)
                    return runtimeIdentity != nil
                }
                return false
            }
            var ready = startedOrFinished()
            while !ready && Date() < until && process.isRunning {
                Thread.sleep(forTimeInterval: 0.005)
                ready = startedOrFinished()
            }
            guard ready || startedOrFinished() else {
                try? close(timeout: 1)
                let diagnosticDeadline = Date().addingTimeInterval(0.1)
                while stderrCount == 0 && Date() < diagnosticDeadline { Thread.sleep(forTimeInterval: 0.005) }
                if diagnosticText.contains("node") && diagnosticText.contains("No such file") {
                    throw ProbeError.failure("Runtime dependency missing: node")
                }
                throw ProbeError.failure("Supervisor startup failed; outcome unknown")
            }
        }

    }
    public var allRecords: [Record] { lock.withLock { records } }
    public var count: Int { lock.withLock { streaming ? receivedCount : records.count } }
    /// Cursor-based observation for a UI adapter; supervision behavior is unchanged.
    public func observation(after cursor: Int) -> (records: [Record], nextCursor: Int, ended: Bool, failure: String?) {
        lock.withLock {
            if streaming {
                let batch = records; records = []; eventSizes = []; eventBytes = 0; lock.broadcast()
                return (batch, receivedCount, stdoutFinished, protocolFailure)
            }
            return (Array(records.dropFirst(cursor)), records.count, stdoutFinished, protocolFailure)
        }
    }
    public var stderrCount: Int { lock.withLock { stderrBytes.count } }
    public var diagnosticText: String { lock.withLock { String(decoding: stderrBytes, as: UTF8.self) } }
    public func raw(_ bytes: Data) throws {
        try writeLock.withLock {
            if streaming && lock.withLock({ streamClosing }) { throw ProbeError.failure("Connection is closing") }
            if supervisionStatusURL != nil && (!process.isRunning || supervisionStatus["state"] as? String != "running") {
                throw ProbeError.failure("Supervision unavailable; new commands blocked")
            }
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }
    public func send(_ value: Record) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        try raw(data)
        lock.withLock {
            if streaming && timeline.count >= 1_024 { timeline.removeFirst(512) }
            timeline.append(["direction": "send", "elapsedSeconds": Date().timeIntervalSince(started),
                                          "type": value["type"] ?? "unknown", "id": value["id"] ?? NSNull()]) }
    }
    public func wait(after: Int = 0, timeout: Double = 5, where match: (Record) -> Bool) throws -> Record {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            let snapshot = lock.withLock { (Array(records.dropFirst(after)), protocolFailure, stdoutFinished) }
            if let item = snapshot.0.first(where: match) { return item }
            if let error = snapshot.1 { throw ProbeError.failure(error) }
            if supervisionStatusURL != nil && !process.isRunning && supervisionStatus["state"] as? String != "clean" {
                throw ProbeError.failure("Supervisor exited without confirmed cleanup")
            }
            if snapshot.2 { throw ProbeError.failure("Protocol EOF before expected response") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw ProbeError.failure("Deadline exceeded; outcome unknown")
    }
    public func close(timeout: Double = 5) throws {
        if streaming { lock.withLock { streamClosing = true; lock.broadcast() } }
        writeLock.withLock { try? input.fileHandleForWriting.close() }
        let until = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            if supervisionStatusURL != nil { _ = runtimeIdentity?.signal(SIGTERM) } else { process.terminate() }
            let grace = Date().addingTimeInterval(4)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                if supervisionStatusURL != nil { _ = runtimeIdentity?.signal(SIGKILL) } else { kill(process.processIdentifier, SIGKILL) }
            }
            throw ProbeError.failure("Orderly shutdown exceeded deadline; escalated")
        }
        if supervisionStatusURL != nil && supervisionStatus["state"] as? String != "clean" {
            throw ProbeError.failure("Descendant cleanup unconfirmed; execution slot must stay blocked")
        }
    }
    public func crash() {
        if supervisionStatusURL != nil { _ = runtimeIdentity?.signal(SIGKILL) }
        else { kill(process.processIdentifier, SIGKILL) }
    }
    public func summary() -> Record {
        var types: [String: Int] = [:]
        for r in allRecords { types[r["type"] as? String ?? "unknown", default: 0] += 1 }
        return ["instanceID": instanceID, "events": types, "stderrBytes": stderrCount, "supervision": supervisionStatus,
                "elapsedSeconds": Date().timeIntervalSince(started)]
    }
    public func trace() -> Record {
        let report = supervisionStatus
        return lock.withLock { ["instanceID": instanceID, "timeline": timeline,
                                "lastSupervisorReport": report, "supervisorRunning": process.isRunning] }
    }
    public var bufferStatus: (events: Int, eventBytes: Int) { lock.withLock { (records.count, eventBytes) } }
}
