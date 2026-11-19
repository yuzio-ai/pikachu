import Foundation
import CoreFoundation
import AgentRuntimeCore
import M0Support

struct PiUsageMapper {
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }
    static func integer(_ value: Any?) -> Int? {
        guard let result = number(value), result < Double(Int.max), result.rounded() == result else { return nil }
        return Int(result)
    }
    static func live(_ stats: Record, model: Record?, coverage: UsageAccumulator?) throws -> RuntimeUsage {
        guard let id = stats["sessionId"] as? String else { throw RuntimeFailure(.protocolError, "统计缺少会话标识。") }
        let raw = stats["tokens"] as? Record ?? [:]
        let tokens = TokenUsage(input: integer(raw["input"]), output: integer(raw["output"]), cacheRead: integer(raw["cacheRead"]), cacheWrite: integer(raw["cacheWrite"]), total: integer(raw["total"]), inputIsUncached: true)
        let rates = model?["cost"] as? Record
        let priced = ["input", "output", "cacheRead", "cacheWrite"].contains { (number(rates?[$0]) ?? 0) > 0 }
        let rawCost = number(stats["cost"])
        let cost = priced && coverage?.missingCost != true && ((tokens.total == 0) || ((rawCost ?? 0) > 0 && coverage != nil)) ? rawCost : nil
        var context: ContextUsage?
        if let raw = stats["contextUsage"] as? Record {
            context = .init(tokens: integer(raw["tokens"]), window: integer(raw["contextWindow"]), percent: number(raw["percent"]))
            if context?.window == 0 { context = nil }
        }
        return .init(sessionID: id, tokens: tokens, estimatedCostUSD: cost, context: context,
                     note: cost == nil ? "当前模型或部分历史未提供可用单价 / 费用；估算不可用。" : "费用为 Pi 的美元估算，不代表服务商余额。")
    }
    static func coverage(_ file: URL) throws -> UsageAccumulator {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var decoder = JSONLDecoder(), result = UsageAccumulator(), bytes = 0
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            bytes += data.count
            guard bytes <= 128 * 1_024 * 1_024 else { throw RuntimeFailure(.protocolError, "统计历史超过读取上限。") }
            for entry in try decoder.feed(data) { result.add(entry) }
        }
        guard decoder.pending.isEmpty else { throw RuntimeFailure(.protocolError, "统计历史尾部尚未写完整。") }
        return result
    }
}

struct UsageAccumulator {
    private var sums = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]
    private var missing = Set<String>()
    private var cost = 0.0
    private(set) var missingCost = false
    private var counted = 0
    mutating func add(_ entry: Record) {
        let type = entry["type"] as? String
        var usage: Record?
        if type == "message", let message = entry["message"] as? Record {
            let role = message["role"] as? String
            usage = message["usage"] as? Record
            if role == "assistant" && usage == nil { missing.formUnion(sums.keys); missingCost = true }
            if role != "assistant" && role != "toolResult" { return }
        } else if ["usage", "compaction", "branch_summary"].contains(type ?? "") { usage = entry["usage"] as? Record }
        guard let usage else { return }
        counted += 1
        var total = 0
        for key in ["input", "output", "cacheRead", "cacheWrite"] {
            if let value = PiUsageMapper.integer(usage[key]), let sum = sums[key], !sum.addingReportingOverflow(value).overflow {
                sums[key] = sum + value
                if !total.addingReportingOverflow(value).overflow { total += value } else { missing.insert("total") }
            } else { missing.insert(key); missing.insert("total") }
        }
        if let explicit = PiUsageMapper.integer(usage["totalTokens"]) { total = explicit }
        if let sum = sums["total"], !sum.addingReportingOverflow(total).overflow { sums["total"] = sum + total } else { missing.insert("total") }
        let part = PiUsageMapper.number((usage["cost"] as? Record)?["total"])
        if total > 0 && (part == nil || part == 0) { missingCost = true }
        if let part { cost += part; if !cost.isFinite { missingCost = true } }
    }
    func snapshot(id: String) -> RuntimeUsage {
        func value(_ key: String) -> Int? { missing.contains(key) ? nil : sums[key] }
        return .init(sessionID: id, tokens: .init(input: value("input"), output: value("output"), cacheRead: value("cacheRead"), cacheWrite: value("cacheWrite"), total: value("total"), inputIsUncached: true),
                     estimatedCostUSD: !missingCost && counted > 0 && cost > 0 ? cost : nil,
                     note: "历史累计统计包含其他分支与压缩用量；当前上下文占用需连接后查询。费用为美元估算，缺失不计作零。")
    }
}
