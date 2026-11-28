import OrchestrationCore
import SwiftUI

struct SessionTitleSettingsView: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    @State private var draft: SessionTitleSettings
    @State private var models: [SessionTitleModel]?
    @State private var catalogueFailed = false
    @State private var catalogueRequest = 0
    @State private var saving = false
    @State private var saveError = false

    init(workspace: WorkspaceController, settings: AppSettings) {
        self.workspace = workspace
        self.settings = settings
        _draft = State(initialValue: workspace.sessionTitleSettings)
    }

    private var rulesTooLong: Bool { draft.rules.utf8.count > SessionTitleSettings.maximumRuleBytes }

    var body: some View {
        SettingsGroup("会话标题", detail: "启用模型生成后，命名规则和首条消息的正文会发送给标题模型。") {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                FlatPanelPicker(title: "生成方式", selection: $draft.mode, options: SessionTitleSettings.Mode.allCases) { mode in
                    switch mode {
                    case .automatic: Text("自动")
                    case .specified: Text("指定模型")
                    case .disabled: Text("关闭模型生成")
                    }
                }
                .accessibilityIdentifier("session-title-mode")
                switch draft.mode {
                case .automatic:
                    Text("跟随首个支持纯文本生成的智能体。没有可用模型时使用首条消息标题。")
                        .settingsDetailLines()
                case .specified:
                    modelPicker.task(id: catalogueRequest) { await loadModels() }
                case .disabled:
                    Text("使用首条消息或附件作为标题。")
                        .settingsDetailLines()
                }
            }
            .settingsRowInsets()
            if draft.mode != .disabled {
                SettingsDivider()
                rulesEditor.settingsRowInsets()
            }
            if draft != workspace.sessionTitleSettings || saveError || saving {
                SettingsDivider()
                saveControls.settingsRowInsets()
            }
        }
        .disabled(!workspace.initialized || workspace.isShuttingDown || saving)
        .onChange(of: workspace.sessionTitleSettings) { previous, saved in
            if draft == previous { draft = saved }
        }
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
            Text("命名规则").zivviFont(.body).accessibilityHidden(true)
            Text("例如使用简体中文，按「模块 · 具体事项」命名。留空时使用默认规则。")
                .settingsDetailLines()
            TextEditor(text: $draft.rules)
                .zivviFont(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 96)
                .flatInputSurface()
                .accessibilityLabel("命名规则")
                .accessibilityIdentifier("session-title-rules")
            if rulesTooLong {
                Text("命名规则不能超过 4 KB。").settingsDetailLines().foregroundStyle(ZivviTheme.warningText)
            }
        }
    }

    private var modelPicker: some View {
        let choices = Dictionary(uniqueKeysWithValues: (models ?? []).map { ($0.id, $0) })
        let selectedID = Binding<String?>(get: { draft.model?.id }, set: { id in
            if let id, let model = choices[id] { draft.model = model }
        })
        return VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            FlatPanelPicker(title: "标题模型", selection: selectedID, options: (models ?? []).map { Optional($0.id) },
                            maximumMenuHeight: 280) { id in
                if let choice = id.flatMap({ choices[$0] }) ?? draft.model {
                    let name = workspace.runtimeDisplayName(for: choice.runtimeID)
                    return Text(verbatim: "\(choice.model.name) · \(name)")
                }
                return Text("选择模型")
            }
            .disabled(models?.isEmpty != false)
            .accessibilityIdentifier("session-title-model")
            if catalogueFailed {
                HStack {
                    Text("无法读取标题模型。").settingsDetailLines()
                    Button("重试") { catalogueRequest += 1 }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                }
            } else if let models {
                if let selected = draft.model, !models.contains(where: { $0.id == selected.id }) {
                    Text("所选模型当前不可用。将使用首条消息标题。").settingsDetailLines()
                } else if models.isEmpty {
                    Text("没有可用的标题模型。需要 Claude Agent ACP 0.88 起的 0.x 版本、Claude Code 2.1.293 或更新版本，以及 API 或云服务认证。")
                        .settingsDetailLines()
                }
            } else {
                FlatProgressView("正在读取标题模型…").controlSize(.small)
            }
        }
    }

    private var saveControls: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if saveError { FeedbackBanner(text: String(localized: "无法保存会话标题设置。请重试。"), warning: true) }
            HStack {
                if saving { FlatProgressView("正在保存会话标题设置…").controlSize(.small) }
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .disabled((draft.mode != .disabled && rulesTooLong) || (draft.mode == .specified && draft.model == nil))
                    .accessibilityIdentifier("session-title-save")
            }
        }
    }

    private func loadModels() async {
        catalogueFailed = false
        models = nil
        do {
            let catalogue = try await settings.titleModelCatalogue()
            guard !Task.isCancelled else { return }
            var seen: Set<String> = []
            models = catalogue.filter { seen.insert($0.id).inserted }
        } catch {
            if !Task.isCancelled { catalogueFailed = true }
        }
    }

    private func save() {
        saving = true
        saveError = false
        let current = draft
        Task {
            defer { saving = false }
            if await workspace.setSessionTitleSettings(current) {
                draft = workspace.sessionTitleSettings
            } else {
                saveError = true
            }
        }
    }
}
