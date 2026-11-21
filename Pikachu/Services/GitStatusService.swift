import Foundation
import Observation

enum GitBranchState: Equatable, Sendable {
    case branch(name: String, hasCommits: Bool)
    case detached(shortSHA: String)

    var displayName: String {
        switch self {
        case .branch(let name, _): name
        case .detached(let shortSHA): shortSHA
        }
    }
}

enum GitAheadState: Equatable, Sendable {
    case count(Int, upstream: String)
    case unavailable(reason: String)

    var displayText: String {
        switch self {
        case .count(let value, _): "\(value)"
        case .unavailable: "—"
        }
    }
}

struct GitRenamedFile: Equatable, Sendable {
    let from: String
    let to: String
}

struct GitChangesSummary: Equatable, Sendable {
    let addedFiles: [String]
    let deletedFiles: [String]
    let modifiedFiles: [String]
    let renamedFiles: [GitRenamedFile]

    var addedCount: Int { addedFiles.count }
    var deletedCount: Int { deletedFiles.count }
    var modifiedCount: Int { modifiedFiles.count }
    var renamedCount: Int { renamedFiles.count }
    var totalCount: Int { addedCount + deletedCount + modifiedCount + renamedCount }
}

struct GitRepositorySnapshot: Equatable, Sendable {
    let directoryPath: String
    let checkoutRoot: String
    let branch: GitBranchState
    let ahead: GitAheadState
    let changes: GitChangesSummary
    let updatedAt: Date
}

enum GitDirectoryState: Equatable, Sendable {
    case idle
    case loading(previous: GitRepositorySnapshot?)
    case loaded(GitRepositorySnapshot, isStale: Bool, refreshError: String?)
    case notRepository(directoryPath: String, reason: String, updatedAt: Date)
    case directoryMissing(directoryPath: String, reason: String, updatedAt: Date)
    case failed(directoryPath: String, reason: String, updatedAt: Date)

    var snapshot: GitRepositorySnapshot? {
        switch self {
        case .loaded(let snapshot, _, _): snapshot
        case .loading(let previous): previous
        default: nil
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum GitRepositoryInspector {
    private static let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func inspect(directory: URL, now: Date = Date()) async -> GitDirectoryState {
        let normalized = normalizedPath(directory.path)
        return await Task.detached(priority: .utility) {
            inspectSync(directoryPath: normalized, now: now)
        }.value
    }

    static func inspectSync(directoryPath: String, now: Date = Date()) -> GitDirectoryState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .directoryMissing(directoryPath: directoryPath, reason: String(localized: "工作目录不存在或已移动。"), updatedAt: now)
        }

        let topLevel = runGit(["rev-parse", "--show-toplevel"], cwd: directoryPath)
        if topLevel.exitCode != 0 {
            let err = topLevel.stderrString.lowercased()
            if err.contains("not a git repository") {
                return .notRepository(directoryPath: directoryPath, reason: String(localized: "当前目录不是 Git 仓库。"), updatedAt: now)
            }
            return .failed(directoryPath: directoryPath, reason: topLevel.stderrString.isEmpty ? String(localized: "无法读取 Git 仓库信息。") : topLevel.stderrString, updatedAt: now)
        }

        let checkoutRoot = normalizedPath(topLevel.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        let status = runGit(["status", "--porcelain=v2", "-z", "-uall", "--branch"], cwd: checkoutRoot)
        guard status.exitCode == 0 else {
            let detail = status.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(directoryPath: directoryPath, reason: detail.isEmpty ? String(localized: "Git 状态读取失败。") : detail, updatedAt: now)
        }

        let snapshot = parsePorcelainV2(status.stdout, directoryPath: directoryPath, checkoutRoot: checkoutRoot, updatedAt: now)
        return .loaded(snapshot, isStale: false, refreshError: nil)
    }

    static func parsePorcelainV2(_ data: Data, directoryPath: String, checkoutRoot: String, updatedAt: Date) -> GitRepositorySnapshot {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }

        var branchOID: String?
        var branchHead: String?
        var branchUpstream: String?
        var aheadCount: Int?

        struct PathState {
            var indexStatus: Character = "."
            var worktreeStatus: Character = "."
            var hasUntracked = false
            var renamedFrom: String?
            var isUnmerged = false
        }

        var pathStates: [String: PathState] = [:]
        var orderedPaths: [String] = []

        func updatePath(_ path: String, _ mutate: (inout PathState) -> Void) {
            if pathStates[path] == nil {
                pathStates[path] = PathState()
                orderedPaths.append(path)
            }
            mutate(&pathStates[path]!)
        }

        var index = 0
        while index < tokens.count {
            let line = tokens[index]
            index += 1

            if line.hasPrefix("# branch.oid ") {
                branchOID = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                branchHead = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                branchUpstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if let plus = parts.first(where: { $0.hasPrefix("+") }),
                   let value = Int(plus.dropFirst()) {
                    aheadCount = value
                }
            } else if line.hasPrefix("1 ") {
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let xy = Array(fields[1])
                guard xy.count == 2 else { continue }
                let path = String(fields[8])
                updatePath(path) { state in
                    state.indexStatus = xy[0]
                    state.worktreeStatus = xy[1]
                }
            } else if line.hasPrefix("2 ") {
                let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let xy = Array(fields[1])
                guard xy.count == 2 else { continue }
                let path = String(fields[9])
                let origPath = index < tokens.count ? tokens[index] : nil
                if origPath != nil { index += 1 }
                updatePath(path) { state in
                    state.indexStatus = xy[0]
                    state.worktreeStatus = xy[1]
                    state.renamedFrom = origPath
                }
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                let path = String(fields[10])
                updatePath(path) { state in
                    state.isUnmerged = true
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                updatePath(path) { state in
                    state.hasUntracked = true
                }
            }
        }

        let isDetached = branchHead == "(detached)"
        let hasCommits = branchOID != nil && branchOID != "(initial)"
        let branch: GitBranchState
        if isDetached {
            let shortSHA = branchOID.map { String($0.prefix(7)) } ?? "HEAD"
            branch = .detached(shortSHA: shortSHA)
        } else {
            branch = .branch(name: branchHead ?? "HEAD", hasCommits: hasCommits)
        }

        let ahead: GitAheadState
        if isDetached {
            ahead = .unavailable(reason: String(localized: "当前处于分离 HEAD 状态，无法统计领先提交。"))
        } else if !hasCommits {
            ahead = .unavailable(reason: String(localized: "当前分支尚无提交记录。"))
        } else if let branchUpstream {
            if let aheadCount {
                ahead = .count(aheadCount, upstream: branchUpstream)
            } else {
                ahead = .unavailable(reason: String(localized: "本地缺少上游追踪引用（\(branchUpstream)）。"))
            }
        } else {
            ahead = .unavailable(reason: String(localized: "当前分支未配置上游分支。"))
        }

        var added: [String] = []
        var deleted: [String] = []
        var modified: [String] = []
        var renamed: [GitRenamedFile] = []

        for path in orderedPaths {
            guard let state = pathStates[path] else { continue }
            if state.isUnmerged {
                modified.append(path)
                continue
            }
            if state.indexStatus == "R" || state.worktreeStatus == "R" {
                if state.worktreeStatus == "D" {
                    deleted.append(state.renamedFrom ?? path)
                } else {
                    renamed.append(.init(from: state.renamedFrom ?? path, to: path))
                }
                continue
            }
            if state.indexStatus == "D" {
                if state.hasUntracked {
                    modified.append(path)
                } else {
                    deleted.append(path)
                }
                continue
            }
            if state.worktreeStatus == "D" {
                if state.indexStatus == "A" {
                    modified.append(path)
                } else {
                    deleted.append(path)
                }
                continue
            }
            if state.indexStatus == "A" || state.indexStatus == "C" || state.hasUntracked {
                added.append(path)
                continue
            }
            modified.append(path)
        }

        return GitRepositorySnapshot(
            directoryPath: directoryPath,
            checkoutRoot: checkoutRoot,
            branch: branch,
            ahead: ahead,
            changes: .init(addedFiles: added, deletedFiles: deleted, modifiedFiles: modified, renamedFiles: renamed),
            updatedAt: updatedAt
        )
    }

    private struct GitCommandOutput {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private static func runGit(_ args: [String], cwd: String) -> GitCommandOutput {
        let process = Process()
        process.executableURL = gitExecutable
        process.arguments = ["--no-optional-locks", "-C", cwd] + args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        do {
            try process.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
            return GitCommandOutput(exitCode: process.terminationStatus, stdout: stdoutBox.data, stderr: stderrBox.data)
        } catch {
            return GitCommandOutput(exitCode: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
    }
}

struct GitWorktree: Identifiable, Sendable, Equatable {
    let path: String
    let branch: String?
    let commit: String?
    var id: String { path }
}

enum GitWorktreeError: LocalizedError {
    case invalidDestination
    case invalidBranch
    case invalidBase
    case commandFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination: String(localized: "请输入尚未存在的工作树绝对路径。")
        case .invalidBranch: String(localized: "请输入有效的新分支名称。")
        case .invalidBase: String(localized: "无法解析基准提交。")
        case .commandFailed(let detail): String(localized: "无法创建工作树：\(detail)")
        case .notFound(let path): String(localized: "未能确认新工作树：\(path)")
        }
    }
}

extension GitRepositoryInspector {
    static func worktrees(in projectPath: String) async -> [GitWorktree]? {
        await Task.detached(priority: .utility) {
            guard let commonDirectory = gitPath("--git-common-dir", in: projectPath),
                  let worktrees = readWorktrees(in: projectPath) else { return nil }
            return worktrees.filter { isCheckout(at: $0.path, commonDirectory: commonDirectory) }
        }.value
    }

    static func isUsableWorktree(_ path: String, in projectPath: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let commonDirectory = gitPath("--git-common-dir", in: projectPath),
                  readWorktrees(in: projectPath)?.contains(where: { $0.path == target }) == true else { return false }
            return isCheckout(at: target, commonDirectory: commonDirectory)
        }.value
    }

    private static func isCheckout(at path: String, commonDirectory: String) -> Bool {
        // A stale registration can still name a path that now leads to another checkout.
        normalizedPath(path) == path &&
            gitPath("--show-toplevel", in: path) == path &&
            gitPath("--git-common-dir", in: path) == commonDirectory
    }

    private static func gitPath(_ option: String, in directory: String) -> String? {
        let result = runGit(["rev-parse", "--path-format=absolute", option], cwd: directory)
        guard result.exitCode == 0, result.stdout.last == 0x0A else { return nil }
        let path = String(decoding: result.stdout.dropLast(), as: UTF8.self)
        guard path.hasPrefix("/") else { return nil }
        return normalizedPath(path)
    }

    private static func readWorktrees(in projectPath: String) -> [GitWorktree]? {
        let result = runGit(["worktree", "list", "--porcelain", "-z"], cwd: projectPath)
        guard result.exitCode == 0 else { return nil }
        return result.stdoutString.components(separatedBy: "\0\0").compactMap { record in
            let fields = record.split(separator: "\0")
            guard let first = fields.first, first.hasPrefix("worktree "),
                  !fields.contains("bare"), !fields.contains(where: { $0 == "prunable" || $0.hasPrefix("prunable ") }) else { return nil }
            let registeredPath = String(first.dropFirst("worktree ".count))
            let path = URL(fileURLWithPath: registeredPath).standardizedFileURL.path
            let branch = fields.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst("branch refs/heads/".count)) }
            let commit = fields.first { $0.hasPrefix("HEAD ") }.map { String($0.dropFirst("HEAD ".count)) }
            return GitWorktree(path: path, branch: branch, commit: commit)
        }
    }

    static func createWorktree(in projectPath: String, destination: String, branch: String, base: String) async throws -> GitWorktree {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let target = normalizedPath(destination)
            guard destination.hasPrefix("/"), !manager.fileExists(atPath: target) else {
                throw GitWorktreeError.invalidDestination
            }
            guard !branch.isEmpty, !branch.hasPrefix("-"),
                  runGit(["check-ref-format", "refs/heads/\(branch)"], cwd: projectPath).exitCode == 0 else {
                throw GitWorktreeError.invalidBranch
            }
            guard !base.isEmpty else { throw GitWorktreeError.invalidBase }
            let resolved = runGit(["rev-parse", "--verify", "--end-of-options", "\(base)^{commit}"], cwd: projectPath)
            guard resolved.exitCode == 0 else { throw GitWorktreeError.invalidBase }
            let commit = resolved.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = runGit(["worktree", "add", "-b", branch, "--", target, commit], cwd: projectPath)
            guard result.exitCode == 0 else {
                throw GitWorktreeError.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let created = readWorktrees(in: projectPath)?.first(where: { $0.path == target && $0.branch == branch }),
                  let commonDirectory = gitPath("--git-common-dir", in: projectPath),
                  isCheckout(at: target, commonDirectory: commonDirectory) else {
                throw GitWorktreeError.notFound(target)
            }
            return created
        }.value
    }
}

@MainActor @Observable final class GitStatusStore {
    private var states: [String: GitDirectoryState] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let inspector: @Sendable (URL) async -> GitDirectoryState

    init(inspector: @escaping @Sendable (URL) async -> GitDirectoryState = { await GitRepositoryInspector.inspect(directory: $0) }) {
        self.inspector = inspector
    }

    func state(for directory: String) -> GitDirectoryState {
        states[GitRepositoryInspector.normalizedPath(directory)] ?? .idle
    }

    func refresh(directory: String, force: Bool = false) {
        let key = GitRepositoryInspector.normalizedPath(directory)
        if !force, tasks[key] != nil { return }

        tasks[key]?.cancel()
        let generation = UUID()
        generations[key] = generation

        let existingSnapshot = states[key]?.snapshot?.directoryPath == key ? states[key]?.snapshot : nil
        if case .loaded(let snapshot, _, let error) = states[key], snapshot.directoryPath == key {
            states[key] = .loaded(snapshot, isStale: true, refreshError: error)
        } else {
            states[key] = .loading(previous: existingSnapshot)
        }

        let url = URL(fileURLWithPath: key)
        tasks[key] = Task { [weak self] in
            let result = await self?.inspector(url)
            guard let self else { return }
            if self.generations[key] == generation {
                self.tasks[key] = nil
            }
            guard !Task.isCancelled, self.generations[key] == generation, let result else { return }
            self.apply(result, forNormalizedDirectory: key)
        }
    }

    private func apply(_ result: GitDirectoryState, forNormalizedDirectory key: String) {
        switch result {
        case .loaded(let snapshot, _, _):
            states[key] = result
            for (otherKey, otherState) in states where otherKey != key {
                if let otherSnap = otherState.snapshot, otherSnap.checkoutRoot == snapshot.checkoutRoot {
                    let shared = GitRepositorySnapshot(
                        directoryPath: otherKey,
                        checkoutRoot: snapshot.checkoutRoot,
                        branch: snapshot.branch,
                        ahead: snapshot.ahead,
                        changes: snapshot.changes,
                        updatedAt: snapshot.updatedAt
                    )
                    states[otherKey] = .loaded(shared, isStale: false, refreshError: nil)
                }
            }
        case .failed(_, let reason, _):
            if let existing = states[key]?.snapshot, existing.directoryPath == key {
                states[key] = .loaded(existing, isStale: true, refreshError: reason)
            } else {
                states[key] = result
            }
        case .notRepository, .directoryMissing, .idle, .loading:
            states[key] = result
        }
    }
}
