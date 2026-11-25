import Foundation
import AgentRuntimeCore
import ProcessSupervision

struct ACPStartupCleanupPending: Error, Sendable {
    let process: JSONRPCProcess

    var failure: RuntimeFailure {
        .init(.supervision, String(localized: "工具进程清理未确认。", bundle: #bundle))
    }

    func confirm() throws {
        guard !process.isRunning else { throw failure }
        if let url = process.supervisionStatusURL {
            let status = process.supervisionStatus
            guard status["state"] as? String == "clean", status["remaining"] as? Int == 0,
                  status["supervisionID"] as? String == url.deletingLastPathComponent().lastPathComponent else {
                throw failure
            }
        }
    }
}

/// Single supervised ACP v1 execution connection.
/// Manages handshake, session creation/resume with replay isolation, non-blocking `session/prompt`,
/// `session/cancel` with bounded settlement wait, dual-path config updates, and supervised close.
final class ACPConnection: @unchecked Sendable {
    static let maximumImageAttachmentBytes = 8 * 1_024 * 1_024
    static let defaultControlTimeout: Double = 15
    static let sessionOpenTimeout: Double = 30

    let client: JSONRPCProcess
    let instanceID: UUID
    let sink: RuntimeEventChannel
    let broker: ACPInteractionBroker
    let clientServices: ACPClientServices
    let configuration: ACPConfiguration
    let initializeResult: ACPInitializeResult
    private let launchEnvironment: [String: String]
    private let terminalAuthentication: Bool

    private let stateLock = NSLock()
    private let closeLock = NSLock()
    private let mapperLock = NSLock()
    private let inboundDispatchLock = NSLock()
    private let turnCondition = NSCondition()

    private var mapper = ACPEventMapper()
    private var metadata = ACPSessionMetadata()
    private var sessionID: String?
    private var pendingReplaySessionID: String?
    private var loadedHistory: [HistoryItem]?
    private var latestPromptUsage: ACPPromptUsage?
    private var activePromptID: JSONRPCID?
    private var unconfirmedPromptID: UUID?
    private var authenticationInteraction: (RuntimeInteraction, AsyncStream<InteractionResponse>.Continuation)?
    private var closing = false
    private var disposed = false
    private var deferDisconnectEvents: Bool
    private var connectionEnded = false

    private var defaultProvider: String {
        if let name = initializeResult.agentInfo?.name, !name.isEmpty {
            return name
        }
        return configuration.runtimeID
    }

    init(
        configuration config: ACPConfiguration,
        instanceID: UUID,
        sink: RuntimeEventChannel,
        supervised: Bool = true,
        supervisionRoot: URL? = nil,
        precheckedEnvironment: [String: String]? = nil,
        terminalAuthentication: Bool = false,
        deferDisconnectEvents: Bool = false
    ) throws {
        self.configuration = config
        self.instanceID = instanceID
        self.sink = sink
        self.deferDisconnectEvents = deferDisconnectEvents
        let command = config.executable.resolvingSymlinksInPath().lastPathComponent
        let shellCommands = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "ssh", "mosh"]
        self.terminalAuthentication = terminalAuthentication && !shellCommands.contains(command)

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: config.workspace.path),
              fm.fileExists(atPath: config.executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fm.isExecutableFile(atPath: config.executable.path) else {
            throw RuntimeFailure(.setup, String(localized: "项目路径或 ACP 可执行文件不可用。", bundle: #bundle))
        }

        let environment = try precheckedEnvironment ?? config.launchEnvironment(inheriting: ProcessInfo.processInfo.environment)
        self.launchEnvironment = environment
        let transport: JSONRPCProcess
        do {
            transport = try JSONRPCProcess(
                executable: config.executable.path,
                arguments: config.arguments,
                cwd: config.workspace,
                environment: environment,
                supervised: supervised,
                supervisionRoot: supervisionRoot,
                supervisionDirectory: config.handoffCleanup?.directory
            )
        } catch let pending as JSONRPCStartupCleanupPending {
            throw ACPStartupCleanupPending(process: pending.process)
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }

        self.client = transport
        let clientServices = ACPClientServices(client: transport, configuration: config)
        self.clientServices = clientServices
        self.broker = ACPInteractionBroker(
            instanceID: instanceID,
            sendResponse: { id, payload in
                try clientServices.respondToApproval(id, payload: payload)
            },
            emit: { event in
                sink.send(.init(instanceID: instanceID, event: event))
            }
        )

        do {
            self.initializeResult = try Self.performInitialize(client: transport, permissions: clientServices.advertisedPermissions,
                                                               terminalAuthentication: self.terminalAuthentication)
        } catch {
            transport.crash()
            do {
                try transport.close(timeout: 2)
                try ACPStartupCleanupPending(process: transport).confirm()
            } catch {
                throw ACPStartupCleanupPending(process: transport)
            }
            throw error
        }

        Thread.detachNewThread { [self] in
            self.pump()
        }
    }

    // MARK: - Handshake & Session Lifecycle

    private static func performInitialize(client: JSONRPCProcess, permissions: RuntimeACPClientPermissions,
                                          terminalAuthentication: Bool) throws -> ACPInitializeResult {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let params: Record = [
            "protocolVersion": ACPProtocol.supportedVersion,
            "clientInfo": [
                "name": "pikachu",
                "title": "Pikachu",
                "version": appVersion
            ],
            "clientCapabilities": [
                "fs": [
                    "readTextFile": permissions.contains(.readFiles),
                    "writeTextFile": permissions.contains(.writeFiles)
                ],
                "terminal": permissions.contains(.terminals),
                "auth": ["terminal": terminalAuthentication],
                "elicitation": ["form": [:] as Record, "url": [:] as Record]
            ]
        ]

        let response: JSONRPCResponse
        do {
            response = try client.request(method: ACPProtocol.Method.initialize, params: params, timeout: defaultControlTimeout)
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }

        if let rpcError = response.error {
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }

        guard let record = response.resultRecord,
              let parsed = ACPInitializeResult.parse(record) else {
            throw RuntimeFailure(.protocolError, String(localized: "ACP 初始化响应格式无效。", bundle: #bundle))
        }

        guard parsed.protocolVersion == ACPProtocol.supportedVersion else {
            throw RuntimeFailure(
                .unsupportedVersion,
                String(localized: "当前构建仅支持 ACP v1（protocolVersion: 1），该 Agent 返回的版本不受支持。", bundle: #bundle)
            )
        }

        return parsed
    }

    func openSession() throws -> RuntimeSession {
        if let expectedID = configuration.expectedSessionID, !expectedID.isEmpty {
            if initializeResult.agentCapabilities.loadSession {
                return try loadSession(id: expectedID)
            }
            return try resumeSession(id: expectedID)
        }
        return try createSession()
    }

    var authentication: RuntimeAgentAuthentication {
        .init(methods: initializeResult.authMethods.compactMap { method in
            switch method.type {
            case "agent": return .init(id: method.id, name: method.name)
            case "terminal" where terminalAuthentication: return .init(id: method.id, name: method.name, kind: .terminal)
            default: return nil
            }
        }, canLogout: initializeResult.agentCapabilities.logout, connectionID: instanceID)
    }

    func chooseAuthenticationMethod(after failure: RuntimeFailure) async throws -> RuntimeAgentAuthentication.Method {
        let advertisedMethods = authentication.methods
        let methods = stateLock.withLock {
            connectionEnded || !client.isRunning ? advertisedMethods.filter { $0.kind == .terminal } : advertisedMethods
        }
        let hasTerminal = methods.contains { $0.kind == .terminal }
        guard !methods.isEmpty else { throw failure }
        let token = "local:authenticate:" + UUID().uuidString
        let request = RuntimeInteraction(
            instanceID: instanceID, requestID: token, kind: .select,
            title: String(localized: "选择 ACP Agent 登录方式", bundle: #bundle),
            options: methods.map(\.name), authenticationMethods: methods
        )
        let (answers, continuation) = AsyncStream.makeStream(of: InteractionResponse.self, bufferingPolicy: .bufferingNewest(1))
        let active = stateLock.withLock {
            guard !closing, !disposed, !connectionEnded || hasTerminal else { return false }
            authenticationInteraction = (request, continuation)
            return true
        }
        guard active else { throw CancellationError() }
        emit(.interaction(request))
        let timeout = Task.detached {
            do { try await Task.sleep(for: .seconds(300)); continuation.finish() }
            catch {}
        }
        let selection = await withTaskCancellationHandler {
            var iterator = answers.makeAsyncIterator()
            return await iterator.next()
        } onCancel: { continuation.finish() }
        timeout.cancel()
        stateLock.withLock { authenticationInteraction = nil }
        guard case .value(let id) = selection, let method = methods.first(where: { $0.id == id }) else {
            emit(.interactionEnded(request.id, .cancelled))
            throw failure
        }
        emit(.interactionEnded(request.id, .answered))
        return method
    }

    func authenticateAgent(methodID: String) async throws {
        try Task.checkCancellation()
        guard isAvailable else {
            throw RuntimeFailure(.connection, String(localized: "连接在启动期间中断。", bundle: #bundle))
        }
        guard authentication.methods.contains(where: { $0.id == methodID && $0.kind == .agent }) else {
            throw RuntimeFailure(.setup, String(localized: "ACP Agent 不支持此登录方式。", bundle: #bundle))
        }
        let response: JSONRPCResponse
        do {
            let rpcID = try client.sendRequest(method: ACPProtocol.Method.authenticate, params: ["methodId": methodID])
            defer { broker.cancelLinkedRequests(rpcID) }
            response = try await client.awaitResponse(id: rpcID, timeout: 300, notifyPeerOnCancel: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }
        if let error = response.error { throw ACPEventMapper.failure(from: Self.toACPError(error)) }
    }

    func terminalAuthenticationLaunch(methodID: String) throws -> RuntimeTerminalAuthenticationLaunch {
        guard terminalAuthentication,
              let method = initializeResult.authMethods.first(where: { $0.id == methodID && $0.type == "terminal" }),
              method.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              method.environment.allSatisfy({ name, value in
                  !name.isEmpty && !name.contains("=") && !name.utf8.contains(0)
                      && !name.hasPrefix("PIKACHU_") && !value.utf8.contains(0)
              }) else {
            throw RuntimeFailure(.setup, String(localized: "ACP 终端登录配置无效。", bundle: #bundle))
        }
        var environment = launchEnvironment
        environment["TERM"] = "xterm-256color"
        environment.merge(method.environment) { _, override in override }
        return .init(name: method.name, executable: configuration.executable, workingDirectory: configuration.workspace,
                     arguments: configuration.arguments + method.arguments, environment: environment,
                     appendedArguments: method.arguments, environmentOverrides: method.environment)
    }

    func reopenAfterTerminalAuthentication(instanceID: UUID? = nil, deferDisconnectEvents: Bool = false) throws -> ACPConnection {
        try Task.checkCancellation()
        if let cleanup = configuration.handoffCleanup {
            guard cleanup.isConfirmed else {
                throw RuntimeFailure(.supervision, String(localized: "终端进程清理未确认。", bundle: #bundle))
            }
            try FileManager.default.removeItem(at: cleanup.directory)
        }
        return try ACPConnection(configuration: configuration, instanceID: instanceID ?? self.instanceID, sink: sink,
                                 precheckedEnvironment: launchEnvironment, terminalAuthentication: terminalAuthentication,
                                 deferDisconnectEvents: deferDisconnectEvents)
    }

    var isAvailable: Bool {
        stateLock.withLock { !closing && !disposed && !connectionEnded } && client.isRunning
    }

    func enableDisconnectEvents() throws {
        let ended = stateLock.withLock {
            guard !closing, !disposed, !connectionEnded else { return true }
            deferDisconnectEvents = false
            return false
        }
        if ended {
            throw RuntimeFailure(.connection, String(localized: "连接在启动期间中断。", bundle: #bundle))
        }
    }

    func respond(_ request: RuntimeInteraction, _ response: InteractionResponse) throws {
        if request.requestID.hasPrefix("local:authenticate:") {
            let continuation = stateLock.withLock { () -> AsyncStream<InteractionResponse>.Continuation? in
                guard authenticationInteraction?.0 == request else { return nil }
                let result = authenticationInteraction?.1
                authenticationInteraction = nil
                return result
            }
            guard let continuation else {
                throw RuntimeFailure(.unsupportedInteraction, String(localized: "该登录请求已结束。", bundle: #bundle))
            }
            continuation.yield(response)
            continuation.finish()
        } else {
            try broker.respond(request, response)
        }
    }

    func cancelInteractions() {
        stateLock.withLock { authenticationInteraction?.1.finish() }
        broker.cancelAll()
    }

    private func createSession() throws -> RuntimeSession {
        let params: Record = [
            "cwd": configuration.workspace.path,
            "mcpServers": [] as [Any]
        ]
        let response: JSONRPCResponse
        do {
            response = try client.request(method: ACPProtocol.Method.sessionNew, params: params, timeout: Self.sessionOpenTimeout)
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }

        if let rpcError = response.error {
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }

        guard let record = response.resultRecord,
              let id = record["sessionId"] as? String, !id.isEmpty else {
            throw RuntimeFailure(.protocolError, String(localized: "ACP Agent 未返回有效的会话标识。", bundle: #bundle))
        }

        let parsedMetadata = ACPSessionMetadata.parse(record)
        stateLock.withLock {
            sessionID = id
            metadata = parsedMetadata
        }

        try applyInitialModeIfNeeded()
        return sessionSnapshot()
    }

    private func loadSession(id expectedID: String) throws -> RuntimeSession {
        guard initializeResult.agentCapabilities.loadSession else {
            throw RuntimeFailure(
                .setup,
                String(localized: "当前 ACP Agent 不支持恢复已有会话（session/load），请新建会话。", bundle: #bundle)
            )
        }

        mapperLock.withLock {
            pendingReplaySessionID = expectedID
            mapper.beginHistoryReplay()
        }

        let params: Record = [
            "sessionId": expectedID,
            "cwd": configuration.workspace.path,
            "mcpServers": [] as [Any]
        ]

        let response: JSONRPCResponse
        do {
            response = try client.request(method: ACPProtocol.Method.sessionLoad, params: params, timeout: Self.sessionOpenTimeout)
        } catch {
            _ = mapperLock.withLock { () -> [HistoryItem] in
                pendingReplaySessionID = nil
                return mapper.finishHistoryReplay()
            }
            throw ACPEventMapper.failure(String(describing: error))
        }

        if let rpcError = response.error {
            _ = mapperLock.withLock { () -> [HistoryItem] in
                pendingReplaySessionID = nil
                return mapper.finishHistoryReplay()
            }
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }

        // Drain any remaining notifications emitted before the session/load response
        // while replayingHistory is still active, so nothing leaks as a live turn.
        let replayedItems: [HistoryItem] = inboundDispatchLock.withLock {
            let batch = client.drainInbound()
            handleInboundMessages(batch.messages)
            return mapperLock.withLock {
                pendingReplaySessionID = nil
                return mapper.finishHistoryReplay()
            }
        }

        let responseMetadata = response.resultRecord.map(ACPSessionMetadata.parse) ?? ACPSessionMetadata()
        stateLock.withLock {
            sessionID = expectedID
            loadedHistory = replayedItems
            if let modes = responseMetadata.modes { metadata.modes = modes }
            if let models = responseMetadata.models { metadata.models = models }
            if !responseMetadata.configOptions.isEmpty { metadata.configOptions = responseMetadata.configOptions }
        }

        if !replayedItems.isEmpty {
            emit(.historyReplayed(replayedItems))
        }

        try applyInitialModeIfNeeded()
        return sessionSnapshot()
    }

    func takeLoadedHistory() -> [HistoryItem]? {
        stateLock.withLock {
            let items = loadedHistory
            loadedHistory = nil
            return items
        }
    }

    private func resumeSession(id: String) throws -> RuntimeSession {
        guard initializeResult.agentCapabilities.sessions.contains("resume") else {
            throw RuntimeFailure(.setup, String(localized: "当前 ACP Agent 不支持恢复已有会话（session/load），请新建会话。", bundle: #bundle))
        }
        let result = try controlRequest(ACPProtocol.Method.sessionResume, params: [
            "sessionId": id, "cwd": configuration.workspace.path, "mcpServers": [] as [Any]
        ], timeout: Self.sessionOpenTimeout)
        stateLock.withLock {
            sessionID = id
            metadata = ACPSessionMetadata.parse(result)
        }
        emit(.notice(String(localized: "已恢复 ACP 会话。历史记录可能不完整。", bundle: #bundle)))
        try applyInitialModeIfNeeded()
        return sessionSnapshot()
    }

    func controlRequest(_ method: String, params: Record? = nil, timeout: Double = defaultControlTimeout) throws -> Record {
        let response = try client.request(method: method, params: params, timeout: timeout)
        if let error = response.error { throw ACPEventMapper.failure(from: Self.toACPError(error)) }
        return response.resultRecord ?? [:]
    }

    private func applyInitialModeIfNeeded() throws {
        guard let targetMode = configuration.initialModeID, !targetMode.isEmpty else { return }
        let current = stateLock.withLock { metadata }
        guard current.currentModeID() != targetMode,
              current.availableModesList().contains(where: { $0.id == targetMode }) else { return }
        _ = try setMode(targetMode)
    }

    // MARK: - Session Snapshot & Configuration

    func sessionSnapshot() -> RuntimeSession {
        let (id, currentMetadata) = stateLock.withLock { (sessionID ?? "", metadata) }
        let models = currentMetadata.availableRuntimeModels(defaultProvider: defaultProvider)
        let thinkingLevels = currentMetadata.availableThinkingLevels()
        let modes = currentMetadata.availableModesList()
        var capabilities: Set<RuntimeCapability> = [.streaming, .tools, .interruption, .usageReporting]
        if initializeResult.agentCapabilities.canRestoreSession {
            capabilities.insert(.sessionResume)
        }
        if initializeResult.agentCapabilities.sessions.contains("delete") {
            capabilities.insert(.sessionDelete)
        }
        if !models.isEmpty || !thinkingLevels.isEmpty {
            capabilities.insert(.modelConfiguration)
        }
        if !modes.isEmpty {
            capabilities.insert(.modeSelection)
        }

        let currentModelID = currentMetadata.currentModelID()
        let displayModel = currentMetadata.currentModelDisplayName(
            fallback: String(localized: "默认模型", bundle: #bundle)
        )
        return RuntimeSession(
            id: id,
            model: displayModel,
            thinking: currentMetadata.currentThinkingLevel(),
            capabilities: capabilities,
            file: nil,
            provider: currentModelID == nil ? nil : defaultProvider,
            modelID: currentModelID,
            runtimeID: configuration.runtimeID,
            modeID: currentMetadata.currentModeID(),
            availableModes: modes.map { RuntimeModeOption(id: $0.id, name: $0.name, description: $0.description) },
            resumable: initializeResult.agentCapabilities.canRestoreSession,
            replaysHistory: initializeResult.agentCapabilities.loadSession
        )
    }

    func configurationOptions() -> RuntimeConfigurationOptions {
        let currentMetadata = stateLock.withLock { metadata }
        return RuntimeConfigurationOptions(
            models: currentMetadata.availableRuntimeModels(defaultProvider: defaultProvider),
            thinkingLevels: currentMetadata.availableThinkingLevels()
        )
    }

    func availableModels() -> [RuntimeModel] {
        stateLock.withLock { metadata.availableRuntimeModels(defaultProvider: defaultProvider) }
    }

    func thinkingLevels() -> [String] {
        stateLock.withLock { metadata.availableThinkingLevels() }
    }

    func usage() -> RuntimeUsage {
        let id = stateLock.withLock { sessionID ?? "" }
        let (snapshot, promptUsage) = mapperLock.withLock { (mapper.latestUsage, latestPromptUsage) }
        return ACPEventMapper.runtimeUsage(sessionID: id, snapshot: snapshot, promptUsage: promptUsage)
    }

    func configure(_ selection: RuntimeSelection) throws -> RuntimeSession {
        try requireIdleForConfiguration()
        let (id, before) = stateLock.withLock { (sessionID, metadata) }
        guard let id, !id.isEmpty else {
            throw RuntimeFailure(.connection, String(localized: "尚未建立 ACP 会话。", bundle: #bundle))
        }

        let modelChanged = before.currentModelID() != selection.modelID && !selection.modelID.isEmpty
        if modelChanged {
            try applyModel(sessionID: id, modelID: selection.modelID)
        }

        if let thinking = selection.thinking, !thinking.isEmpty {
            let current = stateLock.withLock { metadata }
            guard let thoughtOption = current.configOption(category: "thought_level") else {
                throw RuntimeFailure(.setup, String(localized: "当前 ACP Agent 不支持推理强度配置。", bundle: #bundle))
            }
            guard thoughtOption.options.contains(where: { $0.value == thinking }) else {
                throw RuntimeFailure(.setup, String(localized: "该模型不支持所选推理强度，请重新选择。", bundle: #bundle))
            }
            try applyConfigOption(sessionID: id, configID: thoughtOption.id, value: thinking)
        }

        let updated = sessionSnapshot()
        emit(.sessionUpdated(updated))
        return updated
    }

    func setMode(_ modeID: String) throws -> RuntimeSession {
        try requireIdleForConfiguration()
        let (id, current) = stateLock.withLock { (sessionID, metadata) }
        guard let id, !id.isEmpty else {
            throw RuntimeFailure(.connection, String(localized: "尚未建立 ACP 会话。", bundle: #bundle))
        }
        guard !modeID.isEmpty else {
            throw RuntimeFailure(.setup, String(localized: "无效的执行模式。", bundle: #bundle))
        }

        if let modeOption = current.configOption(category: "mode") {
            try applyConfigOption(sessionID: id, configID: modeOption.id, value: modeID)
        } else {
            let response: JSONRPCResponse
            do {
                response = try client.request(
                    method: ACPProtocol.Method.sessionSetMode,
                    params: ["sessionId": id, "modeId": modeID],
                    timeout: Self.defaultControlTimeout
                )
            } catch {
                throw ACPEventMapper.failure(String(describing: error))
            }
            if let rpcError = response.error {
                throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
            }
            stateLock.withLock {
                if metadata.modes != nil {
                    metadata.modes?.currentModeID = modeID
                } else {
                    metadata.modes = ACPModesState(currentModeID: modeID, availableModes: [])
                }
            }
        }

        let updated = sessionSnapshot()
        emit(.sessionUpdated(updated))
        return updated
    }

    private func applyModel(sessionID: String, modelID: String) throws {
        let current = stateLock.withLock { metadata }
        if let modelOption = current.configOption(category: "model") {
            do {
                try applyConfigOption(sessionID: sessionID, configID: modelOption.id, value: modelID)
                return
            } catch let failure as RuntimeFailure where failure.kind != .protocolError {
                // If session/set_config_option failed with methodNotFound, fallback below.
                if current.models == nil { throw failure }
            }
        }

        let response: JSONRPCResponse
        do {
            response = try client.request(
                method: ACPProtocol.Method.sessionSetModel,
                params: ["sessionId": sessionID, "modelId": modelID],
                timeout: Self.defaultControlTimeout
            )
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }
        if let rpcError = response.error {
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }
        stateLock.withLock {
            if metadata.models != nil {
                metadata.models?.currentModelID = modelID
            } else {
                metadata.models = ACPModelsState(currentModelID: modelID, availableModels: [])
            }
        }
    }

    private func applyConfigOption(sessionID: String, configID: String, value: String) throws {
        let response: JSONRPCResponse
        do {
            response = try client.request(
                method: ACPProtocol.Method.sessionSetConfigOption,
                params: ["sessionId": sessionID, "configId": configID, "value": value],
                timeout: Self.defaultControlTimeout
            )
        } catch {
            throw ACPEventMapper.failure(String(describing: error))
        }
        if let rpcError = response.error {
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }
        if let record = response.resultRecord {
            let updatedOptions = ACPConfigOption.parseList(record["configOptions"])
            if !updatedOptions.isEmpty {
                stateLock.withLock {
                    metadata.configOptions = updatedOptions
                    if let modeOption = updatedOptions.first(where: { $0.category == "mode" }) {
                        metadata.modes?.currentModeID = modeOption.currentValue
                    }
                    if let modelOption = updatedOptions.first(where: { $0.category == "model" }) {
                        metadata.models?.currentModelID = modelOption.currentValue
                    }
                }
                return
            }
        }
        // Fallback if server acknowledged without echoing the full configOptions array.
        stateLock.withLock {
            if let index = metadata.configOptions.firstIndex(where: { $0.id == configID }) {
                metadata.configOptions[index].currentValue = value
                if metadata.configOptions[index].category == "mode" {
                    metadata.modes?.currentModeID = value
                } else if metadata.configOptions[index].category == "model" {
                    metadata.models?.currentModelID = value
                }
            }
        }
    }

    private func requireIdleForConfiguration() throws {
        let active: Bool = turnCondition.withLock { activePromptID != nil }
        guard !active else {
            throw RuntimeFailure(.setup, String(localized: "运行期间不能修改模型配置。", bundle: #bundle))
        }
    }

    // MARK: - Prompt Execution & Cancellation

    func send(_ prompt: UserPrompt) throws -> PromptDisposition {
        let id = stateLock.withLock { sessionID }
        guard let id, !id.isEmpty else {
            throw RuntimeFailure(.connection, String(localized: "尚未建立 ACP 会话。", bundle: #bundle))
        }

        let blocks = Self.buildPromptBlocks(
            prompt: prompt,
            supportsImage: initializeResult.agentCapabilities.promptCapabilities.image
        )
        let promptID = prompt.id
        let isHandoff = prompt.handoffContext != nil
        let requestID = try turnCondition.withLock {
            guard activePromptID == nil else {
                throw RuntimeFailure(.setup, String(localized: "当前 ACP 会话正在运行，不支持并发排队发送。", bundle: #bundle))
            }
            let requestID: JSONRPCID
            do {
                requestID = try client.sendRequest(method: ACPProtocol.Method.sessionPrompt,
                                                   params: ["sessionId": id, "prompt": blocks])
            } catch {
                throw ACPEventMapper.failure(String(describing: error))
            }
            activePromptID = requestID
            unconfirmedPromptID = isHandoff ? nil : promptID
            emit(.phase(.running))
            emit(.runStarted)
            return requestID
        }

        client.onResponse(id: requestID) { [weak self] result in
            self?.handlePromptResponse(requestID: requestID, promptID: promptID, isHandoff: isHandoff, result: result)
        }

        return isHandoff ? .awaitingAcceptance : .started
    }

    private func takeUnconfirmedPrompt(requestID: JSONRPCID? = nil) -> UUID? {
        turnCondition.withLock {
            guard requestID == nil || activePromptID == requestID else { return nil }
            defer { unconfirmedPromptID = nil }
            return unconfirmedPromptID
        }
    }

    static func buildPromptBlocks(prompt: UserPrompt, supportsImage: Bool) -> [Record] {
        var blocks: [Record] = []
        var fallbackPaths: [String] = []
        var imageBlocks: [Record] = []

        for file in prompt.files {
            if supportsImage, let imageBlock = encodeImageBlock(file) {
                imageBlocks.append(imageBlock)
            } else {
                fallbackPaths.append(file.path.debugDescription)
            }
        }

        let trimmedText = prompt.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        var textBody = trimmedText
        if !fallbackPaths.isEmpty {
            let prefix = textBody.isEmpty ? "请查看以下文件。" : textBody
            textBody = "\(prefix)\n\n本地文件引用（按需读取）\n\(fallbackPaths.joined(separator: "\n"))"
        } else if textBody.isEmpty && !imageBlocks.isEmpty {
            textBody = "请查看以下图片。"
        }

        if !textBody.isEmpty {
            blocks.append(["type": "text", "text": textBody])
        }
        blocks.append(contentsOf: imageBlocks)
        return blocks
    }

    static func encodeImageBlock(_ url: URL) -> Record? {
        guard let mimeType = imageMIMEType(for: url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0, fileSize <= maximumImageAttachmentBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maximumImageAttachmentBytes else {
            return nil
        }
        return [
            "type": "image",
            "mimeType": mimeType,
            "data": data.base64EncodedString()
        ]
    }

    private static func imageMIMEType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private func handlePromptResponse(requestID: JSONRPCID, promptID: UUID, isHandoff: Bool, result: Result<JSONRPCResponse, Error>) {
        // Serialize with the inbound pump so all session/update frames emitted before
        // the prompt response are processed before turn settlement.
        inboundDispatchLock.lock()
        defer { inboundDispatchLock.unlock() }
        let trailing = client.drainInbound()
        handleInboundMessages(trailing.messages)

        let shouldEmit: Bool = stateLock.withLock { !closing && !disposed }
        defer {
            turnCondition.withLock {
                if activePromptID == requestID {
                    activePromptID = nil
                    unconfirmedPromptID = nil
                }
                turnCondition.broadcast()
            }
        }
        guard shouldEmit else { return }

        broker.cancelAll(reason: .expired, send: false)

        func reportAcceptance(_ acceptance: RuntimePromptAcceptance) {
            if isHandoff { emit(.promptAcceptance(promptID, acceptance)) }
        }

        switch result {
        case .failure(let error):
            reportAcceptance(.unknown)
            let failure = (error as? RuntimeFailure) ?? ACPEventMapper.failure(String(describing: error))
            let events = mapperLock.withLock { mapper.finishTurnWithError(failure) }
            for event in events { emit(event) }

        case .success(let response):
            if let rpcError = response.error {
                let rejected = [-32600, -32601, -32602].contains(rpcError.code)
                reportAcceptance(rejected ? .rejected : .unknown)
                if rejected, let ordinaryPromptID = takeUnconfirmedPrompt(requestID: requestID) {
                    emit(.promptAcceptance(ordinaryPromptID, .rejected))
                }
                let error = Self.toACPError(rpcError)
                // Keep the primary error when a provider echoes the rejected request in its message.
                let structuredLength = RuntimeFailure.promptLengthRejection(error.dataCode)
                let lengthMessage = error.messageBeforeExplicitAuthenticationReason.map(String.init) ?? error.message
                let messageLength = RuntimeFailure.promptLengthRejection(lengthMessage)
                let hintedLength = error.isAuthRequired ? nil : RuntimeFailure.promptLengthRejection(error.authHint)
                let lengthRejection = error.hasAuthenticationCode ? nil : (structuredLength ?? messageLength ?? hintedLength)
                let failure: RuntimeFailure
                if let lengthRejection {
                    failure = rejected ? lengthRejection : .init(.outcomeUnknown, String(localized:
                        "运行时报告请求超出输入长度限制。请先核实送达，再缩短内容。", bundle: #bundle))
                } else {
                    failure = ACPEventMapper.failure(from: error)
                }
                let events = mapperLock.withLock { mapper.finishTurnWithError(failure) }
                for event in events { emit(event) }
                return
            }

            guard let record = response.resultRecord,
                  let parsed = ACPPromptResponse.parse(record) else {
                reportAcceptance(.unknown)
                let failure = RuntimeFailure(.protocolError, String(localized: "ACP 回合结束响应格式无效。", bundle: #bundle))
                let events = mapperLock.withLock { mapper.finishTurnWithError(failure) }
                for event in events { emit(event) }
                return
            }

            reportAcceptance(.accepted)
            if parsed.stopReason != .cancelled, let ordinaryPromptID = takeUnconfirmedPrompt(requestID: requestID) {
                emit(.promptConfirmed(ordinaryPromptID))
            }
            if let usage = parsed.usage {
                mapperLock.withLock { latestPromptUsage = usage }
                emit(.usageUpdated(self.usage()))
            }

            let events = mapperLock.withLock { mapper.finishTurn(stopReason: parsed.stopReason) }
            for event in events { emit(event) }
        }
    }

    func stop() throws {
        let id = stateLock.withLock { sessionID }
        emit(.phase(.stopping))
        broker.pause()

        do {
            if let id, !id.isEmpty {
                try client.sendNotification(method: ACPProtocol.Method.sessionCancel, params: ["sessionId": id])
            }
            broker.cancelAll(reason: .cancelled, send: true)

            let deadline = Date().addingTimeInterval(max(0.1, configuration.cancelTimeoutSeconds))
            let settled: Bool = turnCondition.withLock {
                while activePromptID != nil && Date() < deadline {
                    if stateLock.withLock({ closing || disposed }) {
                        return false
                    }
                    turnCondition.wait(until: deadline)
                }
                return activePromptID == nil
            }

            guard settled else {
                throw RuntimeFailure(.outcomeUnknown, String(localized: "任务尚未确认停止，请强制结束受管进程。", bundle: #bundle))
            }
            broker.resume()
        } catch let failure as RuntimeFailure {
            broker.cancelAll(reason: .cancelled, send: true)
            throw failure
        } catch {
            broker.cancelAll(reason: .cancelled, send: true)
            throw ACPEventMapper.failure(String(describing: error))
        }
    }

    func close(force: Bool, notify: Bool = true) throws {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !stateLock.withLock({ disposed }) else { return }
        broker.pause()
        broker.cancelAll(reason: .disconnected, send: !force)
        stateLock.withLock {
            closing = true
            authenticationInteraction?.1.finish()
        }
        turnCondition.withLock { turnCondition.broadcast() }
        if force {
            client.crash()
        } else if initializeResult.agentCapabilities.sessions.contains("close"),
                  let id = stateLock.withLock({ sessionID }) {
            _ = try? controlRequest(ACPProtocol.Method.sessionClose, params: ["sessionId": id], timeout: 2)
        }
        let childTerminalsClosed = clientServices.close()
        do {
            try client.close()
            if client.supervisionStatusURL != nil {
                guard client.supervisionStatus["state"] as? String == "clean" else {
                    throw RuntimeFailure(.supervision, String(localized: "工具进程清理未确认。", bundle: #bundle))
                }
            }
            guard childTerminalsClosed, configuration.handoffCleanup?.isConfirmed != false else {
                throw RuntimeFailure(.supervision, String(localized: "终端进程清理未确认。", bundle: #bundle))
            }
            stateLock.withLock { disposed = true }
            turnCondition.withLock {
                activePromptID = nil
                unconfirmedPromptID = nil
                turnCondition.broadcast()
            }
            if notify { emit(.disconnected(cleanupConfirmed: true)) }
        } catch let failure as RuntimeFailure {
            stateLock.withLock { closing = false }
            throw failure
        } catch {
            stateLock.withLock { closing = false }
            throw ACPEventMapper.failure(String(describing: error))
        }
    }

    // MARK: - Inbound Pump & Dispatch

    private func emit(_ event: AgentEvent) {
        sink.send(.init(instanceID: instanceID, event: event))
    }

    private func pump() {
        while !stateLock.withLock({ disposed }) {
            do {
                try broker.expire()
            } catch {
                emit(.failure(ACPEventMapper.failure(String(describing: error))))
            }

            let observation: (messages: [JSONRPCInboundMessage], ended: Bool, failure: String?) = inboundDispatchLock.withLock {
                let batch = client.waitInbound(timeout: 0.02)
                handleInboundMessages(batch.messages)
                return batch
            }

            if observation.ended || observation.failure != nil || !client.isRunning {
                let canUseTerminal = authentication.methods.contains { $0.kind == .terminal }
                let shouldNotify = stateLock.withLock { () -> Bool? in
                    guard !closing, !disposed else { return nil }
                    connectionEnded = true
                    if !canUseTerminal { authenticationInteraction?.1.finish() }
                    return !deferDisconnectEvents
                }
                guard let shouldNotify else { continue }
                let until = Date().addingTimeInterval(4)
                while client.isRunning && Date() < until {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let agentClean: Bool
                if client.supervisionStatusURL != nil {
                    agentClean = client.supervisionStatus["state"] as? String == "clean" && !client.isRunning
                } else {
                    agentClean = !client.isRunning
                }
                broker.cancelAll(reason: .disconnected, send: false)
                let terminalsClean = clientServices.close()
                let clean = agentClean && terminalsClean && configuration.handoffCleanup?.isConfirmed != false
                turnCondition.withLock {
                    activePromptID = nil
                    unconfirmedPromptID = nil
                    turnCondition.broadcast()
                }
                if shouldNotify {
                    emit(.failure(.init(
                        observation.failure == nil ? .connection : .protocolError,
                        clean
                            ? String(localized: "ACP 运行时连接已中断，受管进程已清理。不会自动重发任务。", bundle: #bundle)
                            : String(localized: "ACP 运行时连接已中断，进程清理尚未确认。", bundle: #bundle)
                    )))
                    emit(.disconnected(cleanupConfirmed: clean))
                }
                return
            }
        }
    }

    private func handleInboundMessages(_ messages: [JSONRPCInboundMessage]) {
        for message in messages {
            switch message {
            case .notification(let notification):
                handleNotification(notification)
            case .request(let request):
                handleAgentRequest(request)
            }
        }
    }

    private func handleNotification(_ notification: JSONRPCNotification) {
        switch notification.method {
        case ACPProtocol.Method.cancelRequest:
            if let id = JSONRPCID(jsonValue: notification.params["requestId"]) {
                broker.cancel(id)
                clientServices.cancel(id)
            }
            return
        case ACPProtocol.Method.elicitationComplete:
            if let id = notification.params["elicitationId"] as? String { broker.completeElicitation(id) }
            return
        default: break
        }
        guard notification.method == ACPProtocol.Method.sessionUpdate,
              let update = notification.params["update"] as? Record else {
            return
        }

        let targetSessionID = notification.params["sessionId"] as? String
        let activeID = stateLock.withLock { sessionID }
        let replayID = mapperLock.withLock { pendingReplaySessionID }
        if let targetSessionID, !targetSessionID.isEmpty {
            let expected = replayID ?? activeID
            if let expected, !expected.isEmpty, !targetSessionID.utf8.elementsEqual(expected.utf8) {
                return
            }
        }

        let mapped: (events: [AgentEvent], metadata: ACPEventMapper.MetadataUpdate, replaying: Bool) = mapperLock.withLock {
            let result = mapper.mapSessionUpdate(update)
            return (result.events, result.metadata, mapper.replayingHistory)
        }
        if !mapped.replaying, let activeID, targetSessionID?.utf8.elementsEqual(activeID.utf8) == true {
            // Output from the active prompt proves receipt. Configuration and usage
            // notifications can arrive outside a prompt and do not prove receipt.
            let kind = update["sessionUpdate"] as? String
            let hasTurnOutput = ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"]
                .contains(kind ?? "") && !mapped.events.isEmpty
            let echoedInput = kind == "user_message_chunk" && !ACPJSON.textFromContentBlock(update["content"]).isEmpty
            if hasTurnOutput || echoedInput, let promptID = takeUnconfirmedPrompt() {
                emit(.promptConfirmed(promptID))
            }
            broker.receiveToolUpdate(update, sessionID: activeID)
        }

        var sessionChanged = false
        if let modeID = mapped.metadata.currentModeID {
            stateLock.withLock {
                if metadata.modes != nil {
                    metadata.modes?.currentModeID = modeID
                } else {
                    metadata.modes = ACPModesState(currentModeID: modeID, availableModes: [])
                }
                if let index = metadata.configOptions.firstIndex(where: { $0.category == "mode" }) {
                    metadata.configOptions[index].currentValue = modeID
                }
            }
            sessionChanged = true
        }
        if let configOptions = mapped.metadata.configOptions {
            stateLock.withLock {
                metadata.configOptions = configOptions
                if let modeOption = configOptions.first(where: { $0.category == "mode" }) {
                    metadata.modes?.currentModeID = modeOption.currentValue
                }
                if let modelOption = configOptions.first(where: { $0.category == "model" }) {
                    metadata.models?.currentModelID = modelOption.currentValue
                }
            }
            sessionChanged = true
        }

        for event in mapped.events {
            emit(event)
        }

        if !mapped.replaying {
            if sessionChanged && activeID != nil {
                emit(.sessionUpdated(sessionSnapshot()))
            }
            if mapped.metadata.usage != nil && activeID != nil {
                emit(.usageUpdated(usage()))
            }
        }
    }

    private func handleAgentRequest(_ request: JSONRPCRequest) {
        switch request.method {
        case ACPProtocol.Method.elicitationCreate:
            let requestSession = request.params["sessionId"] as? String
            let parentID = JSONRPCID(jsonValue: request.params["requestId"])
            let validScope: Bool
            if let requestSession {
                validScope = parentID == nil && requestSession == stateLock.withLock { sessionID }
            } else {
                validScope = parentID.map(client.hasPendingRequest) ?? false
            }
            guard validScope, let message = request.params["message"] as? String,
                  message.utf8.count <= ACPInteractionBroker.maximumMessageBytes,
                  let elicitation = ACPElicitation(request.params) else {
                try? client.sendErrorResponse(id: request.id, code: ACPProtocol.ErrorCode.invalidParams,
                                              message: "Invalid ACP elicitation")
                return
            }
            try? broker.acceptElicitation(request, elicitation: elicitation, message: message, parentID: parentID)
        case ACPProtocol.Method.sessionRequestPermission:
            guard let id = request.params["sessionId"] as? String,
                  let activeID = stateLock.withLock({ sessionID }),
                  id.utf8.elementsEqual(activeID.utf8) else {
                try? client.sendErrorResponse(id: request.id, code: ACPProtocol.ErrorCode.resourceNotFound,
                                              message: "Unknown session")
                return
            }
            do {
                try broker.accept(request, workingDirectory: configuration.workspace.path)
                if let promptID = takeUnconfirmedPrompt() { emit(.promptConfirmed(promptID)) }
            } catch {
                emit(.failure((error as? RuntimeFailure) ?? ACPEventMapper.failure(String(describing: error))))
                client.crash()
            }
        default:
            clientServices.handle(request, sessionID: stateLock.withLock { sessionID }, broker: broker)
        }
    }

    static func toACPError(_ error: JSONRPCError) -> ACPJSONRPCError {
        let dataRecord = error.dataObject as? Record
        return ACPJSONRPCError(
            code: error.code,
            message: error.message,
            dataCode: dataRecord?["code"] as? String,
            authHint: dataRecord?["hint"] as? String ?? dataRecord?["details"] as? String
        )
    }
}
