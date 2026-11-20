import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Confined to the connection's reader thread. Raw Pi values do not leave this module.
struct PiEventMapper {
    var currentAssistant: UUID?
    var tools: [String: RuntimeTool] = [:]
    // A failed attempt can be followed by a retry or compaction before Pi settles the run.
    private var pendingAssistantFailure: RuntimeFailure?
    static func text(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        return (raw as? [Record] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func clipped(_ text: String, limit: Int = 65_536) -> String { String(text.prefix(limit)) }
    static func toolOutput(_ text: String, details: Any?, name: String, failed: Bool) -> (text: String, truncated: Bool) {
        let retained = text.prefix(65_536)
        let truncation = (details as? Record)?["truncation"] as? Record
        let reported = truncation?["truncated"] as? Bool
        let upstream = reported ?? (failed && (name == "bash" || name == "pikachu_bash") && hasBashTruncationMarker(text))
        return (String(retained), upstream || retained.endIndex < text.endIndex)
    }

    static func readOutputImage(_ content: Any?, name: String, failed: Bool) -> Data? {
        guard !failed, name == "read" || name == "pikachu_read",
              let blocks = content as? [Record] else { return nil }
        // Retain at most one image per read, with a bound on the encoded payload.
        for block in blocks where block["type"] as? String == "image" {
            guard let mimeType = block["mimeType"] as? String, mimeType.hasPrefix("image/"),
                  let encoded = block["data"] as? String, encoded.utf8.count <= 8 * 1024 * 1024,
                  let data = Data(base64Encoded: encoded), !data.isEmpty else { continue }
            return data
        }
        return nil
    }

    private static func hasBashTruncationMarker(_ text: String) -> Bool {
        // Pi puts the truncation marker before the terminal error if it throws and omits details.
        let lines = text.suffix(4096).split(whereSeparator: \.isNewline)
        guard lines.count >= 2, let status = lines.last,
              status == "Command aborted" || status == "Command terminated without an exit code" ||
              status.hasPrefix("Command timed out after ") || status.hasPrefix("Command exited with code ") else { return false }
        let marker = lines[lines.count - 2]
        return (marker.hasPrefix("[Showing lines ") || marker.hasPrefix("[Showing last ")) &&
            marker.contains(". Full output: ") && marker.hasSuffix("]")
    }

    static func setToolArguments(_ raw: Any?, on tool: inout RuntimeTool) {
        let data = raw.flatMap { value -> Data? in
            guard JSONSerialization.isValidJSONObject(value) else { return nil }
            return try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        }
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let preview = text.prefix(16_384)
        tool.arguments = String(preview)
        tool.argumentsTruncated = preview.endIndex < text.endIndex ? true : nil
        tool.editArguments = nil
        tool.writePath = nil
        switch tool.name {
        case "edit", "pikachu_edit":
            if let data { tool.editArguments = try? RuntimeTool.EditArguments.decodeToolArguments(from: data) }
        case "write", "pikachu_write":
            tool.writePath = (raw as? Record)?["path"] as? String
        default:
            break
        }
    }
    static func failure(_ error: String) -> RuntimeFailure {
        let lower = error.lowercased()
        if lower.contains("401") || lower.contains("api key") || lower.contains("unauthorized") { return .init(.authentication, String(localized: "模型认证失败，请检查 Pi 的认证配置。", bundle: #bundle)) }
        if lower.contains("429") || lower.contains("rate limit") { return .init(.model, String(localized: "模型服务限流，请稍后手动重试。", bundle: #bundle)) }
        if lower.contains("deadline") || lower.contains("timeout") || lower.contains("timed out") { return .init(.outcomeUnknown, String(localized: "请求超时，执行结果尚未确认；不会自动重发。", bundle: #bundle)) }
        if lower.contains("protocol") || lower.contains("malformed") { return .init(.protocolError, String(localized: "运行时协议异常，执行状态待核实。", bundle: #bundle)) }
        if lower.contains("supervis") || lower.contains("cleanup") { return .init(.supervision, String(localized: "进程清理尚未确认，已阻止继续执行。", bundle: #bundle)) }
        if lower.contains("node") { return .init(.setup, String(localized: "未找到可用的 Node，请检查连接设置。", bundle: #bundle)) }
        return .init(.connection, String(localized: "运行时请求失败。请结束受管进程并检查 Pi 配置后手动重连。", bundle: #bundle))
    }
    static func assistantFailure(_ raw: Any?) -> RuntimeFailure {
        let error = raw as? String ?? ""
        let mapped = failure(error)
        if mapped.kind == .authentication || mapped.kind == .model { return mapped }
        if error.contains("UND_ERR_SOCKET") {
            return .init(.model, String(localized: "模型服务连接中断（UND_ERR_SOCKET）。", bundle: #bundle))
        }
        return .init(.model, String(localized: "模型响应失败，请检查服务配置后手动重试。", bundle: #bundle))
    }
    static func epochMs(_ raw: Any?) -> Int64? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let ms = value.doubleValue
        guard ms.isFinite, ms >= 946_684_800_000, ms < Double(Int64.max) else { return nil }
        return Int64(ms)
    }
    mutating func map(_ record: Record) -> [AgentEvent] {
        switch record["type"] as? String {
        case "agent_start": return [.phase(.running), .runStarted]
        case "auto_retry_start", "summarization_retry_scheduled", "summarization_retry_attempt_start": return [.phase(.retrying)]
        case "compaction_start": return [.phase(.compacting)]
        case "compaction_end": return [.phase(.running)]
        case "auto_retry_end":
            if record["success"] as? Bool == true { pendingAssistantFailure = nil }
            return [.phase(.running)]
        case "message_start":
            guard let message = record["message"] as? Record else { return [] }
            if message["role"] as? String == "user", let ts = Self.epochMs(message["timestamp"]) {
                return [.userMessageTimestamp(ts, text: Self.text(message["content"]))]
            }
            guard message["role"] as? String == "assistant" else { return [] }
            let id = UUID(); currentAssistant = id
            var events: [AgentEvent] = [.assistantStarted(id)]
            if let ts = Self.epochMs(message["timestamp"]) { events.append(.assistantTimestamp(id, ts)) }
            return events
        case "message_update":
            guard let id = currentAssistant, let delta = record["assistantMessageEvent"] as? Record,
                  delta["type"] as? String == "text_delta", let index = delta["contentIndex"] as? Int,
                  let text = delta["delta"] as? String else { return [] }
            return [.textDelta(id, index, text)]
        case "message_end":
            guard let message = record["message"] as? Record, message["role"] as? String == "assistant" else { return [] }
            let id = currentAssistant ?? UUID(); currentAssistant = nil
            var events: [AgentEvent] = []
            if let ts = Self.epochMs(message["timestamp"]) { events.append(.assistantTimestamp(id, ts)) }
            events.append(.assistantCompleted(id, Self.text(message["content"])))
            if message["stopReason"] as? String == "error" {
                let failure = Self.assistantFailure(message["errorMessage"])
                pendingAssistantFailure = failure
                events.append(.assistantAttemptFailed(id, failure))
            } else {
                pendingAssistantFailure = nil
            }
            return events
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            guard let id = record["toolCallId"] as? String else { return [] }
            var tool = tools[id] ?? RuntimeTool(id: id, name: record["toolName"] as? String ?? "tool")
            if record["args"] != nil { Self.setToolArguments(record["args"], on: &tool) }
            let end = record["type"] as? String == "tool_execution_end"
            let result = record[end ? "result" : "partialResult"] as? Record
            let failed = end && record["isError"] as? Bool == true
            if let result {
                let retained = Self.toolOutput(Self.text(result["content"]), details: result["details"], name: tool.name, failed: failed)
                tool.output = retained.text
                tool.truncated = retained.truncated
            }
            if end {
                tool.state = failed ? .failed : .completed
                tool.outputImage = Self.readOutputImage(result?["content"], name: tool.name, failed: failed)
            }
            if end { tools.removeValue(forKey: id) } else { tools[id] = tool }
            return [.tool(tool)]
        case "queue_update": return [.queue(.init(steering: record["steering"] as? [String] ?? [], followUp: record["followUp"] as? [String] ?? []))]
        case "agent_settled":
            let aborted = record["aborted"] as? Bool ?? false
            defer { pendingAssistantFailure = nil }
            if !aborted, let failure = pendingAssistantFailure {
                return [.failure(failure), .settled(aborted: false)]
            }
            return [.settled(aborted: aborted)]
        default: return []
        }
    }
}
