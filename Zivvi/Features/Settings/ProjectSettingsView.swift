import SwiftUI
import OrchestrationCore

@MainActor @Observable final class SettingsProjectState {
    var selectedID: UUID?
    var operationPending = false
    var nameDrafts: [UUID: String] = [:]
    var nameFailures: [UUID: String] = [:]
    var savingNames: Set<UUID> = []
    var deletionFailures: [UUID: String] = [:]
    var feedback: [UUID: ProjectOperationFeedback] = [:]
    var configFeedback: [UUID: ProjectOperationFeedback] = [:]
    var defaultsSaveFailures: Set<UUID> = []
    var openError: String?
    var selectedConfigDirectory: String?
    var selectedConfigProjectID: UUID?
    var selectedConfigProjectPath: String?
    var loadedWorktrees: [GitWorktree]?
    var loadedWorktreesProjectID: UUID?
    var loadedWorktreesProjectPath: String?
    var worktreeRefreshNonce = 0

    init(selectedID: UUID?) { self.selectedID = selectedID }

    func selectedProject(in projects: [ProjectRecord]) -> ProjectRecord? {
        projects.first { $0.id == selectedID } ?? projects.first
    }

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

struct SettingsProjectPicker: View {
    let projects: [ProjectRecord]
    let project: ProjectRecord
    let selectProject: (UUID) -> Void
    @State private var isOpen = false

    var body: some View {
        SettingsControlRow {
            Text("当前项目")
        } control: {
            FlatMenu(width: 340, triggerTreatment: .outlined, presentation: $isOpen) {
                HStack(spacing: 8) {
                    LightningIconView(.folder, size: 14)
                    Text(verbatim: project.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    FlatDisclosureChevron(.down)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(width: 220)
            } content: { select in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(projects) { option in
                            ProjectSettingsChoice(title: Text(verbatim: option.displayName), path: option.path,
                                                  selected: option.id == project.id) {
                                select { selectProject(option.id) }
                            }
                            .accessibilityIdentifier("settings-project-\(option.id)")
                        }
                    }
                }
                .frame(maxHeight: 240)
                .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityLabel("当前项目")
            .accessibilityValue(Text("\(project.displayName)，\(project.path)，\(isOpen ? Text("已展开") : Text("已折叠"))"))
            .accessibilityIdentifier("settings-project-picker")
            .help(project.path)
        }
    }
}

struct ProjectSettingsView: View {
    private struct WorktreeLookup: Equatable {
        let id: UUID
        let path: String
        let nonce: Int
    }

    let workspace: WorkspaceController
    let settings: AppSettings
    let state: SettingsProjectState
    let worktreesForProject: @Sendable (String) async -> [GitWorktree]?
    let projectDeleted: (UUID) -> Void
    @State private var showsConfigDirectories = false
    @State private var deletion: ProjectDeletionSummary?
    @Environment(\.settingsCompactRows) private var compactRows

    private var project: ProjectRecord? { state.selectedProject(in: workspace.state.projects) }
    private var actionDisabled: Bool { state.operationPending || !workspace.canManageProjects }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            if let project {
                SettingsGroup("项目资料") {
                    ProjectNameRow(project: project, workspace: workspace, state: state)
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                        Text("工作目录")
                        Text(verbatim: project.path).settingsDetailLines().textSelection(.enabled)
                        Text("运行时可在此目录读取内容、修改文件和执行命令。").settingsDetailLines()
                    }
                    .settingsRowInsets()
                }
                configurationGroup(for: project)
                maintenanceGroup(for: project)
                ProjectDeletionSection(reason: workspace.projectDeletionBlockReason(for: project.id),
                                       failure: state.deletionFailures[project.id], disabled: state.operationPending) {
                    state.deletionFailures[project.id] = nil
                    deletion = workspace.projectDeletionSummary(for: project.id)
                }
            } else {
                SettingsControlRow {
                    Text("尚无项目。").foregroundStyle(ZivviTheme.secondaryText)
                } control: {
                    Button("打开项目…", action: openProject)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(actionDisabled)
                }
                .settingsRowInsets()
            }
            if let error = state.openError { FeedbackBanner(text: error, warning: true) }
        }
        .onChange(of: project?.id, initial: true) { _, id in
            state.selectedID = id
        }
        .task(id: project.map { WorktreeLookup(id: $0.id, path: $0.path, nonce: state.worktreeRefreshNonce) }) {
            guard let project else { return }
            let lookup = WorktreeLookup(id: project.id, path: project.path, nonce: state.worktreeRefreshNonce)
            let result = await worktreesForProject(lookup.path)
            guard !Task.isCancelled, self.project?.id == lookup.id, self.project?.path == lookup.path,
                  state.worktreeRefreshNonce == lookup.nonce else { return }
            state.loadedWorktreesProjectID = lookup.id
            state.loadedWorktreesProjectPath = lookup.path
            state.loadedWorktrees = result
        }
        .onChange(of: project.map { WorktreeLookup(id: $0.id, path: $0.path, nonce: 0) }, initial: true) { _, current in
            showsConfigDirectories = false
            state.selectedConfigDirectory = current?.path
            state.selectedConfigProjectID = current?.id
            state.selectedConfigProjectPath = current?.path
            state.loadedWorktrees = nil
            state.loadedWorktreesProjectID = nil
            state.loadedWorktreesProjectPath = nil
        }
        .sheet(item: $deletion) { summary in
            FlatConfirmation(request: ConfirmationRequest(
                title: "删除项目「\(summary.name)」？",
                message: "\(summary.path)\n\n将移除此项目及其在 Zivvi 中的偏好、会话条目和草稿。共有 \(summary.sessionCount) 个会话，\(summary.draftCount) 个会话含草稿。\n\n磁盘上的项目文件和智能体的远端历史会保留。",
                confirmTitle: "删除项目", defaultsToCancel: true
            ) {
                deletion = nil
                delete(summary)
            }, cancel: { deletion = nil })
            .presentationBackground(ZivviTheme.pageBackground)
        }
    }

    private func configurationGroup(for project: ProjectRecord) -> some View {
        let target = state.targetDirectory(for: project)
        let worktrees = state.currentWorktrees(for: project)
        let extra = state.extraWorktrees(for: project)
        return SettingsGroup("项目资源") {
            SettingsControlRow {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    Text("配置目录")
                    Text(verbatim: target)
                        .settingsDetailLines()
                        .textSelection(.enabled)
                        .accessibilityIdentifier("project-resource-directory-path")
                }
            } control: {
                if !extra.isEmpty {
                    let title = directoryLabel(for: target, project: project, worktrees: worktrees)
                    FlatMenu(width: 340, triggerTreatment: .outlined, presentation: $showsConfigDirectories) {
                        HStack(spacing: 8) {
                            title.lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            FlatDisclosureChevron(.down)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(width: 156)
                    } content: { select in
                        ScrollView {
                            VStack(spacing: 3) {
                                ProjectSettingsChoice(title: directoryLabel(for: project.path, project: project, worktrees: worktrees),
                                                      path: project.path, selected: target == project.path) {
                                    select { state.selectConfigDirectory(project.path, for: project) }
                                }
                                ForEach(extra) { tree in
                                    ProjectSettingsChoice(title: tree.branch.map { Text(verbatim: $0) } ?? Text("分离的 HEAD"),
                                                          path: tree.path, selected: target == tree.path) {
                                        select { state.selectConfigDirectory(tree.path, for: project) }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .accessibilityLabel("配置目录")
                    .accessibilityValue(Text("\(title)，\(showsConfigDirectories ? Text("已展开") : Text("已折叠"))"))
                    .accessibilityIdentifier("project-resource-directory-picker")
                }
            }
            .settingsRowInsets()
            SettingsDivider()
            ProjectResourceSourcesView(directory: URL(fileURLWithPath: target, isDirectory: true))
                .id(project.id)
        }
    }

    private func maintenanceGroup(for project: ProjectRecord) -> some View {
        SettingsGroup("项目维护") {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                let layout = compactRows ? AnyLayout(VStackLayout(alignment: .trailing)) : AnyLayout(HStackLayout())
                layout {
                    Button("重新定位项目…") {
                        perform(for: project.id) {
                            guard let url = await settings.pickProjectFromSettings(current: project.path) else { return nil }
                            return await workspace.relocateProject(project.id, to: url)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .disabled(actionDisabled)
                if let feedback = state.feedback[project.id] {
                    FeedbackBanner(text: feedback.message, warning: feedback.warning)
                }
            }
            .settingsRowInsets()
        }
    }

    private func delete(_ summary: ProjectDeletionSummary) {
        state.operationPending = true
        Task {
            defer { state.operationPending = false }
            if let failure = await workspace.deleteProject(summary) {
                state.deletionFailures[summary.id] = failure.message
            } else {
                state.nameDrafts[summary.id] = nil
                state.nameFailures[summary.id] = nil
                state.configFeedback[summary.id] = nil
                state.feedback[summary.id] = nil
                state.defaultsSaveFailures.remove(summary.id)
                if state.selectedID == summary.id { state.selectedID = workspace.state.projects.first?.id }
                projectDeleted(summary.id)
            }
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

private struct ProjectSettingsChoice: View {
    let title: Text
    let path: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    title.lineLimit(1)
                    Text(verbatim: path)
                        .settingsDetailLines()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if selected {
                    LightningIconView(.checkmark, size: 13)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: selected))
        .accessibilityLabel(Text("\(title)，\(path)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(path)
    }
}

private struct ProjectNameRow: View {
    let project: ProjectRecord
    let workspace: WorkspaceController
    let state: SettingsProjectState

    private var draft: String? { state.nameDrafts[project.id] }
    private var saving: Bool { state.savingNames.contains(project.id) }
    private var exitAction: (() -> Void)? {
        guard draft != nil, !saving else { return nil }
        return { cancel() }
    }
    private var name: Binding<String> {
        Binding(get: { draft ?? project.displayName }, set: { value in
            state.nameDrafts[project.id] = value == project.displayName ? nil : value
            state.nameFailures[project.id] = nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            SettingsControlRow {
                Text("显示名称").accessibilityHidden(true)
            } control: {
                TextField("显示名称", text: name)
                    .flatInputSurface()
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("settings-project-display-name")
                    .onSubmit { save() }
                    .onExitCommand(perform: exitAction)
                    .disabled(saving || state.operationPending || workspace.isShuttingDown)
            }
            if saving {
                FlatProgressView("正在保存显示名称…").controlSize(.small)
            } else if draft != nil {
                SettingsControlRow {
                    Text("留空后保存可恢复目录名。").settingsDetailLines()
                } control: {
                    HStack {
                        Button("取消", action: cancel)
                        Button("保存", action: save)
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .accessibilityIdentifier("settings-save-project-display-name")
                    }
                }
                .disabled(state.operationPending)
            }
            if let failure = state.nameFailures[project.id] { FeedbackBanner(text: failure, warning: true) }
        }
        .settingsRowInsets()
    }

    private func cancel() {
        state.nameDrafts[project.id] = nil
        state.nameFailures[project.id] = nil
    }

    private func save() {
        guard let draft, !saving, !state.operationPending else { return }
        let id = project.id
        guard !draft.contains(where: \.isNewline) else {
            state.nameFailures[id] = String(localized: "显示名称不能包含换行。")
            return
        }
        state.savingNames.insert(id)
        Task {
            defer { state.savingNames.remove(id) }
            if await workspace.setProjectDisplayName(draft, for: id) {
                state.nameDrafts[id] = nil
                state.nameFailures[id] = nil
            } else {
                state.nameFailures[id] = workspace.storageError ?? String(localized: "无法保存显示名称。请重试。")
            }
        }
    }
}

private struct ProjectDeletionSection: View {
    let reason: String?
    let failure: String?
    let disabled: Bool
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsDivider()
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                SettingsControlRow {
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                        Text("删除项目").zivviFont(.headline).accessibilityAddTraits(.isHeader)
                        Text("从 Zivvi 删除，保留磁盘文件。").settingsDetailLines()
                    }
                } control: {
                    Button(role: .destructive, action: confirm) {
                        LightningLabel("删除项目…", icon: .trash, size: 13)
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .disabled(reason != nil || disabled)
                    .accessibilityIdentifier("settings-delete-project")
                }
                if let failure { FeedbackBanner(text: failure, warning: true) }
                if let reason, reason != failure { Text(verbatim: reason).settingsDetailLines() }
            }
            .settingsRowInsets()
        }
    }
}
