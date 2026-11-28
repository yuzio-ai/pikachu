import Foundation
import AgentRuntimeCore
import ProcessSupervision

public actor ACPRuntime: AgentRuntime {
    public typealias AuthenticationTransaction = @MainActor @Sendable (@Sendable () async throws -> Void) async throws -> Void

    public nonisolated let instanceID = UUID()
    public nonisolated let events: AsyncStream<RuntimeEnvelope>

    private let channel: RuntimeEventChannel
    private let configuration: ACPConfiguration
    private let pool: ACPConnectionPool?
    private var connection: ACPConnection?
    private var epoch = UUID()
    private let authenticationTransaction: AuthenticationTransaction?
    private let terminalAuthenticator: RuntimeTerminalAuthenticator?
    private var terminalLogin: Task<Void, Error>?
    private var startingConnection: Task<ACPConnection, Error>?
    private var openingSession: Task<RuntimeSession, Error>?
    private var terminalCleanup: RuntimeTerminalCleanupPending?
    private var startupCleanup: ACPStartupCleanupPending?
    private var connectingShared = false

    public init(configuration: ACPConfiguration, pool: ACPConnectionPool? = nil,
                authenticationTransaction: AuthenticationTransaction? = nil,
                terminalAuthenticator: RuntimeTerminalAuthenticator? = nil) {
        self.configuration = configuration
        self.pool = pool
        self.authenticationTransaction = authenticationTransaction
        self.terminalAuthenticator = terminalAuthenticator
        let channel = RuntimeEventChannel()
        self.channel = channel
        self.events = channel.stream()
    }

    /// Runs a zero-inference supervised self-check for an ACP v1 agent:
    /// checks executable & environment, runs `initialize` (strict `protocolVersion == 1`),
    /// runs `session/new` to discover modes/models/auth status, and confirms supervised cleanup.
    public static func checkConnection(_ config: ACPConfiguration) async -> RuntimeConnectionCheckResult {
        await Task.detached {
            let fm = FileManager.default
            var result = RuntimeConnectionCheckResult(
                runtimeID: config.runtimeID,
                executablePath: config.executable.path
            )

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: config.executable.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: config.executable.path) else {
                result.dependencyFailure = .executable
                result.detail = String(localized: "未找到可执行的 ACP Agent 文件。", bundle: #bundle)
                return result
            }
            guard config.toolSearchPaths.allSatisfy(ACPConfiguration.isValidToolSearchPath) else {
                result.dependencyFailure = .tools
                result.detail = String(localized: "ACP 工具搜索目录无效。", bundle: #bundle)
                return result
            }
            let environment: [String: String]
            do {
                environment = try config.launchEnvironment(inheriting: ProcessInfo.processInfo.environment)
            } catch let failure as RuntimeFailure {
                result.dependencyFailure = .environment
                result.detail = failure.detail
                return result
            } catch {
                result.dependencyFailure = .environment
                result.detail = String(localized: "ACP 环境变量无效。", bundle: #bundle)
                return result
            }

            let directory = fm.temporaryDirectory.appendingPathComponent("zivvi-acp-check-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch {
                result.protocolVersion = .failed
                result.detail = String(localized: "无法创建连接自检隔离目录。", bundle: #bundle)
                return result
            }
            defer { try? fm.removeItem(at: directory) }

            let transport: JSONRPCProcess
            do {
                transport = try JSONRPCProcess(
                    executable: config.executable.path,
                    arguments: config.arguments,
                    cwd: directory,
                    environment: environment,
                    supervised: true,
                    supervisionRoot: directory
                )
            } catch let pending as JSONRPCStartupCleanupPending {
                result.protocolVersion = .failed
                result.cleanupUnconfirmed = true
                result.detail = ACPStartupCleanupPending(process: pending.process).failure.detail
                return result
            } catch {
                let message = String(describing: error)
                if message.lowercased().contains("supervisor") {
                    result.dependencyFailure = .supervisor
                    result.detail = String(localized: "进程监督程序不可用，无法安全启动 Agent。", bundle: #bundle)
                } else {
                    result.protocolVersion = .failed
                    result.detail = String(localized: "启动 ACP Agent 进程失败。", bundle: #bundle)
                }
                return result
            }

            func finishAndCheckCleanup() {
                do {
                    try transport.close(timeout: 5)
                } catch {
                    transport.crash()
                    do {
                        try transport.close(timeout: 2)
                    } catch {
                        result.cleanupUnconfirmed = true
                    }
                }
                if transport.supervisionStatusURL != nil,
                   transport.supervisionStatus["state"] as? String != "clean" {
                    result.cleanupUnconfirmed = true
                }
            }

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let initParams: Record = [
                "protocolVersion": ACPProtocol.supportedVersion,
                "clientInfo": [
                    "name": "zivvi",
                    "title": "Zivvi",
                    "version": appVersion
                ],
                "clientCapabilities": [
                    "fs": [
                        "readTextFile": false,
                        "writeTextFile": false
                    ],
                    "terminal": false
                ]
            ]

            let initResponse: JSONRPCResponse
            do {
                initResponse = try transport.request(method: ACPProtocol.Method.initialize, params: initParams, timeout: 10)
            } catch {
                let text = String(describing: error).lowercased()
                if text.contains("deadline") || text.contains("timeout") || text.contains("timed out") {
                    result.protocolVersion = .timedOut
                    result.detail = String(localized: "ACP 初始化握手超时。", bundle: #bundle)
                } else {
                    result.protocolVersion = .failed
                    result.detail = String(localized: "ACP 初始化握手失败。", bundle: #bundle)
                }
                finishAndCheckCleanup()
                return result
            }

            if let rpcError = initResponse.error {
                let acpError = ACPConnection.toACPError(rpcError)
                if acpError.isAuthRequired {
                    result.authRequired = true
                    result.authHint = Self.sanitizedAuthHint(acpError: acpError, authMethods: [], config: config)
                    result.protocolVersion = .failed
                } else {
                    result.protocolVersion = .failed
                    result.detail = ACPEventMapper.failure(from: acpError).detail
                }
                finishAndCheckCleanup()
                return result
            }

            guard let initRecord = initResponse.resultRecord,
                  let initResult = ACPInitializeResult.parse(initRecord) else {
                result.protocolVersion = .unsupported(nil)
                result.detail = String(localized: "ACP 初始化响应格式无效。", bundle: #bundle)
                finishAndCheckCleanup()
                return result
            }

            result.agentName = initResult.agentInfo?.displayName
            result.agentVersion = initResult.agentInfo?.version
            result.capabilitiesSummary.loadSession = initResult.agentCapabilities.loadSession
            result.capabilitiesSummary.imagePrompt = initResult.agentCapabilities.promptCapabilities.image

            guard initResult.protocolVersion == ACPProtocol.supportedVersion else {
                result.protocolVersion = .unsupported(initResult.protocolVersion)
                result.detail = String(localized: "当前构建仅支持 ACP v1（protocolVersion: 1），该 Agent 返回的版本不受支持。", bundle: #bundle)
                finishAndCheckCleanup()
                return result
            }
            result.protocolVersion = .compatible(initResult.protocolVersion)

            // Zero-inference session/new probe to observe modes, models, and auth readiness.
            do {
                let sessionResponse = try transport.request(
                    method: ACPProtocol.Method.sessionNew,
                    params: ["cwd": directory.path, "mcpServers": [] as [Any]],
                    timeout: 15
                )
                if let rpcError = sessionResponse.error {
                    let acpError = ACPConnection.toACPError(rpcError)
                    if acpError.isAuthRequired {
                        result.authRequired = true
                        result.authHint = Self.sanitizedAuthHint(
                            acpError: acpError,
                            authMethods: initResult.authMethods,
                            config: config
                        )
                        result.detail = String(localized: "ACP Agent 需要先完成认证登录。", bundle: #bundle)
                    } else {
                        result.detail = ACPEventMapper.failure(from: acpError).detail
                    }
                } else if let sessionRecord = sessionResponse.resultRecord {
                    let meta = ACPSessionMetadata.parse(sessionRecord)
                    let provider = initResult.agentInfo?.name ?? config.runtimeID
                    result.capabilitiesSummary.modesCount = meta.availableModesList().count
                    result.capabilitiesSummary.modelsCount = meta.availableRuntimeModels(defaultProvider: provider).count
                }
            } catch {
                result.detail = ACPEventMapper.failure(String(describing: error)).detail
            }

            finishAndCheckCleanup()
            return result
        }.value
    }

    /// Reads the model catalogue and thinking levels for an ACP agent without invoking model inference.
    public static func inspectModels(_ config: ACPConfiguration, model: RuntimeModel? = nil) async throws -> RuntimeConfigurationOptions {
        try await Task.detached {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("zivvi-acp-models-\(UUID().uuidString)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }

            var probe = config
            probe.workspace = directory
            probe.expectedSessionID = nil
            probe.initialModeID = nil

            let connection = try ACPConnection(
                configuration: probe,
                instanceID: UUID(),
                sink: RuntimeEventChannel(),
                supervised: true,
                supervisionRoot: directory
            )

            let outcome = Result<RuntimeConfigurationOptions, Error> {
                _ = try connection.openSession()
                if let model, !model.modelID.isEmpty {
                    let selection = RuntimeSelection(provider: model.provider, modelID: model.modelID, thinking: nil)
                    _ = try? connection.configure(selection)
                    return RuntimeConfigurationOptions(models: [], thinkingLevels: connection.thinkingLevels())
                }
                return connection.configurationOptions()
            }

            do {
                try connection.close(force: false)
            } catch {
                try connection.close(force: true)
            }

            return try outcome.get()
        }.value
    }

    private static func sanitizedAuthHint(
        acpError: ACPJSONRPCError,
        authMethods: [ACPAuthMethod],
        config: ACPConfiguration
    ) -> String {
        if config.runtimeID == RuntimeAgentProfile.antigravityRuntimeID
            || config.executable.lastPathComponent == "agy" {
            return String(localized: "请在终端运行 `agy acp --login` 完成登录后重试。", bundle: #bundle)
        }
        if let method = authMethods.first, let description = method.description, !description.isEmpty {
            return String(description.prefix(240))
        }
        if let hint = acpError.authHint, !hint.isEmpty {
            return String(hint.prefix(240))
        }
        return String(localized: "请先在终端完成该 ACP Agent 的账号登录后重试。", bundle: #bundle)
    }

    // MARK: - AgentRuntime Conformance

    public func connect() async throws -> RuntimeSession {
        try await connect(authenticateInteractively: true)
    }

    public func connectForHistory() async throws -> RuntimeSession {
        try await connect(authenticateInteractively: false)
    }

    private func connect(authenticateInteractively: Bool) async throws -> RuntimeSession {
        try await confirmTerminalCleanup()
        try confirmStartupCleanup()
        guard connection == nil, startingConnection == nil, !connectingShared else {
            throw RuntimeFailure(.setup, String(localized: "当前连接尚未关闭。", bundle: #bundle))
        }
        let ticket = UUID()
        epoch = ticket
        var config = configuration
        if !authenticateInteractively { config.initialModeID = nil }
        let launchConfig = config
        let id = instanceID
        let sink = channel

        let authenticator = authenticateInteractively ? terminalAuthenticator : nil
        connectingShared = true
        defer { connectingShared = false }
        let host = try await pool?.connection(for: launchConfig)
        try Task.checkCancellation()
        guard epoch == ticket else { throw CancellationError() }
        let bridge: ACPConnection
        if let host {
            bridge = try ACPConnection(configuration: launchConfig, instanceID: id, sink: sink, host: host,
                                       deferDisconnectEvents: true)
        } else {
            bridge = try await startConnection {
                try ACPConnection(configuration: launchConfig, instanceID: id, sink: sink,
                                  terminalAuthentication: authenticator != nil, deferDisconnectEvents: true)
            }
        }

        guard epoch == ticket else {
            try? await Task.detached { try bridge.close(force: true) }.value
            throw CancellationError()
        }
        connection = bridge

        do {
            let opened: RuntimeSession
            do {
                opened = try await openSession(over: bridge)
            } catch let failure as RuntimeFailure where authenticateInteractively && failure.kind == .authentication {
                guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
                await pool?.authenticationRequired(on: bridge.sharedHost)
                let method = try await bridge.chooseAuthenticationMethod(after: failure)
                let authenticate: @Sendable () async throws -> Void = {
                    try await self.authenticate(method, over: bridge, terminalAuthenticator: authenticator, epoch: ticket)
                }
                if let authenticationTransaction { try await authenticationTransaction(authenticate) }
                else { try await authenticate() }
                guard let connection, epoch == ticket else { throw CancellationError() }
                opened = try await openSession(over: connection)
                await pool?.authenticated(on: connection.sharedHost)
            }
            try Task.checkCancellation()
            guard let connection, epoch == ticket else { throw CancellationError() }
            try connection.enableDisconnectEvents()
            return opened
        } catch {
            let pending = error as? RuntimeTerminalCleanupPending
            if let pending { terminalCleanup = pending }
            if epoch == ticket, let connection {
                try await Task.detached { try connection.close(force: connection.sharedHost == nil, notify: false) }.value
                self.connection = nil
            }
            if let pending { throw pending.failure }
            throw error
        }
    }

    private func authenticate(_ method: RuntimeAgentAuthentication.Method, over bridge: ACPConnection,
                              terminalAuthenticator: RuntimeTerminalAuthenticator?, epoch ticket: UUID) async throws {
        try Task.checkCancellation()
        guard epoch == ticket else { throw CancellationError() }
        if method.kind == .agent {
            try await bridge.authenticateAgent(methodID: method.id)
        } else if let terminalAuthenticator {
            let launch = try bridge.terminalAuthenticationLaunch(methodID: method.id)
            try await Task.detached { try bridge.close(force: false, notify: false) }.value
            try Task.checkCancellation()
            guard epoch == ticket else { throw CancellationError() }
            let login = Task { try await terminalAuthenticator(launch) }
            terminalLogin = login
            defer { terminalLogin = nil }
            try await withTaskCancellationHandler { try await login.value } onCancel: { login.cancel() }
            guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
            if let previousHost = bridge.sharedHost, let pool {
                let config = bridge.configuration
                if let receipt = config.handoffCleanup, receipt.isConfirmed {
                    try FileManager.default.removeItem(at: receipt.directory)
                }
                let host = try await pool.reconnectAfterLogin(config, replacing: previousHost)
                try Task.checkCancellation()
                guard epoch == ticket else { throw CancellationError() }
                if let host {
                    connection = try ACPConnection(configuration: config, instanceID: instanceID, sink: channel,
                                                   host: host, deferDisconnectEvents: true)
                } else {
                    let reconnected = try await startConnection {
                        try ACPConnection(configuration: config, instanceID: self.instanceID, sink: self.channel,
                                          terminalAuthentication: true, deferDisconnectEvents: true)
                    }
                    guard epoch == ticket else {
                        try await Task.detached { try reconnected.close(force: true, notify: false) }.value
                        throw CancellationError()
                    }
                    connection = reconnected
                    try Task.checkCancellation()
                }
                return
            }
            let reconnected = try await startConnection {
                try bridge.reopenAfterTerminalAuthentication(deferDisconnectEvents: true)
            }
            guard epoch == ticket else {
                try await Task.detached { try reconnected.close(force: true, notify: false) }.value
                throw CancellationError()
            }
            // Keep the replacement available for cleanup if cancellation wins.
            connection = reconnected
            try Task.checkCancellation()
        }
    }

    private func openSession(over bridge: ACPConnection) async throws -> RuntimeSession {
        let opening = Task.detached { try bridge.openSession() }
        openingSession = opening
        defer { openingSession = nil }
        return try await opening.value
    }

    private func startConnection(_ create: @escaping @Sendable () throws -> ACPConnection) async throws -> ACPConnection {
        let startup = Task.detached { try create() }
        startingConnection = startup
        defer { startingConnection = nil }
        do {
            return try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
        } catch let pending as ACPStartupCleanupPending {
            startupCleanup = pending
            throw pending.failure
        }
    }

    public func loadedSessionHistory() async -> [HistoryItem]? {
        connection?.takeLoadedHistory()
    }

    public func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return try await Task.detached { try connection.send(prompt) }.value
    }

    public func stop() async throws {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        try await Task.detached { try connection.stop() }.value
    }

    public func sharedConnectionImpact() async -> RuntimeConnectionImpact? {
        guard let host = connection?.sharedHost else { return nil }
        return .init(connectionID: host.id, runtimeIDs: host.endpointIDs)
    }

    public func forceEndSharedConnection(matching impact: RuntimeConnectionImpact) async throws -> Bool {
        guard let host = connection?.sharedHost, host.id == impact.connectionID,
              host.authorizeForce(matching: impact.runtimeIDs) else { return false }
        try await Task.detached { try host.shutdown(force: true) }.value
        return true
    }

    public func close(force: Bool) async throws {
        epoch = UUID()
        terminalLogin?.cancel()
        if let terminalLogin, case .failure(let pending as RuntimeTerminalCleanupPending) = await terminalLogin.result {
            terminalCleanup = pending
        }
        startingConnection?.cancel()
        if let startingConnection {
            switch await startingConnection.result {
            case .success(let candidate):
                connection = candidate
            case .failure(let pending as ACPStartupCleanupPending):
                startupCleanup = pending
            case .failure:
                break
            }
        }
        if !force, connection?.sharedHost != nil, let openingSession {
            // A submitted session/new may still return a remote ID that needs closing.
            _ = await openingSession.result
        }
        if let bridge = connection {
            let notify = terminalCleanup == nil
            try await Task.detached { try bridge.close(force: force, notify: notify) }.value
            connection = nil
        }
        try await confirmTerminalCleanup()
        try confirmStartupCleanup()
        channel.finish()
    }

    private func confirmTerminalCleanup() async throws {
        guard let terminalCleanup else { return }
        guard await terminalCleanup.confirm() else { throw terminalCleanup.failure }
        self.terminalCleanup = nil
    }

    private func confirmStartupCleanup() throws {
        if let startupCleanup {
            try startupCleanup.confirm()
            self.startupCleanup = nil
        }
    }

    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return await Task.detached { connection.configurationOptions() }.value
    }

    public func modelCatalogue() async throws -> [RuntimeModel] {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return await Task.detached { connection.availableModels() }.value
    }

    public func thinkingLevels() async throws -> [String] {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return await Task.detached { connection.thinkingLevels() }.value
    }

    public func currentSession() async throws -> RuntimeSession {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return await Task.detached { connection.sessionSnapshot() }.value
    }

    public func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return try await Task.detached { try connection.configure(selection) }.value
    }

    public func setMode(_ modeID: String) async throws -> RuntimeSession {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return try await Task.detached { try connection.setMode(modeID) }.value
    }

    public func usage() async throws -> RuntimeUsage {
        guard let connection else {
            throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle))
        }
        return await Task.detached { connection.usage() }.value
    }

    public func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {
        guard let connection, request.instanceID == instanceID else {
            throw RuntimeFailure(.unsupportedInteraction, String(localized: "交互来自已结束的执行实例。", bundle: #bundle))
        }
        try await Task.detached { try connection.respond(request, response) }.value
    }

    public func cancelInteractions() async {
        terminalLogin?.cancel()
        startingConnection?.cancel()
        if let connection {
            await Task.detached { connection.cancelInteractions() }.value
        }
    }

    // Verification hook: does not appear in AgentRuntime or product UI.
    public func terminateRuntimeForVerification() async {
        connection?.client.crash()
    }
}
