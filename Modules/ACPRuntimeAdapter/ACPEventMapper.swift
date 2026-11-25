import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Confined to the connection's event processing loop or tests.
/// Translates ACP v1 `session/update` notifications and turn settlement into domain `AgentEvent`s
/// or read-only `HistoryItem`s during `session/load` replay.
struct ACPEventMapper {
    struct ReplaySnapshot: Sendable {
        var items: [HistoryItem]
        var metadataUpdates: MetadataUpdate
    }

    struct MetadataUpdate: Sendable, Equatable {
        var currentModeID: String?
        var configOptions: [ACPConfigOption]?
        var usage: ACPUsageSnapshot?
    }

    static let maximumArgumentsLength = 16_384
    static let maximumOutputLength = 65_536
    static let maximumThoughtLength = 4_000
    static let maximumPlanLength = 4_000

    var replayingHistory = false
    var currentAssistant: UUID?
    var currentAssistantText = ""
    var currentThoughtText = ""
    var tools: [String: RuntimeTool] = [:]
    var latestUsage: ACPUsageSnapshot?
    private(set) var replayedItems: [HistoryItem] = []
    private var replayedToolIndices: [String: Int] = [:]
    private var replayCounter = 0

    mutating func beginHistoryReplay() {
        replayingHistory = true
        replayedItems = []
        replayedToolIndices = [:]
        replayCounter = 0
        currentAssistant = nil
        currentAssistantText = ""
        currentThoughtText = ""
        tools = [:]
    }

    mutating func finishHistoryReplay() -> [HistoryItem] {
        replayingHistory = false
        let items = replayedItems
        replayedItems = []
        replayedToolIndices = [:]
        tools = [:]
        return items
    }

    mutating func mapSessionUpdate(_ update: Record) -> (events: [AgentEvent], metadata: MetadataUpdate) {
        var metadata = MetadataUpdate()
        guard let kind = update["sessionUpdate"] as? String else { return ([], metadata) }

        switch kind {
        case "user_message_chunk":
            let text = ACPJSON.textFromContentBlock(update["content"])
            guard replayingHistory, !text.isEmpty else { return ([], metadata) }
            appendReplayedMessage(kind: .user, text: text)
            return ([], metadata)

        case "agent_message_chunk":
            let text = ACPJSON.textFromContentBlock(update["content"])
            guard !text.isEmpty else { return ([], metadata) }
            if replayingHistory {
                appendReplayedMessage(kind: .assistant, text: text)
                return ([], metadata)
            }
            var events: [AgentEvent] = []
            let id: UUID
            if let existing = currentAssistant {
                id = existing
            } else {
                id = UUID()
                currentAssistant = id
                currentAssistantText = ""
                events.append(.assistantStarted(id))
            }
            currentAssistantText += text
            events.append(.textDelta(id, 0, text))
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
            if !replayingHistory, let activeAssistant = currentAssistant {
                // Separate assistant narrative before a tool call from narrative after it.
                events.append(.assistantCompleted(activeAssistant, currentAssistantText))
                currentAssistant = nil
                currentAssistantText = ""
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
            let options = ACPConfigOption.parseList(update["configOptions"])
            if !options.isEmpty {
                metadata.configOptions = options
            }
            return ([], metadata)

        default:
            return ([], metadata)
        }
    }

    mutating func finishTurn(stopReason: ACPStopReason) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let activeAssistant = currentAssistant {
            events.append(.assistantCompleted(activeAssistant, currentAssistantText))
            currentAssistant = nil
            currentAssistantText = ""
        }
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
        if let activeAssistant = currentAssistant {
            events.append(.assistantCompleted(activeAssistant, currentAssistantText))
            currentAssistant = nil
            currentAssistantText = ""
        }
        if !currentThoughtText.isEmpty {
            currentThoughtText = ""
            events.append(.thought(nil))
        }
        tools.removeAll()
        events.append(.failure(failure))
        if !failure.kind.leavesTurnOutcomeUnknown { events.append(.settled(aborted: false)) }
        return events
    }

    private mutating func appendReplayedMessage(kind: HistoryItemKind, text: String) {
        if let lastIndex = replayedItems.indices.last, replayedItems[lastIndex].kind == kind {
            replayedItems[lastIndex].text += text
        } else {
            replayCounter += 1
            replayedItems.append(HistoryItem(id: "acp-replay-\(replayCounter)", kind: kind, text: text))
        }
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
        var tool = tools[id] ?? RuntimeTool(id: id, name: initialName)
        if !isCreation, let rawKind {
            let resolved = Self.resolvedToolName(kind: rawKind, title: title)
            if tool.name == "tool" || resolved == "edit" {
                tool.name = resolved
            }
        } else if isCreation {
            tool.name = initialName
        }

        if let rawInput = update["rawInput"] {
            Self.applyArguments(rawInput, on: &tool)
        } else if tool.arguments.isEmpty, let title, !title.isEmpty {
            let fallback: Record
            if tool.name == "bash" {
                fallback = ["command": title]
            } else if let locations = update["locations"] as? [Record],
                      let firstPath = locations.first?["path"] as? String, !firstPath.isEmpty {
                fallback = ["path": firstPath, "title": title]
            } else {
                fallback = ["title": title]
            }
            Self.applyArguments(fallback, on: &tool)
        }

        if let rawContent = update["content"] {
            let extracted = ACPJSON.extractToolContent(rawContent)
            if !extracted.text.isEmpty {
                let retained = Self.clippedOutput(extracted.text)
                tool.output = retained.text
                tool.truncated = tool.truncated || retained.truncated
            }
            if let image = extracted.imageData {
                tool.outputImage = image
            }
            if !extracted.diffs.isEmpty {
                tool.name = "edit"
                if let editArguments = Self.makeEditArguments(from: extracted.diffs) {
                    tool.editArguments = editArguments
                }
            }
        } else if let rawOutput = update["rawOutput"] {
            let text = Self.serializeJSON(rawOutput)
            if !text.isEmpty {
                let retained = Self.clippedOutput(text)
                tool.output = retained.text
                tool.truncated = tool.truncated || retained.truncated
            }
        }

        if let status = update["status"] as? String {
            tool.state = Self.mapToolState(status)
        }

        if tool.state == .completed || tool.state == .failed {
            tools.removeValue(forKey: id)
        } else {
            tools[id] = tool
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

    static func applyArguments(_ raw: Any, on tool: inout RuntimeTool) {
        let text = serializeJSON(raw)
        let preview = text.prefix(maximumArgumentsLength)
        tool.arguments = String(preview)
        tool.argumentsTruncated = preview.endIndex < text.endIndex ? true : nil
        if tool.name == "edit", tool.editArguments == nil,
           let data = text.data(using: .utf8),
           let decoded = try? RuntimeTool.EditArguments.decodeToolArguments(from: data) {
            tool.editArguments = decoded
        } else if tool.name == "write", let path = (raw as? Record)?["path"] as? String {
            tool.writePath = path
        }
    }

    static func clippedOutput(_ text: String) -> (text: String, truncated: Bool) {
        let retained = text.prefix(maximumOutputLength)
        return (String(retained), retained.endIndex < text.endIndex)
    }

    static func serializeJSON(_ value: Any) -> String {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
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
            return RuntimeFailure(.authentication, String(localized: "ACP Agent 认证失败，请先完成登录后重试。", bundle: #bundle))
        }
        if rpcError.code == ACPProtocol.ErrorCode.parseError || rpcError.code == ACPProtocol.ErrorCode.invalidRequest {
            return RuntimeFailure(.protocolError, String(localized: "ACP 协议格式异常，执行状态待核实。", bundle: #bundle))
        }
        return failure(rpcError.message)
    }

    static func failure(_ error: String) -> RuntimeFailure {
        let lower = error.lowercased()
        if lower.contains("401") || lower.contains("api key") || lower.contains("unauthorized")
            || lower.contains("auth_required") || lower.contains("authentication required") {
            return .init(.authentication, String(localized: "ACP Agent 认证失败，请先完成登录后重试。", bundle: #bundle))
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return .init(.model, String(localized: "模型服务限流，请稍后手动重试。", bundle: #bundle))
        }
        if lower.contains("deadline") || lower.contains("timeout") || lower.contains("timed out") {
            return .init(.outcomeUnknown, String(localized: "请求超时，执行结果尚未确认；不会自动重发。", bundle: #bundle))
        }
        if lower.contains("protocol") || lower.contains("malformed") {
            return .init(.protocolError, String(localized: "ACP 运行时协议异常，执行状态待核实。", bundle: #bundle))
        }
        if lower.contains("supervis") || lower.contains("cleanup") {
            return .init(.supervision, String(localized: "进程清理尚未确认，已阻止继续执行。", bundle: #bundle))
        }
        return .init(.connection, String(localized: "ACP 运行时请求失败。请结束受管进程并检查 Agent 配置后手动重连。", bundle: #bundle))
    }
}
