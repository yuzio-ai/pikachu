import SwiftUI
import OrchestrationCore

/// Flat horizontal tab bar for the Conversation Area (left main pane).
struct ConversationTabBar: View {
    let workspace: WorkspaceController
    let tabsModel: WorkbenchTabsModel
    let gitStore: GitStatusStore
    let isEditorVisible: Bool
    let hasEditorTabs: Bool
    let onSelectSession: (UUID) -> Void
    let onCloseSession: (UUID) -> Void
    let onNewSession: () -> Void
    let onManageSession: (SessionManagementAction, UUID) -> Void
    let onJumpToGit: (ProjectRecord) -> Void
    let onToggleEditor: () -> Void

    @Environment(\.zivviTypography) private var typography
    @State private var draggedID: UUID?

    private var openProjectsCount: Int {
        let ids = Set(tabsModel.conversationTabs.compactMap { id in
            workspace.state.sessions.first(where: { $0.id == id })?.projectID
        })
        return ids.count
    }

    private var activeProject: ProjectRecord? {
        guard let activeID = tabsModel.activeConversationID,
              let session = workspace.state.sessions.first(where: { $0.id == activeID }) else { return nil }
        return workspace.state.projects.first(where: { $0.id == session.projectID })
    }

    private var activeSession: SessionReference? {
        guard let activeID = tabsModel.activeConversationID else { return nil }
        return workspace.state.sessions.first(where: { $0.id == activeID })
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(tabsModel.conversationTabs, id: \.self) { id in
                            if let session = workspace.state.sessions.first(where: { $0.id == id }),
                               let project = workspace.state.projects.first(where: { $0.id == session.projectID }) {
                                ConversationTabItem(
                                    workspace: workspace,
                                    session: session,
                                    project: project,
                                    isActive: id == tabsModel.activeConversationID,
                                    showsProjectBadge: openProjectsCount > 1,
                                    onSelect: { onSelectSession(id) },
                                    onClose: { onCloseSession(id) }
                                )
                                .id(id)
                                .draggable(id.uuidString) {
                                    Text(verbatim: session.displayTitle)
                                        .zivviFont(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(ZivviTheme.surface, in: .rect(cornerRadius: 6))
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let dropped = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                    tabsModel.moveConversation(draggedID: dropped, before: id)
                                    return true
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .padding(.trailing, 8)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 12)
                    }
                )
                .onChange(of: tabsModel.activeConversationID) { _, id in
                    if let id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if tabsModel.conversationTabs.count > 4 {
                overflowMenu
            }

            Button(action: onNewSession) {
                LightningBrandIconView(.newSession, size: 14)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
            .disabled(!workspace.canManageProjects)
            .help("新建会话（⌘N）")
            .accessibilityLabel("新建会话")
            .accessibilityIdentifier("conversation-tabs-new")

            Spacer(minLength: 4)

            if let activeProject {
                compactGitBadge(for: activeProject)
            }

            if let activeSession {
                sessionActionsMenu(for: activeSession)
            }

            if hasEditorTabs || isEditorVisible {
                Button(action: onToggleEditor) {
                    LightningIconView(isEditorVisible ? .sidebarRight : .insetFilledRightthirdRectangle, size: 14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: isEditorVisible, inset: false, cornerRadius: 6))
                .help(isEditorVisible ? "收起右侧文件区（⌥⌘B）" : "展开右侧文件区（⌥⌘B）")
                .accessibilityLabel(isEditorVisible ? "收起右侧文件区" : "展开右侧文件区")
                .accessibilityIdentifier("toggle-editor-area")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: typography.titlebarControlHeight)
        .accessibilityIdentifier("conversation-tab-bar")
    }

    private var overflowMenu: some View {
        FlatMenu(width: 220) {
            LightningIconView(.chevronDown, size: 12)
                .frame(width: 22, height: 24)
        } content: { select in
            ForEach(tabsModel.conversationTabs, id: \.self) { id in
                if let session = workspace.state.sessions.first(where: { $0.id == id }) {
                    Button { select { onSelectSession(id) } } label: {
                        FlatMenuRow(title: Text(verbatim: session.displayTitle),
                                    selected: id == tabsModel.activeConversationID)
                    }
                    .buttonStyle(FlatControlButtonStyle(isSelected: id == tabsModel.activeConversationID))
                }
            }
        }
        .fixedSize()
        .help("已打开的会话标签")
        .accessibilityLabel("已打开的会话标签")
    }

    @ViewBuilder
    private func compactGitBadge(for project: ProjectRecord) -> some View {
        let dirState = gitStore.state(for: project.path)
        if let snap = dirState.snapshot {
            ViewThatFits(in: .horizontal) {
                Button {
                    onJumpToGit(project)
                } label: {
                    HStack(spacing: 4) {
                        GitBranchIcon()
                            .foregroundStyle(ZivviTheme.secondaryText)
                        Text(verbatim: snap.branch.displayName)
                            .zivviFont(.caption2)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if snap.changes.totalCount > 0 {
                            Text(verbatim: "\(snap.changes.totalCount)")
                                .zivviFont(.caption2, design: .monospaced)
                                .foregroundStyle(ZivviTheme.tertiaryText)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: 130, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
                .help("在左侧切换 \(project.displayName) 至 Git 模式")
                .accessibilityLabel("Git 分支 \(snap.branch.displayName)，\(snap.changes.totalCount) 个变更")

                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func sessionActionsMenu(for session: SessionReference) -> some View {
        FlatMenu(width: 190) {
            LightningIconView(.ellipsis, size: 14)
                .frame(width: 24, height: 24)
        } content: { select in
            if session.sidebarStatus == .open {
                let blocked = workspace.settleBlockReason(for: session)
                Button {
                    select { Task { await workspace.markSessionSettled(session.id) } }
                } label: {
                    FlatMenuRow(title: Text("标记已完成"), lightningIcon: .checkmarkCircle)
                }
                .disabled(blocked != nil)
            } else {
                Button {
                    select { Task { await workspace.reopenSession(session.id) } }
                } label: {
                    FlatMenuRow(title: Text("移回待处理"), lightningIcon: .arrowUturnBackward)
                }
            }
            ZivviDivider()
            let archiveBlock = workspace.sessionArchiveBlockReason(for: session)
            Button {
                select { onManageSession(.archive, session.id) }
            } label: {
                FlatMenuRow(title: Text("归档会话"), lightningIcon: .archivebox)
            }
            .disabled(archiveBlock != nil)
            if workspace.retirementRequiresConfirmation(session.id) {
                Button {
                    select { onManageSession(.confirmRetirement, session.id) }
                } label: {
                    FlatMenuRow(title: Text("应用智能体配置…"), lightningIcon: .arrowTriangleheadClockwise)
                }
            }
            if let active = workspace.execution(for: session.id),
               active.connection != .disconnected,
               active.connection == .blocked || active.phase == .uncertain {
                Button(role: .destructive) {
                    select { onManageSession(.forceEnd, session.id) }
                } label: {
                    FlatMenuRow(title: Text("结束受管进程"), lightningIcon: .exclamationmarkTriangle)
                }
            }
        }
        .fixedSize()
        .help("当前会话操作")
        .accessibilityLabel("当前会话操作")
    }
}

private struct ConversationTabItem: View {
    let workspace: WorkspaceController
    let session: SessionReference
    let project: ProjectRecord
    let isActive: Bool
    let showsProjectBadge: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    private var status: SidebarSessionStatus? {
        SidebarSessionStatus.resolve(
            execution: workspace.execution(for: session.id),
            needsReview: session.submissions.contains(where: \.needsReview),
            hasDraft: false,
            hasExecutionError: workspace.presentations[session.id]?.executionError != nil
        )
    }

    var body: some View {
        let showsClose = isActive || isHovered
        HStack(spacing: 5) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    statusIcon
                    if showsProjectBadge {
                        ProjectBadge(project: project, compact: true)
                            .scaleEffect(0.85)
                    }
                    Text(verbatim: session.displayTitle)
                        .zivviFont(.subheadline, weight: isActive ? .medium : .regular)
                        .foregroundStyle(isActive ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                LightningIconView(.xmark, size: 10)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 4))
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .padding(.trailing, 5)
            .help("关闭会话标签（保留会话与后台运行）")
            .accessibilityLabel("关闭 \(session.displayTitle)")
        }
        .frame(minWidth: 88, maxWidth: 200)
        .frame(height: 28)
        .background(
            isActive ? ZivviTheme.selected : (isHovered ? ZivviTheme.controlHover : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help("\(project.displayName) / \(session.displayTitle)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("conversation-tab-\(session.id)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let status {
            switch status {
            case .awaitingApproval, .awaitingInput, .review:
                LightningIconView(.exclamationmarkTriangleFill, size: 11)
                    .accessibilityHidden(false)
                    .accessibilityLabel(Text(status.label))
            case .failed, .blocked:
                LightningIconView(.xmarkCircleFill, size: 11)
                    .accessibilityHidden(false)
                    .accessibilityLabel(Text(status.label))
            case .running, .retrying, .compacting:
                Circle()
                    .fill(ZivviTheme.sidebarRunningDot)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(Text(status.label))
            default:
                EmptyView()
            }
        } else if session.hasUnreadCompletion {
            Circle()
                .fill(ZivviTheme.sidebarUnreadDot)
                .frame(width: 6, height: 6)
                .accessibilityLabel("有未读完成结果")
        }
    }
}

/// Flat horizontal tab bar for the Editor Area (right main pane).
struct EditorTabBar: View {
    let tabsModel: WorkbenchTabsModel
    let onRequestCloseTab: (WorkbenchTabsModel.EditorTab) -> Void
    let onCollapseEditor: () -> Void

    @Environment(\.zivviTypography) private var typography

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(tabsModel.editorTabs) { tab in
                            EditorTabItem(
                                tab: tab,
                                title: tabsModel.displayTitle(for: tab),
                                isActive: tab.id == tabsModel.activeEditorTabID,
                                onSelect: { tabsModel.activateEditorTab(tab.id) },
                                onClose: { onRequestCloseTab(tab) }
                            )
                            .id(tab.id)
                            .draggable(tab.id) {
                                Text(verbatim: tab.baseTitle)
                                    .zivviFont(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ZivviTheme.surface, in: .rect(cornerRadius: 6))
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let dropped = items.first else { return false }
                                tabsModel.moveEditorTab(draggedID: dropped, before: tab.id)
                                return true
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onChange(of: tabsModel.activeEditorTabID) { _, id in
                    if let id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if tabsModel.editorTabs.count > 4 {
                FlatMenu(width: 240) {
                    LightningIconView(.chevronDown, size: 12)
                        .frame(width: 22, height: 24)
                } content: { select in
                    ForEach(tabsModel.editorTabs) { tab in
                        Button { select { tabsModel.activateEditorTab(tab.id) } } label: {
                            FlatMenuRow(title: Text(verbatim: tabsModel.displayTitle(for: tab)),
                                        selected: tab.id == tabsModel.activeEditorTabID)
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: tab.id == tabsModel.activeEditorTabID))
                    }
                }
                .fixedSize()
                .help("已打开的文件与审查标签")
                .accessibilityLabel("已打开的文件与审查标签")
            }

            Spacer(minLength: 4)

            Button(action: onCollapseEditor) {
                LightningIconView(.xmark, size: 12)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
            .help("收起文件与审查区（保留已打开标签）")
            .accessibilityLabel("收起文件与审查区")
            .accessibilityIdentifier("collapse-editor-area")
        }
        .padding(.horizontal, 6)
        .frame(height: typography.titlebarControlHeight)
        .accessibilityIdentifier("editor-tab-bar")
    }
}

private struct EditorTabItem: View {
    let tab: WorkbenchTabsModel.EditorTab
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        let showsClose = isActive || isHovered
        HStack(spacing: 5) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    tabIcon
                    Text(verbatim: title)
                        .zivviFont(.subheadline, weight: isActive ? .medium : .regular)
                        .foregroundStyle(isActive ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                ZStack {
                    if tab.isDirty && !isHovered {
                        Circle()
                            .fill(ZivviTheme.primaryText)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("有未保存修改")
                    } else {
                        LightningIconView(.xmark, size: 10)
                            .opacity(showsClose ? 1 : 0)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 4))
            .allowsHitTesting(showsClose || tab.isDirty)
            .padding(.trailing, 5)
            .help("关闭标签页")
            .accessibilityLabel("关闭 \(title)")
        }
        .frame(minWidth: 88, maxWidth: 210)
        .frame(height: 28)
        .background(
            isActive ? ZivviTheme.selected : (isHovered ? ZivviTheme.controlHover : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help(tabTooltip)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("editor-tab-\(tab.id)")
    }

    @ViewBuilder
    private var tabIcon: some View {
        switch tab.kind {
        case .file(_, _, _, let path, let kind):
            ProjectFileIcon(path: path, kind: kind)
                .frame(width: 12)
        case .gitDiff:
            LightningIconView(.arrowLeftArrowRight, size: 12)
        case .toolDiff:
            LightningIconView(.clockArrowCirclepath, size: 12)
        case .commit:
            GitCommitIcon()
        }
    }

    private var tabTooltip: String {
        switch tab.kind {
        case .file(_, _, let projectName, let path, _):
            "\(projectName) / \(path.relativePath)"
        case .gitDiff(_, _, let projectName, let path, _, let scope, _):
            "\(projectName) / \(path) · \(scope.comparisonLabel)"
        case .toolDiff(_, let projectName, let title):
            [projectName, tab.toolDiffPath, title].compactMap { $0 }.joined(separator: " · ")
        case .commit(_, _, let projectName, _, let shortHash, let subject):
            "\(projectName) · \(shortHash) \(subject)"
        }
    }
}
