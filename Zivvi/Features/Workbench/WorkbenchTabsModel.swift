import CoreGraphics
import Foundation
import Observation
import AgentRuntimeCore
import OrchestrationCore

/// Manages Dual Tab Groups (Conversation Tabs + Editor Tabs) in a single workbench window.
/// Supports cross-project coexistence without mutating the active session's working directory.
@MainActor
@Observable
final class WorkbenchTabsModel {
    enum EditorTabKind: Equatable, Hashable, Sendable {
        case file(projectID: UUID, rootPath: String, projectName: String, path: ProjectFilePath, kind: ProjectFileEntry.Kind)
        case gitDiff(projectID: UUID, rootPath: String, projectName: String, path: String, previousPath: String?, scope: GitDiffScope, status: GitFileChangeStatus?)
        case toolDiff(id: String, projectName: String?, title: String)
        case commit(projectID: UUID, rootPath: String, projectName: String, hash: String, shortHash: String, subject: String)

        var deduplicationID: String {
            switch self {
            case .file(_, let rootPath, _, let path, _):
                "file:\(rootPath):\(path.relativePath)"
            case .gitDiff(let projectID, let rootPath, _, let path, _, let scope, _):
                "diff:\(projectID):\(rootPath):\(scope.rawValue):\(path)"
            case .toolDiff(let id, _, _):
                "tool-diff:\(id)"
            case .commit(_, let rootPath, _, let hash, _, _):
                "commit:\(rootPath):\(hash)"
            }
        }

        var projectID: UUID? {
            switch self {
            case .file(let id, _, _, _, _), .gitDiff(let id, _, _, _, _, _, _), .commit(let id, _, _, _, _, _): id
            case .toolDiff: nil
            }
        }

        var rootPath: String? {
            switch self {
            case .file(_, let root, _, _, _), .gitDiff(_, let root, _, _, _, _, _), .commit(_, let root, _, _, _, _): root
            case .toolDiff: nil
            }
        }

        var projectName: String? {
            switch self {
            case .file(_, _, let name, _, _), .gitDiff(_, _, let name, _, _, _, _), .commit(_, _, let name, _, _, _): name
            case .toolDiff(_, let name, _): name
            }
        }

        var baseTitle: String {
            switch self {
            case .file(_, _, _, let path, _):
                path.name
            case .gitDiff(_, _, _, let path, _, _, _):
                (path as NSString).lastPathComponent
            case .toolDiff(_, _, let title):
                title
            case .commit(_, _, _, _, let shortHash, _):
                shortHash
            }
        }

        var isMarkdownFile: Bool {
            guard case .file(_, _, _, let path, _) = self else { return false }
            let ext = (path.name as NSString).pathExtension.lowercased()
            return ["md", "markdown", "mdown", "mkd"].contains(ext)
        }

        var isImageFile: Bool {
            guard case .file(_, _, _, let path, _) = self else { return false }
            let ext = (path.name as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext)
        }

        var defaultsToLineWrap: Bool {
            guard case .file(_, _, _, let path, _) = self else { return false }
            let ext = (path.name as NSString).pathExtension.lowercased()
            return ext.isEmpty || ["md", "markdown", "mdown", "mkd", "txt", "log", "rtf"].contains(ext)
        }
    }

    enum FileContentState {
        case loading
        case text(ProjectFileDocument)
        case image(CGImage)
        case failure(ProjectFileIssue)
    }

    private enum LoadedFile {
        case preview(ProjectFilePreview)
        case image(CGImage, ProjectFilesReader.OpenTarget)

        var openTarget: ProjectFilesReader.OpenTarget {
            switch self {
            case .preview(let preview): preview.openTarget
            case .image(_, let target): target
            }
        }
    }

    struct ExternalConflict {
        let message: String
        let diskDocument: ProjectFileDocument?
        let diskRevision: ProjectFileRevision?
    }

    @MainActor
    @Observable
    final class EditorTab: Identifiable {
        let id: String
        fileprivate(set) var kind: EditorTabKind
        var isMarkdownPreview: Bool
        var wrapsLines: Bool
        var contentState: FileContentState = .loading
        var savedDocument: ProjectFileDocument?
        var savedRevision: ProjectFileRevision?
        var draftText: String?
        var openTarget: ProjectFilesReader.OpenTarget?
        var externalConflict: ExternalConflict?
        var saveError: String?
        var isSaving = false
        var targetLine: ProjectFileLineTarget?

        var diffDocument: GitDiffDocument?
        var isLoadingDiff = false
        fileprivate var toolDiffSummary: (() -> TranscriptToolSummary?)?

        private var toolEdit: RuntimeTool.EditArguments? {
            guard let summary = toolDiffSummary?(),
                  case .edit(let edit) = ToolCallPresentation(summary).parameters else { return nil }
            return edit
        }

        var toolDiff: (path: String, lines: [ToolEditDiff.Line])? {
            guard let edit = toolEdit else { return nil }
            let lines = ToolEditDiff.preview(for: edit)
            return lines.isEmpty ? nil : (edit.path, lines)
        }

        var toolDiffPath: String? { toolEdit?.path }
        var baseTitle: String {
            toolDiffPath.map { ($0 as NSString).lastPathComponent } ?? kind.baseTitle
        }

        var commitDetail: GitCommitDetail?
        var isLoadingCommit = false

        var isDirty: Bool {
            guard let draftText, let savedDocument else { return false }
            return !draftText.utf16.elementsEqual(savedDocument.text.utf16)
        }

        var currentEditableDocument: ProjectFileDocument? {
            if let draftText { return ProjectFileDocument(draftText) }
            return savedDocument
        }

        var currentText: String? {
            draftText ?? savedDocument?.text
        }

        init(kind: EditorTabKind, preferSource: Bool = false) {
            self.id = kind.deduplicationID
            self.kind = kind
            self.isMarkdownPreview = kind.isMarkdownFile && !preferSource
            self.wrapsLines = kind.defaultsToLineWrap
        }
    }

    private let reader: any ProjectFilesReading
    @ObservationIgnored private var boundRoots: [String: ProjectFilesReader.Root] = [:]
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var linkedFileRequestID: UUID?
    @ObservationIgnored private var externalOpenRequestID: UUID?

    // MARK: - Conversation Tabs
    private(set) var conversationTabs: [UUID] = []
    private(set) var activeConversationID: UUID?

    // MARK: - Editor Tabs
    private(set) var editorTabs: [EditorTab] = []
    private(set) var activeEditorTabID: String? {
        didSet { if activeEditorTabID != oldValue { invalidateFileOpenRequests() } }
    }
    var isEditorVisible: Bool = false {
        didSet { if !isEditorVisible { invalidateFileOpenRequests() } }
    }
    var isPreparingToTerminate = false {
        didSet { if isPreparingToTerminate { invalidateFileOpenRequests() } }
    }

    var hasUnsavedFileEdits: Bool { editorTabs.contains(where: \.isDirty) }
    var isSavingFile: Bool { editorTabs.contains(where: \.isSaving) }

    init(reader: any ProjectFilesReading = ProjectFilesReader()) {
        self.reader = reader
    }

    var activeEditorTab: EditorTab? {
        guard let activeEditorTabID else { return nil }
        return editorTabs.first { $0.id == activeEditorTabID }
    }

    // MARK: - Conversation Tab Actions

    func syncActiveConversation(_ sessionID: UUID?) {
        activeConversationID = sessionID
        if let sessionID, !conversationTabs.contains(sessionID) {
            conversationTabs.append(sessionID)
        }
    }

    func openConversation(_ sessionID: UUID) {
        if !conversationTabs.contains(sessionID) {
            conversationTabs.append(sessionID)
        }
        activeConversationID = sessionID
    }

    @discardableResult
    func closeConversation(_ sessionID: UUID) -> UUID? {
        guard let index = conversationTabs.firstIndex(of: sessionID) else { return activeConversationID }
        conversationTabs.remove(at: index)
        if activeConversationID == sessionID {
            let next: UUID? = if conversationTabs.indices.contains(index) {
                conversationTabs[index]
            } else {
                conversationTabs.last
            }
            activeConversationID = next
            return next
        }
        return activeConversationID
    }

    func moveConversation(draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let fromIndex = conversationTabs.firstIndex(of: draggedID),
              let toIndex = conversationTabs.firstIndex(of: targetID) else { return }
        let moved = conversationTabs.remove(at: fromIndex)
        conversationTabs.insert(moved, at: toIndex)
    }

    func pruneConversations(validIDs: Set<UUID>) {
        conversationTabs.removeAll { !validIDs.contains($0) }
        if let active = activeConversationID, !validIDs.contains(active) {
            activeConversationID = conversationTabs.last
        }
    }

    // MARK: - Editor Tab Actions

    func openFile(project: ProjectRecord, entry: ProjectFileEntry, line: Int? = nil) {
        openFile(projectID: project.id, rootPath: project.path, projectName: project.displayName,
                 path: entry.path, kind: entry.kind, line: line)
    }

    func openFile(projectID: UUID, rootPath: String, projectName: String,
                  path: ProjectFilePath, kind: ProjectFileEntry.Kind = .file, line: Int? = nil) {
        openFile(projectID: projectID, rootPath: rootPath, projectName: projectName,
                 path: path, kind: kind, line: line, loaded: nil)
    }

    private func openFile(projectID: UUID, rootPath: String, projectName: String,
                          path: ProjectFilePath, kind: ProjectFileEntry.Kind, line: Int?, loaded: LoadedFile?) {
        let tabKind = EditorTabKind.file(projectID: projectID, rootPath: rootPath, projectName: projectName, path: path, kind: kind)
        let id = tabKind.deduplicationID
        if let existing = editorTabs.first(where: { $0.id == id }) {
            if let line {
                existing.isMarkdownPreview = false
                existing.targetLine = ProjectFileLineTarget(line: line)
            }
            activeEditorTabID = existing.id
            isEditorVisible = true
            if let loaded, !existing.isSaving {
                loadTasks.removeValue(forKey: existing.id)?.cancel()
                applyLoadedFile(loaded, to: existing)
            }
            return
        }
        let tab = EditorTab(kind: tabKind, preferSource: line != nil)
        if let line {
            tab.targetLine = ProjectFileLineTarget(line: line)
        }
        editorTabs.append(tab)
        activeEditorTabID = tab.id
        isEditorVisible = true
        if let loaded { applyLoadedFile(loaded, to: tab) }
        else { reloadTab(tab) }
    }

    func beginLinkedFileOpen(canOpen: @escaping @MainActor () -> Bool) -> @MainActor () -> Bool {
        invalidateFileOpenRequests()
        let request = UUID()
        linkedFileRequestID = request
        return { [weak self] in
            guard let self else { return false }
            return linkedFileRequestID == request && canOpen() && !Task.isCancelled && !isPreparingToTerminate
        }
    }

    enum LinkedFileOpenOutcome: Equatable {
        case opened, cancelled
        case unavailable(ProjectFileIssue)
    }

    func openLinkedFile(project: ProjectRecord, rootPath: String, path: ProjectFilePath, line: Int? = nil,
                        isCurrent: @MainActor () -> Bool) async -> LinkedFileOpenOutcome {
        guard isCurrent() else { return .cancelled }
        let tabKind = EditorTabKind.file(projectID: project.id, rootPath: rootPath, projectName: project.displayName,
                                        path: path, kind: .file)
        do {
            let loaded = try await loadFile(rootPath: rootPath, path: path, isImage: tabKind.isImageFile)
            if case .preview(let preview) = loaded { _ = try preview.contents.get() }
            try await reader.validateOpenTarget(loaded.openTarget)
            guard isCurrent() else { return .cancelled }
            openFile(projectID: project.id, rootPath: rootPath, projectName: project.displayName,
                     path: path, kind: .file, line: line, loaded: loaded)
            return .opened
        } catch is CancellationError {
            return .cancelled
        } catch {
            if error as? ProjectFileIssue == .rootUnavailable { boundRoots.removeValue(forKey: rootPath) }
            return isCurrent() ? .unavailable(error as? ProjectFileIssue ?? .unreadable) : .cancelled
        }
    }

    func openGitDiff(project: ProjectRecord, change: GitFileChange, checkoutRoot: String) {
        let tabKind = EditorTabKind.gitDiff(
            projectID: project.id,
            rootPath: checkoutRoot,
            projectName: project.displayName,
            path: change.path,
            previousPath: change.previousPath,
            scope: change.scope,
            status: change.status
        )
        let id = tabKind.deduplicationID
        if let existing = editorTabs.first(where: { $0.id == id }) {
            existing.kind = tabKind
            activeEditorTabID = existing.id
            isEditorVisible = true
            reloadTab(existing)
            return
        }
        let tab = EditorTab(kind: tabKind)
        editorTabs.append(tab)
        activeEditorTabID = tab.id
        isEditorVisible = true
        reloadTab(tab)
    }

    func openToolDiff(_ item: TranscriptItem, sessionID: UUID, projectName: String?, title: String,
                      currentSummary: @escaping () -> TranscriptToolSummary?) {
        guard let summary = currentSummary(),
              case .edit(let edit) = ToolCallPresentation(summary).parameters,
              !ToolEditDiff.preview(for: edit).isEmpty else { return }
        let segmentID = item.sourceSegmentID ?? sessionID
        let tabKind = EditorTabKind.toolDiff(id: "\(sessionID):\(segmentID):\(item.timelineID)", projectName: projectName,
                                             title: title)
        let key = tabKind.deduplicationID
        if let existing = editorTabs.first(where: { $0.id == key }) {
            existing.kind = tabKind
            existing.toolDiffSummary = currentSummary
            activeEditorTabID = existing.id
            isEditorVisible = true
            return
        }
        let tab = EditorTab(kind: tabKind)
        tab.toolDiffSummary = currentSummary
        editorTabs.append(tab)
        activeEditorTabID = tab.id
        isEditorVisible = true
    }

    func openCommit(project: ProjectRecord, commit: GitCommitSummary) {
        let tabKind = EditorTabKind.commit(
            projectID: project.id,
            rootPath: project.path,
            projectName: project.displayName,
            hash: commit.hash,
            shortHash: commit.shortHash,
            subject: commit.subject
        )
        let id = tabKind.deduplicationID
        if let existing = editorTabs.first(where: { $0.id == id }) {
            activeEditorTabID = existing.id
            isEditorVisible = true
            return
        }
        let tab = EditorTab(kind: tabKind)
        editorTabs.append(tab)
        activeEditorTabID = tab.id
        isEditorVisible = true
        reloadTab(tab)
    }

    func activateEditorTab(_ id: String) {
        guard editorTabs.contains(where: { $0.id == id }) else { return }
        activeEditorTabID = id
        isEditorVisible = true
    }

    func moveEditorTab(draggedID: String, before targetID: String) {
        guard draggedID != targetID,
              let fromIndex = editorTabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = editorTabs.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = editorTabs.remove(at: fromIndex)
        editorTabs.insert(moved, at: toIndex)
    }

    func forceCloseEditorTab(_ id: String) {
        guard let index = editorTabs.firstIndex(where: { $0.id == id }) else { return }
        loadTasks.removeValue(forKey: id)?.cancel()
        editorTabs.remove(at: index)
        if activeEditorTabID == id {
            activeEditorTabID = editorTabs.indices.contains(index) ? editorTabs[index].id : editorTabs.last?.id
        }
        if editorTabs.isEmpty {
            isEditorVisible = false
        }
    }

    func toggleEditorArea() {
        isEditorVisible.toggle()
        if isEditorVisible, activeEditorTabID == nil {
            activeEditorTabID = editorTabs.first?.id
        }
    }

    func displayTitle(for tab: EditorTab) -> String {
        let base = tab.baseTitle
        let duplicates = editorTabs.filter { $0.baseTitle == base }
        guard duplicates.count > 1 else { return base }
        switch tab.kind {
        case .file(_, _, let projectName, let path, _):
            let parent = path.parent.name
            if !parent.isEmpty {
                let candidate = "\(parent)/\(base)"
                let sameParent = duplicates.filter {
                    if case .file(_, _, _, let p, _) = $0.kind { return p.parent.name == parent }
                    return false
                }
                if sameParent.count == 1 { return candidate }
            }
            return "\(projectName) · \(base)"
        case .gitDiff(_, _, let projectName, _, _, let scope, _):
            return "\(base) (\(projectName) · \(scope.comparisonLabel))"
        case .toolDiff:
            return "\(base) (历史变更)"
        case .commit(_, _, let projectName, _, let shortHash, _):
            return "\(projectName) · \(shortHash)"
        }
    }

    // MARK: - Loading, Editing, Saving & Conflict Protection

    func reloadTab(_ tab: EditorTab, discardDraft: Bool = false) {
        guard !tab.isSaving, !discardDraft || !isPreparingToTerminate else { return }
        loadTasks[tab.id]?.cancel()
        switch tab.kind {
        case .file(_, let rootPath, _, let path, _):
            tab.openTarget = nil
            if discardDraft {
                tab.draftText = nil
                tab.externalConflict = nil
                tab.saveError = nil
            }
            if tab.savedDocument == nil { tab.contentState = .loading }
            loadTasks[tab.id] = Task { [weak self] in
                await self?.loadFileTab(tab, rootPath: rootPath, path: path)
            }
        case .gitDiff(let projectID, let rootPath, let projectName, let path, _, let scope, _):
            tab.isLoadingDiff = true
            loadTasks[tab.id] = Task { [weak self] in
                let doc = await GitRepositoryInspector.fileDiff(path: path, scope: scope, in: rootPath)
                guard !Task.isCancelled, self != nil else { return }
                if doc.errorMessage == nil {
                    tab.kind = .gitDiff(projectID: projectID, rootPath: rootPath, projectName: projectName,
                                       path: path, previousPath: doc.previousPath, scope: scope, status: doc.status)
                }
                tab.diffDocument = doc
                tab.isLoadingDiff = false
            }
        case .commit(_, let rootPath, _, let hash, _, _):
            tab.isLoadingCommit = true
            loadTasks[tab.id] = Task { [weak self] in
                let detail = await GitRepositoryInspector.commitDetail(hash: hash, in: rootPath)
                guard !Task.isCancelled, self != nil else { return }
                tab.commitDetail = detail
                tab.isLoadingCommit = false
            }
        case .toolDiff:
            break
        }
    }

    private func loadFile(rootPath: String, path: ProjectFilePath, isImage: Bool) async throws -> LoadedFile {
        let root = try await resolveBoundRoot(for: rootPath)
        try Task.checkCancellation()
        let preview = try await reader.read(at: root, path: path)
        guard isImage else { return .preview(preview) }
        let image = try await reader.readMarkdownImage(at: root, path: path)
        try await reader.validateOpenTarget(preview.openTarget)
        return .image(image, preview.openTarget)
    }

    private func loadFileTab(_ tab: EditorTab, rootPath: String, path: ProjectFilePath) async {
        do {
            let loaded = try await loadFile(rootPath: rootPath, path: path, isImage: tab.kind.isImageFile)
            try Task.checkCancellation()
            applyLoadedFile(loaded, to: tab)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let issue = error as? ProjectFileIssue ?? .unreadable
            if issue == .rootUnavailable { boundRoots.removeValue(forKey: rootPath) }
            recordFileLoadFailure(issue, for: tab)
        }
    }

    private func applyLoadedFile(_ loaded: LoadedFile, to tab: EditorTab) {
        switch loaded {
        case .image(let image, let target):
            tab.openTarget = target
            tab.contentState = .image(image)
            tab.savedDocument = nil
            tab.savedRevision = nil
            tab.externalConflict = nil
        case .preview(let preview):
            switch preview.contents {
            case .success(let doc):
                if tab.isDirty, let saved = tab.savedDocument {
                    tab.contentState = .text(saved)
                    if tab.savedRevision != preview.revision {
                        tab.openTarget = nil
                        tab.externalConflict = ExternalConflict(
                            message: String(localized: "磁盘上的文件已被外部（如 Agent）修改，当前保留了你的未保存编辑。"),
                            diskDocument: doc,
                            diskRevision: preview.revision
                        )
                    } else {
                        tab.openTarget = preview.openTarget
                        tab.externalConflict = nil
                    }
                } else {
                    tab.openTarget = preview.openTarget
                    tab.savedDocument = doc
                    tab.savedRevision = preview.revision
                    tab.draftText = nil
                    tab.externalConflict = nil
                    tab.contentState = .text(doc)
                }
            case .failure(let issue):
                recordFileLoadFailure(issue, for: tab, openTarget: preview.openTarget)
            }
        }
    }

    private func recordFileLoadFailure(_ issue: ProjectFileIssue, for tab: EditorTab,
                                       openTarget: ProjectFilesReader.OpenTarget? = nil) {
        if tab.isDirty, let saved = tab.savedDocument {
            tab.openTarget = nil
            tab.contentState = .text(saved)
            tab.externalConflict = ExternalConflict(message: issue.message, diskDocument: nil, diskRevision: nil)
        } else {
            tab.openTarget = openTarget
            tab.savedDocument = nil
            tab.savedRevision = nil
            tab.externalConflict = nil
            tab.contentState = .failure(issue)
        }
    }

    func updateDraft(_ text: String, for tab: EditorTab) {
        guard !isPreparingToTerminate else { return }
        tab.saveError = nil
        if let saved = tab.savedDocument, text.utf16.elementsEqual(saved.text.utf16) {
            tab.draftText = nil
        } else {
            tab.draftText = text
        }
    }

    @discardableResult
    func saveTab(_ tab: EditorTab, overwriteRevision: ProjectFileRevision? = nil,
                 onSaved: (() -> Void)? = nil) async -> Bool {
        guard case .file(_, let rootPath, _, let path, _) = tab.kind,
              let content = tab.currentText, let revision = overwriteRevision ?? tab.savedRevision,
              !tab.isSaving, !isPreparingToTerminate else { return false }
        loadTasks.removeValue(forKey: tab.id)?.cancel()
        tab.isSaving = true
        tab.saveError = nil
        defer { tab.isSaving = false }
        do {
            let root = try await resolveBoundRoot(for: rootPath)
            let outcome = try await reader.write(
                at: root,
                path: path,
                content: content,
                expectedRevision: revision,
                forceOverwrite: false
            )
            // The user may have continued editing, or reverted to the old saved text.
            let latestText = tab.currentText
            tab.savedDocument = outcome.document
            tab.savedRevision = outcome.revision
            tab.openTarget = outcome.openTarget
            tab.draftText = latestText.flatMap { $0.utf16.elementsEqual(content.utf16) ? nil : $0 }
            tab.externalConflict = nil
            tab.contentState = .text(outcome.document)
            onSaved?()
            return true
        } catch ProjectFileWriteFailure.conflict(let diskDoc, let diskRev) {
            tab.openTarget = nil
            tab.externalConflict = ExternalConflict(
                message: String(localized: "保存前检测到文件已被外部修改。为避免覆盖内容，请确认覆盖保存或重新加载磁盘版本。"),
                diskDocument: diskDoc,
                diskRevision: diskRev
            )
            return false
        } catch ProjectFileWriteFailure.recoveryRequired(let location) {
            tab.openTarget = nil
            tab.externalConflict = nil
            tab.saveError = String(localized: "保存时发生外部冲突。请检查恢复文件「\(location)」。")
            return false
        } catch ProjectFileWriteFailure.issue(let issue) {
            tab.saveError = issue.message
            return false
        } catch let issue as ProjectFileIssue {
            tab.saveError = issue.message
            return false
        } catch {
            tab.saveError = String(localized: "保存文件失败：\(error.localizedDescription)")
            return false
        }
    }

    func invalidateFileOpenRequests() {
        linkedFileRequestID = nil
        externalOpenRequestID = nil
    }

    func externalOpenRequest(for tab: EditorTab, canOpen: @escaping @MainActor () -> Bool = { true }) -> TranscriptFileOpener.Request? {
        guard let target = tab.openTarget, isEditorVisible, !isPreparingToTerminate,
              activeEditorTab === tab, canOpen() else { return nil }
        invalidateFileOpenRequests()
        let requestID = UUID()
        externalOpenRequestID = requestID
        let isCurrent: @MainActor () -> Bool = { [weak self, weak tab, weak target] in
            guard let self, let tab, let target else { return false }
            return externalOpenRequestID == requestID && tab.openTarget === target && canOpen()
        }
        return TranscriptFileOpener.Request(url: target.url, contextIsCurrent: isCurrent) { [weak tab, weak target, reader] in
            guard let target else { return false }
            do {
                try await reader.validateOpenTarget(target)
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard !Task.isCancelled, isCurrent() else { return false }
                tab?.openTarget = nil
                tab?.saveError = (error as? ProjectFileIssue ?? .unreadable).message
                return false
            }
        }
    }

    func checkExternalChanges(in directoryPath: String? = nil) {
        let normalizedTarget = directoryPath.map { GitRepositoryInspector.normalizedPath($0) }
        for tab in editorTabs {
            switch tab.kind {
            case .file(_, let rootPath, _, _, _):
                if let normalizedTarget, GitRepositoryInspector.normalizedPath(rootPath) != normalizedTarget {
                    continue
                }
                reloadTab(tab, discardDraft: false)
            case .gitDiff(_, let rootPath, _, _, _, _, _):
                let checkoutRoot = GitRepositoryInspector.normalizedPath(rootPath)
                if let normalizedTarget, normalizedTarget != checkoutRoot,
                   !normalizedTarget.hasPrefix(checkoutRoot + "/") {
                    continue
                }
                reloadTab(tab)
            case .commit, .toolDiff:
                break
            }
        }
    }

    func markdownImageLoader(for tab: EditorTab) -> MarkdownImageLoader? {
        guard case .file(_, let rootPath, _, let path, _) = tab.kind,
              tab.isMarkdownPreview,
              let doc = tab.savedDocument else { return nil }
        let revision = doc.id
        return MarkdownImageLoader(
            revision: revision,
            canLoad: { path.markdownImagePath(for: $0) != nil },
            load: { [weak self] reference in
                guard let self else { throw CancellationError() }
                let root = try await self.resolveBoundRoot(for: rootPath)
                guard let imagePath = path.markdownImagePath(for: reference) else {
                    throw ProjectFileIssue.unsupported
                }
                return try await self.reader.readMarkdownImage(at: root, path: imagePath)
            }
        )
    }

    private func resolveBoundRoot(for path: String) async throws -> ProjectFilesReader.Root {
        if let cached = boundRoots[path] { return cached }
        let bound = try await reader.bindRoot(at: path)
        boundRoots[path] = bound
        return bound
    }
}
