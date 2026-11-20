import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Pi emits queue removal just before the user-message hook. Hold that removal
/// until its checkpoint can be assigned to the turn it is about to close.
struct PiTurnFileChanges {
    static let statusKey = "pikachu-turn-file-changes"

    let scratch: URL?
    private var folder: URL?
    private var baseline: String?
    private var queue = RuntimeQueue()
    private var pendingQueues: [RuntimeQueue] = []

    init(scratch: URL?) {
        self.scratch = scratch
    }

    mutating func map(_ record: Record, events: [AgentEvent]) -> [AgentEvent] {
        if record["type"] as? String == "extension_ui_request",
           record["method"] as? String == "setStatus",
           record["statusKey"] as? String == Self.statusKey {
            return checkpoint(record["statusText"] as? String)
        }

        guard !events.isEmpty else { return [] }
        var result: [AgentEvent] = []
        for event in events {
            if case .queue(let next) = event {
                let mayStartFollowUp = folder != nil && next.followUp.count < queue.followUp.count && next.steering == queue.steering
                queue = next
                if mayStartFollowUp || !pendingQueues.isEmpty {
                    pendingQueues.append(next)
                    continue
                }
            }
            result.append(contentsOf: pendingQueues.map(AgentEvent.queue))
            pendingQueues.removeAll()
            if case .settled = event { reset() }
            result.append(event)
        }
        return result
    }

    private mutating func checkpoint(_ text: String?) -> [AgentEvent] {
        guard let scratch, let text, let marker = try? JSONDecoder().decode(Checkpoint.self, from: Data(text.utf8)) else { return [] }
        let tree = marker.tree.flatMap { Self.validTree($0) ? $0 : nil }
        switch marker.phase {
        case .start:
            guard let name = marker.folder, name.wholeMatch(of: /round-[A-Za-z0-9]{6}/) != nil, let tree else { return [] }
            reset()
            folder = scratch.appendingPathComponent(name, isDirectory: true)
            baseline = tree
            return []
        case .user:
            guard !pendingQueues.isEmpty else { return [] }
        case .end:
            break
        }

        let start = baseline
        baseline = tree
        guard let start, let tree, start != tree, let folder,
              let changes = changes(from: start, to: tree, folder: folder) else { return [] }
        return [.turnFileChanges(changes)]
    }

    private mutating func reset() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        baseline = nil
    }

    private struct Checkpoint: Decodable {
        enum Phase: String, Decodable { case start, user, end }
        let phase: Phase
        let folder: String?
        let tree: String?
    }

    private static func validTree(_ hash: String) -> Bool {
        (hash.count == 40 || hash.count == 64) && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func changes(from: String, to: String, folder: URL) -> TurnFileChanges? {
        let options = ["--attr-source=\(to)", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
                       "--no-relative", "--find-renames", "-l1000"]
        guard let statistics = git(options + ["--raw", "--numstat", "-z", from, to, "--"], folder: folder) else { return nil }
        let files = Self.parseStatistics(statistics)
        return files.isEmpty ? nil : .init(files: files)
    }

    static func parseStatistics(_ data: Data) -> [TurnFileChanges.File] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        var paths: [(path: String, previousPath: String?, kind: TurnFileChanges.File.Kind)] = []
        while index < tokens.count, tokens[index].hasPrefix(":") {
            let status = tokens[index].split(separator: " ").last?.first
            let renamed = status == "R"
            guard index + (renamed ? 2 : 1) < tokens.count else { return [] }
            let path = tokens[index + 1]
            let kind: TurnFileChanges.File.Kind = switch status {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            paths.append((renamed ? tokens[index + 2] : path, renamed ? path : nil, kind))
            index += renamed ? 3 : 2
        }

        var counts: [String: (added: Int?, deleted: Int?)] = [:]
        while index < tokens.count {
            let fields = tokens[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { break }
            let renamed = fields[2].isEmpty
            guard index + (renamed ? 2 : 0) < tokens.count else { return [] }
            let path = renamed ? tokens[index + 2] : String(fields[2])
            counts[path] = (Int(fields[0]), Int(fields[1]))
            index += renamed ? 3 : 1
        }
        return paths.map { file in
            .init(path: file.path, previousPath: file.previousPath, kind: file.kind,
                  added: counts[file.path]?.added, deleted: counts[file.path]?.deleted)
        }
    }

    private func git(_ args: [String], folder: URL) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Diff only the captured trees. Using the real worktree can let Git
        // reuse a working file and invoke its configured clean filter.
        process.arguments = ["--no-optional-locks", "--git-dir=\(folder.path)", "-c", "core.quotePath=false"] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_NO_LAZY_FETCH"] = "1"
        process.environment = env
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A large diff can be expensive even when its summary is small. Do not
        // let optional statistics stall delivery of the queue or settled event.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(1_500), execute: timeout)
        defer { timeout.cancel() }

        var data = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if data.count + chunk.count > 4 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
