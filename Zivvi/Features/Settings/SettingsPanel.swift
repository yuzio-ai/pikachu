import SwiftUI
import UserNotifications
import AgentRuntimeCore
import OrchestrationCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, projects, providers, archived
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .general: "通用"
        case .projects: "项目"
        case .providers: LocalizedStringResource("settings.section.agents", defaultValue: "智能体",
                                                 comment: "Title of the settings section for managing agents")
        case .archived: "已归档"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .providers: "cpu"
        case .archived: "archivebox"
        }
    }
}

struct ProviderConnectionRequest: Equatable {
    let runtimeID: String
    let sequence: Int

    static func hasDestination(for runtimeID: String, agents: [RuntimeAgentProfile]) -> Bool {
        agents.contains { $0.id == runtimeID }
    }
}

struct SettingsPanelNavigation {
    var section: SettingsSection {
        didSet { if section != oldValue { connectionRequest = nil } }
    }
    var selectedAgentID: String? {
        didSet { if selectedAgentID != oldValue { connectionRequest = nil } }
    }
    private(set) var connectionRequest: ProviderConnectionRequest?
    private var lastConnectionSequence = 0

    init(section: SettingsSection, connectionRequest: ProviderConnectionRequest?, agents: [RuntimeAgentProfile]) {
        self.section = section
        openConnection(connectionRequest, agents: agents)
    }

    mutating func openConnection(_ request: ProviderConnectionRequest?, agents: [RuntimeAgentProfile]) {
        guard let request, request.sequence > lastConnectionSequence,
              ProviderConnectionRequest.hasDestination(for: request.runtimeID, agents: agents) else { return }
        lastConnectionSequence = request.sequence
        section = .providers
        selectedAgentID = request.runtimeID
        connectionRequest = request
    }

    mutating func consumeConnection(_ request: ProviderConnectionRequest) -> Bool {
        guard connectionRequest == request else { return false }
        connectionRequest = nil
        return true
    }

    mutating func agentRemoved(_ agentID: String) {
        if selectedAgentID == agentID { selectedAgentID = nil }
    }
}

struct SettingsPanel: View {
    private enum ScrollAnchor { case top }

    let workspace: WorkspaceController
    let availableSize: CGSize
    let settings: AppSettings
    @Binding private var providerConnectionRequest: ProviderConnectionRequest?
    let worktreesForProject: @Sendable (String) async -> [GitWorktree]?
    let projectDeleted: (UUID) -> Void
    let openArchivedSession: (UUID) -> Void
    let close: () -> Void
    let restart: () -> Void
    @State private var navigation: SettingsPanelNavigation
    @State private var projects: SettingsProjectState
    @State private var agentPresentations: [String: ACPAgentSettingsPresentation]
    @State private var showsAddAgentSheet = false
    @State private var showsRestartPrompt = false
    @State private var restartAfterPrompt = false

    init(workspace: WorkspaceController, settings: AppSettings, initialSection: SettingsSection,
         preferredProjectID: UUID?, availableSize: CGSize = .zero,
         providerConnectionRequest: Binding<ProviderConnectionRequest?> = .constant(nil),
         projectState: SettingsProjectState? = nil,
         worktreesForProject: @escaping @Sendable (String) async -> [GitWorktree]? = { await GitRepositoryInspector.worktrees(in: $0) },
         projectDeleted: @escaping (UUID) -> Void = { _ in },
         openArchivedSession: @escaping (UUID) -> Void = { _ in },
         close: @escaping () -> Void, restart: @escaping () -> Void) {
        self.workspace = workspace
        self.availableSize = availableSize
        self.settings = settings
        _providerConnectionRequest = providerConnectionRequest
        self.worktreesForProject = worktreesForProject
        self.projectDeleted = projectDeleted
        self.openArchivedSession = openArchivedSession
        self.close = close
        self.restart = restart
        _navigation = State(initialValue: SettingsPanelNavigation(section: initialSection,
                                                                  connectionRequest: providerConnectionRequest.wrappedValue,
                                                                  agents: settings.acpAgents))
        _projects = State(initialValue: projectState ?? SettingsProjectState(selectedID: preferredProjectID))
        _agentPresentations = State(initialValue: Dictionary(uniqueKeysWithValues: settings.acpAgents.map {
            ($0.id, ACPAgentSettingsPresentation())
        }))
    }

    static let maximumPanelWidth: CGFloat = 1600
    static let maximumPanelHeight: CGFloat = 1060
    static let panelInset: CGFloat = 72
    static let maximumReadingWidth: CGFloat = 880

    static func panelSize(for availableSize: CGSize) -> CGSize {
        // Keep uniform room around the sheet and cap its size only on very large displays.
        guard availableSize.width > 0, availableSize.height > 0 else { return CGSize(width: 780, height: 460) }
        return CGSize(width: min(maximumPanelWidth, max(1, availableSize.width - panelInset)),
                      height: min(maximumPanelHeight, max(1, availableSize.height - panelInset)))
    }

    static func navigationWidth(for panelWidth: CGFloat) -> CGFloat {
        min(216, max(136, panelWidth * 0.20))
    }

    private var panelSize: CGSize {
        Self.panelSize(for: availableSize)
    }

    private var section: SettingsSection { navigation.section }
    private var selectedAgentID: String? {
        settings.acpAgents.first { $0.id == navigation.selectedAgentID }?.id
            ?? settings.defaultRuntimeID ?? settings.acpAgents.first?.id
    }

    var body: some View {
        let size = panelSize
        let horizontalInset: CGFloat = size.width < 720 ? 16 : 24
        let contentWidth = size.width - Self.navigationWidth(for: size.width) - horizontalInset * 2
        let typography = ZivviTypography(size: settings.interfaceFontSize)
        let compactRows = contentWidth < 32 * typography.pointSize(for: .body)
        let currentProject = projects.selectedProject(in: workspace.state.projects)
        HStack(spacing: 0) {
            SettingsNavigation(selection: $navigation.section)
                .frame(width: Self.navigationWidth(for: size.width))
            ZivviDivider(axis: .vertical)
            VStack(spacing: 0) {
                SettingsHeader(section: section, leadingInset: horizontalInset, close: close)
                ZivviDivider()
                if section == .providers {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(settings.acpAgents) { agent in
                                    agentTabButton(runtimeID: agent.id, name: agent.name, enabled: agent.enabled)
                                        .accessibilityIdentifier("settings-agent-\(agent.id)")
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            showsAddAgentSheet = true
                        } label: {
                            LightningLabel("添加智能体…", icon: .plus, size: 13)
                        }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(workspace.isShuttingDown || workspace.hasPendingExecutionControls)
                        .help("添加 ACP 智能体（如 Antigravity CLI）")
                        .accessibilityHint("添加支持 ACP v1 的编程智能体")
                        .accessibilityIdentifier("settings-add-agent")
                    }
                    .padding(.horizontal, horizontalInset).padding(.vertical, 8)
                    ZivviDivider()
                }
                if section == .projects, let currentProject {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsProjectPicker(projects: workspace.state.projects, project: currentProject) { projects.selectedID = $0 }
                            .padding(.vertical, 10)
                        SettingsDivider()
                    }
                    .frame(maxWidth: Self.maximumReadingWidth, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .frame(maxWidth: .infinity)
                }
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch section {
                            case .general:
                                GeneralSettingsView(workspace: workspace, settings: settings)
                            case .projects:
                                ProjectSettingsView(workspace: workspace, settings: settings, state: projects,
                                                    worktreesForProject: worktreesForProject, projectDeleted: projectDeleted)
                            case .archived:
                                ArchivedSessionsSettings(workspace: workspace, openSession: openArchivedSession)
                            case .providers:
                                if let selectedAgentID, let presentation = agentPresentations[selectedAgentID] {
                                    ACPAgentSettingsView(
                                        workspace: workspace,
                                        settings: settings,
                                        agentID: selectedAgentID,
                                        presentation: presentation,
                                        connectionRequest: navigation.connectionRequest, scroll: scroll,
                                        consumeConnection: consumeConnection
                                    ) {
                                        agentPresentations.removeValue(forKey: selectedAgentID)
                                        navigation.agentRemoved(selectedAgentID)
                                    }
                                    .id(selectedAgentID)
                                }
                            }
                        }
                        .frame(maxWidth: Self.maximumReadingWidth, alignment: .leading)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .id(ScrollAnchor.top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .focusSection()
                    .onChange(of: currentProject?.id) { _, _ in
                        if section == .projects { scroll.scrollTo(ScrollAnchor.top, anchor: .top) }
                    }
                    .onChange(of: section) { _, selection in
                        if selection == .archived { scroll.scrollTo(ScrollAnchor.top, anchor: .top) }
                    }
                    .onChange(of: providerConnectionRequest) { _, request in
                        navigation.openConnection(request, agents: settings.acpAgents)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(ZivviTheme.pageBackground)
        .environment(\.settingsCompactRows, compactRows)
        .zivviTypography(settings.interfaceFontSize)
        .accessibilityIdentifier("settings-panel")
        .onChange(of: settings.acpAgents.map(\.id)) { _, ids in
            agentPresentations = Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, agentPresentations[id] ?? ACPAgentSettingsPresentation())
            })
        }
        .onChange(of: settings.interfaceLanguage) { showsRestartPrompt = true }
        .sheet(isPresented: $showsAddAgentSheet) {
            AddACPAgentSheet(settings: settings, existingAgents: settings.acpAgents) { profile in
                settings.addACPAgent(profile)
                workspace.setPreferences(settings.preferences)
                if agentPresentations[profile.id] == nil { agentPresentations[profile.id] = ACPAgentSettingsPresentation() }
                navigation.selectedAgentID = profile.id
                showsAddAgentSheet = false
            } onCancel: {
                showsAddAgentSheet = false
            }
            .zivviTypography(settings.interfaceFontSize)
            .presentationBackground(ZivviTheme.pageBackground)
        }
        .sheet(isPresented: $showsRestartPrompt, onDismiss: finishRestartPrompt) {
            FlatConfirmation(
                request: ConfirmationRequest(
                    title: "重新启动 Zivvi？",
                    message: "语言设置已保存，重新启动 Zivvi 后生效。",
                    confirmTitle: "重新启动",
                    destructive: false,
                    cancelTitle: "稍后",
                    defaultsToCancel: workspace.terminationWouldInterruptWork
                ) {
                    restartAfterPrompt = true
                    showsRestartPrompt = false
                },
                cancel: { showsRestartPrompt = false }
            )
            .presentationBackground(ZivviTheme.pageBackground)
        }
    }

    private func agentTabButton(runtimeID: String, name: String, enabled: Bool) -> some View {
        let selected = selectedAgentID == runtimeID
        let isDefault = settings.defaultRuntimeID == runtimeID && !settings.acpAgents.isEmpty
        return Button {
            navigation.selectedAgentID = runtimeID
        } label: {
            HStack(spacing: 5) {
                CodingAgentLabel(runtimeID: runtimeID, displayName: name, agents: settings.acpAgents)
                if isDefault {
                    Text("新会话默认")
                        .zivviFont(.caption2, weight: .medium)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            .opacity(enabled ? 1 : 0.55)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: selected, inset: false, cornerRadius: 8))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func finishRestartPrompt() {
        guard restartAfterPrompt else { return }
        restartAfterPrompt = false
        restart()
    }

    private func consumeConnection(_ request: ProviderConnectionRequest) -> Bool {
        navigation.consumeConnection(request)
    }
}

private struct SettingsHeader: View {
    let section: SettingsSection
    let leadingInset: CGFloat
    let close: () -> Void

    var body: some View {
        HStack {
            Text(section.title)
                .zivviFont(.title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) {
                IconButtonLabel(systemName: "xmark", weight: .medium)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .keyboardShortcut(.cancelAction)
            .help("关闭设置")
            .accessibilityLabel("关闭设置")
            .accessibilityIdentifier("close-settings")
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 14)
        .frame(height: 50)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text(title).zivviFont(.headline).accessibilityAddTraits(.isHeader)
                if let detail { Text(detail).settingsDetailLines() }
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        ZivviDivider(color: ZivviTheme.subtleDivider)
    }
}

extension View {
    func settingsDetailLines() -> some View {
        zivviFont(.callout).foregroundStyle(ZivviTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func settingsRowInsets() -> some View { padding(.vertical, ZivviSpacing.dialogItemGap) }
}

private struct SettingsNavigation: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置").zivviFont(.title3, weight: .semibold).padding(.horizontal, 8).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    HStack(spacing: 10) {
                        Group {
                            switch section {
                            case .general: LightningBrandIconView(.settings, size: 15)
                            case .projects: LightningBrandIconView(.files, size: 15)
                            case .providers: LightningBrandIconView(.model, size: 15)
                            case .archived: LightningIconView(.archivebox, size: 15)
                            }
                        }
                        .frame(width: 16)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == section ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: selection == section, inset: false))
                .accessibilityAddTraits(selection == section ? .isSelected : [])
                .accessibilityIdentifier("settings-\(section.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .focusSection()
    }
}

private struct GeneralSettingsView: View {
    let workspace: WorkspaceController
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            SettingsGroup("通知") {
                NotificationSettings(notifications: settings.notifications).settingsRowInsets()
            }
            SettingsGroup("界面与文件") {
                FlatPanelPicker(title: "界面语言", selection: $settings.interfaceLanguage,
                                options: InterfaceLanguage.allCases,
                                detail: "下次启动 Zivvi 时生效。") { language in
                    switch language {
                    case .system: Text("跟随系统")
                    case .simplifiedChinese: Text(verbatim: "简体中文")
                    case .english: Text(verbatim: "English")
                    }
                }
                .settingsRowInsets()
                .accessibilityIdentifier("interface-language")
                SettingsDivider()
                FlatPanelPicker(title: "字体大小", selection: $settings.interfaceFontSize,
                                options: InterfaceFontSize.allCases,
                                detail: "即时生效，也可使用 ⌘+ / ⌘- 调整。") { fontSize in
                    Text(fontSize.title)
                }
                .settingsRowInsets()
                .accessibilityIdentifier("interface-font-size")
                SettingsDivider()
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                    FlatPanelPicker(title: "文件打开方式", selection: Binding(
                        get: { settings.fileOpen.preference },
                        set: { settings.fileOpen.preference = $0 }
                    ), options: FileOpenPreference.allCases,
                       detail: "点击对话中的文件或代码行时使用；找不到所选应用时改用系统默认。") { preference in
                        Text(preference.title)
                    }
                    .accessibilityIdentifier("file-open-preference")
                    if settings.fileOpen.preference == .custom {
                        TextField("命令，例如 code -g {path}:{line}", text: Binding(
                            get: { settings.fileOpen.customCommand },
                            set: { settings.fileOpen.customCommand = $0 }
                        ))
                        .flatInputSurface()
                        .accessibilityIdentifier("file-open-command")
                    }
                }
                .settingsRowInsets()
            }
            SettingsGroup("输入与对话") {
                ComposerPreferenceSettings(settings: settings)
            }
            SettingsGroup("额度") {
                Toggle(isOn: $settings.showsAntigravityQuota) {
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                        Text("显示 Antigravity 额度").zivviFont(.body, weight: .semibold)
                        Text("开启后，通过本机 Antigravity CLI 查询额度并显示在底部状态栏。")
                            .zivviFont(.callout).foregroundStyle(ZivviTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(FlatToggleStyle())
                .settingsRowInsets()
                .accessibilityIdentifier("show-antigravity-quota")
            }
            SessionTitleSettingsView(workspace: workspace, settings: settings)
        }
    }

}

private struct ComposerPreferenceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        FlatPanelPicker(title: "发送快捷键", selection: $settings.composerSendShortcut,
                        options: ComposerSendShortcut.allCases,
                        detail: "\(Text("立即应用于任务输入框。")) \(Text(settings.composerSendShortcut.keyHint))") {
            Text($0.title)
        }
        .settingsRowInsets()
        .accessibilityIdentifier("composer-send-shortcut")
    }
}

private struct NotificationSettings: View {
    let notifications: TaskNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            Toggle(isOn: Binding(
                get: { notifications.enabled },
                set: { notifications.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    Text("任务通知").zivviFont(.body, weight: .semibold)
                    Text("等待工具审批、任务完成或失败时播放提示音；Zivvi 在后台时还会发送系统通知。")
                        .zivviFont(.callout).foregroundStyle(ZivviTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(FlatToggleStyle())
            .accessibilityIdentifier("task-end-notifications")
            if notifications.enabled {
                switch notifications.authorization {
                case .denied:
                    Text("macOS 已关闭 Zivvi 的通知。").zivviFont(.caption).foregroundStyle(.secondary)
                    Button("打开系统通知设置…", action: notifications.openSystemSettings)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                case .notDetermined:
                    Button("允许通知…", action: notifications.requestAuthorization)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                case .authorized, .provisional:
                    if notifications.soundSetting == .disabled {
                        Text("macOS 通知已获准，但提示音已关闭。")
                            .zivviFont(.caption).foregroundStyle(.secondary)
                        Button("打开系统通知设置…", action: notifications.openSystemSettings)
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    } else {
                        Text("macOS 通知已获准。").zivviFont(.caption).foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
                if notifications.requestFailed {
                    FeedbackBanner(text: String(localized: "无法请求通知权限。请重试。"), warning: true)
                }
            }
        }
        .task { await notifications.refreshAuthorization() }
    }
}
