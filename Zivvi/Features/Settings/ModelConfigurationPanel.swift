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
    let width: CGFloat
    let opensHandoff: Bool
    @Environment(\.zivviTypography) private var typography
    @State private var modelKey: String
    @State private var thinking = ""
    @State private var thinkingModelID: String?
    @State private var showsReasoningMenu = false
    @State private var models: [RuntimeModel] = []
    @State private var browsing = ModelPickerBrowsingPosition()
    @State private var browsingCatalogue: ModelCatalogueID?
    @State private var modelSearch = ""
    @State private var levels: [String] = []
    @State private var modelError: String?
    @State private var levelError: (request: LevelRequest, detail: String)?
    @State private var saveError: String?
    @State private var loadedModelRequest: ModelRequest?
    @State private var loadedLevelRequest: LevelRequest?
    @State private var reloadModels = 0
    @State private var reloadLevels = 0
    @State private var switchingRuntime = false
    @State private var handoffPreview: SessionHandoffPreview?
    @State private var handoffTargetID: String?
    @State private var handoffContext = ""
    @State private var handoffDraft: SessionHandoffDraft?
    @State private var omitHistory = false
    @State private var editingHandoff = false
    @FocusState private var focusedModel: String?

    private var currentReference: SessionReference {
        workspace.state.sessions.first(where: { $0.id == reference.id }) ?? reference
    }
    private var currentRuntimeID: String { currentReference.runtimeID }
    private var catalogueRuntimeID: String { handoffTargetID ?? currentRuntimeID }
    private var selection: RuntimeSelection? {
        handoffTargetID == nil ? currentReference.pendingSelection ?? currentReference.selection : nil
    }
    private var selectedModel: RuntimeModel? { loadingModels ? nil : models.first { $0.id == modelKey } }
    private var preferences: WorkspaceModelPreferences { workspace.modelPreferences(forRuntime: catalogueRuntimeID) }
    private var searchTerm: String { modelSearch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedScope: ModelPickerScope { browsing.selectedScope(query: searchTerm) }
    private var isCurrentSession: Bool { workspace.state.selectedSessionID == reference.id }
    private var runtimeAvailable: Bool { workspace.isRuntimeAvailable(catalogueRuntimeID) }
    private var canSwitchAgent: Bool {
        workspace.canSwitchDraftAgent(for: currentReference)
    }
    private var displayedRuntimeIDs: [String] {
        guard canSwitchAgent || handoffPreview != nil && !editingHandoff else { return [currentRuntimeID] }
        let available = workspace.availableRuntimeIDs
        return available.contains(currentRuntimeID) ? available : [currentRuntimeID] + available
    }
    private var modelRequest: ModelRequest {
        .init(catalogue: .init(runtimeID: catalogueRuntimeID, staged: handoffTargetID != nil),
              revision: handoffTargetID == nil ? workspace.execution(for: reference.id)?.session?.configurationRevision : nil,
              waitsForSessionOperation: handoffTargetID == nil && workspace.isOperating(on: reference.id),
              retry: reloadModels)
    }
    private var loadingModels: Bool { loadedModelRequest != modelRequest }
    private var levelRequest: LevelRequest { .init(catalogue: modelRequest, model: selectedModel, retry: reloadLevels) }
    private var effectiveContext: String { omitHistory ? "" : handoffContext }
    private var effectiveDraft: SessionHandoffDraft? {
        var draft = handoffDraft
        draft?.omitsHistory = omitHistory
        return draft
    }
    private var canSave: Bool {
        guard !saving, !switchingRuntime, !workspace.isOperating(on: reference.id) else { return false }
        if editingHandoff { return handoffPreview != nil }
        guard !loadingModels, modelError == nil, runtimeAvailable else { return false }
        if handoffPreview != nil {
            return handoffTargetID != nil &&
                (selectedModel == nil || loadedLevelRequest == levelRequest)
        }
        return selectedModel != nil && loadedLevelRequest == levelRequest
    }

    init(workspace: WorkspaceController, reference: SessionReference, saving: Binding<Bool>, width: CGFloat,
         opensHandoff: Bool = false,
         close: @escaping () -> Void) {
        self.workspace = workspace
        self.reference = reference
        _saving = saving
        self.width = width
        self.opensHandoff = opensHandoff
        self.close = close
        _editingHandoff = State(initialValue: opensHandoff)
        let selection = reference.pendingSelection ?? reference.selection
        _modelKey = State(initialValue: selection.map { $0.provider + "/" + $0.modelID } ?? "")
    }

    var body: some View {
        let catalogueRequest = modelRequest
        let request = levelRequest
        VStack(alignment: .leading, spacing: 10) {
            if !editingHandoff { agentControls }
            if handoffPreview == nil, let source = currentReference.modelSource, source != .session {
                if source == .global && currentReference.pendingSelection == nil && currentReference.selection == nil {
                    Text("来源：全局 · 跟随 Agent 默认").zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                } else {
                    Text(source.detail).zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            if !editingHandoff {
                catalogue
                    .disabled(saving || switchingRuntime)
                    .onChange(of: modelKey) { saveError = nil }
            }
            if let handoffPreview {
                if !editingHandoff { ZivviDivider() }
                HandoffContextEditor(preview: handoffPreview,
                                     target: editingHandoff || handoffTargetID != nil
                                         ? workspace.runtimeDisplayName(for: catalogueRuntimeID) : nil,
                                     draft: $handoffDraft, context: $handoffContext, omitHistory: $omitHistory)
                    .disabled(saving)
            }
            if let saveError {
                Text(saveError).foregroundStyle(ZivviTheme.errorText)
            }
            if handoffPreview != nil { ZivviDivider() }
            actions
        }
        .buttonStyle(FlatControlButtonStyle())
        .anchoredPopoverCard(width: width)
        .interactiveDismissDisabled(saving || switchingRuntime || showsReasoningMenu)
        .onKeyPress(.escape) {
            guard showsReasoningMenu else { return .ignored }
            showsReasoningMenu = false
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(handoffPreview == nil ? Text("智能体与模型") : Text("交接上下文"))
        .accessibilityIdentifier("model-configuration-panel")
        .task { if opensHandoff { openHandoff(editing: true) } }
        .task(id: catalogueRequest) { await loadModels(catalogueRequest) }
        .task(id: request) { await loadLevels(request) }
        .onChange(of: request) { showsReasoningMenu = false }
        .onChange(of: searchTerm) { previous, new in
            if previous.isEmpty || new.isEmpty { browsing.scopeWhileSearching = nil }
            browsing.topModelID = nil
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                FlatSegmentedControl(title: "智能体", values: displayedRuntimeIDs,
                                     selection: Binding(get: { catalogueRuntimeID }, set: switchRuntime),
                                     readOnly: !canSwitchAgent && (handoffPreview == nil || editingHandoff)) { runtimeID in
                    CodingAgentLabel(runtimeID: runtimeID, displayName: workspace.runtimeDisplayName(for: runtimeID),
                                     agents: workspace.acpAgents)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("model-picker-agent")
            if currentReference.hasBoundRuntime && handoffPreview == nil {
                HStack {
                    if workspace.availableRuntimeIDs.contains(where: { $0 != currentRuntimeID }) {
                        Button("切换智能体…") { openHandoff(editing: false) }
                    }
                    if currentReference.handoff?.delivered == false {
                        Button("交接上下文…") { openHandoff(editing: true) }
                    }
                }
                .disabled(workspace.handoffBlockReason(for: reference.id) != nil)
            }
        }
        .disabled(saving || switchingRuntime)
    }

    @ViewBuilder private var catalogue: some View {
        if !runtimeAvailable {
            Text("此会话的智能体当前不可用。").foregroundStyle(.secondary)
        } else if loadingModels, browsingCatalogue != modelRequest.catalogue || models.isEmpty {
            FlatProgressView("正在读取模型…").controlSize(.small)
        } else if let modelError {
            Text(modelError).foregroundStyle(.secondary)
            Button("重试读取模型") { reloadModels += 1 }
        } else if models.isEmpty {
            Text("此 Agent 未提供可选模型列表，或需先检查连接与认证配置。").foregroundStyle(.secondary)
            Button("重新读取") { reloadModels += 1 }
        } else {
            let catalogue = pickerCatalogue
            let rows = catalogue.rows(scope: selectedScope, query: searchTerm)
            modelSearchControls
            if rows.isEmpty {
                Text(searchTerm.isEmpty ? "暂无可显示的模型。请在智能体设置中调整模型可见性。" : "未找到匹配的模型。")
                    .foregroundStyle(.secondary)
                if selectedScope == .favorites {
                    Button("查看全部可见模型") { setScope(.all) }
                }
            } else {
                modelRows(rows, favorites: catalogue.favorites)
            }
            reasoning(selectedShown: rows.contains { $0.id == modelKey })
        }
    }

    private var pickerCatalogue: ModelPickerCatalogue {
        var retainedIDs: Set<String> = [modelKey]
        if let selection { retainedIDs.insert(selection.provider + "/" + selection.modelID) }
        return ModelPickerCatalogue(models: models, preferences: preferences, retaining: retainedIDs)
    }

    private var modelSearchControls: some View {
        let horizontal = width >= 25 * typography.pointSize(for: .callout)
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        return layout {
            TextField("搜索模型…", text: $modelSearch)
                .flatInputSurface()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("model-picker-search")
            FlatSegmentedControl(title: "模型范围", values: ModelPickerScope.allCases,
                                 selection: Binding(get: { selectedScope }, set: setScope)) { option in
                Text(option.title)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("model-picker-scope")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型")
    }

    private func setScope(_ value: ModelPickerScope) {
        if searchTerm.isEmpty { browsing.scope = value }
        else { browsing.scopeWhileSearching = value }
        browsing.topModelID = nil
    }

    private func modelRows(_ displayed: [RuntimeModel], favorites: Set<String>) -> some View {
        let duplicates = Set(Dictionary(grouping: displayed) { [$0.provider, $0.name] }
            .filter { $0.value.count > 1 }.keys)
        let showsProvider = !RuntimeAgentProfile.isACPRuntimeID(catalogueRuntimeID)
        let hasSubtitle = showsProvider || !duplicates.isEmpty
        let rowHeight = hasSubtitle
            ? ceil((typography.pointSize(for: .callout) + typography.pointSize(for: .caption)) * 1.25 + 8)
            : ceil(typography.pointSize(for: .callout) * 1.25 + 12)
        let listHeight = CGFloat(min(6, displayed.count)) * (rowHeight + 2) - 2
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(displayed) { model in
                    Button { modelKey = model.id } label: {
                        PickerModelRow(model: model, selected: model.id == modelKey, favorite: favorites.contains(model.id),
                                       showsProvider: showsProvider,
                                       showsID: duplicates.contains([model.provider, model.name]))
                            .padding(.horizontal, 8)
                            .frame(height: rowHeight)
                    }
                    .buttonStyle(FlatControlButtonStyle(isSelected: model.id == modelKey,
                                                      hasKeyboardFocus: focusedModel == model.id, inset: false))
                    .disabled(loadingModels)
                    .focused($focusedModel, equals: model.id)
                    .accessibilityAddTraits(model.id == modelKey ? .isSelected : [])
                    .accessibilityIdentifier("model-picker-row-\(model.id)")
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: listHeight)
        .scrollPosition(id: $browsing.topModelID, anchor: .top)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("model-picker")
        .onMoveCommand { direction in
            guard !loadingModels, let focusedModel, let index = displayed.firstIndex(where: { $0.id == focusedModel }),
                  direction == .up || direction == .down else { return }
            let next = index + (direction == .down ? 1 : -1)
            guard displayed.indices.contains(next) else { return }
            let id = displayed[next].id
            modelKey = id
            browsing.topModelID = id
            self.focusedModel = id
        }
    }

    private func reasoning(selectedShown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !selectedShown, let selectedModel {
                let snapshot = ModelPresentation.snapshot(selectedModel)
                let name = snapshot.map { "\($0.name) (\($0.displayDate))" } ?? selectedModel.name
                Text(verbatim: name).zivviFont(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("推理强度").fontWeight(.medium).fixedSize()
                reasoningOptions
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var reasoningOptions: some View {
        if loadingModels {
            FlatProgressView("正在读取模型…").controlSize(.small)
        } else if selectedModel == nil {
            Text(handoffTargetID != nil ? "使用目标智能体的默认模型。" :
                 selection == nil ? "请先选择模型。" : "已保存的模型当前不可用，请从列表中重新选择。")
                .foregroundStyle(.secondary)
        } else if let levelError, levelError.request == levelRequest {
            VStack(alignment: .leading, spacing: 4) {
                Text(levelError.detail).foregroundStyle(.secondary)
                Button("重试读取推理强度") { reloadLevels += 1 }
            }
        } else if loadedLevelRequest != levelRequest {
            FlatProgressView("正在读取推理强度…").controlSize(.small)
        } else if levels.isEmpty {
            Text("运行时默认").foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                FlatSegmentedControl(title: "推理强度", values: [""] + levels, selection: $thinking) {
                    levelTitle($0, compact: true).accessibilityLabel(levelTitle($0))
                }
                reasoningMenu
            }
            .accessibilityIdentifier("thinking-picker")
        }
    }

    private var reasoningMenu: some View {
        let request = levelRequest
        return FlatMenu(width: 180, triggerTreatment: .outlined, restoresTriggerFocus: true,
                        presentation: $showsReasoningMenu) {
            HStack(spacing: 4) {
                levelTitle(thinking).lineLimit(1)
                FlatDisclosureChevron(.down)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        } content: { select in
            FlatMenuItems(items: ([""] + levels).map { level in
                FlatMenuItem(id: level, title: levelTitle(level), selected: level == thinking) {
                    select {
                        guard request == levelRequest, loadedLevelRequest == request else { return }
                        thinking = level
                    }
                }
            })
        }
        .accessibilityLabel("推理强度")
        .accessibilityValue(Text("\(levelTitle(thinking))，\(showsReasoningMenu ? Text("已展开") : Text("已折叠"))"))
    }

    private func levelTitle(_ level: String, compact: Bool = false) -> Text {
        if level.isEmpty { return Text(compact ? "默认" : "运行时默认") }
        return Text(verbatim: ReasoningLevelLabel.text(for: level))
    }

    private var actions: some View {
        HStack {
            if handoffPreview != nil {
                Toggle("不携带历史", isOn: $omitHistory)
                    .toggleStyle(.checkbox)
                    .zivviFont(.caption)
                    .disabled(saving || switchingRuntime)
            }
            if saving || switchingRuntime { FlatProgressView().controlSize(.small) }
            Spacer()
            Button("取消", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(saving || switchingRuntime)
            Button(handoffPreview != nil ? "保存交接" : "保存", action: save)
                .buttonStyle(FlatControlButtonStyle(treatment: .prominent)).disabled(!canSave)
        }
    }

    private struct ModelCatalogueID: Equatable {
        let runtimeID: String
        let staged: Bool
    }

    private struct ModelRequest: Equatable {
        let catalogue: ModelCatalogueID
        let revision: Int?
        let waitsForSessionOperation: Bool
        let retry: Int
    }

    private struct LevelRequest: Equatable {
        let catalogue: ModelRequest
        let model: RuntimeModel?
        let retry: Int
    }

    private func switchRuntime(to nextRuntimeID: String) {
        if handoffPreview != nil && !editingHandoff {
            guard nextRuntimeID != catalogueRuntimeID else { return }
            handoffTargetID = nextRuntimeID == currentRuntimeID ? nil : nextRuntimeID
            let model = workspace.modelPreferences(forRuntime: nextRuntimeID).defaultModel
            modelKey = handoffTargetID == nil ? (selection.map { $0.provider + "/" + $0.modelID } ?? "") : (model?.id ?? "")
            models = []
            levels = []
            thinking = ""
            thinkingModelID = nil
            modelSearch = ""
            saveError = nil
            // Revisiting a target must wait for its new catalogue before saving.
            reloadModels += 1
            return
        }
        guard canSwitchAgent, !saving, !switchingRuntime, nextRuntimeID != currentRuntimeID else { return }
        switchingRuntime = true
        saveError = nil
        Task {
            let switched = await workspace.setSessionRuntime(nextRuntimeID, for: reference.id)
            switchingRuntime = false
            guard isCurrentSession else { return }
            if switched {
                let updated = currentReference.pendingSelection ?? currentReference.selection
                modelKey = updated.map { $0.provider + "/" + $0.modelID } ?? ""
                thinking = ""
                thinkingModelID = nil
                models = []
                levels = []
                modelError = nil
                levelError = nil
                loadedLevelRequest = nil
                reloadModels += 1
            } else {
                saveError = workspace.storageError ?? workspace.error ?? String(localized: "暂时无法切换智能体，请重试。")
            }
        }
    }

    private func save() {
        guard canSave, isCurrentSession else { return }
        saving = true
        saveError = nil
        let model = selectedModel
        let selection = model.map { RuntimeSelection(provider: $0.provider, modelID: $0.modelID, thinking: thinking.isEmpty ? nil : thinking) }
        Task {
            defer { saving = false }
            do {
                let saved: Bool
                if editingHandoff {
                    saved = await workspace.updateHandoffContext(effectiveContext, draft: effectiveDraft, for: reference.id)
                } else if let handoffPreview, let handoffTargetID {
                    saved = try await workspace.commitHandoff(handoffPreview, to: handoffTargetID, selection: selection,
                                                               modelName: model?.name, context: effectiveContext,
                                                               draft: effectiveDraft, for: reference.id)
                } else if let selection {
                    saved = await workspace.saveSelection(selection, name: model?.name, for: reference.id)
                } else { return }
                guard isCurrentSession else { return }
                if saved { close() }
                else { saveError = workspace.storageError ?? workspace.error ?? String(localized: "暂时无法应用模型配置，请重试。") }
            } catch {
                saveError = (error as? RuntimeFailure)?.detail ?? String(localized: "无法保存交接历史，请重试。")
            }
        }
    }

    private func openHandoff(editing: Bool) {
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do {
                let preview = try await workspace.prepareHandoff(for: reference.id)
                guard isCurrentSession else { return }
                editingHandoff = editing
                let pending = currentReference.handoff.flatMap { $0.delivered ? nil : $0 }
                handoffContext = pending?.context ?? ""
                handoffDraft = pending == nil ? preview.draft : pending?.draft
                omitHistory = handoffDraft?.omitsHistory ?? (pending?.context.isEmpty ?? false)
                handoffPreview = preview
            } catch {
                saveError = (error as? RuntimeFailure)?.detail ?? String(localized: "无法读取交接历史，请重试。")
            }
        }
    }

    private func loadModels(_ request: ModelRequest) async {
        guard !opensHandoff, runtimeAvailable, !request.waitsForSessionOperation, request == modelRequest else { return }
        modelError = nil
        do {
            let catalogue = request.catalogue.staged ? try await workspace.modelCatalogue(forRuntime: request.catalogue.runtimeID)
                : try await workspace.modelCatalogue(for: reference.id)
            guard !Task.isCancelled, isCurrentSession, request == modelRequest else { return }
            var seen: Set<String> = []
            models = catalogue.filter { seen.insert($0.id).inserted }
            loadedModelRequest = request
            if selectedModel == nil { modelKey = "" }
            browsing.update(catalogue: pickerCatalogue, sameCatalogue: browsingCatalogue == request.catalogue,
                            query: searchTerm, selectedModelID: selectedModel?.id)
            browsingCatalogue = request.catalogue
        } catch {
            guard !Task.isCancelled, isCurrentSession, request == modelRequest else { return }
            models = []
            modelError = (error as? RuntimeFailure)?.detail ?? String(localized: "模型目录读取失败，请检查连接设置。")
            loadedModelRequest = request
        }
    }

    private func loadLevels(_ request: LevelRequest) async {
        guard !Task.isCancelled, !request.catalogue.waitsForSessionOperation, levelRequest == request else { return }
        loadedLevelRequest = nil
        levelError = nil
        guard runtimeAvailable, let model = request.model else { return }
        do {
            let availableLevels = if let handoffTargetID {
                try await workspace.configurationOptions(forRuntime: handoffTargetID, model: model).thinkingLevels
            } else {
                try await workspace.thinkingLevels(for: reference.id, model: model)
            }
            guard !Task.isCancelled, isCurrentSession, levelRequest == request else { return }
            var seen: Set<String> = [""]
            levels = availableLevels.filter { seen.insert($0).inserted }
            let saved = selection.flatMap { $0.provider == model.provider && $0.modelID == model.modelID ? $0.thinking : nil }
            if thinkingModelID != model.id || (!thinking.isEmpty && !levels.contains(thinking)) {
                thinking = saved.flatMap { levels.contains($0) ? $0 : nil } ?? ""
            }
            thinkingModelID = model.id
            loadedLevelRequest = request
        } catch {
            guard !Task.isCancelled, isCurrentSession, levelRequest == request else { return }
            levelError = (request, (error as? RuntimeFailure)?.detail ?? String(localized: "推理强度读取失败，请重试。"))
        }
    }
}

enum ModelPickerScope: CaseIterable {
    case favorites, all

    var title: LocalizedStringKey { self == .favorites ? "收藏" : "全部" }
}

struct ModelPickerCatalogue {
    let visible: [RuntimeModel]
    let favorites: Set<String>
    let retained: Set<String>

    init(models: [RuntimeModel], preferences: WorkspaceModelPreferences, retaining: Set<String>) {
        visible = preferences.pickerModels(from: models, keeping: retaining, showAll: true)
        favorites = Set(preferences.favorites.map(\.id)).subtracting(preferences.hiddenModelIDs)
        retained = retaining
    }

    var initialScope: ModelPickerScope {
        visible.contains { favorites.contains($0.id) } ? .favorites : .all
    }

    func rows(scope: ModelPickerScope, query: String) -> [RuntimeModel] {
        let matches = visible.filter { ModelPresentation.matches($0, query: query) }
        return matches.filter { favorites.contains($0.id) }
            + matches.filter { !favorites.contains($0.id) && (scope == .all || retained.contains($0.id)) }
    }
}

struct ModelPickerBrowsingPosition {
    var scope: ModelPickerScope = .favorites
    var scopeWhileSearching: ModelPickerScope?
    var topModelID: String?

    func selectedScope(query: String) -> ModelPickerScope {
        query.isEmpty ? scope : scopeWhileSearching ?? .all
    }

    mutating func update(catalogue: ModelPickerCatalogue, sameCatalogue: Bool, query: String, selectedModelID: String?) {
        if !sameCatalogue {
            scope = catalogue.initialScope
            scopeWhileSearching = nil
        }
        let rows = catalogue.rows(scope: selectedScope(query: query), query: query)
        if sameCatalogue {
            guard let topModelID, !rows.contains(where: { $0.id == topModelID }) else { return }
        }
        topModelID = rows.first { $0.id == selectedModelID }?.id ?? rows.first?.id
    }
}

private struct PickerModelRow: View {
    let model: RuntimeModel
    let selected: Bool
    let favorite: Bool
    let showsProvider: Bool
    let showsID: Bool

    private var subtitle: String? {
        let provider = ModelPresentation.providerName(model.provider)
        switch (showsProvider, showsID) {
        case (true, true): return "\(provider) · \(model.modelID)"
        case (true, false): return provider
        case (false, true): return model.modelID
        case (false, false): return nil
        }
    }

    var body: some View {
        let snapshot = ModelPresentation.snapshot(model)
        HStack(spacing: 8) {
            ProviderLogo(provider: model.provider, model: model.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: snapshot?.name ?? model.name).lineLimit(1).truncationMode(.middle)
                    if let snapshot {
                        Text(verbatim: snapshot.displayDate)
                            .zivviFont(.caption2, design: .monospaced)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .padding(.horizontal, 5)
                            .flatSurface(ZivviTheme.mutedSurface, radius: 8)
                            .shadow(color: .black.opacity(0.07), radius: 1, y: 1)
                            .fixedSize()
                    }
                }
                if let subtitle {
                    Text(verbatim: subtitle)
                        .lineLimit(1).truncationMode(.middle)
                        .zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LightningIconView(.starFill, size: 12)
                .opacity(favorite ? 1 : 0)
            LightningIconView(.checkmark, size: 12)
                .opacity(selected ? 1 : 0)
        }
        .help("\(model.name) · \(model.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: showsProvider
            ? "\(model.name) · \(ModelPresentation.providerName(model.provider)) · \(model.id)"
            : "\(model.name) · \(model.modelID)"))
        .accessibilityValue(favorite ? Text("收藏") : Text(""))
    }
}
