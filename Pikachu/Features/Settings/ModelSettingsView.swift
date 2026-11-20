import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ModelSettingsView: View {
    let workspace: WorkspaceController
    @State private var models: [RuntimeModel] = []
    @State private var search = ""
    @State private var loading = true
    @State private var reload = 0
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false

    private var preferences: WorkspaceModelPreferences {
        workspace.state.modelPreferences ?? WorkspaceModelPreferences()
    }

    private var listedModels: [RuntimeModel] {
        var seen: Set<String> = []
        let saved = preferences.favorites + [preferences.defaultModel].compactMap { $0 }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (models + saved).filter { model in
            seen.insert(model.id).inserted && (query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
                || model.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("默认模型").pikachuFont(.headline)
                        .accessibilityAddTraits(.isHeader)
                    HStack {
                        if let model = preferences.defaultModel {
                            modelLabel(model)
                            Spacer(minLength: 8)
                            Button("跟随 Pi 设置") { save { await workspace.setDefaultModel(nil) } }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                                .accessibilityIdentifier("clear-default-model")
                        } else {
                            Text("跟随 Pi 设置").foregroundStyle(.secondary)
                        }
                    }
                    Text("新会话自动使用默认模型，已有会话不变。")
                        .pikachuFont(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            if let saveError { FeedbackBanner(text: saveError, warning: true) }
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型列表").pikachuFont(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("点星号收藏，关闭开关可从会话的模型选择器中隐藏。")
                        .pikachuFont(.callout).foregroundStyle(.secondary)
                    if loading {
                        FlatProgressView("正在读取模型…").controlSize(.small)
                    } else {
                        if let loadError {
                            FeedbackBanner(text: loadError, warning: true)
                        } else if models.isEmpty {
                            Text("未找到可用模型。请检查 Pi 的模型和认证配置。").foregroundStyle(.secondary)
                        }
                        HStack {
                            TextField("搜索模型", text: $search)
                                .flatInputSurface()
                                .accessibilityIdentifier("search-model-settings")
                            Button("重新读取") { reload += 1 }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        }
                        let catalogueIDs = Set(models.map(\.id))
                        let favoriteIDs = Set(preferences.favorites.map(\.id))
                        let hiddenIDs = preferences.hiddenModelIDs
                        let listed = listedModels
                        if listed.isEmpty, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("没有匹配的模型。").foregroundStyle(.secondary)
                        }
                        LazyVStack(alignment: .leading, spacing: 2) {
                            modelGroup("收藏", models: listed.filter { favoriteIDs.contains($0.id) && !hiddenIDs.contains($0.id) },
                                       catalogueIDs: catalogueIDs, favoriteIDs: favoriteIDs, visible: true)
                            modelGroup("其他模型", models: listed.filter { !favoriteIDs.contains($0.id) && !hiddenIDs.contains($0.id) },
                                       catalogueIDs: catalogueIDs, favoriteIDs: favoriteIDs, visible: true)
                            modelGroup("已从选择器隐藏", models: listed.filter { hiddenIDs.contains($0.id) },
                                       catalogueIDs: catalogueIDs, favoriteIDs: favoriteIDs, visible: false)
                        }
                    }
                }
                .padding(16)
            }
        }
        .disabled(saving)
        .accessibilityIdentifier("model-settings")
        .task(id: reload) { await loadModels() }
    }

    private func modelLabel(_ model: RuntimeModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: model.name).lineLimit(1).truncationMode(.middle)
            Text(verbatim: model.id).lineLimit(1).truncationMode(.middle)
                .pikachuFont(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func modelGroup(_ title: LocalizedStringKey, models: [RuntimeModel], catalogueIDs: Set<String>,
                                         favoriteIDs: Set<String>, visible: Bool) -> some View {
        if !models.isEmpty {
            Text(title).pikachuFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(models) { model in
                modelRow(model, available: catalogueIDs.contains(model.id), favorite: favoriteIDs.contains(model.id), visible: visible)
            }
        }
    }

    private func modelRow(_ model: RuntimeModel, available: Bool, favorite: Bool, visible: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                save { await workspace.setFavoriteModel(model, isFavorite: !favorite) }
            } label: {
                IconButtonLabel(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? PikachuTheme.warningText : PikachuTheme.secondaryText)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .disabled(!available && !favorite)
            .help(favorite ? Text("取消收藏") : Text("收藏模型"))
            .accessibilityLabel(favorite ? Text("取消收藏 \(model.name)") : Text("收藏 \(model.name)"))
            .accessibilityIdentifier("favorite-model-\(model.id)")
            Text(verbatim: model.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(visible ? PikachuTheme.primaryText : PikachuTheme.secondaryText)
                .layoutPriority(1)
            Text(verbatim: model.id).lineLimit(1).truncationMode(.middle)
                .pikachuFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                .help(model.id)
            Spacer(minLength: 4)
            if !available {
                Text("当前不可用").pikachuFont(.caption).foregroundStyle(.secondary)
            } else if preferences.defaultModel?.id != model.id {
                Button("设为默认") { save { await workspace.setDefaultModel(model) } }
                    .buttonStyle(FlatControlButtonStyle())
                    .accessibilityLabel(Text("将 \(model.name) 设为默认模型"))
                    .accessibilityIdentifier("set-default-model-\(model.id)")
            } else {
                Label("默认模型", systemImage: "checkmark")
                    .pikachuFont(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { visible }, set: { newValue in
                save { await workspace.setModelVisible(model, isVisible: newValue) }
            })) {
                Text("在选择器中显示 \(model.name)")
            }
            .toggleStyle(FlatToggleStyle(compact: true))
            .disabled(!available)
            .accessibilityIdentifier("model-visibility-\(model.id)")
        }
    }

    private func save(_ operation: @escaping @MainActor () async -> Bool) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            if !(await operation()) {
                saveError = workspace.storageError ?? String(localized: "无法保存模型设置，请重试。")
            }
        }
    }

    private func loadModels() async {
        loading = true
        loadError = nil
        do {
            let catalogue = try await workspace.modelCatalogue()
            guard !Task.isCancelled else { return }
            models = catalogue
        } catch {
            guard !Task.isCancelled else { return }
            models = []
            loadError = (error as? RuntimeFailure)?.detail ?? String(localized: "模型目录读取失败，请检查连接设置。")
        }
        loading = false
    }
}
