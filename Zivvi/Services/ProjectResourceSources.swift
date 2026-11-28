import Foundation

struct ProjectResourceSources: Sendable {
    enum Scope: String, Sendable { case project, parent, user }

    struct Entry: Identifiable, Sendable {
        let name: String
        let url: URL
        let scope: Scope
        var id: String { url.path }
    }

    struct Report: Sendable {
        var entries: [Entry] = []
        var failedLocations = 0
        var checkedLocations = 0
        var truncated = false

        var failed: Bool { failedLocations > 0 && checkedLocations == 0 }
    }

    let rules: Report
    let skills: Report

    static func inspect(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> Self {
        let work = Task.detached(priority: .utility) {
            let cwd = directory.standardizedFileURL.resolvingSymlinksInPath()
            let userHome = home.standardizedFileURL.resolvingSymlinksInPath()
            let ancestors = Self.ancestors(of: cwd)
            return Self(rules: scanRules(ancestors), skills: scanSkills(ancestors, home: userHome))
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func ancestors(of cwd: URL) -> [URL] {
        var result = [cwd]
        var current = cwd
        while current.path != "/" {
            current.deleteLastPathComponent()
            result.append(current)
        }
        return result
    }

    private static func scanRules(_ ancestors: [URL]) -> Report {
        let names: Set<String> = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
        let locations: [(URL, Scope)] = ancestors.enumerated().map { ($0.element, $0.offset == 0 ? .project : .parent) }
        var report = Report()
        var seen: Set<String> = []
        let fileManager = FileManager.default
        for (directory, scope) in locations where !Task.isCancelled {
            do {
                let filenames = try fileManager.contentsOfDirectory(atPath: directory.path)
                report.checkedLocations += 1
                for name in filenames.sorted() where names.contains(name) {
                    let url = directory.appendingPathComponent(name)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true, values.isSymbolicLink != true, seen.insert(url.path).inserted {
                        report.entries.append(.init(name: name, url: url, scope: scope))
                    }
                }
            } catch let error as CocoaError where scope == .user && error.code == .fileReadNoSuchFile {
                report.checkedLocations += 1
            } catch {
                report.failedLocations += 1
            }
        }
        return report
    }

    private static func scanSkills(_ ancestors: [URL], home: URL) -> Report {
        let fileManager = FileManager.default
        let repoIndex = ancestors.firstIndex { fileManager.fileExists(atPath: $0.appendingPathComponent(".git").path) } ?? 0
        let projectLocations = ancestors.prefix(repoIndex + 1).enumerated().map { index, directory in
            (directory.appendingPathComponent(".agents/skills", isDirectory: true), index == 0 ? Scope.project : .parent)
        }
        let locations = projectLocations + [
            (home.appendingPathComponent(".agents/skills", isDirectory: true), .user)
        ]
        var report = Report()
        var scannedPaths: Set<String> = []
        var seenEntries: Set<String> = []
        var visited = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for (root, scope) in locations {
            guard !Task.isCancelled else { break }
            guard scannedPaths.insert(root.path).inserted else { continue }
            do {
                let rootValues = try root.resourceValues(forKeys: keys)
                guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                      root.resolvingSymlinksInPath().path == root.path else {
                    report.failedLocations += 1
                    continue
                }
                guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in
                        report.failedLocations += 1
                        return true
                    }) else {
                    report.failedLocations += 1
                    continue
                }
                report.checkedLocations += 1
                for case let url as URL in walker {
                    guard !Task.isCancelled else { break }
                    visited += 1
                    guard visited <= 4_000, report.entries.count < 200 else {
                        report.truncated = true
                        break
                    }
                    do {
                        let values = try url.resourceValues(forKeys: keys)
                        if values.isSymbolicLink == true {
                            walker.skipDescendants()
                            continue
                        }
                        if values.isDirectory == true, walker.level >= 12 {
                            walker.skipDescendants()
                            report.truncated = true
                        }
                        if values.isRegularFile == true, url.lastPathComponent == "SKILL.md", seenEntries.insert(url.path).inserted {
                            report.entries.append(.init(name: url.deletingLastPathComponent().lastPathComponent, url: url, scope: scope))
                        }
                    } catch {
                        report.failedLocations += 1
                    }
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                report.checkedLocations += 1
            } catch {
                report.failedLocations += 1
            }
        }
        report.entries.sort { $0.url.path < $1.url.path }
        return report
    }
}
