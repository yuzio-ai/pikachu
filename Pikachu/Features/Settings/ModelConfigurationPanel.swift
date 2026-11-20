import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

enum ReasoningLevelLabel {
    static func text(for level: String) -> String {
        switch level {
        case "off": String(localized: "关闭", comment: "Reasoning disabled")
        case "minimal": String(localized: "最低", comment: "Minimal reasoning effort")
        case "low": String(localized: "低", comment: "Low reasoning effort")
        case "medium": String(localized: "中", comment: "Medium reasoning effort")
        case "high": String(localized: "高", comment: "High reasoning effort")
        case "xhigh": String(localized: "极高", comment: "Extra-high reasoning effort")
        default: level
        }
    }
}

struct ModelConfigurationPanel: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    @Binding var saving: Bool
    let close: () -> Void
    @State private var modelKey: String
    @State private var thinking = ""
    @State private var models: [RuntimeModel] = []
    @State private var showAllModels = false
    @State private var modelSearch = ""
    @State private var levels: [String] = []
    @State private var modelError: String?
    @State private var levelError: String?
    @State private var saveError: String?
    @State private var loadingModels = true
    @State private var loadedLevelKey: String?
    @State private var reloadModels = 0
    @State private var reloadLevels = 0
    @FocusState private var focusedModel: String?
    @FocusState private var focusedThinking: String?
    private var selection: RuntimeSelection? { reference.pendingSelection ?? reference.selection }
    private var selectedModel: RuntimeModel? { models.first { $0.id == modelKey } }
    private var preferences: WorkspaceModelPreferences { workspace.state.modelPreferences ?? WorkspaceModelPreferences() }
    private var favoriteIDs: Set<String> { Set(preferences.favorites.map(\.id)).subtracting(preferences.hiddenModelIDs) }
    private var searchTerm: String { modelSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func pickerModels(showAll: Bool) -> [RuntimeModel] {
        var retainedIDs: Set<String> = [modelKey]
        if let selection { retainedIDs.insert(selection.provider + "/" + selection.modelID) }
        let visible = preferences.pickerModels(from: models, keeping: retainedIDs, showAll: showAll || !searchTerm.isEmpty)
        let matching = searchTerm.isEmpty ? visible : visible.filter {
            $0.name.localizedStandardContains(searchTerm) || $0.id.localizedStandardContains(searchTerm)
        }
        let favorites = favoriteIDs
        return matching.filter { favorites.contains($0.id) } + matching.filter { !favorites.contains($0.id) }
    }
    private var isCurrentSession: Bool { workspace.state.selectedSessionID == reference.id }

    init(workspace: WorkspaceController, reference: SessionReference, saving: Binding<Bool>, close: @escaping () -> Void) {
        self.workspace = workspace
        self.reference = reference
        _saving = saving
        self.close = close
        let selection = reference.pendingSelection ?? reference.selection
        _modelKey = State(initialValue: selection.map { $0.provider + "/" + $0.modelID } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型与推理强度").anchoredCardTitle()
            catalogue
                .disabled(saving)
                .onChange(of: modelKey) { _, _ in saveError = nil }
            if let saveError {
                Text(saveError).foregroundStyle(PikachuTheme.errorText)
            }
            PikachuDivider()
            HStack {
                if saving { FlatProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("保存", action: save)
                    .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                    .disabled(saving || loadingModels || workspace.isOperating(on: reference.id) || selectedModel == nil || loadedLevelKey != modelKey)
            }
        }
        .buttonStyle(FlatControlButtonStyle())
        .anchoredPopoverCard(width: 600)
        .interactiveDismissDisabled(saving)
        .accessibilityIdentifier("model-configuration-panel")
        .task(id: reloadModels) { await loadModels() }
        .task(id: LevelRequest(model: selectedModel, retry: reloadLevels)) { await loadLevels() }
    }

    @ViewBuilder private var catalogue: some View {
        if loadingModels {
            FlatProgressView("正在读取模型…").controlSize(.small)
        } else if let modelError {
            Text(modelError).foregroundStyle(.secondary)
            Button("重试读取模型") { reloadModels += 1 }
        } else if models.isEmpty {
            Text("未找到可用模型。请检查 Pi 的模型和认证配置。").foregroundStyle(.secondary)
            Button("重新读取") { reloadModels += 1 }
        } else {
            HStack(alignment: .top, spacing: 12) {
                modelColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                thinkingColumn
                    .frame(width: 194)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 270)
        }
    }

    private var modelColumn: some View {
        let displayed = pickerModels(showAll: showAllModels)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("搜索模型…", text: $modelSearch)
                .flatInputSurface()
                .accessibilityIdentifier("model-picker-search")
            if searchTerm.isEmpty, showAllModels || displayed.count < pickerModels(showAll: true).count {
                Button {
                    showAllModels.toggle()
                } label: {
                    Label(showAllModels ? "仅看收藏" : "查看全部可见模型", systemImage: showAllModels ? "star" : "list.bullet")
                }
                .accessibilityIdentifier("model-picker-show-all")
            }
            if displayed.isEmpty {
                Text(searchTerm.isEmpty ? "没有显示的模型。可在设置的 Pi 模型页中调整可见性。" : "未找到匹配的模型。")
                    .foregroundStyle(.secondary)
            } else {
                modelRows(displayed)
            }
        }
    }

    private var thinkingColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("推理强度").fontWeight(.medium)
            if let selectedModel {
                Text(verbatim: selectedModel.name)
                    .pikachuFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            PikachuDivider()
            if selectedModel == nil {
                Text(selection == nil ? "先从左侧选择模型。" : "已保存的模型当前不可用，请从列表中重新选择。")
                    .foregroundStyle(.secondary)
            } else if let levelError {
                Text(levelError).foregroundStyle(.secondary)
                Button("重试读取推理强度") { reloadLevels += 1 }
            } else if loadedLevelKey == modelKey {
                thinkingPicker
            } else {
                FlatProgressView("正在读取推理强度…").controlSize(.small)
            }
        }
    }

    private func modelRows(_ displayed: [RuntimeModel]) -> some View {
        let favorites = favoriteIDs
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(displayed) { model in
                    Button {
                        modelKey = model.id
                    } label: {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: model.provider)
                            Text(model.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(model.provider).pikachuFont(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "star.fill")
                                .pikachuFont(.caption)
                                .foregroundStyle(PikachuTheme.warningText)
                                .opacity(favorites.contains(model.id) ? 1 : 0)
                                .accessibilityLabel("收藏")
                                .accessibilityHidden(!favorites.contains(model.id))
                            Image(systemName: "checkmark")
                                .pikachuFont(.caption, weight: .semibold)
                                .opacity(model.id == modelKey ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(isOpen: model.id == modelKey))
                    .focused($focusedModel, equals: model.id)
                    .accessibilityAddTraits(model.id == modelKey ? .isSelected : [])
                }
            }
        }
        .accessibilityIdentifier("model-picker")
    }

    private var thinkingPicker: some View {
        let options = [""] + levels
        return ScrollView {
            VStack(spacing: 2) {
                thinkingRow("", title: Text("运行时默认"))
                ForEach(levels, id: \.self) { level in
                    thinkingRow(level, title: Text(ReasoningLevelLabel.text(for: level)))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("推理强度")
        .accessibilityIdentifier("thinking-picker")
        .onMoveCommand { direction in
            guard direction == .up || direction == .down,
                  let focusedThinking, let index = options.firstIndex(of: focusedThinking) else { return }
            let next = index + (direction == .down ? 1 : -1)
            guard options.indices.contains(next) else { return }
            thinking = options[next]
            self.focusedThinking = options[next]
        }
    }

    private func thinkingRow(_ level: String, title: Text) -> some View {
        Button {
            thinking = level
        } label: {
            HStack {
                title
                Spacer()
                if thinking == level {
                    Image(systemName: "checkmark")
                        .pikachuFont(.caption, weight: .semibold)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: thinking == level))
        .focused($focusedThinking, equals: level)
        .accessibilityAddTraits(thinking == level ? .isSelected : [])
    }

    private struct LevelRequest: Equatable {
        let model: RuntimeModel?
        let retry: Int
    }

    private func save() {
        guard !saving, isCurrentSession, let model = selectedModel, loadedLevelKey == modelKey else { return }
        saving = true
        saveError = nil
        let request = RuntimeSelection(provider: model.provider, modelID: model.modelID, thinking: thinking.isEmpty ? nil : thinking)
        Task {
            let saved = await workspace.saveSelection(request, name: model.name, for: reference.id)
            saving = false
            guard isCurrentSession else { return }
            if saved { close() }
            else { saveError = workspace.storageError ?? workspace.error ?? String(localized: "暂时无法应用模型配置，请重试。") }
        }
    }

    private func loadModels() async {
        loadingModels = true
        modelError = nil
        do {
            let options = try await workspace.configurationOptions(for: reference.id)
            guard !Task.isCancelled, isCurrentSession else { return }
            models = options.models
            if selectedModel == nil { modelKey = "" }
            if let target = selectedModel ?? pickerModels(showAll: showAllModels).first { focusedModel = target.id }
        } catch {
            guard !Task.isCancelled, isCurrentSession else { return }
            modelError = (error as? RuntimeFailure)?.detail ?? String(localized: "模型目录读取失败，请检查连接设置。")
        }
        loadingModels = false
    }

    private func loadLevels() async {
        loadedLevelKey = nil
        levelError = nil
        guard let model = selectedModel else { return }
        do {
            let options = try await workspace.configurationOptions(for: reference.id, model: model)
            guard !Task.isCancelled, isCurrentSession, modelKey == model.id else { return }
            levels = options.thinkingLevels
            let saved = selection.flatMap { $0.provider == model.provider && $0.modelID == model.modelID ? $0.thinking : nil }
            thinking = saved.map { levels.contains($0) ? $0 : "" } ?? ""
            loadedLevelKey = model.id
        } catch {
            guard !Task.isCancelled, isCurrentSession, modelKey == model.id else { return }
            levelError = (error as? RuntimeFailure)?.detail ?? String(localized: "推理强度读取失败，请重试。")
        }
    }
}
