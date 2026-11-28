import SwiftUI
import AppKit
import AgentRuntimeCore
import OrchestrationCore

private extension SessionPresentation {
    func containsTranscriptItem(_ item: TranscriptItem) -> Bool {
        controller.transcript.contains { $0 === item } || frozenTranscript.contains { $0 === item }
    }

    var transcriptItemValidator: ToolResultSource.Validator {
        { [weak self] item in self?.containsTranscriptItem(item) == true }
    }
}

enum SessionManagementAction {
    case archive, deleteDraft, deleteRemoteHistory, forceEnd, confirmRetirement
}

extension ACPPoolStatus {
    var label: LocalizedStringKey {
        switch self {
        case .starting: "正在启动"
        case .ready: "已连接"
        case .reconnecting: "正在重连"
        case .dedicated: "按会话启动"
        case .needsLogin: "需要登录"
        case .failed: "连接失败"
        }
    }
}

struct WorkbenchView: View {
    private static let minimumSidebarWidth: CGFloat = 220

    let workspace: WorkspaceController
    let settings: AppSettings
    let projectFiles: ProjectFilesControls
    let quitRequest: Int
    let openSettingsRequest: Int
    let terminate: (_ restarting: Bool, _ onCancel: @escaping () -> Void) -> Void
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    var canAutomaticallyPresentInteraction: (() -> Bool)? = nil
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modal: WorkbenchModal?
    @State private var providerConnectionRequest: ProviderConnectionRequest?
    @State private var lastArchivedSessionID: UUID?
    @State private var sessionManagementError: String?
    @State private var lastPresentedInteractionID: String?
    @State private var preparingToQuit = false
    @State private var sidebarFilter = SessionSidebarFilter()
    @State private var actionAfterSheet: (() -> Void)?
    @State private var gitStore: GitStatusStore
    @State private var navigatorModel: ProjectNavigatorModel
    @State private var tabsModel: WorkbenchTabsModel

    @State private var readingPositions: WindowTranscriptPositions
    @State private var detailWidth: CGFloat = 0
    @State private var workbenchSize: CGSize = .zero
    @State private var preferredEditorWidth: CGFloat? = nil
    @State private var editorDragWidth: CGFloat?
    @State private var isHoveringEditorDivider = false
    @State private var imagePreview: ImagePreviewSelection?

    init(workspace: WorkspaceController, settings: AppSettings, quitRequest: Int, openSettingsRequest: Int,
         terminate: @escaping (_ restarting: Bool, _ onCancel: @escaping () -> Void) -> Void,
         sidebarVisibility: Binding<NavigationSplitViewVisibility>,
         projectFiles: ProjectFilesControls = ProjectFilesControls(),
         readingPositions: WindowTranscriptPositions = WindowTranscriptPositions(),
         gitStore: GitStatusStore? = nil,
         navigatorModel: ProjectNavigatorModel? = nil,
         tabsModel: WorkbenchTabsModel? = nil,
         canAutomaticallyPresentInteraction: (() -> Bool)? = nil,
         initialImagePreview: ImagePreviewSelection? = nil) {
        _readingPositions = State(initialValue: readingPositions)
        _gitStore = State(initialValue: gitStore ?? GitStatusStore())
        _navigatorModel = State(initialValue: navigatorModel ?? ProjectNavigatorModel())
        _tabsModel = State(initialValue: tabsModel ?? WorkbenchTabsModel())
        self.projectFiles = projectFiles
        self.workspace = workspace
        self.settings = settings
        self.quitRequest = quitRequest
        self.openSettingsRequest = openSettingsRequest
        self.terminate = terminate
        _sidebarVisibility = sidebarVisibility
        self.canAutomaticallyPresentInteraction = canAutomaticallyPresentInteraction
        _imagePreview = State(initialValue: initialImagePreview)
    }

    var body: some View {
        observedWindowContent
            .sheet(item: $modal, onDismiss: sheetDidDismiss, content: presentedModal)
            .scrollIndicators(.never)
    }

    private var observedWindowContent: some View {
        windowWithEditorObservers
            .onChange(of: workspace.newSessionRequest) { _, _ in requestNewSession() }
            .onChange(of: workspace.openProjectRequest) { _, _ in openProject() }
            .onChange(of: openSettingsRequest) { _, _ in presentSettings(.general) }
            .onChange(of: settings.preferences) { _, value in workspace.setPreferences(value) }
            .onChange(of: quitRequest) { _, _ in prepareToQuit(restarting: false) }
            .onChange(of: shouldKeepPresentedInteraction) { _, keepPresented in
                if !keepPresented, case .interaction = modal { modal = nil }
            }
            .onChange(of: modal != nil) { _, hasModal in
                if hasModal { imagePreview = nil }
            }
            .onChange(of: preparingToQuit) { _, quitting in
                if quitting { imagePreview = nil }
            }
            .onChange(of: workspace.viewed?.id) { _, _ in
                imagePreview = nil
                tabsModel.invalidateFileOpenRequests()
            }
            .onChange(of: imagePreview?.isCurrent) { _, current in
                if current == false { imagePreview = nil }
            }
    }

    private var windowWithEditorObservers: some View {
        windowWithSystemObservers
            .onChange(of: workspace.completedTurnsByDirectory) { previous, current in
                for (path, turns) in current where previous[path] != turns {
                    gitStore.refresh(directory: path, force: true)
                    tabsModel.checkExternalChanges(in: path)
                }
            }
            .onChange(of: workspace.state.selectedSessionID, initial: true) { _, id in
                tabsModel.syncActiveConversation(id)
                if let id, let path = workspace.workingDirectory(for: id) {
                    gitStore.refresh(directory: path)
                }
            }
            .onChange(of: workspace.state.sessions.map(\.id)) { _, _ in
                let activeIDs = Set(workspace.state.sessions.filter { $0.archivedAt == nil }.map(\.id))
                tabsModel.pruneConversations(validIDs: activeIDs)
            }
            .onChange(of: projectFiles.isOpen) { _, open in
                syncProjectFilesOpenState(open)
            }
            .onChange(of: tabsModel.isEditorVisible) { _, visible in
                syncEditorVisibleState(visible)
            }
            .onChange(of: showsEditorArea) { _, visible in
                if !visible { tabsModel.invalidateFileOpenRequests() }
            }
            .onChange(of: filesAreBlocked) { _, blocked in
                if blocked { tabsModel.invalidateFileOpenRequests() }
            }
            .onDisappear { tabsModel.invalidateFileOpenRequests() }
    }

    private var windowWithSystemObservers: some View {
        windowContent
            .onGeometryChange(for: CGSize.self, of: \.size) { workbenchSize = $0 }
            .task(id: workspace.initialized) { await workspace.refreshWorkspaceHistory() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                handleApplicationDidBecomeActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
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
    }

    private func handleApplicationDidBecomeActive() {
        if let id = workspace.selected?.id, let path = workspace.workingDirectory(for: id) {
            gitStore.refresh(directory: path, force: true)
        }
        for project in workspace.state.projects where navigatorModel.mode(for: project.id) != .sessions {
            gitStore.refresh(directory: project.path)
        }
        tabsModel.checkExternalChanges()
        Task { await settings.notifications.refreshAuthorization() }
        Task { await workspace.refreshWorkspaceHistory() }
        presentCurrentInteractionIfPossible()
    }

    private func syncProjectFilesOpenState(_ open: Bool) {
        guard open != tabsModel.isEditorVisible else { return }
        if open {
            if let first = tabsModel.editorTabs.first, tabsModel.activeEditorTabID == nil {
                tabsModel.activateEditorTab(first.id)
            } else {
                tabsModel.isEditorVisible = true
            }
        } else {
            tabsModel.isEditorVisible = false
        }
    }

    private func syncEditorVisibleState(_ visible: Bool) {
        if visible && !projectFiles.isOpen { projectFiles.open() }
        else if !visible && projectFiles.isOpen { projectFiles.close() }
        if visible && workbenchSize.width > 0 && workbenchSize.width < 1000 && sidebarVisibility != .detailOnly {
            sidebarVisibility = .detailOnly
        }
    }

    private func presentedModal(_ value: WorkbenchModal) -> some View {
        Group {
            switch value {
            case .interaction(let request, let controller, let title, let projectDirectory):
                InteractionView(request: request, controller: controller, sessionTitle: title, availableSize: workbenchSize,
                                projectDirectory: projectDirectory)
                    .id(request.id)
            case .toolFailures(let failures):
                ToolFailureDetailsSheet(failures: failures, close: { modal = nil })
            case .taskPlan(let controller):
                TaskPlanDetailsSheet(controller: controller, close: { modal = nil })
            case .chooseSessionProject:
                projectSelectionSheet
            case .importACPHistory(let projectID, let directory):
                ACPHistoryImportView(workspace: workspace, settings: settings, projectID: projectID, directory: directory) {
                    sidebarFilter.reveal(in: projectID)
                } openAgentSettings: { agentID in
                    actionAfterSheet = { presentConnectionSettings(for: agentID) }
                    modal = nil
                }
            case .confirmation(let request):
                FlatConfirmation(request: request, cancel: { modal = nil }) { action in
                    actionAfterSheet = action
                    modal = nil
                }
            case .settings(let section):
                SettingsPanel(workspace: workspace, settings: settings, initialSection: section,
                              preferredProjectID: sidebarFilter.projectID ?? workspace.selectedProject?.id,
                              availableSize: workbenchSize, providerConnectionRequest: $providerConnectionRequest,
                              projectDeleted: { id in
                                  if sidebarFilter.projectID == id { sidebarFilter.projectID = nil }
                              },
                              openArchivedSession: openArchivedSession,
                              close: { modal = nil }, restart: { prepareToQuit(restarting: true) })
                    .presentationSizing(.fitted)
            }
        }
        .flatPanelContent()
        .zivviTypography(settings.interfaceFontSize)
        .presentationBackground(ZivviTheme.pageBackground)
    }

    private var windowContent: some View {
        ZStack {
            VStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    workbenchSidebar
                } detail: {
                    workbenchDetail
                }
                .overlay {
                    SidebarDividerHighlight(isEnabled: sidebarVisibility != .detailOnly && !filesAreBlocked)
                }

                GlobalStatusBar(
                    workspace: workspace,
                    toolSearchPaths: settings.acpAgents.filter(\.enabled).flatMap(\.toolSearchPaths),
                    showsAntigravityQuota: settings.showsAntigravityQuota,
                    openSettings: { presentSettings(.general) },
                    toggleDashboard: { workspace.usageExpanded.toggle() }
                )
            }
            .allowsHitTesting(imagePreview == nil)
            .accessibilityHidden(imagePreview != nil)
            .background {
                WorkbenchTitlebar(
                    sidebarVisibility: $sidebarVisibility,
                    workspace: workspace,
                    tabsModel: tabsModel,
                    gitStore: gitStore,
                    detailWidth: detailWidth,
                    showsEditorArea: showsEditorArea,
                    editorWidth: resolvedEditorWidth,
                    isLightboxPresented: imagePreview != nil,
                    onSelectSession: { selectSessionInTabs($0) },
                    onCloseSession: { closeConversationTab($0) },
                    onNewSession: requestNewSession,
                    onManageSession: requestSessionManagement,
                    onJumpToGit: { jumpProjectToGit($0) },
                    onToggleEditor: { toggleEditorArea() },
                    onRequestCloseEditorTab: { requestCloseEditorTab($0) },
                    onCollapseEditor: { tabsModel.isEditorVisible = false }
                )
                .frame(width: 0, height: 0)
            }

            if let imagePreview, imagePreview.isCurrent {
                AttachmentImagePreview(selection: imagePreview) {
                    self.imagePreview = nil
                }
                .zIndex(10)
            }
        }
        .background(ZivviTheme.pageBackground.ignoresSafeArea())
        .onChange(of: filesAreBlocked, initial: true) { _, blocked in
            projectFiles.blocked = blocked
        }
    }

    private var activeEditorFile: (projectID: UUID, path: ProjectFilePath)? {
        guard tabsModel.isEditorVisible,
              let kind = tabsModel.activeEditorTab?.kind,
              case .file(let projectID, _, _, let path, _) = kind else { return nil }
        return (projectID, path)
    }

    private var activeEditorDiff: (projectID: UUID, path: String, scope: GitDiffScope)? {
        guard tabsModel.isEditorVisible,
              let kind = tabsModel.activeEditorTab?.kind,
              case .gitDiff(let projectID, _, _, let path, _, let scope, _) = kind else { return nil }
        return (projectID, path, scope)
    }

    private var activeEditorCommit: (projectID: UUID, hash: String)? {
        guard tabsModel.isEditorVisible,
              let kind = tabsModel.activeEditorTab?.kind,
              case .commit(let projectID, _, _, let hash, _, _) = kind else { return nil }
        return (projectID, hash)
    }

    private var workbenchSidebar: some View {
        SessionSidebar(
            workspace: workspace,
            filter: $sidebarFilter,
            navigator: navigatorModel,
            gitStore: gitStore,
            openProject: openProject,
            createSessionInProject: { createSession(in: $0) },
            onSelectSession: { selectSessionInTabs($0) },
            onOpenFile: { project, entry in openEditorFile(project: project, entry: entry) },
            onOpenDiff: { project, change, checkoutRoot in
                openEditorDiff(project: project, change: change, checkoutRoot: checkoutRoot)
            },
            onOpenCommit: { project, commit in openEditorCommit(project: project, commit: commit) },
            manageSession: requestSessionManagement,
            activeEditorFile: activeEditorFile,
            activeEditorDiff: activeEditorDiff,
            activeEditorCommit: activeEditorCommit,
            showsImportHistory: settings.acpAgents.contains(where: { $0.enabled }),
            importHistory: { requestACPHistory() }
        )
        .frame(minWidth: Self.minimumSidebarWidth)
        .navigationSplitViewColumnWidth(min: Self.minimumSidebarWidth, ideal: 260, max: 380)
        .toolbar(removing: .sidebarToggle)
    }

    private static let minimumConversationWidth: CGFloat = 420
    private static let minimumEditorWidth: CGFloat = 360

    private var canFitEditorArea: Bool {
        detailWidth == 0 || detailWidth >= Self.minimumConversationWidth + Self.minimumEditorWidth + 1
    }

    private var showsEditorArea: Bool {
        tabsModel.isEditorVisible && canFitEditorArea
    }

    private var resolvedEditorWidth: CGFloat {
        guard detailWidth > 0 else { return 480 }
        let maxEditor = max(Self.minimumEditorWidth, detailWidth - Self.minimumConversationWidth - 1)
        let target = preferredEditorWidth ?? floor(detailWidth * 0.45)
        return min(maxEditor, max(Self.minimumEditorWidth, target))
    }

    private var filesAreBlocked: Bool {
        modal != nil || preparingToQuit || actionAfterSheet != nil || imagePreview != nil
    }

    private var workbenchDetail: some View {
        VStack(spacing: 0) {
            ZivviDivider(color: ZivviTheme.subtleDivider)
            HStack(spacing: 0) {
                sessionColumn(excludedTrailingWidth: 0)
                    .frame(minWidth: Self.minimumConversationWidth, maxWidth: .infinity, maxHeight: .infinity)

                if showsEditorArea {
                    editorDivider
                    WorkbenchEditorArea(
                        tabsModel: tabsModel,
                        fileOpen: settings.fileOpen,
                        gitStore: gitStore,
                        canOpenExternally: { showsEditorArea && !filesAreBlocked }
                    )
                    .frame(width: resolvedEditorWidth)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZivviTheme.pageBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { detailWidth = $0 }
        .onChange(of: detailWidth) { _, width in
            // Auto-collapse sidebar first when space gets tight with Editor Area open (confirmed A4).
            if tabsModel.isEditorVisible && width > 0 && width < Self.minimumConversationWidth + Self.minimumEditorWidth + 1,
               sidebarVisibility != .detailOnly {
                sidebarVisibility = .detailOnly
            }
        }
    }

    private var editorDivider: some View {
        let maxEditor = max(Self.minimumEditorWidth, detailWidth - Self.minimumConversationWidth - 1)
        let canResize = maxEditor > Self.minimumEditorWidth + 2
        let isDragging = editorDragWidth != nil
        let isHighlighted = canResize && (isHoveringEditorDivider || isDragging)
        let currentWidth = resolvedEditorWidth

        return ZStack {
            ZivviDivider(axis: .vertical, color: ZivviTheme.subtleDivider)
            Rectangle()
                .fill(ResizeDividerStyle.color(hovering: isHighlighted, dragging: isDragging))
                .frame(width: isHighlighted ? ResizeDividerStyle.activeWidth : 0)
        }
        .frame(width: 1)
        .overlay {
            Color.clear
                .frame(width: ResizeDividerStyle.hitWidth)
                .contentShape(Rectangle())
                .allowsHitTesting(canResize)
                .onHover { hovering in
                    isHoveringEditorDivider = hovering && canResize
                }
                .pointerStyle(editorDividerPointerStyle(width: currentWidth, maxWidth: maxEditor,
                                                        canResize: canResize, isDragging: isDragging))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { change in
                            let initial = editorDragWidth ?? currentWidth
                            editorDragWidth = initial
                            preferredEditorWidth = min(maxEditor, max(Self.minimumEditorWidth, initial - change.translation.width))
                        }
                        .onEnded { _ in editorDragWidth = nil }
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: ResizeDividerStyle.animationDuration), value: isHighlighted)
        .accessibilityHidden(!canResize)
        .accessibilityLabel("调整编辑区宽度")
        .accessibilityValue(Text(verbatim: String(Int(currentWidth))))
        .accessibilityAdjustableAction { direction in
            let change: CGFloat = direction == .increment ? 24 : -24
            preferredEditorWidth = min(maxEditor, max(Self.minimumEditorWidth, currentWidth + change))
        }
    }

    private func editorDividerPointerStyle(width: CGFloat, maxWidth: CGFloat,
                                           canResize: Bool, isDragging: Bool) -> PointerStyle {
        guard canResize else { return .default }
        if isDragging { return .columnResize }
        var directions: HorizontalDirection.Set = []
        if width < maxWidth - 0.5 { directions.insert(.leading) }
        if width > Self.minimumEditorWidth + 0.5 { directions.insert(.trailing) }
        return directions.isEmpty ? .default : .columnResize(directions: directions)
    }

    private func selectSessionInTabs(_ id: UUID) {
        tabsModel.openConversation(id)
        Task {
            guard tabsModel.activeConversationID == id else { return }
            await workspace.openSessionForReview(id)
        }
    }

    private func closeConversationTab(_ id: UUID) {
        let wasActive = tabsModel.activeConversationID == id
        let next = tabsModel.closeConversation(id)
        guard wasActive || workspace.state.selectedSessionID == id else { return }
        if let next {
            Task {
                guard tabsModel.activeConversationID == next else { return }
                await workspace.select(next)
            }
        } else {
            workspace.clearSelection(for: id)
        }
    }

    private func openEditorFile(project: ProjectRecord, entry: ProjectFileEntry) {
        if workbenchSize.width > 0 && workbenchSize.width < 1000 && sidebarVisibility != .detailOnly {
            sidebarVisibility = .detailOnly
        }
        tabsModel.openFile(project: project, entry: entry)
    }

    private func openEditorDiff(project: ProjectRecord, change: GitFileChange, checkoutRoot: String) {
        if workbenchSize.width > 0 && workbenchSize.width < 1000 && sidebarVisibility != .detailOnly {
            sidebarVisibility = .detailOnly
        }
        tabsModel.openGitDiff(project: project, change: change, checkoutRoot: checkoutRoot)
    }

    private func openEditorCommit(project: ProjectRecord, commit: GitCommitSummary) {
        if workbenchSize.width > 0 && workbenchSize.width < 1000 && sidebarVisibility != .detailOnly {
            sidebarVisibility = .detailOnly
        }
        tabsModel.openCommit(project: project, commit: commit)
    }

    private func openToolDiffInEditor(_ item: TranscriptItem) {
        guard let sessionID = workspace.viewed?.id else { return }
        let projectName = workspace.selectedProject?.displayName
        tabsModel.openToolDiff(item, sessionID: sessionID, projectName: projectName,
                               title: String(localized: "历史工具变更")) { [weak workspace] in
            workspace?.transcriptToolSummary(for: item, in: sessionID)
        }
    }

    private func requestCloseEditorTab(_ tab: WorkbenchTabsModel.EditorTab) {
        guard !tab.isSaving, !tabsModel.isPreparingToTerminate else { return }
        guard tab.isDirty else {
            tabsModel.forceCloseEditorTab(tab.id)
            return
        }
        let name = tabsModel.displayTitle(for: tab)
        presentConfirmation(ConfirmationRequest(
            title: "保存对「\(name)」的更改？",
            message: "关闭前可以选择保存更改或直接放弃未保存的编辑。",
            confirmTitle: "保存并关闭",
            destructive: false,
            cancelTitle: "取消",
            defaultsToCancel: false,
            alternative: .init(title: "放弃更改", treatment: .outlined) {
                tabsModel.forceCloseEditorTab(tab.id)
            }
        ) {
            Task {
                if await tabsModel.saveTab(tab) {
                    if let root = tab.kind.rootPath {
                        gitStore.refresh(directory: root, force: true)
                    }
                    if !tab.isDirty { tabsModel.forceCloseEditorTab(tab.id) }
                }
            }
        })
    }

    private func jumpProjectToGit(_ project: ProjectRecord) {
        sidebarVisibility = .all
        navigatorModel.setMode(.git, for: project, gitStore: gitStore)
    }

    private func toggleEditorArea() {
        if !tabsModel.isEditorVisible && workbenchSize.width > 0 && workbenchSize.width < 1000 && sidebarVisibility != .detailOnly {
            sidebarVisibility = .detailOnly
        }
        tabsModel.toggleEditorArea()
    }

    private func sessionColumn(excludedTrailingWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            backgroundRuns
            if let viewed = workspace.viewed {
                SessionDetail(workspace: workspace, settings: settings, presentation: viewed,
                              windowScrollState: readingPositions.state(for: viewed.id),
                              blocksComposerPanels: modal != nil || actionAfterSheet != nil || preparingToQuit || imagePreview != nil,
                              excludedTrailingWidth: excludedTrailingWidth,
                              openConnectionSettings: presentConnectionSettings, presentConfirmation: presentConfirmation,
                              presentToolFailures: presentToolFailures,
                              presentTaskPlan: presentTaskPlan,
                              presentInteraction: { presentInteraction(for: viewed.id) },
                              onOpenFile: openTranscriptFile,
                              onOpenToolDiff: openToolDiffInEditor,
                              onOpenHandoffFile: { await openHandoffFile($0, from: $1, for: viewed.id) },
                              onPreviewImage: presentImagePreview)
                    .id(viewed.id)
            } else if !workspace.state.projects.isEmpty {
                FlatEmptyState("选择一个会话", systemImage: "bubble.left",
                               description: Text("从侧栏选择会话，或新建会话。")) {
                    Button("新建会话", action: requestNewSession)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(!workspace.canManageProjects)
                }
            } else {
                FlatEmptyState("选择一个项目", systemImage: "folder",
                               description: Text("打开本地项目后，可创建会话或只读浏览历史。")) {
                    Button(action: openProject) {
                        LightningLabel("打开项目…", icon: .folderBadgePlus, size: 14)
                            .zivviFont(.callout)
                    }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(!workspace.canManageProjects)
                }
            }
            if let message = workspace.storageError {
                HStack {
                    LightningIconView(.exclamationmarkCircle, size: 14)
                    Text(message)
                    if workspace.initialized { Button("重试保存") { Task { _ = await workspace.flush() } } }
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .zivviFont(.caption).padding(12)
                .flatSurface(ZivviTheme.mutedSurface, radius: 10)
            }
            if let error = workspace.error { FeedbackBanner(text: error, warning: true) }
            if let notice = workspace.notice { FeedbackBanner(text: notice, warning: false) }
            if let sessionManagementError { FeedbackBanner(text: sessionManagementError, warning: true) }
            if let id = lastArchivedSessionID, workspace.state.sessions.contains(where: { $0.id == id && $0.archivedAt != nil }) {
                SessionArchivedBanner(undoDisabled: workspace.isOperating(on: id) || workspace.storageError != nil,
                                      undo: { undoArchive(id) }, dismiss: { lastArchivedSessionID = nil })
            }
        }
    }

    private func presentImagePreview(_ selection: ImagePreviewSelection) {
        guard modal == nil, actionAfterSheet == nil, !preparingToQuit else { return }
        var selection = selection
        if selection.toolResult != nil {
            guard let session = workspace.viewed else { return }
            selection.toolResult?.includesItem = session.transcriptItemValidator
        }
        guard selection.isCurrent else { return }
        imagePreview = selection
    }

    private func openTranscriptFile(_ rawURL: URL) {
        guard !filesAreBlocked else { return }
        let fileURL = TranscriptFileOpener.withoutFragment(rawURL)
        let line = TranscriptFileOpener.lineReference(in: rawURL)
        let fileOpen = settings.fileOpen
        let location = projectLocation(for: fileURL)
        let sessionID = workspace.viewed?.id
        let visibility = projectFiles.visibilityRevision
        let isCurrent = tabsModel.beginLinkedFileOpen {
            guard !filesAreBlocked, workspace.viewed?.id == sessionID,
                  projectFiles.visibilityRevision == visibility else { return false }
            let current = projectLocation(for: fileURL)
            return current?.0.id == location?.0.id && current?.1 == location?.1
        }
        Task {
            if let (project, directory, path) = location {
                let outcome = await tabsModel.openLinkedFile(project: project, rootPath: directory, path: path,
                                                             line: line, isCurrent: isCurrent)
                guard case .unavailable = outcome else { return }
            }
            let request = TranscriptFileOpener.Request(url: fileURL, contextIsCurrent: isCurrent) {
                await Task.detached { FileManager.default.fileExists(atPath: fileURL.path) }.value
            }
            await TranscriptFileOpener.open(request, line: line, configuration: fileOpen)
        }
    }

    private func projectLocation(for fileURL: URL) -> (ProjectRecord, String, ProjectFilePath)? {
        // Prefer the viewed session's working directory to the project's root.
        if let viewed = workspace.viewed,
           let session = workspace.state.sessions.first(where: { $0.id == viewed.id }),
           let project = workspace.state.projects.first(where: { $0.id == session.projectID }),
           let dir = workspace.workingDirectory(for: viewed.id),
           let rel = ProjectFilePath.relativePath(from: fileURL, within: dir) {
            return (project, dir, rel)
        }
        for project in workspace.state.projects {
            if let rel = ProjectFilePath.relativePath(from: fileURL, within: project.path) {
                return (project, project.path, rel)
            }
        }
        return nil
    }

    private func openHandoffFile(_ path: ProjectFilePath, from directory: URL,
                                 for sessionID: UUID) async -> WorkbenchTabsModel.LinkedFileOpenOutcome {
        guard !Task.isCancelled, !filesAreBlocked, workspace.viewed?.id == sessionID else { return .cancelled }
        let dirPath = directory.standardizedFileURL.path
        let project = workspace.state.projects.first {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == dirPath
        } ?? workspace.selectedProject
        guard let project else { return .unavailable(.rootUnavailable) }
        let visibility = projectFiles.visibilityRevision
        let isCurrent = tabsModel.beginLinkedFileOpen {
            !filesAreBlocked && workspace.viewed?.id == sessionID && projectFiles.visibilityRevision == visibility
        }
        return await tabsModel.openLinkedFile(project: project, rootPath: dirPath, path: path, isCurrent: isCurrent)
    }

    private func presentToolFailures(_ failures: [TranscriptItem]) {
        guard modal == nil, actionAfterSheet == nil, !preparingToQuit, !failures.isEmpty else { return }
        modal = .toolFailures(failures)
    }

    private func presentTaskPlan(_ controller: SessionController) {
        guard modal == nil, actionAfterSheet == nil, !preparingToQuit, !controller.plan.isEmpty else { return }
        modal = .taskPlan(controller)
    }

    private func openProject() {
        guard !preparingToQuit, modal == nil, workspace.canManageProjects, let url = settings.pickProject() else { return }
        Task {
            guard let project = await workspace.addProject(url) else { return }
            if workspace.defaultRuntimeID == nil { presentSettings(.providers) }
            if workspace.selected?.projectID == project {
                sidebarFilter.reveal(in: project)
                sidebarVisibility = .all
            }
        }
    }
    private func requestACPHistory() {
        guard !preparingToQuit, modal == nil, workspace.canManageProjects,
              let projectID = sidebarFilter.projectID ?? workspace.selectedProject?.id ?? workspace.state.projects.first?.id,
              let project = workspace.state.projects.first(where: { $0.id == projectID }) else { return }
        let directory = workspace.selected.flatMap { session in
            session.projectID == projectID ? workspace.workingDirectory(for: session.id) : nil
        } ?? project.path
        modal = .importACPHistory(projectID, directory)
    }

    private func requestNewSession() {
        guard !preparingToQuit, modal == nil, workspace.canManageProjects else { return }
        guard workspace.defaultRuntimeID != nil else { presentSettings(.providers); return }
        guard !workspace.state.projects.isEmpty else { openProject(); return }
        if let project = sidebarFilter.projectID ?? workspace.selectedProject?.id {
            createSession(in: project, showsSidebar: false)
        } else {
            modal = .chooseSessionProject
        }
    }

    private var projectSelectionSheet: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            Text("选择新会话的项目").zivviFont(.title3, weight: .semibold)
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
            VStack(spacing: ZivviSpacing.dialogItemGap) {
                ZivviDivider()
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { modal = nil }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .keyboardShortcut(.cancelAction)
                }
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

    private func requestSessionManagement(_ action: SessionManagementAction, id: UUID) {
        guard !preparingToQuit, modal == nil, actionAfterSheet == nil,
              let session = workspace.state.sessions.first(where: { $0.id == id }) else { return }
        sessionManagementError = nil
        switch action {
        case .archive:
            if let reason = workspace.sessionArchiveBlockReason(for: session) {
                sessionManagementError = String(localized: reason)
                return
            }
            func archive(confirm: Bool) {
                Task {
                    if await workspace.setSessionArchived(id, archived: true, confirmRelease: confirm) { lastArchivedSessionID = id }
                    else if workspace.storageError == nil { sessionManagementError = String(localized: "无法归档会话，请重试。") }
                }
            }
            if workspace.archiveRequiresConfirmation(id) {
                presentConfirmation(ConfirmationRequest(title: "归档后无法继续此会话？",
                    message: "历史记录仍可查看。", confirmTitle: "归档", defaultsToCancel: true) { archive(confirm: true) })
            } else {
                archive(confirm: false)
            }
        case .forceEnd:
            Task { await confirmForceEnd(id) }
        case .confirmRetirement:
            guard workspace.retirementRequiresConfirmation(id) else { return }
            presentConfirmation(ConfirmationRequest(title: "应用智能体配置并结束此会话？",
                message: "关闭后无法继续此会话。历史记录和草稿仍可查看。", confirmTitle: "结束会话",
                defaultsToCancel: true) { Task { await workspace.confirmRetirement(id) } })
        case .deleteRemoteHistory:
            guard let target = workspace.remoteHistoryDeletionTarget(for: id) else { return }
            let agent = CodingAgentLabel.displayName(for: target.agentID, agents: settings.acpAgents)
            let revision = settings.acpConfigurationRevision(for: target.agentID)
            presentConfirmation(ConfirmationRequest(
                title: "从 Agent 历史删除？",
                message: "将从「\(agent)」删除「\(session.displayTitle)」。本地记录和草稿将保留为只读。",
                confirmTitle: "删除 Agent 历史",
                defaultsToCancel: true
            ) {
                Task {
                    do {
                        try await settings.withACPHistoryControl(agentID: target.agentID,
                                                                 directory: URL(fileURLWithPath: target.directory),
                                                                 revision: revision) { control in
                            try await workspace.deleteRemoteHistory(target, sharedConnectionID: await control.sharedConnectionID) { remoteID in
                                try await control.delete(sessionID: remoteID)
                            }
                        }
                    } catch {
                        sessionManagementError = (error as? RuntimeFailure)?.detail ?? error.localizedDescription
                    }
                }
            })
        case .deleteDraft:
            guard workspace.canDeleteDraft(session) else { return }
            if workspace.hasDraft(session) {
                presentConfirmation(ConfirmationRequest(
                    title: "删除草稿？",
                    message: "将删除该会话的未发送内容和附件引用。",
                    confirmTitle: "删除草稿",
                    defaultsToCancel: true
                ) { deleteLocalDraft(id, discardContents: true) })
            } else {
                deleteLocalDraft(id, discardContents: false)
            }
        }
    }

    private func confirmForceEnd(_ id: UUID, sharedOnly: Bool = false) async {
        guard let controller = workspace.execution(for: id) else { return }
        guard let impact = await controller.sharedConnectionImpact() else {
            if !sharedOnly { _ = await workspace.disconnect(id, force: true) }
            return
        }
        let affected = workspace.state.sessions.compactMap { session -> String? in
            guard let active = workspace.execution(for: session.id), let runtimeID = active.runtimeInstanceID,
                  impact.runtimeIDs.contains(runtimeID) else { return nil }
            if active.interactions.contains(where: \.isPermissionApproval) {
                return String(localized: "\(session.displayTitle)（等待审批）")
            }
            if active.phase.isActive { return String(localized: "\(session.displayTitle)（运行中）") }
            return session.displayTitle
        }
        let list = affected.joined(separator: "\n")
        presentConfirmation(ConfirmationRequest(title: "结束共享 ACP 进程？",
            message: "以下会话将断开：\n\(list)", confirmTitle: "结束进程", defaultsToCancel: true) {
            Task {
                do {
                    if try await controller.forceEndSharedConnection(matching: impact) == false {
                        await confirmForceEnd(id, sharedOnly: true)
                    }
                } catch {
                    sessionManagementError = (error as? RuntimeFailure)?.detail ?? error.localizedDescription
                }
            }
        })
    }

    private func deleteLocalDraft(_ id: UUID, discardContents: Bool) {
        Task {
            if !(await workspace.deleteDraft(id, discardContents: discardContents)), workspace.storageError == nil {
                sessionManagementError = String(localized: "无法删除草稿，请重试。")
            }
        }
    }

    private func undoArchive(_ id: UUID) {
        sessionManagementError = nil
        Task {
            if await workspace.setSessionArchived(id, archived: false) {
                if lastArchivedSessionID == id { lastArchivedSessionID = nil }
            } else if workspace.storageError == nil {
                sessionManagementError = String(localized: "无法取消归档，请重试。")
            }
        }
    }

    private func openArchivedSession(_ id: UUID) {
        guard !preparingToQuit, case .settings = modal else { return }
        actionAfterSheet = { Task { await workspace.select(id) } }
        modal = nil
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
        guard let runtimeID = workspace.defaultRuntimeID else { presentSettings(.providers); return }
        Task {
            if let id = await workspace.createSession(in: project, runtimeID: runtimeID), workspace.state.selectedSessionID == id {
                sidebarFilter.reveal(in: project)
                if showsSidebar { sidebarVisibility = .all }
            }
        }
    }

    private func presentSettings(_ section: SettingsSection) {
        guard !preparingToQuit, modal == nil else { return }
        providerConnectionRequest = nil
        modal = .settings(section)
    }

    private func presentConnectionSettings(for runtimeID: String) {
        guard !preparingToQuit,
              ProviderConnectionRequest.hasDestination(for: runtimeID, agents: settings.acpAgents) else { return }
        let nextRequest = ProviderConnectionRequest(runtimeID: runtimeID,
                                                    sequence: (providerConnectionRequest?.sequence ?? 0) + 1)
        if case .settings = modal {
            providerConnectionRequest = nextRequest
        } else if modal == nil {
            providerConnectionRequest = nextRequest
            modal = .settings(.providers)
        }
    }

    @ViewBuilder private var backgroundRuns: some View {
        let ids = backgroundExecutionIDs
        if ids.count > 3 {
            ScrollView {
                LazyVStack(spacing: 0) { backgroundRunRows(ids) }
            }
            .frame(height: 96)
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
        guard case .interaction(let request, let controller, _, _) = modal else { return true }
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
        let session = workspace.state.sessions.first { $0.id == id }
        let title = session?.displayTitle ?? String(localized: "执行会话")
        lastPresentedInteractionID = request.id
        let projectDirectory = session.flatMap { session in
            workspace.state.projects.first { $0.id == session.projectID }?.path
        }
        modal = .interaction(request, controller, title, projectDirectory: projectDirectory)
    }
}

struct SessionDetail: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let presentation: SessionPresentation
    var windowScrollState: TranscriptScrollState? = nil
    var blocksComposerPanels = false
    var excludedTrailingWidth: CGFloat = 0
    let openConnectionSettings: (String) -> Void
    let presentConfirmation: (ConfirmationRequest) -> Void
    var presentToolFailures: ([TranscriptItem]) -> Void = { _ in }
    var presentTaskPlan: (SessionController) -> Void = { _ in }
    var presentInteraction: (() -> Void)? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    @State private var enteredAsLocalDraft: Bool?
    @State private var hasShownConversation = false
    @State private var extensionStatusExpanded = false
    @State private var autoConnectAttempted = false
    @State private var isSubmitting = false
    @State private var isPlanDismissed = false
    @State private var isCachedHistoryDismissed = false
    @State private var isComposerFocused = false
    @State private var historyEditTask: Task<Void, Never>?
    @State private var historyEditError: String?
    @State private var fallbackScrollState = TranscriptScrollState()
    private var transcriptScrollState: TranscriptScrollState { windowScrollState ?? fallbackScrollState }

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    func connectionSettingsRuntimeID(agents: [RuntimeAgentProfile]) -> String? {
        guard let reference, let failure = presentation.controller.failure,
              workspace.storageError == nil,
              failure.kind == .authentication || (presentation.controller.connection == .disconnected &&
                  (failure.kind == .setup || failure.kind == .unsupportedVersion)),
              ProviderConnectionRequest.hasDestination(for: reference.runtimeID, agents: agents) else { return nil }
        return reference.runtimeID
    }

    private var isArchived: Bool { reference?.archivedAt != nil }
    private var isLocalDraftAtEntry: Bool {
        guard let reference else { return false }
        return !reference.hasBoundRuntime &&
            reference.submissions.isEmpty && presentation.controller.recoveredDrafts.isEmpty
    }

    private var starterProject: ProjectRecord? {
        guard !isArchived, enteredAsLocalDraft ?? isLocalDraftAtEntry,
              !hasShownConversation, let reference, presentation.controller.transcript.isEmpty,
              presentation.frozenRows.isEmpty, reference.handoff == nil,
              presentation.controller.transcriptTurnStarts.isEmpty,
              !presentation.loading, presentation.loadError == nil, presentation.executionIssue == nil,
              !reference.submissions.contains(where: \.needsReview) else { return nil }
        return workspace.state.projects.first { $0.id == reference.projectID }
    }

    var canSend: Bool {
        guard workspace.initialized, workspace.storageError == nil, !workspace.isOperating(on: presentation.id), !presentation.loading,
              presentation.loadError == nil, presentation.executionIssue == nil,
              reference?.submissions.contains(where: \.needsReview) != true else { return false }
        if let handoff = reference?.handoff, !handoff.delivered, handoff.firstSubmissionID != nil { return false }
        if workspace.execution(for: presentation.id) != nil, presentation.controller.connection == .connected {
            if reference?.pendingSelection != nil, presentation.controller.phase.isActive || !presentation.controller.queue.isEmpty { return false }
            return presentation.controller.canSend
        }
        return presentation.controller.draftPrompt.hasContent
    }
    var sessionConfigurationDisabled: Bool {
        !workspace.canConfigureSession(for: presentation.id)
    }
    var currentModel: ComposerModel? {
        if let pending = reference?.pendingSelection {
            return .init(provider: pending.provider, name: reference?.pendingModelName ?? pending.modelID,
                         thinking: pending.thinking ?? String(localized: "默认"), pending: true)
        }
        if let live = presentation.controller.session, let provider = live.provider {
            return .init(provider: provider, name: live.model, thinking: live.thinking, pending: false)
        }
        if let saved = reference?.selection {
            return .init(provider: saved.provider, name: reference?.modelName ?? saved.modelID,
                         thinking: saved.thinking ?? String(localized: "默认"), pending: false)
        }
        return nil
    }
    private func addFiles() {
        let controller = presentation.controller
        guard !controller.isDraftEditingLocked else { return }
        let directory = workspace.workingDirectory(for: presentation.id).map { URL(fileURLWithPath: $0) }
        Task {
            let files = await settings.pickFiles(in: directory)
            guard !controller.isDraftEditingLocked else { return }
            for file in files.map(\.standardizedFileURL) where !controller.draftFiles.contains(file) {
                controller.draftFiles.append(file)
            }
        }
    }
    private func send() {
        guard !isSubmitting else { return }
        let prompt = presentation.controller.draftPrompt
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            await workspace.send(presentation.id, submitted: prompt)
        }
    }

    private var canSyncCachedHistory: Bool {
        workspace.initialized && workspace.storageError == nil &&
            !isArchived && !blocksComposerPanels && !sessionConfigurationDisabled &&
            !workspace.isOperating(on: presentation.id) &&
            presentation.controller.connection == .disconnected &&
            presentation.executionIssue == nil &&
            !presentation.loading && presentation.loadError == nil &&
            presentation.controller.showingCachedHistory
    }

    private func autoConnectOnInputFocus() {
        guard !autoConnectAttempted,
              workspace.initialized,
              workspace.storageError == nil,
              !isArchived,
              !blocksComposerPanels,
              !sessionConfigurationDisabled,
              !workspace.isOperating(on: presentation.id),
              presentation.controller.connection == .disconnected,
              presentation.controller.failure == nil,
              reference?.handoff?.delivered != false,
              presentation.executionError == nil,
              presentation.executionIssue == nil,
              !presentation.loading,
              presentation.loadError == nil,
              presentation.controller.showingCachedHistory || reference?.hasBoundRuntime == true else { return }
        autoConnectAttempted = true
        Task { await workspace.activate(presentation.id) }
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

    private func confirmApprovalTimeoutRecovery(_ recovery: ApprovalTimeoutRecovery) {
        guard !blocksComposerPanels, workspace.approvalTimeoutRecovery(for: presentation.id) == recovery else { return }
        presentConfirmation(ConfirmationRequest(
            title: "继续刚才的任务？",
            message: "将在当前会话发起新一轮，继续处理剩余事项。已执行的操作会保留，需要审批时会重新请求。",
            confirmTitle: "确定", destructive: false, cancelTitle: "稍后", defaultsToCancel: true,
            alternative: .init(title: "查看审批记录", treatment: .outlined) {
                guard workspace.viewed?.id == presentation.id,
                      presentation.controller.transcript.contains(where: { $0.timelineID == recovery.recordID }) else { return }
                transcriptScrollState.revealApprovalRecord(recovery.recordID)
            }
        ) {
            Task { await workspace.continueAfterApprovalTimeout(recovery, in: presentation.id) }
        })
    }

    private var canEditHistoryMessage: Bool {
        !isArchived && !presentation.controller.isDraftEditingLocked &&
            (reference?.isACPRuntime != true || presentation.executionIssue == nil)
    }

    private func handleEditUserMessage(_ item: TranscriptItem) {
        guard canEditHistoryMessage, item.canRestoreToDraft else { return }
        historyEditTask?.cancel()
        historyEditTask = nil
        historyEditError = nil
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
        let controller = presentation.controller
        guard workspace.viewed?.id == presentation.id, canEditHistoryMessage, item.canRestoreToDraft,
              presentation.containsTranscriptItem(item) else { return }
        historyEditTask?.cancel()
        historyEditTask = nil
        let text = item.editableText
        let files = item.editableFiles
        let images = item.images.map(\.data)
        func restore() {
            controller.draft = text
            controller.draftFiles = files
            workspace.focusInput()
        }
        guard !images.isEmpty else { restore(); return }
        guard let imageFiles = item.confirmedReplayImageFiles else { return }
        let draft = controller.draft
        let draftFiles = controller.draftFiles
        historyEditTask = Task {
            let verification = Task.detached(priority: .utility) {
                TranscriptImageFiles.containsInOrder(images, in: imageFiles)
            }
            let hasMatchingImages = await withTaskCancellationHandler {
                await verification.value
            } onCancel: {
                verification.cancel()
            }
            guard !Task.isCancelled, workspace.viewed?.id == presentation.id, canEditHistoryMessage,
                  presentation.containsTranscriptItem(item),
                  item.editableFiles == files, item.images.map(\.data) == images,
                  item.confirmedReplayImageFiles == imageFiles,
                  controller.draft == draft, controller.draftFiles == draftFiles else { return }
            guard hasMatchingImages else {
                historyEditError = String(localized: "图片附件已变化，草稿保持原样。")
                return
            }
            restore()
        }
    }

    private var shouldAcknowledgeUnreadOnClick: Bool {
        reference?.hasUnreadCompletion == true &&
            workspace.state.selectedSessionID == presentation.id &&
            !blocksComposerPanels &&
            !presentation.loading &&
            presentation.loadError == nil
    }

    var body: some View {
        detailContent
        .background {
            SessionDetailClickMonitor(
                active: shouldAcknowledgeUnreadOnClick,
                excludedTrailingWidth: excludedTrailingWidth
            ) {
                workspace.acknowledgeUnreadCompletion(for: presentation.id)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear {
            if enteredAsLocalDraft == nil { enteredAsLocalDraft = isLocalDraftAtEntry }
        }
        .onDisappear {
            historyEditTask?.cancel()
            historyEditTask = nil
        }
        .onChange(of: presentation.controller.transcript.isEmpty) { _, empty in
            if !empty { hasShownConversation = true }
        }
        .onChange(of: presentation.controller.extensionStatus.isEmpty) { _, empty in
            if empty { extensionStatusExpanded = false }
        }
        .onChange(of: presentation.controller.connection) { _, connection in
            if connection == .connected { autoConnectAttempted = false }
        }
    }

    private var isStarterIdlePaused: Bool {
        isComposerFocused || !presentation.controller.draft.isEmpty
    }

    private var detailContent: some View {
        let isStarter = starterProject != nil
        return SessionDetailLayout(isStarter: isStarter) {
            if isStarter {
                SessionStarterTitle(isIdlePaused: isStarterIdlePaused)
            } else {
                historyContent
            }
        } footer: { viewportHeight in
            footerContent(viewportHeight: viewportHeight, isStarter: isStarter)
        }
        .onChange(of: presentation.controller.plan) { _, _ in isPlanDismissed = false }
        .onChange(of: presentation.controller.showingCachedHistory) { _, showing in
            if !showing { isCachedHistoryDismissed = false }
        }
    }

    private var historyContent: some View {
        let editUserMessage: ((TranscriptItem) -> Void)?
        if canEditHistoryMessage {
            editUserMessage = handleEditUserMessage
        } else {
            editUserMessage = nil
        }
        return VStack(spacing: 0) {
            if presentation.loading { FlatProgressView("正在读取历史…").padding(8) }
            if let error = presentation.loadError {
                FeedbackBanner(text: error, warning: true)
                Button("重新读取") { Task { await workspace.refreshHistory(presentation.id) } }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).padding(8)
            }
            if let issue = presentation.executionIssue {
                FeedbackBanner(text: issue, warning: true)
                if workspace.isHandoffCleanupPending(for: presentation.id) {
                    Button("重新读取") { Task { await workspace.refreshHistory(presentation.id) } }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).padding(8)
                }
            }
            TranscriptView(
                items: presentation.controller.transcript,
                frozenItems: presentation.frozenTranscript,
                frozenRows: presentation.frozenRows,
                activeHandoff: presentation.activeHandoffMarker,
                turnStarts: presentation.controller.transcriptTurnStarts,
                diagnosticSession: presentation.id.uuidString,
                historyLoading: presentation.loading,
                showsThinking: presentation.controller.connection == .connected &&
                    presentation.controller.phase == .running && !presentation.controller.isStopping,
                queue: presentation.controller.queue,
                queueIsKnown: presentation.controller.queueIsKnown,
                showsEmptyState: presentation.loadError == nil && presentation.executionIssue == nil,
                showingCachedHistory: presentation.controller.showingCachedHistory,
                composerClearance: 0,
                workspaceDirectory: workspace.workingDirectory(for: presentation.id).map { URL(fileURLWithPath: $0, isDirectory: true) },
                approvalProjectDirectory: reference.flatMap { session in
                    workspace.state.projects.first { $0.id == session.projectID }?.path
                },
                onOpenFile: onOpenFile,
                onOpenToolDiff: onOpenToolDiff,
                onOpenHandoffFile: onOpenHandoffFile,
                onEditUserMessage: editUserMessage,
                onPreviewImage: onPreviewImage,
                onSyncFullHistory: canSyncCachedHistory ? {
                    Task { await workspace.activate(presentation.id) }
                } : nil,
                onSwitchModel: { workspace.configurationRequest += 1 },
                onOpenConnectionSettings: connectionSettingsRuntimeID(agents: settings.acpAgents).map { id in
                    { openConnectionSettings(id) }
                },
                onSafeRetry: retryableModelPrompt.map { prompt in
                    { confirmModelRetry(prompt) }
                },
                includesToolResultItem: presentation.transcriptItemValidator,
                scrollState: transcriptScrollState
            ).id(presentation.id)
        }
    }

    private func buildComposerNotices() -> [ComposerNoticeItem] {
        var notices: [ComposerNoticeItem] = []
        let controller = presentation.controller

        // Priority 10: Pending approval / interactive requests blocking the task
        let pendingApprovals = controller.interactions.filter(\.isPermissionApproval)
        if !pendingApprovals.isEmpty, let presentInteraction {
            notices.append(ComposerNoticeItem(
                id: "pending-approval",
                priority: 10,
                severity: .warning,
                text: String(localized: "有 \(pendingApprovals.count) 项操作等待审批"),
                interaction: .actionableRow(hint: String(localized: "打开审批面板"), action: presentInteraction),
                accessibilityID: "composer-pending-approval"
            ))
        }

        // Priority 20: Approval timeout recovery
        if let recovery = workspace.approvalTimeoutRecovery(for: presentation.id) {
            notices.append(ComposerNoticeItem(
                id: "approval-timeout",
                priority: 20,
                severity: .warning,
                text: String(localized: "上一项操作因审批超时中断，点击继续任务"),
                interaction: .actionableRow(hint: String(localized: "确认继续任务"), action: { confirmApprovalTimeoutRecovery(recovery) }),
                accessibilityID: "composer-expired-interaction"
            ))
        }

        // Priority 30: Connection / Execution failure (deduplicated with in-transcript TurnExecutionErrorView)
        if let failure = controller.failure, !controller.latestTurnHasFailure {
            let presentationModel = ExecutionErrorPresentation(failure: failure)
            if let runtimeID = connectionSettingsRuntimeID(agents: settings.acpAgents) {
                notices.append(ComposerNoticeItem(
                    id: "failure-auth-setup",
                    priority: 30,
                    severity: .error,
                    text: "\(presentationModel.title)：\(presentationModel.message)",
                    interaction: .withAction(label: String(localized: "打开连接设置"), isBusy: false) {
                        openConnectionSettings(runtimeID)
                    },
                    accessibilityID: "composer-failure-settings"
                ))
            } else if presentationModel.category == .quotaExceeded || presentationModel.category == .contextExceeded {
                notices.append(ComposerNoticeItem(
                    id: "failure-quota",
                    priority: 30,
                    severity: .error,
                    text: "\(presentationModel.title)：\(presentationModel.message)",
                    interaction: .withAction(label: String(localized: "切换模型"), isBusy: false) {
                        workspace.configurationRequest += 1
                    },
                    accessibilityID: "composer-failure-switch-model"
                ))
            } else if let prompt = retryableModelPrompt {
                notices.append(ComposerNoticeItem(
                    id: "failure-retry",
                    priority: 30,
                    severity: .error,
                    text: failure.detail,
                    interaction: .withAction(label: String(localized: "重试"), isBusy: false) {
                        confirmModelRetry(prompt)
                    },
                    accessibilityID: "retry-model-turn"
                ))
            } else {
                notices.append(ComposerNoticeItem(
                    id: "failure-info",
                    priority: 30,
                    severity: .error,
                    text: failure.detail,
                    interaction: .informational,
                    accessibilityID: "composer-failure-info"
                ))
            }
        } else if let message = presentation.executionError ?? historyEditError {
            notices.append(ComposerNoticeItem(
                id: "execution-error",
                priority: 32,
                severity: .error,
                text: message,
                interaction: .informational
            ))
        }

        // Priority 40: Tool failures in current turn
        let toolFailures = controller.recentToolFailures
        if !toolFailures.isEmpty {
            notices.append(ComposerNoticeItem(
                id: "tool-failures",
                priority: 40,
                severity: .warning,
                text: String(localized: "本轮有 \(toolFailures.count) 项工具调用失败，点击查看详情"),
                interaction: .actionableRow(hint: String(localized: "查看失败工具详情"), action: { presentToolFailures(toolFailures) }),
                dismiss: { controller.dismissToolFailures(toolFailures) },
                accessibilityID: "composer-failed-tool"
            ))
        }

        // Priority 50: Connecting / restoring progress
        if isSubmitting && controller.connection == .connecting {
            notices.append(ComposerNoticeItem(
                id: "connecting-progress",
                priority: 50,
                severity: .progress,
                text: reference?.runtimeSessionID != nil ? String(localized: "正在恢复会话…") : String(localized: "正在连接智能体…"),
                interaction: .informational
            ))
        }

        // Priority 60: Offline cached history
        if controller.showingCachedHistory && presentation.executionIssue == nil && !isCachedHistoryDismissed {
            if canSyncCachedHistory {
                notices.append(ComposerNoticeItem(
                    id: "cached-history",
                    priority: 60,
                    severity: .information,
                    text: String(localized: "当前处于离线状态，展示缓存内容。"),
                    interaction: .withAction(label: String(localized: "重新连接"), isBusy: controller.connection == .connecting) {
                        Task { await workspace.activate(presentation.id) }
                    },
                    dismiss: { isCachedHistoryDismissed = true },
                    accessibilityID: "composer-cached-history"
                ))
            } else {
                notices.append(ComposerNoticeItem(
                    id: "cached-history",
                    priority: 60,
                    severity: .information,
                    text: String(localized: "当前处于离线状态，展示缓存内容。"),
                    interaction: .informational,
                    dismiss: { isCachedHistoryDismissed = true },
                    accessibilityID: "composer-cached-history"
                ))
            }
        }

        // Priority 70: Task plan progress
        if !controller.plan.isEmpty && !isPlanDismissed {
            let completed = controller.plan.count { $0.status == .completed }
            notices.append(ComposerNoticeItem(
                id: "task-plan",
                priority: 70,
                severity: .information,
                text: String(localized: "任务计划 · 已完成 \(completed)/\(controller.plan.count)"),
                interaction: .actionableRow(hint: String(localized: "查看任务计划"), action: { presentTaskPlan(controller) }),
                dismiss: { isPlanDismissed = true },
                accessibilityID: "composer-task-plan"
            ))
        }

        // Priority 80: General notice
        if let notice = controller.noticeExcludingComposerPills {
            notices.append(ComposerNoticeItem(
                id: "general-notice",
                priority: 80,
                severity: .information,
                text: notice,
                interaction: .informational
            ))
        }

        return notices
    }

    private func footerContent(viewportHeight: CGFloat, isStarter: Bool) -> some View {
        let maxNoticesHeight = max(84, floor(viewportHeight * 0.25))
        let maxEditorHeight = max(80, floor(viewportHeight * 0.30))
        return VStack(spacing: 0) {
            if isArchived {
                ComposerNoticesStack(
                    items: [
                        ComposerNoticeItem(
                            id: "archived",
                            priority: 0,
                            severity: .information,
                            text: String(localized: "此会话已归档。可在「设置 → 已归档」中取消归档。"),
                            interaction: .informational
                        )
                    ],
                    maxHeight: maxNoticesHeight
                )
                .padding(.bottom, 10)
            } else {
                if !presentation.controller.extensionStatus.isEmpty {
                    ExtensionStatusView(controller: presentation.controller, viewportHeight: viewportHeight,
                                        expanded: $extensionStatusExpanded)
                }
                if let reference, !reference.submissions.isEmpty {
                    SubmissionReview(workspace: workspace, reference: reference)
                }
                ComposerNoticesStack(items: buildComposerNotices(), maxHeight: maxNoticesHeight)
                composer(isStarter: isStarter, maxEditorHeight: maxEditorHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func composer(isStarter: Bool, maxEditorHeight: CGFloat = 180) -> some View {
        ComposerView(
            controller: presentation.controller,
            workspace: workspace,
            isViewedSessionActive: workspace.execution(for: presentation.id) != nil,
            sessionConfigurationDisabled: sessionConfigurationDisabled,
            model: currentModel,
            reference: reference,
            project: workspace.state.projects.first { $0.id == reference?.projectID },
            panelsBlocked: blocksComposerPanels,
            onPickFiles: addFiles,
            onSend: send,
            onStop: { Task { await workspace.stop(presentation.id) } },
            sendEnabled: canSend,
            focusSignal: workspace.inputFocusRequest,
            onInputFocused: autoConnectOnInputFocus,
            onFocusChanged: { isComposerFocused = $0 },
            isStarter: isStarter,
            maxEditorHeight: maxEditorHeight,
            sendShortcut: settings.composerSendShortcut,
            pastedImagesDirectory: settings.pastedImagesDirectory,
            onPreviewImage: onPreviewImage,
            isSubmittingHandoff: presentation.isSubmittingHandoff
        )
        .disabled(reference?.remoteHistoryDeleted == true)
    }
}

struct SessionStarterTitle: View {
    var isIdlePaused = false

    var body: some View {
        VStack(spacing: 14) {
            BrandMotionView(mode: .alive(isPaused: isIdlePaused), width: BrandMotionTiming.welcomeLogoWidth)
            Text(verbatim: BrandCopy.welcome)
                .zivviFont(.hero, weight: .semibold)
                .foregroundStyle(ZivviTheme.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("session-starter-title")
        }
        .padding(.horizontal, WorkbenchReadingColumn.minimumGutter)
        .padding(.bottom, 28) // Composer adds 4 pt above its surface.
    }
}

struct SessionDetailLayout<Content: View, Footer: View>: View {
    let isStarter: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: (CGFloat) -> Footer

    var body: some View {
        GeometryReader { geometry in
            if isStarter {
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: max(24, geometry.size.height * 0.18))
                        content()
                        footer(geometry.size.height)
                            .frame(maxWidth: WorkbenchReadingColumn.maximumWidth)
                            .padding(.horizontal, WorkbenchReadingColumn.minimumGutter)
                        Spacer(minLength: 24)
                    }
                    .frame(minWidth: geometry.size.width, maxWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: 0) {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer(geometry.size.height)
                        .frame(maxWidth: WorkbenchReadingColumn.maximumWidth)
                        .padding(.horizontal, WorkbenchReadingColumn.minimumGutter)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

private struct SessionArchivedBanner: View {
    let undoDisabled: Bool
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("会话已归档").zivviFont(.callout)
            Spacer(minLength: 0)
            Button("撤销", action: undo)
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .disabled(undoDisabled)
                .accessibilityIdentifier("undo-session-archive")
            Button(action: dismiss) {
                IconButtonLabel(systemName: "xmark")
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .accessibilityLabel("关闭提示")
        }
        .padding(ZivviSpacing.contentInset)
        .flatSurface(ZivviTheme.mutedSurface, radius: 10)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct ActiveRunBanner: View {
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
                return request.isPermissionApproval ? "等待审批" : "等待回复"
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

    static func remainingSeconds(until expiresAt: Date, relativeTo now: Date) -> Int {
        let interval = expiresAt.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return 0 }
        let rounded = interval.rounded(.up)
        return rounded >= Double(Int.max) ? Int.max : Int(rounded)
    }

    static func remainingFraction(from createdAt: Date, until expiresAt: Date, relativeTo now: Date) -> Double {
        let total = expiresAt.timeIntervalSince(createdAt)
        guard total.isFinite, total > 0 else { return 0 }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    var body: some View {
        if let active = workspace.execution(for: sessionID) {
            let request = active.phase == .stopping ? nil : active.interactions.first
            let needsRecovery = active.connection == .blocked || active.phase == .uncertain
            let needsAttention = request != nil || needsRecovery || active.phase == .waitingInput
            let isRunning = active.connection == .connected && active.phase == .running
            if let request {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    bannerContent(active: active, request: request, needsAttention: needsAttention,
                                  isRunning: isRunning, now: context.date)
                }
            } else {
                bannerContent(active: active, request: nil, needsAttention: needsAttention,
                              isRunning: isRunning, now: .now)
            }
        }
    }

    private func bannerContent(active: SessionController, request: RuntimeInteraction?,
                               needsAttention: Bool, isRunning: Bool, now: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isRunning && workspace.executionIDs.count > 1 {
                    BrandMotionView(mode: .flow(isActive: true), width: 18)
                } else {
                    Circle()
                        .fill(needsAttention ? ZivviTheme.warningText : (isRunning ? ZivviTheme.runningText : Color.secondary))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(statusText(for: active, request: request))
                    .fontWeight(.medium)
                    .foregroundStyle(needsAttention ? ZivviTheme.warningText : Color.secondary)
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
                        LightningIconView(.arrowUpRight, size: 12)
                    }
                }
                .help(Text(executingName ?? String(localized: "返回执行会话")))
                .accessibilityHint("返回执行会话")
                .accessibilityIdentifier("open-background-session")
                Spacer(minLength: 4)
                if let request {
                    let approvalCount = active.interactions.count(where: \.isPermissionApproval)
                    let seconds = Self.remainingSeconds(until: request.expiresAt, relativeTo: now)
                    Button(action: presentInteraction) {
                        HStack(spacing: 4) {
                            if approvalCount > 1 {
                                Text("去处理（\(approvalCount)）")
                            } else {
                                Text("去处理")
                            }
                            Text(verbatim: "\(seconds)s")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                    .fixedSize()
                    .accessibilityIdentifier("handle-background-interaction")
                }
            }
            .buttonStyle(FlatControlButtonStyle())
            .controlSize(.small)
            .zivviFont(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            ZivviDivider()
        }
        .background(alignment: .leading) {
            if needsAttention {
                if let request {
                    let fraction = Self.remainingFraction(from: request.createdAt, until: request.expiresAt, relativeTo: now)
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(ZivviTheme.warningSurface)
                            .frame(width: proxy.size.width * fraction, height: proxy.size.height)
                            .animation(.linear(duration: 1), value: fraction)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("审批剩余时间进度")
                            .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
                            .accessibilityIdentifier("active-run-progress")
                    }
                } else {
                    ZivviTheme.warningSurface
                }
            }
        }
    }
}

struct SubmissionReview: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    var unresolved: [SubmissionRecord] { reference.submissions.filter { $0.delivery == .unknown } }
    @State private var expanded = false

    var body: some View {
        if !unresolved.isEmpty {
            let reviewingHandoff = reference.handoff?.delivered == false &&
                unresolved.contains { $0.id == reference.handoff?.firstSubmissionID }
            VStack(alignment: .leading, spacing: 2) {
                if reviewingHandoff {
                    SessionTransitionRow(title: String(localized: "送达待核实"), detail: String(localized: "核对送达"),
                                         color: ZivviTheme.warningText, expanded: expanded) { expanded.toggle() }
                        .accessibilityIdentifier("composer-handoff-review")
                    if expanded { reviewItems }
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        reviewItems
                    } label: {
                        Text("发送状态待核实（\(unresolved.count)）")
                            .foregroundStyle(ZivviTheme.warningText)
                    }
                    .disclosureGroupStyle(FlatDisclosureStyle())
                    .padding(8).flatSurface(ZivviTheme.mutedSurface, radius: 9)
                }
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).zivviFont(.caption)
            .foregroundStyle(ZivviTheme.warningText)
            .padding(.horizontal, 24).padding(.vertical, 4)
            .onChange(of: reference.id) { expanded = false }
        }
    }

    private var reviewItems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(unresolved) { submission in
                VStack(alignment: .leading, spacing: 6) {
                    Text(submission.acknowledged ? "运行时曾接受该输入；完成情况未核实。" : "可能已发送，也可能尚未发送。")
                    if !submission.text.isEmpty { Text(submission.text).lineLimit(4).textSelection(.enabled) }
                    if let files = submission.files { Text(files.map(\.lastPathComponent).joined(separator: String(localized: "、"))).lineLimit(2) }
                    Text("关联标识：\(submission.id.uuidString)").zivviFont(.caption2)
                    if let handoff = reference.handoff, !handoff.delivered, handoff.firstSubmissionID == submission.id {
                        Button("确认交接已送达") { Task { await workspace.confirmHandoffDelivery(submission.id, in: reference.id) } }
                            .disabled(workspace.isOperating(on: reference.id) || workspace.storageError != nil)
                        if submission.needsReview {
                            Button("确认未送达") { Task { await workspace.reviewSubmission(submission.id, in: reference.id) } }
                        } else {
                            Button("放回草稿") { Task { await workspace.restoreReviewedSubmission(submission.id, in: reference.id) } }
                                .disabled(workspace.isOperating(on: reference.id) || workspace.storageError != nil)
                        }
                    } else if submission.needsReview {
                        Button("已核对，解除发送限制") { Task { await workspace.reviewSubmission(submission.id, in: reference.id) } }
                    } else if reference.handoff?.firstSubmissionID != submission.id {
                        Button("放回草稿") { Task { await workspace.restoreReviewedSubmission(submission.id, in: reference.id) } }
                            .disabled(workspace.isOperating(on: reference.id) || workspace.storageError != nil)
                    }
                }.padding(6)
            }
        }
    }
}

/// Non-hit-testing overlay that highlights the native NavigationSplitView divider on hover and drag.
private struct SidebarDividerHighlight: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> HighlightView {
        let view = HighlightView()
        view.setEnabled(isEnabled)
        return view
    }

    func updateNSView(_ nsView: HighlightView, context: Context) {
        nsView.setEnabled(isEnabled)
    }

    static func dismantleNSView(_ nsView: HighlightView, coordinator: ()) {
        nsView.teardown()
    }

    final class HighlightView: NSView {
        private let bar = NSView()
        private weak var splitView: NSSplitView?
        private var splitObserver: NSObjectProtocol?
        private var resignKeyObserver: NSObjectProtocol?
        private var mouseMonitor: Any?
        private var trackingArea: NSTrackingArea?
        private var trackingRect: NSRect = .zero
        private var currentDividerX: CGFloat?
        private var isEnabled = true
        private var isHovering = false
        private var isDragging = false
        private var renderedVisible = false
        private var renderedDragging = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            bar.wantsLayer = true
            bar.alphaValue = 0
            addSubview(bar)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        func setEnabled(_ enabled: Bool) {
            guard isEnabled != enabled else { return }
            isEnabled = enabled
            if !enabled {
                isHovering = false
                isDragging = false
            }
            syncGeometryAndBar()
        }

        func teardown() {
            if let splitObserver {
                NotificationCenter.default.removeObserver(splitObserver)
                self.splitObserver = nil
            }
            if let resignKeyObserver {
                NotificationCenter.default.removeObserver(resignKeyObserver)
                self.resignKeyObserver = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
                trackingRect = .zero
            }
            splitView = nil
            isHovering = false
            isDragging = false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard let window else {
                updateBar()
                return
            }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isHovering = false
                    self.isDragging = false
                    self.updateBar()
                }
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseMonitorEvent(event)
                }
                return event
            }
            resolveSplitView()
            Task { @MainActor [weak self] in
                self?.resolveSplitView()
            }
        }

        override func layout() {
            super.layout()
            if splitView == nil { resolveSplitView() }
            syncGeometryAndBar()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBar(forceColorRefresh: true)
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(for: event.locationInWindow)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(for: event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) {
            guard !isDragging else { return }
            if isHovering {
                isHovering = false
                updateBar()
            }
        }

        private func handleMouseMonitorEvent(_ event: NSEvent) {
            guard event.window === window else { return }
            if event.type == .leftMouseDown {
                if isEnabled, isHovering || isPointerOverDivider(windowPoint: event.locationInWindow) {
                    isHovering = true
                    isDragging = true
                    updateBar()
                    // NSSplitView runs a synchronous modal tracking loop inside mouseDown;
                    // reconcile on the next runloop turn in case it consumed mouseUp directly.
                    DispatchQueue.main.async { [weak self] in
                        self?.reconcileDragEndIfNeeded()
                    }
                }
            } else if event.type == .leftMouseUp, isDragging {
                endDragging()
            }
        }

        private func reconcileDragEndIfNeeded() {
            guard isDragging else { return }
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                endDragging()
            }
        }

        private func endDragging() {
            isDragging = false
            if let window {
                isHovering = isPointerOverDivider(windowPoint: window.mouseLocationOutsideOfEventStream)
            } else {
                isHovering = false
            }
            updateBar()
        }

        private func resolveSplitView() {
            guard let contentView = window?.contentView,
                  let found = Self.findSplitView(in: contentView) else { return }
            if splitView !== found {
                if let splitObserver { NotificationCenter.default.removeObserver(splitObserver) }
                splitView = found
                splitObserver = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: found,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.syncGeometryAndBar()
                    }
                }
            }
            syncGeometryAndBar()
        }

        private static func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.delegate is NSSplitViewController {
                return split
            }
            for subview in view.subviews {
                if let found = findSplitView(in: subview) { return found }
            }
            return nil
        }

        private func dividerPosition() -> (x: CGFloat, topY: CGFloat)? {
            guard isEnabled, let window, let splitView,
                  let controller = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = controller.splitViewItems.first(where: { $0.behavior == .sidebar }),
                  !sidebarItem.isCollapsed else { return nil }
            let sidebarView = sidebarItem.viewController.view
            guard sidebarView.bounds.width > 0 else { return nil }
            let x = convert(NSPoint(x: sidebarView.bounds.maxX, y: 0), from: sidebarView).x
            let topY = min(bounds.height, max(0, convert(window.contentLayoutRect, from: nil).maxY))
            guard topY > 0 else { return nil }
            return (x, topY)
        }

        private func syncGeometryAndBar() {
            guard let pos = dividerPosition() else {
                currentDividerX = nil
                isHovering = false
                isDragging = false
                updateTrackingArea(rect: .zero)
                updateBar()
                return
            }
            currentDividerX = pos.x
            let width = ResizeDividerStyle.activeWidth
            bar.frame = NSRect(x: pos.x - width / 2, y: 0, width: width, height: pos.topY)
            let hitWidth = ResizeDividerStyle.hitWidth
            updateTrackingArea(rect: NSRect(x: pos.x - hitWidth / 2, y: 0, width: hitWidth, height: pos.topY))
            updateBar()
        }

        private func updateTrackingArea(rect: NSRect) {
            guard trackingRect != rect else { return }
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            trackingRect = rect
            guard !rect.isEmpty else { return }
            let area = NSTrackingArea(rect: rect,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        private func updateHover(for windowPoint: NSPoint) {
            let hovered = isPointerOverDivider(windowPoint: windowPoint)
            if isHovering != hovered {
                isHovering = hovered
                updateBar()
            }
        }

        private func isPointerOverDivider(windowPoint: NSPoint) -> Bool {
            guard isEnabled, let splitView, let pos = dividerPosition() else { return false }
            let pointInSelf = convert(windowPoint, from: nil)
            guard pointInSelf.y >= 0, pointInSelf.y <= pos.topY else { return false }
            if let superview = splitView.superview {
                let pointInSuper = superview.convert(windowPoint, from: nil)
                return splitView.hitTest(pointInSuper) === splitView
            }
            return abs(pointInSelf.x - pos.x) <= 2.5
        }

        private func updateBar(forceColorRefresh: Bool = false) {
            let visible = isEnabled && currentDividerX != nil && (isHovering || isDragging)
            let dragging = visible && isDragging
            if forceColorRefresh || visible != renderedVisible || dragging != renderedDragging {
                let color = ResizeDividerStyle.color(hovering: visible, dragging: dragging)
                var resolved: CGColor?
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(color).cgColor
                }
                bar.layer?.backgroundColor = resolved
            }
            guard visible != renderedVisible || dragging != renderedDragging else { return }
            renderedVisible = visible
            renderedDragging = dragging
            NSAnimationContext.runAnimationGroup { context in
                context.duration = dragging || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : ResizeDividerStyle.animationDuration
                bar.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}

struct SessionDetailClickMonitor: NSViewRepresentable {
    let active: Bool
    let excludedTrailingWidth: CGFloat
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.update(active: active, excludedTrailingWidth: excludedTrailingWidth, onClick: onClick)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.teardown()
    }

    final class Anchor: NSView {
        private var active = false
        private var excludedTrailingWidth: CGFloat = 0
        private var onClick: (@MainActor () -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { teardown() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncMonitor()
        }

        func update(active: Bool, excludedTrailingWidth: CGFloat, onClick: @escaping @MainActor () -> Void) {
            self.active = active
            self.excludedTrailingWidth = excludedTrailingWidth
            self.onClick = onClick
            syncMonitor()
        }

        private func syncMonitor() {
            guard active, window != nil else {
                teardown()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouseDown(event) }
                return event
            }
        }

        func handleMouseDown(_ event: NSEvent) {
            guard active, let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            if excludedTrailingWidth > 0, point.x >= bounds.maxX - excludedTrailingWidth {
                return
            }
            onClick?()
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
