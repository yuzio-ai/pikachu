import Darwin
import Foundation

/// Delivers the login Agent's environment without putting it in the supervisor's
/// environment, command line, terminal stream, or a regular file.
public enum TerminalLoginEnvironment {
    public static let pipeName = "agent-environment"
    private static let maximumBytes = 1_048_576

    public static func create(in directory: URL) throws -> URL {
        let pipe = directory.appendingPathComponent(pipeName)
        guard mkfifo(pipe.path, 0o600) == 0 else { throw posixError() }
        return pipe
    }

    public static func send(_ environment: [String: String], through pipe: URL) throws {
        let payload = try JSONEncoder().encode(environment)
        guard payload.count <= maximumBytes else { throw POSIXError(.E2BIG) }
        var size = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)

        let deadline = ContinuousClock.now + .seconds(5)
        let descriptor: Int32
        while true {
            try Task.checkCancellation()
            let opened = open(pipe.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if opened >= 0 { descriptor = opened; break }
            guard errno == ENXIO || errno == EINTR else { throw posixError() }
            try pause(until: deadline)
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { throw posixError() }

        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count == -1, errno != EINTR && errno != EAGAIN { throw posixError() }
                try pause(until: deadline)
            }
        }
    }

    public static func receive(in directory: URL, whileOwnerIsActive: () -> Bool) throws -> [String: String] {
        let descriptor = open(directory.appendingPathComponent(pipeName).path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        let deadline = ContinuousClock.now + .seconds(5)
        func readExactly(_ length: Int) throws -> Data {
            var data = Data(count: length)
            try data.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < length {
                    guard whileOwnerIsActive() else { throw CancellationError() }
                    let count = read(descriptor, base.advanced(by: offset), length - offset)
                    if count > 0 { offset += count; continue }
                    if count == -1, errno != EINTR && errno != EAGAIN { throw posixError() }
                    // No writer may be attached yet. The length prefix delimits the frame.
                    try pause(until: deadline)
                }
            }
            return data
        }
        let header = try readExactly(MemoryLayout<UInt32>.size)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard (1...maximumBytes).contains(length) else { throw POSIXError(.E2BIG) }
        return try JSONDecoder().decode([String: String].self, from: readExactly(length))
    }

    private static func pause(until deadline: ContinuousClock.Instant) throws {
        guard .now < deadline else { throw POSIXError(.ETIMEDOUT) }
        Thread.sleep(forTimeInterval: 0.01)
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
