import Foundation

public struct TokenUsage: Sendable, Equatable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var total: Int?
    public var inputIsUncached: Bool
    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil, total: Int? = nil, inputIsUncached: Bool = false) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.total = total; self.inputIsUncached = inputIsUncached
    }
}
public struct ContextUsage: Sendable, Equatable {
    public var tokens: Int?
    public var window: Int?
    public var percent: Double?
    public init(tokens: Int? = nil, window: Int? = nil, percent: Double? = nil) { self.tokens = tokens; self.window = window; self.percent = percent }
}
public struct RuntimeUsage: Sendable, Equatable {
    public let sessionID: String
    public var tokens: TokenUsage
    public var estimatedCostUSD: Double?
    public var context: ContextUsage?
    public var note: String?
    public let observedAt: Date
    public init(sessionID: String, tokens: TokenUsage = .init(), estimatedCostUSD: Double? = nil, context: ContextUsage? = nil, note: String? = nil, observedAt: Date = Date()) {
        self.sessionID = sessionID; self.tokens = tokens; self.estimatedCostUSD = estimatedCostUSD; self.context = context; self.note = note; self.observedAt = observedAt
    }
}
public enum InteractionKind: String, Sendable { case select, confirm, input, editor }
public struct RuntimeToolApproval: Sendable, Equatable {
    public struct Replacement: Codable, Sendable, Equatable {
        public let oldText: String
        public let newText: String
    }
    public enum Inspection: String, Sendable {
        case read, grep, find, ls
    }
    public struct Argument: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public enum Operation: Sendable, Equatable {
        case command(text: String, timeoutSeconds: Double?)
        case write(path: String, content: String)
        case edit(path: String, replacements: [Replacement])
        case inspect(Inspection, arguments: [Argument])
    }

    public let workingDirectory: String
    public let operation: Operation

    public init(workingDirectory: String, operation: Operation) {
        self.workingDirectory = workingDirectory
        self.operation = operation
    }
}

public struct RuntimeInteraction: Identifiable, Sendable, Equatable {
    public var id: String { instanceID.uuidString + ":" + requestID }
    public let instanceID: UUID
    public let requestID: String
    public let kind: InteractionKind
    public let title: String
    public let message: String
    public let options: [String]
    public let placeholder: String
    public let prefill: String
    public let expiresAt: Date
    public let toolApproval: RuntimeToolApproval?
    public init(instanceID: UUID, requestID: String, kind: InteractionKind, title: String, message: String = "", options: [String] = [], placeholder: String = "", prefill: String = "", expiresAt: Date = Date().addingTimeInterval(300), toolApproval: RuntimeToolApproval? = nil) {
        self.instanceID = instanceID; self.requestID = requestID; self.kind = kind; self.title = title; self.message = message
        self.options = options; self.placeholder = placeholder; self.prefill = prefill; self.expiresAt = expiresAt
        self.toolApproval = toolApproval
    }
}
public enum InteractionResponse: Sendable, Equatable { case value(String), confirmed(Bool), cancelled }
public enum InteractionEnd: String, Sendable { case answered, cancelled, expired, disconnected }

/// A pull-driven bounded channel. Only adjacent presentation updates coalesce;
/// lifecycle events retain order, and producers wait rather than drop them.
public final class RuntimeEventChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [RuntimeEnvelope] = []
    private var ended = false
    private let capacity: Int
    public init(capacity: Int = 128) { self.capacity = max(2, capacity) }
    public func stream() -> AsyncStream<RuntimeEnvelope> {
        AsyncStream(unfolding: { [self] in await Task.detached { self.take() }.value }, onCancel: { [self] in finish() })
    }
    public func send(_ value: RuntimeEnvelope) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        if let last = queue.last, last.instanceID == value.instanceID {
            if case .textDelta(let a, let ai, let old) = last.event,
               case .textDelta(let b, let bi, let next) = value.event, a == b, ai == bi, old.utf8.count + next.utf8.count <= 65_536 {
                queue[queue.count - 1] = .init(instanceID: value.instanceID, event: .textDelta(a, ai, old + next)); return
            }
            if case .tool(let a) = last.event, case .tool(let b) = value.event, a.id == b.id, a.state == .running {
                queue[queue.count - 1] = value; return
            }
        }
        while queue.count >= capacity && !ended { condition.wait() }
        guard !ended else { return }
        queue.append(value); condition.broadcast()
    }
    private func take() -> RuntimeEnvelope? {
        condition.lock(); defer { condition.unlock() }
        while queue.isEmpty && !ended { condition.wait() }
        guard !queue.isEmpty else { return nil }
        let origin = queue[0].instanceID
        let count = queue.prefix(32).prefix(while: { $0.instanceID == origin }).count
        let batch = Array(queue.prefix(count)); queue.removeFirst(count); condition.broadcast()
        if batch.count == 1 { return batch[0] }
        return .init(instanceID: batch[0].instanceID, event: .batch(batch.map(\.event)))
    }
    public func finish() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
    public var bufferedCount: Int { condition.lock(); defer { condition.unlock() }; return queue.count }
}
