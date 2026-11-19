import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ConfigurationSheet: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    @Environment(\.dismiss) private var dismiss
    @State private var modelKey: String
    @State private var thinking: String
    @State private var models: [RuntimeModel] = []
    @State private var levels: [String] = []
    @State private var modelError: String?
    @State private var levelError: String?
    @State private var saveError: String?
    @State private var loadingModels = true
    @State private var loadedLevelKey: String?
    @State private var saving = false
    @State private var reloadModels = 0
    @State private var reloadLevels = 0

    private var selection: RuntimeSelection? { reference.pendingSelection ?? reference.selection }
    private var selectedModel: RuntimeModel? { models.first { $0.id == modelKey } }

    init(workspace: WorkspaceController, reference: SessionReference) {
        self.workspace = workspace
        self.reference = reference
        let selection = reference.pendingSelection ?? reference.selection
        _modelKey = State(initialValue: selection.map { $0.provider + "/" + $0.modelID } ?? "")
        _thinking = State(initialValue: selection?.thinking ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型与推理强度").font(.title2)
            if loadingModels {
                ProgressView("正在读取模型…").controlSize(.small)
            } else if let modelError {
                Text(modelError).foregroundStyle(.secondary)
                Button("重试读取模型") { reloadModels += 1 }
            } else if models.isEmpty {
                Text("未找到可用模型。请检查 Pi 的模型和认证配置。").foregroundStyle(.secondary)
                Button("重新读取") { reloadModels += 1 }
            } else {
                Picker("模型", selection: $modelKey) {
                    Text("请选择").tag("")
                    ForEach(models) { model in Text(model.provider + " / " + model.name).tag(model.id) }
                }.accessibilityIdentifier("model-picker")

                if selectedModel != nil {
                    if let levelError {
                        Text(levelError).foregroundStyle(.secondary)
                        Button("重试读取推理强度") { reloadLevels += 1 }
                    } else if loadedLevelKey == modelKey {
                        Picker("推理强度", selection: $thinking) {
                            Text("运行时默认").tag("")
                            ForEach(levels, id: \.self) { level in Text(level).tag(level) }
                        }.accessibilityIdentifier("thinking-picker")
                    } else {
                        ProgressView("正在读取推理强度…").controlSize(.small)
                    }
                } else if selection != nil {
                    Text("已保存的模型当前不可用，请从列表中重新选择。").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let saveError { Text(saveError).foregroundStyle(.orange) }
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") {
                    guard let model = selectedModel else { return }
                    saving = true
                    saveError = nil
                    let selection = RuntimeSelection(provider: model.provider, modelID: model.modelID, thinking: thinking.isEmpty ? nil : thinking)
                    Task {
                        let saved = await workspace.saveSelection(selection, name: model.name, for: reference.id)
                        saving = false
                        if saved { dismiss() }
                        else { saveError = workspace.storageError ?? workspace.error ?? "暂时无法应用模型配置，请重试。" }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(saving || loadingModels || workspace.busy || selectedModel == nil || loadedLevelKey != modelKey)
            }.buttonStyle(.glass)
        }
        .padding(24).frame(width: 465)
        .task(id: reloadModels) { await loadModels() }
        .task(id: LevelRequest(model: selectedModel, retry: reloadLevels)) { await loadLevels() }
        .onChange(of: modelKey) { _, _ in saveError = nil }
    }

    private struct LevelRequest: Equatable {
        let model: RuntimeModel?
        let retry: Int
    }

    private func loadModels() async {
        loadingModels = true
        modelError = nil
        do {
            let options = try await workspace.configurationOptions(for: reference.id)
            guard !Task.isCancelled else { return }
            models = options.models
            if models.isEmpty || selectedModel == nil { modelKey = "" }
        } catch {
            guard !Task.isCancelled else { return }
            modelError = detail(error, fallback: "模型目录读取失败，请检查连接设置。")
        }
        loadingModels = false
    }

    private func loadLevels() async {
        loadedLevelKey = nil
        levelError = nil
        guard let model = selectedModel else { return }
        do {
            let options = try await workspace.configurationOptions(for: reference.id, model: model)
            guard !Task.isCancelled, modelKey == model.id else { return }
            levels = options.thinkingLevels
            let saved = selection.flatMap { $0.provider == model.provider && $0.modelID == model.modelID ? $0.thinking : nil }
            thinking = saved.map { levels.contains($0) ? $0 : "" } ?? ""
            loadedLevelKey = model.id
        } catch {
            guard !Task.isCancelled, modelKey == model.id else { return }
            levelError = detail(error, fallback: "推理强度读取失败，请重试。")
        }
    }

    private func detail(_ error: Error, fallback: String) -> String { (error as? RuntimeFailure)?.detail ?? fallback }
}
