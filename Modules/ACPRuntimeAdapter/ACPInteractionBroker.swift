import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Atomic, single-claim broker for ACP v1 `session/request_permission` requests.
/// Preserves exact JSON-RPC `id` types (`Int` vs `String`), validates bounded payloads,
/// and guarantees at most one response per request across user reply, expiry, cancel, or disconnect.
final class ACPInteractionBroker: @unchecked Sendable {
    private struct ToolCallKey: Hashable {
        let sessionID: Data
        let toolCallID: Data
    }

    private struct PendingEntry {
        let rpcID: JSONRPCID
        var interaction: RuntimeInteraction
        var toolKey: ToolCallKey? = nil
        var toolCall: Record = [:]
        var elicitation: ACPElicitation? = nil
        var parentID: JSONRPCID? = nil
        var cancellation: Record { elicitation == nil ? ACPInteractionBroker.cancelledOutcomePayload() : ["action": "cancel"] }
    }

    static let defaultTimeoutSeconds: TimeInterval = 300
    static let maximumSeenRequests = 4_096
    static let maximumPendingRequests = 16
    static let maximumOptionCount = 32
    static let maximumIDBytes = 4_096
    static let maximumTitleBytes = 4_096
    static let maximumMessageBytes = 65_536
    static let maximumApprovalPayloadBytes = 16 * 1_024 * 1_024
    static let maximumPrettyPrintedRawInputBytes = 262_144
    static let maximumRetainedToolCallBytes = maximumApprovalPayloadBytes
    static let maximumRetainedCacheBytes = 16 * 1_024 * 1_024
    static let maximumOptionIDBytes = 512
    static let maximumOptionNameBytes = 1_024
    static let maximumPathCount = 256

    private let lock = NSLock()
    private var pending: [String: PendingEntry] = [:]
    private var seen = Set<String>()
    private var toolCalls: [ToolCallKey: Record] = [:]
    private var toolCallSizes: [ToolCallKey: Int] = [:]
    private var toolCallOrder: [ToolCallKey] = []
    private var retainedToolCallBytes = 0
    private var paused = false
    private var acceptedExternalIDs = Set<String>()

    private let instanceID: UUID
    private let sendResponse: @Sendable (JSONRPCID, Record) throws -> Void
    private let emit: @Sendable (AgentEvent) -> Void

    init(
        instanceID: UUID,
        sendResponse: @escaping @Sendable (JSONRPCID, Record) throws -> Void,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.instanceID = instanceID
        self.sendResponse = sendResponse
        self.emit = emit
    }

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    func pause() {
        lock.withLock { paused = true }
    }

    func resume() {
        lock.withLock { paused = false }
    }

    private static func interactionKey(for id: JSONRPCID) -> String {
        switch id {
        case .int(let value): return "i:\(value)"
        case .string(let value):
            // The presentation key must also survive Swift's canonical string equality.
            return "s:" + Data(value.utf8).base64EncodedString()
        }
    }

    static func cancelledOutcomePayload() -> Record {
        ["outcome": ["outcome": "cancelled"]]
    }

    static func selectedOutcomePayload(optionID: String) -> Record {
        ["outcome": ["outcome": "selected", "optionId": optionID]]
    }

    func accept(_ request: JSONRPCRequest, workingDirectory: String? = nil, now: Date = Date()) throws {
        if case .string(let id) = request.id, id.utf8.count > Self.maximumIDBytes - 2 {
            throw RuntimeFailure(.protocolError, String(localized: "权限请求缺少有效标识。", bundle: #bundle))
        }
        let key = Self.interactionKey(for: request.id)

        let fresh: Bool = try lock.withLock {
            if seen.contains(key) { return false }
            guard seen.count < Self.maximumSeenRequests, pending.count < Self.maximumPendingRequests else {
                throw RuntimeFailure(.unsupportedInteraction, String(localized: "权限请求超过当前会话上限，请结束运行时后重新激活。", bundle: #bundle))
            }
            seen.insert(key)
            return true
        }
        guard fresh else { return }

        let rawOptions = ACPPermissionOptionPayload.parseList(request.params["options"])
        guard !rawOptions.isEmpty, rawOptions.count <= Self.maximumOptionCount else {
            try sendResponse(request.id, Self.cancelledOutcomePayload())
            emit(.notice(String(localized: "权限请求选项无效或超过上限，已自动取消。", bundle: #bundle)))
            return
        }

        var uniqueIDs = Set<String>()
        var permissionOptions: [RuntimePermissionOption] = []
        for option in rawOptions {
            guard option.optionID.utf8.count <= Self.maximumOptionIDBytes,
                  option.name.utf8.count <= Self.maximumOptionNameBytes,
                  uniqueIDs.insert(option.optionID).inserted else {
                try sendResponse(request.id, Self.cancelledOutcomePayload())
                emit(.notice(String(localized: "权限请求选项无效或超过上限，已自动取消。", bundle: #bundle)))
                return
            }
            let mappedKind = RuntimePermissionOption.Kind(rawValue: option.kind) ?? .other
            permissionOptions.append(RuntimePermissionOption(id: option.optionID, name: option.name, kind: mappedKind))
        }

        let patch = request.params["toolCall"] as? Record ?? [:]
        let toolKey = Self.toolKey(sessionID: request.params["sessionId"] as? String, toolCall: patch)
        if request.params["sessionId"] is String, toolKey == nil {
            try sendResponse(request.id, Self.cancelledOutcomePayload())
            return
        }
        let toolCall = lock.withLock {
            Self.mergeToolCall(patch, into: toolKey.flatMap { toolCalls[$0] } ?? [:])
        }
        if let status = toolCall["status"] as? String, status == "completed" || status == "failed" {
            try sendResponse(request.id, Self.cancelledOutcomePayload())
            return
        }
        guard let interaction = permissionInteraction(
            requestID: key, toolCall: toolCall, options: permissionOptions,
            sessionDirectory: workingDirectory, createdAt: now
        ) else {
            try sendResponse(request.id, Self.cancelledOutcomePayload())
            emit(.notice(String(localized: "权限请求内容超过显示上限，已自动取消；未截断确认内容。", bundle: #bundle)))
            return
        }

        let accepted: Bool = lock.withLock {
            guard !paused, pending.count < Self.maximumPendingRequests else { return false }
            if let toolKey { retainToolCall(toolCall, for: toolKey) }
            pending[key] = PendingEntry(rpcID: request.id, interaction: interaction, toolKey: toolKey, toolCall: toolCall)
            return true
        }
        guard accepted else {
            try sendResponse(request.id, Self.cancelledOutcomePayload())
            return
        }
        emit(.interaction(interaction))
        try expire(now: now)
    }

    func receiveToolUpdate(_ patch: Record, sessionID: String) {
        guard let updateKind = patch["sessionUpdate"] as? String,
              updateKind == "tool_call" || updateKind == "tool_call_update",
              let toolKey = Self.toolKey(sessionID: sessionID, toolCall: patch) else { return }

        let changes: (updated: [RuntimeInteraction], cancelled: [PendingEntry]) = lock.withLock {
            guard !paused else { return ([], []) }
            let prior = toolCalls[toolKey] ?? [:]
            retainToolCall(Self.mergeToolCall(patch, into: prior), for: toolKey)
            var updated: [RuntimeInteraction] = []
            var cancelled: [PendingEntry] = []
            for key in pending.keys.sorted() {
                guard var entry = pending[key], entry.toolKey == toolKey else { continue }
                let shown = entry.interaction
                let toolCall = Self.mergeToolCall(patch, into: entry.toolCall)
                let status = toolCall["status"] as? String
                guard status != "completed", status != "failed",
                      let current = permissionInteraction(
                        requestID: shown.requestID, toolCall: toolCall, options: shown.permissionOptions,
                        sessionDirectory: shown.permissionContext?.sessionDirectory, createdAt: shown.createdAt
                      ) else {
                    pending.removeValue(forKey: key)
                    cancelled.append(entry)
                    continue
                }

                if shown.permissionContext?.awaitingToolDetails == true {
                    entry.toolCall = toolCall
                    entry.interaction = current
                    pending[key] = entry
                    if current != shown { updated.append(current) }
                } else if !Self.sameApprovalTarget(shown, current) {
                    pending.removeValue(forKey: key)
                    cancelled.append(entry)
                }
            }
            return (updated, cancelled)
        }

        for update in changes.updated { emit(.interactionUpdated(update)) }
        for entry in changes.cancelled {
            try? sendResponse(entry.rpcID, entry.cancellation)
            emit(.interactionEnded(entry.interaction.id, .cancelled))
        }
        if !changes.cancelled.isEmpty {
            emit(.notice(String(localized: "操作详情已变化，请等待新的审批请求。", bundle: #bundle)))
        }
    }

    private static func toolKey(sessionID: String?, toolCall: Record) -> ToolCallKey? {
        guard let sessionID, !sessionID.isEmpty,
              let toolCallID = toolCall["toolCallId"] as? String, !toolCallID.isEmpty,
              toolCallID.utf8.count <= maximumIDBytes else { return nil }
        return ToolCallKey(sessionID: Data(sessionID.utf8), toolCallID: Data(toolCallID.utf8))
    }

    private static func mergeToolCall(_ patch: Record, into base: Record) -> Record {
        var merged = base
        for field in ["toolCallId", "title", "name", "kind", "status", "rawInput", "content", "locations"] {
            if let value = patch[field], !(value is NSNull) { merged[field] = value }
        }
        return merged
    }

    private func retainToolCall(_ toolCall: Record, for key: ToolCallKey) {
        // Bound retained input by total cache memory and entry count without blocking large tool calls.
        toolCallOrder.removeAll { $0 == key }
        if let previousSize = toolCallSizes.removeValue(forKey: key) {
            retainedToolCallBytes = max(0, retainedToolCallBytes - previousSize)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: toolCall),
              data.count <= Self.maximumRetainedToolCallBytes else {
            toolCalls.removeValue(forKey: key)
            return
        }
        while toolCallOrder.count >= 64 || (retainedToolCallBytes + data.count > Self.maximumRetainedCacheBytes && !toolCallOrder.isEmpty) {
            let evicted = toolCallOrder.removeFirst()
            toolCalls.removeValue(forKey: evicted)
            if let evictedSize = toolCallSizes.removeValue(forKey: evicted) {
                retainedToolCallBytes = max(0, retainedToolCallBytes - evictedSize)
            }
        }
        toolCalls[key] = toolCall
        toolCallSizes[key] = data.count
        retainedToolCallBytes += data.count
        toolCallOrder.append(key)
    }

    private static func sameApprovalTarget(_ lhs: RuntimeInteraction, _ rhs: RuntimeInteraction) -> Bool {
        guard let previous = lhs.permissionContext, let current = rhs.permissionContext else { return false }
        return lhs.toolApproval == rhs.toolApproval
            && sameUTF8(previous.toolKind, current.toolKind)
            && sameUTF8(previous.toolName, current.toolName)
            && sameUTF8(previous.workingDirectory, current.workingDirectory)
            && previous.paths.elementsEqual(current.paths, by: { $0.utf8.elementsEqual($1.utf8) })
            && previous.fileDiffs.elementsEqual(current.fileDiffs, by: { left, right in
                left.path.utf8.elementsEqual(right.path.utf8)
                    && sameUTF8(left.oldText, right.oldText)
                    && left.newText.utf8.elementsEqual(right.newText.utf8)
            })
            && sameUTF8(previous.rawInputJSON, current.rawInputJSON)
            && sameUTF8(previous.summary, current.summary)
    }

    private static func sameUTF8(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func serializeRawInput(_ value: Any) -> String? {
        let compactOptions: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        guard let compact = try? JSONSerialization.data(withJSONObject: value, options: compactOptions) else {
            return nil
        }
        if compact.count <= Self.maximumPrettyPrintedRawInputBytes,
           let pretty = try? JSONSerialization.data(withJSONObject: value, options: compactOptions.union(.prettyPrinted)) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: compact, as: UTF8.self)
    }

    private func permissionInteraction(
        requestID: String, toolCall: Record, options: [RuntimePermissionOption],
        sessionDirectory: String?, createdAt: Date
    ) -> RuntimeInteraction? {
        let toolCallID = toolCall["toolCallId"] as? String
        let toolTitle = (toolCall["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "工具权限请求", bundle: #bundle)
        let toolName = toolCall["name"] as? String
        let toolKind = (toolCall["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard [toolTitle, toolName, toolKind].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= Self.maximumTitleBytes }) else {
            return nil
        }

        let locations = toolCall["locations"] as? [Record] ?? []
        let paths = locations.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }
        let extracted = ACPJSON.extractToolContent(toolCall["content"])
        let diffs = extracted.diffs.map {
            RuntimePermissionContext.FileDiff(path: $0.path, oldText: $0.oldText, newText: $0.newText)
        }
        guard paths.count <= Self.maximumPathCount, diffs.count <= Self.maximumPathCount,
              (paths + diffs.map(\.path)).allSatisfy({ $0.utf8.count <= Self.maximumTitleBytes }) else { return nil }

        let rawInput = toolCall["rawInput"]
        let rawInputJSON = rawInput.flatMap { Self.serializeRawInput($0) }
        let input = rawInput as? Record ?? [:]
        let command = (input["CommandLine"] as? String) ?? (input["command"] as? String)
        let directory = (input["Cwd"] as? String) ?? (input["cwd"] as? String)
        let toolSummary = input["toolSummary"] as? String
        let message = extracted.text
        let diffBytes = diffs.reduce(0) { $0 + ($1.oldText?.utf8.count ?? 0) + $1.newText.utf8.count }
        let additionalDisplayFields = [command, directory, toolSummary].compactMap { $0 }
        guard rawInput == nil || rawInputJSON != nil,
              message.utf8.count + diffBytes <= Self.maximumApprovalPayloadBytes,
              (rawInputJSON?.utf8.count ?? 0) <= Self.maximumApprovalPayloadBytes,
              additionalDisplayFields.allSatisfy({ $0.utf8.count <= Self.maximumApprovalPayloadBytes }) else { return nil }

        let approval: RuntimeToolApproval?
        if toolKind == "execute", let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            approval = .init(workingDirectory: directory ?? sessionDirectory ?? "", operation: .command(text: command, timeoutSeconds: nil))
        } else {
            approval = nil
        }
        let awaitingDetails: Bool
        switch toolKind {
        case "execute":
            awaitingDetails = toolCallID != nil && approval == nil
        case "edit":
            awaitingDetails = toolCallID != nil && diffs.isEmpty
        case nil:
            // An update can supply input before the operation kind. A standard diff is
            // already reviewable, while arbitrary input is only shown in folded JSON.
            awaitingDetails = toolCallID != nil && (diffs.isEmpty || command != nil)
        default:
            let hasRawInputDetails: Bool
            switch rawInput {
            case let object as Record:
                hasRawInputDetails = !object.keys.allSatisfy { ["toolSummary", "Cwd", "cwd", "WaitMsBeforeAsync"].contains($0) }
            case let array as [Any]:
                hasRawInputDetails = !array.isEmpty
            case let text as String:
                hasRawInputDetails = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                hasRawInputDetails = rawInput != nil
            }
            awaitingDetails = toolCallID != nil && !hasRawInputDetails && diffs.isEmpty && paths.isEmpty && message.isEmpty
        }
        let context = RuntimePermissionContext(
            toolCallID: toolCallID, toolTitle: toolTitle, toolName: toolName, toolKind: toolKind,
            workingDirectory: directory, sessionDirectory: sessionDirectory, paths: paths,
            summary: message.isEmpty ? nil : message, toolSummary: toolSummary,
            rawInputJSON: rawInputJSON, diffs: diffs, awaitingToolDetails: awaitingDetails
        )
        return RuntimeInteraction(
            instanceID: instanceID, requestID: requestID, kind: .select, title: toolTitle, message: message,
            options: options.map(\.name), expiresAt: createdAt.addingTimeInterval(Self.defaultTimeoutSeconds),
            createdAt: createdAt, toolApproval: approval, permissionOptions: options, permissionContext: context
        )
    }

    func acceptElicitation(_ request: JSONRPCRequest, elicitation: ACPElicitation,
                           message: String, parentID: JSONRPCID?) throws {
        let interaction = RuntimeInteraction(
            instanceID: instanceID, requestID: Self.interactionKey(for: request.id), kind: .confirm,
            title: String(localized: "ACP Agent 请求信息", bundle: #bundle), message: message,
            elicitation: elicitation.display
        )
        let accepted: Bool? = lock.withLock {
            guard !seen.contains(interaction.requestID) else { return nil }
            guard !paused, seen.count < Self.maximumSeenRequests, pending.count < Self.maximumPendingRequests,
                  elicitation.externalID.map({ id in
                      !acceptedExternalIDs.contains(id) && !pending.values.contains { $0.elicitation?.externalID == id }
                  }) ?? true else { return false }
            seen.insert(interaction.requestID)
            pending[interaction.requestID] = PendingEntry(rpcID: request.id, interaction: interaction,
                                                          elicitation: elicitation, parentID: parentID)
            return true
        }
        guard let accepted else { return }
        if accepted {
            emit(.interaction(interaction))
        } else {
            try sendResponse(request.id, ["action": "cancel"])
        }
    }

    func completeElicitation(_ id: String) {
        let completed = lock.withLock { acceptedExternalIDs.remove(id) != nil }
        if completed {
            emit(.notice(String(localized: "ACP Agent 已确认外部交互完成。", bundle: #bundle)))
        }
    }

    func cancelLinkedRequests(_ parentID: JSONRPCID) {
        let ids = lock.withLock { pending.values.filter { $0.parentID == parentID }.map(\.rpcID) }
        for id in ids { cancel(id) }
    }

    func cancel(_ rpcID: JSONRPCID) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: Self.interactionKey(for: rpcID)) }) else { return }
        try? sendResponse(entry.rpcID, entry.cancellation)
        emit(.interactionEnded(entry.interaction.id, .cancelled))
    }

    func respond(_ request: RuntimeInteraction, _ response: InteractionResponse, now: Date = Date()) throws {
        guard request.instanceID == instanceID else {
            throw RuntimeFailure(.unsupportedInteraction, String(localized: "交互来自已结束的执行实例。", bundle: #bundle))
        }
        try expire(now: now)

        let payloadAndID: (JSONRPCID, Record) = try lock.withLock {
            guard !paused, let entry = pending[request.requestID], entry.interaction == request else {
                throw RuntimeFailure(.unsupportedInteraction, String(localized: "该权限请求已结束或过期。", bundle: #bundle))
            }
            if let elicitation = entry.elicitation {
                let payload = try elicitation.response(response)
                if let externalID = elicitation.externalID, payload["action"] as? String == "accept" {
                    acceptedExternalIDs.insert(externalID)
                }
                pending.removeValue(forKey: request.requestID)
                return (entry.rpcID, payload)
            }
            let payload: Record
            switch response {
            case .cancelled:
                payload = Self.cancelledOutcomePayload()
            case .value(let optionID):
                guard let option = entry.interaction.permissionOptions.first(where: { $0.id == optionID }),
                      entry.interaction.permissionContext?.awaitingToolDetails != true || option.isReject else {
                    throw RuntimeFailure(.unsupportedInteraction, String(localized: "所选权限选项无效。", bundle: #bundle))
                }
                payload = Self.selectedOutcomePayload(optionID: optionID)
            case .confirmed(let approved):
                let matched = entry.interaction.permissionOptions.first { approved ? $0.isAllow : $0.isReject }
                guard let matched, !approved || entry.interaction.permissionContext?.awaitingToolDetails != true else {
                    throw RuntimeFailure(.unsupportedInteraction, String(localized: "回复类型不匹配。", bundle: #bundle))
                }
                payload = Self.selectedOutcomePayload(optionID: matched.id)
            }
            pending.removeValue(forKey: request.requestID)
            return (entry.rpcID, payload)
        }

        try sendResponse(payloadAndID.0, payloadAndID.1)
        emit(.interactionEnded(request.id, response == .cancelled ? .cancelled : .answered))
    }

    func expire(now: Date = Date()) throws {
        let expired: [PendingEntry] = lock.withLock {
            let items = pending.values.filter { $0.interaction.expiresAt <= now }
                .sorted {
                    let lhs = $0.interaction, rhs = $1.interaction
                    if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.requestID < rhs.requestID
                }
            for item in items {
                pending.removeValue(forKey: item.interaction.requestID)
            }
            return items
        }
        // A cancellation reply can settle the turn. Publish the entire batch first.
        for entry in expired {
            emit(.interactionEnded(entry.interaction.id, .expired))
        }
        for entry in expired {
            try sendResponse(entry.rpcID, entry.cancellation)
        }
    }

    func cancelAll(reason: InteractionEnd = .cancelled, send: Bool = true) {
        let entries: [PendingEntry] = lock.withLock {
            let items = Array(pending.values)
            pending.removeAll()
            acceptedExternalIDs.removeAll()
            toolCalls.removeAll()
            toolCallSizes.removeAll()
            toolCallOrder.removeAll()
            retainedToolCallBytes = 0
            return items
        }
        for entry in entries {
            emit(.interactionEnded(entry.interaction.id, reason))
            if send {
                try? sendResponse(entry.rpcID, entry.cancellation)
            }
        }
    }
}
