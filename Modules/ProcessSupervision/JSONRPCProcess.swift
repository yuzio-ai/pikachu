import Foundation
import Darwin
import CoreFoundation

/// Preserves the JSON-RPC 2.0 ID type and the UTF-8 bytes of string IDs.
public enum JSONRPCID: Hashable, Sendable, Codable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.int(let left), .int(let right)): left == right
        case (.string(let left), .string(let right)): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .int(let value):
            hasher.combine(false)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(true)
            hasher.combine(value.utf8.count)
            for byte in value.utf8 { hasher.combine(byte) }
        }
    }

    public init?(jsonValue: Any?) {
        guard let value = jsonValue, !(value is NSNull) else { return nil }
        if let string = value as? String {
            self = .string(string)
            return
        }
        if let intValue = JSONRPCProcess.parseJSONInt(value) {
            self = .int(intValue)
            return
        }
        return nil
    }

    public var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "JSON-RPC ID must be an integer or string")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Structured JSON-RPC 2.0 error payload.
public struct JSONRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let dataJSON: Data?

    public init(code: Int, message: String, dataJSON: Data? = nil) {
        self.code = code
        self.message = message
        self.dataJSON = dataJSON
    }

    public var dataObject: Any? {
        guard let dataJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: dataJSON, options: [.fragmentsAllowed])
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }
}

/// Inbound JSON-RPC 2.0 response matched to an outbound client request.
public struct JSONRPCResponse: @unchecked Sendable {
    public let id: JSONRPCID
    public let result: Any?
    public let resultJSON: Data?
    public let error: JSONRPCError?
    public let raw: Record
    public fileprivate(set) var receiveOrder = 0

    public init(id: JSONRPCID, result: Any?, resultJSON: Data?, error: JSONRPCError?, raw: Record) {
        self.id = id
        self.result = result
        self.resultJSON = resultJSON
        self.error = error
        self.raw = raw
    }

    public var isError: Bool { error != nil }
    public var resultRecord: Record? { result as? Record }

    public func decodeResult<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let resultJSON else {
            throw ProbeError.failure("JSON-RPC response missing result payload")
        }
        return try decoder.decode(type, from: resultJSON)
    }
}

/// Inbound JSON-RPC 2.0 request initiated by the agent (both `id` and `method` present).
public struct JSONRPCRequest: @unchecked Sendable {
    public let id: JSONRPCID
    public let method: String
    public let params: Record
    public let paramsJSON: Data?
    public let raw: Record

    public init(id: JSONRPCID, method: String, params: Record, paramsJSON: Data?, raw: Record) {
        self.id = id
        self.method = method
        self.params = params
        self.paramsJSON = paramsJSON
        self.raw = raw
    }

    public func decodeParams<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let paramsJSON else {
            throw ProbeError.failure("JSON-RPC request missing params payload")
        }
        return try decoder.decode(type, from: paramsJSON)
    }
}

/// Inbound JSON-RPC 2.0 notification (no `id`, has `method`).
public struct JSONRPCNotification: @unchecked Sendable {
    public let method: String
    public let params: Record
    public let paramsJSON: Data?
    public let raw: Record
    public fileprivate(set) var receiveOrder = 0

    public init(method: String, params: Record, paramsJSON: Data?, raw: Record) {
        self.method = method
        self.params = params
        self.paramsJSON = paramsJSON
        self.raw = raw
    }

    public func decodeParams<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let paramsJSON else {
            throw ProbeError.failure("JSON-RPC notification missing params payload")
        }
        return try decoder.decode(type, from: paramsJSON)
    }
}

/// Ordered inbound non-response message delivered to upper-layer protocol consumers.
public enum JSONRPCInboundMessage: @unchecked Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
}

/// Classification of any decoded JSON-RPC 2.0 wire object.
public enum JSONRPCWireFrame: @unchecked Sendable {
    case response(JSONRPCResponse)
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
}

private final class OneShotResponseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSONRPCResponse, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<JSONRPCResponse, Error>) {
        self.continuation = continuation
    }

    func attachTimeout(_ task: Task<Void, Never>) {
        let shouldCancel: Bool = lock.withLock {
            guard continuation != nil else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func resume(with result: Result<JSONRPCResponse, Error>) {
        let (target, task): (CheckedContinuation<JSONRPCResponse, Error>?, Task<Void, Never>?) = lock.withLock {
            let current = continuation
            let currentTask = timeoutTask
            continuation = nil
            timeoutTask = nil
            return (current, currentTask)
        }
        task?.cancel()
        target?.resume(with: result)
    }
}

/// A failed supervised startup that still owns an unconfirmed process cleanup.
public struct JSONRPCStartupCleanupPending: Error, Sendable, CustomStringConvertible {
    public let process: JSONRPCProcess
    public var description: String { "Supervisor startup failed; outcome unknown" }
}

/// Supervised bidirectional JSON-RPC 2.0 stdio transport.
/// Reuses `zivvi-supervisor`, `ProcessIdentity`, strict LF `JSONLDecoder`, `F_SETNOSIGPIPE`,
/// bounded 16 MiB records, bounded inbound queue backpressure, and confirmed `SIGTERM -> SIGKILL` shutdown.
public final class JSONRPCProcess: @unchecked Sendable {
    public let process = Process()
    public let instanceID = UUID().uuidString
    public let started = Date()
    public private(set) var supervisionStatusURL: URL?

    private let input = Pipe()
    private let output = Pipe()
    private let diagnostic = Pipe()
    private let lock = NSCondition()
    private let writeLock = NSLock()
    private let callbackQueue = DispatchQueue(label: "ai.yuzio.zivvi.jsonrpc.callbacks")

    private let maximumQueueCount: Int
    private let maximumQueueBytes: Int
    private let maximumPendingRequests = 64

    private var runtimeIdentity: ProcessIdentity?

    private var nextRequestID = 1
    private var pendingRequests = Set<JSONRPCID>()
    private var responses: [JSONRPCID: JSONRPCResponse] = [:]
    private var responseHandlers: [JSONRPCID: @Sendable (Result<JSONRPCResponse, Error>) -> Void] = [:]

    private var inboundMessages: [JSONRPCInboundMessage] = []
    private var inboundSizes: [Int] = []
    private var inboundBytes = 0
    private var receivedCount = 0

    private var timeline: [Record] = []
    private var protocolFailure: String?
    private var stderrBytes = Data()
    private var stdoutFinished = false
    private var streamClosing = false

    public var supervisionStatus: Record {
        guard let url = supervisionStatusURL, let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? Record else { return [:] }
        return record
    }

    public var isRunning: Bool { process.isRunning }
    public var count: Int { lock.withLock { receivedCount } }
    public var stderrCount: Int { lock.withLock { stderrBytes.count } }
    public var diagnosticText: String { lock.withLock { String(decoding: stderrBytes, as: UTF8.self) } }

    public var bufferStatus: (inbound: Int, inboundBytes: Int, pendingRequests: Int, bufferedResponses: Int) {
        lock.withLock { (inboundMessages.count, inboundBytes, pendingRequests.count, responses.count) }
    }

    public init(
        executable: String,
        arguments: [String],
        cwd: URL,
        environment: [String: String],
        supervised: Bool = false,
        supervisionRoot: URL? = nil,
        supervisionDirectory: URL? = nil,
        maximumRecordBytes: Int = 16 * 1_024 * 1_024,
        maximumQueueCount: Int = 128,
        maximumQueueBytes: Int = 8 * 1_024 * 1_024
    ) throws {
        self.maximumQueueCount = max(1, maximumQueueCount)
        self.maximumQueueBytes = max(1_024, maximumQueueBytes)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if supervised {
            let helper = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("zivvi-supervisor")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw ProbeError.failure("Supervisor executable missing; build zivvi-supervisor")
            }
            let directory = supervisionDirectory ?? (supervisionRoot ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("zivvi-supervision-\(UUID().uuidString)")
            if supervisionDirectory != nil {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw ProbeError.failure("Supervisor receipt directory already exists")
                }
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: supervisionDirectory == nil,
                attributes: [.posixPermissions: 0o700]
            )
            supervisionStatusURL = directory.appendingPathComponent("status.json")
            process.executableURL = helper
            process.arguments = [supervisionStatusURL!.path, UUID().uuidString, String(getpid()), "--", executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }

        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostic

        let writeDescriptor = input.fileHandleForWriting.fileDescriptor
        let writeFlags = fcntl(writeDescriptor, F_GETFL)
        if writeFlags < 0 || fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) != 0 ||
            fcntl(writeDescriptor, F_SETFL, writeFlags | O_NONBLOCK) != 0 {
            throw ProbeError.failure("Cannot establish safe protocol writes")
        }

        try process.run()

        let recordLimit = maximumRecordBytes
        Thread.detachNewThread { [self] in
            self.readStdoutLoop(maximumRecordBytes: recordLimit)
        }
        Thread.detachNewThread { [self] in
            self.readStderrLoop()
        }

        if supervised {
            let until = Date().addingTimeInterval(5)
            while Date() < until && supervisionStatus["state"] == nil && process.isRunning {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if let pid = (supervisionStatus["runtimePID"] as? NSNumber)?.int32Value {
                runtimeIdentity = ProcessIdentity.read(pid)
            }
            guard supervisionStatus["state"] as? String == "running", runtimeIdentity != nil else {
                if runtimeIdentity == nil, process.isRunning { process.terminate() }
                do { try close(timeout: 1) }
                catch { throw JSONRPCStartupCleanupPending(process: self) }
                let diagnosticDeadline = Date().addingTimeInterval(0.1)
                while stderrCount == 0 && Date() < diagnosticDeadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                throw ProbeError.failure("Supervisor startup failed; outcome unknown")
            }
        }
    }

    // MARK: - Classification

    static func parseJSONInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if !CFNumberIsFloatType(number as CFNumber) {
            return number.intValue
        }
        return Int(exactly: number.doubleValue)
    }

    public static func classify(_ record: Record) throws -> JSONRPCWireFrame {
        if let version = record["jsonrpc"], version as? String != "2.0" {
            throw ProbeError.failure("Unsupported JSON-RPC version")
        }

        if record.keys.contains("method") {
            guard let method = record["method"] as? String, !method.isEmpty else {
                throw ProbeError.failure("Malformed JSON-RPC method")
            }
            let params: Record
            let paramsJSON: Data?
            if let rawParams = record["params"], !(rawParams is NSNull) {
                if let dict = rawParams as? Record {
                    params = dict
                    paramsJSON = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                } else if JSONSerialization.isValidJSONObject(rawParams) {
                    params = [:]
                    paramsJSON = try JSONSerialization.data(withJSONObject: rawParams, options: [.fragmentsAllowed])
                } else {
                    throw ProbeError.failure("Malformed JSON-RPC params")
                }
            } else {
                params = [:]
                paramsJSON = nil
            }

            if !record.keys.contains("id") {
                return .notification(JSONRPCNotification(method: method, params: params, paramsJSON: paramsJSON, raw: record))
            }
            guard let id = JSONRPCID(jsonValue: record["id"]) else {
                throw ProbeError.failure("Malformed JSON-RPC request ID")
            }
            return .request(JSONRPCRequest(id: id, method: method, params: params, paramsJSON: paramsJSON, raw: record))
        }

        if let rawError = record["error"], !(rawError is NSNull) {
            guard let errorDict = rawError as? Record,
                  let code = parseJSONInt(errorDict["code"]),
                  let message = errorDict["message"] as? String else {
                throw ProbeError.failure("Malformed JSON-RPC error object")
            }
            let dataJSON: Data?
            if let rawData = errorDict["data"], !(rawData is NSNull) {
                dataJSON = try? JSONSerialization.data(withJSONObject: rawData, options: [.fragmentsAllowed])
            } else {
                dataJSON = nil
            }
            if record["id"] == nil || record["id"] is NSNull {
                throw ProbeError.failure("JSON-RPC error \(code): \(message)")
            }
            guard let id = JSONRPCID(jsonValue: record["id"]) else {
                throw ProbeError.failure("Malformed JSON-RPC response ID")
            }
            let error = JSONRPCError(code: code, message: message, dataJSON: dataJSON)
            return .response(JSONRPCResponse(id: id, result: nil, resultJSON: nil, error: error, raw: record))
        }

        if record.keys.contains("result") {
            guard let id = JSONRPCID(jsonValue: record["id"]) else {
                throw ProbeError.failure("Malformed JSON-RPC response ID")
            }
            let resultValue = record["result"]
            let resultJSON: Data?
            if let value = resultValue, !(value is NSNull) {
                resultJSON = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            } else if resultValue is NSNull {
                resultJSON = Data("null".utf8)
            } else {
                resultJSON = nil
            }
            return .response(JSONRPCResponse(id: id, result: resultValue, resultJSON: resultJSON, error: nil, raw: record))
        }

        throw ProbeError.failure("Malformed JSON-RPC message")
    }

    // MARK: - Outbound Writing

    public typealias WriteGate = (() throws -> Void) throws -> Void

    public func raw(_ bytes: Data) throws {
        try raw(bytes, writeGate: nil)
    }

    private func raw(_ bytes: Data, writeGate: WriteGate?) throws {
        try writeLock.withLock {
            if isTransportEnding {
                try writeGate?({})
                throw ProbeError.failure("Connection is closing")
            }
            if supervisionStatusURL != nil && (!process.isRunning || supervisionStatus["state"] as? String != "running") {
                try writeGate?({})
                throw ProbeError.failure("Supervision unavailable; new commands blocked")
            }
            if bytes.isEmpty { return }
            let descriptor = input.fileHandleForWriting.fileDescriptor
            let deadline = ContinuousClock.now + .seconds(5)
            try bytes.withUnsafeBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    guard !isTransportEnding else {
                        if offset == 0 { try writeGate?({}) }
                        throw ProbeError.failure("Connection is closing")
                    }
                    var count = 0
                    var writeError: Int32 = 0
                    let write = {
                        count = Darwin.write(descriptor, address.advanced(by: offset), buffer.count - offset)
                        if count < 0 { writeError = errno }
                    }
                    // A frame starts on its first successful write. Until then retirement can reject it.
                    if offset == 0, let writeGate { try writeGate(write) }
                    else { write() }
                    if count > 0 { offset += count; continue }
                    if ContinuousClock.now >= deadline {
                        failProtocol("Protocol write timed out")
                        throw ProbeError.failure("Protocol write timed out")
                    }
                    if writeError == EINTR { continue }
                    guard writeError == EAGAIN || writeError == EWOULDBLOCK else {
                        failProtocol("Protocol write failed")
                        throw ProbeError.failure("Protocol write failed")
                    }
                    var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&writable, 1, 50)
                }
            }
        }
    }

    public var isTransportEnding: Bool {
        lock.withLock { streamClosing || stdoutFinished || protocolFailure != nil }
    }

    private func sendObject(_ value: Record, kind: String, method: String?, id: JSONRPCID?,
                            writeGate: WriteGate? = nil) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ProbeError.failure("Invalid JSON-RPC payload")
        }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        try raw(data, writeGate: writeGate)
        lock.withLock {
            appendTimeline(direction: "send", kind: kind, method: method, id: id)
        }
    }

    /// Sends a JSON-RPC 2.0 request with an auto-incrementing integer ID and returns that ID immediately.
    @discardableResult
    public func sendRequest(method: String, params: Record? = nil, writeGate: WriteGate? = nil,
                            register: ((JSONRPCID) throws -> Void)? = nil) throws -> JSONRPCID {
        let id: JSONRPCID = try lock.withLock {
            guard !streamClosing else { throw ProbeError.failure("Connection is closing") }
            guard pendingRequests.count < maximumPendingRequests else {
                throw ProbeError.failure("Too many pending protocol requests")
            }
            let allocated = JSONRPCID.int(nextRequestID)
            nextRequestID += 1
            pendingRequests.insert(allocated)
            return allocated
        }
        return try sendPreparedRequest(id: id, method: method, params: params, writeGate: writeGate, register: register)
    }

    /// Sends a JSON-RPC 2.0 request using an explicit caller-provided ID (integer or string).
    @discardableResult
    public func sendRequest(id: JSONRPCID, method: String, params: Record? = nil) throws -> JSONRPCID {
        try lock.withLock {
            guard !streamClosing else { throw ProbeError.failure("Connection is closing") }
            guard pendingRequests.count < maximumPendingRequests else {
                throw ProbeError.failure("Too many pending protocol requests")
            }
            guard !pendingRequests.contains(id) else {
                throw ProbeError.failure("Duplicate pending JSON-RPC request ID")
            }
            pendingRequests.insert(id)
        }
        return try sendPreparedRequest(id: id, method: method, params: params)
    }

    private func sendPreparedRequest(id: JSONRPCID, method: String, params: Record?,
                                     writeGate: WriteGate? = nil, register: ((JSONRPCID) throws -> Void)? = nil) throws -> JSONRPCID {
        var payload: Record = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        do {
            try register?(id)
            try sendObject(payload, kind: "request", method: method, id: id, writeGate: writeGate)
            return id
        } catch {
            lock.withLock {
                pendingRequests.remove(id)
                responses.removeValue(forKey: id)
                responseHandlers.removeValue(forKey: id)
            }
            throw error
        }
    }

    /// Sends a JSON-RPC 2.0 notification (no `id` member).
    public func sendNotification(method: String, params: Record? = nil) throws {
        var payload: Record = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try sendObject(payload, kind: "notification", method: method, id: nil)
    }

    /// Sends a JSON-RPC 2.0 success response echoing the exact raw `id` type (`Int` or `String`).
    public func sendResponse(id: JSONRPCID, result: Any) throws {
        let payload: Record = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result
        ]
        try sendObject(payload, kind: "response", method: nil, id: id)
    }

    /// Sends a JSON-RPC 2.0 error response echoing the exact raw `id` type (`Int` or `String`).
    public func sendErrorResponse(id: JSONRPCID, code: Int, message: String, data: Any? = nil) throws {
        var errorObject: Record = [
            "code": code,
            "message": message
        ]
        if let data {
            errorObject["data"] = data
        }
        let payload: Record = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": errorObject
        ]
        try sendObject(payload, kind: "error_response", method: nil, id: id)
    }

    // MARK: - Response Awaiting (Synchronous, Callback, and Async)

    /// Registers a non-blocking completion callback for a pending request ID.
    /// Invoked on a dedicated serial callback queue so the stdout reader thread never blocks.
    public func onResponse(id: JSONRPCID, handler: @escaping @Sendable (Result<JSONRPCResponse, Error>) -> Void) {
        let immediate: Result<JSONRPCResponse, Error>? = lock.withLock {
            if let response = responses.removeValue(forKey: id) {
                pendingRequests.remove(id)
                return .success(response)
            }
            if let failure = protocolFailure {
                pendingRequests.remove(id)
                return .failure(ProbeError.failure(failure))
            }
            if streamClosing {
                pendingRequests.remove(id)
                return .failure(ProbeError.failure("Connection is closing"))
            }
            if stdoutFinished {
                pendingRequests.remove(id)
                return .failure(ProbeError.failure("Protocol EOF before expected response"))
            }
            guard pendingRequests.contains(id) else {
                return .failure(CancellationError())
            }
            responseHandlers[id] = handler
            return nil
        }
        if let immediate {
            callbackQueue.async { handler(immediate) }
        }
    }

    /// Cancels local waiting and optionally requests cancellation at the peer.
    /// A received response wins over a concurrent cancellation.
    @discardableResult
    public func cancelPendingRequest(_ id: JSONRPCID, error: Error = CancellationError(),
                                     notifyPeer: Bool = false) -> Bool {
        let claim = lock.withLock {
            guard responses[id] == nil, pendingRequests.remove(id) != nil else {
                return (false, nil as (@Sendable (Result<JSONRPCResponse, Error>) -> Void)?)
            }
            let handler = responseHandlers.removeValue(forKey: id)
            lock.broadcast()
            return (true, handler)
        }
        guard claim.0 else { return false }
        if let handler = claim.1 {
            callbackQueue.async { handler(.failure(error)) }
        }
        if notifyPeer {
            try? sendNotification(method: "$/cancel_request", params: ["requestId": id.jsonValue])
        }
        return true
    }

    public func hasPendingRequest(_ id: JSONRPCID) -> Bool {
        lock.withLock { pendingRequests.contains(id) && responses[id] == nil }
    }

    /// Synchronously waits for the response to a previously submitted request ID.
    /// Supports concurrent long-running requests (e.g. `session/prompt`) alongside short control requests.
    public func waitResponse(
        id: JSONRPCID,
        timeout: Double = 5,
        extendingDeadline: (() -> Date?)? = nil
    ) throws -> JSONRPCResponse {
        defer {
            lock.withLock {
                pendingRequests.remove(id)
                responses.removeValue(forKey: id)
                responseHandlers.removeValue(forKey: id)
            }
        }
        let baseDeadline: Date? = timeout.isFinite ? Date().addingTimeInterval(timeout) : nil
        while true {
            let effectiveDeadline: Date?
            if let baseDeadline {
                effectiveDeadline = max(baseDeadline, extendingDeadline?() ?? baseDeadline)
            } else {
                effectiveDeadline = nil
            }

            let stepResult: Result<JSONRPCResponse, Error>? = lock.withLock {
                if let response = responses.removeValue(forKey: id) {
                    pendingRequests.remove(id)
                    return .success(response)
                }
                if let failure = protocolFailure {
                    return .failure(ProbeError.failure(failure))
                }
                if streamClosing {
                    return .failure(ProbeError.failure("Connection is closing"))
                }
                if stdoutFinished {
                    return .failure(ProbeError.failure("Protocol EOF before expected response"))
                }
                if !pendingRequests.contains(id) {
                    return .failure(CancellationError())
                }
                let now = Date()
                if let effectiveDeadline, now >= effectiveDeadline {
                    return .failure(ProbeError.failure("Deadline exceeded; outcome unknown"))
                }
                let sliceEnd = now.addingTimeInterval(0.05)
                let wakeTime = effectiveDeadline.map { min($0, sliceEnd) } ?? sliceEnd
                lock.wait(until: wakeTime)
                return nil
            }

            if let stepResult {
                return try stepResult.get()
            }
            if supervisionStatusURL != nil && !process.isRunning && supervisionStatus["state"] as? String != "clean" {
                throw ProbeError.failure("Supervisor exited without confirmed cleanup")
            }
        }
    }

    /// Convenience synchronous request + waitResponse.
    public func request(method: String, params: Record? = nil, timeout: Double = 5) throws -> JSONRPCResponse {
        let id = try sendRequest(method: method, params: params)
        return try waitResponse(id: id, timeout: timeout)
    }

    /// Async non-blocking await for a previously submitted request ID (holds no blocking thread while waiting).
    public func awaitResponse(id: JSONRPCID, timeout: Double? = 5, notifyPeerOnCancel: Bool = false) async throws -> JSONRPCResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONRPCResponse, Error>) in
                let waiter = OneShotResponseWaiter(continuation)
                self.onResponse(id: id) { result in
                    waiter.resume(with: result)
                }
                if Task.isCancelled {
                    self.cancelPendingRequest(id, notifyPeer: notifyPeerOnCancel)
                }
                if let timeout, timeout.isFinite {
                    let clamped = max(0, timeout)
                    let timer = Task.detached { [weak self] in
                        try? await Task.sleep(for: .seconds(clamped))
                        guard !Task.isCancelled else { return }
                        let error = ProbeError.failure("Deadline exceeded; outcome unknown")
                        _ = self?.cancelPendingRequest(id, error: error, notifyPeer: notifyPeerOnCancel)
                    }
                    waiter.attachTimeout(timer)
                }
            }
        } onCancel: {
            self.cancelPendingRequest(id, notifyPeer: notifyPeerOnCancel)
        }
    }

    // MARK: - Inbound Queue Observation (Requests & Notifications)

    /// Drains all currently buffered inbound requests and notifications in wire order, releasing backpressure.
    public func drainInbound() -> (messages: [JSONRPCInboundMessage], ended: Bool, failure: String?) {
        lock.withLock {
            let batch = inboundMessages
            inboundMessages = []
            inboundSizes = []
            inboundBytes = 0
            lock.broadcast()
            return (batch, stdoutFinished, protocolFailure)
        }
    }

    /// Waits up to `timeout` seconds for at least one inbound message (or EOF/failure/closing), then drains the batch.
    public func waitInbound(timeout: Double = 0.05) -> (messages: [JSONRPCInboundMessage], ended: Bool, failure: String?) {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        return lock.withLock {
            while inboundMessages.isEmpty && !stdoutFinished && !streamClosing && protocolFailure == nil && Date() < deadline {
                lock.wait(until: deadline)
            }
            let batch = inboundMessages
            inboundMessages = []
            inboundSizes = []
            inboundBytes = 0
            lock.broadcast()
            return (batch, stdoutFinished, protocolFailure)
        }
    }

    /// Wait without claiming frames when a caller also serializes response dispatch.
    public func waitForInboundActivity(timeout: Double) {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        lock.withLock {
            while inboundMessages.isEmpty && !stdoutFinished && !streamClosing && protocolFailure == nil && Date() < deadline {
                lock.wait(until: deadline)
            }
        }
    }

    private func waitNextInbound(timeout: Double) -> JSONRPCInboundMessage? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        return lock.withLock {
            while inboundMessages.isEmpty && !stdoutFinished && !streamClosing && protocolFailure == nil && Date() < deadline {
                lock.wait(until: deadline)
            }
            guard !inboundMessages.isEmpty else { return nil }
            let first = inboundMessages.removeFirst()
            let size = inboundSizes.removeFirst()
            inboundBytes = max(0, inboundBytes - size)
            lock.broadcast()
            return first
        }
    }

    private var isInboundEnded: Bool {
        lock.withLock {
            inboundMessages.isEmpty && (stdoutFinished || streamClosing || protocolFailure != nil)
        }
    }

    /// Returns a bounded ordered `AsyncStream` of inbound requests and notifications.
    /// Use either `inboundStream()` or `drainInbound()`/`waitInbound()` from a single consumer.
    public func inboundStream() -> AsyncStream<JSONRPCInboundMessage> {
        AsyncStream { continuation in
            let pump = Task.detached { [self] in
                while !Task.isCancelled {
                    if let message = self.waitNextInbound(timeout: 0.05) {
                        continuation.yield(message)
                    } else if self.isInboundEnded {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }

    // MARK: - Shutdown & Diagnostics

    public func close(timeout: Double = 5) throws {
        let orphanedHandlers: [@Sendable (Result<JSONRPCResponse, Error>) -> Void] = lock.withLock {
            streamClosing = true
            let handlers = Array(responseHandlers.values)
            responseHandlers.removeAll()
            lock.broadcast()
            return handlers
        }
        if !orphanedHandlers.isEmpty {
            let error = ProbeError.failure("Connection is closing")
            callbackQueue.async {
                for handler in orphanedHandlers { handler(.failure(error)) }
            }
        }

        writeLock.withLock { try? input.fileHandleForWriting.close() }

        let until = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < until {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            if supervisionStatusURL != nil {
                _ = runtimeIdentity?.signal(SIGTERM)
            } else {
                process.terminate()
            }
            let grace = Date().addingTimeInterval(4)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                if supervisionStatusURL != nil {
                    _ = runtimeIdentity?.signal(SIGKILL)
                } else {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            throw ProbeError.failure("Orderly shutdown exceeded deadline; escalated")
        }
        if supervisionStatusURL != nil && supervisionStatus["state"] as? String != "clean" {
            throw ProbeError.failure("Descendant cleanup unconfirmed; execution slot must stay blocked")
        }
    }

    public func crash() {
        if supervisionStatusURL != nil {
            _ = runtimeIdentity?.signal(SIGKILL)
        } else {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    public func trace() -> Record {
        let report = supervisionStatus
        return lock.withLock {
            [
                "instanceID": instanceID,
                "timeline": timeline,
                "lastSupervisorReport": report,
                "supervisorRunning": process.isRunning
            ]
        }
    }

    // MARK: - Reader Threads

    private func readStdoutLoop(maximumRecordBytes: Int) {
        var decoder = JSONLDecoder(maximumRecordBytes: maximumRecordBytes)
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            var size: Int
            repeat {
                size = buffer.withUnsafeMutableBytes {
                    Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
            } while size < 0 && errno == EINTR

            if size < 0 {
                failProtocol("Protocol pipe read failed")
                break
            }
            if size == 0 {
                break
            }

            let chunk = Data(buffer.prefix(size))
            do {
                let records = try decoder.feed(chunk)
                for (index, record) in records.enumerated() {
                    let frame = try Self.classify(record)
                    let recordBytes = decoder.decodedSizes[index]
                    routeInboundFrame(frame, recordBytes: recordBytes)
                }
            } catch let error as ProbeError {
                failProtocol(error.description)
                break
            } catch {
                failProtocol("Malformed protocol record")
                break
            }
        }

        let (remainingHandlers, terminalMessage): ([@Sendable (Result<JSONRPCResponse, Error>) -> Void], String) = lock.withLock {
            if !decoder.pending.isEmpty && protocolFailure == nil {
                protocolFailure = "Incomplete protocol record at EOF"
            }
            stdoutFinished = true
            let handlers = Array(responseHandlers.values)
            responseHandlers.removeAll()
            let message = protocolFailure ?? "Protocol EOF before expected response"
            lock.broadcast()
            return (handlers, message)
        }
        if !remainingHandlers.isEmpty {
            let error = ProbeError.failure(terminalMessage)
            callbackQueue.async {
                for handler in remainingHandlers { handler(.failure(error)) }
            }
        }
    }

    private func routeInboundFrame(_ frame: JSONRPCWireFrame, recordBytes: Int) {
        switch frame {
        case .response(var response):
            let matchedHandler: (@Sendable (Result<JSONRPCResponse, Error>) -> Void)? = lock.withLock {
                receivedCount += 1
                response.receiveOrder = receivedCount
                appendTimeline(direction: "receive", kind: response.isError ? "error_response" : "response", method: nil, id: response.id)
                if let handler = responseHandlers.removeValue(forKey: response.id) {
                    pendingRequests.remove(response.id)
                    return handler
                }
                if pendingRequests.contains(response.id) {
                    responses[response.id] = response
                    lock.broadcast()
                }
                return nil
            }
            if let matchedHandler {
                callbackQueue.async { [response] in matchedHandler(.success(response)) }
            }

        case .request(let request):
            enqueueInbound(.request(request), recordBytes: recordBytes, kind: "request", method: request.method, id: request.id)

        case .notification(let notification):
            enqueueInbound(.notification(notification), recordBytes: recordBytes, kind: "notification", method: notification.method, id: nil)
        }
    }

    private func enqueueInbound(_ message: JSONRPCInboundMessage, recordBytes: Int, kind: String, method: String, id: JSONRPCID?) {
        lock.withLock {
            receivedCount += 1
            while !streamClosing && !inboundMessages.isEmpty &&
                    (inboundMessages.count >= maximumQueueCount || inboundBytes + recordBytes > maximumQueueBytes) {
                lock.wait()
            }
            if streamClosing { return }
            if case .notification(var notification) = message {
                notification.receiveOrder = receivedCount
                inboundMessages.append(.notification(notification))
            } else {
                inboundMessages.append(message)
            }
            inboundSizes.append(recordBytes)
            inboundBytes += recordBytes
            appendTimeline(direction: "receive", kind: kind, method: method, id: id)
            lock.broadcast()
        }
    }

    private func failProtocol(_ reason: String) {
        let handlers: [@Sendable (Result<JSONRPCResponse, Error>) -> Void] = lock.withLock {
            if protocolFailure == nil { protocolFailure = reason }
            let drained = Array(responseHandlers.values)
            responseHandlers.removeAll()
            lock.broadcast()
            return drained
        }
        if !handlers.isEmpty {
            let error = ProbeError.failure(reason)
            callbackQueue.async {
                for handler in handlers { handler(.failure(error)) }
            }
        }
    }

    private func readStderrLoop() {
        while true {
            let data = diagnostic.fileHandleForReading.availableData
            if data.isEmpty { break }
            lock.withLock {
                if stderrBytes.count < 65_536 {
                    stderrBytes.append(data.prefix(65_536 - stderrBytes.count))
                }
            }
        }
    }

    private func appendTimeline(direction: String, kind: String, method: String?, id: JSONRPCID?) {
        if timeline.count >= 1_024 { timeline.removeFirst(512) }
        timeline.append([
            "direction": direction,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "kind": kind,
            "method": method ?? NSNull(),
            "id": id?.jsonValue ?? NSNull()
        ])
    }
}
