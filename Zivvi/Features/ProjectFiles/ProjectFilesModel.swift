import Foundation
import Observation

@MainActor
@Observable
final class ProjectFilesModel {
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
    @ObservationIgnored private var listings: [ProjectFilePath: Result<[ProjectFileEntry], ProjectFileIssue>] = [:]
    @ObservationIgnored private var limits: [ProjectFilePath: Int] = [:]
    @ObservationIgnored private var rootPath: String?
    private(set) var expanded: Set<ProjectFilePath> = [.root]
    private(set) var rows: [TreeRow] = []

    init(reader: any ProjectFilesReading = ProjectFilesReader()) {
        self.reader = reader
    }

    func bind(to path: String) {
        guard rootPath != path else { return }
        rootPath = path
        boundRoot = nil
        expanded = [.root]
        limits.removeAll()
        listings.removeAll()
        refresh()
    }

    func refresh() {
        guard let rootPath else { return }
        cancelRequests()
        if let boundRoot {
            reload(boundRoot)
        } else {
            listings.removeAll()
            bindDirectory(rootPath)
            rebuildRows()
        }
    }

    private func reload(_ boundRoot: ProjectFilesReader.Root) {
        for directory in expanded.sorted(by: { $0.components.count < $1.components.count }) {
            loadDirectory(directory, root: boundRoot)
        }
        rebuildRows()
    }

    func toggle(_ path: ProjectFilePath) {
        guard rootPath != nil, path != .root, !rootIsUnavailable else { return }
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

    func showMore(in directory: ProjectFilePath) {
        limits[directory, default: Self.pageSize] += Self.pageSize
        rebuildRows()
    }

    private var rootIsUnavailable: Bool {
        if case .failure(.rootUnavailable) = listings[.root] { return true }
        return false
    }

    private func bindDirectory(_ path: String) {
        let id = UUID()
        let task = Task { [weak self, reader] in
            let binding = try? await reader.bindRoot(at: path)
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
            listings[path] = result
            rebuildRows()
        }
        folderRequests[path] = Request(id: id, task: request)
    }

    private func cancelRequests() {
        rootRequest?.task.cancel()
        rootRequest = nil
        for request in folderRequests.values { request.task.cancel() }
        folderRequests.removeAll()
    }

    private func invalidateDirectory() {
        cancelRequests()
        listings = [.root: .failure(.rootUnavailable)]
        rebuildRows()
    }

    private func rebuildRows() {
        var visible: [TreeRow] = []
        appendRows(in: .root, depth: 0, to: &visible)
        rows = visible
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
