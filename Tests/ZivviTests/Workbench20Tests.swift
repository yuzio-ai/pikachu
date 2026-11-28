import Foundation
import CoreGraphics
import Darwin
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

final class Workbench20Tests: XCTestCase {

    // MARK: - Progressive Markdown Rendering

    func testProgressiveMarkdownSplitsStableBlocksAndSemanticSkeleton() {
        // 1. ATX Heading + paragraph + unclosed fenced code block -> .code skeleton
        let streamingCode = """
        # Workbench 2.0

        This is a completed paragraph.

        ```swift
        func hello() {
            print("streaming
        """
        let codeSplit = ProgressiveMarkdownSplitter.split(streamingCode, isStreaming: true)
        XCTAssertTrue(codeSplit.stableSource.contains("# Workbench 2.0"))
        XCTAssertTrue(codeSplit.stableSource.contains("This is a completed paragraph."))
        XCTAssertFalse(codeSplit.stableSource.contains("func hello"))
        XCTAssertEqual(codeSplit.skeletonKind, .code)

        // 2. Closed fenced code block commits immediately
        let closedCode = streamingCode + "\")\n}\n```\n"
        let closedSplit = ProgressiveMarkdownSplitter.split(closedCode, isStreaming: true)
        XCTAssertTrue(closedSplit.stableSource.contains("func hello()"))
        XCTAssertNil(closedSplit.skeletonKind)

        // 3. Progressive table: header + separator + complete row committed, partial tail gets .table skeleton
        let streamingTable = """
        | File | Status |
        | --- | --- |
        | `main.swift` | Added |
        | `app.swift` | Pen
        """
        let tableSplit = ProgressiveMarkdownSplitter.split(streamingTable, isStreaming: true)
        XCTAssertTrue(tableSplit.stableSource.contains("main.swift"))
        XCTAssertFalse(tableSplit.stableSource.contains("Pen"))
        XCTAssertEqual(tableSplit.skeletonKind, .table)

        // 4. List items commit previous completed items and show .list skeleton for active item
        let streamingList = """
        - First item completed
        - Second item completed
        - Third item still typ
        """
        let listSplit = ProgressiveMarkdownSplitter.split(streamingList, isStreaming: true)
        XCTAssertTrue(listSplit.stableSource.contains("First item completed"))
        XCTAssertTrue(listSplit.stableSource.contains("Second item completed"))
        XCTAssertEqual(listSplit.skeletonKind, .list)

        // 5. Final non-streaming pass returns full source with nil skeleton & matches MarkdownBlocks.parse
        let fullRefDoc = """
        Read [the spec][spec] carefully.

        [spec]: https://example.com/spec
        """
        let finalSplit = ProgressiveMarkdownSplitter.split(fullRefDoc, isStreaming: false)
        XCTAssertEqual(finalSplit.stableSource, fullRefDoc)
        XCTAssertNil(finalSplit.skeletonKind)
        XCTAssertEqual(MarkdownBlocks.parse(finalSplit.stableSource), MarkdownBlocks.parse(fullRefDoc))
    }

    @MainActor
    func testMarkdownStreamingStateClearsSkeletonOnStreamEndAndPreservesFullContent() async throws {
        let state = MarkdownStreamingState(interval: .milliseconds(10), skeletonDelay: .milliseconds(10))
        let partial = "# 标题\n\n第一段已完成。\n\n```swift\nlet x = 1"
        state.submit(.init(text: partial, streaming: true))

        let deadline = ContinuousClock.now + .seconds(2)
        while state.snapshot == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        let midSnapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(midSnapshot.skeletonKind, .code)
        XCTAssertFalse(midSnapshot.blocks.isEmpty)

        // Stream finishes (or is interrupted/cancelled) with unclosed code -> skeleton clears and full text parses
        state.submit(.init(text: partial, streaming: false))
        let endDeadline = ContinuousClock.now + .seconds(2)
        while (state.snapshot?.skeletonKind != nil || state.showsSkeleton) && ContinuousClock.now < endDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(state.showsSkeleton)
        XCTAssertNil(state.snapshot?.skeletonKind)
        XCTAssertEqual(state.snapshot?.stableSource, partial)
    }

    // MARK: - Git Service (Net HEAD Stats, Diff, Commits)

    func testGitNumstatZAndPorcelainParsing() {
        let porcelain = [
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 abcdef1 abcdef2 Sources/Staged.swift",
            "1 .M N... 100644 100644 100644 abcdef1 abcdef2 Sources/Unstaged.swift",
            "1 MM N... 100644 100644 100644 abcdef1 abcdef2 Sources/Both.swift",
            "? Sources/NewFile.swift",
            "u UU N... 100644 100644 100644 100644 abcdef1 abcdef2 abcdef3 Sources/Conflict.swift"
        ].joined(separator: "\0") + "\0"

        let snapshot = GitRepositoryInspector.parsePorcelainV2(
            Data(porcelain.utf8),
            directoryPath: "/tmp/repo",
            checkoutRoot: "/tmp/repo",
            updatedAt: .now
        )
        XCTAssertEqual(snapshot.branch, .branch(name: "main", hasCommits: true))
        XCTAssertEqual(snapshot.upstream, "origin/main")
        XCTAssertEqual(snapshot.behindCount, 1)
        XCTAssertEqual(snapshot.changes.stagedChanges.count, 2)
        XCTAssertEqual(snapshot.changes.unstagedChanges.count, 2)
        XCTAssertEqual(snapshot.changes.untrackedChanges.count, 1)
        XCTAssertEqual(snapshot.changes.conflictChanges.count, 1)
        XCTAssertEqual(snapshot.changes.fileStatuses["Sources/Conflict.swift"], .conflict)
        XCTAssertEqual(snapshot.changes.fileStatuses["Sources/NewFile.swift"], .untracked)

        let numstat = "12\t3\tSources/App.swift\0-\t-\tAssets/icon.png\0"
        let stats = GitRepositoryInspector.parseNumstatZ(Data(numstat.utf8))
        XCTAssertEqual(stats["Sources/App.swift"], GitLineStat(added: 12, deleted: 3, isBinary: false))
        XCTAssertEqual(stats["Assets/icon.png"], GitLineStat(added: nil, deleted: nil, isBinary: true))
    }

    @MainActor
    func testGitRealRepoNetHeadStatsNoDoubleCountingAndDiffCommits() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zivvi-git-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func git(_ args: [String], expecting status: Int32 = 0) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = tempDir
            var env = ProcessInfo.processInfo.environment
            env["GIT_AUTHOR_NAME"] = "Zivvi Test"
            env["GIT_AUTHOR_EMAIL"] = "test@zivvi.local"
            env["GIT_COMMITTER_NAME"] = "Zivvi Test"
            env["GIT_COMMITTER_EMAIL"] = "test@zivvi.local"
            process.environment = env
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, status, "git \(args.joined(separator: " ")) returned an unexpected status")
        }

        try git(["init", "-b", "main"])
        try git(["config", "core.autocrlf", "false"])
        let srcDir = tempDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let appFile = srcDir.appendingPathComponent("App.swift")
        try "line1\nline2\nline3\n".write(to: appFile, atomically: true, encoding: .utf8)
        try git(["add", "Sources/App.swift"])
        try git(["commit", "-m", "Initial commit"])

        // Stage a 2-line addition AND also make an unstaged 1-line addition on the SAME file.
        // Net HEAD diff should be +3 (not +2 + +1 double-counted into +5).
        try "line1\nline2\nline3\nstaged1\nstaged2\n".write(to: appFile, atomically: true, encoding: .utf8)
        try git(["add", "Sources/App.swift"])
        try "line1\nline2\nline3\nstaged1\nstaged2\nunstaged1\n".write(to: appFile, atomically: true, encoding: .utf8)

        // Add an untracked 4-line UTF-8 file
        let newFile = srcDir.appendingPathComponent("Notes.md")
        try "# Notes\nA\nB\nC\n".write(to: newFile, atomically: true, encoding: .utf8)

        let result = await GitRepositoryInspector.inspect(directory: srcDir)
        let repo = try XCTUnwrap(result.snapshot, "Expected git repository snapshot")
        XCTAssertEqual(repo.changes.fileStats["Sources/App.swift"]?.added, 3)
        XCTAssertEqual(repo.changes.fileStats["Sources/App.swift"]?.deleted, 0)
        XCTAssertEqual(repo.changes.fileStats["Sources/Notes.md"]?.added, 4)
        XCTAssertEqual(repo.changes.directoryStats["Sources"]?.added, 7)
        XCTAssertEqual(repo.changes.totalAdditions, 7)

        // Diff for unstaged change
        let unstagedDiff = await GitRepositoryInspector.fileDiff(path: "Sources/App.swift", scope: .unstagedVsIndex, in: tempDir.path)
        XCTAssertEqual(unstagedDiff.additions, 1)
        XCTAssertTrue(unstagedDiff.lines.contains { $0.kind == .addition && $0.text == "unstaged1" })

        // Diff for untracked file
        let untrackedDiff = await GitRepositoryInspector.fileDiff(path: "Sources/Notes.md", scope: .untrackedNewFile, in: tempDir.path)
        XCTAssertEqual(untrackedDiff.additions, 4)
        let model = WorkbenchTabsModel()
        let project = ProjectRecord(id: UUID(), path: srcDir.path)
        model.openGitDiff(project: project, change: try XCTUnwrap(repo.changes.untrackedChanges.first),
                          checkoutRoot: repo.checkoutRoot)
        let diffTab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { diffTab.diffDocument != nil }
        XCTAssertEqual(diffTab.diffDocument?.additions, 4)

        // Commits & Commit detail
        let commits = await GitRepositoryInspector.commits(in: tempDir.path, limit: 10, skip: 0)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "Initial commit")
        let detail = await GitRepositoryInspector.commitDetail(hash: commits[0].hash, in: tempDir.path)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.files.first?.path, "Sources/App.swift")

        let literal = ":(glob)*.txt"
        try Data("literal path content\n".utf8).write(to: tempDir.appendingPathComponent(literal))
        try Data("another file\n".utf8).write(to: tempDir.appendingPathComponent("other.txt"))
        try git(["--literal-pathspecs", "add", "--", literal, "other.txt"])
        let literalDiff = await GitRepositoryInspector.fileDiff(path: literal, scope: .stagedVsHEAD, in: tempDir.path)
        XCTAssertEqual(literalDiff.lines.filter { $0.kind == .addition }.map(\.text), ["literal path content"])

        let stagedAdd = GitFileChange(path: literal, previousPath: nil, status: .added,
                                      scope: .stagedVsHEAD, stat: .zero)
        model.openGitDiff(project: project, change: stagedAdd, checkoutRoot: repo.checkoutRoot)
        let stagedTab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { stagedTab.diffDocument != nil }
        try git(["add", "--", "Sources/Notes.md"])
        model.reloadTab(diffTab)
        try await waitForEditor { !diffTab.isLoadingDiff }
        XCTAssertEqual(diffTab.diffDocument?.additions, 0)
        XCTAssertNil(diffTab.diffDocument?.status)

        try git(["commit", "-m", "Fixture files"])
        try git(["mv", "--", "other.txt", "renamed.txt"])
        let stagedRename = GitFileChange(path: "renamed.txt", previousPath: "other.txt", status: .renamed,
                                         scope: .stagedVsHEAD, stat: .zero)
        model.openGitDiff(project: project, change: stagedRename, checkoutRoot: repo.checkoutRoot)
        let renamedTab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { !renamedTab.isLoadingDiff }
        XCTAssertEqual(renamedTab.diffDocument?.previousPath, "other.txt")
        XCTAssertEqual(renamedTab.diffDocument?.status, .renamed)

        try git(["mv", "--", "renamed.txt", "other.txt"])
        try Data("separate old file change\n".utf8).write(to: tempDir.appendingPathComponent("other.txt"))
        try Data("separate new file\n".utf8).write(to: tempDir.appendingPathComponent("renamed.txt"))
        try git(["add", "--", "other.txt", "renamed.txt"])
        model.reloadTab(renamedTab)
        try await waitForEditor { !renamedTab.isLoadingDiff }
        XCTAssertNil(renamedTab.diffDocument?.previousPath)
        XCTAssertEqual(renamedTab.diffDocument?.status, .added)
        if case .gitDiff(_, _, _, _, let previousPath, _, let status) = renamedTab.kind {
            XCTAssertNil(previousPath)
            XCTAssertEqual(status, .added)
        } else { XCTFail("Expected a Git Diff tab") }
        XCTAssertFalse(renamedTab.diffDocument?.rawText.contains("separate old file change") ?? true)

        for (path, text) in [("测试一.txt", "first\r\nsecond\r\n"), ("测试二.txt", "third\r\nfourth\r\n")] {
            try Data(text.utf8).write(to: tempDir.appendingPathComponent(path))
            let untracked = await GitRepositoryInspector.fileDiff(path: path, scope: .untrackedNewFile, in: tempDir.path)
            XCTAssertEqual(untracked.lines.map(\.newLineNumber), [1, 2])
            try git(["add", "--", path])
            let staged = await GitRepositoryInspector.fileDiff(path: path, scope: .stagedVsHEAD, in: tempDir.path)
            XCTAssertEqual(staged.lines.filter { $0.kind == .addition }.map(\.newLineNumber), [1, 2])
        }
        let blankPath = "blank-lines.txt"
        let blankURL = tempDir.appendingPathComponent(blankPath)
        try Data("alpha\n\nbefore\n".utf8).write(to: blankURL)
        try git(["add", "--", blankPath])
        try git(["commit", "-m", "Quoted paths"])
        let latest = await GitRepositoryInspector.commits(in: tempDir.path, limit: 1, skip: 0)
        let latestHash = try XCTUnwrap(latest.first?.hash)
        let quotedDetail = await GitRepositoryInspector.commitDetail(hash: latestHash, in: tempDir.path)
        let docs = try XCTUnwrap(quotedDetail?.diffDocuments)
        for (path, text) in [("测试一.txt", "first\r"), ("测试二.txt", "third\r")] {
            let doc = try XCTUnwrap(docs.first { $0.path == path })
            XCTAssertTrue(doc.lines.contains { $0.kind == .addition && $0.text == text })
        }

        try git(["config", "diff.suppressBlankEmpty", "true"])
        let linkName = "测试一.txt"
        let linkURL = tempDir.appendingPathComponent(linkName)
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "other.txt")
        try Data("alpha\n\nafter\n".utf8).write(to: blankURL)
        let blankDiff = await GitRepositoryInspector.fileDiff(path: blankPath, scope: .unstagedVsIndex, in: tempDir.path)
        XCTAssertEqual(blankDiff.lines.first { $0.kind == .addition }?.newLineNumber, 3)
        try git(["add", "--", linkName, blankPath])
        try git(["commit", "-m", "File type change and blank context"])
        let typeCommits = await GitRepositoryInspector.commits(in: tempDir.path, limit: 1, skip: 0)
        let typeHash = try XCTUnwrap(typeCommits.first?.hash)
        let typeDetail = await GitRepositoryInspector.commitDetail(hash: typeHash, in: tempDir.path)
        let typeDocs = try XCTUnwrap(typeDetail?.diffDocuments)
        let typeDoc = try XCTUnwrap(typeDocs.first { $0.path == linkName })
        XCTAssertEqual(typeDoc.additions, 1)
        XCTAssertEqual(typeDoc.deletions, 2)
        XCTAssertEqual(typeDocs.first { $0.path == blankPath }?.lines.first { $0.kind == .addition }?.newLineNumber, 3)

        try git(["rm", "--cached", "--", "other.txt"])
        let recreated = await GitRepositoryInspector.inspect(directory: tempDir).snapshot
        XCTAssertTrue(recreated?.changes.stagedChanges.contains { $0.path == "other.txt" && $0.status == .deleted } == true)
        XCTAssertTrue(recreated?.changes.untrackedChanges.contains { $0.path == "other.txt" } == true)
        XCTAssertEqual(recreated?.changes.fileStatuses["other.txt"], .modified)

        let flatPath = "former-file"
        let flat = tempDir.appendingPathComponent(flatPath)
        try Data("original file contents\n".utf8).write(to: flat)
        try git(["add", "--", flatPath])
        try git(["commit", "-m", "Track a flat file"])
        try FileManager.default.removeItem(at: flat)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: false)
        try Data("different child contents\n".utf8).write(to: flat.appendingPathComponent("child.txt"))
        try git(["add", "-A", "--", flatPath])
        let flatDiff = await GitRepositoryInspector.fileDiff(path: flatPath, scope: .stagedVsHEAD, in: tempDir.path)
        XCTAssertEqual(flatDiff.status, .deleted)
        XCTAssertEqual(flatDiff.lines.filter { $0.kind == .deletion }.map(\.text), ["original file contents"])
        XCTAssertFalse(flatDiff.rawText.contains("different child contents"))

        try git(["config", "status.renames", "false"])
        let renamedPath = "moved-child.txt"
        let originalPath = "\(flatPath)/child.txt"
        try git(["commit", "-m", "Replace file with directory"])
        try git(["mv", "--", originalPath, renamedPath])
        let noRenames = await GitRepositoryInspector.inspect(directory: tempDir).snapshot
        XCTAssertTrue(noRenames?.changes.stagedChanges.contains { $0.path == originalPath && $0.status == .deleted } == true)
        XCTAssertEqual(noRenames?.changes.stagedChanges.first { $0.path == originalPath }?.stat?.deleted, 1)
        XCTAssertEqual(noRenames?.changes.stagedChanges.first { $0.path == renamedPath }?.stat?.added, 1)
        let sourceDiff = await GitRepositoryInspector.fileDiff(path: originalPath, scope: .stagedVsHEAD, in: tempDir.path)
        XCTAssertEqual(sourceDiff.status, .deleted)
        XCTAssertGreaterThan(sourceDiff.deletions, 0)
        try git(["commit", "-m", "Move the tracked file"])

        try git(["checkout", "-b", "side"])
        try Data("side change\n".utf8).write(to: tempDir.appendingPathComponent("side.txt"))
        try git(["add", "--", "side.txt"])
        try git(["commit", "-m", "Side change"])
        try git(["checkout", "main"])
        try Data("main change\n".utf8).write(to: tempDir.appendingPathComponent("main.txt"))
        try git(["add", "--", "main.txt"])
        try git(["commit", "-m", "Main change"])
        try git(["merge", "--no-ff", "-m", "Merge fixture branch", "side"])
        let mergeCommits = await GitRepositoryInspector.commits(in: tempDir.path, limit: 1, skip: 0)
        let mergeHash = try XCTUnwrap(mergeCommits.first?.hash)
        let merge = await GitRepositoryInspector.commitDetail(hash: mergeHash, in: tempDir.path)
        XCTAssertEqual(merge?.files.map(\.path), ["side.txt"])
        XCTAssertEqual(merge?.diffDocuments.first?.lines.first { $0.kind == .addition }?.text, "side change")
        XCTAssertEqual(mergeCommits.first?.filesChanged, merge?.summary.filesChanged)
        XCTAssertEqual(mergeCommits.first?.additions, merge?.summary.additions)

        try git(["config", "status.renames", "copies"])
        let copySource = "copy-source.txt"
        let sourceURL = tempDir.appendingPathComponent(copySource)
        let sourceLines = (1...100).map { "original line \($0)" }
        try Data((sourceLines.joined(separator: "\n") + "\n").utf8).write(to: sourceURL)
        try git(["add", "--", copySource])
        try git(["commit", "-m", "Add copy source"])
        try git(["mv", "--", copySource, "renamed-source.txt"])
        let copyName = "copied-source.txt"
        let copied = sourceLines.prefix(75) + ["extra copy line"]
        try Data((copied.joined(separator: "\n") + "\n").utf8).write(to: tempDir.appendingPathComponent(copyName))
        try git(["add", "--", copyName])
        let copySnapshot = await GitRepositoryInspector.inspect(directory: tempDir).snapshot
        let copy = copySnapshot?.changes.stagedChanges.first { $0.path == copyName }
        XCTAssertEqual(copy?.status, .added)
        XCTAssertEqual(copy?.previousPath, copySource)
        let copyDiff = await GitRepositoryInspector.fileDiff(path: copyName, scope: .stagedVsHEAD, in: tempDir.path)
        XCTAssertEqual(copyDiff.status, .added)
        XCTAssertEqual(copyDiff.previousPath, copySource)
        XCTAssertTrue(copyDiff.rawText.contains("copy from \(copySource)"))
        XCTAssertFalse(copyDiff.rawText.contains("rename from"))

        try git(["commit", "-m", "Rename and copy fixture"])
        let conflictPath = "conflict.txt"
        let conflictURL = tempDir.appendingPathComponent(conflictPath)
        let ordinaryPath = "ordinary.txt"
        let ordinaryURL = tempDir.appendingPathComponent(ordinaryPath)
        try Data("base conflict\n".utf8).write(to: conflictURL)
        try Data("base ordinary\n".utf8).write(to: ordinaryURL)
        try git(["add", "--", conflictPath, ordinaryPath])
        try git(["commit", "-m", "Base for conflict"])
        try git(["checkout", "-b", "conflicting-side"])
        try Data("side conflict\n".utf8).write(to: conflictURL)
        try git(["commit", "-am", "Side conflict"])
        try git(["checkout", "main"])
        try Data("main conflict\n".utf8).write(to: conflictURL)
        try git(["commit", "-am", "Main conflict"])
        try git(["merge", "--no-ff", "conflicting-side"], expecting: 1)
        try Data("staged ordinary\n".utf8).write(to: ordinaryURL)
        try git(["add", "--", ordinaryPath])
        try Data("unstaged ordinary\n".utf8).write(to: ordinaryURL)
        for (scope, text) in [(GitDiffScope.stagedVsHEAD, "staged ordinary"), (.unstagedVsIndex, "unstaged ordinary")] {
            let ordinaryDiff = await GitRepositoryInspector.fileDiff(path: ordinaryPath, scope: scope, in: tempDir.path)
            XCTAssertEqual(ordinaryDiff.lines.filter { $0.kind == .addition }.map(\.text), [text])
            XCTAssertFalse(ordinaryDiff.rawText.contains(conflictPath))
        }
        let conflictDiff = await GitRepositoryInspector.fileDiff(path: conflictPath, scope: .workingTreeVsHEAD, in: tempDir.path)
        XCTAssertTrue(conflictDiff.rawText.contains("side conflict"))
    }

    func testGitHunkLineNumbersIgnoreNumbersInSectionTitle() {
        let diff = GitRepositoryInspector.parseUnifiedDiff(
            "@@ -8,1 +12,1 @@ Section -42 +84\n-before\n+after\n",
            path: "test.txt", previousPath: nil, scope: .unstagedVsIndex, status: .modified)
        XCTAssertEqual(diff.lines.first { $0.kind == .deletion }?.oldLineNumber, 8)
        XCTAssertEqual(diff.lines.first { $0.kind == .addition }?.newLineNumber, 12)
    }

    // MARK: - Safe File Editing & Conflict Protection

    func testProjectFilesReaderDetectsExternalConflictWithoutOverwriting() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zivvi-edit-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let reader = ProjectFilesReader()
        let root = try await reader.bindRoot(at: tempDir.path)
        let path = try XCTUnwrap(ProjectFilePath.relativePath(from: fileURL, within: tempDir.path))
        let preview = try await reader.read(at: root, path: path)
        let originalRevision = try XCTUnwrap(preview.revision)

        // Clean save succeeds
        let outcome1 = try await reader.write(at: root, path: path, content: "# Edited v1\n",
                                              expectedRevision: originalRevision, forceOverwrite: false)
        XCTAssertEqual(outcome1.document.text, "# Edited v1\n")

        // Simulate external Agent modification on disk
        try "# Modified By Agent\n".write(to: fileURL, atomically: true, encoding: .utf8)

        // Saving with stale revision MUST throw .conflict and NOT overwrite disk
        do {
            _ = try await reader.write(at: root, path: path, content: "# User Draft v2\n",
                                       expectedRevision: outcome1.revision, forceOverwrite: false)
            XCTFail("Expected conflict when disk changed externally")
        } catch let ProjectFileWriteFailure.conflict(diskDoc, _) {
            XCTAssertEqual(diskDoc?.text, "# Modified By Agent\n")
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Modified By Agent\n")

        // Explicit force overwrite succeeds
        let outcome3 = try await reader.write(at: root, path: path, content: "# User Draft v2\n",
                                              expectedRevision: outcome1.revision, forceOverwrite: true)
        XCTAssertEqual(outcome3.document.text, "# User Draft v2\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# User Draft v2\n")
    }

    func testFileSaveReplacesInodeAndPreservesEncodingAndPermissions() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unicode.txt")
        let original = Data([0xFE, 0xFF]) + (try XCTUnwrap("原文".data(using: .utf16BigEndian)))
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let oldFile = try FileHandle(forReadingFrom: url)
        defer { try? oldFile.close() }

        let reader = ProjectFilesReader()
        let root = try await reader.bindRoot(at: directory.path)
        let path = try XCTUnwrap(ProjectFilePath.relativePath(from: url, within: directory.path))
        let preview = try await reader.read(at: root, path: path)
        let revision = try XCTUnwrap(preview.revision)
        let outcome = try await reader.write(at: root, path: path, content: "修改后的文字",
                                             expectedRevision: revision, forceOverwrite: false)
        XCTAssertNotEqual(outcome.revision.inode, revision.inode)
        XCTAssertEqual(try oldFile.readToEnd(), original)
        let saved = try Data(contentsOf: url)
        XCTAssertTrue(saved.starts(with: [0xFE, 0xFF]))
        XCTAssertEqual(String(data: saved, encoding: .utf16), "修改后的文字")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
        try await reader.validateOpenTarget(outcome.openTarget)
    }

    func testFileSaveRestoresExternalVersionWrittenAfterFinalCheck() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: url)
        let reader = ProjectFilesReader(beforeReplacingFile: {
            try Data("late external version".utf8).write(to: url, options: .atomic)
        })
        let root = try await reader.bindRoot(at: directory.path)
        let path = ProjectFilePath(components: [url.lastPathComponent])
        let revision = try await reader.checkRevision(at: root, path: path)
        do {
            _ = try await reader.write(at: root, path: path, content: "user draft",
                                       expectedRevision: revision, forceOverwrite: false)
            XCTFail("The exchange displaced an external revision")
        } catch ProjectFileWriteFailure.conflict(let document, let conflictRevision) {
            XCTAssertEqual(document?.text, "late external version")
            let currentRevision = try await reader.checkRevision(at: root, path: path)
            XCTAssertEqual(conflictRevision, currentRevision)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "late external version")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    func testFileSaveRollsBackWhenParentMovesAfterFinalCheck() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("src", isDirectory: true)
        let moved = directory.appendingPathComponent("src-old", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let url = parent.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: url)
        let reader = ProjectFilesReader(beforeReplacingFile: {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data("new directory version".utf8).write(to: url)
        })
        let root = try await reader.bindRoot(at: directory.path)
        let path = ProjectFilePath(components: ["src", url.lastPathComponent])
        let revision = try await reader.checkRevision(at: root, path: path)
        do {
            _ = try await reader.write(at: root, path: path, content: "user draft",
                                       expectedRevision: revision, forceOverwrite: false)
            XCTFail("The original parent moved during the save")
        } catch ProjectFileWriteFailure.issue(.replaced) { }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new directory version")
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent(url.lastPathComponent), encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [url.lastPathComponent])
    }

    func testFileSaveLeavesOriginalWhenStagingCannotBeCreated() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission checks require an unprivileged user") }
        let directory = try makeEditorTestDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let reader = ProjectFilesReader()
        let root = try await reader.bindRoot(at: directory.path)
        let path = try XCTUnwrap(ProjectFilePath.relativePath(from: url, within: directory.path))
        let revision = try await reader.checkRevision(at: root, path: path)
        do {
            _ = try await reader.write(at: root, path: path, content: "replace", expectedRevision: revision, forceOverwrite: false)
            XCTFail("Expected staging to fail in a read-only directory")
        } catch ProjectFileWriteFailure.issue(.permission) { }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    @MainActor
    func testDirtyFileRemainsEditableWhenDiskFileDisappearsAndReturns() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = ProjectFilePath(components: ["notes.txt"])
        let url = directory.appendingPathComponent(path.name)
        try Data("original".utf8).write(to: url)
        let project = ProjectRecord(id: UUID(), path: directory.path)
        let model = WorkbenchTabsModel()
        model.openFile(project: project, entry: .init(path: path, kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { tab.savedDocument != nil }
        model.updateDraft("draft", for: tab)

        for external in [nil, Data([0]), Data(repeating: 65, count: ProjectFilesReader.maximumBytes + 1)] {
            if let external { try external.write(to: url, options: .atomic) }
            else { try FileManager.default.removeItem(at: url) }
            let previousMessage = tab.externalConflict?.message
            model.reloadTab(tab)
            try await waitForEditor { tab.externalConflict?.message != previousMessage }
            guard case .text = tab.contentState else { return XCTFail("Draft editor was replaced with an error") }
            XCTAssertEqual(tab.currentText, "draft")
            XCTAssertNil(tab.openTarget)
        }

        model.updateDraft("continued draft", for: tab)
        try Data("external version".utf8).write(to: url, options: .atomic)
        model.reloadTab(tab)
        try await waitForEditor { tab.externalConflict?.diskRevision != nil }
        guard case .text = tab.contentState else { return XCTFail("Draft editor did not recover") }
        XCTAssertEqual(tab.currentText, "continued draft")
        XCTAssertEqual(tab.externalConflict?.diskDocument?.text, "external version")

        model.reloadTab(tab, discardDraft: true)
        try await waitForEditor { tab.savedDocument?.text == "external version" }
        XCTAssertNil(tab.draftText)
        XCTAssertNil(tab.externalConflict)
    }

    @MainActor
    func testConversationLinkReportsUnavailableBeforeCreatingEditorTab() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectRecord(id: UUID(), path: directory.path)
        let model = WorkbenchTabsModel()
        let path = ProjectFilePath(components: ["note.md"])
        let url = directory.appendingPathComponent(path.name)

        let missing = await model.openLinkedFile(project: project, rootPath: directory.path, path: path,
                                                isCurrent: model.beginLinkedFileOpen { true })
        XCTAssertEqual(missing, .unavailable(.missing))
        XCTAssertTrue(model.editorTabs.isEmpty)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("target.md"))
        let isCurrent = model.beginLinkedFileOpen { true }
        let link = await model.openLinkedFile(project: project, rootPath: directory.path, path: path, isCurrent: isCurrent)
        XCTAssertEqual(link, .unavailable(.link))
        XCTAssertTrue(model.editorTabs.isEmpty)
        let fallback = TranscriptFileOpener.Request(url: url, contextIsCurrent: isCurrent)
        XCTAssertTrue(fallback.isCurrent)
        model.invalidateFileOpenRequests()
        let dispatched = await fallback.withAuthorization { true }
        XCTAssertNil(dispatched)

        try FileManager.default.removeItem(at: url)
        try Data("title\nsecond line".utf8).write(to: url)
        let opened = await model.openLinkedFile(project: project, rootPath: directory.path, path: path, line: 2,
                                                isCurrent: model.beginLinkedFileOpen { true })
        XCTAssertEqual(opened, .opened)
        let tab = try XCTUnwrap(model.activeEditorTab)
        XCTAssertEqual(tab.currentText, "title\nsecond line")
        XCTAssertEqual(tab.targetLine?.line, 2)
        XCTAssertFalse(tab.isMarkdownPreview)
    }

    @MainActor
    func testEditorSwitchInvalidatesPendingLinkAndBlockedExternalOpen() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectRecord(id: UUID(), path: directory.path)
        let original = ProjectFilePath(components: ["original.txt"])
        let linked = ProjectFilePath(components: ["linked.txt"])
        for path in [original, linked] {
            try Data(path.name.utf8).write(to: directory.appendingPathComponent(path.name))
        }
        let reader = PausingWorkbenchReader(pausedPath: linked)
        let model = WorkbenchTabsModel(reader: reader)
        model.openFile(project: project, entry: .init(path: original, kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { tab.openTarget != nil }

        var allowsOpen = true
        let request = try XCTUnwrap(model.externalOpenRequest(for: tab) { allowsOpen })
        allowsOpen = false
        XCTAssertFalse(request.isCurrent)
        model.invalidateFileOpenRequests()
        allowsOpen = true
        XCTAssertFalse(request.isCurrent)

        let isCurrent = model.beginLinkedFileOpen { true }
        let opening = Task {
            await model.openLinkedFile(project: project, rootPath: directory.path, path: linked, isCurrent: isCurrent)
        }
        try await waitForEditor { await reader.isWaitingToRead }
        model.openFile(project: project, entry: .init(path: .init(components: ["other.txt"]), kind: .file))
        model.activateEditorTab(tab.id)
        await reader.resumeRead()
        let outcome = await opening.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(model.activeEditorTab === tab)
        XCTAssertEqual(model.editorTabs.count, 2)
    }

    @MainActor
    func testEditorKeepsEditsMadeDuringSaveAndRejectsReplacedExternalOpenTarget() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: url)
        let path = try XCTUnwrap(ProjectFilePath.relativePath(from: url, within: directory.path))
        let reader = PausingWorkbenchReader()
        let model = WorkbenchTabsModel(reader: reader)
        let project = ProjectRecord(id: UUID(), path: directory.path)
        model.openFile(project: project, entry: ProjectFileEntry(path: path, kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { tab.savedDocument != nil }
        model.updateDraft("first edit", for: tab)
        XCTAssertTrue(model.hasUnsavedFileEdits)

        let saving = Task { await model.saveTab(tab) }
        try await waitForEditor { await reader.isWaitingToWrite }
        XCTAssertTrue(model.isSavingFile)
        model.updateDraft("original", for: tab)
        await reader.resumeWrite()
        let didSave = await saving.value
        XCTAssertTrue(didSave)
        XCTAssertEqual(tab.savedDocument?.text, "first edit")
        XCTAssertEqual(tab.draftText, "original")
        XCTAssertTrue(model.hasUnsavedFileEdits)
        XCTAssertFalse(model.isSavingFile)

        model.isPreparingToTerminate = true
        model.updateDraft("edit while quitting", for: tab)
        XCTAssertEqual(tab.draftText, "original")
        model.isPreparingToTerminate = false

        let request = try XCTUnwrap(model.externalOpenRequest(for: tab))
        try Data("replacement".utf8).write(to: url, options: .atomic)
        let launched = await request.withAuthorization { true }
        XCTAssertNil(launched)
        XCTAssertNil(tab.openTarget)
        XCTAssertNotNil(tab.saveError)
        XCTAssertEqual(tab.draftText, "original")
    }

    @MainActor
    func testEditorPreservesCanonicallyEquivalentEditsAndExpiredOpenRequests() async throws {
        let directory = try makeEditorTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectRecord(id: UUID(), path: directory.path)
        let path = ProjectFilePath(components: ["A.txt"])
        let other = ProjectFilePath(components: ["B.txt"])
        let url = directory.appendingPathComponent(path.name)
        let composed = "é"
        let decomposed = "e\u{0301}"
        try Data(composed.utf8).write(to: url)
        let reader = PausingWorkbenchReader()
        let model = WorkbenchTabsModel(reader: reader)
        model.openFile(project: project, entry: .init(path: path, kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        try await waitForEditor { tab.savedDocument != nil }

        let expired = try XCTUnwrap(model.externalOpenRequest(for: tab))
        model.openFile(project: project, entry: .init(path: other, kind: .file))
        model.activateEditorTab(tab.id)
        XCTAssertFalse(expired.isCurrent)
        let first = try XCTUnwrap(model.externalOpenRequest(for: tab))
        let second = try XCTUnwrap(model.externalOpenRequest(for: tab))
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(second.isCurrent)
        model.isEditorVisible = false
        model.isEditorVisible = true
        XCTAssertFalse(second.isCurrent)

        model.updateDraft(decomposed, for: tab)
        XCTAssertTrue(tab.isDirty)
        let saving = Task { await model.saveTab(tab) }
        try await waitForEditor { await reader.isWaitingToWrite }
        model.updateDraft(composed, for: tab)
        await reader.resumeWrite()
        let didSave = await saving.value
        XCTAssertTrue(didSave)
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(tab.draftText.map { Array($0.utf16) }, Array(composed.utf16))
        XCTAssertEqual(try Data(contentsOf: url), Data(decomposed.utf8))
    }

    private func makeEditorTestDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-editor-\(UUID())",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func waitForEditor(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Dual Tab Groups & Cross-Project Disambiguation

    @MainActor
    func testWorkbenchTabsModelDeduplicationAndCrossProjectDisambiguation() throws {
        let model = WorkbenchTabsModel()
        let p1 = ProjectRecord(id: UUID(), path: "/tmp/alpha")
        let p2 = ProjectRecord(id: UUID(), path: "/tmp/beta")

        // Conversation tabs: open, deduplicate, close does not delete session
        let s1 = UUID(), s2 = UUID()
        model.syncActiveConversation(s1)
        model.syncActiveConversation(s2)
        model.syncActiveConversation(s1)
        XCTAssertEqual(model.conversationTabs, [s1, s2])
        XCTAssertEqual(model.activeConversationID, s1)
        let next = model.closeConversation(s1)
        XCTAssertEqual(next, s2)
        XCTAssertEqual(model.conversationTabs, [s2])

        // Editor tabs: File and Git Diff for the same path coexist; duplicate same-scope Diff reuses tab
        let readmePath = try XCTUnwrap(ProjectFilePath.relativePath(
            from: URL(fileURLWithPath: "/tmp/alpha/README.md"), within: "/tmp/alpha"))
        model.openFile(project: p1, entry: ProjectFileEntry(path: readmePath, kind: .file))
        XCTAssertTrue(model.isEditorVisible)
        XCTAssertEqual(model.editorTabs.count, 1)
        XCTAssertTrue(model.editorTabs[0].isMarkdownPreview, "Markdown files should open in preview mode by default")

        let diffChange = GitFileChange(path: "README.md", previousPath: nil, status: .modified,
                                       scope: .unstagedVsIndex, stat: GitLineStat(added: 2, deleted: 1, isBinary: false))
        model.openGitDiff(project: p1, change: diffChange, checkoutRoot: p1.path)
        XCTAssertEqual(model.editorTabs.count, 2, "File and Diff tabs for the same file must coexist")
        model.openGitDiff(project: p1, change: diffChange, checkoutRoot: p1.path)
        XCTAssertEqual(model.editorTabs.count, 2, "Opening the same Diff scope again should deduplicate")

        // Cross-project file with identical name disambiguates titles
        let readmePath2 = try XCTUnwrap(ProjectFilePath.relativePath(
            from: URL(fileURLWithPath: "/tmp/beta/README.md"), within: "/tmp/beta"))
        model.openFile(project: p2, entry: ProjectFileEntry(path: readmePath2, kind: .file))
        XCTAssertEqual(model.editorTabs.count, 3)
        let t1 = model.displayTitle(for: model.editorTabs[0])
        let t3 = model.displayTitle(for: model.editorTabs[2])
        XCTAssertNotEqual(t1, t3)
        XCTAssertTrue(t1.contains("Alpha"))
        XCTAssertTrue(t3.contains("Beta"))
    }

    @MainActor func testOpenToolDiffTracksReplacementAndClearWithinItsSession() throws {
        let model = WorkbenchTabsModel()
        let sessionID = UUID()
        func tool(_ path: String, _ text: String) -> RuntimeTool {
            var tool = RuntimeTool(id: "tool", name: "edit")
            tool.editArguments = .init(path: path, edits: [.init(oldText: "", newText: text)])
            return tool
        }
        let presentation = SessionPresentation(id: sessionID)
        var reference = SessionReference(id: sessionID, projectID: UUID(), runtimeID: "acp-example")
        reference.cachedHistoryItems = [.init(id: "tool", kind: .tool, tool: tool("old.swift", "old"))]
        presentation.controller.showCachedHistory(reference.cachedHistoryItems ?? [])
        let item = try XCTUnwrap(presentation.controller.transcript.first)
        model.openToolDiff(item, sessionID: sessionID, projectName: "Example", title: "Old") {
            presentation.toolSummary(for: item, reference: reference)
        }
        let original = try XCTUnwrap(model.editorTabs.first)
        XCTAssertEqual(original.toolDiff?.lines.last?.text, "old")
        item.tool = tool("new.swift", "new")
        XCTAssertEqual(original.toolDiff?.path, "new.swift")
        XCTAssertEqual(original.toolDiff?.lines.last?.text, "new")
        XCTAssertEqual(model.displayTitle(for: original), "new.swift")
        item.tool?.editArguments = nil
        XCTAssertNil(original.toolDiff)
        item.tool = tool("third.swift", "third")

        reference.cachedHistoryItems = [.init(id: "tool", kind: .tool, tool: tool("restored.swift", "restored"))]
        presentation.controller.showCachedHistory(reference.cachedHistoryItems ?? [])
        let reloaded = try XCTUnwrap(presentation.controller.transcript.first)
        XCTAssertFalse(reloaded === item)
        XCTAssertEqual(original.toolDiff?.lines.last?.text, "restored")
        presentation.controller.showHistory([])
        XCTAssertEqual(original.toolDiff?.lines.last?.text, "restored")

        presentation.controller.showHistory([.init(id: "tool", kind: .tool, tool: .init(id: "tool", name: "edit"))])
        XCTAssertNil(original.toolDiff)
        XCTAssertEqual(model.displayTitle(for: original), "Old")
        model.openToolDiff(reloaded, sessionID: sessionID, projectName: "Example", title: "New") {
            reloaded.toolSummary
        }
        XCTAssertEqual(model.editorTabs.count, 1)
        XCTAssertTrue(model.editorTabs.first === original)
        XCTAssertEqual(original.toolDiff?.lines.last?.text, "restored")

        model.openToolDiff(item, sessionID: UUID(), projectName: "Example", title: "Empty") {
            presentation.toolSummary(for: item, reference: reference)
        }
        XCTAssertEqual(model.editorTabs.count, 1)
        model.openToolDiff(reloaded, sessionID: UUID(), projectName: "Another project", title: "Other") {
            reloaded.toolSummary
        }
        XCTAssertEqual(model.editorTabs.count, 2)
    }

    @MainActor func testOpenFrozenToolDiffRetainsItsSegmentWhenHistoryIsEvicted() throws {
        let model = WorkbenchTabsModel()
        let sessionID = UUID()
        let otherLegacySegmentID = UUID()
        let qualifiedSegmentID = UUID()
        let presentation = SessionPresentation(id: sessionID)
        var reference = SessionReference(id: sessionID, projectID: UUID(), runtimeID: "acp-example")
        reference.activeSegmentID = UUID()
        presentation.controller.timelineSegmentID = reference.activeSegmentID
        func segment(_ id: UUID) -> FrozenSessionSegment {
            .init(id: id, runtimeID: reference.runtimeID, runtimeSessionID: nil, file: nil,
                  modelName: nil, selection: nil, modeID: nil, coverage: .available, incomingHandoff: nil)
        }
        let segmentIDs = [sessionID, otherLegacySegmentID, qualifiedSegmentID]
        reference.frozenSegments = segmentIDs.map(segment)

        func makeFrozenTimeline(_ segmentID: UUID, liveSegmentID: UUID?, text: String)
            -> (items: [TranscriptItem], rows: [TranscriptDisplayRow]) {
            var tool = RuntimeTool(id: "shared", name: "edit")
            tool.editArguments = .init(path: "\(text).swift", edits: [.init(oldText: "", newText: text)])
            let user = TranscriptItem(id: "shared", kind: .user, text: "Same row ID")
            let item = TranscriptItem(id: "shared", kind: .tool, tool: tool)
            user.timelineSegmentID = liveSegmentID
            item.timelineSegmentID = liveSegmentID
            return SessionHistorySnapshot(transcript: [user, item], coverage: .available)
                .timeline(frozenSegmentID: segmentID)
        }

        let legacy = makeFrozenTimeline(sessionID, liveSegmentID: nil, text: "legacy")
        let otherLegacy = makeFrozenTimeline(otherLegacySegmentID, liveSegmentID: nil, text: "other")
        let qualified = makeFrozenTimeline(qualifiedSegmentID, liveSegmentID: qualifiedSegmentID, text: "qualified")
        let legacyItem = try XCTUnwrap(legacy.items.first { $0.kind == .tool })
        let otherLegacyItem = try XCTUnwrap(otherLegacy.items.first { $0.kind == .tool })
        let qualifiedItem = try XCTUnwrap(qualified.items.first { $0.kind == .tool })
        XCTAssertEqual(legacyItem.timelineID, "shared")
        XCTAssertEqual(otherLegacyItem.timelineID, "shared")
        XCTAssertEqual(qualifiedItem.timelineID, "\(qualifiedSegmentID):shared")
        presentation.setFrozenTranscript(legacy.items + otherLegacy.items + qualified.items,
                                         rows: legacy.rows + otherLegacy.rows + qualified.rows, segmentIDs: segmentIDs)
        for item in [legacyItem, otherLegacyItem, qualifiedItem] {
            model.openToolDiff(item, sessionID: sessionID, projectName: nil, title: "Edit") {
                presentation.toolSummary(for: item, reference: reference)
            }
        }
        XCTAssertEqual(model.editorTabs.compactMap { $0.toolDiff?.lines.last?.text }, ["legacy", "other", "qualified"])

        presentation.setFrozenTranscript([], rows: [], segmentIDs: [])
        XCTAssertEqual(model.editorTabs.compactMap { $0.toolDiff?.lines.last?.text }, ["legacy", "other", "qualified"])

        reference.frozenSegments = [segment(otherLegacySegmentID), segment(qualifiedSegmentID)]
        XCTAssertNil(model.editorTabs.first?.toolDiff)
        XCTAssertEqual(model.editorTabs.compactMap { $0.toolDiff?.lines.last?.text }, ["other", "qualified"])
    }

    // MARK: - Multi-Source Quotas (Antigravity + Multi-Period Lowest Remaining)

    func testAntigravityQuotaParsingAndMultiPeriodLowestMetric() throws {
        let json = """
        {
          "command": {
            "data": {
              "groups": [
                {
                  "label": "Gemini",
                  "buckets": [
                    { "label": "5h", "remainingFraction": 0.62, "resetTime": "2026-11-28T16:00:00Z" },
                    { "label": "7d", "remainingFraction": 0.18, "resetTime": "2026-12-03T00:00:00Z" }
                  ]
                }
              ]
            }
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_800_000)
        let windows = try AntigravityQuotaClient.windows(from: Data(json.utf8), observedAt: now)
        XCTAssertEqual(windows.count, 2)

        var pool = QuotaPoolState(id: "antigravity", provider: "Antigravity", providerKey: "antigravity")
        pool.windows = windows
        let metric = pool.metric(at: now)
        XCTAssertEqual(metric.severity, .warning)
        XCTAssertEqual(metric.displayValue, "18%")
        XCTAssertNotNil(metric.remainingFraction)
        XCTAssertEqual(metric.remainingFraction ?? 0, 0.18, accuracy: 0.01)

        // Critical threshold (<= 10%)
        pool.windows = [
            AccountQuotaWindow(id: "w1", provider: "Codex", account: "a", period: "5h",
                               remaining: 5, limit: 1000, resetAt: nil, observedAt: now,
                               expiresAt: now.addingTimeInterval(300))
        ]
        let critical = pool.metric(at: now)
        XCTAssertEqual(critical.severity, .critical)
        XCTAssertEqual(critical.displayValue, "<1%")
    }

    func testQuotaMetricDistinguishesUnknownZeroSmallAndExpiredWindows() {
        let now = Date(timeIntervalSince1970: 100)
        var pool = QuotaPoolState(id: "codex", provider: "Codex", providerKey: "openai-codex")
        func window(_ remaining: Int?, limit: Int? = 100, resetAt: Date? = nil) -> AccountQuotaWindow {
            .init(id: "daily", provider: "Codex", account: "Example", period: "Daily",
                  remaining: remaining, limit: limit, resetAt: resetAt, observedAt: now)
        }

        for windows in [[], [window(nil)], [window(2, limit: nil)], [window(0, resetAt: now)]] {
            pool.windows = windows
            let metric = pool.metric(at: now)
            XCTAssertNil(metric.remainingFraction)
            XCTAssertEqual(metric.displayValue, "—")
            XCTAssertEqual(metric.severity, .unavailable)
        }
        let cases: [(Int, String, QuotaPoolState.Severity)] = [
            (0, "0%", .critical), (100, "10%", .critical), (110, "11%", .warning), (620, "62%", .normal)
        ]
        for (remaining, label, severity) in cases {
            pool.windows = [window(remaining, limit: 1_000)]
            let metric = pool.metric(at: now)
            XCTAssertEqual(metric.displayValue, label)
            XCTAssertEqual(metric.severity, severity)
        }
        pool.windows = [window(1, limit: 1_000)]
        XCTAssertEqual(pool.metric(at: now).displayValue, "<1%")
    }

    // MARK: - Tool Summary First & Structured Execution Errors

    @MainActor
    func testToolSummaryPriorityAndStructuredMCPEntries() throws {
        let tool = RuntimeTool(
            id: "t1", name: "mcp_github_search_issues",
            summary: "搜索 yuzio/zivvi 仓库中未关闭的 bug 议题",
            arguments: #"{"query":"label:bug state:open","repo":"yuzio/zivvi","limit":10}"#,
            output: "",
            state: .completed
        )
        let item = TranscriptItem(id: "t1", kind: .tool, tool: tool)
        let presentation = ToolCallPresentation(try XCTUnwrap(item.toolSummary))
        XCTAssertEqual(presentation.primarySummaryText, "搜索 yuzio/zivvi 仓库中未关闭的 bug 议题")
        let entries = presentation.structuredRawEntries
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.contains { $0.key == "repo" && $0.value == "yuzio/zivvi" })
    }

    func testExecutionErrorCategorizationAndResetHintExtraction() {
        let quotaFailure = RuntimeFailure(
            .model,
            "Provider error",
            rawDetail: "HTTP 429: Your model quota has been exhausted. Resets in 2h25m10s."
        )
        let presentation = ExecutionErrorPresentation(failure: quotaFailure)
        XCTAssertEqual(presentation.category, .quotaExceeded)
        XCTAssertEqual(presentation.resetHint, "Resets in 2h25m10s")

        let authFailure = RuntimeFailure(.authentication, "401 Unauthorized")
        XCTAssertEqual(ExecutionErrorPresentation(failure: authFailure).category, .authentication)

        let contextFailure = RuntimeFailure(.model, "context length exceeded for model")
        XCTAssertEqual(ExecutionErrorPresentation(failure: contextFailure).category, .contextExceeded)
    }
}

private actor PausingWorkbenchReader: ProjectFilesReading {
    private let reader = ProjectFilesReader()
    private let pausedPath: ProjectFilePath?
    private var pausedRead: CheckedContinuation<Void, Never>?
    private var pausedWrite: CheckedContinuation<Void, Never>?

    init(pausedPath: ProjectFilePath? = nil) {
        self.pausedPath = pausedPath
    }

    var isWaitingToRead: Bool { pausedRead != nil }
    var isWaitingToWrite: Bool { pausedWrite != nil }

    func resumeRead() {
        pausedRead?.resume()
        pausedRead = nil
    }

    func resumeWrite() {
        pausedWrite?.resume()
        pausedWrite = nil
    }

    func bindRoot(at path: String) async throws -> ProjectFilesReader.Root {
        try await reader.bindRoot(at: path)
    }

    func directory(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> [ProjectFileEntry] {
        try await reader.directory(at: root, path: path)
    }

    func read(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> ProjectFilePreview {
        if path == pausedPath { await withCheckedContinuation { pausedRead = $0 } }
        return try await reader.read(at: root, path: path)
    }

    func readMarkdownImage(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> CGImage {
        try await reader.readMarkdownImage(at: root, path: path)
    }

    func validateOpenTarget(_ target: ProjectFilesReader.OpenTarget) async throws {
        try await reader.validateOpenTarget(target)
    }

    func write(at root: ProjectFilesReader.Root, path: ProjectFilePath, content: String,
               expectedRevision: ProjectFileRevision?, forceOverwrite: Bool) async throws -> ProjectFileWriteOutcome {
        await withCheckedContinuation { pausedWrite = $0 }
        return try await reader.write(at: root, path: path, content: content,
                                      expectedRevision: expectedRevision, forceOverwrite: forceOverwrite)
    }
}
