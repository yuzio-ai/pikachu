import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Confined to the connection's event processing loop or tests.
/// Translates ACP v1 `session/update` notifications and turn settlement into domain `AgentEvent`s
/// or read-only `HistoryItem`s during `session/load` replay.
struct ACPEventMapper {
    struct MetadataUpdate: Sendable, Equatable {
        var currentModeID: String?
        var configOptions: [ACPConfigOption]?
        var usage: ACPUsageSnapshot?
    }

    private struct ToolProjection {
        var tool: RuntimeTool
        var hasRawInput = false
        var contentEdits: RuntimeTool.EditArguments?
        var titleSummary: String?
    }

    static let maximumArgumentsLength = 16_384
    static let maximumOutputLength = 65_536
    static let maximumThoughtLength = 4_000
    static let maximumPlanLength = 4_000

    var replayingHistory = false
    private var currentAssistant: UUID?
    private var currentAssistantMessageID: Data?
    private var currentAssistantText = ""
    var currentThoughtText = ""
    private var tools: [String: ToolProjection] = [:]
    var latestUsage: ACPUsageSnapshot?
    private(set) var replayedItems: [HistoryItem] = []
    private var replayedMessage: (id: Data?, index: Int)?
    private var replayedToolIndices: [String: Int] = [:]
    private var replayCounter = 0

    mutating func beginHistoryReplay() {
        replayingHistory = true
        replayedItems = []
        replayedToolIndices = [:]
        replayCounter = 0
        replayedMessage = nil
        currentAssistant = nil
        currentAssistantMessageID = nil
        currentAssistantText = ""
        currentThoughtText = ""
        tools = [:]
    }

    mutating func finishHistoryReplay() -> [HistoryItem] {
        replayingHistory = false
        let items = replayedItems
        replayedItems = []
        replayedMessage = nil
        replayedToolIndices = [:]
        tools = [:]
        return items
    }

    mutating func mapSessionUpdate(_ update: Record) -> (events: [AgentEvent], metadata: MetadataUpdate) {
        var metadata = MetadataUpdate()
        guard let kind = update["sessionUpdate"] as? String else { return ([], metadata) }

        switch kind {
        case "user_message_chunk", "agent_message_chunk":
            let isUser = kind == "user_message_chunk"
            // Live prompts already have a local user row with the original attachments.
            guard replayingHistory || !isUser else { return ([], metadata) }
            let messageID = (update["messageId"] as? String).map { Data($0.utf8) }
            let text = ACPJSON.textFromContentBlock(update["content"])
            let image = ACPJSON.imageDataFromContentBlock(update["content"])
            if replayingHistory {
                appendReplayedMessage(kind: isUser ? .user : .assistant, messageID: messageID, text: text, image: image)
                return ([], metadata)
            }
            var events: [AgentEvent] = []
            if currentAssistantMessageID != messageID, let completed = completeAssistant() {
                events.append(completed)
            }
            guard !text.isEmpty || image != nil else { return (events, metadata) }
            let id: UUID
            if let existing = currentAssistant {
                id = existing
            } else {
                id = UUID()
                currentAssistant = id
                currentAssistantMessageID = messageID
                events.append(.assistantStarted(id))
            }
            if !text.isEmpty {
                currentAssistantText += text
                events.append(.textDelta(id, 0, text))
            }
            if let image { events.append(.assistantImage(id, image)) }
            return (events, metadata)

        case "agent_thought_chunk":
            guard !replayingHistory else { return ([], metadata) }
            let text = ACPJSON.textFromContentBlock(update["content"])
            guard !text.isEmpty else { return ([], metadata) }
            if currentThoughtText.count < Self.maximumThoughtLength {
                let remaining = Self.maximumThoughtLength - currentThoughtText.count
                currentThoughtText += String(text.prefix(remaining))
            }
            return ([.thought(currentThoughtText)], metadata)

        case "tool_call", "tool_call_update":
            guard let toolCallID = update["toolCallId"] as? String, !toolCallID.isEmpty else {
                return ([], metadata)
            }
            var events: [AgentEvent] = []
            if !replayingHistory, currentAssistantMessageID == nil, let completed = completeAssistant() {
                // Without an ID, use the tool call to separate adjacent assistant messages.
                events.append(completed)
            }
            let tool = mergeTool(id: toolCallID, update: update, isCreation: kind == "tool_call")
            if replayingHistory {
                upsertReplayedTool(tool)
                return ([], metadata)
            }
            events.append(.tool(tool))
            return (events, metadata)

        case "plan":
            let entries = ACPPlanEntry.parseList(update["entries"])
            guard !replayingHistory else { return ([], metadata) }
            return ([.plan(Self.planEntries(from: entries))], metadata)

        case "usage_update":
            let snapshot = ACPUsageSnapshot.parse(update)
            latestUsage = snapshot
            metadata.usage = snapshot
            return ([], metadata)

        case "current_mode_update":
            if let modeID = update["currentModeId"] as? String, !modeID.isEmpty {
                metadata.currentModeID = modeID
            }
            return ([], metadata)

        case "config_option_update":
            metadata.configOptions = ACPConfigOption.parseList(update["configOptions"])
            return ([], metadata)

        default:
            return ([], metadata)
        }
    }

    mutating func finishTurn(stopReason: ACPStopReason) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let completed = completeAssistant() { events.append(completed) }
        if !currentThoughtText.isEmpty {
            currentThoughtText = ""
            events.append(.thought(nil))
        }
        tools.removeAll()
        switch stopReason {
        case .endTurn:
            events.append(.settled(aborted: false))
        case .cancelled:
            events.append(.settled(aborted: true))
        case .maxTokens:
            events.append(.notice(String(localized: "模型达到输出长度上限，回复已提前结束。", bundle: #bundle)))
            events.append(.settled(aborted: false))
        case .maxTurnRequests:
            events.append(.notice(String(localized: "本轮工具调用次数达到上限，任务已暂停。", bundle: #bundle)))
            events.append(.settled(aborted: false))
        case .refusal:
            events.append(.failure(.init(.model, String(localized: "模型拒绝了该请求。", bundle: #bundle))))
            events.append(.settled(aborted: false))
        }
        return events
    }

    mutating func finishTurnWithError(_ failure: RuntimeFailure) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let completed = completeAssistant() { events.append(completed) }
        if !currentThoughtText.isEmpty {
            currentThoughtText = ""
            events.append(.thought(nil))
        }
        tools.removeAll()
        events.append(.failure(failure))
        if !failure.kind.leavesTurnOutcomeUnknown { events.append(.settled(aborted: false)) }
        return events
    }

    private mutating func completeAssistant() -> AgentEvent? {
        guard let id = currentAssistant else { return nil }
        let event = AgentEvent.assistantCompleted(id, currentAssistantText)
        currentAssistant = nil
        currentAssistantMessageID = nil
        currentAssistantText = ""
        return event
    }

    private mutating func appendReplayedMessage(kind: HistoryItemKind, messageID: Data?, text: String, image: Data?) {
        if let message = replayedMessage, message.id == messageID, replayedItems[message.index].kind == kind,
           messageID != nil || message.index == replayedItems.indices.last {
            replayedItems[message.index].text += text
            if let image { replayedItems[message.index].appendImage(image) }
            return
        }
        replayedMessage = nil
        guard !text.isEmpty || image != nil else { return }
        replayCounter += 1
        replayedMessage = (messageID, replayedItems.count)
        replayedItems.append(HistoryItem(id: "acp-replay-\(replayCounter)", kind: kind, text: text, images: image.map { [$0] }))
    }

    private mutating func upsertReplayedTool(_ tool: RuntimeTool) {
        if let index = replayedToolIndices[tool.id], replayedItems.indices.contains(index) {
            replayedItems[index].tool = tool
        } else {
            replayCounter += 1
            let index = replayedItems.count
            replayedItems.append(HistoryItem(id: "acp-replay-tool-\(tool.id)", kind: .tool, tool: tool))
            replayedToolIndices[tool.id] = index
        }
    }

    private mutating func mergeTool(id: String, update: Record, isCreation: Bool) -> RuntimeTool {
        let rawKind = update["kind"] as? String
        let title = update["title"] as? String
        let initialName = Self.resolvedToolName(kind: rawKind, title: title)
        var projection = tools[id] ?? ToolProjection(tool: RuntimeTool(id: id, name: initialName))
        var tool = projection.tool
        if !isCreation, let rawKind {
            let resolved = Self.resolvedToolName(kind: rawKind, title: title)
            if tool.name == "tool" || resolved == "edit" {
                tool.name = resolved
            }
        } else if isCreation {
            tool.name = initialName
        }

        if let rawInput = update["rawInput"], !(rawInput is NSNull) {
            projection.hasRawInput = true
            let arguments = rawInput as? Record
            let inputSummary = (arguments?["toolSummary"] as? String)
                ?? (arguments?["summary"] as? String)
                ?? (arguments?["description"] as? String)
            let trimmed = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            tool.summary = trimmed == "" ? nil : trimmed
            tool.editArguments = Self.applyArguments(rawInput, on: &tool)
        } else if !projection.hasRawInput, tool.arguments.isEmpty, let title, !title.isEmpty {
            let fallback: Record
            if tool.name == "bash" {
                fallback = ["command": title]
            } else if let locations = update["locations"] as? [Record],
                      let firstPath = locations.first?["path"] as? String, !firstPath.isEmpty {
                fallback = ["path": firstPath, "title": title]
            } else {
                fallback = ["title": title]
            }
            if let edits = Self.applyArguments(fallback, on: &tool), tool.editArguments == nil {
                tool.editArguments = edits
            }
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let distinct = !trimmed.isEmpty && trimmed.lowercased() != tool.name.lowercased()
                && trimmed.lowercased() != rawKind?.lowercased()
            projection.titleSummary = distinct ? trimmed : nil
        }

        if let rawContent = update["content"] as? [Record] {
            let extracted = ACPJSON.extractToolContent(rawContent)
            let retained = Self.clippedOutput(extracted.text)
            tool.output = retained.text
            tool.truncated = retained.truncated
            tool.outputImage = extracted.imageData
            projection.contentEdits = Self.makeEditArguments(from: extracted.diffs)
        } else if let rawOutput = update["rawOutput"], !(rawOutput is NSNull) {
            let retained = Self.clippedOutput(Self.serializeJSON(rawOutput))
            tool.output = retained.text
            tool.truncated = retained.truncated
        }

        if let status = update["status"] as? String {
            tool.state = Self.mapToolState(status)
        }

        projection.tool = tool
        tools[id] = projection
        tool.summary = tool.summary ?? projection.titleSummary
        if let edits = projection.contentEdits {
            tool.name = "edit"
            tool.editArguments = edits
        }
        return tool
    }

    static func resolvedToolName(kind: String?, title: String?) -> String {
        switch kind {
        case "edit": return "edit"
        case "execute": return "bash"
        case "read": return "read"
        case "search": return "grep"
        default:
            if let title, !title.isEmpty { return title }
            if let kind, !kind.isEmpty { return kind }
            return "tool"
        }
    }

    static func mapToolState(_ status: String) -> ToolState {
        switch status {
        case "completed": return .completed
        case "failed": return .failed
        case "pending", "in_progress": return .running
        default: return .running
        }
    }

    static func makeEditArguments(from diffs: [ACPDiffBlock]) -> RuntimeTool.EditArguments? {
        guard let first = diffs.first else { return nil }
        let edits = diffs.map { RuntimeToolApproval.Replacement(oldText: $0.oldText ?? "", newText: $0.newText) }
        return RuntimeTool.EditArguments(path: first.path, edits: edits, replacementCount: edits.count)
    }

    static func applyArguments(_ raw: Any, on tool: inout RuntimeTool) -> RuntimeTool.EditArguments? {
        let text = serializeJSON(raw)
        let preview = text.prefix(maximumArgumentsLength)
        tool.arguments = String(preview)
        tool.argumentsTruncated = preview.endIndex < text.endIndex ? true : nil
        tool.writePath = tool.name == "write" ? (raw as? Record)?["path"] as? String : nil
        if tool.name == "edit" {
            return try? RuntimeTool.EditArguments.decodeToolArguments(from: Data(text.utf8))
        }
        return nil
    }

    static func clippedOutput(_ text: String) -> (text: String, truncated: Bool) {
        let retained = text.prefix(maximumOutputLength)
        return (String(retained), retained.endIndex < text.endIndex)
    }

    static func serializeJSON(_ value: Any) -> String {
        if let string = value as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func planEntries(from entries: [ACPPlanEntry]) -> [RuntimePlanEntry] {
        var remainingBudget = maximumPlanLength
        var mapped: [RuntimePlanEntry] = []
        for (index, entry) in entries.enumerated() where remainingBudget > 0 {
            let clipped = String(entry.content.prefix(remainingBudget))
            guard !clipped.isEmpty else { continue }
            remainingBudget -= clipped.count
            let status: RuntimePlanEntry.Status = switch entry.status {
            case "completed": .completed
            case "in_progress": .inProgress
            default: .pending
            }
            mapped.append(RuntimePlanEntry(
                id: "\(index):\(clipped)",
                content: clipped,
                priority: entry.priority,
                status: status
            ))
        }
        return mapped
    }

    static func runtimeUsage(sessionID: String, snapshot: ACPUsageSnapshot?, promptUsage: ACPPromptUsage?) -> RuntimeUsage {
        let tokens = TokenUsage(
            input: promptUsage?.inputTokens,
            output: promptUsage?.outputTokens,
            cacheRead: promptUsage?.cachedReadTokens,
            cacheWrite: promptUsage?.cachedWriteTokens,
            total: promptUsage?.totalTokens
        )
        var context: ContextUsage?
        if let snapshot, snapshot.used != nil || snapshot.size != nil {
            let percent: Double?
            if let used = snapshot.used, let size = snapshot.size, size > 0 {
                percent = (Double(used) / Double(size)) * 100.0
            } else {
                percent = nil
            }
            context = ContextUsage(tokens: snapshot.used, window: snapshot.size, percent: percent)
        }
        let estimatedCostUSD: Double?
        if let amount = snapshot?.costAmount,
           (snapshot?.costCurrency == nil || snapshot?.costCurrency?.uppercased() == "USD") {
            estimatedCostUSD = amount
        } else {
            estimatedCostUSD = nil
        }
        let note: String? = estimatedCostUSD != nil
            ? String(localized: "费用为 Agent 上报的估算值，缺失数据未计作零。", bundle: #bundle)
            : nil
        return RuntimeUsage(
            sessionID: sessionID,
            tokens: tokens,
            estimatedCostUSD: estimatedCostUSD,
            context: context,
            note: note
        )
    }

    static func failure(from rpcError: ACPJSONRPCError) -> RuntimeFailure {
        if rpcError.isAuthRequired {
            return RuntimeFailure(.authentication, String(localized: "ACP Agent 认证失败，请先完成登录后重试。", bundle: #bundle), rawDetail: rpcError.message)
        }
        if rpcError.code == ACPProtocol.ErrorCode.parseError || rpcError.code == ACPProtocol.ErrorCode.invalidRequest {
            return RuntimeFailure(.protocolError, String(localized: "ACP 协议格式异常，执行状态待核实。", bundle: #bundle), rawDetail: rpcError.message)
        }
        return failure(rpcError.message)
    }

    static func failure(_ error: String) -> RuntimeFailure {
        let lower = error.lowercased()
        if lower.contains("401") || lower.contains("api key") || lower.contains("unauthorized")
            || lower.contains("auth_required") || lower.contains("authentication required") {
            return .init(.authentication, String(localized: "ACP Agent 认证失败，请先完成登录后重试。", bundle: #bundle), rawDetail: error)
        }
        if lower.contains("quota reached") || lower.contains("individual quota")
            || lower.contains("insufficient_quota") || lower.contains("usage limit") {
            return .init(.model, String(localized: "当前模型额度已耗尽，请查看额度或切换其他模型。", bundle: #bundle), rawDetail: error)
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return .init(.model, String(localized: "模型服务限流，请稍后手动重试。", bundle: #bundle), rawDetail: error)
        }
        if lower.contains("deadline") || lower.contains("timeout") || lower.contains("timed out") {
            return .init(.outcomeUnknown, String(localized: "请求超时，执行结果尚未确认；不会自动重发。", bundle: #bundle), rawDetail: error)
        }
        if lower.contains("protocol") || lower.contains("malformed") {
            return .init(.protocolError, String(localized: "ACP 运行时协议异常，执行状态待核实。", bundle: #bundle), rawDetail: error)
        }
        if lower.contains("supervis") || lower.contains("cleanup") {
            return .init(.supervision, String(localized: "进程清理尚未确认，已阻止继续执行。", bundle: #bundle), rawDetail: error)
        }
        return .init(.connection, String(localized: "ACP 运行时请求失败。请结束受管进程并检查 Agent 配置后手动重连。", bundle: #bundle), rawDetail: error)
    }
}
