import Foundation
import AgentRuntimeCore
import M0Support

/// No Process, inference or writes. Display history is the active branch, not LLM context.
public actor PiHistoryReader: RuntimeHistoryReader {
    private struct CachedRead {
        let file: URL
        let bytes: Data
        let history: RuntimeHistory
    }

    private static let chunkSize = 65_536
    private static let cacheByteLimit = 4 * 1_024 * 1_024
    private let roots: [URL]
    private var recentReads: [CachedRead] = []

    public init(roots: [URL]) { self.roots = roots }

    public func read(_ file: URL) throws -> RuntimeHistory {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }

            // Always read the source. Byte equality also detects in-place rewrites,
            // truncation and replacements with unchanged size or timestamps.
            var prefix = Data()
            while prefix.count <= Self.cacheByteLimit,
                  let chunk = try handle.read(upToCount: min(Self.chunkSize, Self.cacheByteLimit + 1 - prefix.count)),
                  !chunk.isEmpty {
                prefix.append(chunk)
            }

            if let cachedIndex = recentReads.firstIndex(where: { $0.file == file }) {
                let cached = recentReads.remove(at: cachedIndex)
                if cached.bytes == prefix {
                    recentReads.append(cached)
                    return cached.history
                }
            }

            let history = try Self.parse(file, handle: handle, prefix: prefix)
            if prefix.count <= Self.cacheByteLimit, !history.incompleteTail {
                if recentReads.count == 2 { recentReads.removeFirst() }
                recentReads.append(.init(file: file, bytes: prefix, history: history))
            }
            return history
        }
        catch let error as RuntimeFailure { throw error }
        catch { throw RuntimeFailure(.protocolError, "会话文件缺失、不可读或已损坏；源文件未修改。") }
    }
    public func discover(locations: [String]) throws -> HistoryDiscovery {
        let result = scan(locations: locations) { $0 }
        return .init(sessions: result.sessions, issues: result.issues)
    }
    public func discoverSummaries(locations: [String]) throws -> (sessions: [RuntimeHistorySummary], issues: [String]) {
        scan(locations: locations, transform: RuntimeHistorySummary.init)
    }
    private func scan<Session>(locations: [String], transform: (RuntimeHistory) -> Session) -> (sessions: [Session], issues: [String]) {
        let accepted = Set(locations.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        var sessions: [Session] = [], issues: [String] = [], seen = Set<String>()
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else {
                issues.append("一个会话目录无法读取。"); continue
            }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted else { continue }
                do {
                    let history = try Self.parse(file)
                    if accepted.contains(URL(fileURLWithPath: history.cwd).standardizedFileURL.resolvingSymlinksInPath().path) {
                        sessions.append(transform(history))
                    }
                } catch { issues.append("发现一个无法读取或不受支持的会话文件：\(file.lastPathComponent)") }
            }
        }
        return (sessions, issues)
    }
    private static func parse(_ file: URL) throws -> RuntimeHistory {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        return try parse(file, handle: handle)
    }

    private static func parse(_ file: URL, handle: FileHandle, prefix: Data = Data()) throws -> RuntimeHistory {
        var decoder = JSONLDecoder(), records: [Record] = [], total = prefix.count
        for start in stride(from: 0, to: prefix.count, by: chunkSize) {
            records += try decoder.feed(prefix[start..<min(start + chunkSize, prefix.count)])
        }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            total += chunk.count
            guard total <= 128 * 1_024 * 1_024 else { throw RuntimeFailure(.protocolError, "会话超过当前 128 MiB 读取上限。") }
            records += try decoder.feed(chunk)
        }
        guard let header = records.first, header["type"] as? String == "session", header["version"] as? Int == 3,
              let sessionID = header["id"] as? String, !sessionID.isEmpty, let cwd = header["cwd"] as? String, cwd.hasPrefix("/") else {
            throw RuntimeFailure(.protocolError, "会话格式不受支持；仅支持 Pi v3 会话文件，源文件未修改。")
        }
        var byID: [String: Record] = [:], lastID: String?
        for entry in records.dropFirst() {
            guard let id = entry["id"] as? String, !id.isEmpty, byID[id] == nil, entry["type"] as? String != "session" else {
                throw RuntimeFailure(.protocolError, "会话条目标识损坏或重复。")
            }
            if let parent = entry["parentId"] as? String {
                guard byID[parent] != nil else { throw RuntimeFailure(.protocolError, "会话分支的父条目缺失。") }
            } else if !(entry["parentId"] is NSNull) { throw RuntimeFailure(.protocolError, "会话分支结构损坏。") }
            byID[id] = entry; lastID = id
        }
        var branch: [Record] = []
        while let id = lastID, let entry = byID[id] { branch.append(entry); lastID = entry["parentId"] as? String }
        branch.reverse()
        var items: [HistoryItem] = [], toolIndices: [String: Int] = [:], warnings: [String] = [], selection: RuntimeSelection?, thinking: String?, title = "历史会话"
        var lastObservedModel: RuntimeSelection?
        var needsReply = false
        var turns: [HistoryTurnInfo] = []
        var openTurnID: String?
        var openTurnItems: [String] = []
        var openTurnUserMs: Int64?
        var openTurnAssistantMs: Int64?
        var openTurnToolID: String?
        var openTurnStopReason: String?
        var openTurnEndTimestamp: Date?
        var openTurnToolIndices: [Int] = []
        var pendingUserMs: Int64?

        func flushTurn() {
            guard !openTurnItems.isEmpty, let turnID = openTurnID else {
                openTurnID = nil; openTurnItems = []; openTurnUserMs = nil; openTurnAssistantMs = nil
                openTurnToolID = nil; openTurnStopReason = nil; openTurnEndTimestamp = nil; openTurnToolIndices = []
                return
            }
            let hasInterruptedTool = openTurnToolIndices.contains { items[$0].tool?.state == .interrupted }
            let status: TurnStatus
            let endedAt: Date?
            if hasInterruptedTool {
                status = .uncertain
                endedAt = nil
            } else {
                switch openTurnStopReason {
                case "stop":
                    status = .completed
                    endedAt = openTurnEndTimestamp
                case "aborted":
                    status = .stopped
                    endedAt = openTurnEndTimestamp
                case "error":
                    status = .failed
                    endedAt = openTurnEndTimestamp
                default:
                    status = .uncertain
                    endedAt = nil
                }
            }
            turns.append(.init(id: turnID, itemIDs: openTurnItems, firstUserTimestampMs: openTurnUserMs,
                               firstAssistantTimestampMs: openTurnAssistantMs, firstToolCallID: openTurnToolID,
                               endedAt: endedAt, durationSeconds: nil, status: status))
            openTurnID = nil; openTurnItems = []; openTurnUserMs = nil; openTurnAssistantMs = nil
            openTurnToolID = nil; openTurnStopReason = nil; openTurnEndTimestamp = nil; openTurnToolIndices = []
        }

        func ensureOpenTurn(entryID: String) {
            if openTurnID == nil {
                openTurnID = "turn:" + entryID
                openTurnUserMs = pendingUserMs
                pendingUserMs = nil
            }
        }

        for entry in branch {
            let entryID = entry["id"] as! String
            let id = "history:" + entryID, type = entry["type"] as? String ?? ""
            switch type {
            case "message":
                guard let message = entry["message"] as? Record, let role = message["role"] as? String else { throw RuntimeFailure(.protocolError, "会话消息结构损坏。") }
                var text = PiEventMapper.text(message["content"])
                if (message["content"] as? [Record])?.contains(where: { $0["type"] as? String == "image" }) == true {
                    text += "\n（含图片，当前仅展示文字。）"
                }
                switch role {
                case "user":
                    flushTurn()
                    needsReply = true
                    if title == "历史会话", !text.isEmpty { title = String(text.prefix(48)) }
                    let msgMs = PiEventMapper.epochMs(message["timestamp"])
                    let sentAt = msgMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) } ?? timestamp(entry["timestamp"])
                    pendingUserMs = msgMs
                    items.append(.init(id: id, kind: .user, text: text, sentAt: sentAt, messageTimestampMs: msgMs))
                case "assistant":
                    ensureOpenTurn(entryID: entryID)
                    if openTurnAssistantMs == nil { openTurnAssistantMs = PiEventMapper.epochMs(message["timestamp"]) }
                    if !text.isEmpty {
                        items.append(.init(id: id, kind: .assistant, text: text))
                        openTurnItems.append(id)
                    }
                    let blocks = message["content"] as? [Record] ?? []
                    for (offset, block) in blocks.enumerated() where block["type"] as? String == "toolCall" {
                        guard let call = block["id"] as? String else { continue }
                        let itemIndex = items.count
                        toolIndices[call] = itemIndex
                        let toolItemID = "history-tool:\(offset):\(id)"
                        if openTurnToolID == nil { openTurnToolID = call }
                        openTurnItems.append(toolItemID)
                        openTurnToolIndices.append(itemIndex)
                        // A protocol call ID can repeat in imported history. The display ID identifies the block.
                        items.append(.init(id: toolItemID, kind: .tool, tool: .init(id: call, name: block["name"] as? String ?? "tool", arguments: PiEventMapper.json(block["arguments"]), state: .interrupted)))
                    }
                    if let provider = message["provider"] as? String, let model = message["model"] as? String {
                        let model = RuntimeSelection(provider: provider, modelID: model, thinking: thinking)
                        if selection == nil { selection = model }
                        lastObservedModel = model
                    }
                    let stop = message["stopReason"] as? String
                    openTurnStopReason = stop
                    openTurnEndTimestamp = timestamp(entry["timestamp"])
                    needsReply = stop == "toolUse" || stop == "error" || stop == "aborted"
                        || blocks.contains { $0["type"] as? String == "toolCall" }
                    if message["stopReason"] as? String == "error" {
                        items.append(.init(id: "history-end:" + id, kind: .notice, text: PiEventMapper.failure(message["errorMessage"] as? String ?? "model failure").detail))
                    } else if message["stopReason"] as? String == "aborted" {
                        items.append(.init(id: "history-end:" + id, kind: .notice, text: "该轮回复已中断，不能据此确认任务完成。"))
                    }
                case "toolResult":
                    ensureOpenTurn(entryID: entryID)
                    let call = message["toolCallId"] as? String ?? id
                    if openTurnToolID == nil { openTurnToolID = call }
                    var tool = RuntimeTool(id: call, name: message["toolName"] as? String ?? "tool", output: PiEventMapper.clipped(text), state: message["isError"] as? Bool == true ? .failed : .completed, truncated: text.count > 65_536)
                    if let index = toolIndices[call] {
                        tool.arguments = items[index].tool?.arguments ?? ""
                        items[index].tool = tool
                    } else {
                        items.append(.init(id: id, kind: .tool, tool: tool))
                        openTurnItems.append(id)
                    }
                case "system": break
                case "custom": if !text.isEmpty { items.append(.init(id: id, kind: .notice, text: text)) }
                default: warnings.append("存在未展示的消息类型：\(role)")
                }
            case "model_change":
                if let provider = entry["provider"] as? String, let model = entry["modelId"] as? String { selection = .init(provider: provider, modelID: model, thinking: thinking) }
            case "thinking_level_change": thinking = entry["thinkingLevel"] as? String; selection?.thinking = thinking
            case "compaction": items.append(.init(id: id, kind: .notice, text: "上下文压缩摘要（之前的消息仍是历史记录）\n" + (entry["summary"] as? String ?? "")))
            case "branch_summary": items.append(.init(id: id, kind: .notice, text: "分支摘要\n" + (entry["summary"] as? String ?? "")))
            case "context_edit": items.append(.init(id: id, kind: .notice, text: "后续模型上下文已调整；原始历史保留。"))
            case "session_info": if let name = entry["name"] as? String { title = name }
            case "custom", "label", "usage": break
            default: warnings.append("存在未展示的条目类型：\(type)")
            }
        }
        flushTurn()
        var usage = UsageAccumulator(); for record in records { usage.add(record) }
        let lastTimestamp = branch.reversed().lazy.compactMap { timestamp($0["timestamp"]) }.first ?? timestamp(header["timestamp"])
        let interruptedTool = toolIndices.values.contains { items[$0].tool?.state == .interrupted }
        return .init(sessionID: sessionID, file: file, cwd: cwd, title: title, items: items, turns: turns, incompleteTail: !decoder.pending.isEmpty, warnings: Array(Set(warnings)).sorted(), selection: selection, usage: decoder.pending.isEmpty ? usage.snapshot(id: sessionID) : nil,
                     activityAt: lastTimestamp, lastObservedModel: lastObservedModel, needsAttention: needsReply || interruptedTool)
    }
    private static func timestamp(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
            ?? (try? Date.ISO8601FormatStyle().parse(raw))
    }
}
