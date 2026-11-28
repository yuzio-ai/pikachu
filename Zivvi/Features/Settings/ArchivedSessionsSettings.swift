import SwiftUI
import OrchestrationCore

struct ArchivedSessionsSettings: View {
    let workspace: WorkspaceController
    let openSession: (UUID) -> Void
    @State private var projectID: UUID?
    @State private var restoreFailed = false

    var body: some View {
        let projects = workspace.state.projects.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        let archived = Dictionary(grouping: workspace.state.sessions.filter { $0.archivedAt != nil }, by: \.projectID)
        let visibleProjects = projects.filter { (projectID == nil || projectID == $0.id) && archived[$0.id] != nil }

        LazyVStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            FlatPanelPicker(title: "按项目筛选", selection: $projectID, options: [nil] + projects.map { Optional($0.id) },
                            maximumMenuHeight: 240) { id in
                if let project = projects.first(where: { $0.id == id }) { Text(verbatim: project.displayName) }
                else { Text("全部项目") }
            }
            .settingsRowInsets()
            .accessibilityIdentifier("archived-sessions-project-filter")

            if let error = workspace.storageError {
                FeedbackBanner(text: error, warning: true)
            } else if restoreFailed {
                FeedbackBanner(text: String(localized: "无法取消归档，请重试。"), warning: true)
            }
            if visibleProjects.isEmpty {
                Text("暂无已归档会话")
                    .settingsDetailLines()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            ForEach(visibleProjects) { project in
                let sessions = (archived[project.id] ?? []).sorted {
                    let left = $0.archivedAt ?? .distantPast
                    let right = $1.archivedAt ?? .distantPast
                    return left == right ? $0.id < $1.id : left > right
                }
                ArchivedProjectGroup(project: project, sessions: sessions, workspace: workspace,
                                     openSession: openSession, restoreSession: restoreSession)
            }
        }
        .onChange(of: workspace.state.projects.map(\.id)) { _, ids in
            if let projectID, !ids.contains(projectID) { self.projectID = nil }
        }
    }

    private func restoreSession(_ id: UUID) {
        restoreFailed = false
        Task { restoreFailed = !(await workspace.setSessionArchived(id, archived: false)) }
    }
}

private struct ArchivedProjectGroup: View {
    let project: ProjectRecord
    let sessions: [SessionReference]
    let workspace: WorkspaceController
    let openSession: (UUID) -> Void
    let restoreSession: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack(spacing: 6) {
                ProjectBadge(project: project, compact: true)
                Text(verbatim: project.displayName)
                    .zivviFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .help(project.path)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sessions) { session in
                    VStack(spacing: 0) {
                        if session.id != sessions.first?.id { SettingsDivider() }
                        ArchivedSessionRow(
                            session: session,
                            restoreDisabled: workspace.isOperating(on: session.id) || workspace.storageError != nil,
                            open: { openSession(session.id) },
                            restore: { restoreSession(session.id) }
                        )
                    }
                }
            }
        }
    }
}

private struct ArchivedSessionRow: View {
    let session: SessionReference
    let restoreDisabled: Bool
    let open: () -> Void
    let restore: () -> Void

    var body: some View {
        SettingsControlRow {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text(verbatim: session.displayTitle)
                    .zivviFont(.body)
                    .lineLimit(2)
                    .help(session.displayTitle)
                if let archivedAt = session.archivedAt {
                    Text(archivedAt, format: .dateTime.year().month().day())
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }
        } control: {
            HStack(spacing: 8) {
                Button("查看会话", action: open)
                    .accessibilityLabel("查看会话 \(session.displayTitle)")
                    .accessibilityIdentifier("view-archived-session-\(session.id)")
                Button("取消归档", action: restore)
                    .disabled(restoreDisabled)
                    .accessibilityLabel("取消归档 \(session.displayTitle)")
                    .accessibilityIdentifier("unarchive-session-\(session.id)")
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
            .fixedSize()
        }
        .settingsRowInsets()
    }
}
