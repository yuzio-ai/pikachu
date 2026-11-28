import SwiftUI
import OrchestrationCore

/// Project-scoped read-only Git inspector mounted in left-sidebar Git mode.
/// Presents Repository Status, Changes (Staged / Unstaged / Untracked / Conflicts), and Commits.
struct ProjectNavigatorGitView: View {
    let project: ProjectRecord
    let gitStore: GitStatusStore
    let activeDiffPath: String?
    let activeDiffScope: GitDiffScope?
    let activeCommitHash: String?
    let onOpenDiff: (ProjectRecord, GitFileChange, String) -> Void
    let onOpenCommit: (ProjectRecord, GitCommitSummary) -> Void

    @State private var changesExpanded = true
    @State private var commitsExpanded = true

    private var directoryState: GitDirectoryState {
        gitStore.state(for: project.path)
    }

    private var snapshot: GitRepositorySnapshot? {
        guard let snap = directoryState.snapshot,
              snap.directoryPath == GitRepositoryInspector.normalizedPath(project.path) else { return nil }
        return snap
    }

    private var commitsState: GitStatusStore.CommitsState {
        gitStore.commitsState(for: project.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch directoryState {
            case .notRepository(_, let reason, _):
                emptyState(title: "非 Git 仓库", detail: reason)
            case .directoryMissing(_, let reason, _):
                emptyState(title: "目录不可用", detail: reason)
            case .failed(_, let reason, _):
                emptyState(title: "Git 状态读取失败", detail: reason, canRetry: true)
            case .idle, .loading(previous: nil):
                HStack(spacing: 6) {
                    FlatProgressView().controlSize(.mini)
                    Text("正在读取 Git 状态…")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            default:
                if let snapshot {
                    repositoryStatusHeader(snapshot)
                    ZivviDivider(color: ZivviTheme.subtleDivider)
                        .padding(.horizontal, 8)
                    changesSection(snapshot)
                    ZivviDivider(color: ZivviTheme.subtleDivider)
                        .padding(.horizontal, 8)
                    commitsSection
                }
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 6)
        .onAppear {
            if case .idle = directoryState {
                gitStore.refresh(directory: project.path)
            }
            if commitsState.commits.isEmpty && !commitsState.isLoading {
                gitStore.refreshCommits(directory: project.path)
            }
        }
        .accessibilityIdentifier("project-git-view-\(project.id)")
    }

    private func emptyState(title: LocalizedStringKey, detail: String, canRetry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .zivviFont(.callout, weight: .medium)
                .foregroundStyle(ZivviTheme.secondaryText)
            Text(verbatim: detail)
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("重试") {
                    gitStore.refresh(directory: project.path, force: true)
                    gitStore.refreshCommits(directory: project.path)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .zivviFont(.caption)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func repositoryStatusHeader(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                GitBranchIcon()
                Text(verbatim: snapshot.branch.displayName)
                    .zivviFont(.callout, weight: .semibold)
                    .foregroundStyle(ZivviTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                aheadBehindLabel(snapshot)
                Button {
                    gitStore.refresh(directory: project.path, force: true)
                    gitStore.refreshCommits(directory: project.path)
                } label: {
                    if directoryState.isLoading {
                        FlatProgressView().controlSize(.mini).frame(width: 20, height: 20)
                    } else {
                        LightningIconView(.arrowClockwise, size: 12)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .disabled(directoryState.isLoading)
                .help("刷新 Git 状态与提交记录")
                .accessibilityLabel("刷新 Git 状态")
            }

            if let upstream = snapshot.upstream {
                Text(verbatim: upstream)
                    .zivviFont(.caption2)
                    .foregroundStyle(ZivviTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if case .detached = snapshot.branch {
                Text("分离 HEAD")
                    .zivviFont(.caption2)
                    .foregroundStyle(ZivviTheme.warningText)
            } else {
                Text("未配置上游分支")
                    .zivviFont(.caption2)
                    .foregroundStyle(ZivviTheme.tertiaryText)
            }

            HStack(spacing: 6) {
                Text(snapshot.changes.totalCount == 0
                     ? String(localized: "工作区干净")
                     : String(localized: "\(snapshot.changes.totalCount) 个变更文件"))
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if snapshot.changes.hasLineStats,
                   snapshot.changes.totalAdditions > 0 || snapshot.changes.totalDeletions > 0 {
                    GitInlineStatBadge(added: snapshot.changes.totalAdditions,
                                       deleted: snapshot.changes.totalDeletions)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func aheadBehindLabel(_ snapshot: GitRepositorySnapshot) -> some View {
        if case .count(let ahead, _) = snapshot.ahead {
            let behind = snapshot.behindCount
            HStack(spacing: 4) {
                Text(verbatim: "↑\(ahead)")
                    .foregroundStyle(ahead > 0 ? ZivviTheme.primaryText : ZivviTheme.tertiaryText)
                if let behind {
                    Text(verbatim: "↓\(behind)")
                        .foregroundStyle(behind > 0 ? ZivviTheme.warningText : ZivviTheme.tertiaryText)
                }
            }
            .zivviFont(.caption2, design: .monospaced)
            .monospacedDigit()
            .fixedSize()
        }
    }

    private func changesSection(_ snapshot: GitRepositorySnapshot) -> some View {
        let changes = snapshot.changes
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                changesExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    FlatDisclosureChevron(expanded: changesExpanded)
                        .frame(width: 10)
                    Text("变更")
                        .zivviFont(.caption, weight: .semibold)
                        .foregroundStyle(ZivviTheme.secondaryText)
                    Text(verbatim: "\(changes.totalCount)")
                        .zivviFont(.caption2, design: .monospaced)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))

            if changesExpanded {
                if changes.totalCount == 0 {
                    Text("暂无未提交变更")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                } else {
                    if !changes.conflictChanges.isEmpty {
                        changeGroup(title: "冲突", items: changes.conflictChanges, checkoutRoot: snapshot.checkoutRoot)
                    }
                    if !changes.stagedChanges.isEmpty {
                        changeGroup(title: "已暂存", items: changes.stagedChanges, checkoutRoot: snapshot.checkoutRoot)
                    }
                    if !changes.unstagedChanges.isEmpty {
                        changeGroup(title: "未暂存", items: changes.unstagedChanges, checkoutRoot: snapshot.checkoutRoot)
                    }
                    if !changes.untrackedChanges.isEmpty {
                        changeGroup(title: "未跟踪", items: changes.untrackedChanges, checkoutRoot: snapshot.checkoutRoot)
                    }
                }
            }
        }
    }

    private func changeGroup(title: LocalizedStringKey, items: [GitFileChange], checkoutRoot: String) -> some View {
        let duplicateNames = Set(
            Dictionary(grouping: items, by: \.fileName)
                .filter { $0.value.count > 1 }
                .keys
        )
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .zivviFont(.caption2, weight: .medium)
                    .foregroundStyle(ZivviTheme.tertiaryText)
                Text(verbatim: "\(items.count)")
                    .zivviFont(.caption2, design: .monospaced)
                    .foregroundStyle(ZivviTheme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 3)
            .padding(.bottom, 1)

            ForEach(items) { change in
                let isSelected = activeDiffPath == change.path && activeDiffScope == change.scope
                Button {
                    onOpenDiff(project, change, checkoutRoot)
                } label: {
                    HStack(spacing: 5) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: change.fileName)
                                .zivviFont(.callout, weight: isSelected ? .medium : .regular)
                                .foregroundStyle(change.status == .conflict ? ZivviTheme.errorText : ZivviTheme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if duplicateNames.contains(change.fileName), !change.directoryPath.isEmpty {
                                Text(verbatim: change.directoryPath)
                                    .zivviFont(.caption2)
                                    .foregroundStyle(ZivviTheme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 4)
                        if let stat = change.stat, stat.hasVisibleChange {
                            GitInlineStatBadge(added: stat.added, deleted: stat.deleted)
                                .fixedSize()
                        }
                        GitStatusCodeBadge(status: change.status)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: isSelected, inset: false, cornerRadius: 6))
                .help("\(change.path)（\(change.scope.comparisonLabel)）")
                .accessibilityLabel("\(change.fileName)，\(change.status.localizedName)，\(change.scope.comparisonLabel)")
                .accessibilityHint("点击打开 Diff 审查标签页")
            }
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                commitsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    FlatDisclosureChevron(expanded: commitsExpanded)
                        .frame(width: 10)
                    Text("提交历史")
                        .zivviFont(.caption, weight: .semibold)
                        .foregroundStyle(ZivviTheme.secondaryText)
                    if !commitsState.commits.isEmpty {
                        Text(verbatim: "\(commitsState.commits.count)")
                            .zivviFont(.caption2, design: .monospaced)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                    }
                    Spacer(minLength: 4)
                    if commitsState.isLoading {
                        FlatProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))

            if commitsExpanded {
                if commitsState.commits.isEmpty && !commitsState.isLoading {
                    Text("暂无提交记录")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(commitsState.commits.enumerated()), id: \.element.id) { index, commit in
                            commitRow(commit, isLast: index == commitsState.commits.count - 1)
                        }
                        if commitsState.hasMore && !commitsState.commits.isEmpty {
                            Button {
                                gitStore.refreshCommits(directory: project.path, loadMore: true)
                            } label: {
                                Text(commitsState.isLoading ? "正在加载…" : "加载更多提交")
                                    .zivviFont(.caption)
                                    .foregroundStyle(ZivviTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                            .disabled(commitsState.isLoading)
                        }
                    }
                }
            }
        }
    }

    private func commitRow(_ commit: GitCommitSummary, isLast: Bool) -> some View {
        let isSelected = activeCommitHash == commit.hash
        return Button {
            onOpenCommit(project, commit)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                VStack(spacing: 2) {
                    Circle()
                        .fill(isSelected ? ZivviTheme.lightningYellow : ZivviTheme.tertiaryText)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    if !isLast {
                        Rectangle()
                            .fill(ZivviTheme.subtleDivider)
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: commit.subject)
                        .zivviFont(.callout, weight: isSelected ? .medium : .regular)
                        .foregroundStyle(ZivviTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text(verbatim: commit.shortHash)
                            .zivviFont(.caption2, design: .monospaced)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                        Text("·")
                            .zivviFont(.caption2)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                        Text(commit.date, format: .relative(presentation: .named))
                            .zivviFont(.caption2)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let add = commit.additions, let del = commit.deletions, (add > 0 || del > 0) {
                            GitInlineStatBadge(added: add, deleted: del, secondary: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: isSelected, inset: false, cornerRadius: 6))
        .help("\(commit.shortHash) · \(commit.subject)\n\(commit.author)")
        .accessibilityLabel("\(commit.subject)，\(commit.shortHash)")
        .accessibilityHint("点击查看提交详情")
    }
}
