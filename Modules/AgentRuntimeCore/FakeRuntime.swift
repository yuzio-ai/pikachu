import Foundation

/// Explicit offline backend for contract tests and native UI verification.
public actor FakeRuntime: AgentRuntime {
    public nonisolated let instanceID = UUID()
    public nonisolated let events: AsyncStream<RuntimeEnvelope>
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    private var generation = UUID()
    private var active = false
    private var queue = RuntimeQueue()
    private let sessionID = UUID().uuidString
    private var selection = RuntimeSelection(provider: "pikachu", modelID: "demo", thinking: "off")
    public static let models = [
        RuntimeModel(provider: "pikachu", modelID: "demo", name: String(localized: "演示模型", bundle: #bundle)),
        RuntimeModel(provider: "pikachu", modelID: "demo-reasoning", name: String(localized: "演示推理模型", bundle: #bundle)),
    ]
    public nonisolated static func options(for model: RuntimeModel?) -> RuntimeConfigurationOptions {
        .init(models: models, thinkingLevels: model?.modelID == "demo-reasoning" ? ["off", "low", "medium", "high"] : ["off"])
    }
    public init() {
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    private func emit(_ event: AgentEvent) { continuation.yield(.init(instanceID: instanceID, event: event)) }
    public func connect() async throws -> RuntimeSession {
        try await currentSession()
    }
    public func currentSession() async throws -> RuntimeSession {
        .init(id: sessionID, model: Self.models.first { $0.modelID == selection.modelID }?.name ?? selection.modelID,
              thinking: selection.thinking ?? "off", capabilities: [.streaming, .tools, .interruption, .queuedPrompts],
              provider: selection.provider, modelID: selection.modelID)
    }
    public func configurationOptions() async throws -> RuntimeConfigurationOptions {
        Self.options(for: Self.models.first { $0.modelID == selection.modelID })
    }
    public func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        guard let model = Self.models.first(where: { $0.provider == selection.provider && $0.modelID == selection.modelID }),
              selection.thinking.map({ Self.options(for: model).thinkingLevels.contains($0) }) != false else {
            throw RuntimeFailure(.model, String(localized: "演示模型或推理强度不可用。", bundle: #bundle))
        }
        self.selection = selection
        return try await currentSession()
    }
    public func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        if prompt.text == "/handled" { emit(.notice(String(localized: "演示指令已处理", bundle: #bundle))); return .handled }
        if prompt.text == "/error" { throw RuntimeFailure(.model, String(localized: "演示模型拒绝了请求", bundle: #bundle)) }
        if active {
            if prompt.mode == .steer { queue.steering.append(prompt.runtimeText) } else { queue.followUp.append(prompt.runtimeText) }
            emit(.queue(queue)); return .queued
        }
        active = true
        let ticket = UUID(); generation = ticket
        emit(.phase(.running))
        Task { await self.run(ticket) }
        return .started
    }
    private func run(_ ticket: UUID) async {
        let id = UUID(), toolID = UUID().uuidString
        emit(.assistantStarted(id))
        let chunks = [
            String(localized: "正在检查项目。", bundle: #bundle) + "\n\n",
            String(localized: "**执行过程**会在这里实时更新。", bundle: #bundle) + "\n\n",
            "```swift\nlet result = 1 + 1\n```",
        ]
        for text in chunks {
            try? await Task.sleep(for: .milliseconds(200))
            guard generation == ticket else { return }
            emit(.textDelta(id, 0, text))
        }
        emit(.assistantCompleted(id, chunks.joined()))
        emit(.tool(.init(id: toolID, name: "bash", arguments: "swift test", output: String(localized: "正在运行测试…", bundle: #bundle))))
        try? await Task.sleep(for: .seconds(2))
        guard generation == ticket else { return }
        emit(.tool(.init(id: toolID, name: "bash", arguments: "swift test", output: "Test Suite passed.\n0 failures.", state: .completed)))
        let next = queue.steering + queue.followUp
        queue = .init(); emit(.queue(queue))
        if !next.isEmpty {
            let nextID = UUID()
            emit(.assistantStarted(nextID))
            emit(.assistantCompleted(nextID, String(localized: "已处理补充内容：\n\(next.joined(separator: "\n"))", bundle: #bundle)))
        }
        active = false; emit(.settled(aborted: false))
    }
    public func stop() async throws {
        let drafts = queue.steering.map { PendingPrompt(text: $0, mode: .steer) } + queue.followUp.map { PendingPrompt(text: $0, mode: .followUp) }
        generation = UUID(); active = false; queue = .init()
        emit(.phase(.stopping)); emit(.recoveredDrafts(UUID(), drafts)); emit(.queue(queue)); emit(.settled(aborted: true))
    }
    public func close(force: Bool) async throws {
        generation = UUID(); active = false; emit(.disconnected(cleanupConfirmed: true)); continuation.finish()
    }
}
