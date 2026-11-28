import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct SessionSidebarFilter: Equatable {
    var query = ""
    var projectID: UUID?

    var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { projectID != nil || !searchTerm.isEmpty }
    var normalized: Self { .init(query: searchTerm, projectID: projectID) }

    mutating func reveal(in project: UUID) {
        query = ""
        if projectID != project { projectID = nil }
    }
}

struct SidebarSessionGroups {
    struct Row: Identifiable {
        let session: SessionReference
        let project: ProjectRecord

        var id: UUID { session.id }
    }

    private let rows: [SessionProcessingStatus: [Row]]

    init(sessions: [SessionReference], projects: [ProjectRecord], filter: SessionSidebarFilter) {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let normalized = filter.normalized
        let matching = sessions.compactMap { session -> Row? in
            guard session.archivedAt == nil, let project = projectsByID[session.projectID] else { return nil }
            let row = Row(session: session, project: project)
            return Self.matches(row, filter: normalized) ? row : nil
        }.sorted {
            let left = $0.session.activity.date
            let right = $1.session.activity.date
            return left == right ? $0.id < $1.id : left > right
        }
        rows = Dictionary(grouping: matching) { $0.session.sidebarStatus }
    }

    private static func matches(_ row: Row, filter: SessionSidebarFilter) -> Bool {
        let term = filter.query
        return (filter.projectID == nil || filter.projectID == row.project.id)
            && (term.isEmpty || row.session.displayTitle.localizedStandardContains(term)
                || row.project.displayName.localizedStandardContains(term)
                || row.project.name.localizedStandardContains(term))
    }

    func count(in status: SessionProcessingStatus) -> Int { rows[status]?.count ?? 0 }

    func visibleRows(in status: SessionProcessingStatus, expanded: Bool, selected: UUID?,
                     settledLimit: Int = SidebarSettledBatches.initialLimit) -> [Row] {
        let rows = rows[status] ?? []
        if expanded { return status == .settled ? Array(rows.prefix(settledLimit)) : rows }
        guard let selected, let row = rows.first(where: { $0.id == selected }) else { return [] }
        return [row]
    }

    func settledIndex(of selection: UUID?) -> Int? {
        guard let selection else { return nil }
        return rows[.settled]?.firstIndex { $0.id == selection }
    }

    func newlyMatchingSettledID(_ selection: UUID?, previousFilter: SessionSidebarFilter) -> UUID? {
        guard let selection,
              let row = rows[.settled]?.first(where: { $0.id == selection }),
              !Self.matches(row, filter: previousFilter.normalized) else { return nil }
        return row.id
    }

    func settledID(at index: Int) -> UUID? {
        guard let settled = rows[.settled], settled.indices.contains(index) else { return nil }
        return settled[index].id
    }
}

struct SidebarSettledBatches {
    static let initialLimit = 10
    static let batchSize = 25

    private var unfilteredLimit = Self.initialLimit
    private var filtered: (filter: SessionSidebarFilter, limit: Int)?

    func limit(for filter: SessionSidebarFilter, including selectedIndex: Int? = nil) -> Int {
        let scope = filter.normalized
        let scopedLimit = filtered.flatMap { $0.filter == scope ? $0.limit : nil }
        let saved = scope.isActive ? scopedLimit ?? Self.initialLimit : unfilteredLimit
        guard let selectedIndex, selectedIndex >= saved else { return saved }
        let batch = (selectedIndex - Self.initialLimit) / Self.batchSize + 1
        return Self.initialLimit + batch * Self.batchSize
    }

    mutating func remember(_ limit: Int, for filter: SessionSidebarFilter) {
        let scope = filter.normalized
        if scope.isActive {
            filtered = (scope, limit)
        } else {
            unfilteredLimit = limit
        }
    }

    mutating func updateFilter(_ filter: SessionSidebarFilter) {
        if filtered?.filter != filter.normalized { filtered = nil }
    }

    static func remainingInNextBatch(total: Int, limit: Int) -> Int {
        min(batchSize, max(0, total - limit))
    }
}

struct SessionSidebar: View {
    let workspace: WorkspaceController
    @Binding var filter: SessionSidebarFilter
    let navigator: ProjectNavigatorModel
    let gitStore: GitStatusStore
    let openProject: () -> Void
    let createSessionInProject: (UUID) -> Void
    let onSelectSession: (UUID) -> Void
    let onOpenFile: (ProjectRecord, ProjectFileEntry) -> Void
    let onOpenDiff: (ProjectRecord, GitFileChange, String) -> Void
    let onOpenCommit: (ProjectRecord, GitCommitSummary) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void
    var activeEditorFile: (projectID: UUID, path: ProjectFilePath)? = nil
    var activeEditorDiff: (projectID: UUID, path: String, scope: GitDiffScope)? = nil
    var activeEditorCommit: (projectID: UUID, hash: String)? = nil
    var showsImportHistory = false
    var importHistory: () -> Void = {}

    var body: some View {
        let groups = SidebarSessionGroups(sessions: workspace.state.sessions, projects: workspace.state.projects, filter: filter)
        VStack(spacing: 0) {
            ZivviDivider(color: ZivviTheme.subtleDivider)
            SessionSidebarControls(
                workspace: workspace,
                filter: $filter,
                openProject: openProject,
                showsImportHistory: showsImportHistory,
                importHistory: importHistory
            )
            if let warning = workspace.historyIndexWarning {
                SessionHistoryWarning(message: warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            ProjectNavigatorList(
                workspace: workspace,
                filter: filter,
                groups: groups,
                navigator: navigator,
                gitStore: gitStore,
                activeEditorFile: activeEditorFile,
                activeEditorDiff: activeEditorDiff,
                activeEditorCommit: activeEditorCommit,
                createSessionInProject: createSessionInProject,
                onSelectSession: onSelectSession,
                onOpenFile: onOpenFile,
                onOpenDiff: onOpenDiff,
                onOpenCommit: onOpenCommit,
                manageSession: manageSession
            )
        }
        .foregroundStyle(ZivviTheme.primaryText)
        .background(ZivviTheme.pageBackground)
    }
}

private struct SessionHistoryWarning: View {
    let message: String
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 5) {
                LightningIconView(.exclamationmarkTriangle, size: 13)
                Text("会话列表更新异常")
                LightningIconView(.chevronRight, size: 11)
            }
            .zivviFont(.caption)
            .foregroundStyle(ZivviTheme.warningText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(showsDetails ? Color.clear : ZivviTheme.warningSurface, in: .capsule)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: showsDetails, inset: false, cornerRadius: 12))
        .accessibilityValue(showsDetails ? Text("已展开") : Text("已折叠"))
        .accessibilityIdentifier("session-history-warning")
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            ScrollView {
                Text(verbatim: message)
                    .zivviFont(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 280)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .frame(idealHeight: 110, maxHeight: 220)
            .background(ZivviTheme.pageBackground)
            .presentationBackground(ZivviTheme.pageBackground)
        }
    }
}

private struct SessionSidebarControls: View {
    let workspace: WorkspaceController
    @Binding var filter: SessionSidebarFilter
    let openProject: () -> Void
    let showsImportHistory: Bool
    let importHistory: () -> Void
    @State private var searchHovered = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                LightningIconView(.magnifyingglass, size: 13)
                TextField("搜索", text: $filter.query,
                          prompt: Text("搜索项目或会话").foregroundStyle(ZivviTheme.secondaryText))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("search-sessions")
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        LightningIconView(.xmarkCircleFill, size: 13)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false))
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .zivviFont(.callout)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .padding(.vertical, 3)
            .background(searchHovered ? ZivviTheme.controlHover : .clear, in: .rect(cornerRadius: 7))
            .overlay {
                if searchFocused {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(ZivviTheme.focusBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect(cornerRadius: 7))
            .onHover { searchHovered = $0 }

            if showsImportHistory {
                FlatMenu(width: 220) {
                    IconButtonLabel(systemName: "ellipsis")
                        .foregroundStyle(ZivviTheme.secondaryText)
                } content: { select in
                    Button { select(importHistory) } label: {
                        FlatMenuRow(title: Text("从 Agent 导入会话"), lightningIcon: .squareAndArrowDown)
                    }
                    .disabled(!workspace.canManageProjects || workspace.state.projects.isEmpty)
                }
                .fixedSize()
                .help("更多项目操作")
                .accessibilityLabel("更多项目操作")
            }

            SidebarIconButton("添加项目", icon: IconButtonLabel(assetName: "SidebarFolderPlus"), action: openProject)
                .disabled(!workspace.canManageProjects)
                .accessibilityIdentifier("open-project")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private enum SidebarFocus: Hashable {
    case session(UUID)
    case remind(UUID)
    case settle(UUID)
    case reopen(UUID)
    case showMore

    var sessionID: UUID? {
        switch self {
        case .session(let id), .remind(let id), .settle(let id), .reopen(let id): id
        case .showMore: nil
        }
    }
}

private struct ProjectNavigatorList: View {
    let workspace: WorkspaceController
    let filter: SessionSidebarFilter
    let groups: SidebarSessionGroups
    let navigator: ProjectNavigatorModel
    let gitStore: GitStatusStore
    let activeEditorFile: (projectID: UUID, path: ProjectFilePath)?
    let activeEditorDiff: (projectID: UUID, path: String, scope: GitDiffScope)?
    let activeEditorCommit: (projectID: UUID, hash: String)?
    let createSessionInProject: (UUID) -> Void
    let onSelectSession: (UUID) -> Void
    let onOpenFile: (ProjectRecord, ProjectFileEntry) -> Void
    let onOpenDiff: (ProjectRecord, GitFileChange, String) -> Void
    let onOpenCommit: (ProjectRecord, GitCommitSummary) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void

    @AppStorage("session-sidebar-settled-expanded") private var settledExpanded = false
    @State private var filteredSettledExpansion: Bool?
    @State private var batches = SidebarSettledBatches()
    @State private var revealSettled = false
    @State private var appendedFocusID: UUID?
    @FocusState private var focus: SidebarFocus?
    private let listPadding: CGFloat = 8

    private var visibleProjects: [ProjectRecord] {
        let term = filter.searchTerm
        return workspace.state.projects.filter { project in
            if let filterProjectID = filter.projectID, project.id != filterProjectID { return false }
            guard !term.isEmpty else { return true }
            if project.displayName.localizedStandardContains(term) || project.name.localizedStandardContains(term) {
                return true
            }
            let openRows = groups.visibleRows(in: .open, expanded: true, selected: workspace.state.selectedSessionID)
            if openRows.contains(where: { $0.project.id == project.id }) { return true }
            if navigator.mode(for: project.id) == .files { return true }
            return false
        }
    }

    var body: some View {
        let selected = workspace.state.selectedSessionID
        let selectedStatus = workspace.selected?.sidebarStatus
        let openRowsByProject = Dictionary(
            grouping: groups.visibleRows(in: .open, expanded: true, selected: selected),
            by: { $0.project.id }
        )
        let settledCount = groups.count(in: .settled)
        let isSettledExpanded = settledCount > 0 && (filter.isActive ? filteredSettledExpansion ?? true : settledExpanded)
        let selectedSettledIndex = groups.settledIndex(of: selected)
        let settledLimit = batches.limit(for: filter, including: isSettledExpanded ? selectedSettledIndex : nil)
        let settledRows = groups.visibleRows(in: .settled, expanded: isSettledExpanded, selected: selected, settledLimit: settledLimit)
        let isSearching = !filter.searchTerm.isEmpty

        GeometryReader { viewport in
            let isCompactSidebar = viewport.size.width < 205
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if visibleProjects.isEmpty {
                            Text(filter.isActive ? "没有匹配的项目或会话" : "点击右上角添加本地项目")
                                .zivviFont(.callout)
                                .foregroundStyle(ZivviTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(visibleProjects) { project in
                                ProjectNavigatorSection(
                                    project: project,
                                    workspace: workspace,
                                    navigator: navigator,
                                    gitStore: gitStore,
                                    openRows: openRowsByProject[project.id] ?? [],
                                    selectedSessionID: selected,
                                    isCompactSidebar: isCompactSidebar,
                                    isSearching: isSearching,
                                    searchQuery: filter.searchTerm,
                                    activeFilePath: activeEditorFile?.projectID == project.id ? activeEditorFile?.path : nil,
                                    activeDiffPath: activeEditorDiff?.projectID == project.id ? activeEditorDiff?.path : nil,
                                    activeDiffScope: activeEditorDiff?.projectID == project.id ? activeEditorDiff?.scope : nil,
                                    activeCommitHash: activeEditorCommit?.projectID == project.id ? activeEditorCommit?.hash : nil,
                                    focus: $focus,
                                    createSession: { createSessionInProject(project.id) },
                                    onSelectSession: onSelectSession,
                                    onOpenFile: onOpenFile,
                                    onOpenDiff: onOpenDiff,
                                    onOpenCommit: onOpenCommit,
                                    manageSession: manageSession
                                )
                            }
                        }

                        if settledCount > 0 || !visibleProjects.isEmpty {
                            ZivviDivider(color: ZivviTheme.subtleDivider)
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                        }

                        SettledSidebarSection(
                            workspace: workspace,
                            rows: settledRows,
                            selected: selected,
                            count: settledCount,
                            expanded: isSettledExpanded,
                            nextCount: SidebarSettledBatches.remainingInNextBatch(total: settledCount, limit: settledLimit),
                            focus: $focus,
                            onSelectSession: onSelectSession,
                            manageSession: manageSession
                        ) {
                            if filter.isActive { filteredSettledExpansion = !isSettledExpanded }
                            else { settledExpanded = !isSettledExpanded }
                            if !isSettledExpanded { revealSettled.toggle() }
                        } showMore: {
                            guard let firstNewID = groups.settledID(at: settledLimit) else { return }
                            let input = NSApp.currentEvent?.type
                            if input == .keyDown || input == .keyUp { appendedFocusID = firstNewID }
                            batches.remember(settledLimit + SidebarSettledBatches.batchSize, for: filter)
                        }
                    }
                    .frame(minHeight: max(0, viewport.size.height - 2 * listPadding), alignment: .top)
                    .padding(listPadding)
                }
                .scrollIndicators(.never, axes: .vertical)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .onChange(of: revealSettled) {
                    if selectedSettledIndex != nil, let selected {
                        scroll.scrollTo(selected)
                    } else {
                        scroll.scrollTo(SessionProcessingStatus.settled, anchor: .top)
                    }
                }
                .onChange(of: selected, initial: true) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
                .onChange(of: selectedStatus) {
                    if let selected { scroll.scrollTo(selected) }
                }
                .onChange(of: filter.normalized) { previous, current in
                    batches.updateFilter(current)
                    if !current.isActive { filteredSettledExpansion = nil }
                    rememberLimit(settledLimit)
                    let target = current.isActive
                        ? groups.newlyMatchingSettledID(selected, previousFilter: previous)
                        : selected
                    if let target { scroll.scrollTo(target) }
                }
                .onChange(of: settledLimit, initial: true) {
                    rememberLimit(settledLimit)
                }
                .onChange(of: appendedFocusID) {
                    guard let id = appendedFocusID else { return }
                    scroll.scrollTo(id)
                    focus = .session(id)
                    appendedFocusID = nil
                }
            }
        }
    }

    private func rememberLimit(_ limit: Int) {
        if limit > batches.limit(for: filter) { batches.remember(limit, for: filter) }
    }
}

private struct ProjectNavigatorSection: View {
    let project: ProjectRecord
    let workspace: WorkspaceController
    let navigator: ProjectNavigatorModel
    let gitStore: GitStatusStore
    let openRows: [SidebarSessionGroups.Row]
    let selectedSessionID: UUID?
    let isCompactSidebar: Bool
    let isSearching: Bool
    let searchQuery: String
    let activeFilePath: ProjectFilePath?
    let activeDiffPath: String?
    let activeDiffScope: GitDiffScope?
    let activeCommitHash: String?
    let focus: FocusState<SidebarFocus?>.Binding
    let createSession: () -> Void
    let onSelectSession: (UUID) -> Void
    let onOpenFile: (ProjectRecord, ProjectFileEntry) -> Void
    let onOpenDiff: (ProjectRecord, GitFileChange, String) -> Void
    let onOpenCommit: (ProjectRecord, GitCommitSummary) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void

    private var mode: ProjectNavigationMode { navigator.mode(for: project.id) }
    private var isExpanded: Bool { isSearching || navigator.isExpanded(for: project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            projectHeader
            if isExpanded {
                switch mode {
                case .sessions:
                    if openRows.isEmpty {
                        Text(isSearching ? "没有匹配的会话" : "暂无活跃会话")
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                            .padding(.leading, 24)
                            .padding(.vertical, 4)
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(openRows) { row in
                                SidebarSessionCard(
                                    workspace: workspace,
                                    session: row.session,
                                    project: row.project,
                                    selected: row.id == selectedSessionID,
                                    showsProjectPrefix: isSearching,
                                    focus: focus,
                                    onSelect: { onSelectSession(row.id) },
                                    manageSession: manageSession
                                )
                            }
                        }
                        .padding(.leading, 6)
                    }
                case .files:
                    ProjectNavigatorFilesView(
                        project: project,
                        model: navigator.fileTree(for: project),
                        gitStore: gitStore,
                        activeFilePath: activeFilePath,
                        searchQuery: searchQuery,
                        onOpenFile: onOpenFile
                    )
                case .git:
                    ProjectNavigatorGitView(
                        project: project,
                        gitStore: gitStore,
                        activeDiffPath: activeDiffPath,
                        activeDiffScope: activeDiffScope,
                        activeCommitHash: activeCommitHash,
                        onOpenDiff: onOpenDiff,
                        onOpenCommit: onOpenCommit
                    )
                }
            }
        }
        .accessibilityIdentifier("project-section-\(project.id)")
    }

    private var projectHeader: some View {
        HStack(spacing: 4) {
            Button {
                navigator.toggleExpanded(for: project.id)
            } label: {
                HStack(spacing: 5) {
                    FlatDisclosureChevron(expanded: isExpanded)
                        .frame(width: 10)
                    ProjectBadge(project: project, compact: true)
                    Text(verbatim: project.displayName)
                        .zivviFont(.callout, weight: .semibold)
                        .foregroundStyle(ZivviTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
            .help(project.path)
            .accessibilityLabel("项目 \(project.displayName)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .layoutPriority(1)

            Spacer(minLength: 2)

            if isCompactSidebar {
                compactModeMenu
            } else {
                HStack(spacing: 1) {
                    ForEach(ProjectNavigationMode.allCases) { item in
                        let isSelected = mode == item
                        Button {
                            navigator.setMode(item, for: project, gitStore: gitStore)
                        } label: {
                            navigationModeIcon(for: item, size: 12)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: isSelected, inset: false, cornerRadius: 5))
                        .help(Text(item.title))
                        .accessibilityLabel("\(project.displayName) \(Text(item.title))")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("project-mode-\(item.rawValue)-\(project.id)")
                    }
                }
            }

            Button(action: createSession) {
                LightningBrandIconView(.newSession, size: 13)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
            .disabled(!workspace.canManageProjects)
            .help("在 \(project.displayName) 中新建会话")
            .accessibilityLabel("在 \(project.displayName) 中新建会话")
            .accessibilityIdentifier("new-session-project-\(project.id)")
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func navigationModeIcon(for item: ProjectNavigationMode, size: CGFloat) -> some View {
        switch item {
        case .sessions: LightningBrandIconView(.sessions, size: size)
        case .files: LightningBrandIconView(.files, size: size)
        case .git: LightningIconView(.arrowTriangleBranch, size: size)
        }
    }

    private var compactModeMenu: some View {
        FlatMenu(width: 140) {
            navigationModeIcon(for: mode, size: 13)
                .frame(width: 22, height: 22)
        } content: { select in
            ForEach(ProjectNavigationMode.allCases) { item in
                Button {
                    select { navigator.setMode(item, for: project, gitStore: gitStore) }
                } label: {
                    switch item {
                    case .sessions:
                        FlatMenuRow(title: Text(item.title), selected: mode == item, brandIcon: .sessions)
                    case .files:
                        FlatMenuRow(title: Text(item.title), selected: mode == item, brandIcon: .files)
                    case .git:
                        FlatMenuRow(title: Text(item.title), selected: mode == item, lightningIcon: .arrowTriangleBranch)
                    }
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: mode == item))
            }
        }
        .fixedSize()
        .help("切换导航模式")
        .accessibilityLabel("\(project.displayName) 导航模式")
    }
}

private struct SettledSidebarSection: View {
    let workspace: WorkspaceController
    let rows: [SidebarSessionGroups.Row]
    let selected: UUID?
    let count: Int
    let expanded: Bool
    let nextCount: Int
    let focus: FocusState<SidebarFocus?>.Binding
    let onSelectSession: (UUID) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void
    let toggleExpansion: () -> Void
    let showMore: () -> Void

    var body: some View {
        LazyVStack(spacing: 3) {
            SettledSidebarHeader(count: count, expanded: expanded, toggle: toggleExpansion)
                .id(SessionProcessingStatus.settled)
            ForEach(rows) { row in
                SidebarSessionCard(
                    workspace: workspace,
                    session: row.session,
                    project: row.project,
                    selected: row.id == selected,
                    showsProjectPrefix: true,
                    focus: focus,
                    onSelect: { onSelectSession(row.id) },
                    manageSession: manageSession
                )
            }
            if expanded && nextCount > 0 {
                Button(action: showMore) {
                    Label("再显示 \(nextCount) 条", systemImage: "chevron.down")
                        .zivviFont(.callout)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false))
                .focused(focus, equals: .showMore)
                .accessibilityIdentifier("show-more-settled")
            }
        }
    }
}

private struct SettledSidebarHeader: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Text(LocalizedStringResource("session.group.settled", defaultValue: "已完成",
                                             comment: "Short sidebar heading for settled sessions"))
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(ZivviTheme.tertiaryText)
                FlatDisclosureChevron(expanded: expanded)
            }
            .zivviFont(.callout)
            .foregroundStyle(ZivviTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .disabled(count == 0)
        .accessibilityLabel("已完成会话")
        .accessibilityValue(expanded ? "已展开，\(count) 个" : "已收起，\(count) 个")
        .accessibilityIdentifier("sessions-settled")
    }
}

enum SidebarSessionStatus: String {
    case running, awaitingApproval, awaitingInput, draft, review, cleaning, retrying, compacting, stopping
    case connecting, blocked, failed, historyIssue

    var label: LocalizedStringResource {
        switch self {
        case .running: "运行中"
        case .awaitingApproval: "待审批"
        case .awaitingInput: "待输入"
        case .draft: "有草稿"
        case .review: "待核对"
        case .cleaning: "清理中"
        case .retrying: "重试中"
        case .compacting: "压缩中"
        case .stopping: "停止中"
        case .connecting: "连接中"
        case .blocked: "已阻止"
        case .failed: "发生错误"
        case .historyIssue: "历史异常"
        }
    }

    var needsAction: Bool {
        switch self {
        case .awaitingApproval, .awaitingInput, .review, .blocked, .failed, .historyIssue: true
        default: false
        }
    }

    var isRunning: Bool { self == .running || self == .retrying }

    @MainActor static func resolve(execution: SessionController?, needsReview: Bool, hasDraft: Bool,
                                   hasExecutionError: Bool = false) -> Self? {
        if let execution {
            if execution.connection == .blocked { return .blocked }
            if execution.phase == .uncertain { return .review }
            if execution.connection == .closing { return .cleaning }
            if execution.isStopping { return .stopping }
            if execution.interactions.contains(where: \.isPermissionApproval) { return .awaitingApproval }
            if !execution.interactions.isEmpty { return .awaitingInput }
            if execution.connection == .connecting { return .connecting }
            if execution.connection == .connected {
                switch execution.phase {
                case .running: return .running
                case .retrying: return .retrying
                case .compacting: return .compacting
                default: break
                }
            }
        }
        if hasExecutionError || execution?.failure != nil { return .failed }
        if needsReview { return .review }
        return hasDraft ? .draft : nil
    }
}

enum SidebarCardIndicator: Equatable {
    case status(SidebarSessionStatus), unreadCompletion, reminderDue, reminderSnoozed(Date)

    var label: String {
        switch self {
        case .status(.blocked): String(localized: "进程清理待核实 · 已阻止继续执行")
        case .status(.historyIssue): String(localized: "历史读取异常或尾部未写完")
        case .status(let status): String(localized: status.label)
        case .unreadCompletion: String(localized: "任务已完成，尚未查看")
        case .reminderDue: String(localized: "提醒已到期")
        case .reminderSnoozed(let date): String(localized: "暂缓至 \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    var color: Color {
        switch self {
        case .status(.blocked), .status(.failed): ZivviTheme.errorText
        case .status(let status) where status.needsAction: ZivviTheme.warningText
        case .reminderDue: ZivviTheme.warningText
        case .status(let status) where status.isRunning: ZivviTheme.runningText
        case .unreadCompletion: ZivviTheme.infoText
        case .status(.draft): ZivviTheme.draftText
        default: ZivviTheme.secondaryText
        }
    }

    var dotColor: Color {
        switch self {
        case .status(.blocked), .status(.failed): color
        case .status(let status) where status.needsAction: ZivviTheme.sidebarWarningDot
        case .reminderDue: ZivviTheme.sidebarWarningDot
        case .status(let status) where status.isRunning: ZivviTheme.sidebarRunningDot
        case .unreadCompletion: ZivviTheme.sidebarUnreadDot
        default: color
        }
    }

    var badgeLabel: LocalizedStringResource {
        switch self {
        case .status(let status): status.label
        case .unreadCompletion: "未读"
        case .reminderDue: "提醒已到期"
        case .reminderSnoozed: "已暂缓"
        }
    }

    // The first entry is visible on the card. All entries remain available in the details.
    static func ordered(execution: SidebarSessionStatus?, needsReview: Bool, hasDraft: Bool,
                        unread: Bool, reminder: SessionReminderState, hasHistoryIssue: Bool = false) -> [Self] {
        var indicators: [Self] = []
        if let execution, execution.needsAction { indicators.append(.status(execution)) }
        if needsReview, execution != .review { indicators.append(.status(.review)) }
        if hasHistoryIssue { indicators.append(.status(.historyIssue)) }
        if reminder == .due { indicators.append(.reminderDue) }
        if let execution, execution.isRunning { indicators.append(.status(execution)) }
        if unread { indicators.append(.unreadCompletion) }
        if let execution, !execution.needsAction && !execution.isRunning { indicators.append(.status(execution)) }
        if hasDraft, execution != .draft { indicators.append(.status(.draft)) }
        if case .snoozed(let date) = reminder { indicators.append(.reminderSnoozed(date)) }
        return indicators
    }
}

private struct SidebarSessionCard: View {
    @Environment(\.zivviTypography) private var typography
    let workspace: WorkspaceController
    let session: SessionReference
    let project: ProjectRecord
    let selected: Bool
    var showsProjectPrefix: Bool = false
    let focus: FocusState<SidebarFocus?>.Binding
    let onSelect: () -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void
    @State private var isHovered = false
    @State private var reminderPresented = false
    private var isOpen: Bool { session.sidebarStatus == .open }
    private var timeWidth: CGFloat { typography.sidebarTimeWidth }
    private var actionSlotWidth: CGFloat { 2 * IconButtonLabel.side + 3 }
    private var trailingSlotWidth: CGFloat { max(actionSlotWidth, timeWidth) }
    private let horizontalInset: CGFloat = 8
    private let openVerticalInset: CGFloat = 6

    private var showsActions: Bool {
        isHovered || focus.wrappedValue?.sessionID == session.id || reminderPresented
    }

    private func indicators(reminder: SessionReminderState) -> [SidebarCardIndicator] {
        let presentation = isOpen ? workspace.presentations[session.id] : nil
        let hasHistoryIssue = presentation?.loadError != nil
        return SidebarCardIndicator.ordered(
            execution: isOpen ? SidebarSessionStatus.resolve(execution: workspace.execution(for: session.id),
                                                            needsReview: false, hasDraft: false,
                                                            hasExecutionError: !hasHistoryIssue && presentation?.executionError != nil) : nil,
            needsReview: isOpen && session.submissions.contains(where: \.needsReview),
            hasDraft: isOpen && workspace.hasDraft(session), unread: session.hasUnreadCompletion, reminder: reminder,
            hasHistoryIssue: hasHistoryIssue)
    }

    private var model: (provider: String?, name: String?) {
        if let active = workspace.execution(for: session.id), active.connection == .connected {
            return (active.session?.provider, active.session?.model ?? active.session?.modelID)
        }
        if let selection = session.selection { return (selection.provider, session.modelName ?? selection.modelID) }
        return (session.historicalModel?.provider, session.historicalModel?.modelID)
    }

    private var modelHelp: String {
        let model = model
        let providerName = model.provider?.lowercased() == "openai" ? "OpenAI" : model.provider
        return [providerName, model.name ?? String(localized: "模型未知")].compactMap { $0 }.joined(separator: " · ")
    }

    private var agentDisplayName: String {
        if session.runtimeID.isEmpty { return String(localized: "未知") }
        let resolved = workspace.runtimeDisplayName(for: session.runtimeID)
        if resolved != session.runtimeID { return resolved }
        return CodingAgentLabel.displayName(for: session.runtimeID, agents: workspace.acpAgents)
    }

    private var agentHelp: String {
        let agentName = switch session.runtimeID {
        case "": String(localized: "未知")
        default: agentDisplayName
        }
        return String(localized: "Agent：\(agentName)")
    }

    private var agentIcon: some View {
        CodingAgentIcon(runtimeID: session.runtimeID, displayName: agentDisplayName, agents: workspace.acpAgents)
    }

    private var modelAndAgentIcons: some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: model.provider ?? "", model: model.name)
            agentIcon
        }
        .foregroundStyle(ZivviTheme.tertiaryText)
    }

    var body: some View {
        let now = Date.now
        let reminder = session.reminderState(at: now)
        let dates: [Date] = if case .snoozed(let deadline) = reminder { [now, deadline] } else { [now] }
        TimelineView(.explicit(dates)) { context in
            card(reminder: session.reminderState(at: context.date))
        }
    }

    private func card(reminder: SessionReminderState) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let indicators = indicators(reminder: reminder)
        return Group {
            if isOpen {
                selectionButton(indicators: indicators)
                    .accessibilityActions {
                        if workspace.initialized && workspace.storageError == nil {
                            Button("暂缓提醒") { reminderPresented = true }
                        }
                        if workspace.settleBlockReason(for: session) == nil {
                            Button("标记已完成") { move(to: .settled) }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        actions(reminder: reminder)
                            .frame(width: actionSlotWidth, alignment: .trailing)
                            .padding(.top, 4).padding(.trailing, horizontalInset)
                    }
            } else {
                selectionButton(indicators: indicators)
                    .accessibilityAction(named: Text("移回待处理")) { move(to: .open) }
                    .overlay(alignment: .trailing) {
                        Button {
                            move(to: .open)
                        } label: {
                            IconButtonLabel(systemName: "arrow.uturn.backward")
                                .foregroundStyle(ZivviTheme.secondaryText)
                        }
                        .buttonStyle(FlatControlButtonStyle(inset: false))
                        .focused(focus, equals: .reopen(session.id))
                        .disabled(!showsActions)
                        .revealedAction(showsActions)
                        .accessibilityHidden(!showsActions)
                        .help("移回待处理")
                        .accessibilityLabel("移回待处理")
                        .padding(.trailing, horizontalInset)
                    }
            }
        }
        .background(cardFill, in: shape)
        .overlay {
            let focused = focus.wrappedValue == .session(session.id)
            if focused {
                shape.strokeBorder(ZivviTheme.focusBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .background {
            SidebarHoverPanel(active: isHovered && !reminderPresented, content: hoverCard(indicators: indicators))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button { manageSession(.archive, session.id) } label: {
                LightningLabel("归档", icon: .archivebox, size: 13)
            }
            .disabled(workspace.sessionArchiveBlockReason(for: session) != nil)
            if session.canDeleteRemoteHistory == true && session.remoteHistoryDeleted != true {
                Button(role: .destructive) { manageSession(.deleteRemoteHistory, session.id) } label: {
                    LightningLabel("从 Agent 历史删除", icon: .trash, size: 13)
                }
                .disabled(workspace.sessionArchiveBlockReason(for: session) != nil)
            }
            if workspace.isDeletableDraft(session) {
                Button(role: .destructive) { manageSession(.deleteDraft, session.id) } label: {
                    LightningLabel("删除草稿", icon: .trash, size: 13)
                }
                .disabled(!workspace.canDeleteDraft(session))
            }
        }
    }

    private var cardFill: Color {
        if selected { return ZivviTheme.selected }
        if isHovered || reminderPresented { return ZivviTheme.controlHover }
        return .clear
    }

    private func selectionButton(indicators: [SidebarCardIndicator]) -> some View {
        Button {
            DiagnosticMetrics.shared.record("history-select", tag: session.id.uuidString)
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                titleRow(indicator: indicators.first)
                if isOpen {
                    HStack(spacing: 6) {
                        if let indicator = indicators.first {
                            statusBadge(indicator)
                                .layoutPriority(1)
                        }
                        if showsProjectPrefix {
                            Text(verbatim: project.displayName)
                                .zivviFont(.caption2)
                                .foregroundStyle(ZivviTheme.tertiaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        modelAndAgentIcons
                    }
                    .padding(.leading, showsProjectPrefix ? 23 : 0)
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, isOpen ? openVerticalInset : 6)
            .frame(minHeight: isOpen ? nil : 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: .session(session.id))
        .accessibilityLabel("\(project.displayName)，\(session.displayTitle)")
        .accessibilityValue((indicators.map(\.label) + [fullActivityTime, modelHelp, agentHelp])
            .joined(separator: String(localized: "，")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("session-\(session.id)")
    }

    private func titleRow(indicator: SidebarCardIndicator?) -> some View {
        HStack(spacing: 6) {
            if showsProjectPrefix || !isOpen {
                HStack(spacing: 5) {
                    projectBadge
                    if !isOpen, let dotColor = indicator?.dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            } else if let indicator {
                Circle()
                    .fill(indicator.dotColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            Text(session.displayTitle)
                .zivviFont(.callout, weight: selected ? .medium : .regular)
                .foregroundStyle(isOpen || selected || isHovered ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            activitySlot
        }
    }

    private func statusBadge(_ indicator: SidebarCardIndicator) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(indicator.dotColor)
                .frame(width: 6, height: 6)
            Text(indicator.badgeLabel)
                .zivviFont(.caption2, weight: .medium)
                .foregroundStyle(indicator.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(indicator.color.opacity(0.12), in: .capsule)
        .accessibilityHidden(true)
    }

    private var fullActivityTime: String {
        let time = session.activity.date.formatted(date: .abbreviated, time: .shortened)
        return session.activity.isEstimate ? String(localized: "近似时间：\(time)") : time
    }

    private func hoverCard(indicators: [SidebarCardIndicator]) -> some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            Text(verbatim: session.displayTitle)
                .anchoredCardTitle()
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            hoverDetailRow(Text(verbatim: project.displayName)) {
                ProjectBadge(project: project, compact: true)
            }
            hoverDetailRow(Text(verbatim: modelHelp)) {
                ProviderLogo(provider: model.provider ?? "", model: model.name)
            }
            hoverDetailRow(Text(verbatim: agentHelp)) {
                agentIcon
            }
            ForEach(indicators.indices, id: \.self) { index in
                let indicator = indicators[index]
                hoverDetailRow(Text(indicator.label)) { LightningIconView(.circleFill, size: 9) }
                    .foregroundStyle(indicator.color)
            }
            hoverDetailRow(Text(verbatim: fullActivityTime)) { LightningIconView(.clock, size: 12) }
        }
        .zivviFont(.caption)
        .foregroundStyle(ZivviTheme.secondaryText)
        .lineLimit(1)
        .frame(width: 220, alignment: .leading)
        .anchoredPreviewCard()
        .environment(\.zivviTypography, typography)
    }

    private func hoverDetailRow<Icon: View>(_ title: Text, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon().frame(width: typography.projectBadgeCompactSize)
            title
        }
    }

    private var projectBadge: some View {
        let isSettled = session.sidebarStatus == .settled
        return ProjectBadge(project: project, compact: isSettled, muted: isSettled && !isHovered && !selected)
    }

    private var activitySlot: some View {
        activityTime
            .frame(width: trailingSlotWidth, alignment: .trailing)
            .opacity(showsActions ? 0 : 1)
            .accessibilityHidden(true)
    }

    private var activityTime: some View {
        let activity = session.activity
        let date = activity.date
        let format: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.month(.defaultDigits).day()
        return Text(date, format: format)
            .zivviFont(.caption2)
            .foregroundStyle(ZivviTheme.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: timeWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func actions(reminder: SessionReminderState) -> some View {
        let blocked = workspace.settleBlockReason(for: session)
        return HStack(spacing: 3) {
            SidebarReminderMenu(workspace: workspace, sessionID: session.id, state: reminder, showsAction: showsActions,
                                isPresented: $reminderPresented, focus: focus)
            Button {
                move(to: .settled)
            } label: {
                IconButtonLabel(systemName: "checkmark.circle")
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .focused(focus, equals: .settle(session.id))
            .disabled(blocked != nil || !showsActions)
            .revealedAction(showsActions)
            .accessibilityHidden(!showsActions)
            .help(blocked.map { String(localized: $0) } ?? String(localized: "标记已完成"))
            .accessibilityLabel("标记已完成")
            .accessibilityHint(blocked.map { String(localized: $0) } ?? "")
        }
    }

    private func move(to status: SessionProcessingStatus) {
        Task {
            switch status {
            case .open: await workspace.reopenSession(session.id)
            case .settled: await workspace.markSessionSettled(session.id)
            }
            if workspace.state.selectedSessionID == session.id { focus.wrappedValue = .session(session.id) }
        }
    }
}

struct ProjectBadge: View {
    @Environment(\.zivviTypography) private var typography
    let project: ProjectRecord
    var compact = false
    var muted = false

    var body: some View {
        let regularSize = typography.projectBadgeSize
        let width = compact ? typography.projectBadgeCompactSize : regularSize.width
        let height = compact ? typography.projectBadgeCompactSize : regularSize.height
        Text(verbatim: project.name.prefix(2).uppercased())
            .zivviFont(.badge, weight: .semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: width, height: height)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        muted ? ZivviTheme.tertiaryText : ZivviTheme.projectTint(id: project.id)
    }
}

private struct SidebarReminderMenu: View {
    let workspace: WorkspaceController
    let sessionID: UUID
    let state: SessionReminderState
    let showsAction: Bool
    @Binding var isPresented: Bool
    let focus: FocusState<SidebarFocus?>.Binding

    var body: some View {
        let presentation = switch state {
        case .none: ("bell", String(localized: "暂缓提醒"))
        case .snoozed(let date): ("bell.slash", SidebarCardIndicator.reminderSnoozed(date).label)
        case .due: ("bell.badge.fill", SidebarCardIndicator.reminderDue.label)
        }
        let visible = showsAction
        return FlatMenu(width: 166, presentation: $isPresented) {
            IconButtonLabel(systemName: presentation.0)
                .foregroundStyle(state == .none ? ZivviTheme.secondaryText : ZivviTheme.warningText)
                .background(state == .none || isPresented ? Color.clear : ZivviTheme.warningSurface,
                            in: .rect(cornerRadius: 5))
        } content: { select in
            SessionReminderMenuActions(workspace: workspace, sessionID: sessionID, state: state, select: select)
        }
        .fixedSize()
        .focused(focus, equals: .remind(sessionID))
        .disabled(!visible || !workspace.initialized || workspace.storageError != nil)
        .revealedAction(visible)
        .accessibilityHidden(!visible)
        .help(presentation.1)
        .accessibilityLabel(presentation.1)
    }
}

struct SessionReminderMenuActions: View {
    let workspace: WorkspaceController
    let sessionID: UUID
    let state: SessionReminderState
    let select: (@escaping () -> Void) -> Void

    var body: some View {
        Button { select { setDeadline(Date.now.addingTimeInterval(3600)) } } label: {
            FlatMenuRow(title: Text("1 小时后"))
        }
        Button {
            select {
                let calendar = Calendar.current
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now),
                   let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
                    setDeadline(morning)
                }
            }
        } label: {
            FlatMenuRow(title: Text("明天 09:00"))
        }
        if state != .none {
            ZivviDivider()
            Button { select { setDeadline(nil) } } label: {
                FlatMenuRow(title: Text(state == .due ? "取消提醒" : "取消暂缓"))
            }
        }
    }

    private func setDeadline(_ deadline: Date?) {
        Task { await workspace.setSessionReminder(sessionID, until: deadline) }
    }
}

private struct SidebarIconButton: View {
    let title: LocalizedStringResource
    let icon: IconButtonLabel
    let action: () -> Void

    init(_ title: LocalizedStringResource, icon: IconButtonLabel, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(ZivviTheme.secondaryText)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
