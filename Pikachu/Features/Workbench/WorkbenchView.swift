import SwiftUI
import AppKit
import AgentRuntimeCore
import OrchestrationCore

enum SessionManagementAction {
    case archive, deleteDraft, deleteRemoteHistory
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
    @State private var modal: WorkbenchModal?
    @State private var providerConnectionRequest: ProviderConnectionRequest?
    @State private var lastArchivedSessionID: UUID?
    @State private var sessionManagementError: String?
    @State private var lastPresentedInteractionID: String?
    @State private var preparingToQuit = false
    @State private var sidebarFilter = SessionSidebarFilter()
    @State private var actionAfterSheet: (() -> Void)?
    @State private var gitStore = GitStatusStore()

    @State private var detailWidth: CGFloat = 0
    @State private var workbenchSize: CGSize = .zero
    @State private var filesModel: ProjectFilesModel
    @State private var filesFocus = ProjectFilesFocusBridge()
    @State private var preferredFilesWidth: CGFloat = 640
    @State private var filesDragWidth: CGFloat?
    @State private var isHoveringFilesDivider = false
    @State private var imagePreview: ImagePreviewSelection?

    init(workspace: WorkspaceController, settings: AppSettings, quitRequest: Int, openSettingsRequest: Int,
         terminate: @escaping (_ restarting: Bool, _ onCancel: @escaping () -> Void) -> Void,
         sidebarVisibility: Binding<NavigationSplitViewVisibility>,
         projectFiles: ProjectFilesControls = ProjectFilesControls(),
         filesModel: ProjectFilesModel? = nil,
         canAutomaticallyPresentInteraction: (() -> Bool)? = nil,
         initialImagePreview: ImagePreviewSelection? = nil) {
        self.projectFiles = projectFiles
        _filesModel = State(initialValue: filesModel ?? ProjectFilesModel())
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
        windowContent
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
        .onChange(of: modal != nil) { _, hasModal in
            if hasModal { imagePreview = nil }
        }
        .onChange(of: preparingToQuit) { _, quitting in
            if quitting { imagePreview = nil }
        }
        .onChange(of: workspace.viewed?.id) { _, _ in
            imagePreview = nil
        }
        .sheet(item: $modal, onDismiss: sheetDidDismiss, content: presentedModal)
        .scrollIndicators(.never)
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
        .pikachuTypography(settings.interfaceFontSize)
        .presentationBackground(PikachuTheme.pageBackground)
    }

    private var windowContent: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                workbenchSidebar
            } detail: {
                workbenchDetail
            }
            .overlay {
                SidebarDividerHighlight(isEnabled: sidebarVisibility != .detailOnly && !filesAreBlocked)
            }
            .allowsHitTesting(imagePreview == nil)
            .accessibilityHidden(imagePreview != nil)
            .background {
                WorkbenchTitlebar(sidebarVisibility: $sidebarVisibility, workspace: workspace,
                                  gitStore: gitStore, detailWidth: detailWidth, hasSession: workspace.viewed != nil,
                                  isLightboxPresented: imagePreview != nil, projectFiles: projectFiles,
                                  filesModel: filesModel, filesRoot: filesRoot,
                                  filesWidth: filesLayout.width, filesFocus: filesFocus,
                                  createSession: { createSession(in: $0, showsSidebar: false) },
                                  manageSession: requestSessionManagement)
                    .frame(width: 0, height: 0)
            }

            if let imagePreview {
                AttachmentImagePreview(selection: imagePreview) {
                    self.imagePreview = nil
                }
                .zIndex(10)
            }
        }
        .background(PikachuTheme.pageBackground.ignoresSafeArea())
        .onChange(of: filesRoot, initial: true) { _, root in
            filesModel.bind(root: root, isOpen: projectFiles.isOpen)
        }
        .onChange(of: projectFiles.isOpen, initial: true) { _, open in
            if open { filesFocus.capture() }
            else { filesFocus.restoreIfNeeded() }
            filesModel.bind(root: filesRoot, isOpen: open)
        }
        .onDisappear { filesModel.bind(root: filesRoot, isOpen: false) }
        .onChange(of: workspace.inputFocusRequest) {
            if projectFiles.isOpen, !filesLayout.isDocked {
                filesFocus.clear()
                projectFiles.close()
            }
        }
        .onChange(of: filesAreBlocked, initial: true) { _, blocked in
            projectFiles.blocked = blocked
        }
    }

    private var workbenchSidebar: some View {
        SessionSidebar(
            workspace: workspace, filter: $sidebarFilter,
            openProject: openProject, createSession: requestNewSession,
            openSettings: { presentSettings(.general) },
            manageSession: requestSessionManagement,
            toolSearchPaths: settings.acpAgents.filter(\.enabled).flatMap(\.toolSearchPaths),
            showsImportHistory: settings.acpAgents.contains(where: { $0.enabled }),
            importHistory: { requestACPHistory() }
        )
        // Preserve the native sidebar overlay's minimum width.
        .frame(minWidth: Self.minimumSidebarWidth)
        .navigationSplitViewColumnWidth(min: Self.minimumSidebarWidth, ideal: 292, max: 360)
        .toolbar(removing: .sidebarToggle)
    }

    private var filesRoot: ProjectFilesRoot? {
        guard let viewed = workspace.viewed,
              let session = workspace.state.sessions.first(where: { $0.id == viewed.id }),
              let project = workspace.state.projects.first(where: { $0.id == session.projectID }),
              let directory = workspace.workingDirectory(for: viewed.id),
              directory.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let projectRoot = URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL
        return ProjectFilesRoot(projectID: project.id, path: root.path,
                                displayName: root == projectRoot ? project.displayName : root.lastPathComponent)
    }

    private var filesLayout: ProjectFilesLayout {
        ProjectFilesLayout(available: detailWidth, preferred: preferredFilesWidth)
    }

    private var filesAreBlocked: Bool {
        modal != nil || preparingToQuit || actionAfterSheet != nil || imagePreview != nil
    }

    private var workbenchDetail: some View {
        let layout = filesLayout
        return ZStack(alignment: .trailing) {
            sessionColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, projectFiles.isOpen && layout.isDocked ? layout.width + 1 : 0)

            if let paneOpeningID = projectFiles.openingID {
                let paneRoot = filesRoot
                ProjectFilesPane(model: filesModel, root: paneRoot, layout: layout,
                                 keyboardOpenRequest: projectFiles.keyboardOpenRequest,
                                 toolbarTrailingInset: projectFiles.toolbarTrailingInset,
                                 windowControls: projectFiles,
                                 fileOpen: settings.fileOpen,
                                 canLaunch: {
                                     projectFiles.openingID == paneOpeningID && !filesAreBlocked && filesRoot == paneRoot
                                 },
                                 close: {
                                     filesFocus.closeFromPane()
                                     projectFiles.close()
                                 })
                    .overlay(alignment: .leading) { filesDivider(layout) }
                    .shadow(color: .black.opacity(layout.isDocked ? 0 : 0.16),
                            radius: layout.isDocked ? 0 : 9, x: -2, y: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PikachuTheme.pageBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { detailWidth = $0 }
        .background {
            ProjectFilesFocusBridge.Attachment(bridge: filesFocus).frame(width: 0, height: 0)
        }
    }

    private func filesDivider(_ layout: ProjectFilesLayout) -> some View {
        let maxFilesWidth = min(780, detailWidth - 501)
        let canResize = layout.hasColumns && maxFilesWidth > 600
        let isDragging = filesDragWidth != nil
        let isHighlighted = canResize && (isHoveringFilesDivider || isDragging)

        return Rectangle()
            .fill(ResizeDividerStyle.color(hovering: isHighlighted, dragging: isDragging))
            .frame(width: isHighlighted ? ResizeDividerStyle.activeWidth : ResizeDividerStyle.restingWidth)
            .frame(width: ResizeDividerStyle.hitWidth)
            .contentShape(Rectangle())
            .offset(x: -4)
            .allowsHitTesting(canResize)
            .onHover { hovering in
                isHoveringFilesDivider = hovering && canResize
            }
            .onChange(of: canResize) { _, resizable in
                if !resizable {
                    isHoveringFilesDivider = false
                    filesDragWidth = nil
                }
            }
            .onDisappear {
                isHoveringFilesDivider = false
                filesDragWidth = nil
            }
            .pointerStyle(filesDividerPointerStyle(width: layout.width, maxWidth: maxFilesWidth,
                                                   canResize: canResize, isDragging: isDragging))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { change in
                        let initial = filesDragWidth ?? layout.width
                        filesDragWidth = initial
                        preferredFilesWidth = min(maxFilesWidth, max(600, initial - change.translation.width))
                    }
                    .onEnded { _ in filesDragWidth = nil }
            )
            .animation(.easeOut(duration: ResizeDividerStyle.animationDuration), value: isHighlighted)
            .accessibilityHidden(!canResize)
            .accessibilityLabel("调整文件预览宽度")
            .accessibilityValue(Text(verbatim: String(Int(layout.width))))
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = direction == .increment ? 20 : -20
                preferredFilesWidth = min(maxFilesWidth, max(600, layout.width + change))
            }
    }

    private func filesDividerPointerStyle(width: CGFloat, maxWidth: CGFloat,
                                          canResize: Bool, isDragging: Bool) -> PointerStyle {
        guard canResize else { return .default }
        if isDragging { return .columnResize }
        var directions: HorizontalDirection.Set = []
        if width < maxWidth - 0.5 { directions.insert(.leading) }
        if width > 600.5 { directions.insert(.trailing) }
        return directions.isEmpty ? .default : .columnResize(directions: directions)
    }

    private var sessionColumn: some View {
        VStack(spacing: 0) {
            backgroundRuns
            if let viewed = workspace.viewed {
                SessionDetail(workspace: workspace, settings: settings, presentation: viewed,
                              blocksComposerPanels: modal != nil || actionAfterSheet != nil || preparingToQuit || imagePreview != nil,
                              openConnectionSettings: presentConnectionSettings, presentConfirmation: presentConfirmation,
                              presentToolFailures: presentToolFailures,
                              presentTaskPlan: presentTaskPlan,
                              onOpenFile: openTranscriptFile,
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
            if let sessionManagementError { FeedbackBanner(text: sessionManagementError, warning: true) }
            if let id = lastArchivedSessionID, workspace.state.sessions.contains(where: { $0.id == id && $0.archivedAt != nil }) {
                SessionArchivedBanner(undoDisabled: workspace.isOperating(on: id) || workspace.storageError != nil,
                                      undo: { undoArchive(id) }, dismiss: { lastArchivedSessionID = nil })
            }
        }
    }

    private func presentImagePreview(_ selection: ImagePreviewSelection) {
        guard modal == nil, actionAfterSheet == nil, !preparingToQuit else { return }
        imagePreview = selection
    }

    private func openTranscriptFile(_ rawURL: URL) {
        let fileURL = TranscriptFileOpener.withoutFragment(rawURL)
        let line = TranscriptFileOpener.lineReference(in: rawURL)
        let fileOpen = settings.fileOpen
        let fallback: @MainActor @Sendable () -> Void = {
            TranscriptFileOpener.open(fileURL, line: line, configuration: fileOpen)
        }
        guard !filesAreBlocked, let root = filesRoot,
              let path = ProjectFilePath.relativePath(from: fileURL, within: root.path) else {
            fallback()
            return
        }
        filesModel.openFromTranscript(
            path: path,
            in: root,
            line: line,
            canOpen: { !filesAreBlocked && filesRoot == root },
            activatePane: {
                projectFiles.open()
                filesModel.bind(root: root, isOpen: true)
            },
            onFallback: fallback
        )
    }

    private func openHandoffFile(_ path: ProjectFilePath, from directory: URL,
                                 for sessionID: UUID) async -> ProjectFilesModel.TranscriptOpenOutcome {
        guard !Task.isCancelled, !filesAreBlocked, workspace.viewed?.id == sessionID else { return .cancelled }
        guard let root = filesRoot else { return .unavailable(.rootUnavailable) }
        guard root.path == directory.standardizedFileURL.path else { return .cancelled }
        let visibility = projectFiles.visibilityRevision
        let request = filesModel.openFromTranscript(
            path: path,
            in: root,
            canOpen: {
                !filesAreBlocked && workspace.viewed?.id == sessionID && filesRoot == root &&
                    projectFiles.visibilityRevision == visibility
            },
            activatePane: {
                projectFiles.open()
                filesModel.bind(root: root, isOpen: true)
            }
        )
        return await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
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
            Task {
                if await workspace.setSessionArchived(id, archived: true) { lastArchivedSessionID = id }
                else if workspace.storageError == nil { sessionManagementError = String(localized: "无法归档会话，请重试。") }
            }
        case .deleteRemoteHistory:
            guard session.canDeleteRemoteHistory == true, session.remoteHistoryDeleted != true else { return }
            let agent = CodingAgentLabel.displayName(for: session.runtimeID, agents: settings.acpAgents)
            presentConfirmation(ConfirmationRequest(
                title: "从 Agent 历史删除？",
                message: "将从「\(agent)」删除「\(session.displayTitle)」。本地记录和草稿将保留为只读。",
                confirmTitle: "删除 Agent 历史",
                defaultsToCancel: true
            ) {
                Task {
                    do {
                        try await workspace.deleteRemoteHistory(id) { agentID, path, remoteID in
                            let control = try await settings.openACPControl(agentID: agentID, directory: URL(fileURLWithPath: path))
                            do { try await control.delete(sessionID: remoteID) }
                            catch { try? await control.close(); throw error }
                            try? await control.close()
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
    var blocksComposerPanels = false
    let openConnectionSettings: (String) -> Void
    let presentConfirmation: (ConfirmationRequest) -> Void
    var presentToolFailures: ([TranscriptItem]) -> Void = { _ in }
    var presentTaskPlan: (SessionController) -> Void = { _ in }
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    @State private var enteredAsLocalDraft: Bool?
    @State private var hasShownConversation = false
    @State private var composerClearance: CGFloat = 0
    @State private var extensionStatusExpanded = false
    @State private var autoConnectAttempted = false
    @State private var transcriptScrollState = TranscriptScrollState()

    var reference: SessionReference? { workspace.state.sessions.first { $0.id == presentation.id } }
    func connectionSettingsRuntimeID(agents: [RuntimeAgentProfile]) -> String? {
        guard let reference, let failure = presentation.controller.failure,
              presentation.controller.connection == .disconnected, workspace.storageError == nil,
              failure.kind == .setup || failure.kind == .unsupportedVersion,
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
        let prompt = presentation.controller.draftPrompt
        Task { await workspace.send(presentation.id, submitted: prompt) }
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

    private var canEditHistoryMessage: Bool {
        !isArchived && !presentation.controller.isDraftEditingLocked &&
            (reference?.isACPRuntime != true || presentation.executionIssue == nil)
    }

    private func handleEditUserMessage(_ item: TranscriptItem) {
        guard canEditHistoryMessage else { return }
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
        guard canEditHistoryMessage else { return }
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
        .onChange(of: presentation.controller.connection) { _, connection in
            if connection == .connected { autoConnectAttempted = false }
        }
    }

    private var detailContent: some View {
        let starter = starterProject
        return SessionDetailViewport(isStarter: starter != nil) { viewportHeight in
            historyContent(starter: starter)
            footerContent(viewportHeight: viewportHeight, isStarter: starter != nil)
        }
    }

    private func historyContent(starter: ProjectRecord?) -> some View {
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
                    composerClearance: composerClearance,
                    workspaceDirectory: workspace.workingDirectory(for: presentation.id).map { URL(fileURLWithPath: $0, isDirectory: true) },
                    onOpenFile: onOpenFile,
                    onOpenHandoffFile: onOpenHandoffFile,
                    onEditUserMessage: editUserMessage,
                    onPreviewImage: onPreviewImage,
                    onSyncFullHistory: canSyncCachedHistory ? {
                        Task { await workspace.activate(presentation.id) }
                    } : nil,
                    scrollState: transcriptScrollState
                ).id(presentation.id)
            }
        }
    }

    private func footerContent(viewportHeight: CGFloat, isStarter: Bool) -> some View {
        VStack(spacing: 0) {
            if isArchived {
                FeedbackBanner(text: String(localized: "此会话已归档。可在「设置 → 已归档」中取消归档。"), warning: false)
            } else {
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
                    if let runtimeID = connectionSettingsRuntimeID(agents: settings.acpAgents) {
                        Button("打开连接设置…") { openConnectionSettings(runtimeID) }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).pikachuFont(.caption).padding(.vertical, 4)
                    }
                }
                if let message = presentation.executionError, message != presentation.controller.failure?.detail {
                    FeedbackBanner(text: message, warning: true)
                }
                if let notice = presentation.controller.noticeExcludingComposerPills { FeedbackBanner(text: notice, warning: false) }
                if let reference, !reference.submissions.isEmpty { SubmissionReview(workspace: workspace, reference: reference) }
                composer(isStarter: isStarter)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { composerClearance = $0 }
    }

    private func composer(isStarter: Bool) -> some View {
        ComposerView(
            controller: presentation.controller,
            workspace: workspace,
            isViewedSessionActive: workspace.execution(for: presentation.id) != nil,
            isReadOnlyHistory: presentation.executionIssue != nil,
            sessionConfigurationDisabled: sessionConfigurationDisabled,
            model: currentModel,
            reference: reference,
            project: workspace.state.projects.first { $0.id == reference?.projectID },
            panelsBlocked: blocksComposerPanels,
            onPickFiles: addFiles,
            onSend: send,
            onStop: { Task { await workspace.stop(presentation.id) } },
            presentToolFailures: presentToolFailures,
            presentTaskPlan: { presentTaskPlan(presentation.controller) },
            onSyncCachedHistory: canSyncCachedHistory ? {
                Task { await workspace.activate(presentation.id) }
            } : nil,
            onJumpToMessage: { transcriptScrollState.requestJump(to: $0) },
            sendEnabled: canSend,
            focusSignal: workspace.inputFocusRequest,
            onInputFocused: autoConnectOnInputFocus,
            isStarter: isStarter,
            sendShortcut: settings.composerSendShortcut,
            pastedImagesDirectory: settings.pastedImagesDirectory,
            onPreviewImage: onPreviewImage,
            isSubmittingHandoff: presentation.isSubmittingHandoff
        )
        .disabled(reference?.remoteHistoryDeleted == true)
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

struct SessionHeader<FileTabs: View>: View {
    let workspace: WorkspaceController
    let presentation: SessionPresentation
    let gitStore: GitStatusStore
    let preferredTabsWidth: CGFloat?
    let createSession: (UUID) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void
    @ViewBuilder let fileTabs: () -> FileTabs
    @Environment(\.pikachuTypography) private var typography
    @State private var showsGitDetails = false
    @FocusState private var projectFocused: Bool
    @FocusState private var gitDetailsFocused: Bool

    private var filesOpen: Bool { preferredTabsWidth != nil }

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

    private func projectButton(_ project: ProjectRecord) -> some View {
        Button { createSession(project.id) } label: {
            HStack(spacing: 6) {
                ProjectBadge(project: project, compact: true)
                Text(verbatim: project.displayName)
                    .pikachuFont(.headline, weight: .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: filesOpen ? 144 : nil, alignment: .leading)
            }
        }
        .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: projectFocused, height: typography.composerActionButtonSize,
                                          restingForegroundColor: PikachuTheme.secondaryText))
        .focused($projectFocused)
        .disabled(!workspace.canManageProjects)
        .help(Text("在 \(project.displayName) 中新建会话\n\(project.path)"))
        .accessibilityLabel("项目 \(project.displayName)")
        .accessibilityHint("新建会话")
        .accessibilityIdentifier("new-session-in-viewed-project")
    }

    @ViewBuilder private var projectIdentity: some View {
        if let owningProject {
            projectButton(owningProject)
            Text("/")
                .pikachuFont(.headline, weight: .regular)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var sessionTitle: some View {
        if let reference, reference.archivedAt == nil {
            SessionTitleControl(workspace: workspace, session: reference, reservesEllipsis: filesOpen, manageSession: manageSession)
                .id(reference.id)
        } else if let reference {
            Text(verbatim: reference.displayTitle)
                .pikachuFont(.headline, weight: .semibold)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text("会话")
                .pikachuFont(.headline, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var identitySection: some View {
        HStack(spacing: 8) {
            projectIdentity
            sessionTitle
        }
    }

    @ViewBuilder
    private func executionActionsSection(compact: Bool) -> some View {
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
    }

    private func gitDetailsButton(project: ProjectRecord) -> some View {
        Button { showsGitDetails.toggle() } label: {
            IconButtonLabel(assetName: "GitPullRequest")
                .frame(width: typography.composerActionButtonSize, height: typography.composerActionButtonSize)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: showsGitDetails, hasKeyboardFocus: gitDetailsFocused,
                                          inset: false))
        .focused($gitDetailsFocused)
        .help("Git 详情")
        .accessibilityLabel("Git 详情")
        .accessibilityValue(showsGitDetails ? Text("已展开") : Text("已折叠"))
        .popover(isPresented: $showsGitDetails) {
            GitSummaryBar(project: project, gitStore: gitStore, displaysDetails: true)
        }
    }

    var body: some View {
        Group {
            if let preferredTabsWidth {
                SessionHeaderFileLayout(preferredTabsWidth: preferredTabsWidth) {
                    HStack(spacing: 4) {
                        projectIdentity
                        sessionTitle.layoutPriority(1)
                    }
                    HStack(spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            executionActionsSection(compact: false)
                            executionActionsSection(compact: true)
                        }
                        if let project { gitDetailsButton(project: project).fixedSize() }
                    }
                    fileTabs()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        identitySection.frame(minWidth: 150, alignment: .leading)
                        Spacer(minLength: 6)
                        if let project { GitSummaryBar(project: project, gitStore: gitStore).fixedSize() }
                        executionActionsSection(compact: false).fixedSize()
                    }
                    HStack(spacing: 8) {
                        identitySection
                        Spacer(minLength: 4)
                        executionActionsSection(compact: true).fixedSize()
                        if let project { gitDetailsButton(project: project).fixedSize() }
                    }
                }
                .padding(.horizontal, 2)
                .id(presentation.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: filesOpen) { showsGitDetails = false }
        .onChange(of: presentation.id) { showsGitDetails = false }
        .task(id: project?.path) {
            if let path = project?.path {
                gitStore.refresh(directory: path)
            }
        }
    }
}

private struct SessionHeaderFileLayout: Layout {
    let preferredTabsWidth: CGFloat
    private let leadingInset: CGFloat = 2
    private let trailingInset: CGFloat = 8
    private let actionsSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let width = proposal.width, width.isFinite, let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: height)
        }
        let controls = subviews.prefix(2).map { $0.sizeThatFits(.unspecified) }
        let idealWidth = controls.reduce(leadingInset + trailingInset + actionsSpacing + preferredTabsWidth) {
            $0 + $1.width
        }
        let idealHeight = controls.map(\.height).max() ?? 0
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth,
                      height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? idealHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let identity = subviews[0]
        let actions = subviews[1]
        let tabs = subviews[2]
        let minimum = ProposedViewSize(width: 0, height: bounds.height)
        let minimumActions = actions.sizeThatFits(minimum).width
        let minimumIdentity = identity.sizeThatFits(minimum).width
        let gaps = leadingInset + trailingInset + (minimumActions > 0 ? actionsSpacing : 0)
        // Measure localized controls before giving any remaining width to file tabs.
        let minimumSession = gaps + minimumActions + minimumIdentity
        let sessionWidth = min(bounds.width, max(minimumSession, bounds.width - preferredTabsWidth))
        let available = max(0, sessionWidth - gaps)
        let idealIdentity = identity.sizeThatFits(.unspecified).width
        let actionProposal = ProposedViewSize(width: max(minimumActions, available - idealIdentity), height: bounds.height)
        let actionSize = actions.sizeThatFits(actionProposal)
        let identityProposal = ProposedViewSize(width: max(0, available - actionSize.width), height: bounds.height)
        let identityX = bounds.minX + leadingInset
        let boundary = bounds.minX + sessionWidth

        identity.place(at: CGPoint(x: identityX, y: bounds.midY), anchor: .leading, proposal: identityProposal)
        actions.place(at: CGPoint(x: boundary - trailingInset, y: bounds.midY), anchor: .trailing,
                      proposal: actionProposal)
        tabs.place(at: CGPoint(x: boundary, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: bounds.width - sessionWidth, height: bounds.height))
    }
}

private struct SessionTitleControl: View {
    let workspace: WorkspaceController
    let session: SessionReference
    let reservesEllipsis: Bool
    let manageSession: (SessionManagementAction, UUID) -> Void
    @Environment(\.pikachuTypography) private var typography
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
                    .truncationMode(.tail)
                    .frame(minWidth: reservesEllipsis ? typography.pointSize(for: .headline) : nil, alignment: .leading)
                FlatDisclosureChevron(.down)
                    .opacity(isHovered || isMenuFocused || isMenuOpen ? 1 : 0)
            }
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: isMenuOpen, hasKeyboardFocus: isMenuFocused,
                                          height: typography.composerActionButtonSize, showsHoverBackground: false))
        .focused($isMenuFocused)
        .onHover { isHovered = $0 }
        .help(session.displayTitle)
        .accessibilityLabel(Text(verbatim: session.displayTitle))
        .accessibilityValue(isMenuOpen ? Text("已展开") : Text("已折叠"))
        .accessibilityHint(Text("会话操作"))
        .accessibilityIdentifier("session-title-menu")
        .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
            Group {
                if isEditing {
                    renameEditor
                        .background(PikachuTheme.pageBackground)
                        .presentationBackground(PikachuTheme.pageBackground)
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
                FlatMenuRow(title: Text("标记已完成"))
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
        let archiveBlock = workspace.sessionArchiveBlockReason(for: session)
        Button {
            select { manageSession(.archive, session.id) }
        } label: {
            FlatMenuRow(title: Text("归档"), icon: Image(systemName: "archivebox"))
        }
        .disabled(archiveBlock != nil)
        .help(archiveBlock.map { String(localized: $0) } ?? "")
        .accessibilityIdentifier("archive-session")
        if workspace.isDeletableDraft(session) {
            Button(role: .destructive) {
                select { manageSession(.deleteDraft, session.id) }
            } label: {
                FlatMenuRow(title: Text("删除草稿"), icon: Image(systemName: "trash"))
            }
            .disabled(!workspace.canDeleteDraft(session))
            .accessibilityIdentifier("delete-session-draft")
        }
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

private struct SessionArchivedBanner: View {
    let undoDisabled: Bool
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("会话已归档").pikachuFont(.callout)
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
        .padding(8)
        .flatSurface(PikachuTheme.mutedSurface, radius: 10)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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

private struct GitSummaryBar: View {
    let project: ProjectRecord
    let gitStore: GitStatusStore
    var displaysDetails = false
    @Environment(\.pikachuTypography) private var typography
    @State private var showsBranchPopover = false
    @State private var showsAheadPopover = false
    @State private var showsChangesPopover = false
    @FocusState private var focused: Control?

    private enum Control: Hashable { case branch, ahead, changes }

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
            .buttonStyle(FlatControlButtonStyle(isOpen: showsBranchPopover, hasKeyboardFocus: focused == .branch,
                                              height: typography.composerActionButtonSize))
            .focused($focused, equals: .branch)
            .foregroundStyle(snapshot == nil ? .secondary : .primary)
            .help(branchText)
            .accessibilityLabel("Git 分支")
            .accessibilityValue(branchText)
            .accessibilityHint(showsBranchPopover ? Text("已展开") : Text("已折叠"))
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
            .buttonStyle(FlatControlButtonStyle(isOpen: showsAheadPopover, hasKeyboardFocus: focused == .ahead,
                                              height: typography.composerActionButtonSize))
            .focused($focused, equals: .ahead)
            .foregroundStyle(.secondary)
            .help("领先本地上游引用的提交数：\(aheadText)")
            .accessibilityLabel("领先本地上游引用的提交数")
            .accessibilityValue(aheadText)
            .accessibilityHint(showsAheadPopover ? Text("已展开") : Text("已折叠"))
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
            .buttonStyle(FlatControlButtonStyle(isOpen: showsChangesPopover, hasKeyboardFocus: focused == .changes,
                                              height: typography.composerActionButtonSize))
            .focused($focused, equals: .changes)
            .help("变更文件")
            .accessibilityLabel("变更文件")
            .accessibilityValue(changesAccessibilityValue)
            .accessibilityHint(showsChangesPopover ? Text("已展开") : Text("已折叠"))
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
            .pikachuFont(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            PikachuDivider()
        }
        .background(alignment: .leading) {
            if needsAttention {
                if let request {
                    let fraction = Self.remainingFraction(from: request.createdAt, until: request.expiresAt, relativeTo: now)
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(PikachuTheme.warningSurface)
                            .frame(width: proxy.size.width * fraction, height: proxy.size.height)
                            .animation(.linear(duration: 1), value: fraction)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("审批剩余时间进度")
                            .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
                            .accessibilityIdentifier("active-run-progress")
                    }
                } else {
                    PikachuTheme.warningSurface
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
                                         color: PikachuTheme.warningText, expanded: expanded) { expanded.toggle() }
                        .accessibilityIdentifier("composer-handoff-review")
                    if expanded { reviewItems }
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        reviewItems
                    } label: {
                        Text("发送状态待核实（\(unresolved.count)）")
                            .foregroundStyle(PikachuTheme.warningText)
                    }
                    .disclosureGroupStyle(FlatDisclosureStyle())
                    .padding(8).flatSurface(PikachuTheme.mutedSurface, radius: 9)
                }
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).pikachuFont(.caption)
            .foregroundStyle(PikachuTheme.warningText)
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
                    Text("关联标识：\(submission.id.uuidString)").pikachuFont(.caption2)
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
                context.duration = dragging ? 0 : ResizeDividerStyle.animationDuration
                bar.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}
