import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// A supervised connection for Agent operations outside a running workbench session.
public actor ACPAgentConnection: RuntimeAgentControl {
    private var bridge: ACPConnection?
    private let configuration: ACPConfiguration
    private let channel: RuntimeEventChannel
    private let terminalAuthenticator: RuntimeTerminalAuthenticator?
    private let pool: ACPConnectionPool?
    private var terminalLogin: Task<Void, Error>?
    private var startingBridge: Task<ACPConnection, Error>?
    private var terminalCleanup: RuntimeTerminalCleanupPending?
    private var startupCleanup: ACPStartupCleanupPending?
    private var connecting = false
    private var closing = false
    public nonisolated let events: AsyncStream<RuntimeEnvelope>
    public var isConnected: Bool {
        !closing && terminalCleanup == nil && startupCleanup == nil && bridge?.isAvailable == true
    }
    public var authentication: RuntimeAgentAuthentication {
        guard isConnected, let bridge else { return .init(methods: [], canLogout: false) }
        return bridge.authentication
    }

    public var sharedConnectionID: UUID? { bridge?.sharedHost?.id }

    public init(configuration: ACPConfiguration, terminalAuthenticator: RuntimeTerminalAuthenticator? = nil,
                pool: ACPConnectionPool? = nil) {
        self.configuration = configuration
        let channel = RuntimeEventChannel()
        self.channel = channel
        self.terminalAuthenticator = terminalAuthenticator
        self.pool = pool
        events = channel.stream()
    }

    public static func open(_ configuration: ACPConfiguration,
                            terminalAuthenticator: RuntimeTerminalAuthenticator? = nil,
                            pool: ACPConnectionPool? = nil) async throws -> ACPAgentConnection {
        let opened = ACPAgentConnection(configuration: configuration, terminalAuthenticator: terminalAuthenticator, pool: pool)
        do {
            try await opened.connect()
        } catch {
            try await opened.close()
            throw error
        }
        return opened
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard !closing, !connecting, startingBridge == nil, bridge == nil, startupCleanup == nil else { throw unsupported() }
        connecting = true
        defer { connecting = false }
        let config = configuration
        let sink = channel
        let supportsTerminal = terminalAuthenticator != nil
        let host = try await pool?.connection(for: config)
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        if let host {
            let endpoint = try ACPConnection(configuration: config, instanceID: UUID(), sink: sink,
                                             host: host, deferDisconnectEvents: false, isControl: true)
            bridge = endpoint
            return
        }
        try await startBridge {
            try ACPConnection(configuration: config, instanceID: UUID(), sink: sink,
                              terminalAuthentication: supportsTerminal, deferDisconnectEvents: true)
        }
    }

    public func close() async throws {
        closing = true
        channel.finish()
        terminalLogin?.cancel()
        if let terminalLogin, case .failure(let pending as RuntimeTerminalCleanupPending) = await terminalLogin.result {
            terminalCleanup = pending
        }
        startingBridge?.cancel()
        if let startingBridge {
            switch await startingBridge.result {
            case .success(let candidate):
                bridge = candidate
            case .failure(let pending as ACPStartupCleanupPending):
                startupCleanup = pending
            case .failure:
                break
            }
        }
        if let bridge {
            try await Task.detached { try bridge.close(force: false, notify: false) }.value
            self.bridge = nil
        }
        try await confirmTerminalCleanup()
        if let startupCleanup {
            try startupCleanup.confirm()
            self.startupCleanup = nil
        }
    }

    private func confirmTerminalCleanup() async throws {
        guard let terminalCleanup else { return }
        guard await terminalCleanup.confirm() else { throw terminalCleanup.failure }
        self.terminalCleanup = nil
    }

    public func authenticate(methodID: String) async throws {
        try await confirmTerminalCleanup()
        guard isConnected, terminalLogin == nil, startingBridge == nil, let bridge,
              let method = authentication.methods.first(where: { $0.id == methodID }) else {
            throw RuntimeFailure(.setup, String(localized: "ACP Agent 不支持此登录方式。", bundle: #bundle))
        }
        if method.kind == .agent {
            try await bridge.authenticateAgent(methodID: methodID)
            await pool?.authenticated(on: bridge.sharedHost)
            return
        }

        guard let terminalAuthenticator else { throw unsupported() }
        let launch = try bridge.terminalAuthenticationLaunch(methodID: methodID)
        let login = Task { try await terminalAuthenticator(launch) }
        terminalLogin = login
        defer { terminalLogin = nil }
        do {
            try await withTaskCancellationHandler { try await login.value } onCancel: { login.cancel() }
        } catch let pending as RuntimeTerminalCleanupPending {
            terminalCleanup = pending
            throw pending.failure
        }
        guard !closing, !Task.isCancelled else { throw CancellationError() }
        try await Task.detached { try bridge.close(force: false, notify: false) }.value
        self.bridge = nil
        guard !closing, !Task.isCancelled else { throw CancellationError() }

        if let previousHost = bridge.sharedHost, let pool {
            if let host = try await pool.reconnectAfterLogin(configuration, replacing: previousHost) {
                try Task.checkCancellation()
                guard !closing else { throw CancellationError() }
                self.bridge = try ACPConnection(configuration: configuration, instanceID: UUID(), sink: channel,
                                                host: host, deferDisconnectEvents: false, isControl: true)
            } else {
                try await connect()
            }
            return
        }

        try await startBridge {
            try bridge.reopenAfterTerminalAuthentication(instanceID: UUID(), deferDisconnectEvents: true)
        }
    }

    private func startBridge(_ create: @escaping @Sendable () throws -> ACPConnection) async throws {
        let start = Task.detached { try create() }
        startingBridge = start
        defer { startingBridge = nil }
        let candidate: ACPConnection
        do {
            candidate = try await withTaskCancellationHandler {
                try await start.value
            } onCancel: {
                start.cancel()
            }
        } catch let pending as ACPStartupCleanupPending {
            startupCleanup = pending
            throw pending.failure
        } catch {
            if Task.isCancelled, (error as? RuntimeFailure)?.kind != .supervision { throw CancellationError() }
            throw error
        }
        do {
            guard !closing else { throw CancellationError() }
            try Task.checkCancellation()
            try candidate.enableDisconnectEvents()
        } catch {
            bridge = candidate
            try await Task.detached { try candidate.close(force: true, notify: false) }.value
            bridge = nil
            throw error
        }
        bridge = candidate
    }

    public func logout() async throws {
        guard authentication.canLogout else { throw unsupported() }
        _ = try await request(ACPProtocol.Method.logout)
    }

    public func list(cursor: String?) async throws -> RuntimeRemoteSessionPage {
        let bridge = try connectedBridge()
        guard bridge.initializeResult.agentCapabilities.sessions.contains("list") else { throw unsupported() }
        var params: Record = ["cwd": bridge.configuration.workspace.path]
        params["cursor"] = cursor
        let response = try await request(ACPProtocol.Method.sessionList, params: params)
        guard let body = response.resultRecord, let records = body["sessions"] as? [Record] else {
            throw RuntimeFailure(.protocolError, String(localized: "ACP Agent 返回了无效的会话列表。", bundle: #bundle))
        }
        let root = bridge.configuration.workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let sessions = records.compactMap { entry -> RuntimeRemoteSession? in
            guard let id = entry["sessionId"] as? String, !id.isEmpty,
                  let directory = entry["cwd"] as? String, directory.hasPrefix("/"),
                  URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path == root
            else { return nil }
            return .init(id: id, directory: root, title: entry["title"] as? String)
        }
        let capabilities = bridge.initializeResult.agentCapabilities
        return .init(sessions: sessions, nextCursor: body["nextCursor"] as? String,
                     canRestore: capabilities.canRestoreSession, canDelete: capabilities.sessions.contains("delete"))
    }

    public func delete(sessionID: String) async throws {
        let bridge = try connectedBridge()
        guard bridge.initializeResult.agentCapabilities.sessions.contains("delete") else { throw unsupported() }
        let response = try await request(ACPProtocol.Method.sessionDelete, params: ["sessionId": sessionID],
                                         allowedError: ACPProtocol.ErrorCode.resourceNotFound)
        try ACPConnection.requireSessionMutationResult(response)
    }

    public func respond(to interaction: RuntimeInteraction, with response: InteractionResponse) async throws {
        try connectedBridge().broker.respond(interaction, response)
    }

    private func request(_ method: String, params: Record? = nil, timeout: Double = 15,
                         allowedError: Int? = nil) async throws -> JSONRPCResponse {
        try Task.checkCancellation()
        let bridge = try connectedBridge()
        let id = try bridge.sendLinkedRequest(method, params: params)
        defer { bridge.finishLinkedRequest(id) }
        let response = try await bridge.client.awaitResponse(id: id, timeout: timeout, notifyPeerOnCancel: true)
        if let error = response.error, error.code != allowedError {
            let failure = ACPEventMapper.failure(from: ACPConnection.toACPError(error))
            if failure.kind == .authentication { await pool?.authenticationRequired(on: bridge.sharedHost) }
            throw failure
        }
        return response
    }

    private func connectedBridge() throws -> ACPConnection {
        guard isConnected, let bridge else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return bridge
    }

    private func unsupported() -> RuntimeFailure {
        .init(.setup, String(localized: "当前 ACP Agent 不支持此操作。", bundle: #bundle))
    }
}
