import Darwin
import Foundation
import ProcessSupervision

/// Reads read-only account quota windows from the locally installed official Antigravity CLI
/// using `agy -p /usage --output-format json` without starting any model turn.
enum AntigravityQuotaClient {
    enum Failure: Error, Equatable {
        case notInstalled
        case notSignedIn
        case unsupportedVersion
        case invalidResponse
        case failed(String)
    }

    private struct SupervisionReceipt: Decodable {
        let state: String
        let supervisionID: String
        let remaining: Int
        let runtimeExitStatus: Int32?
    }

    static func windows(from data: Data, observedAt: Date) throws -> [AccountQuotaWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let errorObj = root["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            let lower = message.lowercased()
            if lower.contains("login") || lower.contains("auth") || lower.contains("sign in") {
                throw Failure.notSignedIn
            }
            throw Failure.failed(message)
        }
        let command = (root["command"] as? [String: Any]) ?? root
        let payload = (command["data"] as? [String: Any]) ?? command
        guard let groups = payload["groups"] as? [[String: Any]] else {
            throw Failure.invalidResponse
        }

        var results: [AccountQuotaWindow] = []
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]

        for (groupIdx, group) in groups.enumerated() {
            let groupTitle = (group["label"] as? String) ?? (group["name"] as? String) ?? (group["id"] as? String) ?? "Group \(groupIdx + 1)"
            let buckets = (group["buckets"] as? [[String: Any]]) ?? []
            for (bucketIdx, bucket) in buckets.enumerated() {
                let bucketName = (bucket["label"] as? String) ?? (bucket["name"] as? String) ?? (bucket["window"] as? String)
                let period = bucketName.map { $0.isEmpty ? groupTitle : "\(groupTitle) · \($0)" } ?? groupTitle
                let remainingRatio: Double? = {
                    if let r = bucket["remainingFraction"] as? Double { return r }
                    if let r = bucket["remaining"] as? Double, r >= 0, r <= 1 { return r }
                    if let pct = bucket["remainingPercent"] as? Double { return pct / 100.0 }
                    if let used = bucket["usedFraction"] as? Double { return 1.0 - used }
                    if let usedPct = bucket["usedPercent"] as? Double { return 1.0 - usedPct / 100.0 }
                    return nil
                }()
                let remainingInt: Int? = remainingRatio.flatMap { ratio in
                    guard ratio.isFinite, ratio >= 0, ratio <= 1 else { return nil }
                    if ratio == 0 { return 0 }
                    let scaled = Int((ratio * 1000).rounded(.down))
                    return max(1, min(1000, scaled))
                }
                let resetAt: Date? = {
                    if let resetStr = (bucket["resetTime"] as? String) ?? (bucket["resetsAt"] as? String) {
                        return isoWithFraction.date(from: resetStr) ?? isoStandard.date(from: resetStr)
                    }
                    if let epoch = (bucket["resetsAt"] as? Double) ?? (bucket["resetAt"] as? Double), epoch > 0 {
                        return Date(timeIntervalSince1970: epoch)
                    }
                    return nil
                }()
                let id = "agy:\(groupIdx):\(bucketIdx):\(period)"
                results.append(AccountQuotaWindow(
                    id: id,
                    provider: "Antigravity",
                    account: String(localized: "本机 Antigravity 账号"),
                    period: period,
                    remaining: remainingInt,
                    limit: remainingInt != nil ? 1000 : nil,
                    resetAt: resetAt,
                    observedAt: observedAt,
                    expiresAt: observedAt.addingTimeInterval(600)
                ))
            }
        }
        return results
    }

    static func fetch(searchPaths: [String] = []) async throws -> [AccountQuotaWindow] {
        guard !QuotaCLIProcessPolicy.shouldSkipUserCLIProbes else { return [] }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin", "/usr/local/bin",
                     home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".npm-global/bin").path,
                     home.appendingPathComponent(".bun/bin").path]
            + searchPaths
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let executable = paths.filter({ $0.hasPrefix("/") }).map({ $0 + "/agy" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.notInstalled
        }

        return try await query(executable: URL(fileURLWithPath: executable))
    }

    static func query(executable: URL, timeout: Duration = .seconds(8)) async throws -> [AccountQuotaWindow] {
        let work = Task.detached(priority: .utility) {
            try runQuery(executable: executable, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            let windows = try await work.value
            try Task.checkCancellation()
            return windows
        } onCancel: {
            work.cancel()
        }
    }

    private static func runQuery(executable: URL, timeout: Duration) throws -> [AccountQuotaWindow] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let version = try runCommand(executable: executable, arguments: ["--version"], deadline: deadline)
        guard version.exitStatus == 0, supportsUsageCommand(String(decoding: version.output, as: UTF8.self)) else {
            throw Failure.unsupportedVersion
        }

        let usage = try runCommand(executable: executable, arguments: ["-p", "/usage", "--output-format", "json"],
                                   deadline: deadline)
        if usage.exitStatus != 0 {
            let message = String(decoding: usage.diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = message.lowercased()
            if lower.contains("unknown option") || lower.contains("unsupported") {
                throw Failure.unsupportedVersion
            }
            if lower.contains("login") || lower.contains("auth") || lower.contains("sign in") {
                throw Failure.notSignedIn
            }
            throw Failure.failed(message.isEmpty ? String(localized: "无法查询 Antigravity 额度。") : message)
        }
        return try windows(from: usage.output, observedAt: .now)
    }

    private static func supportsUsageCommand(_ versionOutput: String) -> Bool {
        let line = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #/(?i)(?:(?:antigravity(?: cli)?|agy)(?: version)?[: ]+)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+[A-Za-z0-9.-]+)?/#
        guard let version = line.wholeMatch(of: pattern),
              let major = Int(version.1), let minor = Int(version.2), let patch = Int(version.3) else { return false }
        return (major, minor, patch) >= (1, 1, 11)
    }

    private static func runCommand(executable: URL, arguments: [String], deadline: ContinuousClock.Instant)
        throws -> (output: Data, diagnostics: Data, exitStatus: Int32) {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw Failure.failed(String(localized: "Antigravity CLI 查询超时。"))
        }
        guard let supervisor = Bundle.main.url(forAuxiliaryExecutable: "zivvi-supervisor") else {
            throw Failure.failed(String(localized: "无法查询 Antigravity 额度。"))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zivvi-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent("status.json")
        let process = Process()
        process.executableURL = supervisor
        process.arguments = [receiptURL.path, UUID().uuidString, String(getpid()), "--quota-probe", executable.path] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Nonblocking reads let one worker service both pipes and check its deadline,
        // even if a child inherits the write end of a pipe and keeps it open.
        var descriptors = [try pollReader(for: stdoutPipe), try pollReader(for: stderrPipe)]
        try process.run()
        let identity = ProcessIdentity.read(process.processIdentifier)
        defer { stopAndReap(process, identity: identity) }

        var stdout = Data(), stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while descriptors[0].fd >= 0 || descriptors[1].fd >= 0 || process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw Failure.failed(String(localized: "Antigravity CLI 查询超时。"))
            }
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 25) }
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try readPipe(&descriptors[0], into: &stdout, buffer: &buffer, limit: 1024 * 1024, keepPrefix: false)
            try readPipe(&descriptors[1], into: &stderr, buffer: &buffer, limit: 64 * 1024, keepPrefix: true)
        }
        try Task.checkCancellation()

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(SupervisionReceipt.self, from: data),
              receipt.state == "clean", receipt.remaining == 0,
              receipt.supervisionID == directory.lastPathComponent,
              let exitStatus = receipt.runtimeExitStatus else {
            throw Failure.failed(String(localized: "无法查询 Antigravity 额度。"))
        }
        return (stdout, stderr, exitStatus)
    }

    private static func pollReader(for pipe: Pipe) throws -> pollfd {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    }

    private static func readPipe(_ source: inout pollfd, into data: inout Data,
                                 buffer: inout [UInt8], limit: Int, keepPrefix: Bool) throws {
        guard source.fd >= 0, source.revents != 0 else { return }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(source.fd, $0.baseAddress, $0.count) }
        if count == 0 {
            source.fd = -1
            return
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let remaining = limit - data.count
        guard keepPrefix || count <= remaining else { throw Failure.invalidResponse }
        data.append(contentsOf: buffer.prefix(min(count, remaining)))
    }

    private static func stopAndReap(_ process: Process, identity: ProcessIdentity?) {
        if process.isRunning {
            process.terminate()
            // The watchdog sweeps and escalates signals for the entire process tree.
            let grace = ContinuousClock.now.advanced(by: .seconds(4))
            while process.isRunning && ContinuousClock.now < grace {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                if let identity {
                    _ = identity.signal(SIGKILL)
                } else {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process.waitUntilExit()
    }
}
