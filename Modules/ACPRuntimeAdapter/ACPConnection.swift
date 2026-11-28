import Foundation
import Darwin
import AgentRuntimeCore
import ProcessSupervision

struct ACPStartupCleanupPending: Error, Sendable {
    let process: JSONRPCProcess

    var failure: RuntimeFailure {
        .init(.supervision, String(localized: "工具进程清理未确认。", bundle: #bundle))
    }

    func confirm() throws {
        // Foundation can report the process as running briefly after the kernel marks it exited.
        let pid = process.process.processIdentifier
        let exited = !process.isRunning || ProcessIdentity.read(pid)?.live == false
            || (pid > 0 && Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        guard exited else { throw failure }
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
    let sharedHost: ACPSharedHost?
    let isControl: Bool

    private let stateLock = NSLock()
    private let closeLock = NSLock()
    private let mapperLock = NSLock()
    private let inboundDispatchLock = NSLock()
    private let turnCondition = NSCondition()

    private var mapper = ACPEventMapper()
    private var metadata = ACPSessionMetadata()
    private var configurationRevision = 0
    private var configOptionsReceiveOrder = 0
    private var reportedMode: (id: String, receiveOrder: Int)?
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
    private var sharedDisconnectConfirmed = false
    private var sharedSessionMayBeOpen = false
    private var sharedSessionClosed = false

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
        deferDisconnectEvents: Bool = false,
        startPump: Bool = true
    ) throws {
        self.configuration = config
        self.instanceID = instanceID
        self.sink = sink
        self.deferDisconnectEvents = deferDisconnectEvents
        self.sharedHost = nil
        self.isControl = false
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

        if startPump {
            Thread.detachNewThread { [self] in self.pump() }
        }
    }

    init(configuration: ACPConfiguration, instanceID: UUID, sink: RuntimeEventChannel,
         host: ACPSharedHost, deferDisconnectEvents: Bool, isControl: Bool = false) throws {
        self.configuration = configuration
        self.instanceID = instanceID
        self.sink = sink
        self.deferDisconnectEvents = deferDisconnectEvents
        self.sharedHost = host
        self.isControl = isControl
        let root = host.root
        client = root.client
        initializeResult = root.initializeResult
        launchEnvironment = root.launchEnvironment
        terminalAuthentication = root.terminalAuthentication
        let services = ACPClientServices(client: root.client, configuration: configuration,
                                         advertisedPermissions: root.clientServices.advertisedPermissions)
        clientServices = services
        broker = ACPInteractionBroker(instanceID: instanceID, sendResponse: { id, payload in
            try services.respondToApproval(id, payload: payload)
        }, emit: { event in
            sink.send(.init(instanceID: instanceID, event: event))
        })
        try host.attach(self)
    }

    // MARK: - Handshake & Session Lifecycle

    private static func performInitialize(client: JSONRPCProcess, permissions: RuntimeACPClientPermissions,
                                          terminalAuthentication: Bool) throws -> ACPInitializeResult {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let params: Record = [
            "protocolVersion": ACPProtocol.supportedVersion,
            "clientInfo": [
                "name": "zivvi",
                "title": "Zivvi",
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
        if let sharedHost {
            return try sharedHost.open(self, isNew: configuration.expectedSessionID?.isEmpty != false) {
                try self.openConfiguredSession()
            }
        }
        return try openConfiguredSession()
    }

    private func openConfiguredSession() throws -> RuntimeSession {
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
            let rpcID = try sendLinkedRequest(ACPProtocol.Method.authenticate, params: ["methodId": methodID])
            defer { finishLinkedRequest(rpcID) }
            response = try await client.awaitResponse(id: rpcID, timeout: 300, notifyPeerOnCancel: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RuntimeFailure {
            throw failure
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
                      && !name.hasPrefix("ZIVVI_") && !value.utf8.contains(0)
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
        stateLock.withLock { !closing && !disposed && !connectionEnded } && client.isRunning && !client.isTransportEnding
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
        } else if let sharedHost {
            try sharedHost.withInboundDispatch { try broker.respond(request, response) }
        } else {
            try inboundDispatchLock.withLock { try broker.respond(request, response) }
        }
    }

    func cancelInteractions() {
        stateLock.withLock { authenticationInteraction?.1.finish() }
        broker.cancelAll()
    }

    func sendLinkedRequest(_ method: String, params: Record?) throws -> JSONRPCID {
        if let sharedHost { return try sharedHost.sendLinkedRequest(from: self, method: method, params: params) }
        return try client.sendRequest(method: method, params: params)
    }

    func finishLinkedRequest(_ id: JSONRPCID) {
        sharedHost?.finishLinkedRequest(id)
        broker.cancelLinkedRequests(id)
    }

    private func sessionSetupRequest(_ method: String, params: Record) throws -> JSONRPCResponse {
        let request = try sendLinkedRequest(method, params: params)
        defer { finishLinkedRequest(request) }
        return try client.waitResponse(id: request, timeout: Self.sessionOpenTimeout)
    }

    private func createSession() throws -> RuntimeSession {
        let params: Record = [
            "cwd": configuration.workspace.path,
            "mcpServers": [] as [Any]
        ]
        let response: JSONRPCResponse
        do {
            response = try sessionSetupRequest(ACPProtocol.Method.sessionNew, params: params)
        } catch let failure as RuntimeFailure where failure.kind == .setup {
            throw failure
        } catch {
            sharedHost?.markUnknownCreation(self)
            throw ACPEventMapper.failure(String(describing: error))
        }

        if let rpcError = response.error {
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }

        guard let record = response.resultRecord,
              let id = record["sessionId"] as? String, !id.isEmpty else {
            sharedHost?.markUnknownCreation(self)
            throw RuntimeFailure(.protocolError, String(localized: "ACP Agent 未返回有效的会话标识。", bundle: #bundle))
        }

        updateConfiguration {
            sessionID = id
            mergeSessionMetadata(response)
        }
        try sharedHost?.bind(self, sessionID: id, newlyCreated: true)
        sharedSessionMayBeOpen = sharedHost != nil

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
        if let sharedHost {
            try sharedHost.bind(self, sessionID: expectedID)
            stateLock.withLock { sessionID = expectedID }
            sharedSessionMayBeOpen = true
        }

        let params: Record = [
            "sessionId": expectedID,
            "cwd": configuration.workspace.path,
            "mcpServers": [] as [Any]
        ]

        let response: JSONRPCResponse
        do {
            response = try sessionSetupRequest(ACPProtocol.Method.sessionLoad, params: params)
        } catch {
            _ = mapperLock.withLock { () -> [HistoryItem] in
                pendingReplaySessionID = nil
                return mapper.finishHistoryReplay()
            }
            if let failure = error as? RuntimeFailure, failure.kind == .setup {
                sharedSessionMayBeOpen = false
                throw failure
            }
            throw ACPEventMapper.failure(String(describing: error))
        }

        if let rpcError = response.error {
            sharedSessionMayBeOpen = false
            _ = mapperLock.withLock { () -> [HistoryItem] in
                pendingReplaySessionID = nil
                return mapper.finishHistoryReplay()
            }
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }

        // Drain any remaining notifications emitted before the session/load response
        // while replayingHistory is still active, so nothing leaks as a live turn.
        let finishReplay = {
            self.mapperLock.withLock {
                self.pendingReplaySessionID = nil
                return self.mapper.finishHistoryReplay()
            }
        }
        let replayedItems: [HistoryItem]
        if let sharedHost {
            replayedItems = sharedHost.drainInbound(then: finishReplay)
        } else {
            replayedItems = inboundDispatchLock.withLock {
                handleInboundMessages(client.drainInbound().messages)
                return finishReplay()
            }
        }

        updateConfiguration {
            sessionID = expectedID
            loadedHistory = replayedItems
            mergeSessionMetadata(response)
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
        if let sharedHost {
            try sharedHost.bind(self, sessionID: id)
            stateLock.withLock { sessionID = id }
            sharedSessionMayBeOpen = true
        }
        let response: JSONRPCResponse
        do {
            response = try sessionSetupRequest(ACPProtocol.Method.sessionResume, params: [
                "sessionId": id, "cwd": configuration.workspace.path, "mcpServers": [] as [Any]
            ])
        } catch let failure as RuntimeFailure where failure.kind == .setup {
            sharedSessionMayBeOpen = false
            throw failure
        }
        if let rpcError = response.error {
            sharedSessionMayBeOpen = false
            throw ACPEventMapper.failure(from: Self.toACPError(rpcError))
        }
        updateConfiguration {
            sessionID = id
            mergeSessionMetadata(response)
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

    private func updateConfiguration(_ update: () -> Void) {
        stateLock.withLock {
            let previous = metadata
            update()
            if metadata != previous { configurationRevision += 1 }
        }
    }

    // The following metadata helpers run inside updateConfiguration.
    private func mergeSessionMetadata(_ response: JSONRPCResponse) {
        guard let record = response.resultRecord else { return }
        if var modes = ACPModesState.parse(record["modes"] as? Record) {
            if let reportedMode, reportedMode.receiveOrder > response.receiveOrder { modes.currentModeID = reportedMode.id }
            metadata.modes = modes
        }
        if let models = ACPModelsState.parse(record["models"] as? Record) { metadata.models = models }
        if let options = ACPConfigOption.parseList(record["configOptions"]) {
            replaceConfigOptions(options, receiveOrder: response.receiveOrder)
        }
    }

    private func replaceConfigOptions(_ options: [ACPConfigOption], receiveOrder: Int) {
        guard receiveOrder >= configOptionsReceiveOrder else { return }
        configOptionsReceiveOrder = receiveOrder
        metadata.replaceConfigOptions(options)
        if let reportedMode, reportedMode.receiveOrder > receiveOrder,
           let index = options.firstIndex(where: { $0.category == "mode" }) {
            metadata.updateConfigValue(reportedMode.id, at: index)
        }
    }

    private func reportMode(_ id: String, receiveOrder: Int) {
        guard receiveOrder >= (reportedMode?.receiveOrder ?? 0) else { return }
        reportedMode = (id, receiveOrder)
        if let modes = metadata.modes {
            metadata.modes = ACPModesState(currentModeID: id, availableModes: modes.availableModes)
        } else {
            metadata.modes = ACPModesState(currentModeID: id, availableModes: [])
        }
        if receiveOrder >= configOptionsReceiveOrder,
           let index = metadata.configOptions.firstIndex(where: { $0.category == "mode" }) {
            metadata.updateConfigValue(id, at: index)
        }
    }

    func sessionSnapshot() -> RuntimeSession {
        let (id, currentMetadata, revision) = stateLock.withLock { (sessionID ?? "", metadata, configurationRevision) }
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
            replaysHistory: initializeResult.agentCapabilities.loadSession,
            configurationRevision: revision
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
            guard !current.hasConfigOptions else {
                throw RuntimeFailure(.setup, String(localized: "无效的执行模式。", bundle: #bundle))
            }
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
            updateConfiguration { reportMode(modeID, receiveOrder: response.receiveOrder) }
        }

        let updated = sessionSnapshot()
        emit(.sessionUpdated(updated))
        return updated
    }

    private func applyModel(sessionID: String, modelID: String) throws {
        let current = stateLock.withLock { metadata }
        guard !current.hasConfigOptions || !current.configOptions.isEmpty else {
            throw RuntimeFailure(.setup, String(localized: "当前 ACP Agent 不支持模型配置。", bundle: #bundle))
        }
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
        updateConfiguration {
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
        if let options = ACPConfigOption.parseList(response.resultRecord?["configOptions"]) {
            updateConfiguration { replaceConfigOptions(options, receiveOrder: response.receiveOrder) }
            return
        }
        // Fallback if server acknowledged without echoing the full configOptions array.
        let acknowledge = {
            self.updateConfiguration {
                guard response.receiveOrder >= self.configOptionsReceiveOrder,
                      let index = self.metadata.configOptions.firstIndex(where: { $0.id == configID }) else { return }
                if self.metadata.configOptions[index].category == "mode",
                   let mode = self.reportedMode, mode.receiveOrder > response.receiveOrder { return }
                self.metadata.updateConfigValue(value, at: index)
            }
        }
        if let sharedHost {
            sharedHost.drainInbound(then: acknowledge)
        } else {
            inboundDispatchLock.withLock {
                handleInboundMessages(client.drainInbound().messages)
                acknowledge()
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
        let requestID = try issuePrompt(sessionID: id, blocks: blocks, promptID: promptID, isHandoff: isHandoff)

        client.onResponse(id: requestID) { [weak self] result in
            self?.handlePromptResponse(requestID: requestID, promptID: promptID, isHandoff: isHandoff, result: result)
        }

        return isHandoff ? .awaitingAcceptance : .started
    }

    private func issuePrompt(sessionID: String, blocks: [Record], promptID: UUID, isHandoff: Bool) throws -> JSONRPCID {
        try turnCondition.withLock {
            guard activePromptID == nil else {
                throw RuntimeFailure(.setup, String(localized: "当前 ACP 会话正在运行，不支持并发排队发送。", bundle: #bundle))
            }
            let requestID: JSONRPCID
            do {
                guard stateLock.withLock({ !closing && !disposed && !connectionEnded }) else {
                    throw RuntimeFailure(.setup, String(localized: "尚未建立 ACP 会话。", bundle: #bundle))
                }
                requestID = try client.sendRequest(method: ACPProtocol.Method.sessionPrompt,
                                                   params: ["sessionId": sessionID, "prompt": blocks],
                                                   writeGate: sharedHost.map { host in { try host.admitRequest($0) } })
            } catch let failure as RuntimeFailure {
                throw failure
            } catch {
                throw ACPEventMapper.failure(String(describing: error))
            }
            activePromptID = requestID
            unconfirmedPromptID = isHandoff ? nil : promptID
            emit(.phase(.running))
            emit(.runStarted)
            return requestID
        }
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
        guard let mimeType = RuntimeACPInlineImage.mimeType(for: url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0, fileSize <= ACPJSON.maximumImageBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= ACPJSON.maximumImageBytes else {
            return nil
        }
        return [
            "type": "image",
            "mimeType": mimeType,
            "data": data.base64EncodedString()
        ]
    }

    private func handlePromptResponse(requestID: JSONRPCID, promptID: UUID, isHandoff: Bool, result: Result<JSONRPCResponse, Error>) {
        // Serialize with the inbound pump so all session/update frames emitted before
        // the prompt response are processed before turn settlement.
        if let sharedHost {
            sharedHost.drainInbound {
                settlePrompt(requestID: requestID, promptID: promptID, isHandoff: isHandoff, result: result)
            }
        } else {
            inboundDispatchLock.withLock {
                handleInboundMessages(client.drainInbound().messages)
                settlePrompt(requestID: requestID, promptID: promptID, isHandoff: isHandoff, result: result)
            }
        }
    }

    func ownsPromptRequest(_ id: JSONRPCID) -> Bool {
        turnCondition.withLock { activePromptID == id }
    }

    private func settlePrompt(requestID: JSONRPCID, promptID: UUID, isHandoff: Bool, result: Result<JSONRPCResponse, Error>) {
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

        broker.cancelAll(reason: .cancelled, send: false)

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
        if let sharedHost {
            try closeShared(on: sharedHost, force: force, notify: notify)
            return
        }
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

    private func closeShared(on host: ACPSharedHost, force: Bool, notify: Bool) throws {
        stateLock.withLock {
            closing = true
            authenticationInteraction?.1.finish()
        }
        defer { stateLock.withLock { closing = false } }
        broker.pause()
        broker.cancelAll(reason: .disconnected, send: !force && host.isRunning)
        if force {
            try host.shutdown(force: true)
        } else if host.hasUnknownCreation(for: self) {
            throw RuntimeFailure(.outcomeUnknown, String(localized: "ACP 会话创建结果待核实。", bundle: #bundle))
        } else if sharedSessionMayBeOpen, !sharedSessionClosed, let id = stateLock.withLock({ sessionID }) {
            try releaseSharedSession(id, on: host)
        } else if !isControl, !host.isRunning || client.isTransportEnding {
            try confirmEndedHost(host)
        }
        guard clientServices.close() else {
            throw RuntimeFailure(.supervision, String(localized: "终端进程清理未确认。", bundle: #bundle))
        }
        if sharedSessionClosed || !sharedSessionMayBeOpen { try configuration.handoffCleanup?.recordSharedSessionClose() }
        guard configuration.handoffCleanup?.isConfirmed != false else {
            throw RuntimeFailure(.supervision, String(localized: "终端进程清理未确认。", bundle: #bundle))
        }
        stateLock.withLock { disposed = true }
        turnCondition.withLock {
            activePromptID = nil
            unconfirmedPromptID = nil
            turnCondition.broadcast()
        }
        host.detach(self)
        if notify { emit(.disconnected(cleanupConfirmed: true)) }
    }

    private func releaseSharedSession(_ id: String, on host: ACPSharedHost) throws {
        guard host.isRunning, !client.isTransportEnding else { return try confirmEndedHost(host) }
        let response: JSONRPCResponse
        do {
            response = try client.request(method: ACPProtocol.Method.sessionClose, params: ["sessionId": id], timeout: 5)
        } catch {
            guard client.isTransportEnding || !host.isRunning else { throw error }
            return try confirmEndedHost(host)
        }
        if let error = response.error, error.code != ACPProtocol.ErrorCode.resourceNotFound {
            if error.code == -32601 { host.markIncompatible() }
            throw ACPEventMapper.failure(from: Self.toACPError(error))
        }
        try Self.requireSessionMutationResult(response)
        sharedSessionClosed = true
    }

    private func confirmEndedHost(_ host: ACPSharedHost) throws {
        // EOF can reach a response waiter before the host's pump has finished cleanup.
        // The host rechecks all endpoints together. This close also checks its own terminals below.
        try? host.shutdown(force: false)
        try host.confirmCleanup()
    }

    static func requireSessionMutationResult(_ response: JSONRPCResponse) throws {
        if response.error?.code == ACPProtocol.ErrorCode.resourceNotFound { return }
        guard let result = response.resultRecord, result.keys.allSatisfy({ $0 == "_meta" }),
              result["_meta"].map({ $0 is Record || $0 is NSNull }) ?? true else {
            throw RuntimeFailure(.protocolError, String(localized: "ACP Agent 响应格式无效。", bundle: #bundle))
        }
    }

    func sharedConnectionEnded(clean: Bool, failed: Bool) -> Bool {
        let first = stateLock.withLock {
            let first = !connectionEnded && !disposed
            connectionEnded = true
            if first { authenticationInteraction?.1.finish() }
            return first
        }
        if first {
            broker.cancelAll(reason: .disconnected, send: false)
            turnCondition.withLock {
                activePromptID = nil
                unconfirmedPromptID = nil
                turnCondition.broadcast()
            }
        }
        let terminalsClean = clientServices.close()
        let confirmed = clean && terminalsClean && configuration.handoffCleanup?.isConfirmed != false
        let notification = stateLock.withLock { () -> (failure: Bool, disconnected: Bool) in
            let becameConfirmed = confirmed && !sharedDisconnectConfirmed
            sharedDisconnectConfirmed = confirmed
            guard !disposed, !deferDisconnectEvents else { return (false, false) }
            return (first && !closing && (!isControl || failed || !confirmed), first || becameConfirmed)
        }
        if notification.failure {
            emit(.failure(.init(failed ? .protocolError : .connection, confirmed
                                ? String(localized: "ACP 运行时连接已中断，受管进程已清理。不会自动重发任务。", bundle: #bundle)
                                : String(localized: "ACP 运行时连接已中断，进程清理尚未确认。", bundle: #bundle))))
        }
        if notification.disconnected { emit(.disconnected(cleanupConfirmed: confirmed)) }
        return confirmed
    }

    func expirePendingInteractions() {
        do { try broker.expire() }
        catch { emit(.failure(ACPEventMapper.failure(String(describing: error)))) }
    }

    // MARK: - Inbound Pump & Dispatch

    private func emit(_ event: AgentEvent) {
        sink.send(.init(instanceID: instanceID, event: event))
    }

    private func pump() {
        while !stateLock.withLock({ disposed }) {
            // A prompt reply or approval action can dispatch while the transport is idle.
            client.waitForInboundActivity(timeout: 0.02)
            let observation: (messages: [JSONRPCInboundMessage], ended: Bool, failure: String?) = inboundDispatchLock.withLock {
                expirePendingInteractions()
                let batch = client.drainInbound()
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

    func handleInboundMessages(_ messages: [JSONRPCInboundMessage]) {
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
            updateConfiguration { reportMode(modeID, receiveOrder: notification.receiveOrder) }
            sessionChanged = true
        }
        if let configOptions = mapped.metadata.configOptions {
            updateConfiguration { replaceConfigOptions(configOptions, receiveOrder: notification.receiveOrder) }
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
        if sharedHost != nil, stateLock.withLock({ closing || disposed || connectionEnded }) {
            try? client.sendErrorResponse(id: request.id, code: ACPProtocol.ErrorCode.resourceNotFound, message: "Session is closing")
            return
        }
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
                if sharedHost == nil { client.crash() }
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
