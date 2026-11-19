import Foundation
import AgentRuntimeCore
import M0Support

/// Claims are atomic; no UI dismissal or duplicate can cause a second response.
final class PiInteractionBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: RuntimeInteraction] = [:]
    private var seen = Set<String>()
    private var revision = 0
    private var paused = false
    private var lastChange = Date.distantPast
    var interactionRevision: Int { lock.withLock { revision } }
    func acknowledgementDeadline(since start: Int) -> Date? {
        lock.withLock {
            guard revision > start else { return nil }
            return max(lastChange, pending.values.map(\.expiresAt).max() ?? .distantPast).addingTimeInterval(5)
        }
    }
    private let instanceID: UUID
    private let native: Bool
    private let write: @Sendable (Record) throws -> Void
    private let emit: @Sendable (AgentEvent) -> Void
    init(instanceID: UUID, native: Bool, write: @escaping @Sendable (Record) throws -> Void, emit: @escaping @Sendable (AgentEvent) -> Void) {
        self.instanceID = instanceID; self.native = native; self.write = write; self.emit = emit
    }
    func pause() { lock.withLock { paused = true } }
    func resume() { lock.withLock { paused = false } }
    func accept(_ record: Record, now: Date = Date()) throws {
        guard let method = record["method"] as? String, let kind = InteractionKind(rawValue: method), let id = record["id"] as? String,
              !id.isEmpty, id.utf8.count <= 4_096 else {
            throw RuntimeFailure(.protocolError, "扩展交互请求缺少有效标识或类型。")
        }
        let fresh = try lock.withLock {
            if seen.contains(id) { return false }
            guard seen.count < 4_096, pending.count < 16 else { throw RuntimeFailure(.unsupportedInteraction, "扩展交互超过当前会话上限，请结束运行时后重新激活。") }
            seen.insert(id); return true
        }
        guard fresh else { return }
        guard native else { try write(["type":"extension_ui_response","id":id,"cancelled":true]); emit(.notice("当前兼容模式自动取消了扩展交互。")); return }
        let title = record["title"] as? String ?? "扩展交互", message = record["message"] as? String ?? ""
        let options = record["options"] as? [String] ?? [], placeholder = record["placeholder"] as? String ?? "", prefill = record["prefill"] as? String ?? ""
        guard id.utf8.count <= 4_096, title.utf8.count <= 4_096, message.utf8.count <= 65_536,
              placeholder.utf8.count <= 8_192, prefill.utf8.count <= 1_048_576,
              options.count <= 512, options.allSatisfy({ $0.utf8.count <= 8_192 }), kind != .select || !options.isEmpty else {
            try write(["type":"extension_ui_response","id":id,"cancelled":true]); emit(.notice("扩展交互内容无效或超过显示上限，已取消；没有截断确认内容。")); return
        }
        let milliseconds = (record["timeout"] as? NSNumber)?.doubleValue
        if let milliseconds, !milliseconds.isFinite || milliseconds < 0 {
            try write(["type":"extension_ui_response","id":id,"cancelled":true]); return
        }
        // Pi 1.5.2 emits no expiry notification. Use a conservative local limit,
        // cancel before the advertised TTL, and also retire on command completion.
        let duration = milliseconds.map { min(300, max(0, ($0 - 50) / 1_000)) } ?? 300
        let request = RuntimeInteraction(instanceID: instanceID, requestID: id, kind: kind, title: title, message: message,
                                         options: options, placeholder: placeholder, prefill: prefill, expiresAt: now.addingTimeInterval(duration))
        let accepted = lock.withLock {
            guard !paused else { return false }
            pending[id] = request; revision += 1; lastChange = now
            emit(.interaction(request))
            return true
        }
        guard accepted else { try write(["type":"extension_ui_response","id":id,"cancelled":true]); return }
        try expire(now: now)
    }
    func respond(_ request: RuntimeInteraction, _ response: InteractionResponse, now: Date = Date()) throws {
        guard request.instanceID == instanceID else { throw RuntimeFailure(.unsupportedInteraction, "交互来自已结束的执行实例。") }
        try expire(now: now)
        try lock.withLock {
            guard !paused, let current = pending[request.requestID], current == request else { throw RuntimeFailure(.unsupportedInteraction, "该交互已结束或过期。") }
            var fields: Record = ["type":"extension_ui_response","id":request.requestID]
            switch response {
            case .cancelled: fields["cancelled"] = true
            case .confirmed(let yes):
                guard current.kind == .confirm else { throw RuntimeFailure(.unsupportedInteraction, "回复类型不匹配。") }; fields["confirmed"] = yes
            case .value(let value):
                guard current.kind != .confirm, value.utf8.count <= 1_048_576,
                      current.kind != .select || current.options.contains(value) else { throw RuntimeFailure(.unsupportedInteraction, "请输入有效内容；文本不能超过 1 MiB。") }
                fields["value"] = value
            }
            pending.removeValue(forKey: request.requestID); lastChange = now
            try write(fields)
        }
        emit(.interactionEnded(request.id, response == .cancelled ? .cancelled : .answered))
    }
    func expire(now: Date = Date()) throws {
        let expired = lock.withLock {
            let values = pending.values.filter { $0.expiresAt <= now }
            for value in values { pending.removeValue(forKey: value.requestID) }; if !values.isEmpty { lastChange = now }; return values
        }
        for request in expired {
            emit(.interactionEnded(request.id, .expired)); try write(["type":"extension_ui_response","id":request.requestID,"cancelled":true])
        }
    }
    func cancelAll(reason: InteractionEnd = .cancelled, send: Bool = true) {
        let requests = lock.withLock { let values = Array(pending.values); pending.removeAll(); if !values.isEmpty { lastChange = Date() }; return values }
        for request in requests {
            emit(.interactionEnded(request.id, reason))
            if send { try? write(["type":"extension_ui_response","id":request.requestID,"cancelled":true]) }
        }
    }
}
