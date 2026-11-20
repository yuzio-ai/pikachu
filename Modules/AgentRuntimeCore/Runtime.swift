import Foundation

public enum RuntimeCapability: String, Sendable, Hashable { case streaming, tools, interruption, queuedPrompts, turnFileChanges }
public enum SendMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case steer, followUp
    public var id: Self { self }
}
public enum AgentMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case plan, interactive, automatic
    public var id: Self { self }
    public var availableApprovals: [ToolApprovalPolicy] {
        switch self {
        case .interactive: [.everyCall, .mutations, .never]
        case .plan: [.everyCall, .never]
        case .automatic: [.never]
        }
    }
    public var defaultApproval: ToolApprovalPolicy { self == .interactive ? .mutations : .never }
}
public enum ToolApprovalPolicy: String, Sendable, Codable, Identifiable {
    case everyCall, mutations, never
    public var id: Self { self }
}
public struct AgentExecutionPolicy: Sendable, Equatable {
    public let mode: AgentMode
    public let approval: ToolApprovalPolicy

    public init(mode: AgentMode, approval: ToolApprovalPolicy? = nil) {
        self.mode = mode
        self.approval = approval.flatMap { mode.availableApprovals.contains($0) ? $0 : nil } ?? mode.defaultApproval
    }
}
public enum PromptDisposition: String, Sendable { case started, queued, handled }
public struct UserPrompt: Sendable {
    public let id: UUID
    public let text: String
    public let mode: SendMode
    public let files: [URL]
    public var hasContent: Bool { !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var runtimeText: String {
        guard !files.isEmpty else { return text }
        let paths = files.map { $0.path.debugDescription }.joined(separator: "\n")
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请查看以下文件。" : text
        return "\(message)\n\n本地文件引用（按需读取）\n\(paths)"
    }
    public init(id: UUID = UUID(), text: String, mode: SendMode = .steer, files: [URL] = []) {
        self.id = id; self.text = text; self.mode = mode; self.files = files
    }
}
public struct RuntimeSession: Sendable, Equatable {
    public let id: String
    public let model: String
    public let thinking: String
    public let capabilities: Set<RuntimeCapability>
    public let file: URL?
    public let provider: String?
    public let modelID: String?
    public init(id: String, model: String, thinking: String, capabilities: Set<RuntimeCapability>, file: URL? = nil, provider: String? = nil, modelID: String? = nil) {
        self.id = id; self.model = model; self.thinking = thinking; self.capabilities = capabilities
        self.file = file; self.provider = provider; self.modelID = modelID
    }
}
public struct PendingPrompt: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let mode: SendMode
    public let files: [URL]?
    public init(id: UUID = UUID(), text: String, mode: SendMode, files: [URL] = []) {
        self.id = id; self.text = text; self.mode = mode; self.files = files.isEmpty ? nil : files
    }
}
public struct RuntimeQueue: Sendable, Equatable {
    public var steering: [String]
    public var followUp: [String]
    public var isEmpty: Bool { steering.isEmpty && followUp.isEmpty }
    public init(steering: [String] = [], followUp: [String] = []) { self.steering = steering; self.followUp = followUp }
}
public protocol RuntimeClock: Sendable {
    func now() -> Date
    func monotonicNow() -> ContinuousClock.Instant
}
public struct SystemRuntimeClock: RuntimeClock {
    public init() {}
    public func now() -> Date { Date() }
    public func monotonicNow() -> ContinuousClock.Instant { ContinuousClock.now }
}
public enum TurnStatus: String, Sendable, Codable, Equatable {
    case running, completed, stopped, failed, uncertain
}
public enum ExecutionPhase: String, Sendable {
    case idle, running, waitingInput, retrying, compacting, stopping, uncertain
    public var isActive: Bool { self != .idle }
}
public enum ToolState: String, Sendable, Codable { case running, completed, failed, interrupted }
public struct RuntimeTool: Sendable, Codable, Equatable, Identifiable {
    public struct EditArguments: Codable, Sendable, Equatable {
        public static let maximumPreviewBytes = 65_536
        public static let maximumPreviewLinesPerSide = 256

        public let path: String
        public let edits: [RuntimeToolApproval.Replacement]
        public let replacementCount: Int
        public var omittedPreviewCount: Int { replacementCount - edits.count }

        private enum CodingKeys: String, CodingKey { case path, edits, replacementCount }

        public static func decodeToolArguments(from data: Data) throws -> Self {
            Self(raw: try JSONDecoder().decode(RawArguments.self, from: data))
        }

        public init(from decoder: Decoder) throws {
            let arguments = try decoder.container(keyedBy: CodingKeys.self)
            let recordedCount = try? arguments.decode(Int.self, forKey: .replacementCount)
            self.init(raw: try RawArguments(from: decoder), recordedCount: recordedCount)
        }

        private init(raw: RawArguments, recordedCount: Int? = nil) {
            path = raw.path
            replacementCount = max(raw.replacements.count, recordedCount ?? 0)
            edits = Self.previewableReplacements(raw.replacements)
        }

        private struct RawArguments: Decodable {
            let path: String
            let replacements: [RuntimeToolApproval.Replacement]

            init(from decoder: Decoder) throws {
                let arguments = try decoder.container(keyedBy: CodingKeys.self)
                path = try arguments.decode(String.self, forKey: .path)
                var replacements = try arguments.decodeIfPresent(EditList.self, forKey: .edits)?.replacements ?? []
                if let legacy = try? RuntimeToolApproval.Replacement(from: decoder) {
                    replacements.append(legacy)
                }
                self.replacements = replacements
            }
        }

        private static func previewableReplacements(_ replacements: [RuntimeToolApproval.Replacement]) -> [RuntimeToolApproval.Replacement] {
            var remainingBytes = maximumPreviewBytes
            var remainingLines = maximumPreviewLinesPerSide * 2
            var preview: [RuntimeToolApproval.Replacement] = []
            for replacement in replacements {
                if remainingLines == 0 { break }
                let bytes = replacement.oldText.utf8.count + replacement.newText.utf8.count
                guard bytes <= remainingBytes else { continue }

                let oldLines = lineCount(in: replacement.oldText)
                let newLines = lineCount(in: replacement.newText)
                let lines = max(1, oldLines + newLines)
                guard oldLines <= maximumPreviewLinesPerSide, newLines <= maximumPreviewLinesPerSide,
                      lines <= remainingLines else { continue }

                preview.append(replacement)
                remainingBytes -= bytes
                remainingLines -= lines
            }
            return preview
        }

        private static func lineCount(in text: String) -> Int {
            var terminatedLines = 0
            for character in text where character.isNewline {
                terminatedLines += 1
                if terminatedLines > maximumPreviewLinesPerSide { return terminatedLines }
            }
            return terminatedLines + (text.last?.isNewline == false ? 1 : 0)
        }

        private struct EditList: Decodable {
            let replacements: [RuntimeToolApproval.Replacement]

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let array = try? container.decode([RuntimeToolApproval.Replacement].self) {
                    replacements = array
                } else if let replacement = try? container.decode(RuntimeToolApproval.Replacement.self) {
                    replacements = [replacement]
                } else {
                    let input = Data(try container.decode(String.self).utf8)
                    let decoder = JSONDecoder()
                    if let array = try? decoder.decode([RuntimeToolApproval.Replacement].self, from: input) {
                        replacements = array
                    } else {
                        replacements = [try decoder.decode(RuntimeToolApproval.Replacement.self, from: input)]
                    }
                }
            }
        }
    }

    public let id: String
    public var name: String
    public var arguments: String
    public var argumentsTruncated: Bool?
    public var editArguments: EditArguments?
    public var output: String
    public var state: ToolState
    public var truncated: Bool
    public init(id: String, name: String, arguments: String = "", output: String = "", state: ToolState = .running, truncated: Bool = false) {
        self.id = id; self.name = name; self.arguments = arguments; self.output = output; self.state = state; self.truncated = truncated
    }
}
public enum RuntimeFailureKind: String, Sendable { case setup, unsupportedVersion, authentication, model, tool, protocolError, connection, outcomeUnknown, supervision, unsupportedInteraction }
public struct RuntimeFailure: Error, Sendable, Equatable {
    public let kind: RuntimeFailureKind
    public let detail: String
    public init(_ kind: RuntimeFailureKind, _ detail: String) { self.kind = kind; self.detail = detail }
}
public enum AgentEvent: Sendable {
    case batch([AgentEvent])
    case phase(ExecutionPhase)
    case runStarted
    case userMessageTimestamp(Int64, text: String? = nil)
    case assistantStarted(UUID)
    case assistantTimestamp(UUID, Int64)
    case textDelta(UUID, Int, String)
    case assistantCompleted(UUID, String)
    case tool(RuntimeTool)
    case turnFileChanges(TurnFileChanges)
    case queue(RuntimeQueue)
    case settled(aborted: Bool)
    case recoveredDrafts(UUID, [PendingPrompt])
    case notice(String)
    case failure(RuntimeFailure)
    case disconnected(cleanupConfirmed: Bool)
    case interaction(RuntimeInteraction)
    case interactionEnded(String, InteractionEnd)
    case suggestedDraft(String)
    case extensionStatus(String, String?)
}
public struct RuntimeEnvelope: Sendable {
    public let instanceID: UUID
    public let event: AgentEvent
    public init(instanceID: UUID, event: AgentEvent) { self.instanceID = instanceID; self.event = event }
}
public protocol AgentRuntime: Sendable {
    var instanceID: UUID { get }
    var events: AsyncStream<RuntimeEnvelope> { get }
    func connect() async throws -> RuntimeSession
    func send(_ prompt: UserPrompt) async throws -> PromptDisposition
    func stop() async throws
    func close(force: Bool) async throws
    func configurationOptions() async throws -> RuntimeConfigurationOptions
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession
    func currentSession() async throws -> RuntimeSession
    func usage() async throws -> RuntimeUsage
    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws
    func cancelInteractions() async
}

public extension AgentRuntime {
    func configurationOptions() async throws -> RuntimeConfigurationOptions { throw RuntimeFailure(.setup, String(localized: "此运行时不支持模型配置。", bundle: #bundle)) }
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession { throw RuntimeFailure(.setup, String(localized: "此运行时不支持模型配置。", bundle: #bundle)) }
    func currentSession() async throws -> RuntimeSession { throw RuntimeFailure(.setup, String(localized: "此运行时不支持状态读取。", bundle: #bundle)) }
    func usage() async throws -> RuntimeUsage { throw RuntimeFailure(.setup, String(localized: "此运行时未提供统计。", bundle: #bundle)) }
    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws { throw RuntimeFailure(.unsupportedInteraction, String(localized: "此运行时不支持交互回复。", bundle: #bundle)) }
    func cancelInteractions() async {}
}
