import SwiftUI
import UserNotifications
import OrchestrationCore
import PiRuntimeAdapter

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, projects, providers
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .general: "通用"
        case .projects: "项目"
        case .providers: "服务商"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .providers: "cpu"
        }
    }
}

struct SettingsPanel: View {
    let workspace: WorkspaceController
    let availableSize: CGSize
    let settings: AppSettings
    let worktreesForProject: @Sendable (String) async -> [GitWorktree]?
    let close: () -> Void
    let restart: () -> Void
    @State private var section: SettingsSection
    @State private var projects: SettingsProjectState
    @State private var environmentDraft: [PiEnvironmentRow]?
    @State private var providerPage: ProviderPage
    @State private var showsRestartPrompt = false
    @State private var restartAfterPrompt = false

    init(workspace: WorkspaceController, settings: AppSettings, initialSection: SettingsSection,
         preferredProjectID: UUID?, availableSize: CGSize = .zero,
         projectState: SettingsProjectState? = nil,
         worktreesForProject: @escaping @Sendable (String) async -> [GitWorktree]? = { await GitRepositoryInspector.worktrees(in: $0) },
         close: @escaping () -> Void, restart: @escaping () -> Void) {
        self.workspace = workspace
        self.availableSize = availableSize
        self.settings = settings
        self.worktreesForProject = worktreesForProject
        self.close = close
        self.restart = restart
        _section = State(initialValue: initialSection)
        _providerPage = State(initialValue: initialSection == .providers ? .connection : .models)
        _projects = State(initialValue: projectState ?? SettingsProjectState(selectedID: preferredProjectID))
    }

    private var panelSize: CGSize {
        // Leave room around the sheet and cap its size so settings remain readable in a maximized window.
        guard availableSize.width > 0, availableSize.height > 0 else { return CGSize(width: 780, height: 460) }
        return CGSize(width: min(1080, max(1, availableSize.width - 80)),
                      height: min(760, max(1, availableSize.height - 104)))
    }

    var body: some View {
        let size = panelSize
        let horizontalInset: CGFloat = size.width < 720 ? 16 : 24
        HStack(spacing: 0) {
            SettingsNavigation(selection: $section)
                .frame(width: min(168, max(112, size.width * 0.21)))
                .background(PikachuTheme.sidebar)
            PikachuDivider(axis: .vertical)
            VStack(spacing: 0) {
                SettingsHeader(section: section, leadingInset: horizontalInset, close: close)
                PikachuDivider()
                if section == .providers {
                    HStack(spacing: 4) {
                        ForEach(ProviderPage.allCases, id: \.self) { page in
                            Button { providerPage = page } label: { Text(page.title) }
                                .buttonStyle(FlatControlButtonStyle(isOpen: providerPage == page))
                                .accessibilityAddTraits(providerPage == page ? .isSelected : [])
                                .accessibilityIdentifier("settings-pi-\(page.rawValue)")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, horizontalInset).padding(.vertical, 8)
                    .background(PikachuTheme.surface)
                    PikachuDivider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch section {
                        case .general:
                            GeneralSettingsView(settings: settings)
                        case .projects:
                            ProjectSettingsView(workspace: workspace, settings: settings, state: projects,
                                                worktreesForProject: worktreesForProject)
                        case .providers:
                            if providerPage == .models {
                                ModelSettingsView(workspace: workspace)
                            } else {
                                ProviderSettingsView(workspace: workspace, settings: settings, draft: $environmentDraft)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .focusSection()
            }
            .background(PikachuTheme.workspace)
        }
        .frame(width: size.width, height: size.height)
        .pikachuTypography(settings.interfaceFontSize)
        .accessibilityIdentifier("settings-panel")
        .onChange(of: settings.interfaceLanguage) { showsRestartPrompt = true }
        .sheet(isPresented: $showsRestartPrompt, onDismiss: finishRestartPrompt) {
            FlatConfirmation(
                request: ConfirmationRequest(
                    title: "重新启动 Pikachu？",
                    message: "语言设置已保存，重新启动 Pikachu 后生效。",
                    confirmTitle: "重新启动",
                    destructive: false,
                    cancelTitle: "稍后",
                    defaultsToCancel: workspace.restartWouldInterruptWork
                ) {
                    restartAfterPrompt = true
                    showsRestartPrompt = false
                },
                cancel: { showsRestartPrompt = false }
            )
            .presentationBackground(PikachuTheme.surface)
        }
    }

    private enum ProviderPage: String, CaseIterable {
        case models, connection
        var title: LocalizedStringResource {
            switch self {
            case .models: "Pi 模型"
            case .connection: "Pi 连接"
            }
        }
    }

    private func finishRestartPrompt() {
        guard restartAfterPrompt else { return }
        restartAfterPrompt = false
        restart()
    }
}

private struct SettingsHeader: View {
    let section: SettingsSection
    let leadingInset: CGFloat
    let close: () -> Void

    var body: some View {
        HStack {
            Text(section.title)
                .pikachuFont(.title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) {
                IconButtonLabel(systemName: "xmark", weight: .medium)
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

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatSurface(radius: 10)
    }
}

private struct SettingsNavigation: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置").pikachuFont(.title3, weight: .semibold).padding(.horizontal, 8).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .pikachuFont(.callout)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(FlatControlButtonStyle(isOpen: selection == section))
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
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsCard {
            NotificationSettings(notifications: settings.notifications)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            PikachuDivider().padding(.horizontal, 16)
            FlatPanelPicker(title: "界面语言", selection: $settings.interfaceLanguage,
                            options: InterfaceLanguage.allCases,
                            detail: "下次启动 Pikachu 时生效。") { language in
                switch language {
                case .system: Text("跟随系统")
                case .simplifiedChinese: Text(verbatim: "简体中文")
                case .english: Text(verbatim: "English")
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("interface-language")
            PikachuDivider().padding(.horizontal, 16)
            FlatPanelPicker(title: "字体大小", selection: $settings.interfaceFontSize,
                            options: InterfaceFontSize.allCases,
                            detail: "即时生效，也可使用 ⌘+ / ⌘- 调整。") { fontSize in
                Text(fontSize.title)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("interface-font-size")
        }
    }
}

private struct NotificationSettings: View {
    let notifications: TaskNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { notifications.enabled },
                set: { notifications.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("任务通知").pikachuFont(.body, weight: .semibold)
                    Text("Pikachu 在后台时，等待工具审批、任务完成或失败都会发送通知。")
                        .pikachuFont(.callout).foregroundStyle(PikachuTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(FlatToggleStyle())
            .accessibilityIdentifier("task-end-notifications")
            if notifications.enabled {
                switch notifications.authorization {
                case .denied:
                    Text("macOS 已关闭 Pikachu 的通知。").pikachuFont(.caption).foregroundStyle(.secondary)
                    Button("打开系统通知设置…", action: notifications.openSystemSettings)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                case .notDetermined:
                    Button("允许通知…", action: notifications.requestAuthorization)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                case .authorized, .provisional:
                    Text("macOS 通知已获准。").pikachuFont(.caption).foregroundStyle(.secondary)
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

@MainActor @Observable final class SettingsProjectState {
    var selectedID: UUID?
    var operationPending = false
    var feedback: [UUID: ProjectOperationFeedback] = [:]
    var configFeedback: [UUID: ProjectOperationFeedback] = [:]
    var openError: String?
    var selectedConfigDirectory: String?
    var selectedConfigProjectID: UUID?
    var selectedConfigProjectPath: String?
    var loadedWorktrees: [GitWorktree]?
    var loadedWorktreesProjectID: UUID?
    var loadedWorktreesProjectPath: String?
    var worktreeRefreshNonce = 0

    init(selectedID: UUID?) { self.selectedID = selectedID }

    func currentWorktrees(for project: ProjectRecord) -> [GitWorktree]? {
        guard loadedWorktreesProjectID == project.id,
              loadedWorktreesProjectPath == project.path else { return nil }
        return loadedWorktrees
    }

    func extraWorktrees(for project: ProjectRecord) -> [GitWorktree] {
        let canonicalRoot = WorkspaceController.canonicalPath(project.path)
        return (currentWorktrees(for: project) ?? []).filter {
            WorkspaceController.canonicalPath($0.path) != canonicalRoot
        }
    }

    func targetDirectory(for project: ProjectRecord) -> String {
        guard selectedConfigProjectID == project.id,
              selectedConfigProjectPath == project.path,
              let selected = selectedConfigDirectory else {
            return project.path
        }
        let canonicalSelected = WorkspaceController.canonicalPath(selected)
        let canonicalRoot = WorkspaceController.canonicalPath(project.path)
        if canonicalSelected == canonicalRoot {
            return project.path
        }
        if let match = extraWorktrees(for: project).first(where: {
            WorkspaceController.canonicalPath($0.path) == canonicalSelected
        }) {
            return match.path
        }
        return project.path
    }

    func selectConfigDirectory(_ path: String, for project: ProjectRecord) {
        selectedConfigProjectID = project.id
        selectedConfigProjectPath = project.path
        selectedConfigDirectory = path
    }
}

private struct ProjectSettingsView: View {
    private struct ProjectIdentityPath: Equatable {
        let id: UUID
        let path: String
    }

    private struct ProjectWorktreeLookup: Equatable {
        let id: UUID
        let path: String
        let nonce: Int
    }

    let workspace: WorkspaceController
    let settings: AppSettings
    let state: SettingsProjectState
    let worktreesForProject: @Sendable (String) async -> [GitWorktree]?
    @State private var showsConfigDirectories = false

    private var project: ProjectRecord? {
        workspace.state.projects.first { $0.id == state.selectedID } ?? workspace.state.projects.first
    }
    private var actionDisabled: Bool { state.operationPending || !workspace.canManageProjects }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let project {
                let worktrees = state.currentWorktrees(for: project)
                let extra = state.extraWorktrees(for: project)
                let target = state.targetDirectory(for: project)
                let savingConfig = workspace.isSavingProjectPiConfig(for: target)
                let canEditConfig = workspace.canChangeProjectPiConfig(for: target) && !state.operationPending

                SettingsProjectList(projects: workspace.state.projects, selectedID: project.id) {
                    state.selectedID = $0
                }
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: project.displayName).pikachuFont(.headline)
                            .accessibilityAddTraits(.isHeader)
                        PikachuDivider()
                        LabeledContent {
                            Text(verbatim: project.path)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("工作目录")
                        }
                        Text("运行时可在此目录读取内容、修改文件和执行命令。")
                            .pikachuFont(.callout).foregroundStyle(PikachuTheme.secondaryText)
                        PikachuDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { workspace.isProjectPiConfigTrusted(for: target) },
                                set: { newValue in
                                    setPiConfigTrusted(newValue, projectID: project.id, directory: target)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("加载项目提供的 Pi 配置").pikachuFont(.body, weight: .semibold)
                                    Text("开启后，Pi 启动该目录会话时会加载项目提供的设置和系统提示。")
                                        .pikachuFont(.callout).foregroundStyle(PikachuTheme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(FlatToggleStyle())
                            .disabled(!canEditConfig)
                            .accessibilityIdentifier("project-pi-config-trust-toggle")

                            if !extra.isEmpty {
                                let title = directoryLabel(for: target, project: project, worktrees: worktrees)
                                let expansionState = showsConfigDirectories ? Text("已展开") : Text("已折叠")
                                HStack(spacing: 8) {
                                    Text("配置目录")
                                        .foregroundStyle(PikachuTheme.secondaryText)
                                    Spacer(minLength: 8)
                                    FlatMenu(width: 340, triggerTreatment: .outlined, presentation: $showsConfigDirectories) {
                                        HStack(spacing: 8) {
                                            title.lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            FlatDisclosureChevron(.down)
                                        }
                                        .foregroundStyle(PikachuTheme.primaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: 260)
                                    } content: { select in
                                        let canonicalRoot = WorkspaceController.canonicalPath(project.path)
                                        let canonicalTarget = WorkspaceController.canonicalPath(target)
                                        let rootBranch = worktrees?.first {
                                            WorkspaceController.canonicalPath($0.path) == canonicalRoot
                                        }?.branch
                                        directoryMenuRow(
                                            title: rootBranch.map { Text("主目录 · \($0)") } ?? Text("主目录"),
                                            path: project.path,
                                            selected: canonicalTarget == canonicalRoot
                                        ) {
                                            select { state.selectConfigDirectory(project.path, for: project) }
                                        }
                                        ForEach(extra) { tree in
                                            let canonicalTree = WorkspaceController.canonicalPath(tree.path)
                                            directoryMenuRow(
                                                title: tree.branch.map { Text(verbatim: $0) } ?? Text("分离的 HEAD"),
                                                path: tree.path,
                                                selected: canonicalTarget == canonicalTree
                                            ) {
                                                select { state.selectConfigDirectory(tree.path, for: project) }
                                            }
                                        }
                                    }
                                    .accessibilityLabel("配置目录")
                                    .accessibilityValue(Text("\(title)，\(expansionState)"))
                                    .accessibilityIdentifier("project-pi-config-directory-picker")
                                }
                            }

                            Text(verbatim: target)
                                .pikachuFont(.caption)
                                .foregroundStyle(PikachuTheme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("project-pi-config-directory-path")

                            if savingConfig {
                                Text("正在保存该目录的项目配置设置…")
                                    .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                            } else if !workspace.canChangeProjectPiConfig(for: target), workspace.storageError == nil {
                                Text("该目录有会话正在启动或运行，完成后可修改。")
                                    .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                            }

                            if let error = state.configFeedback[project.id]?.message ?? workspace.storageError {
                                FeedbackBanner(text: error, warning: true)
                            }
                        }
                        PikachuDivider()
                        HStack {
                            Spacer(minLength: 0)
                            Button("刷新会话") { perform(for: project.id) { await workspace.discover(project.id) } }
                            Button("重新定位项目…") {
                                perform(for: project.id) {
                                    guard let url = await settings.pickProjectFromSettings(current: project.path) else { return nil }
                                    return await workspace.relocateProject(project.id, to: url)
                                }
                            }
                        }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(actionDisabled)
                        if let feedback = state.feedback[project.id] {
                            FeedbackBanner(text: feedback.message, warning: feedback.warning)
                        }
                    }
                    .padding(16)
                }
            } else {
                SettingsCard {
                    HStack {
                        Text("尚无项目。").foregroundStyle(PikachuTheme.secondaryText)
                        Spacer()
                        Button("打开项目…", action: openProject)
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .disabled(actionDisabled)
                    }
                    .padding(16)
                }
            }
            if let error = state.openError { FeedbackBanner(text: error, warning: true) }
        }
        .onAppear {
            state.selectedConfigDirectory = nil
            state.selectedConfigProjectID = nil
            state.selectedConfigProjectPath = nil
        }
        .onChange(of: project.map { ProjectIdentityPath(id: $0.id, path: $0.path) }) { _, current in
            state.selectedConfigDirectory = current?.path
            state.selectedConfigProjectID = current?.id
            state.selectedConfigProjectPath = current?.path
            state.loadedWorktrees = nil
            state.loadedWorktreesProjectID = nil
            state.loadedWorktreesProjectPath = nil
        }
        .task(id: project.map { ProjectWorktreeLookup(id: $0.id, path: $0.path, nonce: state.worktreeRefreshNonce) }) {
            guard let project else { return }
            let lookup = ProjectWorktreeLookup(id: project.id, path: project.path, nonce: state.worktreeRefreshNonce)
            let result = await worktreesForProject(lookup.path)
            guard !Task.isCancelled,
                  let current = self.project,
                  current.id == lookup.id,
                  current.path == lookup.path else { return }
            state.loadedWorktreesProjectID = lookup.id
            state.loadedWorktreesProjectPath = lookup.path
            state.loadedWorktrees = result
        }
    }

    private func directoryLabel(for target: String, project: ProjectRecord, worktrees: [GitWorktree]?) -> Text {
        let canonicalRoot = WorkspaceController.canonicalPath(project.path)
        let canonicalTarget = WorkspaceController.canonicalPath(target)
        if canonicalTarget == canonicalRoot {
            let rootBranch = worktrees?.first {
                WorkspaceController.canonicalPath($0.path) == canonicalRoot
            }?.branch
            return rootBranch.map { Text("主目录 · \($0)") } ?? Text("主目录")
        }
        if let tree = worktrees?.first(where: { WorkspaceController.canonicalPath($0.path) == canonicalTarget }) {
            return tree.branch.map { Text(verbatim: $0) } ?? Text("分离的 HEAD")
        }
        return Text(verbatim: URL(fileURLWithPath: target).lastPathComponent)
    }

    private func directoryMenuRow(title: Text, path: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    title.lineLimit(1)
                    Text(verbatim: path)
                        .pikachuFont(.caption)
                        .foregroundStyle(PikachuTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .pikachuFont(.caption, weight: .semibold)
                        .foregroundStyle(PikachuTheme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setPiConfigTrusted(_ trusted: Bool, projectID: UUID, directory: String) {
        guard workspace.canChangeProjectPiConfig(for: directory), !state.operationPending else { return }
        state.configFeedback[projectID] = nil
        Task {
            let failure = await workspace.setProjectPiConfigTrusted(trusted, forProject: projectID, directory: directory)
            if let failure {
                state.configFeedback[projectID] = failure
                if workspace.storageError == nil {
                    state.worktreeRefreshNonce += 1
                }
            }
        }
    }

    private func perform(for id: UUID, action: @escaping @MainActor () async -> ProjectOperationFeedback?) {
        guard !actionDisabled else { return }
        state.feedback[id] = nil
        state.configFeedback[id] = nil
        state.operationPending = true
        Task {
            defer { state.operationPending = false }
            state.feedback[id] = await action()
            state.worktreeRefreshNonce += 1
        }
    }

    private func openProject() {
        guard !actionDisabled else { return }
        state.openError = nil
        state.operationPending = true
        Task {
            defer { state.operationPending = false }
            guard let url = await settings.pickProjectFromSettings() else { return }
            state.selectedID = await workspace.addProject(url, createInitialSession: false)
            if state.selectedID == nil || workspace.storageError != nil {
                state.openError = workspace.storageError ?? workspace.error ?? String(localized: "无法打开项目。")
            }
        }
    }
}

private struct SettingsProjectList: View {
    let projects: [ProjectRecord]
    let selectedID: UUID
    let select: (UUID) -> Void

    var body: some View {
        SettingsCard {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(projects) { project in
                        let isSelected = project.id == selectedID
                        VStack(spacing: 3) {
                            Button { select(project.id) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: project.displayName)
                                            .pikachuFont(.body, weight: .semibold).lineLimit(1)
                                        Text(verbatim: project.path)
                                            .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .pikachuFont(.caption, weight: .semibold)
                                            .foregroundStyle(PikachuTheme.accentText)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(FlatControlButtonStyle(isOpen: isSelected))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityIdentifier("settings-project-\(project.id)")
                            .help(project.path)
                            if project.id != projects.last?.id {
                                PikachuDivider().padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 136)
                .padding(6)
            }
        }
    }
}

private struct ProviderSettingsView: View {
    let workspace: WorkspaceController
    @Bindable var settings: AppSettings
    @Binding var draft: [PiEnvironmentRow]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pi").pikachuFont(.headline)
                .accessibilityAddTraits(.isHeader)
            SettingsCard {
                PiRuntimeSettings(settings: settings).padding(16)
            }
            SettingsCard {
                PiTrustedExtensions(settings: settings).padding(16)
            }
            SettingsCard {
                PiEnvironmentEditor(settings: settings, draft: $draft).padding(16)
            }
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        .disabled(workspace.isShuttingDown || workspace.hasPendingExecutionControls)
    }
}

private struct PiRuntimeSettings: View {
    @Bindable var settings: AppSettings
    @State private var hasInvalidSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行环境").pikachuFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Pi 可执行文件").accessibilityHidden(true)
                    TextField("Pi 可执行文件", text: $settings.piPath)
                        .flatInputSurface()
                    Button("选择 Pi…") { settings.choosePi() }
                }
                PikachuDivider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Node 所在目录").accessibilityHidden(true)
                    TextField("Node 所在目录", text: $settings.nodeDirectory)
                        .flatInputSurface()
                }
                PikachuDivider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .firstTextBaseline) {
                    Text("工具搜索目录").pikachuFont(.body, weight: .semibold)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(settings.toolSearchPaths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Text(verbatim: path)
                                    .pikachuFont(.callout, design: .monospaced)
                                    .lineLimit(1).truncationMode(.middle).help(path)
                                Button {
                                    settings.toolSearchPaths.removeAll { $0 == path }
                                } label: {
                                    Label("移除 \(path)", systemImage: "minus.circle").labelStyle(.iconOnly)
                                        .pikachuFont(.caption)
                                }
                                .buttonStyle(FlatControlButtonStyle())
                                .help("移除 \(path)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("添加工具目录…", action: addDirectories)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("add-pi-tool-directory")
                }
            }
            Text("可添加受信任的工具目录，例如 /opt/homebrew/bin。下次启动 Pi 时生效，不影响当前运行。")
                .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
            if hasInvalidSelection {
                FeedbackBanner(text: String(localized: "工具目录必须是绝对路径，且不能包含冒号。"), warning: true)
            }
            Text("认证复用 Pi 配置。").pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
        }
    }

    private func addDirectories() {
        let paths = settings.pickToolDirectories()
        guard !paths.isEmpty else { return }
        let valid = paths.filter(PiConfiguration.isValidToolSearchPath)
        hasInvalidSelection = valid.count != paths.count
        var seen = Set(settings.toolSearchPaths)
        settings.toolSearchPaths += valid.filter { seen.insert($0).inserted }
    }
}

private struct PiTrustedExtensions: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("受信任的扩展").pikachuFont(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("所选扩展由自主执行加载。")
                        .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Button("添加信任的 Pi 扩展…") { settings.chooseExtension() }
                    .fixedSize(horizontal: true, vertical: false)
            }
            ForEach(settings.extensionPaths, id: \.self) { path in
                HStack {
                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button("移除") { settings.extensionPaths.removeAll { $0 == path } }
                }
                .pikachuFont(.caption)
            }
        }
    }
}

private struct PiEnvironmentRow: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

private struct PiEnvironmentEditor: View {
    let settings: AppSettings
    @Binding var draft: [PiEnvironmentRow]?
    @State private var revealsValues = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("环境变量").pikachuFont(.headline).accessibilityAddTraits(.isHeader)
            if let rows = Binding($draft), settings.piEnvironmentLoaded {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        TextField("变量名", text: row.name)
                            .autocorrectionDisabled()
                            .flatInputSurface()
                        Group {
                            if revealsValues {
                                TextField("变量值", text: row.value).autocorrectionDisabled()
                            } else {
                                SecureField("变量值", text: row.value)
                            }
                        }
                        .flatInputSurface()
                        Button {
                            draft?.removeAll { $0.id == row.wrappedValue.id }
                        } label: {
                            Label("移除变量", systemImage: "minus.circle").labelStyle(.iconOnly)
                                .pikachuFont(.caption)
                        }
                        .buttonStyle(FlatControlButtonStyle())
                        .help("移除变量")
                    }
                    .pikachuFont(.callout, design: .monospaced)
                }
                HStack {
                    Button("添加变量") { draft?.append(.init(name: "", value: "")) }
                    if !rows.wrappedValue.isEmpty {
                        Button {
                            revealsValues.toggle()
                        } label: {
                            Text(revealsValues ? "遮蔽变量值" : "显示变量值")
                        }
                    }
                    Spacer()
                    Button("保存环境变量", action: save)
                        .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                        .disabled(parsedValues() == settings.piEnvironment)
                }
                .disabled(settings.piEnvironmentUpdating)
            }
            Text("保存后，在下次启动 Pi 子进程时传入。")
                .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
            if let error = validationError ?? settings.piEnvironmentError {
                FeedbackBanner(text: error, warning: true)
                if !settings.piEnvironmentLoaded {
                    Button("重试读取环境变量") { Task { await settings.reloadPiEnvironment(); loadDraft() } }
                        .disabled(settings.piEnvironmentUpdating)
                }
            }
        }
        .task { loadDraft() }
    }

    private func loadDraft() {
        if draft == nil, settings.piEnvironmentLoaded {
            draft = settings.piEnvironment.keys.sorted().map { key in
                PiEnvironmentRow(name: key, value: settings.piEnvironment[key] ?? "")
            }
        }
    }

    private func parsedValues() -> [String: String]? {
        var values: [String: String] = [:]
        for row in draft ?? [] {
            guard let key = PiConfiguration.environmentKey(row.name),
                  values[key] == nil, !row.value.utf8.contains(0) else { return nil }
            values[key] = row.value
        }
        return values
    }

    private func save() {
        guard let values = parsedValues() else {
            validationError = String(localized: "请检查变量名。名称必须有效且唯一，PATH 和 PI_CODING_AGENT_DIR 由应用管理。")
            return
        }
        validationError = nil
        Task { _ = await settings.savePiEnvironment(values) }
    }
}
