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

enum GitFileChangeStatus: String, Equatable, Sendable, Hashable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "U"
    case conflict = "!"

    var badgeText: String { rawValue }

    var localizedName: String {
        switch self {
        case .modified: String(localized: "已修改")
        case .added: String(localized: "已新增")
        case .deleted: String(localized: "已删除")
        case .renamed: String(localized: "已重命名")
        case .untracked: String(localized: "未跟踪")
        case .conflict: String(localized: "冲突")
        }
    }
}

struct GitLineStat: Equatable, Sendable, Hashable {
    let added: Int?
    let deleted: Int?
    let isBinary: Bool

    static let zero = GitLineStat(added: 0, deleted: 0, isBinary: false)

    var hasVisibleChange: Bool {
        if isBinary { return false }
        return (added ?? 0) > 0 || (deleted ?? 0) > 0
    }
}

enum GitDiffScope: String, Equatable, Sendable, Hashable {
    case workingTreeVsHEAD
    case stagedVsHEAD
    case unstagedVsIndex
    case untrackedNewFile

    var comparisonLabel: String {
        switch self {
        case .workingTreeVsHEAD: String(localized: "工作区 vs HEAD")
        case .stagedVsHEAD: String(localized: "暂存区 vs HEAD")
        case .unstagedVsIndex: String(localized: "未暂存 vs 暂存区")
        case .untrackedNewFile: String(localized: "未跟踪新文件")
        }
    }
}

struct GitFileChange: Identifiable, Equatable, Sendable, Hashable {
    let path: String
    let previousPath: String?
    let status: GitFileChangeStatus
    let scope: GitDiffScope
    let stat: GitLineStat?

    var id: String { "\(scope.rawValue):\(path)" }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directoryPath: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
}

struct GitDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case hunkHeader, context, addition, deletion, meta
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

struct GitDiffDocument: Equatable, Sendable {
    let path: String
    let previousPath: String?
    let scope: GitDiffScope
    let comparisonLabel: String
    let status: GitFileChangeStatus?
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isEmpty: Bool
    let truncated: Bool
    let rawText: String
    let lines: [GitDiffLine]
    let errorMessage: String?
}

struct GitCommitSummary: Identifiable, Equatable, Sendable, Hashable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date
    let filesChanged: Int?
    let additions: Int?
    let deletions: Int?

    var id: String { hash }
}

struct GitCommitFileChange: Identifiable, Equatable, Sendable {
    let path: String
    let previousPath: String?
    let status: GitFileChangeStatus
    let stat: GitLineStat

    var id: String { path }
}

struct GitCommitDetail: Equatable, Sendable {
    let summary: GitCommitSummary
    let body: String
    let files: [GitCommitFileChange]
    let diffDocuments: [GitDiffDocument]
    let rawPatch: String
}

struct GitChangesSummary: Equatable, Sendable {
    let addedFiles: [String]
    let deletedFiles: [String]
    let modifiedFiles: [String]
    let renamedFiles: [GitRenamedFile]
    let stagedChanges: [GitFileChange]
    let unstagedChanges: [GitFileChange]
    let untrackedChanges: [GitFileChange]
    let conflictChanges: [GitFileChange]
    let fileStatuses: [String: GitFileChangeStatus]
    let fileStats: [String: GitLineStat]
    let directoryStats: [String: GitLineStat]
    let totalAdditions: Int
    let totalDeletions: Int
    let hasLineStats: Bool

    init(
        addedFiles: [String],
        deletedFiles: [String],
        modifiedFiles: [String],
        renamedFiles: [GitRenamedFile],
        stagedChanges: [GitFileChange] = [],
        unstagedChanges: [GitFileChange] = [],
        untrackedChanges: [GitFileChange] = [],
        conflictChanges: [GitFileChange] = [],
        fileStatuses: [String: GitFileChangeStatus] = [:],
        fileStats: [String: GitLineStat] = [:],
        directoryStats: [String: GitLineStat] = [:],
        totalAdditions: Int = 0,
        totalDeletions: Int = 0,
        hasLineStats: Bool = false
    ) {
        self.addedFiles = addedFiles
        self.deletedFiles = deletedFiles
        self.modifiedFiles = modifiedFiles
        self.renamedFiles = renamedFiles
        self.stagedChanges = stagedChanges
        self.unstagedChanges = unstagedChanges
        self.untrackedChanges = untrackedChanges
        self.conflictChanges = conflictChanges
        self.fileStatuses = fileStatuses
        self.fileStats = fileStats
        self.directoryStats = directoryStats
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.hasLineStats = hasLineStats
    }

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
    let upstream: String?
    let behindCount: Int?
    let changes: GitChangesSummary
    let updatedAt: Date

    init(
        directoryPath: String,
        checkoutRoot: String,
        branch: GitBranchState,
        ahead: GitAheadState,
        upstream: String? = nil,
        behindCount: Int? = nil,
        changes: GitChangesSummary,
        updatedAt: Date
    ) {
        self.directoryPath = directoryPath
        self.checkoutRoot = checkoutRoot
        self.branch = branch
        self.ahead = ahead
        self.upstream = upstream
        self.behindCount = behindCount
        self.changes = changes
        self.updatedAt = updatedAt
    }
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
        let enriched = enrichLineStats(snapshot: snapshot, checkoutRoot: checkoutRoot)
        return .loaded(enriched, isStale: false, refreshError: nil)
    }

    static func parsePorcelainV2(_ data: Data, directoryPath: String, checkoutRoot: String, updatedAt: Date) -> GitRepositorySnapshot {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }

        var branchOID: String?
        var branchHead: String?
        var branchUpstream: String?
        var aheadCount: Int?
        var behindCount: Int?

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
                if let minus = parts.first(where: { $0.hasPrefix("-") }),
                   let value = Int(minus.dropFirst()) {
                    behindCount = value
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
        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []
        var untracked: [GitFileChange] = []
        var conflicts: [GitFileChange] = []
        var fileStatuses: [String: GitFileChangeStatus] = [:]

        func status(for code: Character) -> GitFileChangeStatus {
            switch code {
            case "A", "C": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
        }

        for path in orderedPaths {
            guard let state = pathStates[path] else { continue }
            if state.isUnmerged {
                modified.append(path)
                fileStatuses[path] = .conflict
                conflicts.append(.init(path: path, previousPath: nil, status: .conflict, scope: .workingTreeVsHEAD, stat: nil))
                continue
            }
            if state.indexStatus != "." {
                staged.append(.init(
                    path: path,
                    previousPath: state.indexStatus == "R" || state.indexStatus == "C" ? state.renamedFrom : nil,
                    status: status(for: state.indexStatus),
                    scope: .stagedVsHEAD,
                    stat: nil
                ))
            }
            if state.worktreeStatus != "." {
                unstaged.append(.init(
                    path: path,
                    previousPath: state.worktreeStatus == "R" || state.worktreeStatus == "C" ? state.renamedFrom : nil,
                    status: status(for: state.worktreeStatus),
                    scope: .unstagedVsIndex,
                    stat: nil
                ))
            }
            if state.hasUntracked {
                untracked.append(.init(path: path, previousPath: nil, status: .untracked, scope: .untrackedNewFile, stat: nil))
            }

            if state.indexStatus == "R" || state.worktreeStatus == "R" {
                if state.worktreeStatus == "D" {
                    deleted.append(state.renamedFrom ?? path)
                    fileStatuses[state.renamedFrom ?? path] = .deleted
                } else {
                    renamed.append(.init(from: state.renamedFrom ?? path, to: path))
                    fileStatuses[path] = .renamed
                }
                continue
            }
            if state.indexStatus == "D" {
                if state.hasUntracked {
                    modified.append(path)
                    fileStatuses[path] = .modified
                } else {
                    deleted.append(path)
                    fileStatuses[path] = .deleted
                }
                continue
            }
            if state.worktreeStatus == "D" {
                if state.indexStatus == "A" {
                    modified.append(path)
                    fileStatuses[path] = .modified
                } else {
                    deleted.append(path)
                    fileStatuses[path] = .deleted
                }
                continue
            }
            if state.indexStatus == "A" || state.indexStatus == "C" || state.worktreeStatus == "C" {
                added.append(path)
                fileStatuses[path] = .added
                continue
            }
            if state.hasUntracked {
                added.append(path)
                fileStatuses[path] = .untracked
                continue
            }
            modified.append(path)
            fileStatuses[path] = .modified
        }

        return GitRepositorySnapshot(
            directoryPath: directoryPath,
            checkoutRoot: checkoutRoot,
            branch: branch,
            ahead: ahead,
            upstream: branchUpstream,
            behindCount: behindCount,
            changes: .init(
                addedFiles: added,
                deletedFiles: deleted,
                modifiedFiles: modified,
                renamedFiles: renamed,
                stagedChanges: staged,
                unstagedChanges: unstaged,
                untrackedChanges: untracked,
                conflictChanges: conflicts,
                fileStatuses: fileStatuses
            ),
            updatedAt: updatedAt
        )
    }

    private static func enrichLineStats(snapshot: GitRepositorySnapshot, checkoutRoot: String) -> GitRepositorySnapshot {
        let hasCommits: Bool
        switch snapshot.branch {
        case .branch(_, let commits): hasCommits = commits
        case .detached: hasCommits = true
        }

        // Net changes relative to HEAD (prevents staged + unstaged double-counting).
        let diffArgs = ["diff", "--numstat", "-z"] + statusRenameArguments(in: checkoutRoot)
        let netDiffArgs = diffArgs + (hasCommits ? ["HEAD"] : ["--cached"])
        let netOutput = runGit(netDiffArgs, cwd: checkoutRoot)
        var fileStats = netOutput.exitCode == 0 ? parseNumstatZ(netOutput.stdout) : [:]

        // Per-scope stats for Git -> Changes sections (staged vs HEAD, unstaged vs Index).
        let stagedStats: [String: GitLineStat] = snapshot.changes.stagedChanges.isEmpty ? [:] : {
            let out = runGit(diffArgs + ["--cached"], cwd: checkoutRoot)
            return out.exitCode == 0 ? parseNumstatZ(out.stdout) : [:]
        }()
        let unstagedStats: [String: GitLineStat] = snapshot.changes.unstagedChanges.isEmpty ? [:] : {
            let out = runGit(diffArgs, cwd: checkoutRoot)
            return out.exitCode == 0 ? parseNumstatZ(out.stdout) : [:]
        }()

        // Untracked files: count real lines for readable UTF-8 text files (bounded).
        var untrackedStats: [String: GitLineStat] = [:]
        for item in snapshot.changes.untrackedChanges {
            let stat = countUntrackedLines(relativePath: item.path, checkoutRoot: checkoutRoot)
            untrackedStats[item.path] = stat
            if fileStats[item.path] == nil {
                fileStats[item.path] = stat
            }
        }

        // Roll up deduplicated net fileStats upward into parent directories.
        var dirTotals: [String: (added: Int, deleted: Int, hasNumeric: Bool)] = [:]
        var totalAdditions = 0
        var totalDeletions = 0
        var hasLineStats = false
        for (path, stat) in fileStats {
            guard !stat.isBinary, let a = stat.added, let d = stat.deleted else { continue }
            hasLineStats = true
            totalAdditions += a
            totalDeletions += d
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty && current != "." && current != "/" {
                var entry = dirTotals[current] ?? (0, 0, false)
                entry.added += a
                entry.deleted += d
                entry.hasNumeric = true
                dirTotals[current] = entry
                let next = (current as NSString).deletingLastPathComponent
                if next == current { break }
                current = next
            }
        }
        let directoryStats = dirTotals.compactMapValues { entry -> GitLineStat? in
            guard entry.hasNumeric else { return nil }
            return GitLineStat(added: entry.added, deleted: entry.deleted, isBinary: false)
        }

        let updatedStaged = snapshot.changes.stagedChanges.map {
            GitFileChange(path: $0.path, previousPath: $0.previousPath, status: $0.status,
                          scope: $0.scope, stat: stagedStats[$0.path])
        }
        let updatedUnstaged = snapshot.changes.unstagedChanges.map {
            GitFileChange(path: $0.path, previousPath: $0.previousPath, status: $0.status,
                          scope: $0.scope, stat: unstagedStats[$0.path])
        }
        let updatedUntracked = snapshot.changes.untrackedChanges.map {
            GitFileChange(path: $0.path, previousPath: $0.previousPath, status: $0.status,
                          scope: $0.scope, stat: untrackedStats[$0.path])
        }
        let updatedConflicts = snapshot.changes.conflictChanges.map {
            GitFileChange(path: $0.path, previousPath: $0.previousPath, status: $0.status,
                          scope: $0.scope, stat: fileStats[$0.path])
        }

        return GitRepositorySnapshot(
            directoryPath: snapshot.directoryPath,
            checkoutRoot: snapshot.checkoutRoot,
            branch: snapshot.branch,
            ahead: snapshot.ahead,
            upstream: snapshot.upstream,
            behindCount: snapshot.behindCount,
            changes: GitChangesSummary(
                addedFiles: snapshot.changes.addedFiles,
                deletedFiles: snapshot.changes.deletedFiles,
                modifiedFiles: snapshot.changes.modifiedFiles,
                renamedFiles: snapshot.changes.renamedFiles,
                stagedChanges: updatedStaged,
                unstagedChanges: updatedUnstaged,
                untrackedChanges: updatedUntracked,
                conflictChanges: updatedConflicts,
                fileStatuses: snapshot.changes.fileStatuses,
                fileStats: fileStats,
                directoryStats: directoryStats,
                totalAdditions: totalAdditions,
                totalDeletions: totalDeletions,
                hasLineStats: hasLineStats
            ),
            updatedAt: snapshot.updatedAt
        )
    }

    static func parseNumstatZ(_ data: Data) -> [String: GitLineStat] {
        // With -z, records are: "<add>\t<del>\t<path>\0" OR for renames "<add>\t<del>\t\0<old>\0<new>\0".
        let chunks = data.split(separator: 0, omittingEmptySubsequences: false)
        var result: [String: GitLineStat] = [:]
        var i = 0
        while i < chunks.count {
            let chunk = String(decoding: chunks[i], as: UTF8.self)
            i += 1
            guard !chunk.isEmpty else { continue }
            let parts = chunk.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let addStr = String(parts[0])
            let delStr = String(parts[1])
            let pathPart = String(parts[2])
            let resolvedPath: String
            if pathPart.isEmpty {
                // Rename entry: next two NUL-separated tokens are oldPath and newPath.
                guard i + 1 < chunks.count else { break }
                resolvedPath = String(decoding: chunks[i + 1], as: UTF8.self)
                i += 2
            } else {
                resolvedPath = pathPart
            }
            guard !resolvedPath.isEmpty else { continue }
            if addStr == "-" || delStr == "-" {
                result[resolvedPath] = GitLineStat(added: nil, deleted: nil, isBinary: true)
            } else if let a = Int(addStr), let d = Int(delStr) {
                result[resolvedPath] = GitLineStat(added: a, deleted: d, isBinary: false)
            }
        }
        return result
    }

    private static func countUntrackedLines(relativePath: String, checkoutRoot: String) -> GitLineStat {
        let url = URL(fileURLWithPath: checkoutRoot, isDirectory: true).appending(path: relativePath)
        var st = stat()
        guard lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size <= Int64(ProjectFilesReader.maximumBytes),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return GitLineStat(added: nil, deleted: nil, isBinary: true)
        }
        if data.isEmpty {
            return GitLineStat(added: 0, deleted: 0, isBinary: false)
        }
        if data.contains(0) {
            return GitLineStat(added: nil, deleted: nil, isBinary: true)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return GitLineStat(added: nil, deleted: nil, isBinary: true)
        }
        var lines = 0
        for byte in text.utf8 where byte == 0x0A {
            lines += 1
        }
        if text.utf8.last != 0x0A {
            lines += 1
        }
        return GitLineStat(added: lines, deleted: 0, isBinary: false)
    }

    static func fileDiff(path: String, scope: GitDiffScope, in directoryPath: String) async -> GitDiffDocument {
        let normalized = normalizedPath(directoryPath)
        return await Task.detached(priority: .userInitiated) {
            fileDiffSync(path: path, scope: scope, directoryPath: normalized)
        }.value
    }

    private static func fileDiffSync(path: String, scope: GitDiffScope, directoryPath: String) -> GitDiffDocument {
        func empty(error: String? = nil) -> GitDiffDocument {
            GitDiffDocument(path: path, previousPath: nil, scope: scope, comparisonLabel: scope.comparisonLabel,
                            status: nil, additions: 0, deletions: 0, isBinary: false, isEmpty: true, truncated: false,
                            rawText: "", lines: [], errorMessage: error)
        }

        if scope == .untrackedNewFile {
            let untracked = runGit(["--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--", path],
                                   cwd: directoryPath)
            guard untracked.exitCode == 0,
                  untracked.stdout.split(separator: 0).contains(where: { $0.elementsEqual(path.utf8) }) else {
                return empty(error: untracked.exitCode == 0 ? nil : String(localized: "无法生成 Git Diff。"))
            }
            let url = URL(fileURLWithPath: directoryPath, isDirectory: true).appending(path: path)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                return GitDiffDocument(path: path, previousPath: nil, scope: scope,
                                       comparisonLabel: scope.comparisonLabel, status: .untracked,
                                       additions: 0, deletions: 0, isBinary: false, isEmpty: true,
                                       truncated: false, rawText: "", lines: [],
                                       errorMessage: String(localized: "无法读取未跟踪文件。"))
            }
            if st.st_size > Int64(ProjectFilesReader.maximumBytes) {
                return GitDiffDocument(path: path, previousPath: nil, scope: scope,
                                       comparisonLabel: scope.comparisonLabel, status: .untracked,
                                       additions: 0, deletions: 0, isBinary: false, isEmpty: true,
                                       truncated: true, rawText: "", lines: [],
                                       errorMessage: String(localized: "文件超过 512 KiB 预览上限。"))
            }
            guard let data = try? Data(contentsOf: url) else {
                return GitDiffDocument(path: path, previousPath: nil, scope: scope,
                                       comparisonLabel: scope.comparisonLabel, status: .untracked,
                                       additions: 0, deletions: 0, isBinary: false, isEmpty: true,
                                       truncated: false, rawText: "", lines: [],
                                       errorMessage: String(localized: "读取文件失败。"))
            }
            if data.contains(0) || String(data: data, encoding: .utf8) == nil {
                return GitDiffDocument(path: path, previousPath: nil, scope: scope,
                                       comparisonLabel: scope.comparisonLabel, status: .untracked,
                                       additions: 0, deletions: 0, isBinary: true, isEmpty: false,
                                       truncated: false, rawText: "", lines: [], errorMessage: nil)
            }
            let text = String(decoding: data, as: UTF8.self)
            let rawLines = text.isEmpty ? [] : text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            let trimmed = data.last == 0x0A ? Array(rawLines.dropLast()) : rawLines
            let diffLines = trimmed.enumerated().map { idx, line in
                GitDiffLine(id: idx, kind: .addition, oldLineNumber: nil, newLineNumber: idx + 1, text: line)
            }
            let rawUnified = trimmed.map { "+\($0)" }.joined(separator: "\n")
            return GitDiffDocument(path: path, previousPath: nil, scope: scope,
                                   comparisonLabel: scope.comparisonLabel, status: .untracked,
                                   additions: diffLines.count, deletions: 0, isBinary: false,
                                   isEmpty: diffLines.isEmpty, truncated: false,
                                   rawText: rawUnified, lines: diffLines, errorMessage: nil)
        }

        var args = ["--literal-pathspecs", "-c", "diff.suppressBlankEmpty=false",
                    "diff", "--no-ext-diff", "--submodule=short"] + statusRenameArguments(in: directoryPath)
        switch scope {
        case .stagedVsHEAD:
            args += ["--cached", "--diff-filter=u"]
        case .unstagedVsIndex:
            // Avoid raw-only unmerged records and combined patches. Conflicts have their own HEAD comparison.
            args += ["--ours", "--diff-filter=u"]
        case .workingTreeVsHEAD: args.append("HEAD")
        case .untrackedNewFile: break
        }
        let patchArgs = ["--raw", "-z", "--patch", "--no-color", "--unified=3"]
        // A pathspec changes the set of potential sources and destinations used by rename and copy detection.
        let output = runGit(args + patchArgs, cwd: directoryPath)
        guard output.exitCode == 0 else {
            let error = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return empty(error: error.isEmpty ? String(localized: "无法生成 Git Diff。") : error)
        }
        let patch = parsePatchOutput(output.stdout)
        guard let file = patch.files.first(where: { $0.change.path.utf8.elementsEqual(path.utf8) }) else { return empty() }
        return parseUnifiedDiff(String(file.text), path: path, previousPath: file.change.previousPath,
                                scope: scope, status: file.change.status)
    }

    private static func statusRenameArguments(in directoryPath: String) -> [String] {
        let override = runGit(["config", "--get", "status.renames"], cwd: directoryPath)
        guard override.exitCode == 0 else { return [] } // Git diff then uses diff.renames, as status does.
        if override.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copies" {
            return ["--find-copies"]
        }
        let enabled = runGit(["config", "--type=bool", "--get", "status.renames"], cwd: directoryPath)
        guard enabled.exitCode == 0 else { return [] }
        return enabled.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            ? ["--find-renames"] : ["--no-renames"]
    }

    static func parseUnifiedDiff(
        _ raw: String,
        path: String,
        previousPath: String?,
        scope: GitDiffScope,
        status: GitFileChangeStatus?,
        comparisonLabel: String? = nil
    ) -> GitDiffDocument {
        let maxLines = 4_000
        let rawLines = raw.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        var parsed: [GitDiffLine] = []
        var additions = 0
        var deletions = 0
        var isBinary = false
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var truncated = false

        for substring in rawLines {
            if parsed.count >= maxLines {
                truncated = true
                break
            }
            let line = String(decoding: substring, as: UTF8.self)
            if line.hasPrefix("diff --git ") {
                inHunk = false
                continue
            }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
                continue
            }
            if line.hasPrefix("@@ ") {
                inHunk = true
                let numbers = parseHunkHeader(line)
                oldLine = numbers.oldStart
                newLine = numbers.newStart
                parsed.append(GitDiffLine(id: parsed.count, kind: .hunkHeader, oldLineNumber: nil, newLineNumber: nil, text: line))
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                additions += 1
                parsed.append(GitDiffLine(id: parsed.count, kind: .addition, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                deletions += 1
                parsed.append(GitDiffLine(id: parsed.count, kind: .deletion, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                parsed.append(GitDiffLine(id: parsed.count, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                parsed.append(GitDiffLine(id: parsed.count, kind: .meta, oldLineNumber: nil, newLineNumber: nil, text: line))
            }
        }

        return GitDiffDocument(
            path: path,
            previousPath: previousPath,
            scope: scope,
            comparisonLabel: comparisonLabel ?? scope.comparisonLabel,
            status: status,
            additions: additions,
            deletions: deletions,
            isBinary: isBinary,
            isEmpty: parsed.isEmpty && !isBinary,
            truncated: truncated,
            rawText: raw,
            lines: parsed,
            errorMessage: nil
        )
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int) {
        // Format: @@ -12,7 +14,9 @@ optional context
        var oldStart = 1
        var newStart = 1
        let parts = line.split(separator: " ", maxSplits: 3)
        for part in parts.dropFirst().prefix(2) {
            if part.hasPrefix("-"), let num = Int(part.dropFirst().split(separator: ",").first ?? "") {
                oldStart = num
            } else if part.hasPrefix("+"), let num = Int(part.dropFirst().split(separator: ",").first ?? "") {
                newStart = num
            }
        }
        return (oldStart, newStart)
    }

    static func commits(in directoryPath: String, limit: Int = 40, skip: Int = 0) async -> [GitCommitSummary] {
        let normalized = normalizedPath(directoryPath)
        return await Task.detached(priority: .utility) {
            commitsSync(directoryPath: normalized, limit: limit, skip: skip)
        }.value
    }

    private static func commitsSync(directoryPath: String, limit: Int, skip: Int) -> [GitCommitSummary] {
        let marker = "\u{1E}"
        let sep = "\u{1F}"
        let args = [
            "log",
            "--max-count=\(limit)",
            "--skip=\(skip)",
            "--shortstat",
            "--diff-merges=first-parent",
            "--find-renames",
            "--format=\(marker)%H\(sep)%h\(sep)%s\(sep)%an\(sep)%ct"
        ]
        let output = runGit(args, cwd: directoryPath)
        guard output.exitCode == 0 else { return [] }
        let records = output.stdoutString.split(separator: Character(marker), omittingEmptySubsequences: true)
        return records.compactMap { rawRecord -> GitCommitSummary? in
            let lines = rawRecord.split(separator: "\n", omittingEmptySubsequences: true)
            guard let headerLine = lines.first else { return nil }
            let fields = headerLine.split(separator: Character(sep), omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            let hash = String(fields[0])
            let shortHash = String(fields[1])
            let subject = String(fields[2])
            let author = String(fields[3])
            let timestamp = TimeInterval(fields[4]) ?? 0
            var filesChanged: Int?
            var additions: Int?
            var deletions: Int?
            if let statLine = lines.dropFirst().first(where: { $0.contains("file") || $0.contains("insertion") || $0.contains("deletion") }) {
                let text = String(statLine)
                filesChanged = firstRegexInt(#"(\d+)\s+file"#, in: text)
                additions = firstRegexInt(#"(\d+)\s+insertion"#, in: text)
                deletions = firstRegexInt(#"(\d+)\s+deletion"#, in: text)
                if filesChanged != nil {
                    additions = additions ?? 0
                    deletions = deletions ?? 0
                }
            }
            return GitCommitSummary(
                hash: hash,
                shortHash: shortHash,
                subject: subject,
                author: author,
                date: Date(timeIntervalSince1970: timestamp),
                filesChanged: filesChanged,
                additions: additions,
                deletions: deletions
            )
        }
    }

    private static func firstRegexInt(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func commitDetail(hash: String, in directoryPath: String) async -> GitCommitDetail? {
        let normalized = normalizedPath(directoryPath)
        return await Task.detached(priority: .userInitiated) {
            commitDetailSync(hash: hash, directoryPath: normalized)
        }.value
    }

    private static func commitDetailSync(hash: String, directoryPath: String) -> GitCommitDetail? {
        let sep = "\u{1F}"
        let meta = runGit(["show", "-s", "--format=%H\(sep)%h\(sep)%s\(sep)%an\(sep)%ct\(sep)%b", hash], cwd: directoryPath)
        guard meta.exitCode == 0 else { return nil }
        let fields = meta.stdoutString.split(separator: Character(sep), maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count >= 5 else { return nil }
        let body = fields.count > 5 ? String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        let args = ["-c", "diff.suppressBlankEmpty=false", "show", "--format=", "--diff-merges=first-parent", "--find-renames",
                    "--no-ext-diff", "--no-textconv", "--submodule=short"]
        let numstatOut = runGit(args + ["--numstat", "-z", hash], cwd: directoryPath)
        let statsMap = numstatOut.exitCode == 0 ? parseNumstatZ(numstatOut.stdout) : [:]

        let patchOut = runGit(args + ["--raw", "-z", "--patch", "--no-color", "--unified=3", hash], cwd: directoryPath)
        let patch = parsePatchOutput(patchOut.exitCode == 0 ? patchOut.stdout : Data())
        let files = patch.changes.map {
            GitCommitFileChange(path: $0.path, previousPath: $0.previousPath, status: $0.status,
                                stat: statsMap[$0.path] ?? GitLineStat(added: nil, deleted: nil, isBinary: false))
        }

        var totalAdd = 0
        var totalDel = 0
        var hasStats = false
        for file in files {
            if !file.stat.isBinary, let a = file.stat.added, let d = file.stat.deleted {
                totalAdd += a
                totalDel += d
                hasStats = true
            }
        }

        let shortHash = String(fields[1])
        let comparisonLabel = String(localized: "提交 \(shortHash)")
        let diffDocs = patch.files.map { file in
            parseUnifiedDiff(String(file.text), path: file.change.path, previousPath: file.change.previousPath,
                             scope: .workingTreeVsHEAD, status: file.change.status, comparisonLabel: comparisonLabel)
        }

        let summary = GitCommitSummary(
            hash: String(fields[0]),
            shortHash: shortHash,
            subject: String(fields[2]),
            author: String(fields[3]),
            date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
            filesChanged: files.count,
            additions: hasStats ? totalAdd : nil,
            deletions: hasStats ? totalDel : nil
        )
        return GitCommitDetail(summary: summary, body: body, files: files, diffDocuments: diffDocs, rawPatch: patch.text)
    }

    private struct DiffPathChange {
        let path: String
        let previousPath: String?
        let status: GitFileChangeStatus
        var patchSectionCount = 1
    }

    private static func parseDiffPathChanges(_ data: Data) -> [DiffPathChange] {
        let tokens = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [DiffPathChange] = []
        var index = 0
        while index + 1 < tokens.count {
            let code = tokens[index].split(separator: " ").last?.first
            let path = tokens[index + 1]
            index += 2
            if code == "R" || code == "C" {
                guard index < tokens.count else { break }
                result.append(.init(path: tokens[index], previousPath: path, status: code == "C" ? .added : .renamed))
                index += 1
            } else {
                let status: GitFileChangeStatus = switch code {
                case "A": .added
                case "D": .deleted
                case "U": .conflict
                default: .modified
                }
                result.append(.init(path: path, previousPath: nil, status: status, patchSectionCount: code == "T" ? 2 : 1))
            }
        }
        return result
    }

    private static func parsePatchOutput(_ data: Data)
        -> (text: String, changes: [DiffPathChange], files: [(change: DiffPathChange, text: Substring)]) {
        // Git separates NUL-terminated raw records from the patch with an additional NUL.
        guard let separator = data.range(of: Data([0, 0])) else { return ("", parseDiffPathChanges(data), []) }
        let changes = parseDiffPathChanges(data[..<separator.lowerBound])
        let text = String(decoding: data[separator.upperBound...], as: UTF8.self)
        let bytes = text.utf8
        let starts = bytes.split(separator: 0x0A).compactMap { line in
            line.starts(with: "diff --git ".utf8) ? line.startIndex : nil
        }
        guard starts.count == changes.reduce(0, { $0 + $1.patchSectionCount }) else { return (text, changes, []) }
        var files: [(DiffPathChange, Substring)] = []
        var index = 0
        for file in changes {
            let next = index + file.patchSectionCount
            let end = next < starts.count ? starts[next] : bytes.endIndex
            files.append((file, text[starts[index]..<end]))
            index = next
        }
        return (text, changes, files)
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
    struct CommitsState: Equatable {
        var commits: [GitCommitSummary] = []
        var isLoading = false
        var hasMore = true
    }

    private var states: [String: GitDirectoryState] = [:]
    private var commitStates: [String: CommitsState] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var commitTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let inspector: @Sendable (URL) async -> GitDirectoryState

    init(inspector: @escaping @Sendable (URL) async -> GitDirectoryState = { await GitRepositoryInspector.inspect(directory: $0) }) {
        self.inspector = inspector
    }

    func state(for directory: String) -> GitDirectoryState {
        states[GitRepositoryInspector.normalizedPath(directory)] ?? .idle
    }

    func commitsState(for directory: String) -> CommitsState {
        commitStates[GitRepositoryInspector.normalizedPath(directory)] ?? CommitsState()
    }

    func refreshCommits(directory: String, loadMore: Bool = false) {
        let key = GitRepositoryInspector.normalizedPath(directory)
        var current = commitStates[key] ?? CommitsState()
        if current.isLoading && loadMore { return }
        let pageSize = 30
        let skip = loadMore ? current.commits.count : 0
        commitTasks[key]?.cancel()
        current.isLoading = true
        commitStates[key] = current

        commitTasks[key] = Task { [weak self] in
            let fetched = await GitRepositoryInspector.commits(in: key, limit: pageSize, skip: skip)
            guard !Task.isCancelled, let self else { return }
            var updated = self.commitStates[key] ?? CommitsState()
            if loadMore {
                let existing = Set(updated.commits.map(\.hash))
                updated.commits.append(contentsOf: fetched.filter { !existing.contains($0.hash) })
            } else {
                updated.commits = fetched
            }
            updated.isLoading = false
            updated.hasMore = fetched.count >= pageSize
            self.commitStates[key] = updated
            self.commitTasks[key] = nil
        }
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
                        upstream: snapshot.upstream,
                        behindCount: snapshot.behindCount,
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
