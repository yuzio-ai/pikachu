import SwiftUI
import OrchestrationCore

struct SessionSidebarFilter: Equatable {
    var query = ""
    var projectID: UUID?

    var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { projectID != nil || !searchTerm.isEmpty }

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
        let term = filter.searchTerm
        let matching = sessions.compactMap { session -> Row? in
            guard let project = projectsByID[session.projectID],
                  filter.projectID == nil || filter.projectID == project.id,
                  term.isEmpty || session.title.localizedStandardContains(term) || project.name.localizedStandardContains(term) else { return nil }
            return Row(session: session, project: project)
        }.sorted {
            let left = $0.session.activity.date
            let right = $1.session.activity.date
            return left == right ? $0.id < $1.id : left > right
        }
        rows = Dictionary(grouping: matching) { $0.session.sidebarStatus }
    }

    func count(in status: SessionProcessingStatus) -> Int { rows[status]?.count ?? 0 }

    func visibleRows(in status: SessionProcessingStatus, expanded: Bool, selected: UUID?) -> [Row] {
        let rows = rows[status] ?? []
        if expanded { return rows }
        guard let selected, let row = rows.first(where: { $0.id == selected }) else { return [] }
        return [row]
    }
}

struct SessionSidebar: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    @Binding var filter: SessionSidebarFilter
    let openProject: () -> Void
    let createSession: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionSidebarControls(workspace: workspace, settings: settings, filter: $filter,
                                   openProject: openProject, createSession: createSession)
            Divider().padding(.horizontal, 10)
            SessionSidebarList(workspace: workspace, filter: filter)
            Divider()
            SessionSidebarFooter(workspace: workspace, openSettings: openSettings)
        }
    }
}

private struct SessionSidebarControls: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    @Binding var filter: SessionSidebarFilter
    let openProject: () -> Void
    let createSession: () -> Void
    @State private var projectDetails: ProjectRecord?

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("搜索会话", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("search-sessions")
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .font(.callout)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(.quaternary.opacity(0.38), in: .rect(cornerRadius: 7))
            projectMenu
            SidebarIconButton("新建项目", symbol: "folder.badge.plus", action: openProject)
                .disabled(!workspace.canManageProjects)
                .accessibilityIdentifier("open-project")
            SidebarIconButton("新建会话", symbol: "square.and.pencil", action: createSession)
                .disabled(!workspace.canManageProjects || workspace.state.projects.isEmpty)
                .accessibilityIdentifier("new-session")
        }
        .padding(10)
    }

    private var projectMenu: some View {
        Menu {
            Picker("筛选项目", selection: $filter.projectID) {
                Text("全部项目").tag(nil as UUID?)
                ForEach(workspace.state.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
            if !workspace.state.projects.isEmpty {
                Divider()
                Menu("项目操作") {
                    ForEach(workspace.state.projects) { project in
                        Menu(project.name) {
                            Button("项目详情…") { projectDetails = project }
                            Button("刷新会话") { Task { await workspace.discover(project.id) } }
                                .disabled(!workspace.canManageProjects)
                            Button("重新定位项目…") {
                                if let url = settings.pickProject() {
                                    Task { await workspace.relocateProject(project.id, to: url) }
                                }
                            }
                            .disabled(!workspace.canManageProjects)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filter.projectID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(filter.projectID == nil ? Color.secondary : Color.accentColor)
                .frame(width: 23, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选项目")
        .accessibilityLabel("筛选项目")
        .accessibilityValue(workspace.state.projects.first { $0.id == filter.projectID }?.name ?? String(localized: "全部项目"))
        .accessibilityIdentifier("filter-sessions")
        .popover(item: $projectDetails) { ProjectLocationView(project: $0) }
    }
}

private struct SessionSidebarList: View {
    let workspace: WorkspaceController
    let filter: SessionSidebarFilter
    @AppStorage("session-sidebar-open-expanded") private var openExpanded = true
    @AppStorage("session-sidebar-settled-expanded") private var settledExpanded = false
    @State private var searchExpansion: [SessionProcessingStatus: Bool] = [:]
    @FocusState private var focusedSession: UUID?

    var body: some View {
        let groups = SidebarSessionGroups(sessions: workspace.state.sessions, projects: workspace.state.projects, filter: filter)
        let selected = workspace.state.selectedSessionID
        let selectedStatus = workspace.selected?.sidebarStatus
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(SessionProcessingStatus.allCases, id: \.self) { status in
                        let count = groups.count(in: status)
                        let expanded = isExpanded(status, count: count)
                        SidebarGroupHeader(status: status, count: count, expanded: expanded) {
                            setExpanded(!expanded, status: status)
                        }
                        ForEach(groups.visibleRows(in: status, expanded: expanded, selected: selected)) { row in
                            SidebarSessionCard(workspace: workspace, session: row.session, project: row.project,
                                               selected: row.id == selected, focus: $focusedSession)
                        }
                    }
                    if groups.count(in: .open) + groups.count(in: .settled) == 0 {
                        Text(filter.isActive ? "没有匹配的会话" : "暂无会话")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 9)
                    }
                }
                .padding(10)
            }
            .onChange(of: selected, initial: true) { _, id in
                if let id { scroll.scrollTo(id) }
            }
            .onChange(of: selectedStatus) {
                if let selected { scroll.scrollTo(selected) }
            }
            .onChange(of: filter.isActive) {
                searchExpansion.removeAll()
                if !filter.isActive, let selected { scroll.scrollTo(selected) }
            }
        }
    }

    private func isExpanded(_ status: SessionProcessingStatus, count: Int) -> Bool {
        if filter.isActive { return searchExpansion[status] ?? (count > 0) }
        return status == .open ? openExpanded : settledExpanded
    }

    private func setExpanded(_ value: Bool, status: SessionProcessingStatus) {
        if filter.isActive { searchExpansion[status] = value }
        else if status == .open { openExpanded = value }
        else { settledExpanded = value }
    }
}

private struct SidebarGroupHeader: View {
    let status: SessionProcessingStatus
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(status == .open ? "Open" : "Settled").fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, status == .settled ? 6 : 0)
        .accessibilityLabel(status == .open ? "Open 会话" : "Settled 会话")
        .accessibilityValue(expanded ? "已展开，\(count) 个" : "已收起，\(count) 个")
        .accessibilityIdentifier("sessions-\(status.rawValue)")
    }
}

private struct SidebarSessionCard: View {
    let workspace: WorkspaceController
    let session: SessionReference
    let project: ProjectRecord
    let selected: Bool
    let focus: FocusState<UUID?>.Binding
    private let timeWidth: CGFloat = 42
    private let actionWidth: CGFloat = 24

    private var status: LocalizedStringResource? {
        if session.id == workspace.activeID, let active = workspace.active {
            if active.connection == .blocked || active.phase == .uncertain { return "待核对" }
            if active.connection == .closing { return "清理中" }
            if !active.interactions.isEmpty { return "待输入" }
            if active.connection == .connected {
                switch active.phase {
                case .running: return "运行中"
                case .retrying: return "重试中"
                case .compacting: return "压缩中"
                case .stopping: return "停止中"
                default: break
                }
            }
        }
        if session.submissions.contains(where: \.needsReview) { return "待核对" }
        return workspace.hasDraft(session) ? "有草稿" : nil
    }

    private var isRunning: Bool {
        session.id == workspace.activeID && workspace.active?.connection == .connected && workspace.active?.phase == .running
    }

    private var model: (provider: String?, name: String?) {
        if session.id == workspace.activeID, let active = workspace.active, active.connection == .connected {
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
        Group {
            if session.sidebarStatus == .open {
                selectionButton
                    .overlay(alignment: .topTrailing) { actions.padding(.top, 4).padding(.trailing, timeWidth + 12) }
            } else {
                selectionButton
                    .contextMenu { Button("移回 Open") { move(to: .open) } }
                    .accessibilityAction(named: Text("移回 Open")) { move(to: .open) }
            }
        }
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.65) : .secondary.opacity(session.sidebarStatus == .open ? 0.18 : 0))
                .allowsHitTesting(false)
        }
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
                                    Text(project.name).font(.caption).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                projectBadge
                            }
                            Spacer(minLength: 0)
                            Color.clear.frame(width: actionWidth * 2 + 3, height: 18)
                            activityTime
                        }
                        .frame(minHeight: 24)
                        HStack(spacing: 5) {
                            if isRunning {
                                Circle().fill(.green).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            Text(session.title).font(.callout.weight(.medium)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let status {
                                Text(status).font(.caption2).foregroundStyle(isRunning ? Color.green : Color.secondary)
                                    .fixedSize()
                            }
                            ProviderLogo(provider: model.provider ?? "")
                                .help(modelHelp)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        projectBadge
                        Text(session.title).font(.callout).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        activityTime
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, session.sidebarStatus == .open ? 4 : 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: session.id)
        .help("\(project.name) · \(session.title)")
        .accessibilityLabel("\(project.name)，\(session.title)")
        .accessibilityValue(accessibilityDetails)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("session-\(session.id)")
    }

    private var accessibilityDetails: String {
        let time = session.activity.date.formatted(date: .abbreviated, time: .shortened)
        let timeLabel = session.activity.isEstimate ? String(localized: "近似时间，\(time)") : time
        guard session.sidebarStatus == .open else { return timeLabel }
        return [status.map { String(localized: $0) }, timeLabel, modelHelp].compactMap { $0 }.joined(separator: "，")
    }

    private var projectBadge: some View {
        Text(String(project.name.prefix(2)))
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: 21, height: 19)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 4))
            .help("\(project.name) · \(project.path)")
    }

    private var activityTime: some View {
        let activity = session.activity
        let date = activity.date
        let format: Date.FormatStyle = Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month().day()
        let fullTime = date.formatted(date: .abbreviated, time: .shortened)
        return Text(date, format: format)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: timeWidth, alignment: .trailing)
            .help(activity.isEstimate ? "近似时间：\(fullTime)" : fullTime)
    }

    private var actions: some View {
        let blocked = workspace.settleBlockReason(for: session)
        return HStack(spacing: 3) {
            SidebarReminderMenu(workspace: workspace, session: session, width: actionWidth)
            Button {
                move(to: .settled)
            } label: {
                Image(systemName: "checkmark.circle").frame(width: actionWidth, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(blocked != nil)
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
            if workspace.state.selectedSessionID == session.id { focus.wrappedValue = session.id }
        }
    }
}

private struct SidebarReminderMenu: View {
    let workspace: WorkspaceController
    let session: SessionReference
    let width: CGFloat

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
        return Menu {
            Button("1 小时后") { setDeadline(Date.now.addingTimeInterval(3600)) }
            Button("明天 09:00") {
                let calendar = Calendar.current
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now),
                   let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
                    setDeadline(morning)
                }
            }
            if state != .none {
                Divider()
                Button(state == .due ? "取消提醒" : "取消暂缓") { setDeadline(nil) }
            }
        } label: {
            Image(systemName: presentation.0)
                .foregroundStyle(state == .none ? Color.secondary : Color.orange)
                .frame(width: width, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!workspace.initialized || workspace.storageError != nil)
        .help(presentation.1)
        .accessibilityLabel(presentation.1)
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
            if workspace.refreshingHistoryIndex { ProgressView().controlSize(.mini).accessibilityLabel("正在刷新会话") }
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
            Image(systemName: symbol).frame(width: 23, height: 26)
        }
        .buttonStyle(.borderless)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
