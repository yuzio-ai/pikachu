import SwiftUI
import AppKit
import AgentRuntimeCore
import OrchestrationCore

struct WorkbenchView: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let quitRequest: Int
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    @State private var modal: WorkbenchModal?
    @State private var preparingToQuit = false
    @State private var sidebarFilter = SessionSidebarFilter()
    @State private var choosesSessionProject = false
    @State private var gitStore = GitStatusStore()

    private var isConfigurationModal: Bool {
        if case .configuration = modal { return true }
        return false
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SessionSidebar(workspace: workspace, settings: settings, filter: $sidebarFilter,
                           openProject: openProject, createSession: requestNewSession,
                           openSettings: presentRuntimeSettings)
                .navigationSplitViewColumnWidth(min: 205, ideal: 286, max: 340)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if let activeID = workspace.activeID, activeID != workspace.state.selectedSessionID {
                    ActiveRunBanner(workspace: workspace, presentInteraction: presentInteraction)
                }
                if let viewed = workspace.viewed {
                    SessionDetail(workspace: workspace, settings: settings, presentation: viewed,
                                  gitStore: gitStore, isModelSheetOpen: isConfigurationModal,
                                  configure: presentConfiguration, openSettings: presentRuntimeSettings)
                        .id(viewed.id)
                } else {
                    ContentUnavailableView {
                        Label("选择一个项目", systemImage: "folder")
                    } description: {
                        Text("打开本地项目后，可创建会话或只读浏览历史。")
                    } actions: {
                        Button("打开项目…", systemImage: "folder.badge.plus", action: openProject)
                            .buttonStyle(.glass)
                            .disabled(!workspace.canManageProjects)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let message = workspace.storageError {
                    HStack {
                        Text(message)
                        if workspace.initialized { Button("重试保存") { Task { _ = await workspace.flush() } } }
                    }
                    .buttonStyle(.glass)
                    .font(.caption).foregroundStyle(.red).padding(12)
                    .glassEffect(.regular.tint(.red.opacity(0.14)), in: .rect(cornerRadius: 12))
                }
                if let error = workspace.error { FeedbackBanner(text: error, warning: true) }
                if let notice = workspace.notice { FeedbackBanner(text: notice, warning: false) }
                PendingInteractionBar(workspace: workspace, present: presentInteraction)
            }
            .background {
                LinearGradient(
                    colors: [.indigo.opacity(0.18), .purple.opacity(0.05), PikachuTheme.lightningYellow.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
        }
        .background {
            WorkbenchTitlebar(sidebarVisibility: $sidebarVisibility)
                .frame(width: 0, height: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let path = workspace.selectedProject?.path {
                gitStore.refresh(directory: path, force: true)
            }
        }
        .onChange(of: workspace.completedTurnSequence) { _, _ in
            if let path = workspace.lastCompletedTurnDirectory {
                gitStore.refresh(directory: path, force: true)
            }
        }
        .onChange(of: workspace.newSessionRequest) { requestNewSession() }
        .onChange(of: workspace.openProjectRequest) { openProject() }
        .confirmationDialog("选择新会话的项目", isPresented: $choosesSessionProject, titleVisibility: .visible) {
            ForEach(workspace.state.projects) { project in
                Button(project.name) { createSession(in: project.id) }
                    .accessibilityIdentifier("new-session-\(project.id)")
            }
        }
        .onChange(of: settings.preferences) { _, value in workspace.setPreferences(value) }
        .onChange(of: workspace.configurationRequest) { _, _ in presentConfiguration() }
        .onChange(of: quitRequest) { _, _ in
            // AppKit's default terminate action is blocked while a sheet is open.
            // Retire the request first, dismiss our sheet, then use the existing
            // application delegate's confirmation and supervised shutdown path.
            guard !preparingToQuit else { return }
            preparingToQuit = true
            modal = nil
            Task {
                await workspace.active?.cancelInteractions()
                try? await Task.sleep(for: .milliseconds(200))
                // terminateLater spins AppKit's event loop. Invoke termination
                // from a run-loop timer, never a Swift task or main-queue block:
                // either would prevent that nested loop from running cleanup.
                preparingToQuit = false
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0,
                              inModes: [.default, .modalPanel, .eventTracking])
            }
        }
        .onChange(of: workspace.active?.interactions.first?.id) { _, _ in
            if case .interaction(let request, _, _) = modal, workspace.active?.interactions.contains(where: { $0.id == request.id }) != true { modal = nil }
            if modal == nil && workspace.activeID == workspace.state.selectedSessionID { presentInteraction() }
        }
        .onChange(of: modal?.id) { _, value in
            if value == nil && workspace.activeID == workspace.state.selectedSessionID { presentInteraction() }
        }
        .sheet(item: $modal) { value in
            switch value {
            case .configuration(let reference): ConfigurationSheet(workspace: workspace, reference: reference)
            case .interaction(let request, let controller, let title): InteractionView(request: request, controller: controller, sessionTitle: title).id(request.id)
            case .runtimeSettings:
                VStack(spacing: 0) {
                    RuntimeSettings(workspace: workspace, settings: settings)
                    Divider()
                    HStack {
                        Spacer()
                        Button("完成") { modal = nil }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    }.padding(12)
                }
            }
        }
    }
    private func openProject() {
        guard !preparingToQuit, modal == nil, workspace.canManageProjects, let url = settings.pickProject() else { return }
        Task {
            if let project = await workspace.addProject(url), workspace.selected?.projectID == project {
                sidebarFilter.reveal(in: project)
                sidebarVisibility = .all
            }
        }
    }
    private func requestNewSession() {
        guard !preparingToQuit, modal == nil, workspace.canManageProjects, !workspace.state.projects.isEmpty else { return }
        if let project = sidebarFilter.projectID ?? workspace.selectedProject?.id {
            createSession(in: project)
        } else {
            choosesSessionProject = true
        }
    }
    private func createSession(in project: UUID) {
        Task {
            if let id = await workspace.createSession(in: project), workspace.state.selectedSessionID == id {
                sidebarFilter.reveal(in: project)
                sidebarVisibility = .all
            }
        }
    }

    private func presentRuntimeSettings() {
        guard !preparingToQuit, modal == nil else { return }
        modal = .runtimeSettings
    }

    private func presentConfiguration() {
        guard !preparingToQuit, modal == nil, let reference = workspace.selected, !workspace.busy else { return }
        modal = .configuration(reference)
    }
    private func presentInteraction() {
        guard !preparingToQuit, let controller = workspace.active, let request = controller.interactions.first else { return }
        let title = workspace.state.sessions.first { $0.id == workspace.activeID }?.title ?? "执行会话"
        modal = .interaction(request, controller, title)
    }
}

struct ProjectLocationView: View {
    let project: ProjectRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name).font(.headline)
            Text("工作目录").foregroundStyle(.secondary)
            Text(project.path).textSelection(.enabled)
            Text("运行时可在此目录读取内容、修改文件和执行命令。")
                .foregroundStyle(.secondary)
        }.font(.callout).frame(width: 320, alignment: .leading).padding(16)
    }
}

private struct RuntimeSettings: View {
    let workspace: WorkspaceController
    @Bindable var settings: AppSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("连接设置").font(.headline)
                TextField("Pi 可执行文件", text: $settings.piPath)
                    .padding(7).glassEffect(in: .rect(cornerRadius: 8))
                Button("选择 Pi…") { settings.choosePi() }
                TextField("Node 所在目录", text: $settings.nodeDirectory)
                    .padding(7).glassEffect(in: .rect(cornerRadius: 8))
                TextField("代理（可留空）", text: $settings.proxy)
                    .padding(7).glassEffect(in: .rect(cornerRadius: 8))
                Button("添加信任的 Pi 扩展…") { settings.chooseExtension() }
                ForEach(settings.extensionPaths, id: \.self) { path in
                    HStack { Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).help(path); Spacer(); Button("移除") { settings.extensionPaths.removeAll { $0 == path } } }.font(.caption)
                }
                Text("只有自动模式会加载所选扩展。更改在下次建立执行连接时生效。认证复用 Pi 配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.plain).buttonStyle(.glass).padding(16)
        }
        .frame(width: 360, height: 390)
        .disabled(workspace.busy || workspace.active?.commandPending == true)
    }
}

struct SessionDetail: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let presentation: SessionPresentation
    let gitStore: GitStatusStore
    let isModelSheetOpen: Bool
    let configure: () -> Void
    let openSettings: () -> Void
    @State private var confirmSend = false
    @State private var pendingPrompt: UserPrompt?
    @State private var confirmReplaceDraft = false
    @State private var editCandidate: TranscriptItem?

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    var canSend: Bool {
        guard workspace.initialized, workspace.storageError == nil, !workspace.busy, !presentation.loading,
              presentation.loadError == nil, presentation.executionIssue == nil, presentation.history?.incompleteTail != true,
              reference?.submissions.contains(where: \.needsReview) != true else { return false }
        if workspace.activeID == presentation.id, presentation.controller.connection == .connected {
            if reference?.pendingSelection != nil, presentation.controller.phase.isActive || !presentation.controller.queue.isEmpty { return false }
            return presentation.controller.canSend
        }
        return presentation.controller.draftPrompt.hasContent
    }
    var modeDisabled: Bool {
        workspace.busy || workspace.storageError != nil ||
            (workspace.activeID == presentation.id &&
             (presentation.controller.phase.isActive || presentation.controller.commandPending || !presentation.controller.queue.isEmpty))
    }
    var currentModel: ComposerModel? {
        if let pending = reference?.pendingSelection {
            return .init(provider: pending.provider, name: reference?.pendingModelName ?? pending.modelID,
                         thinking: pending.thinking ?? "默认", pending: true)
        }
        if let live = presentation.controller.session, let provider = live.provider {
            return .init(provider: provider, name: live.model, thinking: live.thinking, pending: false)
        }
        if let saved = reference?.selection ?? presentation.history?.selection {
            return .init(provider: saved.provider, name: reference?.modelName ?? saved.modelID,
                         thinking: saved.thinking ?? "默认", pending: false)
        }
        return nil
    }
    private func addFiles() {
        let controller = presentation.controller
        let projectID = reference?.projectID
        let directory = workspace.state.projects.first { $0.id == projectID }.map { URL(fileURLWithPath: $0.path) }
        Task {
            let files = await settings.pickFiles(in: directory)
            for file in files.map(\.standardizedFileURL) where !controller.draftFiles.contains(file) {
                controller.draftFiles.append(file)
            }
        }
    }
    private func send() {
        let prompt = presentation.controller.draftPrompt
        if workspace.requiresStopBeforeSend {
            pendingPrompt = prompt
            confirmSend = true
        } else { Task { await workspace.send(presentation.id, submitted: prompt) } }
    }
    private func handleEditUserMessage(_ item: TranscriptItem) {
        let hasExistingDraft = !presentation.controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !presentation.controller.draftFiles.isEmpty
        if hasExistingDraft {
            editCandidate = item
            confirmReplaceDraft = true
        } else {
            applyEdit(item)
        }
    }
    private func applyEdit(_ item: TranscriptItem) {
        presentation.controller.draft = item.editableText
        presentation.controller.draftFiles = item.editableFiles
        workspace.focusInput()
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(workspace: workspace, presentation: presentation, gitStore: gitStore)
            VStack(spacing: 0) {
                if presentation.loading { ProgressView("正在读取历史…").padding(8) }
                if let error = presentation.loadError {
                    FeedbackBanner(text: error, warning: true)
                    Button("重新读取") { Task { await workspace.refreshHistory(presentation.id) } }
                        .buttonStyle(.glass).padding(8)
                }
                if presentation.history?.incompleteTail == true { FeedbackBanner(text: "文件尾部尚未写完。已显示完整记录，当前禁止执行；请稍后重新读取。", warning: true) }
                if let issue = presentation.executionIssue { FeedbackBanner(text: issue, warning: true) }
                if let warnings = presentation.history?.warnings, !warnings.isEmpty { FeedbackBanner(text: warnings.joined(separator: "\n"), warning: true) }
                TranscriptView(
                    items: presentation.controller.transcript,
                    diagnosticSession: presentation.id.uuidString,
                    historyLoading: presentation.loading,
                    showsEmptyState: presentation.loadError == nil && presentation.executionIssue == nil,
                    onEditUserMessage: handleEditUserMessage
                ).id(presentation.id)
                if !presentation.controller.extensionStatus.isEmpty { ExtensionStatusView(controller: presentation.controller) }
                if let failure = presentation.controller.failure {
                    FeedbackBanner(text: failure.detail, warning: true)
                    if presentation.controller.connection == .disconnected && workspace.storageError == nil &&
                        (failure.kind == .setup || failure.kind == .unsupportedVersion) {
                        Button("打开连接设置…", action: openSettings)
                            .buttonStyle(.glass).font(.caption).padding(.vertical, 4)
                    }
                }
                if let notice = presentation.controller.notice { FeedbackBanner(text: notice, warning: false) }
                if let reference, !reference.submissions.isEmpty { SubmissionReview(workspace: workspace, reference: reference) }
                ComposerView(
                    controller: presentation.controller,
                    workspace: workspace,
                    agentMode: reference?.executionMode ?? .automatic,
                    activeMode: workspace.activeMode,
                    isViewedSessionActive: workspace.activeID == presentation.id,
                    isReadOnlyHistory: presentation.executionIssue != nil,
                    modeDisabled: modeDisabled,
                    model: currentModel,
                    isModelSheetOpen: isModelSheetOpen,
                    onPickFiles: addFiles,
                    onMode: { mode in Task { await workspace.setAgentMode(mode, for: presentation.id) } },
                    onModel: configure,
                    onSend: send,
                    sendEnabled: canSend,
                    focusSignal: workspace.inputFocusRequest
                )
            }
            .frame(maxWidth: .infinity)
        }
        .alert("停止当前任务并发送？", isPresented: $confirmSend) {
            Button("停止当前任务并发送", role: .destructive) {
                if let prompt = pendingPrompt {
                    pendingPrompt = nil
                    Task { await workspace.send(presentation.id, stopCurrent: true, submitted: prompt) }
                }
            }
            Button("返回当前任务") { pendingPrompt = nil; if let id = workspace.activeID { Task { await workspace.select(id) } } }
            Button("取消", role: .cancel) { pendingPrompt = nil }
        } message: { Text("目标草稿会保留。旧任务停止且受管进程清理确认后，将连接目标会话并发送。") }
        .alert("替换当前草稿？", isPresented: $confirmReplaceDraft) {
            Button("替换草稿", role: .destructive) {
                if let item = editCandidate {
                    editCandidate = nil
                    applyEdit(item)
                }
            }
            Button("取消", role: .cancel) { editCandidate = nil }
        } message: { Text("当前输入框已有未发送的草稿，替换为所选消息内容？") }
    }
}

struct SessionHeader: View {
    let workspace: WorkspaceController
    let presentation: SessionPresentation
    let gitStore: GitStatusStore
    @State private var showsProjectLocation = false

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    var project: ProjectRecord? { workspace.state.projects.first { $0.id == reference?.projectID } }
    var isViewedActive: Bool { workspace.activeID == presentation.id }
    var activeController: SessionController? { isViewedActive ? presentation.controller : nil }

    private var connectionStatus: (kind: ConnectionBadgeKind, description: String) {
        if let active = activeController {
            switch active.connection {
            case .disconnected:
                break
            case .connecting:
                return (.progress, String(localized: "正在建立连接…"))
            case .closing:
                return (.progress, String(localized: "正在清理受管进程…"))
            case .blocked:
                return (.warning, String(localized: "进程清理待核实 · 已阻止继续执行"))
            case .connected:
                switch active.phase {
                case .idle:
                    return (.connected, String(localized: "已连接 · 就绪"))
                case .running:
                    return (.connected, String(localized: "已连接 · 正在执行"))
                case .waitingInput:
                    return (.warning, String(localized: "已连接 · 等待扩展回复"))
                case .retrying:
                    return (.connected, String(localized: "已连接 · 正在重试"))
                case .compacting:
                    return (.connected, String(localized: "已连接 · 正在压缩上下文"))
                case .stopping:
                    return (.progress, String(localized: "已连接 · 正在停止…"))
                case .uncertain:
                    return (.warning, String(localized: "执行结果待核实"))
                }
            }
        }
        if reference?.submissions.contains(where: \.needsReview) == true {
            return (.warning, String(localized: "存在发送状态待核实的记录"))
        }
        if presentation.history?.incompleteTail == true || presentation.loadError != nil {
            return (.warning, String(localized: "历史读取异常或尾部未写完"))
        }
        if reference?.file == nil {
            return (.disconnected, String(localized: "未连接 · 独立草稿"))
        }
        return (.disconnected, String(localized: "未连接 · 历史浏览"))
    }

    private var activeStatusLabel: String? {
        guard let active = activeController else { return nil }
        switch active.connection {
        case .disconnected: return nil
        case .connecting: return String(localized: "正在连接…")
        case .closing: return String(localized: "正在清理进程…")
        case .blocked: return String(localized: "进程待核实")
        case .connected:
            switch active.phase {
            case .idle: return nil
            case .running: return String(localized: "执行中")
            case .waitingInput: return String(localized: "等待扩展回复")
            case .retrying: return String(localized: "正在重试")
            case .compacting: return String(localized: "正在压缩")
            case .stopping: return String(localized: "正在停止…")
            case .uncertain: return String(localized: "结果待核实")
            }
        }
    }

    private var sessionTitle: some View {
        let title = reference?.title ?? String(localized: "会话")
        return Text(title)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .help(title)
            .accessibilityAddTraits(.isHeader)
    }

    private func projectButton(_ project: ProjectRecord) -> some View {
        Button { showsProjectLocation.toggle() } label: {
            Text(project.name)
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(project.path)
        .accessibilityLabel("项目 \(project.name)")
        .accessibilityHint("显示工作目录")
        .popover(isPresented: $showsProjectLocation) {
            ProjectLocationView(project: project)
        }
    }

    private var identitySection: some View {
        let status = connectionStatus
        return HStack(spacing: 8) {
            ConnectionStatusIcon(kind: status.kind)
                .help(status.description)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("runtime-status")
                .accessibilityLabel("会话连接状态")
                .accessibilityValue(status.description)
            if let project {
                projectButton(project)
                Text("/")
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            sessionTitle
        }
    }

    private var executionActionsSection: some View {
        HStack(spacing: 8) {
            if let label = activeStatusLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(activeController?.connection == .blocked || activeController?.phase == .uncertain || activeController?.phase == .waitingInput ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let active = activeController, active.connection != .disconnected {
                if active.connection == .blocked || active.phase == .uncertain {
                    Button("结束受管进程", role: .destructive) {
                        Task { _ = await workspace.disconnect(force: true) }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(workspace.busy || active.commandPending)
                    .fixedSize()
                } else if active.phase.isActive || !active.queue.isEmpty {
                    Button("停止", systemImage: "stop") {
                        Task { await workspace.stop() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(workspace.busy || !active.canStop)
                    .help("停止（⌘.）")
                    .accessibilityIdentifier("stop-run")
                    .fixedSize()
                }
            }
            Menu {
                if let active = activeController, active.connection == .connected || active.connection == .connecting {
                    Button("断开连接") { Task { _ = await workspace.disconnect() } }
                        .disabled(workspace.busy || active.commandPending)
                }
                if let project {
                    Button("刷新 Git 状态") { gitStore.refresh(directory: project.path, force: true) }
                    Button("显示工作目录…") { showsProjectLocation = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("会话操作")
            .accessibilityLabel("会话操作")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    identitySection
                        .frame(minWidth: 190, alignment: .leading)
                    Spacer(minLength: 8)
                    if let project {
                        GitSummaryBar(project: project, gitStore: gitStore)
                            .fixedSize()
                    }
                    executionActionsSection
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        identitySection
                        Spacer(minLength: 6)
                        executionActionsSection
                            .fixedSize()
                    }
                    if let project {
                        HStack {
                            GitSummaryBar(project: project, gitStore: gitStore)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
        }
        .task(id: project?.path) {
            if let path = project?.path {
                gitStore.refresh(directory: path)
            }
        }
    }
}

private enum ConnectionBadgeKind {
    case connected, disconnected, progress, warning
}

private struct ConnectionStatusIcon: View {
    let kind: ConnectionBadgeKind
    var body: some View {
        Group {
            switch kind {
            case .connected:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            case .disconnected:
                Circle()
                    .stroke(Color.secondary.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            case .progress:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 12, height: 12)
            }
        }
    }
}

private struct GitSummaryBar: View {
    let project: ProjectRecord
    let gitStore: GitStatusStore
    @State private var showsBranchPopover = false
    @State private var showsAheadPopover = false
    @State private var showsChangesPopover = false

    private var state: GitDirectoryState {
        gitStore.state(for: project.path)
    }

    private var snapshot: GitRepositorySnapshot? {
        guard let snap = state.snapshot,
              snap.directoryPath == GitRepositoryInspector.normalizedPath(project.path) else { return nil }
        return snap
    }

    private var branchText: String {
        if let snapshot { return snapshot.branch.displayName }
        switch state {
        case .notRepository: return String(localized: "非 Git 仓库")
        case .directoryMissing: return String(localized: "目录缺失")
        case .failed: return String(localized: "读取失败")
        case .idle, .loading: return "—"
        case .loaded: return "—"
        }
    }

    private var aheadText: String {
        snapshot?.ahead.displayText ?? "—"
    }

    private var addedText: String {
        snapshot.map { "+\($0.changes.addedCount)" } ?? "—"
    }

    private var deletedText: String {
        snapshot.map { "−\($0.changes.deletedCount)" } ?? "—"
    }

    private var changesAccessibilityValue: String {
        guard let snapshot else { return String(localized: "变更文件数未知") }
        return String(localized: "新增 \(snapshot.changes.addedCount) 个文件，删除 \(snapshot.changes.deletedCount) 个文件，共 \(snapshot.changes.totalCount) 个变更文件")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { showsBranchPopover.toggle() } label: {
                HStack(spacing: 5) {
                    GitBranchIcon()
                        .foregroundStyle(.secondary)
                    Text(branchText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(snapshot == nil ? .secondary : .primary)
            .help(branchText)
            .accessibilityLabel("Git 分支")
            .accessibilityValue(branchText)
            .popover(isPresented: $showsBranchPopover) {
                branchPopover
            }

            Divider().frame(height: 12)

            Button { showsAheadPopover.toggle() } label: {
                HStack(spacing: 4) {
                    GitCommitIcon()
                        .foregroundStyle(.secondary)
                    Text(aheadText)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("领先本地 upstream 提交数：\(aheadText)")
            .accessibilityLabel("领先本地 upstream 提交数")
            .accessibilityValue(aheadText)
            .popover(isPresented: $showsAheadPopover) {
                aheadPopover
            }

            Button { showsChangesPopover.toggle() } label: {
                HStack(spacing: 5) {
                    FileTextIcon()
                        .foregroundStyle(.secondary)
                    Text(addedText)
                        .foregroundStyle(snapshot == nil ? Color.secondary : Color.green)
                        .monospacedDigit()
                    Text(deletedText)
                        .foregroundStyle(snapshot == nil ? Color.secondary : Color.red)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help("仓库文件变化")
            .accessibilityLabel("仓库文件变化")
            .accessibilityValue(changesAccessibilityValue)
            .popover(isPresented: $showsChangesPopover) {
                changesPopover
            }
        }
        .font(.caption)
    }

    private var branchPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("分支信息", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.mini) }
            }
            if let snapshot {
                switch snapshot.branch {
                case .branch(let name, let hasCommits):
                    Text("当前分支：\(name)").textSelection(.enabled)
                    if !hasCommits {
                        Text("仓库尚无提交记录（unborn HEAD）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .detached(let sha):
                    Text("分离 HEAD：\(sha)").textSelection(.enabled)
                }
                Text("Checkout：\(snapshot.checkoutRoot)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail)
                    .foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var aheadPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本地提交领先").font(.headline)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.mini) }
            }
            if let snapshot {
                switch snapshot.ahead {
                case .count(let value, let upstream):
                    Text("领先 \(value) 个提交")
                        .font(.body.weight(.medium))
                    Text("上游分支：\(upstream)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                }
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail).foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private var changesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("工作区变更").font(.headline)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.mini) }
            }
            if let snapshot {
                let c = snapshot.changes
                Text("共 \(c.totalCount) 个变更文件")
                    .font(.body.weight(.medium))
                HStack(spacing: 12) {
                    Label("新增 \(c.addedCount)", systemImage: "plus.circle")
                        .foregroundStyle(.green)
                    Label("删除 \(c.deletedCount)", systemImage: "minus.circle")
                        .foregroundStyle(.red)
                    Label("修改 \(c.modifiedCount)", systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                    Label("重命名 \(c.renamedCount)", systemImage: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if c.totalCount > 0 {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(c.addedFiles, id: \.self) { file in
                                Text("+ \(file)").foregroundStyle(.green)
                            }
                            ForEach(c.deletedFiles, id: \.self) { file in
                                Text("− \(file)").foregroundStyle(.red)
                            }
                            ForEach(c.modifiedFiles, id: \.self) { file in
                                Text("M \(file)").foregroundStyle(.secondary)
                            }
                            ForEach(c.renamedFiles.indices, id: \.self) { i in
                                let ren = c.renamedFiles[i]
                                Text("R \(ren.from) → \(ren.to)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail).foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 350, alignment: .leading)
    }

    private var unavailableDetail: String {
        switch state {
        case .notRepository(_, let reason, _), .directoryMissing(_, let reason, _), .failed(_, let reason, _):
            return reason
        case .loading, .idle:
            return String(localized: "正在读取 Git 状态…")
        case .loaded:
            return String(localized: "已加载")
        }
    }

    @ViewBuilder
    private func popoverFooter(updatedAt: Date?) -> some View {
        Divider()
        if case .loaded(_, let isStale, let error) = state {
            if let error {
                Text("最近刷新失败：\(error)（显示上次成功记录）")
                    .font(.caption).foregroundStyle(.orange)
            } else if isStale {
                Text("状态可能已变化，正在或等待刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            if let updatedAt {
                Text("更新于 \(TranscriptTimestampFormatter.shortTime(updatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") {
                gitStore.refresh(directory: project.path, force: true)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .disabled(state.isLoading)
        }
    }
}

private struct ActiveRunBanner: View {
    let workspace: WorkspaceController
    let presentInteraction: () -> Void

    private var statusText: String {
        guard let active = workspace.active else { return "" }
        switch active.connection {
        case .disconnected: return String(localized: "连接已结束")
        case .connecting: return String(localized: "正在连接")
        case .closing: return String(localized: "正在清理进程")
        case .blocked: return String(localized: "进程待核实")
        case .connected:
            switch active.phase {
            case .idle: return String(localized: "已连接")
            case .running: return String(localized: "执行中")
            case .waitingInput: return String(localized: "等待扩展回复")
            case .retrying: return String(localized: "正在重试")
            case .compacting: return String(localized: "正在压缩上下文")
            case .stopping: return String(localized: "正在停止")
            case .uncertain: return String(localized: "结果待核实")
            }
        }
    }

    private var executingName: String? {
        guard let id = workspace.activeID,
              let session = workspace.state.sessions.first(where: { $0.id == id }),
              let project = workspace.state.projects.first(where: { $0.id == session.projectID }) else { return nil }
        return "\(project.name) / \(session.title)"
    }

    var body: some View {
        if let active = workspace.active, let activeID = workspace.activeID {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    let isAttention = active.connection == .blocked || active.phase == .uncertain || active.phase == .waitingInput
                    let isRunning = active.connection == .connected && active.phase == .running
                    Image(systemName: isAttention ? "exclamationmark.triangle.fill" : (isRunning ? "waveform.path" : "circle.fill"))
                        .font(.caption)
                        .foregroundStyle(isAttention ? Color.orange : (isRunning ? Color.green : Color.secondary))
                        .accessibilityHidden(true)
                    Text(statusText)
                        .fontWeight(.medium)
                        .accessibilityIdentifier("active-run-status")
                    if let executingName {
                        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(executingName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(executingName)
                    }
                    Spacer(minLength: 8)
                    if !active.interactions.isEmpty {
                        Button("处理交互", action: presentInteraction)
                    }
                    Button("返回执行会话") {
                        Task { await workspace.select(activeID) }
                    }
                    if active.connection == .blocked || active.phase == .uncertain {
                        Button("结束受管进程", role: .destructive) {
                            Task { _ = await workspace.disconnect(force: true) }
                        }
                        .disabled(workspace.busy || active.commandPending)
                    } else {
                        Button("停止", systemImage: "stop") {
                            Task { await workspace.stop() }
                        }
                        .disabled(workspace.busy || !active.canStop)
                        .help("停止（⌘.）")
                        .accessibilityIdentifier("stop-run")
                        Menu {
                            Button("断开连接") { Task { _ = await workspace.disconnect() } }
                                .disabled(workspace.busy || active.commandPending)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("连接操作")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                Divider()
            }
            .background(.ultraThinMaterial)
        }
    }
}

struct SubmissionReview: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    var unresolved: [SubmissionRecord] { reference.submissions.filter { $0.delivery == .unknown } }
    var body: some View {
        if !unresolved.isEmpty {
            DisclosureGroup("发送状态待核实（\(unresolved.count)）") {
                ForEach(unresolved) { submission in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(submission.acknowledged ? "运行时曾接受该输入；完成情况未核实。" : "可能已发送，也可能尚未发送。")
                        if !submission.text.isEmpty { Text(submission.text).lineLimit(4).textSelection(.enabled) }
                        if let files = submission.files { Text(files.map(\.lastPathComponent).joined(separator: "、")).lineLimit(2) }
                        Text("关联标识：\(submission.id.uuidString)").font(.caption2)
                        if submission.needsReview { Button("已核对，解除发送限制") { Task { await workspace.reviewSubmission(submission.id, in: reference.id) } } }
                        else {
                            Button("放回草稿") { Task { await workspace.restoreReviewedSubmission(submission.id, in: reference.id) } }
                                .disabled(workspace.busy || workspace.storageError != nil)
                        }
                    }.padding(6)
                }
            }
            .buttonStyle(.glass).font(.caption).foregroundStyle(.orange)
            .padding(8).glassEffect(.regular.tint(.orange.opacity(0.16)), in: .rect(cornerRadius: 9))
            .padding(.horizontal, 24).padding(.vertical, 4)
        }
    }
}

struct FeedbackBanner: View {
    let text: String
    let warning: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
            Text(text).font(.callout).textSelection(.enabled); Spacer(minLength: 0)
        }.foregroundStyle(warning ? Color.orange : Color.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(warning ? .orange.opacity(0.18) : nil), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
