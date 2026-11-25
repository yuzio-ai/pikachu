import CoreGraphics
import Foundation
import Observation

struct ProjectFilesRoot: Equatable, Sendable {
    let projectID: UUID
    let path: String
    let displayName: String
}

enum ProjectFilesRegion: Hashable { case directory, preview }

enum ProjectFilesLayout: Equatable {
    case columns(CGFloat)
    case single(CGFloat)
    case overlay(CGFloat)

    init(available: CGFloat, preferred: CGFloat) {
        let availableForFiles = available - 501
        if availableForFiles >= 600 {
            self = .columns(min(780, max(600, preferred), availableForFiles))
        } else if availableForFiles >= 320 {
            self = .single(min(460, availableForFiles))
        } else {
            self = .overlay(320)
        }
    }

    var width: CGFloat {
        switch self {
        case .columns(let width), .single(let width), .overlay(let width): width
        }
    }

    var isDocked: Bool {
        if case .overlay = self { return false }
        return true
    }

    var hasColumns: Bool {
        if case .columns = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ProjectFilesModel {
    enum Preview {
        case loading, document(ProjectFileDocument), failure(ProjectFileIssue)
    }

    struct Tab: Identifiable {
        let id: ProjectFilePath
        fileprivate(set) var kind: ProjectFileEntry.Kind
        fileprivate var rendersMarkdown = false
    }

    struct TreeRow: Identifiable {
        enum Content {
            case entry(ProjectFileEntry), loading, empty, failure(ProjectFileIssue), more
        }

        enum ID: Hashable {
            case entry(ProjectFilePath), status(ProjectFilePath), more(ProjectFilePath)
        }

        let id: ID
        let path: ProjectFilePath
        let depth: Int
        let content: Content

        var isActionable: Bool {
            switch content {
            case .entry, .more: true
            case .loading, .empty, .failure: false
            }
        }
    }

    struct DirectoryLocation: Equatable {
        let row: TreeRow.ID
        let id = UUID()
    }

    struct TabLocation: Equatable {
        let path: ProjectFilePath
        let id = UUID()
    }

    struct LineTarget: Equatable {
        let path: ProjectFilePath
        let line: Int
        let id = UUID()
    }

    enum TranscriptOpenOutcome: Equatable {
        case opened, fallback, cancelled
        case unavailable(ProjectFileIssue)
    }

    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let pageSize = 200
    private let reader: any ProjectFilesReading
    @ObservationIgnored private var boundRoot: ProjectFilesReader.Root?
    @ObservationIgnored private var rootRequest: Request?
    @ObservationIgnored private var folderRequests: [ProjectFilePath: Request] = [:]
    private var fileRequest: Request?
    private var openTarget: ProjectFilesReader.OpenTarget?
    @ObservationIgnored private var openRequestID: UUID?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptOpenID: UUID?
    @ObservationIgnored private var transcriptOpenTask: Task<TranscriptOpenOutcome, Never>?
    @ObservationIgnored private var listings: [ProjectFilePath: Result<[ProjectFileEntry], ProjectFileIssue>] = [:]
    @ObservationIgnored private var limits: [ProjectFilePath: Int] = [:]
    @ObservationIgnored private var pendingDirectory: ProjectFilePath?
    private(set) var root: ProjectFilesRoot?
    private(set) var isOpen = false
    private(set) var expanded: Set<ProjectFilePath> = [.root]
    private(set) var rows: [TreeRow] = []
    private(set) var tabs: [Tab] = []
    private(set) var selected: ProjectFilePath?
    private(set) var preview: Preview?
    private(set) var directoryLocation: DirectoryLocation?
    private(set) var tabLocation: TabLocation?
    private(set) var lineTarget: LineTarget?
    var treePosition: TreeRow.ID?
    var focusedRow: TreeRow.ID?
    var region: ProjectFilesRegion = .directory
    var hidesDirectory = false

    init(reader: any ProjectFilesReading = ProjectFilesReader()) {
        self.reader = reader
    }

    func markdownImageLoader(for document: ProjectFilePath) -> MarkdownImageLoader? {
        guard let revision = markdownImageRevision(in: document) else { return nil }
        return MarkdownImageLoader(
            revision: revision,
            canLoad: { document.markdownImagePath(for: $0) != nil },
            load: { [weak self] reference in
                guard let self else { throw CancellationError() }
                return try await self.loadMarkdownImage(reference, in: document, revision: revision)
            }
        )
    }

    private func markdownImageRevision(in document: ProjectFilePath) -> UUID? {
        guard isOpen, rendersMarkdown, selected == document, openTarget != nil,
              case .document(let current) = preview else { return nil }
        return current.id
    }

    private func loadMarkdownImage(_ reference: URL, in document: ProjectFilePath, revision: UUID) async throws -> CGImage {
        try Task.checkCancellation()
        guard markdownImageRevision(in: document) == revision,
              let root = boundRoot, let documentTarget = openTarget else { throw CancellationError() }
        guard let path = document.markdownImagePath(for: reference) else { throw ProjectFileIssue.unsupported }
        try await reader.validateOpenTarget(documentTarget)
        try Task.checkCancellation()
        guard markdownImageRevision(in: document) == revision, openTarget === documentTarget else { throw CancellationError() }
        let image = try await reader.readMarkdownImage(at: root, path: path)
        try Task.checkCancellation()
        try await reader.validateOpenTarget(documentTarget)
        try Task.checkCancellation()
        guard markdownImageRevision(in: document) == revision, openTarget === documentTarget else { throw CancellationError() }
        return image
    }

    func bind(root: ProjectFilesRoot?, isOpen: Bool) {
        guard self.root != root || self.isOpen != isOpen else { return }
        let changesDirectory = self.root?.projectID != root?.projectID || self.root?.path != root?.path
        self.root = root
        guard changesDirectory || self.isOpen != isOpen else { return }
        if changesDirectory || !isOpen { cancelTranscriptOpen() }
        if changesDirectory {
            boundRoot = nil
            expanded = [.root]
            limits.removeAll()
            selected = nil
            tabs.removeAll()
            tabLocation = nil
            lineTarget = nil
            treePosition = nil
            focusedRow = nil
            region = .directory
            hidesDirectory = false
        }

        self.isOpen = isOpen
        pendingDirectory = nil
        directoryLocation = nil
        cancelRequests()
        listings.removeAll()
        preview = nil
        rebuildRows()
        guard isOpen, root != nil else { return }
        refresh()
    }

    func refresh() {
        guard let root, isOpen else { return }
        cancelRequests()
        if let boundRoot {
            reload(boundRoot)
        } else {
            listings.removeAll()
            if selected != nil { preview = .loading }
            bindDirectory(root)
            rebuildRows()
        }
    }

    private func reload(_ boundRoot: ProjectFilesReader.Root) {
        for directory in expanded.sorted(by: { $0.components.count < $1.components.count }) {
            loadDirectory(directory, root: boundRoot)
        }
        if let selected {
            if rootIsUnavailable {
                // The root listing will resume the current selection after it rechecks the binding.
                preview = .loading
            } else {
                loadFile(selected, root: boundRoot)
            }
        }
        rebuildRows()
    }

    func toggle(_ path: ProjectFilePath) {
        guard root != nil, isOpen, path != .root, !rootIsUnavailable else { return }
        pendingDirectory = nil
        if expanded.contains(path) {
            for directory in expanded.filter({ $0.isWithin(path) }) {
                expanded.remove(directory)
                folderRequests.removeValue(forKey: directory)?.task.cancel()
                listings.removeValue(forKey: directory)
                limits.removeValue(forKey: directory)
            }
        } else {
            expanded.insert(path)
            if let boundRoot { loadDirectory(path, root: boundRoot) }
        }
        rebuildRows()
    }

    func showMore(in directory: ProjectFilePath, movesFocus: Bool = false) {
        let moreIndex = movesFocus ? rows.firstIndex { $0.id == .more(directory) } : nil
        limits[directory, default: Self.pageSize] += Self.pageSize
        rebuildRows()
        guard movesFocus else { return }
        guard let moreIndex else {
            focusedRow = rows.last { $0.isActionable && $0.path.parent == directory }?.id
                ?? rows.first(where: \.isActionable)?.id
            return
        }
        if rows.indices.contains(moreIndex), case .entry = rows[moreIndex].content, rows[moreIndex].path.parent == directory {
            focusedRow = rows[moreIndex].id
        } else {
            focusedRow = rows.prefix(moreIndex).last { $0.isActionable }?.id
                ?? rows.dropFirst(moreIndex).first { $0.isActionable }?.id
        }
    }

    func open(_ entry: ProjectFileEntry) {
        guard root != nil, isOpen, entry.kind != .directory, !rootIsUnavailable else { return }
        if let index = tabs.firstIndex(where: { $0.id == entry.path }) {
            if tabs[index].kind != entry.kind {
                tabs[index].kind = entry.kind
                if selected == entry.path { loadSelection(entry.path) }
            }
        } else {
            tabs.append(Tab(id: entry.path, kind: entry.kind))
        }
        activateTab(entry.path)
    }

    func activateTab(_ path: ProjectFilePath) {
        guard isOpen, tabs.contains(where: { $0.id == path }) else { return }
        cancelTranscriptOpen()
        pendingDirectory = nil
        region = .preview
        if selected == path {
            tabLocation = TabLocation(path: path)
        } else {
            loadSelection(path)
        }
    }

    @discardableResult
    func closeTab(_ path: ProjectFilePath) -> ProjectFilePath? {
        guard isOpen, let index = tabs.firstIndex(where: { $0.id == path }) else { return nil }
        cancelTranscriptOpen()
        tabs.remove(at: index)
        let neighbor = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        if selected == path {
            loadSelection(neighbor)
            if neighbor == nil {
                region = .directory
                hidesDirectory = false
            }
        }
        return neighbor
    }

    var rendersMarkdown: Bool {
        tabs.first { $0.id == selected }?.rendersMarkdown ?? false
    }

    func toggleMarkdown() {
        guard let index = tabs.firstIndex(where: { $0.id == selected }) else { return }
        tabs[index].rendersMarkdown.toggle()
    }

    private func loadSelection(_ path: ProjectFilePath?) {
        invalidateOpenTarget()
        fileRequest?.task.cancel()
        fileRequest = nil
        lineTarget = nil
        selected = path
        tabLocation = path.map { TabLocation(path: $0) }
        guard let path else {
            preview = nil
            return
        }
        guard !rootIsUnavailable else {
            preview = folderRequests[.root] == nil ? .failure(.rootUnavailable) : .loading
            return
        }
        preview = .loading
        if let boundRoot { loadFile(path, root: boundRoot) }
    }

    func revealDirectory(_ directory: ProjectFilePath) {
        guard let selected, selected.parent.isWithin(directory), isOpen, !rootIsUnavailable else { return }
        region = .directory
        hidesDirectory = false
        pendingDirectory = directory
        var ancestor = ProjectFilePath.root
        for component in directory.components {
            let parent = ancestor
            ancestor = parent.appending(component)
            includeNavigationTarget(in: parent)
            if expanded.insert(ancestor).inserted, let boundRoot {
                loadDirectory(ancestor, root: boundRoot)
            }
        }
        rebuildRows()
    }

    var canOpenSelection: Bool {
        isOpen && fileRequest == nil && openTarget != nil
    }

    var isLoadingFile: Bool { fileRequest != nil }

    @discardableResult
    func openSelection(canLaunch: @escaping @MainActor () -> Bool = { true },
                       perform: @escaping @MainActor (TranscriptFileOpener.Request) async -> Void) -> Task<Void, Never>? {
        guard canOpenSelection, let target = openTarget, canLaunch() else { return nil }
        openTask?.cancel()
        let id = UUID()
        openRequestID = id
        let isCurrent: @MainActor () -> Bool = { [weak self, weak target] in
            guard let self, let target else { return false }
            return openRequestID == id && openTarget === target && isOpen && canLaunch()
        }
        let request = TranscriptFileOpener.Request(url: target.url, contextIsCurrent: isCurrent) {
            [weak self, weak target, reader] in
            guard let target else { return false }
            do {
                try await reader.validateOpenTarget(target)
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard let self, !Task.isCancelled, isCurrent() else { return false }
                let issue = error as? ProjectFileIssue ?? .unreadable
                if issue == .rootUnavailable {
                    invalidateDirectory()
                } else {
                    invalidateOpenTarget()
                    preview = .failure(issue)
                }
                return false
            }
        }
        let task = Task { [weak self] in
            await perform(request)
            // The command can still fail after its initial launch task has returned.
            if self?.openRequestID == id { self?.openTask = nil }
        }
        openTask = task
        return task
    }

    private func cancelTranscriptOpen() {
        transcriptOpenTask?.cancel()
        transcriptOpenTask = nil
        transcriptOpenID = nil
    }

    @discardableResult
    func openFromTranscript(
        path: ProjectFilePath,
        in targetRoot: ProjectFilesRoot,
        line: Int? = nil,
        canOpen: @escaping @MainActor () -> Bool = { true },
        activatePane: @escaping @MainActor () -> Void,
        onFallback: (@MainActor () -> Void)? = nil
    ) -> Task<TranscriptOpenOutcome, Never> {
        cancelTranscriptOpen()
        let requestID = UUID()
        transcriptOpenID = requestID
        let existingBinding = root == targetRoot ? boundRoot : nil
        let task = Task { [weak self, reader] () -> TranscriptOpenOutcome in
            guard let self else { return .cancelled }
            defer {
                if self.transcriptOpenID == requestID { self.transcriptOpenTask = nil }
            }
            @MainActor func failure(_ issue: ProjectFileIssue) -> TranscriptOpenOutcome {
                guard self.transcriptOpenID == requestID, !Task.isCancelled, canOpen() else { return .cancelled }
                guard let onFallback else { return .unavailable(issue) }
                onFallback()
                return .fallback
            }
            let binding: ProjectFilesReader.Root
            let result: ProjectFilePreview
            do {
                try Task.checkCancellation()
                binding = if let existingBinding { existingBinding } else {
                    try await reader.bindRoot(at: targetRoot.path)
                }
                try Task.checkCancellation()
                result = try await reader.read(at: binding, path: path)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return failure(error as? ProjectFileIssue ?? .unreadable)
            }
            let document: ProjectFileDocument
            switch result.contents {
            case .success(let value): document = value
            case .failure(let issue): return failure(issue)
            }
            guard self.transcriptOpenID == requestID, !Task.isCancelled, canOpen() else { return .cancelled }

            activatePane()
            guard self.root == targetRoot, self.isOpen else { return .cancelled }

            self.pendingDirectory = path
            var ancestor = ProjectFilePath.root
            for component in path.parent.components {
                ancestor = ancestor.appending(component)
                self.expanded.insert(ancestor)
            }
            if self.boundRoot == nil {
                self.rootRequest?.task.cancel()
                self.rootRequest = nil
                self.boundRoot = binding
                self.reload(binding)
            } else if let currentBinding = self.boundRoot {
                var directory = ProjectFilePath.root
                self.includeNavigationTarget(in: directory)
                if self.listings[directory] == nil && self.folderRequests[directory] == nil {
                    self.loadDirectory(directory, root: currentBinding)
                }
                for component in path.parent.components {
                    directory = directory.appending(component)
                    self.includeNavigationTarget(in: directory)
                    if self.listings[directory] == nil && self.folderRequests[directory] == nil {
                        self.loadDirectory(directory, root: currentBinding)
                    }
                }
            }

            self.invalidateOpenTarget()
            self.fileRequest?.task.cancel()
            self.fileRequest = nil
            if let index = self.tabs.firstIndex(where: { $0.id == path }) {
                self.tabs[index].kind = .file
                if line != nil { self.tabs[index].rendersMarkdown = false }
            } else {
                self.tabs.append(Tab(id: path, kind: .file))
            }
            self.selected = path
            self.region = .preview
            self.tabLocation = TabLocation(path: path)
            self.openTarget = result.openTarget
            self.preview = .document(document)
            self.lineTarget = line.map { LineTarget(path: path, line: $0) }
            self.rebuildRows()
            return .opened
        }
        transcriptOpenTask = task
        return task
    }

    private var rootIsUnavailable: Bool {
        if case .failure(.rootUnavailable) = listings[.root] { return true }
        return false
    }

    private func bindDirectory(_ root: ProjectFilesRoot) {
        let id = UUID()
        let task = Task { [weak self, reader] in
            let binding = try? await reader.bindRoot(at: root.path)
            guard let self, !Task.isCancelled, rootRequest?.id == id else { return }
            rootRequest = nil
            guard let binding else {
                invalidateDirectory()
                return
            }
            boundRoot = binding
            reload(binding)
        }
        rootRequest = Request(id: id, task: task)
    }

    private func loadDirectory(_ path: ProjectFilePath, root: ProjectFilesReader.Root) {
        let id = UUID()
        let request = Task { [weak self, reader] in
            let result: Result<[ProjectFileEntry], ProjectFileIssue>
            do { result = .success(try await reader.directory(at: root, path: path)) }
            catch is CancellationError { return }
            catch { result = .failure(error as? ProjectFileIssue ?? .unreadable) }

            guard let self, !Task.isCancelled, folderRequests[path]?.id == id else { return }
            folderRequests.removeValue(forKey: path)
            if case .failure(.rootUnavailable) = result {
                invalidateDirectory()
                return
            }
            let recoversRoot = path == .root && rootIsUnavailable
            listings[path] = result
            if recoversRoot, let selected { loadFile(selected, root: root) }
            includeNavigationTarget(in: path)
            rebuildRows()
        }
        folderRequests[path] = Request(id: id, task: request)
    }

    private func loadFile(_ path: ProjectFilePath, root: ProjectFilesReader.Root) {
        fileRequest?.task.cancel()
        if preview == nil { preview = .loading }
        let id = UUID()
        let request = Task { [weak self, reader] in
            let result: Result<ProjectFilePreview, ProjectFileIssue>
            do { result = .success(try await reader.read(at: root, path: path)) }
            catch is CancellationError { return }
            catch { result = .failure(error as? ProjectFileIssue ?? .unreadable) }

            guard let self, !Task.isCancelled, fileRequest?.id == id else { return }
            fileRequest = nil
            switch result {
            case .success(let file):
                openTarget = file.openTarget
                switch file.contents {
                case .success(let document): preview = .document(document)
                case .failure(let issue): preview = .failure(issue)
                }
            case .failure(.rootUnavailable):
                invalidateDirectory()
            case .failure(let issue):
                preview = .failure(issue)
            }
        }
        fileRequest = Request(id: id, task: request)
    }

    private func cancelRequests() {
        invalidateOpenTarget()
        rootRequest?.task.cancel()
        rootRequest = nil
        for request in folderRequests.values { request.task.cancel() }
        folderRequests.removeAll()
        fileRequest?.task.cancel()
        fileRequest = nil
    }

    private func invalidateOpenTarget() {
        openTask?.cancel()
        openTask = nil
        openRequestID = nil
        openTarget = nil
    }

    private func invalidateDirectory() {
        cancelRequests()
        pendingDirectory = nil
        listings = [.root: .failure(.rootUnavailable)]
        preview = selected == nil ? nil : .failure(.rootUnavailable)
        rebuildRows()
    }

    private func rebuildRows() {
        guard root != nil, isOpen else { rows = []; return }
        var visible: [TreeRow] = []
        appendRows(in: .root, depth: 0, to: &visible)
        rows = visible
        guard let directory = pendingDirectory else { return }
        let row = directory == .root ? visible.first?.id : .entry(directory)
        guard let row, visible.contains(where: { $0.id == row }) else { return }
        pendingDirectory = nil
        focusedRow = row
        directoryLocation = DirectoryLocation(row: row)
    }

    private func includeNavigationTarget(in parent: ProjectFilePath) {
        guard let directory = pendingDirectory, directory != parent, directory.isWithin(parent),
              case .success(let entries) = listings[parent] else { return }
        let child = parent.appending(directory.components[parent.components.count])
        guard let index = entries.firstIndex(where: { $0.path == child }) else { return }
        let containingPage = (index / Self.pageSize + 1) * Self.pageSize
        limits[parent] = max(limits[parent] ?? Self.pageSize, containingPage)
    }

    private func appendRows(in directory: ProjectFilePath, depth: Int, to rows: inout [TreeRow]) {
        let status: TreeRow.Content
        switch listings[directory] {
        case nil: status = .loading
        case .failure(let issue): status = .failure(issue)
        case .success(let entries) where entries.isEmpty: status = .empty
        case .success(let entries):
            let limit = limits[directory] ?? Self.pageSize
            for entry in entries.prefix(limit) {
                rows.append(TreeRow(id: .entry(entry.path), path: entry.path, depth: depth, content: .entry(entry)))
                if entry.kind == .directory, expanded.contains(entry.path) {
                    appendRows(in: entry.path, depth: depth + 1, to: &rows)
                }
            }
            if entries.count > limit {
                rows.append(TreeRow(id: .more(directory), path: directory, depth: depth, content: .more))
            }
            return
        }
        rows.append(TreeRow(id: .status(directory), path: directory, depth: depth, content: status))
    }
}
