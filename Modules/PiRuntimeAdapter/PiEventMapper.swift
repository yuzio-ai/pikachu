import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Confined to the connection's reader thread. Raw Pi values do not leave this module.
struct PiEventMapper {
    var currentAssistant: UUID?
    var tools: [String: RuntimeTool] = [:]
    static func text(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        return (raw as? [Record] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func clipped(_ text: String, limit: Int = 65_536) -> String { String(text.prefix(limit)) }
    static func json(_ raw: Any?) -> String {
        guard let raw, JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return clipped(String(decoding: data, as: UTF8.self), limit: 16_384)
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
        case "compaction_end", "auto_retry_end": return [.phase(.running)]
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
                let failure = Self.failure(message["errorMessage"] as? String ?? "model failure")
                events.append(.failure(failure.kind == .connection ? .init(.model, String(localized: "模型响应失败，请检查服务配置后手动重试。", bundle: #bundle)) : failure))
            }
            return events
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            guard let id = record["toolCallId"] as? String else { return [] }
            var tool = tools[id] ?? RuntimeTool(id: id, name: record["toolName"] as? String ?? "tool")
            if record["args"] != nil { tool.arguments = Self.json(record["args"]) }
            let end = record["type"] as? String == "tool_execution_end"
            let result = record[end ? "result" : "partialResult"] as? Record
            if let result {
                let full = Self.text(result["content"])
                tool.output = Self.clipped(full); tool.truncated = full.count > 65_536
            }
            if end { tool.state = record["isError"] as? Bool == true ? .failed : .completed }
            if end { tools.removeValue(forKey: id) } else { tools[id] = tool }
            return [.tool(tool)]
        case "queue_update": return [.queue(.init(steering: record["steering"] as? [String] ?? [], followUp: record["followUp"] as? [String] ?? []))]
        case "agent_settled": return [.settled(aborted: record["aborted"] as? Bool ?? false)]
        default: return []
        }
    }
}
