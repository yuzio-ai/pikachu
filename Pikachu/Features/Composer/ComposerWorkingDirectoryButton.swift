import SwiftUI
import OrchestrationCore

struct ComposerWorkingDirectoryButton: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    let project: ProjectRecord
    @Binding var isPresented: Bool
    let panelsBlocked: Bool
    @State private var worktrees: [GitWorktree]?
    @State private var loading = true

    private var path: String { reference.workingDirectory(in: project) }

    private var title: LocalizedStringResource {
        if reference.worktreePath != nil {
            let name = worktrees?.first { $0.path == path }?.branch ?? URL(fileURLWithPath: path).lastPathComponent
            return "工作树 · \(name)"
        }
        return "工作区 · \(project.name)"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: isPresented))
        .frame(maxWidth: 145)
        .help(path)
        .accessibilityLabel("工作区选择器")
        .accessibilityValue(Text(title))
        .accessibilityHint(path)
        .accessibilityIdentifier("composer-working-directory")
        .disabled(panelsBlocked || workspace.isOperating(on: reference.id) || workspace.storageError != nil)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ComposerWorkingDirectoryPanel(
                workspace: workspace, reference: reference, project: project,
                worktrees: worktrees, loading: loading,
                close: { isPresented = false }
            )
        }
        .task(id: DirectoryLookup(project: project.path, worktree: reference.worktreePath, open: isPresented)) {
            guard isPresented || reference.worktreePath != nil else { return }
            loading = true
            let result = await GitRepositoryInspector.worktrees(in: project.path)
            guard !Task.isCancelled else { return }
            worktrees = result
            loading = false
        }
    }

    private struct DirectoryLookup: Equatable {
        let project: String
        let worktree: String?
        let open: Bool
    }
}

private struct ComposerWorkingDirectoryPanel: View {
    let workspace: WorkspaceController
    let reference: SessionReference
    let project: ProjectRecord
    let worktrees: [GitWorktree]?
    let loading: Bool
    let close: () -> Void
    @State private var showsCreation = false
    @State private var base = "HEAD"
    @State private var branch = ""
    @State private var destination = ""
    @State private var applying = false
    @State private var error: String?

    private var currentPath: String { reference.workingDirectory(in: project) }
    private var choices: [GitWorktree] {
        worktrees?.filter { $0.path != project.path } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作区").pikachuFont(.headline)
            if reference.hasBoundWorkingDirectory {
                Text("更换目录将在目标位置新建会话并带上草稿。")
                    .pikachuFont(.caption).foregroundStyle(.secondary)
            }
            if showsCreation {
                creationForm
            } else {
                directories
            }
            if let error {
                Text(error).pikachuFont(.caption).foregroundStyle(PikachuTheme.errorText).textSelection(.enabled)
            }
            if applying { FlatProgressView().controlSize(.small) }
        }
        .lineLimit(nil)
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .flatPanelContent()
        .disabled(applying || workspace.isShuttingDown)
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
    }

    private var directories: some View {
        VStack(alignment: .leading, spacing: 8) {
            let projectBranch = worktrees?.first { $0.path == project.path }?.branch
            directoryButton("项目工作区", path: project.path, branch: projectBranch) { choose(nil) }
            if loading {
                FlatProgressView("正在读取工作树…").controlSize(.small)
            } else if worktrees != nil {
                if !choices.isEmpty {
                    Text("已有工作树").pikachuFont(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(choices) { tree in
                                directoryButton(
                                    tree.branch.map { Text($0) } ?? Text("分离的 HEAD"),
                                    path: tree.path,
                                    branch: tree.branch == nil ? tree.commit.map { String($0.prefix(12)) } : nil
                                ) { choose(tree.path) }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("新建工作树…") {
                    error = nil
                    showsCreation = true
                }
            }
        }
    }

    private func directoryButton(_ title: LocalizedStringKey, path: String, branch: String?, action: @escaping () -> Void) -> some View {
        directoryButton(Text(title), path: path, branch: branch, action: action)
    }

    private func directoryButton(_ title: Text, path: String, branch: String?, action: @escaping () -> Void) -> some View {
        let isSelected = path == currentPath
        return Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    if let branch { Text(branch).pikachuFont(.caption).foregroundStyle(.secondary) }
                    Text(path).pikachuFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                if isSelected {
                    Image(systemName: "checkmark")
                        .pikachuFont(.caption, weight: .semibold)
                        .foregroundStyle(PikachuTheme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, isOpen: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新建工作树").pikachuFont(.subheadline, weight: .medium)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("基准提交")
                    TextField("基准提交", text: $base).labelsHidden()
                        .flatInputSurface()
                }
                GridRow {
                    Text("新分支")
                    TextField("新分支", text: $branch).labelsHidden()
                        .flatInputSurface()
                }
                GridRow {
                    Text("绝对路径")
                    TextField("绝对路径", text: $destination).labelsHidden()
                        .flatInputSurface()
                }
            }
            Text("项目工作区的未提交改动会留在原目录。")
                .pikachuFont(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回") { showsCreation = false; error = nil }
                Spacer()
                Button("创建并选择", action: create)
                    .disabled(base.isEmpty || branch.isEmpty || destination.isEmpty)
            }
        }
    }

    private func choose(_ worktree: String?) {
        error = nil
        applying = true
        Task {
            defer { applying = false }
            if await workspace.chooseWorkingDirectory(worktree: worktree, for: reference.id) {
                close()
            } else {
                error = workspace.presentations[reference.id]?.executionError ?? workspace.storageError
                    ?? String(localized: "暂时无法选择工作区。")
            }
        }
    }

    private func create() {
        error = nil
        applying = true
        let base = base, branch = branch, destination = destination
        Task {
            defer { applying = false }
            do {
                let worktree = try await GitRepositoryInspector.createWorktree(
                    in: project.path, destination: destination, branch: branch, base: base
                )
                let current = workspace.state.sessions.first { $0.id == reference.id }
                if current?.hasBoundWorkingDirectory == reference.hasBoundWorkingDirectory,
                   current?.workingDirectory(in: project) == currentPath,
                   await workspace.chooseWorkingDirectory(worktree: worktree.path, for: reference.id) {
                    close()
                } else {
                    error = String(localized: "工作树已创建于 \(worktree.path)，请重新打开列表选择。")
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
