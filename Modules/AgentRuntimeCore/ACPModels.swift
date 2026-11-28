import Foundation

public enum RuntimeACPInlineImage {
    public static let maximumBytes = 8 * 1_024 * 1_024

    public static func mimeType(for file: URL) -> String? {
        switch file.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}

public enum ACPPoolStatus: Sendable, Equatable {
    case starting, ready(UUID), reconnecting, dedicated(ACPDedicatedConnectionReason), needsLogin(UUID?), failed(String)
}

public enum ACPDedicatedConnectionReason: Sendable, Equatable {
    case missingSessionClose, incompatible
}

/// Identifies the protocol family of a configured Coding Agent runtime.
public enum RuntimeAgentKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case acp
}

/// Built-in presets for adding ACP v1 Coding Agents in Settings.
public enum ACPAgentPreset: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case antigravity
    case custom

    public var id: String { rawValue }
}

public struct RuntimeACPClientPermissions: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let readFiles = Self(rawValue: 1 << 0)
    public static let writeFiles = Self(rawValue: 1 << 1)
    public static let terminals = Self(rawValue: 1 << 2)
}

/// Runtime-neutral descriptor for a configured Coding Agent (e.g. Antigravity CLI or a custom ACP v1 agent).
/// Lives in `AgentRuntimeCore` so `Features/` never imports `ACPRuntimeAdapter`.
public struct RuntimeAgentProfile: Identifiable, Codable, Sendable, Equatable, Hashable {
    public static let acpRuntimePrefix = "acp:"
    public static let antigravityRuntimeID = "acp:antigravity"

    public var id: String
    public var name: String
    public var kind: RuntimeAgentKind
    public var preset: ACPAgentPreset?
    public var executablePath: String
    public var arguments: [String]
    public var enabled: Bool
    public var toolSearchPaths: [String]
    public var clientPermissions: RuntimeACPClientPermissions
    public var registryID: String?

    public init(
        id: String = "acp:\(UUID().uuidString.lowercased())",
        name: String,
        kind: RuntimeAgentKind = .acp,
        preset: ACPAgentPreset? = .custom,
        executablePath: String,
        arguments: [String] = [],
        enabled: Bool = true,
        toolSearchPaths: [String] = [],
        clientPermissions: RuntimeACPClientPermissions = [],
        registryID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.preset = preset
        self.executablePath = executablePath
        self.arguments = arguments
        self.enabled = enabled
        self.toolSearchPaths = toolSearchPaths
        self.clientPermissions = clientPermissions
        self.registryID = registryID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, preset, executablePath, arguments, enabled, toolSearchPaths, clientPermissions, registryID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(RuntimeAgentKind.self, forKey: .kind) ?? .acp
        preset = try container.decodeIfPresent(ACPAgentPreset.self, forKey: .preset)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        toolSearchPaths = try container.decodeIfPresent([String].self, forKey: .toolSearchPaths) ?? []
        clientPermissions = try container.decodeIfPresent(RuntimeACPClientPermissions.self, forKey: .clientPermissions) ?? []
        registryID = try container.decodeIfPresent(String.self, forKey: .registryID)
    }

    public var isAntigravityPreset: Bool {
        preset == .antigravity || id == Self.antigravityRuntimeID
    }

    public static func isACPRuntimeID(_ runtimeID: String) -> Bool {
        // Older workspaces also accepted user-supplied ACP configuration IDs.
        !runtimeID.isEmpty && runtimeID != "pi"
    }

    public static func antigravityPreset(executablePath: String = "agy") -> RuntimeAgentProfile {
        RuntimeAgentProfile(
            id: antigravityRuntimeID,
            name: "Antigravity",
            kind: .acp,
            preset: .antigravity,
            executablePath: executablePath,
            arguments: ["acp"],
            enabled: true,
            toolSearchPaths: []
        )
    }

    public static func customACP(
        id: String = "acp:\(UUID().uuidString.lowercased())",
        name: String,
        executablePath: String,
        arguments: [String] = [],
        enabled: Bool = true,
        toolSearchPaths: [String] = [],
        registryID: String? = nil
    ) -> RuntimeAgentProfile {
        RuntimeAgentProfile(
            id: id,
            name: name,
            kind: .acp,
            preset: .custom,
            executablePath: executablePath,
            arguments: arguments,
            enabled: enabled,
            toolSearchPaths: toolSearchPaths,
            registryID: registryID
        )
    }
}

/// Native execution mode option advertised by a runtime (e.g. ACP `default`, `accept-edits`, `plan`, `auto`).
public struct RuntimeModeOption: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Runtime-neutral self-check report for ACP v1 and other pluggable runtimes.
public struct RuntimeConnectionCheckResult: Equatable, Sendable {
    public enum Dependency: String, Hashable, Sendable, Codable {
        case executable
        case tools
        case environment
        case supervisor
    }

    public enum ProtocolVersion: Equatable, Sendable {
        case notChecked
        case compatible(Int)
        case unsupported(Int?)
        case timedOut
        case failed
    }

    public struct CapabilitiesSummary: Equatable, Sendable {
        public var loadSession: Bool
        public var imagePrompt: Bool
        public var modesCount: Int
        public var modelsCount: Int

        public init(
            loadSession: Bool = false,
            imagePrompt: Bool = false,
            modesCount: Int = 0,
            modelsCount: Int = 0
        ) {
            self.loadSession = loadSession
            self.imagePrompt = imagePrompt
            self.modesCount = modesCount
            self.modelsCount = modelsCount
        }
    }

    public let runtimeID: String
    public let executablePath: String
    public var dependencyFailure: Dependency?
    public var protocolVersion: ProtocolVersion
    public var agentName: String?
    public var agentVersion: String?
    public var capabilitiesSummary: CapabilitiesSummary
    public var authRequired: Bool
    public var authHint: String?
    public var cleanupUnconfirmed: Bool
    public var detail: String?

    public init(
        runtimeID: String,
        executablePath: String,
        dependencyFailure: Dependency? = nil,
        protocolVersion: ProtocolVersion = .notChecked,
        agentName: String? = nil,
        agentVersion: String? = nil,
        capabilitiesSummary: CapabilitiesSummary = .init(),
        authRequired: Bool = false,
        authHint: String? = nil,
        cleanupUnconfirmed: Bool = false,
        detail: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.executablePath = executablePath
        self.dependencyFailure = dependencyFailure
        self.protocolVersion = protocolVersion
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.capabilitiesSummary = capabilitiesSummary
        self.authRequired = authRequired
        self.authHint = authHint
        self.cleanupUnconfirmed = cleanupUnconfirmed
        self.detail = detail
    }

    public var isReady: Bool {
        guard dependencyFailure == nil, !authRequired, !cleanupUnconfirmed else { return false }
        if case .compatible = protocolVersion { return true }
        return false
    }
}

/// Permission choice offered by an agent (e.g. ACP `session/request_permission`).
public struct RuntimePermissionOption: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
        case other
    }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }
    public var isReject: Bool { kind == .rejectOnce || kind == .rejectAlways }
}

/// Optional structured tool details attached to a multi-option permission request.
public struct RuntimePermissionContext: Codable, Sendable, Equatable {
    public struct FileDiff: Codable, Sendable, Equatable {
        public let path: String
        public let oldText: String?
        public let newText: String

        public init(path: String, oldText: String?, newText: String) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.oldText == rhs.oldText && lhs.newText == rhs.newText
        }
    }

    public let toolCallID: String?
    public let toolTitle: String
    public let toolName: String?
    public let toolKind: String?
    public let workingDirectory: String?
    public let sessionDirectory: String?
    public let paths: [String]
    public let summary: String?
    public let toolSummary: String?
    public let rawInputJSON: String?
    public let diff: RuntimeTool.EditArguments?
    public let diffs: [FileDiff]?
    public let awaitingToolDetails: Bool?

    public init(
        toolCallID: String? = nil,
        toolTitle: String,
        toolName: String? = nil,
        toolKind: String? = nil,
        workingDirectory: String? = nil,
        sessionDirectory: String? = nil,
        paths: [String] = [],
        summary: String? = nil,
        toolSummary: String? = nil,
        rawInputJSON: String? = nil,
        diff: RuntimeTool.EditArguments? = nil,
        diffs: [FileDiff]? = nil,
        awaitingToolDetails: Bool? = nil
    ) {
        self.toolCallID = toolCallID
        self.toolTitle = toolTitle
        self.toolName = toolName
        self.toolKind = toolKind
        self.workingDirectory = workingDirectory
        self.sessionDirectory = sessionDirectory
        self.paths = paths
        self.summary = summary
        self.toolSummary = toolSummary
        self.rawInputJSON = rawInputJSON
        self.diff = diff
        self.diffs = diffs
        self.awaitingToolDetails = awaitingToolDetails
    }

    public var fileDiffs: [FileDiff] {
        if let diffs { return diffs }
        guard let diff else { return [] }
        return diff.edits.map { .init(path: diff.path, oldText: $0.oldText, newText: $0.newText) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Path-only updates must differ even when Swift considers their strings canonically equivalent.
        lhs.toolCallID == rhs.toolCallID
            && lhs.toolTitle == rhs.toolTitle
            && lhs.toolName == rhs.toolName
            && lhs.toolKind == rhs.toolKind
            && samePath(lhs.workingDirectory, rhs.workingDirectory)
            && samePath(lhs.sessionDirectory, rhs.sessionDirectory)
            && lhs.paths.elementsEqual(rhs.paths, by: { $0.utf8.elementsEqual($1.utf8) })
            && lhs.summary == rhs.summary
            && lhs.toolSummary == rhs.toolSummary
            && lhs.rawInputJSON == rhs.rawInputJSON
            && lhs.diff == rhs.diff
            && samePath(lhs.diff?.path, rhs.diff?.path)
            && lhs.diffs == rhs.diffs
            && lhs.awaitingToolDetails == rhs.awaitingToolDetails
    }

    private static func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
}

public struct RuntimeRemoteSession: Equatable, Sendable, Identifiable {
    public let id: String
    public let directory: String
    public let title: String?

    public init(id: String, directory: String, title: String?) {
        self.id = id
        self.directory = directory
        self.title = title
    }
}

public struct RuntimeRemoteSessionPage: Equatable, Sendable {
    public let sessions: [RuntimeRemoteSession]
    public let nextCursor: String?
    public let canRestore: Bool
    public let canDelete: Bool

    public init(sessions: [RuntimeRemoteSession], nextCursor: String?, canRestore: Bool, canDelete: Bool) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.canRestore = canRestore
        self.canDelete = canDelete
    }
}

public struct RuntimeAgentAuthentication: Equatable, Sendable {
    public struct Method: Equatable, Sendable, Identifiable {
        public enum Kind: Sendable, Equatable { case agent, terminal }

        public let id: String
        public let name: String
        public let kind: Kind

        public init(id: String, name: String, kind: Kind = .agent) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public let methods: [Method]
    public let canLogout: Bool
    public let connectionID: UUID?

    public init(methods: [Method], canLogout: Bool, connectionID: UUID? = nil) {
        self.methods = methods
        self.canLogout = canLogout
        self.connectionID = connectionID
    }
}

public struct RuntimeTerminalAuthenticationLaunch: Sendable {
    public let name: String
    public let executable: URL
    public let workingDirectory: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let appendedArguments: [String]
    public let environmentOverrides: [String: String]

    public var requiresEnvironmentConsent: Bool { !environmentOverrides.isEmpty }

    public init(name: String, executable: URL, workingDirectory: URL, arguments: [String],
                environment: [String: String], appendedArguments: [String], environmentOverrides: [String: String]) {
        self.name = name
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.environment = environment
        self.appendedArguments = appendedArguments
        self.environmentOverrides = environmentOverrides
    }
}

/// An ended login can still own processes. Keep its cleanup check reachable
/// until the supervisor's terminal report is confirmed.
public struct RuntimeTerminalCleanupPending: Error, Sendable {
    public let failure: RuntimeFailure
    public let confirm: @MainActor @Sendable () -> Bool

    public init(failure: RuntimeFailure, confirm: @escaping @MainActor @Sendable () -> Bool) {
        self.failure = failure
        self.confirm = confirm
    }
}

public typealias RuntimeTerminalAuthenticator = @MainActor @Sendable (RuntimeTerminalAuthenticationLaunch) async throws -> Void

public enum RuntimeElicitation: Sendable, Equatable {
    case form([RuntimeElicitationField])
    case url(URL)
}

public struct RuntimeElicitationField: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case string, integer, number, boolean, array
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let required: Bool
    public let choices: [String]
    public let defaultValue: String?

    public init(id: String, title: String, kind: Kind, required: Bool,
                choices: [String], defaultValue: String?) {
        self.id = id
        self.title = title
        self.kind = kind
        self.required = required
        self.choices = choices
        self.defaultValue = defaultValue
    }
}

public protocol RuntimeAgentControl: Sendable {
    var authentication: RuntimeAgentAuthentication { get async }
    var isConnected: Bool { get async }
    var events: AsyncStream<RuntimeEnvelope> { get }
    var sharedConnectionID: UUID? { get async }
    func authenticate(methodID: String) async throws
    func logout() async throws
    func list(cursor: String?) async throws -> RuntimeRemoteSessionPage
    func delete(sessionID: String) async throws
    func respond(to interaction: RuntimeInteraction, with response: InteractionResponse) async throws
    func close() async throws
}

public extension RuntimeAgentControl {
    var sharedConnectionID: UUID? { get async { nil } }
}
