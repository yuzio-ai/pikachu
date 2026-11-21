import SwiftUI
import AppKit
import AgentRuntimeCore
import OrchestrationCore

struct WorkbenchView: View {
    private static let minimumSidebarWidth: CGFloat = 220

    let workspace: WorkspaceController
    let settings: AppSettings
    let quitRequest: Int
    let openSettingsRequest: Int
    let terminate: (_ restarting: Bool, _ onCancel: @escaping () -> Void) -> Void
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    var canAutomaticallyPresentInteraction: (() -> Bool)? = nil
    @Environment(\.appearsActive) private var appearsActive
    @State private var modal: WorkbenchModal?
    @State private var lastPresentedInteractionID: String?
    @State private var preparingToQuit = false
    @State private var sidebarFilter = SessionSidebarFilter()
    @State private var actionAfterSheet: (() -> Void)?
    @State private var gitStore = GitStatusStore()

    @State private var detailWidth: CGFloat = 0
    @State private var workbenchSize: CGSize = .zero

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SessionSidebar(workspace: workspace, filter: $sidebarFilter,
                           openProject: openProject, createSession: requestNewSession,
                           openSettings: { presentSettings(.general) },
                           toolSearchPaths: settings.toolSearchPaths)
                // The native overlay can size the sidebar from its content instead of the column's minimum.
                .frame(minWidth: Self.minimumSidebarWidth)
                .navigationSplitViewColumnWidth(min: Self.minimumSidebarWidth, ideal: 292, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                backgroundRuns
                if let viewed = workspace.viewed {
                    SessionDetail(workspace: workspace, settings: settings, presentation: viewed,
                                  blocksComposerPanels: modal != nil || actionAfterSheet != nil || preparingToQuit,
                                  openSettings: { presentSettings(.providers) }, presentConfirmation: presentConfirmation,
                                  presentToolFailures: presentToolFailures)
                        .id(viewed.id)
                } else {
                    FlatEmptyState("选择一个项目", systemImage: "folder",
                                   description: Text("打开本地项目后，可创建会话或只读浏览历史。")) {
                        Button(action: openProject) {
                            Label("打开项目…", systemImage: "folder.badge.plus")
                                .pikachuFont(.callout)
                        }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .disabled(!workspace.canManageProjects)
                    }
                }
                if let message = workspace.storageError {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(PikachuTheme.errorText)
                            .accessibilityHidden(true)
                        Text(message)
                        if workspace.initialized { Button("重试保存") { Task { _ = await workspace.flush() } } }
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .pikachuFont(.caption).padding(12)
                    .flatSurface(PikachuTheme.mutedSurface, radius: 10)
                }
                if let error = workspace.error { FeedbackBanner(text: error, warning: true) }
                if let notice = workspace.notice { FeedbackBanner(text: notice, warning: false) }
            }
            .background(PikachuTheme.workspace)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { detailWidth = $0 }
        }
        .background {
            WorkbenchTitlebar(sidebarVisibility: $sidebarVisibility, workspace: workspace,
                              gitStore: gitStore, detailWidth: detailWidth, hasSession: workspace.viewed != nil,
                              createSession: { createSession(in: $0, showsSidebar: false) })
                .frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { workbenchSize = $0 }
        .task(id: workspace.initialized) { await workspace.refreshWorkspaceHistory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let id = workspace.selected?.id, let path = workspace.workingDirectory(for: id) {
                gitStore.refresh(directory: path, force: true)
            }
            Task { await settings.notifications.refreshAuthorization() }
            Task { await workspace.refreshWorkspaceHistory() }
            presentCurrentInteractionIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
            // File pickers are AppKit sheets and are not represented by `modal`.
            Task { @MainActor in presentCurrentInteractionIfPossible() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { @MainActor in presentCurrentInteractionIfPossible() }
        }
        .onChange(of: automaticInteraction?.id, initial: true) { _, _ in
            presentCurrentInteractionIfPossible()
        }
        .onChange(of: appearsActive) { _, active in
            if active { presentCurrentInteractionIfPossible() }
        }
        .onChange(of: workspace.completedTurnsByDirectory) { previous, current in
            for (path, turns) in current where previous[path] != turns {
                gitStore.refresh(directory: path, force: true)
            }
        }
        .onChange(of: workspace.newSessionRequest) { requestNewSession() }
        .onChange(of: workspace.openProjectRequest) { openProject() }
        .onChange(of: openSettingsRequest) { presentSettings(.general) }
        .onChange(of: settings.preferences) { _, value in workspace.setPreferences(value) }
        .onChange(of: quitRequest) { prepareToQuit(restarting: false) }
        .onChange(of: shouldKeepPresentedInteraction) { _, keepPresented in
            if !keepPresented, case .interaction = modal { modal = nil }
        }
        .sheet(item: $modal, onDismiss: sheetDidDismiss) { value in
            Group {
                switch value {
                case .interaction(let request, let controller, let title):
                    InteractionView(request: request, controller: controller, sessionTitle: title,
                                    availableSize: workbenchSize)
                        .id(request.id)
                case .toolFailures(let failures):
                    ToolFailureDetailsSheet(failures: failures, close: { modal = nil })
                case .chooseSessionProject:
                    projectSelectionSheet
                case .confirmation(let request):
                    FlatConfirmation(request: request, cancel: { modal = nil }) { action in
                        actionAfterSheet = action
                        modal = nil
                    }
                case .settings(let section):
                    SettingsPanel(workspace: workspace, settings: settings, initialSection: section,
                                  preferredProjectID: sidebarFilter.projectID ?? workspace.selectedProject?.id,
                                  availableSize: workbenchSize,
                                  close: { modal = nil }, restart: { prepareToQuit(restarting: true) })
                        .presentationSizing(.fitted)
                }
            }
            .flatPanelContent()
            .pikachuTypography(settings.interfaceFontSize)
            .presentationBackground(PikachuTheme.surface)
        }
    }
    private func presentToolFailures(_ failures: [TranscriptItem]) {
        guard modal == nil, actionAfterSheet == nil, !preparingToQuit, !failures.isEmpty else { return }
        modal = .toolFailures(failures)
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
            modal = .chooseSessionProject
        }
    }

    private var projectSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择新会话的项目").pikachuFont(.title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(workspace.state.projects) { project in
                        Button {
                            actionAfterSheet = { createSession(in: project.id) }
                            modal = nil
                        } label: {
                            FlatMenuRow(title: Text(verbatim: project.displayName))
                        }
                        .help(project.path)
                        .accessibilityIdentifier("new-session-\(project.id)")
                    }
                }
            }
            .frame(maxHeight: 260)
            PikachuDivider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { modal = nil }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(FlatControlButtonStyle())
        .padding(20)
        .frame(width: 380)
    }

    private func presentConfirmation(_ request: ConfirmationRequest) {
        guard !preparingToQuit, modal == nil else { return }
        modal = .confirmation(request)
    }

    private func prepareToQuit(restarting: Bool) {
        guard !preparingToQuit else { return }
        preparingToQuit = true
        let requestTermination = {
            terminate(restarting) {
                preparingToQuit = false
            }
        }
        // AppKit cannot terminate while a workbench sheet is attached.
        if modal != nil || actionAfterSheet != nil {
            actionAfterSheet = requestTermination
            modal = nil
        } else {
            requestTermination()
        }
    }

    private func sheetDidDismiss() {
        let action = actionAfterSheet
        actionAfterSheet = nil
        if let action { action() }
        else { presentCurrentInteractionIfPossible() }
    }
    private func createSession(in project: UUID, showsSidebar: Bool = true) {
        guard !preparingToQuit, modal == nil, actionAfterSheet == nil else { return }
        Task {
            if let id = await workspace.createSession(in: project), workspace.state.selectedSessionID == id {
                sidebarFilter.reveal(in: project)
                if showsSidebar { sidebarVisibility = .all }
            }
        }
    }

    private func presentSettings(_ section: SettingsSection) {
        guard !preparingToQuit, modal == nil else { return }
        modal = .settings(section)
    }

    @ViewBuilder private var backgroundRuns: some View {
        let ids = backgroundExecutionIDs
        if ids.count > 3 {
            ScrollView {
                LazyVStack(spacing: 0) { backgroundRunRows(ids) }
            }
            .frame(height: 120)
        } else {
            backgroundRunRows(ids)
        }
    }

    private func backgroundRunRows(_ ids: [UUID]) -> some View {
        ForEach(ids, id: \.self) { id in
            ActiveRunBanner(workspace: workspace, sessionID: id, presentInteraction: { presentInteraction(for: id) })
                .frame(maxWidth: WorkbenchReadingColumn.maximumWidth)
                .padding(.horizontal, WorkbenchReadingColumn.minimumGutter)
                .frame(maxWidth: .infinity)
        }
    }

    private var backgroundExecutionIDs: [UUID] {
        workspace.executionIDs.filter { id in
            guard id != workspace.selected?.id, let execution = workspace.execution(for: id) else { return false }
            return execution.connection != .connected || execution.phase.isActive ||
                !execution.queue.isEmpty || !execution.interactions.isEmpty
        }
    }

    private var shouldKeepPresentedInteraction: Bool {
        guard case .interaction(let request, let controller, _) = modal else { return true }
        return controller.didExpire(request) ||
            controller.interactions.contains { $0.id == request.id && $0.instanceID == request.instanceID }
    }

    private var automaticInteraction: RuntimeInteraction? {
        guard !preparingToQuit, let id = workspace.viewed?.id,
              id == workspace.selected?.id, let controller = workspace.execution(for: id),
              controller.phase != .stopping else { return nil }
        return controller.interactions.first
    }

    private var workbenchCanPresentInteraction: Bool {
        guard appearsActive, NSApp.isActive, NSApp.modalWindow == nil, let window = NSApp.keyWindow else { return false }
        return window.attachedSheet == nil && window.sheetParent == nil
    }

    private func presentCurrentInteractionIfPossible() {
        guard canAutomaticallyPresentInteraction?() ?? workbenchCanPresentInteraction,
              let request = automaticInteraction, request.id != lastPresentedInteractionID,
              let id = workspace.viewed?.id else { return }
        presentInteraction(for: id)
    }

    private func presentInteraction(for id: UUID) {
        guard !preparingToQuit, modal == nil, actionAfterSheet == nil, let controller = workspace.execution(for: id),
              controller.phase != .stopping, let request = controller.interactions.first,
              request.expiresAt > Date() else { return }
        let title = workspace.state.sessions.first { $0.id == id }?.displayTitle ?? String(localized: "执行会话")
        lastPresentedInteractionID = request.id
        modal = .interaction(request, controller, title)
    }
}

struct SessionDetail: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let presentation: SessionPresentation
    var blocksComposerPanels = false
    let openSettings: () -> Void
    let presentConfirmation: (ConfirmationRequest) -> Void
    var presentToolFailures: ([TranscriptItem]) -> Void = { _ in }
    @State private var enteredAsLocalDraft: Bool?
    @State private var hasShownConversation = false
    @State private var composerClearance: CGFloat = 0
    @State private var extensionStatusExpanded = false

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    private var isLocalDraftAtEntry: Bool {
        guard let reference else { return false }
        return reference.historyConfirmed != true && reference.file == nil &&
            reference.submissions.isEmpty && presentation.controller.recoveredDrafts.isEmpty
    }

    private var starterProject: ProjectRecord? {
        guard enteredAsLocalDraft ?? isLocalDraftAtEntry,
              !hasShownConversation, let reference, presentation.controller.transcript.isEmpty,
              presentation.controller.transcriptTurnStarts.isEmpty,
              !presentation.loading, presentation.loadError == nil, presentation.executionIssue == nil,
              presentation.history == nil,
              !reference.submissions.contains(where: \.needsReview) else { return nil }
        return workspace.state.projects.first { $0.id == reference.projectID }
    }

    var canSend: Bool {
        guard workspace.initialized, workspace.storageError == nil, !workspace.isOperating(on: presentation.id), !presentation.loading,
              presentation.loadError == nil, presentation.executionIssue == nil, presentation.history?.incompleteTail != true,
              reference?.submissions.contains(where: \.needsReview) != true else { return false }
        if workspace.execution(for: presentation.id) != nil, presentation.controller.connection == .connected {
            if reference?.pendingSelection != nil, presentation.controller.phase.isActive || !presentation.controller.queue.isEmpty { return false }
            return presentation.controller.canSend
        }
        return presentation.controller.draftPrompt.hasContent
    }
    var sessionConfigurationDisabled: Bool {
        !workspace.canChangeExecutionPolicy(for: presentation.id)
    }
    var currentModel: ComposerModel? {
        if let pending = reference?.pendingSelection {
            return .init(provider: pending.provider, name: reference?.pendingModelName ?? pending.modelID,
                         thinking: pending.thinking ?? String(localized: "默认"), pending: true)
        }
        if let live = presentation.controller.session, let provider = live.provider {
            return .init(provider: provider, name: live.model, thinking: live.thinking, pending: false)
        }
        if let saved = reference?.selection ?? presentation.history?.selection {
            return .init(provider: saved.provider, name: reference?.modelName ?? saved.modelID,
                         thinking: saved.thinking ?? String(localized: "默认"), pending: false)
        }
        return nil
    }
    private func addFiles() {
        let controller = presentation.controller
        let directory = workspace.workingDirectory(for: presentation.id).map { URL(fileURLWithPath: $0) }
        Task {
            let files = await settings.pickFiles(in: directory)
            for file in files.map(\.standardizedFileURL) where !controller.draftFiles.contains(file) {
                controller.draftFiles.append(file)
            }
        }
    }
    private func send() {
        let prompt = presentation.controller.draftPrompt
        Task { await workspace.send(presentation.id, submitted: prompt) }
    }
    private var retryableModelPrompt: UserPrompt? {
        guard !workspace.isOperating(on: presentation.id), !blocksComposerPanels,
              reference?.submissions.contains(where: \.needsReview) == false else { return nil }
        return workspace.execution(for: presentation.id)?.retryableModelPrompt
    }

    private func confirmModelRetry(_ prompt: UserPrompt) {
        presentConfirmation(ConfirmationRequest(
            title: "重试上一条任务？", message: "将重新发送上一条消息。本轮已执行的操作不会撤销。",
            confirmTitle: "重试"
        ) {
            Task {
                guard retryableModelPrompt?.id == prompt.id else { return }
                await workspace.send(presentation.id, submitted: .init(text: prompt.text, mode: prompt.mode, files: prompt.files))
            }
        })
    }

    private func handleEditUserMessage(_ item: TranscriptItem) {
        let hasExistingDraft = !presentation.controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !presentation.controller.draftFiles.isEmpty
        if hasExistingDraft {
            presentConfirmation(ConfirmationRequest(
                title: "替换当前草稿？", message: "当前输入框已有未发送的草稿，替换为所选消息内容？",
                confirmTitle: "替换草稿"
            ) { applyEdit(item) })
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
        detailContent
        .onAppear {
            if enteredAsLocalDraft == nil { enteredAsLocalDraft = isLocalDraftAtEntry }
        }
        .onChange(of: presentation.controller.transcript.isEmpty) { _, empty in
            if !empty { hasShownConversation = true }
        }
        .onChange(of: presentation.controller.extensionStatus.isEmpty) { _, empty in
            if empty { extensionStatusExpanded = false }
        }
    }

    private var detailContent: some View {
        let starter = starterProject
        return SessionDetailViewport(isStarter: starter != nil) { viewportHeight in
            VStack(spacing: 0) {
                if presentation.loading { FlatProgressView("正在读取历史…").padding(8) }
                if let error = presentation.loadError {
                    FeedbackBanner(text: error, warning: true)
                    Button("重新读取") { Task { await workspace.refreshHistory(presentation.id) } }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).padding(8)
                }
                if presentation.history?.incompleteTail == true { FeedbackBanner(text: String(localized: "文件尾部尚未写完。已显示完整记录，当前禁止执行；请稍后重新读取。"), warning: true) }
                if let issue = presentation.executionIssue { FeedbackBanner(text: issue, warning: true) }
                if let warnings = presentation.history?.warnings, !warnings.isEmpty { FeedbackBanner(text: warnings.joined(separator: "\n"), warning: true) }
                if let starter {
                    Text("想在 \(starter.displayName) 中做什么？")
                        .pikachuFont(.hero, weight: .medium)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("session-starter-title")
                        .padding(.horizontal, WorkbenchReadingColumn.minimumGutter)
                        .padding(.bottom, 22)
                } else {
                    TranscriptView(
                        items: presentation.controller.transcript,
                        turnStarts: presentation.controller.transcriptTurnStarts,
                        diagnosticSession: presentation.id.uuidString,
                        historyLoading: presentation.loading,
                        showsThinking: presentation.controller.connection == .connected &&
                            presentation.controller.phase == .running && !presentation.controller.isStopping,
                        queue: presentation.controller.queue,
                        queueIsKnown: presentation.controller.queueIsKnown,
                        showsEmptyState: presentation.loadError == nil && presentation.executionIssue == nil,
                        composerClearance: composerClearance,
                        workspaceDirectory: workspace.workingDirectory(for: presentation.id).map { URL(fileURLWithPath: $0, isDirectory: true) },
                        onEditUserMessage: handleEditUserMessage
                    ).id(presentation.id)
                }
            }
            VStack(spacing: 0) {
                if !presentation.controller.extensionStatus.isEmpty {
                    ExtensionStatusView(controller: presentation.controller, viewportHeight: viewportHeight,
                                        expanded: $extensionStatusExpanded)
                }
                if let failure = presentation.controller.failure {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .pikachuFont(.caption)
                            .foregroundStyle(PikachuTheme.warningText)
                            .accessibilityHidden(true)
                        Text(failure.detail).pikachuFont(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let prompt = retryableModelPrompt {
                            Button("重试") { confirmModelRetry(prompt) }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                                .pikachuFont(.caption)
                                .fixedSize()
                                .accessibilityIdentifier("retry-model-turn")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .flatSurface(PikachuTheme.mutedSurface, radius: 8)
                    .padding(.horizontal, 12).padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    if presentation.controller.connection == .disconnected && workspace.storageError == nil &&
                        (failure.kind == .setup || failure.kind == .unsupportedVersion) {
                        Button("打开连接设置…", action: openSettings)
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).pikachuFont(.caption).padding(.vertical, 4)
                    }
                }
                if let message = presentation.executionError, message != presentation.controller.failure?.detail {
                    FeedbackBanner(text: message, warning: true)
                }
                if let notice = presentation.controller.noticeExcludingExpiredInteraction { FeedbackBanner(text: notice, warning: false) }
                if let reference, !reference.submissions.isEmpty { SubmissionReview(workspace: workspace, reference: reference) }
                ComposerView(
                    controller: presentation.controller,
                    workspace: workspace,
                    executionPolicy: reference?.executionPolicy ?? .init(mode: .automatic),
                    activePolicy: workspace.runningPolicy(for: presentation.id),
                    isViewedSessionActive: workspace.execution(for: presentation.id) != nil,
                    isReadOnlyHistory: presentation.executionIssue != nil,
                    sessionConfigurationDisabled: sessionConfigurationDisabled,
                    model: currentModel,
                    reference: reference,
                    project: workspace.state.projects.first { $0.id == reference?.projectID },
                    panelsBlocked: blocksComposerPanels,
                    onPickFiles: addFiles,
                    onMode: { mode in Task { await workspace.setAgentMode(mode, for: presentation.id) } },
                    onApproval: { approval in Task { await workspace.setToolApproval(approval, for: presentation.id) } },
                    onSend: send,
                    onStop: { Task { await workspace.stop(presentation.id) } },
                    presentToolFailures: presentToolFailures,
                    sendEnabled: canSend,
                    focusSignal: workspace.inputFocusRequest,
                    isStarter: starter != nil,
                    pastedImagesDirectory: settings.pastedImagesDirectory
                )
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { composerClearance = $0 }
        }
    }
}

/// One scroll container keeps the composer mounted as a draft becomes a conversation.
struct SessionDetailViewport<Content: View>: View {
    let isStarter: Bool
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                SessionDetailLayout(isStarter: isStarter, viewportHeight: geometry.size.height) {
                    content(geometry.size.height)
                }
                .frame(width: geometry.size.width)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct SessionDetailLayout: Layout {
    let isStarter: Bool
    let viewportHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        guard isStarter else { return CGSize(width: width, height: viewportHeight) }
        let titleHeight = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
        let composerHeight = subviews[1].sizeThatFits(composerProposal(for: width)).height
        return CGSize(width: width, height: max(viewportHeight, titleHeight + composerHeight))
    }

    private func composerProposal(for width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: WorkbenchReadingColumn.width(in: width), height: nil)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0]
        let composer = subviews[1]
        let composerProposal = composerProposal(for: bounds.width)
        if isStarter {
            let titleProposal = ProposedViewSize(width: bounds.width, height: nil)
            let titleHeight = content.sizeThatFits(titleProposal).height
            let composerHeight = composer.sizeThatFits(composerProposal).height
            let groupHeight = titleHeight + composerHeight
            let top = bounds.minY + max(0, viewportHeight * 0.44 - groupHeight / 2)
            content.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top, proposal: titleProposal)
            composer.place(at: CGPoint(x: bounds.midX, y: top + titleHeight), anchor: .top, proposal: composerProposal)
        } else {
            content.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            composer.place(at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom, proposal: composerProposal)
        }
    }
}

struct SessionHeader: View {
    let workspace: WorkspaceController
    let presentation: SessionPresentation
    let gitStore: GitStatusStore
    let createSession: (UUID) -> Void
    @State private var showsGitDetails = false

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    private var owningProject: ProjectRecord? {
        guard let reference else { return nil }
        return workspace.state.projects.first { $0.id == reference.projectID }
    }
    var project: ProjectRecord? {
        guard let reference, var project = owningProject else { return nil }
        project.path = reference.workingDirectory(in: project)
        return project
    }
    var activeController: SessionController? { workspace.execution(for: presentation.id) }

    private typealias ConnectionStatus = (kind: ConnectionBadgeKind, label: LocalizedStringResource, description: String)

    private var connectionStatus: ConnectionStatus {
        if let active = activeController {
            switch active.connection {
            case .disconnected:
                break
            case .connecting:
                return (.progress, "连接中", String(localized: "正在建立连接…"))
            case .closing:
                return (.progress, "清理中", String(localized: "正在清理受管进程…"))
            case .blocked:
                return (.error, "已阻止", String(localized: "进程清理待核实 · 已阻止继续执行"))
            case .connected:
                if active.isStopping { return (.progress, "停止中", String(localized: "已连接 · 正在停止…")) }
                switch active.phase {
                case .idle:
                    if let failure = active.failure { return (.error, "发生错误", failure.detail) }
                    return (.neutral, "就绪", String(localized: "已连接 · 就绪"))
                case .running:
                    return (.running, "运行中", String(localized: "已连接 · 正在执行"))
                case .waitingInput:
                    if active.interactions.contains(where: { $0.toolApproval != nil }) {
                        return (.warning, "等待审批", String(localized: "等待工具审批"))
                    }
                    return (.warning, "等待回复", String(localized: "已连接 · 等待扩展回复"))
                case .retrying:
                    return (.progress, "重试中", String(localized: "已连接 · 正在重试"))
                case .compacting:
                    return (.progress, "压缩中", String(localized: "已连接 · 正在压缩上下文"))
                case .stopping:
                    return (.progress, "停止中", String(localized: "已连接 · 正在停止…"))
                case .uncertain:
                    return (.warning, "待核实", String(localized: "执行结果待核实"))
                }
            }
        }
        if reference?.submissions.contains(where: \.needsReview) == true {
            return (.warning, "待核实", String(localized: "存在发送状态待核实的记录"))
        }
        if presentation.history?.incompleteTail == true || presentation.loadError != nil {
            return (.warning, "历史异常", String(localized: "历史读取异常或尾部未写完"))
        }
        if reference?.file == nil {
            return (.neutral, "草稿", String(localized: "未连接 · 独立草稿"))
        }
        return (.neutral, "历史浏览", String(localized: "未连接 · 历史浏览"))
    }

    private func projectButton(_ project: ProjectRecord) -> some View {
        Button { createSession(project.id) } label: {
            HStack(spacing: 6) {
                ProjectBadge(project: project, compact: true)
                Text(verbatim: project.displayName)
                    .pikachuFont(.headline, weight: .regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .disabled(!workspace.canManageProjects)
        .help(Text("在 \(project.displayName) 中新建会话\n\(project.path)"))
        .accessibilityLabel("项目 \(project.displayName)")
        .accessibilityHint("新建会话")
        .accessibilityIdentifier("new-session-in-viewed-project")
    }

    private func identitySection(status: ConnectionStatus) -> some View {
        HStack(spacing: 8) {
            if let owningProject {
                projectButton(owningProject)
                Text("/")
                    .pikachuFont(.headline, weight: .regular)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 4) {
                if let reference {
                    SessionTitleControl(workspace: workspace, session: reference)
                        .id(reference.id)
                } else {
                    Text("会话")
                        .pikachuFont(.headline, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                }
                statusBadge(status)
            }
        }
    }

    private func statusBadge(_ status: ConnectionStatus) -> some View {
        let tint = status.kind == .neutral ? PikachuTheme.secondaryText : status.kind.color
        return HStack(spacing: 5) {
            Circle()
                .fill(status.kind.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .pikachuFont(.caption, weight: .medium)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            Capsule()
                .fill(tint.opacity(0.12))
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        }
        .frame(height: 24)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .help(status.description)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("runtime-status")
        .accessibilityLabel("会话连接状态")
        .accessibilityValue(status.description)
    }

    private func executionActionsSection(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let active = activeController, active.connection != .disconnected,
               active.connection == .blocked || active.phase == .uncertain {
                Button(role: .destructive) {
                    Task { _ = await workspace.disconnect(presentation.id, force: true) }
                } label: {
                    Label("结束受管进程", systemImage: "exclamationmark.triangle")
                        .labelStyle(ToolbarActionLabel(compact: compact))
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: !compact))
                .controlSize(.small)
                .disabled(workspace.isOperating(on: presentation.id) || active.commandPending)
                .help("结束受管进程")
                .accessibilityLabel("结束受管进程")
                .fixedSize()
            }
            if compact, let project {
                Button { showsGitDetails.toggle() } label: {
                    IconButtonLabel(systemName: "info.circle")
                }
                .buttonStyle(FlatControlButtonStyle(isOpen: showsGitDetails, inset: false))
                .help("Git 详情")
                .accessibilityLabel("Git 详情")
                .popover(isPresented: $showsGitDetails) {
                    GitSummaryBar(project: project, gitStore: gitStore, displaysDetails: true)
                }
            }
        }
    }

    var body: some View {
        let status = connectionStatus
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identitySection(status: status).frame(minWidth: 150, alignment: .leading)
                Spacer(minLength: 6)
                if let project { GitSummaryBar(project: project, gitStore: gitStore).fixedSize() }
                executionActionsSection(compact: false).fixedSize()
            }
            HStack(spacing: 8) {
                identitySection(status: status)
                Spacer(minLength: 4)
                executionActionsSection(compact: true).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project?.path) {
            if let path = project?.path {
                gitStore.refresh(directory: path)
            }
        }
    }
}

private struct SessionTitleControl: View {
    let workspace: WorkspaceController
    let session: SessionReference
    @State private var isHovered = false
    @State private var isMenuOpen = false
    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var isSaving = false
    @State private var saveFailed = false
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isMenuFocused: Bool

    var body: some View {
        Button {
            if !isMenuOpen { isEditing = false }
            isMenuOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: session.displayTitle)
                    .pikachuFont(.headline, weight: .semibold)
                    .lineLimit(1)
                FlatDisclosureChevron(.down)
                    .opacity(isHovered || isMenuFocused || isMenuOpen ? 1 : 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: isMenuOpen, inset: false))
        .focused($isMenuFocused)
        .onHover { isHovered = $0 }
        .help(session.displayTitle)
        .accessibilityHint(Text("会话操作"))
        .accessibilityIdentifier("session-title-menu")
        .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
            Group {
                if isEditing {
                    renameEditor
                } else {
                    FlatMenuPanel(width: 190) { menuActions }
                }
            }
            .onExitCommand { isMenuOpen = false }
        }
    }

    @ViewBuilder private var menuActions: some View {
        if session.sidebarStatus == .open {
            let blocked = workspace.settleBlockReason(for: session)
            Button {
                select { Task { await workspace.markSessionSettled(session.id) } }
            } label: {
                FlatMenuRow(title: Text("标记已处理"))
            }
            .disabled(blocked != nil)
            .help(blocked.map { String(localized: $0) } ?? "")

            DisclosureGroup("暂缓提醒") {
                SessionReminderMenuActions(workspace: workspace, sessionID: session.id,
                                           state: session.reminderState(at: .now), select: select)
                    .padding(.leading, 10)
            }
            .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
            .padding(.horizontal, 8)
            .disabled(!workspace.initialized || workspace.storageError != nil)
        } else {
            Button {
                select { Task { await workspace.reopenSession(session.id) } }
            } label: {
                FlatMenuRow(title: Text("移回待处理"))
            }
            .disabled(!workspace.initialized || workspace.storageError != nil)
        }
        PikachuDivider()
        Button(action: beginEditing) {
            FlatMenuRow(title: Text("修改会话名称"))
        }
        .disabled(isSaving)
        if let active = workspace.execution(for: session.id),
           active.connection == .connected || active.connection == .connecting {
            PikachuDivider()
            Button {
                select { Task { _ = await workspace.disconnect(session.id) } }
            } label: {
                FlatMenuRow(title: Text("断开连接"))
            }
            .disabled(workspace.isOperating(on: session.id) || active.commandPending)
        }
    }

    private func select(_ action: () -> Void) {
        isMenuOpen = false
        action()
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修改会话名称").pikachuFont(.headline)
            TextField("会话名称", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .disabled(isSaving)
                .onSubmit(save)
                .onAppear { isTitleFocused = true }
            if saveFailed {
                Text("会话名称未保存，请重试。")
                    .pikachuFont(.caption)
                    .foregroundStyle(PikachuTheme.errorText)
            }
            HStack {
                Spacer()
                Button("取消") { isMenuOpen = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存", action: save)
                    .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        }
        .padding(12)
        .frame(width: 280)
    }

    private var canSave: Bool {
        !isSaving && !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginEditing() {
        guard !isSaving, !isEditing else { return }
        draftTitle = session.displayTitle
        saveFailed = false
        isEditing = true
    }

    private func save() {
        guard canSave else { return }
        let proposedTitle = draftTitle
        isSaving = true
        saveFailed = false
        Task {
            let saved = await workspace.renameSession(session.id, to: proposedTitle)
            isSaving = false
            saveFailed = !saved
            if saved { isMenuOpen = false }
            else if isMenuOpen && isEditing { isTitleFocused = true }
        }
    }
}

private struct ToolbarActionLabel: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon.pikachuFont(.callout)
                .frame(width: IconButtonLabel.side, height: IconButtonLabel.side)
        } else {
            HStack(spacing: 4) {
                configuration.icon.pikachuFont(.callout)
                configuration.title
            }
        }
    }
}

private enum ConnectionBadgeKind {
    case neutral, running, progress, warning, error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .running: PikachuTheme.runningText
        case .progress: PikachuTheme.accentText
        case .warning: PikachuTheme.warningText
        case .error: PikachuTheme.errorText
        }
    }
}

private struct GitSummaryBar: View {
    let project: ProjectRecord
    let gitStore: GitStatusStore
    var displaysDetails = false
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

    private var changesAccessibilityValue: String {
        guard let snapshot else { return String(localized: "变更文件数未知") }
        return String(localized: "新增 \(snapshot.changes.addedCount) 个文件，删除 \(snapshot.changes.deletedCount) 个文件，共 \(snapshot.changes.totalCount) 个变更文件")
    }

    var body: some View {
        if displaysDetails {
            summaryPopover
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { showsBranchPopover.toggle() } label: {
                HStack(spacing: 4) {
                    GitBranchIcon()
                        .foregroundStyle(.secondary)
                    if snapshot != nil {
                        Text("分支 ·")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(branchText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .buttonStyle(FlatControlButtonStyle(isOpen: showsBranchPopover, inset: false))
            .foregroundStyle(snapshot == nil ? .secondary : .primary)
            .help(branchText)
            .accessibilityLabel("Git 分支")
            .accessibilityValue(branchText)
            .popover(isPresented: $showsBranchPopover) {
                branchPopover
            }

            PikachuDivider(axis: .vertical).frame(height: 12)

            Button { showsAheadPopover.toggle() } label: {
                HStack(spacing: 4) {
                    GitCommitIcon()
                        .foregroundStyle(.secondary)
                    Text("领先提交 · \(aheadText)")
                        .monospacedDigit()
                }
            }
            .buttonStyle(FlatControlButtonStyle(isOpen: showsAheadPopover, inset: false))
            .foregroundStyle(.secondary)
            .help("领先本地上游引用的提交数：\(aheadText)")
            .accessibilityLabel("领先本地上游引用的提交数")
            .accessibilityValue(aheadText)
            .popover(isPresented: $showsAheadPopover) {
                aheadPopover
            }

            Button { showsChangesPopover.toggle() } label: {
                HStack(spacing: 4) {
                    FileTextIcon()
                        .foregroundStyle(.secondary)
                    Text("变更文件 · \(snapshot?.changes.totalCount.formatted() ?? "—")")
                        .monospacedDigit()
                }
            }
            .buttonStyle(FlatControlButtonStyle(isOpen: showsChangesPopover, inset: false))
            .help("变更文件")
            .accessibilityLabel("变更文件")
            .accessibilityValue(changesAccessibilityValue)
            .popover(isPresented: $showsChangesPopover) {
                changesPopover
            }
        }
        .pikachuFont(.caption)
    }

    private var summaryPopover: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            Text("Git 详情").anchoredCardTitle()
            if let snapshot {
                Text("分支：\(branchText)").textSelection(.enabled)
                switch snapshot.ahead {
                case .count(let value, let upstream):
                    Text("领先 \(upstream) \(value) 个提交")
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                }
                let changes = snapshot.changes
                Text("共 \(changes.totalCount) 个变更文件")
                Text("新增 \(changes.addedCount) · 删除 \(changes.deletedCount) · 修改 \(changes.modifiedCount) · 重命名 \(changes.renamedCount)")
                    .foregroundStyle(.secondary)
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail).foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .anchoredPopoverCard(width: 320)
    }

    private var branchPopover: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            HStack {
                Label {
                    Text("分支信息").anchoredCardTitle()
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .pikachuFont(.caption)
                        .accessibilityHidden(true)
                }
                Spacer()
                if state.isLoading { FlatProgressView().controlSize(.mini) }
            }
            if let snapshot {
                switch snapshot.branch {
                case .branch(let name, let hasCommits):
                    Text("当前分支：\(name)").textSelection(.enabled)
                    if !hasCommits {
                        Text("当前分支尚无提交记录。")
                            .pikachuFont(.caption).foregroundStyle(.secondary)
                    }
                case .detached(let sha):
                    Text("分离 HEAD：\(sha)").textSelection(.enabled)
                }
                Text("仓库根目录：\(snapshot.checkoutRoot)")
                    .pikachuFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail)
                    .foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .anchoredPopoverCard(width: 320)
    }

    private var aheadPopover: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            HStack {
                Text("本地提交领先").anchoredCardTitle()
                Spacer()
                if state.isLoading { FlatProgressView().controlSize(.mini) }
            }
            if let snapshot {
                switch snapshot.ahead {
                case .count(let value, let upstream):
                    Text("领先 \(value) 个提交")
                        .pikachuFont(.body, weight: .medium)
                    Text("上游分支：\(upstream)")
                        .pikachuFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                }
                popoverFooter(updatedAt: snapshot.updatedAt)
            } else {
                Text(unavailableDetail).foregroundStyle(.secondary)
                popoverFooter(updatedAt: nil)
            }
        }
        .anchoredPopoverCard(width: 300)
    }

    private var changesPopover: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            HStack {
                Text("变更文件").anchoredCardTitle()
                Spacer()
                if state.isLoading { FlatProgressView().controlSize(.mini) }
            }
            if let snapshot {
                let c = snapshot.changes
                Text("共 \(c.totalCount) 个变更文件")
                    .pikachuFont(.body, weight: .medium)
                HStack(spacing: 12) {
                    Label("新增 \(c.addedCount)", systemImage: "plus.circle")
                        .foregroundStyle(PikachuTheme.runningText)
                    Label("删除 \(c.deletedCount)", systemImage: "minus.circle")
                        .foregroundStyle(PikachuTheme.errorText)
                    Label("修改 \(c.modifiedCount)", systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                    Label("重命名 \(c.renamedCount)", systemImage: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                }
                .pikachuFont(.caption)
                if c.totalCount > 0 {
                    PikachuDivider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(c.addedFiles, id: \.self) { file in
                                Text("+ \(file)").foregroundStyle(PikachuTheme.runningText)
                            }
                            ForEach(c.deletedFiles, id: \.self) { file in
                                Text("− \(file)").foregroundStyle(PikachuTheme.errorText)
                            }
                            ForEach(c.modifiedFiles, id: \.self) { file in
                                Text("修改：\(file)").foregroundStyle(.secondary)
                            }
                            ForEach(c.renamedFiles.indices, id: \.self) { i in
                                let ren = c.renamedFiles[i]
                                Text("重命名：\(ren.from) → \(ren.to)").foregroundStyle(.secondary)
                            }
                        }
                        .pikachuFont(.caption, design: .monospaced)
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
        .anchoredPopoverCard(width: 350)
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
        PikachuDivider()
        if case .loaded(_, let isStale, let error) = state {
            if let error {
                Text("最近刷新失败：\(error)（显示上次成功记录）")
                    .pikachuFont(.caption).foregroundStyle(PikachuTheme.warningText)
            } else if isStale {
                Text("状态可能已变化，正在或等待刷新。")
                    .pikachuFont(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            if let updatedAt {
                Text("更新于 \(TranscriptTimestampFormatter.shortTime(updatedAt))")
                    .pikachuFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") {
                gitStore.refresh(directory: project.path, force: true)
            }
            .buttonStyle(FlatControlButtonStyle())
            .pikachuFont(.caption, weight: .medium)
            .disabled(state.isLoading)
        }
    }
}

private struct ActiveRunBanner: View {
    let workspace: WorkspaceController
    let sessionID: UUID
    let presentInteraction: () -> Void

    private func statusText(for active: SessionController, request: RuntimeInteraction?) -> LocalizedStringKey {
        switch active.connection {
        case .disconnected: return "连接已结束"
        case .connecting: return "正在连接"
        case .closing: return "正在清理进程"
        case .blocked: return "进程待核实"
        case .connected:
            if active.phase != .uncertain, let request {
                return request.kind == .confirm && request.toolApproval != nil ? "等待审批" : "等待回复"
            }
            switch active.phase {
            case .idle: return "已连接"
            case .running: return "后台运行中"
            case .waitingInput: return "等待扩展回复"
            case .retrying: return "正在重试"
            case .compacting: return "正在压缩上下文"
            case .stopping: return "正在停止"
            case .uncertain: return "结果待核实"
            }
        }
    }

    private var executingName: String? {
        guard let session = workspace.state.sessions.first(where: { $0.id == sessionID }) else { return nil }
        guard session.projectID != workspace.selected?.projectID,
              let project = workspace.state.projects.first(where: { $0.id == session.projectID }) else { return session.displayTitle }
        return "\(project.displayName) / \(session.displayTitle)"
    }

    var body: some View {
        if let active = workspace.execution(for: sessionID) {
            let request = active.phase == .stopping ? nil : active.interactions.first
            let needsRecovery = active.connection == .blocked || active.phase == .uncertain
            let needsAttention = request != nil || needsRecovery || active.phase == .waitingInput
            let isRunning = active.connection == .connected && active.phase == .running
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(needsAttention ? PikachuTheme.warningText : (isRunning ? PikachuTheme.runningText : Color.secondary))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(statusText(for: active, request: request))
                        .fontWeight(.medium)
                        .foregroundStyle(needsAttention ? PikachuTheme.warningText : Color.secondary)
                        .fixedSize()
                        .accessibilityIdentifier("active-run-status")
                    Button {
                        Task { await workspace.select(sessionID) }
                    } label: {
                        HStack(spacing: 4) {
                            if let executingName {
                                Text(executingName).lineLimit(1)
                            } else {
                                Text("返回执行会话")
                            }
                            Image(systemName: "arrow.up.right")
                                .pikachuFont(.caption, weight: .medium)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .help(Text(executingName ?? String(localized: "返回执行会话")))
                    .accessibilityHint("返回执行会话")
                    .accessibilityIdentifier("open-background-session")
                    Spacer(minLength: 4)
                    if request != nil {
                        let approvalCount = active.interactions.count { $0.kind == .confirm && $0.toolApproval != nil }
                        Button(action: presentInteraction) {
                            if approvalCount > 1 {
                                Text("去处理（\(approvalCount)）")
                            } else {
                                Text("去处理")
                            }
                        }
                        .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                        .fixedSize()
                        .accessibilityIdentifier("handle-background-interaction")
                    }
                    FlatMenu(width: 168) {
                        IconButtonLabel(systemName: "ellipsis")
                    } content: { select in
                        if needsRecovery {
                            Button(role: .destructive) {
                                select { Task { _ = await workspace.disconnect(sessionID, force: true) } }
                            } label: {
                                FlatMenuRow(title: Text("结束受管进程"))
                            }
                            .disabled(workspace.isOperating(on: sessionID) || active.commandPending)
                        } else {
                            Button(role: .destructive) {
                                select { Task { await workspace.stop(sessionID) } }
                            } label: {
                                FlatMenuRow(title: Text("停止此会话"))
                            }
                            .disabled(!workspace.canStop(sessionID))
                            .accessibilityIdentifier("stop-run")
                            Button { select { Task { _ = await workspace.disconnect(sessionID) } } } label: {
                                FlatMenuRow(title: Text("断开连接"))
                            }
                            .disabled(workspace.isOperating(on: sessionID) || active.commandPending)
                        }
                    }
                    .fixedSize()
                    .help("会话操作")
                    .accessibilityLabel("会话操作")
                }
                .buttonStyle(FlatControlButtonStyle())
                .controlSize(.small)
                .pikachuFont(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                PikachuDivider()
            }
            .background(needsAttention ? PikachuTheme.warningSurface : Color.clear, ignoresSafeAreaEdges: [])
        }
    }
}

struct SubmissionReview: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    var unresolved: [SubmissionRecord] { reference.submissions.filter { $0.delivery == .unknown } }
    var body: some View {
        if !unresolved.isEmpty {
            DisclosureGroup {
                ForEach(unresolved) { submission in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(submission.acknowledged ? "运行时曾接受该输入；完成情况未核实。" : "可能已发送，也可能尚未发送。")
                        if !submission.text.isEmpty { Text(submission.text).lineLimit(4).textSelection(.enabled) }
                        if let files = submission.files { Text(files.map(\.lastPathComponent).joined(separator: String(localized: "、"))).lineLimit(2) }
                        Text("关联标识：\(submission.id.uuidString)").pikachuFont(.caption2)
                        if submission.needsReview { Button("已核对，解除发送限制") { Task { await workspace.reviewSubmission(submission.id, in: reference.id) } } }
                        else {
                            Button("放回草稿") { Task { await workspace.restoreReviewedSubmission(submission.id, in: reference.id) } }
                                .disabled(workspace.isOperating(on: reference.id) || workspace.storageError != nil)
                        }
                    }.padding(6)
                }
            } label: {
                Text("发送状态待核实（\(unresolved.count)）")
                    .foregroundStyle(PikachuTheme.warningText)
            }
            .disclosureGroupStyle(FlatDisclosureStyle())
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).pikachuFont(.caption)
            .foregroundStyle(PikachuTheme.warningText)
            .padding(8).flatSurface(PikachuTheme.mutedSurface, radius: 9)
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
                .pikachuFont(.caption)
                .foregroundStyle(warning ? PikachuTheme.warningText : Color.secondary)
            Text(text).pikachuFont(.callout).textSelection(.enabled); Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .flatSurface(PikachuTheme.mutedSurface, radius: 10)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
