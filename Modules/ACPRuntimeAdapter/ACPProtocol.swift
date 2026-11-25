import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// ACP v1 (`protocolVersion: 1`) wire constants and strongly typed payload parsers.
public enum ACPProtocol {
    public static let supportedVersion = 1

    public enum Method {
        public static let initialize = "initialize"
        public static let authenticate = "authenticate"
        public static let logout = "logout"
        public static let sessionList = "session/list"
        public static let sessionResume = "session/resume"
        public static let sessionClose = "session/close"
        public static let sessionDelete = "session/delete"
        public static let cancelRequest = "$/cancel_request"
        public static let elicitationCreate = "elicitation/create"
        public static let elicitationComplete = "elicitation/complete"
        public static let sessionNew = "session/new"
        public static let sessionLoad = "session/load"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionUpdate = "session/update"
        public static let sessionRequestPermission = "session/request_permission"
        public static let sessionSetMode = "session/set_mode"
        public static let sessionSetModel = "session/set_model"
        public static let sessionSetConfigOption = "session/set_config_option"
    }

    public enum ErrorCode {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        public static let authRequired = -32000
        public static let resourceNotFound = -32002
    }
}

public struct ACPImplementationInfo: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let version: String?

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    public init(name: String, title: String? = nil, version: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
    }

    static func parse(_ record: Record?) -> ACPImplementationInfo? {
        guard let record, let name = record["name"] as? String, !name.isEmpty else { return nil }
        return ACPImplementationInfo(
            name: name,
            title: record["title"] as? String,
            version: record["version"] as? String
        )
    }
}

public struct ACPPromptCapabilities: Sendable, Equatable {
    public let image: Bool
    public let audio: Bool
    public let embeddedContext: Bool

    public init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
    }

    static func parse(_ record: Record?) -> ACPPromptCapabilities {
        guard let record else { return .init() }
        return ACPPromptCapabilities(
            image: record["image"] as? Bool ?? false,
            audio: record["audio"] as? Bool ?? false,
            embeddedContext: record["embeddedContext"] as? Bool ?? false
        )
    }
}

public struct ACPMCPCapabilities: Sendable, Equatable {
    public let http: Bool
    public let sse: Bool

    public init(http: Bool = false, sse: Bool = false) {
        self.http = http
        self.sse = sse
    }

    static func parse(_ record: Record?) -> ACPMCPCapabilities {
        guard let record else { return .init() }
        return ACPMCPCapabilities(
            http: record["http"] as? Bool ?? false,
            sse: record["sse"] as? Bool ?? false
        )
    }
}

public struct ACPAgentCapabilities: Sendable, Equatable {
    public let loadSession: Bool
    public let sessions: Set<String>
    public let logout: Bool
    public var canRestoreSession: Bool { loadSession || sessions.contains("resume") }
    public let promptCapabilities: ACPPromptCapabilities
    public let mcpCapabilities: ACPMCPCapabilities

    public init(loadSession: Bool = false,
                promptCapabilities: ACPPromptCapabilities = .init(),
                mcpCapabilities: ACPMCPCapabilities = .init(),
                sessions: Set<String> = [], logout: Bool = false) {
        self.loadSession = loadSession
        self.sessions = sessions
        self.logout = logout
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
    }

    static func parse(_ record: Record?) -> ACPAgentCapabilities {
        guard let record else { return .init() }
        return ACPAgentCapabilities(
            loadSession: record["loadSession"] as? Bool ?? false,
            promptCapabilities: .parse(record["promptCapabilities"] as? Record),
            mcpCapabilities: .parse(record["mcpCapabilities"] as? Record),
            sessions: Set((record["sessionCapabilities"] as? Record ?? [:]).compactMap { key, value in
                value is Record ? key : nil
            }),
            logout: (record["auth"] as? Record)?["logout"] is Record
        )
    }
}

public struct ACPAuthMethod: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let type: String
    let arguments: [String]
    let environment: [String: String]

    public init(id: String, name: String, description: String? = nil, type: String = "agent",
                arguments: [String] = [], environment: [String: String] = [:]) {
        self.type = type
        self.id = id
        self.name = name
        self.description = description
        self.arguments = arguments
        self.environment = environment
    }

    static func parseList(_ raw: Any?) -> [ACPAuthMethod] {
        guard let records = raw as? [Record] else { return [] }
        var seen: Set<String> = []
        return records.compactMap { record in
            guard let id = record["id"] as? String, !id.isEmpty else { return nil }
            let type = record["type"] as? String ?? "agent"
            let arguments = record["args"] as? [String]
            let environment = record["env"] as? [String: String]
            if type == "terminal" {
                guard record["args"] == nil || arguments != nil,
                      record["env"] == nil || environment != nil else { return nil }
            }
            guard seen.insert(id).inserted else { return nil }
            return ACPAuthMethod(
                id: id,
                name: (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                description: record["description"] as? String,
                type: type,
                arguments: arguments ?? [],
                environment: environment ?? [:]
            )
        }
    }
}

public struct ACPInitializeResult: Sendable, Equatable {
    public let protocolVersion: Int
    public let agentInfo: ACPImplementationInfo?
    public let agentCapabilities: ACPAgentCapabilities
    public let authMethods: [ACPAuthMethod]

    public init(protocolVersion: Int,
                agentInfo: ACPImplementationInfo? = nil,
                agentCapabilities: ACPAgentCapabilities = .init(),
                authMethods: [ACPAuthMethod] = []) {
        self.protocolVersion = protocolVersion
        self.agentInfo = agentInfo
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
    }

    public static func parse(_ record: Record) -> ACPInitializeResult? {
        guard let version = ACPJSON.int(record["protocolVersion"]) else { return nil }
        return ACPInitializeResult(
            protocolVersion: version,
            agentInfo: .parse(record["agentInfo"] as? Record),
            agentCapabilities: .parse(record["agentCapabilities"] as? Record),
            authMethods: ACPAuthMethod.parseList(record["authMethods"])
        )
    }
}

public struct ACPModeInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct ACPModesState: Sendable, Equatable {
    public var currentModeID: String
    public var availableModes: [ACPModeInfo]

    public init(currentModeID: String, availableModes: [ACPModeInfo]) {
        self.currentModeID = currentModeID
        self.availableModes = availableModes
    }

    static func parse(_ record: Record?) -> ACPModesState? {
        guard let record, let current = record["currentModeId"] as? String, !current.isEmpty else { return nil }
        let modes = (record["availableModes"] as? [Record] ?? []).compactMap { item -> ACPModeInfo? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ACPModeInfo(id: id, name: name, description: item["description"] as? String)
        }
        return ACPModesState(currentModeID: current, availableModes: modes)
    }
}

public struct ACPModelInfo: Sendable, Equatable {
    public let modelID: String
    public let name: String
    public let description: String?

    public init(modelID: String, name: String, description: String? = nil) {
        self.modelID = modelID
        self.name = name
        self.description = description
    }
}

public struct ACPModelsState: Sendable, Equatable {
    public var currentModelID: String
    public var availableModels: [ACPModelInfo]

    public init(currentModelID: String, availableModels: [ACPModelInfo]) {
        self.currentModelID = currentModelID
        self.availableModels = availableModels
    }

    static func parse(_ record: Record?) -> ACPModelsState? {
        guard let record else { return nil }
        let current = record["currentModelId"] as? String ?? ""
        let models = (record["availableModels"] as? [Record] ?? []).compactMap { item -> ACPModelInfo? in
            guard let id = item["modelId"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ACPModelInfo(modelID: id, name: name, description: item["description"] as? String)
        }
        guard !current.isEmpty || !models.isEmpty else { return nil }
        return ACPModelsState(currentModelID: current, availableModels: models)
    }
}

public struct ACPConfigSelectOption: Sendable, Equatable {
    public let value: String
    public let name: String
    public let description: String?
    public let group: String?

    public init(value: String, name: String, description: String? = nil, group: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
        self.group = group
    }
}

public struct ACPConfigOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let type: String
    public var currentValue: String
    public let options: [ACPConfigSelectOption]

    public init(id: String, name: String, description: String? = nil, category: String? = nil,
                type: String = "select", currentValue: String, options: [ACPConfigSelectOption]) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.options = options
    }

    static func parseList(_ raw: Any?) -> [ACPConfigOption] {
        guard let records = raw as? [Record] else { return [] }
        return records.compactMap(parse)
    }

    static func parse(_ record: Record) -> ACPConfigOption? {
        guard let id = record["id"] as? String, !id.isEmpty,
              let currentValue = record["currentValue"] as? String else { return nil }
        let name = (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let type = record["type"] as? String ?? "select"
        var parsedOptions: [ACPConfigSelectOption] = []
        if let rawOptions = record["options"] as? [Record] {
            for item in rawOptions {
                if let groupName = item["name"] as? String, let nested = item["options"] as? [Record] {
                    for option in nested {
                        if let parsed = parseSelectOption(option, group: groupName) {
                            parsedOptions.append(parsed)
                        }
                    }
                } else if let parsed = parseSelectOption(item, group: nil) {
                    parsedOptions.append(parsed)
                }
            }
        }
        return ACPConfigOption(
            id: id,
            name: name,
            description: record["description"] as? String,
            category: record["category"] as? String,
            type: type,
            currentValue: currentValue,
            options: parsedOptions
        )
    }

    private static func parseSelectOption(_ record: Record, group: String?) -> ACPConfigSelectOption? {
        guard let value = record["value"] as? String, !value.isEmpty else { return nil }
        let name = (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
        return ACPConfigSelectOption(
            value: value,
            name: name,
            description: record["description"] as? String,
            group: group
        )
    }
}

public struct ACPSessionMetadata: Sendable, Equatable {
    public var modes: ACPModesState?
    public var models: ACPModelsState?
    public var configOptions: [ACPConfigOption]

    public init(modes: ACPModesState? = nil, models: ACPModelsState? = nil, configOptions: [ACPConfigOption] = []) {
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
    }

    public static func parse(_ record: Record) -> ACPSessionMetadata {
        ACPSessionMetadata(
            modes: .parse(record["modes"] as? Record),
            models: .parse(record["models"] as? Record),
            configOptions: ACPConfigOption.parseList(record["configOptions"])
        )
    }

    public func configOption(category: String) -> ACPConfigOption? {
        configOptions.first { $0.category == category }
    }

    public func availableRuntimeModels(defaultProvider: String) -> [RuntimeModel] {
        if let modelOption = configOption(category: "model"), !modelOption.options.isEmpty {
            return modelOption.options.map {
                RuntimeModel(provider: defaultProvider, modelID: $0.value, name: $0.name)
            }
        }
        if let models, !models.availableModels.isEmpty {
            return models.availableModels.map {
                RuntimeModel(provider: defaultProvider, modelID: $0.modelID, name: $0.name)
            }
        }
        return []
    }

    public func availableThinkingLevels() -> [String] {
        guard let option = configOption(category: "thought_level") else { return [] }
        return option.options.map(\.value)
    }

    public func currentModelID() -> String? {
        if let option = configOption(category: "model"), !option.currentValue.isEmpty {
            return option.currentValue
        }
        if let id = models?.currentModelID, !id.isEmpty {
            return id
        }
        return nil
    }

    public func currentModelDisplayName(fallback: String) -> String {
        if let option = configOption(category: "model") {
            if let match = option.options.first(where: { $0.value == option.currentValue }) {
                return match.name
            }
            if !option.currentValue.isEmpty { return option.currentValue }
        }
        if let models, !models.currentModelID.isEmpty {
            if let match = models.availableModels.first(where: { $0.modelID == models.currentModelID }) {
                return match.name
            }
            return models.currentModelID
        }
        return fallback
    }

    public func currentThinkingLevel() -> String {
        if let option = configOption(category: "thought_level"), !option.currentValue.isEmpty {
            return option.currentValue
        }
        return "—"
    }

    public func currentModeID() -> String? {
        if let option = configOption(category: "mode"), !option.currentValue.isEmpty {
            return option.currentValue
        }
        if let id = modes?.currentModeID, !id.isEmpty {
            return id
        }
        return nil
    }

    public func availableModesList() -> [ACPModeInfo] {
        if let option = configOption(category: "mode"), !option.options.isEmpty {
            return option.options.map { ACPModeInfo(id: $0.value, name: $0.name, description: $0.description) }
        }
        return modes?.availableModes ?? []
    }
}

public enum ACPStopReason: String, Sendable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
    case cancelled = "cancelled"
}

public struct ACPPromptUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedReadTokens: Int?
    public let cachedWriteTokens: Int?
    public let thoughtTokens: Int?
    public let totalTokens: Int?

    static func parse(_ record: Record?) -> ACPPromptUsage? {
        guard let record else { return nil }
        let parsed = ACPPromptUsage(
            inputTokens: ACPJSON.int(record["inputTokens"]),
            outputTokens: ACPJSON.int(record["outputTokens"]),
            cachedReadTokens: ACPJSON.int(record["cachedReadTokens"]),
            cachedWriteTokens: ACPJSON.int(record["cachedWriteTokens"]),
            thoughtTokens: ACPJSON.int(record["thoughtTokens"]),
            totalTokens: ACPJSON.int(record["totalTokens"])
        )
        guard parsed.inputTokens != nil || parsed.outputTokens != nil || parsed.cachedReadTokens != nil
                || parsed.cachedWriteTokens != nil || parsed.totalTokens != nil else { return nil }
        return parsed
    }
}

public struct ACPPromptResponse: Sendable, Equatable {
    public let stopReason: ACPStopReason
    public let usage: ACPPromptUsage?

    static func parse(_ record: Record) -> ACPPromptResponse? {
        guard let rawReason = record["stopReason"] as? String,
              let stopReason = ACPStopReason(rawValue: rawReason) else { return nil }
        return ACPPromptResponse(
            stopReason: stopReason,
            usage: .parse(record["usage"] as? Record)
        )
    }
}

public struct ACPDiffBlock: Sendable, Equatable {
    public let path: String
    public let oldText: String?
    public let newText: String

    public init(path: String, oldText: String?, newText: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
}

public struct ACPPlanEntry: Sendable, Equatable {
    public let content: String
    public let priority: String?
    public let status: String

    public init(content: String, priority: String? = nil, status: String) {
        self.content = content
        self.priority = priority
        self.status = status
    }

    static func parseList(_ raw: Any?) -> [ACPPlanEntry] {
        guard let items = raw as? [Record] else { return [] }
        return items.compactMap { item in
            guard let content = item["content"] as? String, !content.isEmpty else { return nil }
            let status = item["status"] as? String ?? "pending"
            return ACPPlanEntry(content: content, priority: item["priority"] as? String, status: status)
        }
    }
}

public struct ACPUsageSnapshot: Sendable, Equatable {
    public let used: Int?
    public let size: Int?
    public let costAmount: Double?
    public let costCurrency: String?

    static func parse(_ record: Record) -> ACPUsageSnapshot {
        let cost = record["cost"] as? Record
        return ACPUsageSnapshot(
            used: ACPJSON.int(record["used"]),
            size: ACPJSON.int(record["size"]),
            costAmount: ACPJSON.double(cost?["amount"]),
            costCurrency: cost?["currency"] as? String
        )
    }
}

public struct ACPPermissionOptionPayload: Sendable, Equatable {
    public let optionID: String
    public let name: String
    public let kind: String

    public init(optionID: String, name: String, kind: String) {
        self.optionID = optionID
        self.name = name
        self.kind = kind
    }

    static func parseList(_ raw: Any?) -> [ACPPermissionOptionPayload] {
        guard let records = raw as? [Record] else { return [] }
        return records.compactMap { record in
            guard let optionID = record["optionId"] as? String, !optionID.isEmpty,
                  let name = record["name"] as? String, !name.isEmpty else { return nil }
            return ACPPermissionOptionPayload(
                optionID: optionID,
                name: name,
                kind: record["kind"] as? String ?? "other"
            )
        }
    }
}

public struct ACPJSONRPCError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let dataCode: String?
    public let authHint: String?

    var hasAuthenticationCode: Bool {
        code == ACPProtocol.ErrorCode.authRequired || dataCode?.lowercased() == "auth_required"
    }

    var messageBeforeExplicitAuthenticationReason: Substring? {
        let status = message.firstMatch(of: /(?i)\b(?:(?:http(?:\/\d+(?:\.\d+)?)?|status(?: code)?)\s*:?\s*401|401[\s:-]+bearer)\b/)
        let reason = message.firstMatch(of: /(?i)\b(?:unauthorized|auth_required|authentication (?:required|failed)|(?:invalid|missing) api key|api key (?:invalid|missing|expired))\b/)
        guard let start = [status?.range.lowerBound, reason?.range.lowerBound].compactMap({ $0 }).min() else { return nil }
        return message[..<start]
    }

    public var isAuthRequired: Bool {
        if hasAuthenticationCode { return true }
        let lower = message.lowercased()
        return lower.contains("auth_required") || lower.contains("authentication required")
            || lower.contains("unauthorized") || lower.contains(/\b401\b/)
            || messageBeforeExplicitAuthenticationReason != nil
    }

    public init(code: Int, message: String, dataCode: String? = nil, authHint: String? = nil) {
        self.code = code
        self.message = message
        self.dataCode = dataCode
        self.authHint = authHint
    }

    public init(rpcError: JSONRPCError) {
        let dataRecord = rpcError.dataObject as? Record
        self.code = rpcError.code
        self.message = rpcError.message
        self.dataCode = dataRecord?["code"] as? String
        self.authHint = dataRecord?["hint"] as? String ?? dataRecord?["details"] as? String
    }

    static func parse(_ record: Record?) -> ACPJSONRPCError? {
        guard let record, let code = ACPJSON.int(record["code"]) else { return nil }
        let message = record["message"] as? String ?? "JSON-RPC error"
        let data = record["data"] as? Record
        return ACPJSONRPCError(
            code: code,
            message: message,
            dataCode: data?["code"] as? String,
            authHint: data?["hint"] as? String ?? data?["details"] as? String
        )
    }
}

enum ACPJSON {
    static func int(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    static func double(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func textFromContentBlock(_ raw: Any?) -> String {
        guard let block = raw as? Record else { return "" }
        switch block["type"] as? String {
        case "text":
            return block["text"] as? String ?? ""
        case "resource_link":
            let name = block["name"] as? String ?? block["uri"] as? String ?? ""
            return name.isEmpty ? "" : "[resource: \(name)]"
        case "resource":
            if let resource = block["resource"] as? Record {
                if let text = resource["text"] as? String { return text }
                if let uri = resource["uri"] as? String { return "[resource: \(uri)]" }
            }
            return ""
        default:
            return block["text"] as? String ?? ""
        }
    }

    static func extractToolContent(_ raw: Any?) -> (text: String, diffs: [ACPDiffBlock], imageData: Data?) {
        guard let items = raw as? [Record] else { return ("", [], nil) }
        var texts: [String] = []
        var diffs: [ACPDiffBlock] = []
        var imageData: Data?
        for item in items {
            switch item["type"] as? String {
            case "content":
                if let inner = item["content"] as? Record {
                    let blockText = textFromContentBlock(inner)
                    if !blockText.isEmpty { texts.append(blockText) }
                    if imageData == nil, inner["type"] as? String == "image",
                       let mime = inner["mimeType"] as? String, mime.hasPrefix("image/"),
                       let encoded = inner["data"] as? String, encoded.utf8.count <= 8 * 1024 * 1024,
                       let data = Data(base64Encoded: encoded), !data.isEmpty {
                        imageData = data
                    }
                }
            case "diff":
                if let path = item["path"] as? String, !path.isEmpty,
                   let newText = item["newText"] as? String {
                    let oldText = item["oldText"] as? String
                    diffs.append(ACPDiffBlock(path: path, oldText: oldText, newText: newText))
                }
            case "terminal":
                if let terminalID = item["terminalId"] as? String {
                    texts.append("[terminal: \(terminalID)]")
                }
            case "text":
                if let text = item["text"] as? String, !text.isEmpty {
                    texts.append(text)
                }
            default:
                break
            }
        }
        return (texts.joined(separator: "\n"), diffs, imageData)
    }
}
