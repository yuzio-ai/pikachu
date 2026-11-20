import Foundation
import AgentRuntimeCore
import ProcessSupervision

private struct ToolApprovalMessage: Decodable {
    static let prefix = "pikachu.tool-approval.v1\n"
    let approval: RuntimeToolApproval

    private enum Tool: String, Decodable { case bash, write, edit, read, grep, find, ls }
    private enum CodingKeys: CodingKey { case tool, workingDirectory, parameters }
    private enum Parameter: String, CodingKey, CaseIterable {
        case command, timeout, path, content, edits, pattern, glob, offset, limit, ignoreCase, literal, context
    }

    init(from decoder: Decoder) throws {
        let envelope = try decoder.container(keyedBy: CodingKeys.self)
        let tool = try envelope.decode(Tool.self, forKey: .tool)
        let directory = try envelope.decode(String.self, forKey: .workingDirectory)
        let parameters = try envelope.nestedContainer(keyedBy: Parameter.self, forKey: .parameters)
        let operation: RuntimeToolApproval.Operation
        switch tool {
        case .bash:
            operation = .command(text: try parameters.decode(String.self, forKey: .command),
                                 timeoutSeconds: try parameters.decodeIfPresent(Double.self, forKey: .timeout))
        case .write:
            operation = .write(path: try parameters.decode(String.self, forKey: .path),
                               content: try parameters.decode(String.self, forKey: .content))
        case .edit:
            operation = .edit(path: try parameters.decode(String.self, forKey: .path),
                              replacements: try parameters.decode([RuntimeToolApproval.Replacement].self, forKey: .edits))
        case .read, .grep, .find, .ls:
            guard let inspection = RuntimeToolApproval.Inspection(rawValue: tool.rawValue) else {
                throw DecodingError.dataCorruptedError(forKey: .tool, in: envelope, debugDescription: "Unknown inspection tool.")
            }
            let arguments: [RuntimeToolApproval.Argument] = try Parameter.allCases.compactMap { key in
                guard parameters.contains(key) else { return nil }
                let value: String
                switch key {
                case .path, .pattern, .glob:
                    value = try parameters.decode(String.self, forKey: key)
                case .offset, .limit, .context:
                    value = try parameters.decode(Decimal.self, forKey: key).description
                case .ignoreCase, .literal:
                    value = try parameters.decode(Bool.self, forKey: key).description
                case .command, .timeout, .content, .edits:
                    throw DecodingError.dataCorruptedError(forKey: key, in: parameters, debugDescription: "Unexpected inspection argument.")
                }
                return .init(name: key.rawValue, value: value)
            }
            operation = .inspect(inspection, arguments: arguments)
        }
        approval = .init(workingDirectory: directory, operation: operation)
    }
}

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
    private let toolApprovals: Bool
    private let write: @Sendable (Record) throws -> Void
    private let emit: @Sendable (AgentEvent) -> Void
    init(instanceID: UUID, native: Bool, toolApprovals: Bool = false, write: @escaping @Sendable (Record) throws -> Void, emit: @escaping @Sendable (AgentEvent) -> Void) {
        self.instanceID = instanceID; self.native = native; self.toolApprovals = toolApprovals
        self.write = write; self.emit = emit
    }
    func pause() { lock.withLock { paused = true } }
    func resume() { lock.withLock { paused = false } }
    func accept(_ record: Record, now: Date = Date()) throws {
        guard let method = record["method"] as? String, let kind = InteractionKind(rawValue: method), let id = record["id"] as? String,
              !id.isEmpty, id.utf8.count <= 4_096 else {
            throw RuntimeFailure(.protocolError, String(localized: "扩展交互请求缺少有效标识或类型。", bundle: #bundle))
        }
        let fresh = try lock.withLock {
            if seen.contains(id) { return false }
            guard seen.count < 4_096, pending.count < 16 else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "扩展交互超过当前会话上限，请结束运行时后重新激活。", bundle: #bundle)) }
            seen.insert(id); return true
        }
        guard fresh else { return }
        guard native else { try write(["type":"extension_ui_response","id":id,"cancelled":true]); emit(.notice(String(localized: "当前兼容模式自动取消了扩展交互。", bundle: #bundle))); return }
        let title = record["title"] as? String ?? String(localized: "扩展交互", bundle: #bundle), message = record["message"] as? String ?? ""
        let options = record["options"] as? [String] ?? [], placeholder = record["placeholder"] as? String ?? "", prefill = record["prefill"] as? String ?? ""
        guard id.utf8.count <= 4_096, title.utf8.count <= 4_096, message.utf8.count <= 65_536,
              placeholder.utf8.count <= 8_192, prefill.utf8.count <= 1_048_576,
              options.count <= 512, options.allSatisfy({ $0.utf8.count <= 8_192 }), kind != .select || !options.isEmpty else {
            try write(["type":"extension_ui_response","id":id,"cancelled":true]); emit(.notice(String(localized: "扩展交互内容无效或超过显示上限，已取消；没有截断确认内容。", bundle: #bundle))); return
        }
        let milliseconds = (record["timeout"] as? NSNumber)?.doubleValue
        if let milliseconds, !milliseconds.isFinite || milliseconds < 0 {
            try write(["type":"extension_ui_response","id":id,"cancelled":true]); return
        }
        var toolApproval: RuntimeToolApproval?
        if toolApprovals, kind == .confirm, message.hasPrefix(ToolApprovalMessage.prefix) {
            let data = Data(message.utf8.dropFirst(ToolApprovalMessage.prefix.utf8.count))
            guard let details = try? JSONDecoder().decode(ToolApprovalMessage.self, from: data),
                  !details.approval.workingDirectory.isEmpty else {
                try write(["type":"extension_ui_response","id":id,"cancelled":true])
                emit(.notice(String(localized: "扩展交互内容无效或超过显示上限，已取消；没有截断确认内容。", bundle: #bundle)))
                return
            }
            toolApproval = details.approval
        }
        // Pi 1.5.2 emits no expiry notification. Use a conservative local limit,
        // cancel before the advertised TTL, and also retire on command completion.
        let duration = milliseconds.map { min(300, max(0, ($0 - 50) / 1_000)) } ?? 300
        let request = RuntimeInteraction(instanceID: instanceID, requestID: id, kind: kind, title: title, message: message,
                                         options: options, placeholder: placeholder, prefill: prefill, expiresAt: now.addingTimeInterval(duration),
                                         toolApproval: toolApproval)
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
        guard request.instanceID == instanceID else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "交互来自已结束的执行实例。", bundle: #bundle)) }
        try expire(now: now)
        try lock.withLock {
            guard !paused, let current = pending[request.requestID], current == request else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "该交互已结束或过期。", bundle: #bundle)) }
            var fields: Record = ["type":"extension_ui_response","id":request.requestID]
            switch response {
            case .cancelled: fields["cancelled"] = true
            case .confirmed(let yes):
                guard current.kind == .confirm else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "回复类型不匹配。", bundle: #bundle)) }; fields["confirmed"] = yes
            case .value(let value):
                guard current.kind != .confirm, value.utf8.count <= 1_048_576,
                      current.kind != .select || current.options.contains(value) else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "请输入有效内容；文本不能超过 1 MiB。", bundle: #bundle)) }
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
