import AppKit
import SwiftUI
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
            guard let project = projectsByID[session.projectID] else { return nil }
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
    let openProject: () -> Void
    let createSession: () -> Void
    let openSettings: () -> Void
    @AppStorage("session-sidebar-open-expanded") private var openExpanded = true
    @State private var filteredOpenExpansion: Bool?

    var body: some View {
        let groups = SidebarSessionGroups(sessions: workspace.state.sessions, projects: workspace.state.projects, filter: filter)
        let showsOpen = filter.isActive ? filteredOpenExpansion ?? (groups.count(in: .open) > 0) : openExpanded
        VStack(spacing: 0) {
            SessionSidebarControls(workspace: workspace, filter: $filter, openExpanded: showsOpen,
                                   openProject: openProject, createSession: createSession) {
                if filter.isActive { filteredOpenExpansion = !showsOpen }
                else { openExpanded = !showsOpen }
            }
            SessionSidebarList(workspace: workspace, filter: filter, groups: groups, openExpanded: showsOpen)
            Rectangle().fill(PikachuTheme.subtleDivider).frame(height: 1).accessibilityHidden(true)
            SessionSidebarFooter(workspace: workspace, openSettings: openSettings)
        }
        .foregroundStyle(PikachuTheme.primaryText)
        .background(PikachuTheme.sidebar)
        .onChange(of: filter.isActive) { filteredOpenExpansion = nil }
    }
}

private struct SessionSidebarControls: View {
    let workspace: WorkspaceController
    @Binding var filter: SessionSidebarFilter
    let openExpanded: Bool
    let openProject: () -> Void
    let createSession: () -> Void
    let toggleOpen: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PikachuTheme.secondaryText)
                    .accessibilityHidden(true)
                TextField("搜索会话", text: $filter.query,
                          prompt: Text("搜索会话").foregroundStyle(PikachuTheme.secondaryText))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("search-sessions")
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false))
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .pikachuFont(.callout)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .padding(.vertical, 3)
            .overlay {
                if searchFocused {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(PikachuTheme.focusBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            projectMenu
            SidebarIconButton("添加项目", symbol: "folder.badge.plus", action: openProject)
                .disabled(!workspace.canManageProjects)
                .accessibilityIdentifier("open-project")
            SidebarIconButton("新建会话", symbol: "square.and.pencil", action: createSession)
                .disabled(!workspace.canManageProjects || workspace.state.projects.isEmpty)
                .accessibilityIdentifier("new-session")
        }
        .padding(10)
    }

    private var projectMenu: some View {
        FlatMenu(width: 250) {
            Image(systemName: filter.projectID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(filter.projectID == nil ? PikachuTheme.secondaryText : PikachuTheme.accentText)
                .frame(width: 23, height: 26)
        } content: { select in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    projectFilterRow(Text("全部项目"), projectID: nil, select: select)
                    ForEach(workspace.state.projects) { project in
                        projectFilterRow(Text(verbatim: project.name), projectID: project.id, select: select)
                            .help(project.path)
                    }
                }
            }
            .frame(maxHeight: 330)
            PikachuDivider()
            Button { select(toggleOpen) } label: {
                FlatMenuRow(title: Text(openExpanded ? "收起待处理会话" : "展开待处理会话"))
            }
            .accessibilityIdentifier("toggle-open-sessions")
        }
        .fixedSize()
        .help("侧栏筛选与显示")
        .accessibilityLabel("侧栏筛选与显示")
        .accessibilityValue(workspace.state.projects.first { $0.id == filter.projectID }?.name ?? String(localized: "全部项目"))
        .accessibilityIdentifier("filter-sessions")
    }

    private func projectFilterRow(_ title: Text, projectID: UUID?,
                                  select: @escaping (@escaping () -> Void) -> Void) -> some View {
        let selected = filter.projectID == projectID
        return Button { select { filter.projectID = projectID } } label: {
            FlatMenuRow(title: title, selected: selected)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

private struct SessionSidebarList: View {
    let workspace: WorkspaceController
    let filter: SessionSidebarFilter
    let groups: SidebarSessionGroups
    let openExpanded: Bool
    @AppStorage("session-sidebar-settled-expanded") private var settledExpanded = false
    @State private var filteredSettledExpansion: Bool?
    @State private var batches = SidebarSettledBatches()
    @State private var revealSettled = false
    @State private var appendedFocusID: UUID?
    @FocusState private var focus: SidebarFocus?
    private let listPadding: CGFloat = 10

    var body: some View {
        let selected = workspace.state.selectedSessionID
        let selectedStatus = workspace.selected?.sidebarStatus
        let count = groups.count(in: .settled)
        let expanded = count > 0 && (filter.isActive ? filteredSettledExpansion ?? true : settledExpanded)
        let selectedIndex = groups.settledIndex(of: selected)
        let limit = batches.limit(for: filter, including: expanded ? selectedIndex : nil)
        let openRows = groups.visibleRows(in: .open, expanded: openExpanded, selected: selected)
        let settledRows = groups.visibleRows(in: .settled, expanded: expanded, selected: selected, settledLimit: limit)
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        if !openRows.isEmpty {
                            LazyVStack(spacing: 5) {
                                ForEach(openRows) { row in
                                    SidebarSessionCard(workspace: workspace, session: row.session, project: row.project,
                                                       selected: row.id == selected, focus: $focus)
                                }
                            }
                        }
                        if groups.count(in: .open) + groups.count(in: .settled) == 0 {
                            Text(filter.isActive ? "没有匹配的会话" : "暂无会话")
                                .pikachuFont(.callout)
                                .foregroundStyle(PikachuTheme.secondaryText)
                                .padding(.vertical, 9)
                        }
                        Spacer(minLength: openRows.isEmpty || count == 0 ? 12 : 20)
                        SettledSidebarSection(workspace: workspace, rows: settledRows, selected: selected, count: count,
                                              expanded: expanded, nextCount: SidebarSettledBatches.remainingInNextBatch(total: count, limit: limit),
                                              focus: $focus) {
                            if filter.isActive { filteredSettledExpansion = !expanded }
                            else { settledExpanded = !expanded }
                            if !expanded { revealSettled.toggle() }
                        } showMore: {
                            guard let firstNewID = groups.settledID(at: limit) else { return }
                            let input = NSApp.currentEvent?.type
                            if input == .keyDown || input == .keyUp { appendedFocusID = firstNewID }
                            batches.remember(limit + SidebarSettledBatches.batchSize, for: filter)
                        }
                    }
                    .frame(minHeight: max(0, viewport.size.height - 2 * listPadding))
                    .padding(listPadding)
                }
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .onChange(of: revealSettled) {
                    if selectedIndex != nil, let selected {
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
                    rememberLimit(limit)
                    let target = current.isActive
                        ? groups.newlyMatchingSettledID(selected, previousFilter: previous)
                        : selected
                    if let target { scroll.scrollTo(target) }
                }
                .onChange(of: limit, initial: true) {
                    rememberLimit(limit)
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

private struct SettledSidebarSection: View {
    let workspace: WorkspaceController
    let rows: [SidebarSessionGroups.Row]
    let selected: UUID?
    let count: Int
    let expanded: Bool
    let nextCount: Int
    let focus: FocusState<SidebarFocus?>.Binding
    let toggleExpansion: () -> Void
    let showMore: () -> Void

    var body: some View {
        LazyVStack(spacing: 3) {
            SettledSidebarHeader(count: count, expanded: expanded, toggle: toggleExpansion)
                .id(SessionProcessingStatus.settled)
            ForEach(rows) { row in
                SidebarSessionCard(workspace: workspace, session: row.session, project: row.project,
                                   selected: row.id == selected, focus: focus)
            }
            if expanded && nextCount > 0 {
                Button(action: showMore) {
                    Label("再显示 \(nextCount) 条", systemImage: "chevron.down")
                        .pikachuFont(.callout)
                        .foregroundStyle(PikachuTheme.secondaryText)
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
                Text(LocalizedStringResource("session.group.settled", defaultValue: "已处理",
                                             comment: "Short sidebar heading for settled sessions"))
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Text(count, format: .number).monospacedDigit()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .pikachuFont(.caption2)
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .pikachuFont(.callout)
            .foregroundStyle(PikachuTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .disabled(count == 0)
        .accessibilityLabel("已处理会话")
        .accessibilityValue(expanded ? "已展开，\(count) 个" : "已收起，\(count) 个")
        .accessibilityIdentifier("sessions-settled")
    }
}

enum SidebarSessionStatus: String {
    case running, awaitingApproval, awaitingInput, draft, review, cleaning, retrying, compacting, stopping

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
        }
    }

    var color: Color {
        switch self {
        case .running: PikachuTheme.runningText
        case .awaitingApproval: PikachuTheme.warningText
        default: PikachuTheme.secondaryText
        }
    }

    @MainActor static func resolve(execution: SessionController?, needsReview: Bool, hasDraft: Bool) -> Self? {
        if let execution {
            if execution.connection == .blocked || execution.phase == .uncertain { return .review }
            if execution.connection == .closing { return .cleaning }
            if execution.isStopping { return .stopping }
            if execution.interactions.contains(where: { $0.toolApproval != nil }) { return .awaitingApproval }
            if !execution.interactions.isEmpty { return .awaitingInput }
            if execution.connection == .connected {
                switch execution.phase {
                case .running: return .running
                case .retrying: return .retrying
                case .compacting: return .compacting
                default: break
                }
            }
        }
        if needsReview { return .review }
        return hasDraft ? .draft : nil
    }
}

private struct SidebarSessionCard: View {
    @Environment(\.pikachuTypography) private var typography
    let workspace: WorkspaceController
    let session: SessionReference
    let project: ProjectRecord
    let selected: Bool
    let focus: FocusState<SidebarFocus?>.Binding
    @State private var isHovered = false
    @State private var reminderPresented = false
    private var timeWidth: CGFloat { typography.sidebarTimeWidth }
    private let actionWidth: CGFloat = 24

    private var status: SidebarSessionStatus? {
        SidebarSessionStatus.resolve(execution: workspace.execution(for: session.id),
                                     needsReview: session.submissions.contains(where: \.needsReview),
                                     hasDraft: workspace.hasDraft(session))
    }

    private var showsActions: Bool {
        isHovered || focus.wrappedValue?.sessionID == session.id || reminderPresented
    }

    private func statusLabel(for status: SidebarSessionStatus) -> some View {
        Text(status.label)
            .pikachuFont(.caption2)
            .foregroundStyle(status.color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: 68, alignment: .trailing)
            .fixedSize()
            .accessibilityIdentifier(status == .running ? "session-running" : "session-status-\(status.rawValue)")
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
        return [model.provider, model.name ?? String(localized: "模型未知")].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Group {
            if session.sidebarStatus == .open {
                selectionButton
                    .accessibilityActions {
                        if workspace.initialized && workspace.storageError == nil {
                            Button("暂缓提醒") { reminderPresented = true }
                        }
                        if workspace.settleBlockReason(for: session) == nil {
                            Button("标记已处理") { move(to: .settled) }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            actions
                            if let status {
                                statusLabel(for: status).hidden().allowsHitTesting(false).accessibilityHidden(true)
                            }
                            Color.clear.frame(width: timeWidth, height: 24).allowsHitTesting(false)
                        }
                        .padding(.top, 4).padding(.trailing, 8)
                    }
            } else {
                selectionButton
                    .accessibilityAction(named: Text("移回待处理")) { move(to: .open) }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 7) {
                            Button {
                                move(to: .open)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundStyle(PikachuTheme.tertiaryText)
                                    .frame(width: actionWidth, height: 24)
                            }
                            .buttonStyle(FlatControlButtonStyle(inset: false))
                            .focused(focus, equals: .reopen(session.id))
                            .disabled(!showsActions)
                            .opacity(showsActions ? 1 : 0)
                            .allowsHitTesting(showsActions)
                            .accessibilityHidden(!showsActions)
                            .help("移回待处理")
                            .accessibilityLabel("移回待处理")
                            Color.clear.frame(width: timeWidth, height: 24).allowsHitTesting(false)
                        }
                        .padding(.trailing, 8)
                    }
            }
        }
        .background(cardFill, in: shape)
        .overlay {
            if focus.wrappedValue == .session(session.id) {
                shape.strokeBorder(PikachuTheme.focusBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var cardFill: Color {
        if selected { return PikachuTheme.selected }
        if isHovered { return PikachuTheme.hover }
        return .clear
    }

    private var selectionButton: some View {
        Button {
            DiagnosticMetrics.shared.record("history-select", tag: session.id.uuidString)
            Task { await workspace.select(session.id) }
        } label: {
            Group {
                if session.sidebarStatus == .open {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 5) {
                                    projectBadge
                                    Text(project.name).pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                projectBadge
                            }
                            Spacer(minLength: 0)
                            Color.clear.frame(width: actionWidth * 2 + 3, height: 18)
                            if let status { statusLabel(for: status) }
                            activityTime
                        }
                        .frame(minHeight: 24)
                        HStack(spacing: 5) {
                            Text(session.displayTitle).pikachuFont(.callout, weight: selected ? .semibold : .medium).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ProviderLogo(provider: model.provider ?? "")
                                .foregroundStyle(PikachuTheme.secondaryText)
                                .help(modelHelp)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        projectBadge
                        Text(session.displayTitle).pikachuFont(.callout, weight: selected ? .medium : .regular).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: actionWidth, height: 18)
                        activityTime
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, session.sidebarStatus == .open ? 4 : 3)
            .frame(minHeight: session.sidebarStatus == .settled ? 24 : nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: .session(session.id))
        .help("\(project.name) · \(session.displayTitle)")
        .accessibilityLabel("\(project.name)，\(session.displayTitle)")
        .accessibilityValue(accessibilityDetails)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("session-\(session.id)")
    }

    private var accessibilityDetails: String {
        let time = session.activity.date.formatted(date: .abbreviated, time: .shortened)
        let timeLabel = session.activity.isEstimate ? String(localized: "近似时间，\(time)") : time
        guard session.sidebarStatus == .open else { return timeLabel }
        return [status.map { String(localized: $0.label) }, timeLabel, modelHelp].compactMap { $0 }.joined(separator: String(localized: "，"))
    }

    private var projectBadge: some View {
        ProjectBadge(name: project.name, compact: session.sidebarStatus == .settled)
            .help("\(project.name) · \(project.path)")
    }

    private var activityTime: some View {
        let activity = session.activity
        let date = activity.date
        let format: Date.FormatStyle = Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month().day()
        let fullTime = date.formatted(date: .abbreviated, time: .shortened)
        return Text(date, format: format)
            .pikachuFont(.caption2)
            .foregroundStyle(PikachuTheme.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: timeWidth, alignment: .trailing)
            .help(activity.isEstimate ? String(localized: "近似时间：\(fullTime)") : fullTime)
    }

    private var actions: some View {
        let blocked = workspace.settleBlockReason(for: session)
        return HStack(spacing: 3) {
            SidebarReminderMenu(workspace: workspace, session: session, width: actionWidth, showsAction: showsActions,
                                isPresented: $reminderPresented, focus: focus)
            Button {
                move(to: .settled)
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(PikachuTheme.secondaryText)
                    .frame(width: actionWidth, height: 24)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .focused(focus, equals: .settle(session.id))
            .disabled(blocked != nil || !showsActions)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
            .help(blocked.map { String(localized: $0) } ?? String(localized: "标记已处理"))
            .accessibilityLabel("标记已处理")
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
    @Environment(\.pikachuTypography) private var typography
    let name: String
    var compact = false

    var body: some View {
        let regularSize = typography.projectBadgeSize
        let width = compact ? typography.projectBadgeCompactSize : regularSize.width
        let height = compact ? typography.projectBadgeCompactSize : regularSize.height
        Text(String(name.prefix(2)))
            .pikachuFont(.badge, weight: .semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: width, height: height)
            .foregroundStyle(compact ? PikachuTheme.tertiaryText : PikachuTheme.accentText)
            .background(PikachuTheme.selected, in: .rect(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

private struct SidebarReminderMenu: View {
    let workspace: WorkspaceController
    let session: SessionReference
    let width: CGFloat
    let showsAction: Bool
    @Binding var isPresented: Bool
    let focus: FocusState<SidebarFocus?>.Binding

    var body: some View {
        let now = Date.now
        if case .snoozed(let date) = session.reminderState(at: now) {
            TimelineView(.explicit([now, date])) { menu(for: session.reminderState(at: $0.date)) }
        } else {
            menu(for: session.reminderState(at: now))
        }
    }

    private func menu(for state: SessionReminderState) -> some View {
        let presentation = switch state {
        case .none: ("bell", String(localized: "暂缓提醒"))
        case .snoozed(let date): ("bell.slash", String(localized: "暂缓至 \(date.formatted(date: .abbreviated, time: .shortened))"))
        case .due: ("bell.badge.fill", String(localized: "提醒已到期"))
        }
        let visible = showsAction
        return FlatMenu(width: 166, presentation: $isPresented) {
            Image(systemName: presentation.0)
                .foregroundStyle(state == .none ? PikachuTheme.secondaryText : PikachuTheme.warningText)
                .frame(width: width, height: 24)
                .background(state == .none ? Color.clear : PikachuTheme.warningSurface, in: .rect(cornerRadius: 5))
        } content: { select in
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
                PikachuDivider()
                Button { select { setDeadline(nil) } } label: {
                    FlatMenuRow(title: Text(state == .due ? "取消提醒" : "取消暂缓"))
                }
            }
        }
        .fixedSize()
        .focused(focus, equals: .remind(session.id))
        .disabled(!visible || !workspace.initialized || workspace.storageError != nil)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .help(presentation.1)
        .accessibilityLabel(presentation.1)
        .overlay {
            if !visible && state != .none {
                Circle()
                    .fill(PikachuTheme.warningText)
                    .frame(width: 6, height: 6)
                    .help(presentation.1)
                    .accessibilityLabel(presentation.1)
            }
        }
    }

    private func setDeadline(_ deadline: Date?) {
        Task { await workspace.setSessionReminder(session.id, until: deadline) }
    }
}

private struct SessionSidebarFooter: View {
    let workspace: WorkspaceController
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            SidebarIconButton("设置", symbol: "gearshape", action: openSettings)
            SidebarIconButton("当前会话统计", symbol: "chart.bar") { workspace.usageExpanded.toggle() }
                .disabled(workspace.viewed == nil)
            SidebarIconButton("刷新会话列表", symbol: "arrow.clockwise") {
                Task { await workspace.refreshWorkspaceHistory() }
            }
            .disabled(!workspace.canManageProjects || workspace.state.projects.isEmpty)
            .accessibilityIdentifier("refresh-sessions")
            if workspace.refreshingHistoryIndex { FlatProgressView().controlSize(.mini).accessibilityLabel("正在刷新会话") }
            Spacer(minLength: 0)
            SidebarQuotaButton(windows: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct SidebarIconButton: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void

    init(_ title: LocalizedStringResource, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .pikachuFont(.callout)
                .foregroundStyle(PikachuTheme.secondaryText)
                .frame(width: 25, height: 26)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
