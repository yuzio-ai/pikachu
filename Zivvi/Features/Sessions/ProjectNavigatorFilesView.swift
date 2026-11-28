import AppKit
import SwiftUI
import OrchestrationCore

/// Git-aware project file tree mounted inside a project's left-sidebar Files mode.
struct ProjectNavigatorFilesView: View {
    let project: ProjectRecord
    @Bindable var model: ProjectFilesModel
    let gitStore: GitStatusStore
    let activeFilePath: ProjectFilePath?
    let searchQuery: String
    let onOpenFile: (ProjectRecord, ProjectFileEntry) -> Void

    @Environment(\.zivviTypography) private var typography

    private var gitSnapshot: GitRepositorySnapshot? {
        let state = gitStore.state(for: project.path)
        guard let snap = state.snapshot,
              snap.directoryPath == GitRepositoryInspector.normalizedPath(project.path) else { return nil }
        return snap
    }

    private var filteredRows: [ProjectFilesModel.TreeRow] {
        let term = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.rows }
        return model.rows.filter { row in
            switch row.content {
            case .entry(let entry):
                return entry.path.name.localizedStandardContains(term) ||
                    entry.path.relativePath.localizedStandardContains(term)
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot = gitSnapshot, snapshot.changes.hasLineStats,
               (snapshot.changes.totalAdditions > 0 || snapshot.changes.totalDeletions > 0) {
                HStack(spacing: 6) {
                    Text("项目文件")
                        .zivviFont(.caption2, weight: .medium)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                    Spacer(minLength: 4)
                    GitInlineStatBadge(added: snapshot.changes.totalAdditions,
                                       deleted: snapshot.changes.totalDeletions,
                                       secondary: true)
                    Button {
                        model.refresh()
                        gitStore.refresh(directory: project.path, force: true)
                    } label: {
                        LightningIconView(.arrowClockwise, size: 12)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                    .help("刷新项目文件与 Git 统计")
                    .accessibilityLabel("刷新项目文件")
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)
            } else {
                HStack(spacing: 6) {
                    Text("项目文件")
                        .zivviFont(.caption2, weight: .medium)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                    Spacer(minLength: 4)
                    Button {
                        model.refresh()
                        gitStore.refresh(directory: project.path, force: true)
                    } label: {
                        LightningIconView(.arrowClockwise, size: 12)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                    .help("刷新项目文件")
                    .accessibilityLabel("刷新项目文件")
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)
            }

            if filteredRows.isEmpty && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有匹配的文件")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredRows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
            }
        }
        .padding(.leading, 4)
        .accessibilityIdentifier("project-files-tree-\(project.id)")
    }

    @ViewBuilder
    private func rowView(_ row: ProjectFilesModel.TreeRow) -> some View {
        switch row.content {
        case .entry(let entry):
            entryRow(entry, depth: row.depth)
        case .loading:
            HStack(spacing: 6) {
                FlatProgressView().controlSize(.mini)
                Text("正在读取…")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.tertiaryText)
            }
            .padding(.leading, indent(for: row.depth) + 18)
            .padding(.vertical, 4)
        case .empty:
            Text("空目录")
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.tertiaryText)
                .padding(.leading, indent(for: row.depth) + 18)
                .padding(.vertical, 4)
        case .failure(let issue):
            Text(verbatim: issue.message)
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.warningText)
                .padding(.leading, indent(for: row.depth) + 18)
                .padding(.vertical, 4)
        case .more:
            Button {
                model.showMore(in: row.path)
            } label: {
                Text("显示更多…")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .padding(.leading, indent(for: row.depth) + 18)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
        }
    }

    private func entryRow(_ entry: ProjectFileEntry, depth: Int) -> some View {
        let isDirectory = entry.kind == .directory
        let isExpanded = isDirectory && model.expanded.contains(entry.path)
        let isSelected = !isDirectory && activeFilePath == entry.path
        let relative = entry.path.relativePath
        let changes = gitSnapshot?.changes
        let fileStatus = isDirectory ? nil : changes?.fileStatuses[relative]
        let stat: GitLineStat? = isDirectory ? changes?.directoryStats[relative] : changes?.fileStats[relative]

        return Button {
            if isDirectory {
                model.toggle(entry.path)
            } else {
                onOpenFile(project, entry)
            }
        } label: {
            HStack(spacing: 5) {
                if isDirectory {
                    FlatDisclosureChevron(expanded: isExpanded)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                if isDirectory {
                    LightningIconView(.folder, size: 13)
                        .frame(width: 14)
                } else {
                    ProjectFileIcon(path: entry.path, kind: entry.kind)
                        .frame(width: 14)
                }
                Text(verbatim: entry.path.name)
                    .zivviFont(.callout, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(fileNameColor(isSelected: isSelected, status: fileStatus))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let stat, stat.hasVisibleChange {
                    GitInlineStatBadge(added: stat.added, deleted: stat.deleted, secondary: isDirectory)
                        .fixedSize()
                }
                if let fileStatus {
                    GitStatusCodeBadge(status: fileStatus)
                        .fixedSize()
                }
            }
            .padding(.leading, indent(for: depth) + 4)
            .padding(.trailing, 8)
            .frame(minHeight: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: isSelected, inset: false, cornerRadius: 6))
        .help(entry.path.relativePath)
        .accessibilityLabel(accessibilityText(entry: entry, status: fileStatus, stat: stat))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            let fullPath = URL(fileURLWithPath: project.path, isDirectory: true)
                .appending(path: entry.path.relativePath).path
            Button("复制相对路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path.relativePath, forType: .string)
            }
            Button("复制完整路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullPath, forType: .string)
            }
            if !isDirectory {
                ZivviDivider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                }
            }
        }
    }

    private func indent(for depth: Int) -> CGFloat {
        CGFloat(max(0, depth)) * 12
    }

    private func fileNameColor(isSelected: Bool, status: GitFileChangeStatus?) -> Color {
        if isSelected { return ZivviTheme.primaryText }
        if status == .conflict { return ZivviTheme.errorText }
        return ZivviTheme.primaryText
    }

    private func accessibilityText(entry: ProjectFileEntry, status: GitFileChangeStatus?, stat: GitLineStat?) -> String {
        var parts = [entry.path.name]
        if entry.kind == .directory {
            parts.append(model.expanded.contains(entry.path) ? String(localized: "已展开") : String(localized: "已折叠"))
        }
        if let status { parts.append(status.localizedName) }
        if let stat, !stat.isBinary {
            if let a = stat.added, a > 0 { parts.append(String(localized: "新增 \(a) 行")) }
            if let d = stat.deleted, d > 0 { parts.append(String(localized: "删除 \(d) 行")) }
        }
        return parts.joined(separator: "，")
    }
}

struct GitInlineStatBadge: View {
    let added: Int?
    let deleted: Int?
    var secondary = false

    var body: some View {
        HStack(spacing: 4) {
            if let added, added > 0 {
                Text(verbatim: "+\(formatCompact(added))")
                    .foregroundStyle(secondary ? ZivviTheme.diffAddition.opacity(0.75) : ZivviTheme.diffAddition)
            }
            if let deleted, deleted > 0 {
                Text(verbatim: "−\(formatCompact(deleted))")
                    .foregroundStyle(secondary ? ZivviTheme.diffDeletion.opacity(0.75) : ZivviTheme.diffDeletion)
            }
        }
        .zivviFont(.caption2, design: .monospaced)
        .monospacedDigit()
    }

    private func formatCompact(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        return "\(value)"
    }
}

struct GitStatusCodeBadge: View {
    let status: GitFileChangeStatus

    var body: some View {
        Text(verbatim: status.badgeText)
            .zivviFont(.caption2, weight: .semibold, design: .monospaced)
            .foregroundStyle(color)
            .frame(minWidth: 12, alignment: .center)
            .accessibilityLabel(status.localizedName)
    }

    private var color: Color {
        switch status {
        case .added, .untracked: ZivviTheme.diffAddition
        case .deleted: ZivviTheme.diffDeletion
        case .conflict: ZivviTheme.errorText
        case .modified, .renamed: ZivviTheme.warningText
        }
    }
}
