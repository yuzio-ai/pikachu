import Foundation
import XCTest
@testable import Zivvi

@MainActor final class ProjectResourceSourcesTests: XCTestCase {
    func testProjectWorktreeAndUserSourcesStayInTheirOwnScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = root.appendingPathComponent("repository", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try write("repository/.git", under: root)
        try write("worktree/.git", under: root)
        try write("AGENTS.md", under: root)
        try write("agent/AGENTS.override.md", under: root)
        try write("repository/AGENTS.md", under: root)
        try write("worktree/CLAUDE.md", under: root)
        try write("repository/.agents/skills/project-only/SKILL.md", under: root)
        try write("worktree/.agents/skills/worktree-only/SKILL.md", under: root)
        try write("agent/skills/agent-only/SKILL.md", under: root)
        try write("home/.agents/skills/home-only/SKILL.md", under: root)

        let project = await ProjectResourceSources.inspect(directory: repo, home: home)
        XCTAssertEqual(Set(project.skills.entries.map(\.name)), ["project-only", "home-only"])
        XCTAssertEqual(project.rules.entries.first { $0.url.path == repo.resolvingSymlinksInPath().appendingPathComponent("AGENTS.md").path }?.scope, .project)
        XCTAssertFalse(project.rules.entries.contains { $0.name == "AGENTS.override.md" && $0.scope == .user })
        let checkedWorktree = await ProjectResourceSources.inspect(directory: worktree, home: home)
        XCTAssertEqual(Set(checkedWorktree.skills.entries.map(\.name)), ["worktree-only", "home-only"])
        XCTAssertTrue(checkedWorktree.rules.entries.contains { $0.name == "CLAUDE.md" && $0.scope == .project })
        XCTAssertTrue(checkedWorktree.rules.entries.contains { $0.name == "AGENTS.md" && $0.scope == .parent })
        XCTAssertFalse(checkedWorktree.rules.entries.contains { $0.url.path.contains("/repository/") })
    }

    func testSkillsScopeDoesNotFollowLinksOrVisitBeyondLimit() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try write("outside/linked/SKILL.md", under: root)
        try write("home/.agents/skills/available/SKILL.md", under: root)
        try write("project/.agents/skills/normal/SKILL.md", under: root)
        let deepPath = Array(repeating: "directory", count: 13).joined(separator: "/")
        try write("project/.agents/skills/\(deepPath)/SKILL.md", under: root)
        try fm.createSymbolicLink(at: project.appendingPathComponent(".agents/skills/linked"),
                                  withDestinationURL: root.appendingPathComponent("outside/linked"))
        try fm.createSymbolicLink(at: root.appendingPathComponent(".agents"),
                                  withDestinationURL: root.appendingPathComponent("outside"))
        let report = await ProjectResourceSources.inspect(directory: project, home: home)
        XCTAssertEqual(Set(report.skills.entries.map(\.name)), ["available", "normal"])
        XCTAssertTrue(report.skills.truncated)
    }

    private func write(_ path: String, under root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: file)
    }
}
