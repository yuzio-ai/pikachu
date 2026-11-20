import Foundation
import Darwin
import AgentRuntimeCore
import ProcessSupervision

public actor PiRuntime: AgentRuntime {
    public nonisolated let instanceID = UUID()
    public nonisolated let events: AsyncStream<RuntimeEnvelope>
    private let channel: RuntimeEventChannel
    private let configuration: PiConfiguration
    private var connection: PiConnection?
    private var epoch = UUID()
    public init(configuration: PiConfiguration) {
        self.configuration = configuration
        let channel = RuntimeEventChannel(); self.channel = channel; events = channel.stream()
    }
    /// No project history or execution slot is involved in model inspection.
    public static func inspectModels(_ config: PiConfiguration, model: RuntimeModel?) async throws -> RuntimeConfigurationOptions {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-models-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            var probe = config
            probe.workspace = directory
            let connection = try PiConnection(configuration: probe, instanceID: UUID(), sink: RuntimeEventChannel(), modelProbe: true)
            let result = Result {
                if let model { try connection.selectModel(provider: model.provider, id: model.modelID) }
                return try connection.options()
            }
            do { try connection.close(force: false) }
            catch { try connection.close(force: true) }
            return try result.get()
        }.value
    }
    public func connect() async throws -> RuntimeSession {
        guard connection == nil else { throw RuntimeFailure(.setup, String(localized: "当前连接尚未关闭。", bundle: #bundle)) }
        let ticket = UUID(); epoch = ticket
        let config = configuration, id = instanceID, sink = channel
        var resumeID: String?
        if let file = config.resumeFile {
            let history = try await PiHistoryReader(roots: []).read(file)
            guard !history.incompleteTail, config.expectedSessionID == nil || history.sessionID == config.expectedSessionID else {
                throw RuntimeFailure(.protocolError, String(localized: "会话尾部尚未写完或标识不匹配，禁止激活执行。", bundle: #bundle))
            }
            guard URL(fileURLWithPath: history.cwd).standardizedFileURL.resolvingSymlinksInPath() == config.workspace.standardizedFileURL.resolvingSymlinksInPath() else {
                throw RuntimeFailure(.setup, String(localized: "历史工作目录与项目当前位置不同。请只读查看旧会话，或在当前位置新建会话；不会在旧目录执行。", bundle: #bundle))
            }
            resumeID = history.sessionID
        }
        let bridge = try await Task.detached { try PiConnection(configuration: config, instanceID: id, sink: sink) }.value
        guard epoch == ticket else { try? await Task.detached { try bridge.close(force: true) }.value; throw CancellationError() }
        connection = bridge
        do {
            try await Task.detached { try bridge.verifyPolicy(config.executionPolicy) }.value
            if let file = config.resumeFile, let resumeID {
                try await Task.detached {
                    try bridge.resume(file, expectedID: resumeID)
                    try bridge.verifyPolicy(config.executionPolicy)
                }.value
            }
            return try await Task.detached { try bridge.session() }.value
        }
        catch { try? await Task.detached { try bridge.close(force: true) }.value; throw error }
    }
    public func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        return try await Task.detached { try connection.send(prompt) }.value
    }
    public func stop() async throws {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        try await Task.detached { try connection.stop() }.value
    }
    public func close(force: Bool) async throws {
        epoch = UUID()
        guard let bridge = connection else { channel.finish(); return }
        try await Task.detached { try bridge.close(force: force) }.value
        connection = nil; channel.finish()
    }
    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        return try await Task.detached { try connection.options() }.value
    }
    public func currentSession() async throws -> RuntimeSession {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        return try await Task.detached { try connection.session() }.value
    }
    public func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        return try await Task.detached { try connection.configure(selection) }.value
    }
    public func usage() async throws -> RuntimeUsage {
        guard let connection else { throw RuntimeFailure(.connection, String(localized: "尚未连接运行时。", bundle: #bundle)) }
        return try await Task.detached { try connection.usage() }.value
    }
    public func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {
        guard let connection, request.instanceID == instanceID else { throw RuntimeFailure(.unsupportedInteraction, String(localized: "交互来自已结束的执行实例。", bundle: #bundle)) }
        try await Task.detached { try connection.broker.respond(request, response) }.value
    }
    public func cancelInteractions() async {
        if let connection { await Task.detached { connection.broker.cancelAll() }.value }
    }
    // Test hook: does not appear in AgentRuntime or product UI.
    public func terminateRuntimeForVerification() async { connection?.client.crash() }
}

private final class PiConnection: @unchecked Sendable {
    let client: RPCProcess
    let instanceID: UUID
    let sink: RuntimeEventChannel
    let broker: PiInteractionBroker
    private let verificationTraceURL: URL?
    private let turnChangesScratch: URL?
    private let lock = NSLock()
    private var closing = false
    private var disposed = false
    private var runActive = false
    private var stopped = false
    private var policyStatus: String?
    init(configuration config: PiConfiguration, instanceID: UUID, sink: RuntimeEventChannel, modelProbe: Bool = false) throws {
        self.instanceID = instanceID; self.sink = sink
        verificationTraceURL = config.extensionFixture.map { _ in config.agentDirectory.appendingPathComponent("rpc-\(instanceID).json") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.workspace.path), fm.isExecutableFile(atPath: config.executable.path),
              fm.isExecutableFile(atPath: config.nodeDirectory.appendingPathComponent("node").path) else {
            throw RuntimeFailure(.setup, String(localized: "项目、Pi 路径或 Node 路径不可用。", bundle: #bundle))
        }
        var environment = try config.launchEnvironment(inheriting: ProcessInfo.processInfo.environment)
        // Version probe is bounded and never starts an agent run.
        let version = Process(), out = Pipe()
        version.executableURL = config.executable; version.arguments = ["--version"]; version.environment = environment
        version.standardOutput = out; version.standardError = FileHandle.nullDevice
        try version.run()
        let deadline = Date().addingTimeInterval(5)
        while version.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if version.isRunning { version.terminate(); throw RuntimeFailure(.setup, String(localized: "Pi 版本检测超时。", bundle: #bundle)) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedVersion = /1\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/
        guard version.terminationStatus == 0, text.wholeMatch(of: supportedVersion) != nil else {
            throw RuntimeFailure(.unsupportedVersion, String(localized: "此构建支持 Pi 1.x，请选择该大版本的 Pi。", bundle: #bundle))
        }
        var arguments = ["--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"]
        var scratch: URL?
        if modelProbe {
            arguments += ["--no-session", "--no-tools", "--no-mcp", "--no-context-files"]
        } else {
            arguments += [config.approveProjectConfiguration ? "--approve" : "--no-approve"]
            try fm.createDirectory(at: config.sessionDirectory, withIntermediateDirectories: true)
            arguments += ["--session-dir", config.sessionDirectory.path]
            let execution = config.executionPolicy
            if config.agentMode == .automatic {
                if let fixture = config.extensionFixture { arguments += ["-e", fixture.path] }
                for path in config.extensionPaths {
                    guard fm.isReadableFile(atPath: path.path) else { throw RuntimeFailure(.setup, String(localized: "所选扩展文件无法读取。", bundle: #bundle)) }
                    arguments += ["-e", path.path]
                }
            } else {
                let readTools = ["read", "grep", "find", "ls"]
                let tools = execution.approval == .everyCall ? readTools.map { "pikachu_" + $0 } : readTools
                let writeTools = ["bash", "edit", "write"]
                let enabled = execution.mode == .plan ? tools : tools + writeTools.map {
                    execution.approval == .never ? $0 : "pikachu_" + $0
                }
                arguments += ["--no-mcp", "--tools", enabled.joined(separator: ",")]
            }
            guard let policy = Bundle.piRuntimeAdapter.url(forResource: "execution-policy", withExtension: "ts"),
                  fm.isReadableFile(atPath: policy.path) else { throw RuntimeFailure(.setup, String(localized: "无法加载 Pikachu 执行模式。", bundle: #bundle)) }
            arguments += ["-e", policy.path]
            environment["PIKACHU_EXECUTION_MODE"] = execution.mode.rawValue
            environment["PIKACHU_TOOL_APPROVAL"] = execution.approval.rawValue
            if let tracker = Bundle.piRuntimeAdapter.url(forResource: "turn-file-changes", withExtension: "ts") {
                let temporaryRoot = ProcessInfo.processInfo.environment["TMPDIR"]
                    .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? fm.temporaryDirectory
                let directory = temporaryRoot.appendingPathComponent("pikachu-turn-changes-\(instanceID)", isDirectory: true)
                if (try? fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil {
                    scratch = directory
                    environment["PIKACHU_TURN_CHANGES_DIRECTORY"] = directory.path
                    arguments += ["-e", tracker.path]
                }
            }
        }
        turnChangesScratch = scratch
        do {
            let transport = try RPCProcess(executable: config.executable.path, arguments: arguments, cwd: config.workspace,
                                           environment: environment, supervised: true, streaming: true)
            client = transport
            broker = PiInteractionBroker(instanceID: instanceID, native: config.nativeDialogs,
                                         toolApprovals: !modelProbe && config.executionPolicy.approval != .never,
                                         write: { try transport.send($0) }, emit: { sink.send(.init(instanceID: instanceID, event: $0)) })
        } catch {
            if let scratch { try? fm.removeItem(at: scratch) }
            throw PiEventMapper.failure(String(describing: error))
        }
        Thread.detachNewThread { [self] in pump() }
    }
    func emit(_ event: AgentEvent) { sink.send(.init(instanceID: instanceID, event: event)) }
    func usage() throws -> RuntimeUsage {
        let stats = try client.ok("get_session_stats"), state = try client.ok("get_state")
        let coverage = (state["sessionFile"] as? String).flatMap { try? PiUsageMapper.coverage(URL(fileURLWithPath: $0)) }
        return try PiUsageMapper.live(stats, model: state["model"] as? Record, coverage: coverage)
    }
    func session() throws -> RuntimeSession {
        do {
            let state = try client.ok("get_state", timeout: 15)
            guard let id = state["sessionId"] as? String else { throw RuntimeFailure(.protocolError, String(localized: "运行时未返回会话标识。", bundle: #bundle)) }
            let model = state["model"] as? Record
            // Pi uses an "unknown" placeholder when no authenticated model exists.
            // It is display information, not a configuration that can be restored.
            let provider = model?["provider"] as? String, modelID = model?["id"] as? String
            let configured = provider?.isEmpty == false && provider != "unknown" && modelID?.isEmpty == false && modelID != "unknown"
            return .init(id: id, model: model?["name"] as? String ?? model?["id"] as? String ?? String(localized: "未配置模型", bundle: #bundle),
                         thinking: state["thinkingLevel"] as? String ?? "—",
                         capabilities: turnChangesScratch == nil ? [.streaming, .tools, .interruption, .queuedPrompts]
                             : [.streaming, .tools, .interruption, .queuedPrompts, .turnFileChanges],
                         file: (state["sessionFile"] as? String).map { URL(fileURLWithPath: $0) }, provider: configured ? provider : nil, modelID: configured ? modelID : nil)
        } catch let failure as RuntimeFailure { verificationTrace("session-failed"); throw failure }
        catch { verificationTrace("session-failed"); throw PiEventMapper.failure(String(describing: error)) }
    }
    private func verificationTrace(_ stage: String) {
        // Explicit development fixtures only. Metadata contains no prompts,
        // tool output, authentication values or raw stderr.
        guard let verificationTraceURL else { return }
        let buffers = client.bufferStatus
        let data: Record = ["stage":stage,"trace":client.trace(),"received":client.count,"stderrBytes":client.stderrCount,
                            "bufferedEvents":buffers.events,"bufferedBytes":buffers.eventBytes,"bufferedResponses":buffers.responses]
        try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:verificationTraceURL,options:.atomic)
    }
    func resume(_ file: URL, expectedID: String) throws {
        let result = try client.ok("switch_session", ["sessionPath": file.path], timeout: 15)
        guard result["cancelled"] as? Bool == false else { throw RuntimeFailure(.setup, String(localized: "运行时取消了会话恢复；没有发送任务。", bundle: #bundle)) }
        let restored = try session()
        guard restored.id == expectedID, restored.file?.standardizedFileURL.resolvingSymlinksInPath() == file.standardizedFileURL.resolvingSymlinksInPath() else {
            throw RuntimeFailure(.protocolError, String(localized: "恢复后的会话标识或文件位置不匹配。", bundle: #bundle))
        }
    }
    func verifyPolicy(_ policy: AgentExecutionPolicy) throws {
        guard policy.mode != .automatic else { return }
        let command = "pikachu-verify-policy"
        let commands = try client.ok("get_commands")["commands"] as? [Record] ?? []
        guard commands.contains(where: { $0["name"] as? String == command && $0["source"] as? String == "extension" }) else {
            throw RuntimeFailure(.setup, String(localized: "Pikachu 执行模式未加载。", bundle: #bundle))
        }
        let nonce = UUID().uuidString
        let reply = try client.ok("prompt", ["message": "/\(command) \(nonce)"])
        guard reply["disposition"] as? String == "handled" else { throw RuntimeFailure(.setup, String(localized: "执行模式验证失败。", bundle: #bundle)) }
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            if lock.withLock({ policyStatus == "\(policy.mode.rawValue):\(policy.approval.rawValue):\(nonce)" }) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw RuntimeFailure(.setup, String(localized: "运行时工具列表或审批规则与当前设置不匹配。", bundle: #bundle))
    }
    func options() throws -> RuntimeConfigurationOptions {
        let models = try client.ok("get_available_models")["models"] as? [Record] ?? []
        let levels = try client.ok("get_available_thinking_levels")["levels"] as? [String] ?? []
        return .init(models: models.compactMap {
            guard let provider = $0["provider"] as? String, let id = $0["id"] as? String else { return nil }
            return RuntimeModel(provider: provider, modelID: id, name: $0["name"] as? String ?? id)
        }, thinkingLevels: levels)
    }
    func configure(_ selection: RuntimeSelection) throws -> RuntimeSession {
        let state = try client.ok("get_state")
        guard state["isStreaming"] as? Bool == false, state["isCompacting"] as? Bool != true,
              state["pendingMessageCount"] as? Int == 0 else { throw RuntimeFailure(.setup, String(localized: "运行期间不能修改模型配置。", bundle: #bundle)) }
        let before = try session()
        let changesModel = before.provider != selection.provider || before.modelID != selection.modelID
        if changesModel { try selectModel(provider: selection.provider, id: selection.modelID) }
        do {
            if let thinking = selection.thinking {
                let levels = try client.ok("get_available_thinking_levels")["levels"] as? [String] ?? []
                guard levels.contains(thinking) else {
                    throw RuntimeFailure(.setup, String(localized: "该模型不支持所选推理强度，请重新选择。", bundle: #bundle))
                }
                _ = try client.ok("set_thinking_level", ["level": thinking])
            }
            let applied = try session()
            guard applied.provider == selection.provider, applied.modelID == selection.modelID,
                  selection.thinking == nil || applied.thinking == selection.thinking else { throw RuntimeFailure(.outcomeUnknown, String(localized: "模型配置读回不一致，请重新连接核对。", bundle: #bundle)) }
            return applied
        } catch {
            if changesModel, let provider = before.provider, let model = before.modelID {
                do {
                    try selectModel(provider: provider, id: model)
                    _ = try client.ok("set_thinking_level", ["level": before.thinking])
                } catch { throw RuntimeFailure(.outcomeUnknown, String(localized: "无法确认恢复原模型配置，请重新连接。", bundle: #bundle)) }
            }
            throw error
        }
    }
    func selectModel(provider: String, id: String) throws {
        do { _ = try client.ok("set_model", ["provider": provider, "modelId": id]) }
        catch { throw PiEventMapper.failure(String(describing: error)) }
    }
    func send(_ prompt: UserPrompt) throws -> PromptDisposition {
        do {
            let fields: Record = ["message": prompt.runtimeText, "streamingBehavior": prompt.mode.rawValue]
            let revision = broker.interactionRevision
            let requestID = try client.submit("prompt", fields)
            let acknowledgement = try client.response(requestID, timeout: 5, extendingDeadline: { self.broker.acknowledgementDeadline(since: revision) })
            guard acknowledgement["success"] as? Bool == true else {
                throw RuntimeFailure(.model, String(localized: "运行时未接受这条输入。请检查连接与模型配置后重试。", bundle: #bundle))
            }
            let response = acknowledgement["data"] as? Record ?? [:]
            guard let text = response["disposition"] as? String, let disposition = PromptDisposition(rawValue: text) else {
                throw RuntimeFailure(.outcomeUnknown, String(localized: "未能确认消息接受状态；不会自动重发。", bundle: #bundle))
            }
            if disposition == .handled { broker.cancelAll(reason: .expired, send: false) }
            return disposition
        } catch let error as RuntimeFailure { broker.cancelAll(); throw error }
        catch { broker.cancelAll(); throw PiEventMapper.failure(String(describing: error)) }
    }
    func stop() throws {
        emit(.phase(.stopping)); lock.withLock { stopped = true }
        broker.pause()
        do {
            let recovered = try client.ok("clear_queue")
            let drafts = (recovered["steering"] as? [String] ?? []).map { PendingPrompt(text: $0, mode: .steer) }
                + (recovered["followUp"] as? [String] ?? []).map { PendingPrompt(text: $0, mode: .followUp) }
            emit(.recoveredDrafts(UUID(), drafts)) // Retain even if abort subsequently times out.
            broker.cancelAll()
            _ = try client.ok("abort", timeout: 15)
            let state = try client.ok("get_state")
            guard state["isStreaming"] as? Bool == false, state["pendingMessageCount"] as? Int == 0 else {
                throw RuntimeFailure(.outcomeUnknown, String(localized: "任务尚未确认停止。", bundle: #bundle))
            }
            broker.resume()
        } catch let failure as RuntimeFailure { broker.cancelAll(); throw failure }
        catch { broker.cancelAll(); throw PiEventMapper.failure(String(describing: error)) }
    }
    func close(force: Bool) throws {
        guard !lock.withLock({ disposed }) else { return }
        broker.pause()
        broker.cancelAll(reason: .disconnected)
        lock.withLock { closing = true }
        if force { client.crash() }
        do {
            try client.close()
            guard client.supervisionStatus["state"] as? String == "clean" else { throw RuntimeFailure(.supervision, String(localized: "工具进程清理未确认。", bundle: #bundle)) }
            lock.withLock { disposed = true }
            // An active checkpoint is cleaned by the pump after its last read.
            if let turnChangesScratch { _ = rmdir(turnChangesScratch.path) }
            emit(.disconnected(cleanupConfirmed: true))
        } catch {
            lock.withLock { closing = false }
            throw PiEventMapper.failure(String(describing: error))
        }
    }
    private func pump() {
        var cursor = 0, mapper = PiEventMapper()
        var changes = PiTurnFileChanges(scratch: turnChangesScratch)
        defer {
            if let turnChangesScratch { try? FileManager.default.removeItem(at: turnChangesScratch) }
        }
        while !lock.withLock({ disposed }) {
            do { try broker.expire() } catch { emit(.failure(PiEventMapper.failure(String(describing: error)))) }
            let observation = client.observation(after: cursor); cursor = observation.nextCursor
            for record in observation.records {
                for event in changes.map(record, events: mapper.map(record)) {
                    switch event {
                    case .phase(.running): lock.withLock { runActive = true }
                    case .settled: lock.withLock { runActive = false }
                    default: break
                    }
                    emit(event)
                }
                if record["type"] as? String == "extension_ui_request", let method = record["method"] as? String {
                    if InteractionKind(rawValue: method) != nil {
                        do { try broker.accept(record) }
                        catch { emit(.failure(error as? RuntimeFailure ?? PiEventMapper.failure(String(describing: error)))); client.crash() }
                    } else if method == "notify" {
                        emit(.notice(PiEventMapper.clipped(record["message"] as? String ?? String(localized: "扩展通知", bundle: #bundle), limit: 2000)))
                    } else if method == "set_editor_text" {
                        if let text = record["text"] as? String, !text.isEmpty { emit(.suggestedDraft(PiEventMapper.clipped(text))) }
                    } else if method == "setStatus", let key = record["statusKey"] as? String, key.utf8.count <= 1_024 {
                        if key == "pikachu-policy" { lock.withLock { policyStatus = record["statusText"] as? String } }
                        else if key != PiTurnFileChanges.statusKey {
                            emit(.extensionStatus("status:" + key, (record["statusText"] as? String).map { PiEventMapper.clipped($0, limit: 2_000) }))
                        }
                    } else if method == "setWidget", let key = record["widgetKey"] as? String, key.utf8.count <= 1_024 {
                        emit(.extensionStatus("widget:" + key, (record["widgetLines"] as? [String]).map { PiEventMapper.clipped($0.joined(separator: "\n"), limit: 4_000) }))
                    } else if method == "setTitle" {
                        emit(.extensionStatus("title", (record["title"] as? String).map { PiEventMapper.clipped($0, limit: 2_000) }))
                    } else if !["select", "confirm", "input", "editor", "setStatus", "setWidget", "setTitle", "set_editor_text"].contains(method) {
                        emit(.failure(.init(.unsupportedInteraction, String(localized: "运行时请求了无法识别的交互，请停止任务或结束进程。", bundle: #bundle))))
                    }
                }
            }
            if !lock.withLock({ closing }) && (observation.ended || observation.failure != nil || !client.process.isRunning) {
                // Give the independent supervisor its bounded cleanup window.
                let until = Date().addingTimeInterval(4)
                while client.process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
                let clean = client.supervisionStatus["state"] as? String == "clean" && !client.process.isRunning
                broker.cancelAll(reason: .disconnected, send: false)
                emit(.failure(.init(observation.failure == nil ? .connection : .protocolError,
                                    clean ? String(localized: "运行时连接已中断，受管进程已清理。不会自动重发任务。", bundle: #bundle) : String(localized: "运行时连接已中断，工具清理尚未确认。", bundle: #bundle))))
                emit(.disconnected(cleanupConfirmed: clean)); return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
