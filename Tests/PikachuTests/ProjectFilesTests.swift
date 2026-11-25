import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Pikachu

final class ProjectFilesTests: XCTestCase {
    @MainActor func testMarkdownImageRequiresSelectedFormattedDocumentAndUsesBoundReader() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let docs = fixture.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# Sample".write(to: docs.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: markdownImageSample, to: fixture.appending(path: "sample.png"))
        try FileManager.default.createSymbolicLink(at: fixture.appending(path: "alias.png"),
                                                   withDestinationURL: fixture.appending(path: "sample.png"))

        let document = ProjectFilePath(components: ["docs", "README.md"])
        let relative = try XCTUnwrap(URL(string: "../sample.png"))
        let model = ProjectFilesModel()
        model.bind(root: .init(projectID: UUID(), path: fixture.path, displayName: "Fixture"), isOpen: true)
        model.open(.init(path: document, kind: .file))
        _ = try await previewText(model)
        XCTAssertNil(model.markdownImageLoader(for: document))

        model.toggleMarkdown()
        let loader = try XCTUnwrap(model.markdownImageLoader(for: document))
        let image = try await loader.load(relative)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 32)

        let target = try XCTUnwrap(URL(string: "../alias.png"))
        do {
            _ = try await loader.load(target)
            XCTFail("A symlink must not supply a Markdown image")
        } catch let issue as ProjectFileIssue {
            XCTAssertEqual(issue, .link)
        }

        for denied in ["https://example.invalid/image.png", "//example.invalid/image.png", "/sample.png",
                       "../../outside.png", "../%2E%2E/outside.png", "../dir%2Fsample.png", "../.git/sample.png"] {
            XCTAssertNil(document.markdownImagePath(for: try XCTUnwrap(URL(string: denied))), denied)
        }
    }

    @MainActor func testMarkdownImageRefreshRetriesOnlyRequestedImagesAndRecoversFromMissingFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, _, _) = try await selectedDraft(in: fixture)
        let document = ProjectFilePath.root.appending("draft.md")
        let imageFile = fixture.appending(path: "sample.png")
        let reference = try XCTUnwrap(URL(string: "sample.png"))
        try FileManager.default.copyItem(at: markdownImageSample, to: imageFile)
        model.toggleMarkdown()
        let first = try XCTUnwrap(model.markdownImageLoader(for: document))
        let request = MarkdownImageRequest()
        XCTAssertNil(request.key(for: first, url: reference))
        request.request()
        let firstKey = try XCTUnwrap(request.key(for: first, url: reference))
        await request.update(url: reference, loader: first, key: firstKey)
        guard case .loaded(let original) = request.status(for: firstKey) else {
            return XCTFail("Expected the requested image")
        }
        XCTAssertEqual(original.width, 64)

        try FileManager.default.removeItem(at: imageFile)
        model.refresh()
        XCTAssertNil(model.markdownImageLoader(for: document))
        guard case .placeholder = request.status(for: nil) else {
            return XCTFail("Refreshing must stop displaying the previous image")
        }
        await request.update(url: reference, loader: nil, key: nil)
        let missing = try await waitFor { model.markdownImageLoader(for: document) }
        XCTAssertNotEqual(missing.revision, first.revision)
        XCTAssertNil(MarkdownImageRequest().key(for: missing, url: reference))
        let missingKey = try XCTUnwrap(request.key(for: missing, url: reference))
        await request.update(url: reference, loader: missing, key: missingKey)
        guard case .failed = request.status(for: missingKey) else {
            return XCTFail("The removed image must report an unavailable state")
        }

        try writeReplacementMarkdownImage(to: imageFile)
        model.refresh()
        let recovered = try await waitFor { model.markdownImageLoader(for: document) }
        let recoveredKey = try XCTUnwrap(request.key(for: recovered, url: reference))
        XCTAssertNotEqual(recoveredKey, missingKey)
        await request.update(url: reference, loader: recovered, key: recoveredKey)
        guard case .loaded(let replacement) = request.status(for: recoveredKey) else {
            return XCTFail("The requested image must recover on refresh")
        }
        XCTAssertEqual(replacement.width, 1)
    }

    @MainActor func testMarkdownImageRefreshDiscardsDecodedImageFromPreviousRevision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = ProjectFilePath.root.appending("README.md")
        try "![Sample](sample.png)".write(to: fixture.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let imageFile = fixture.appending(path: "sample.png")
        try FileManager.default.copyItem(at: markdownImageSample, to: imageFile)
        let reference = try XCTUnwrap(URL(string: "sample.png"))
        let reader = DelayedReader(delaysReads: false)
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: .init(projectID: UUID(), path: fixture.path, displayName: "Fixture"), isOpen: true)
        model.open(.init(path: document, kind: .file))
        _ = try await previewText(model)
        model.toggleMarkdown()
        let first = try XCTUnwrap(model.markdownImageLoader(for: document))
        let request = MarkdownImageRequest()
        request.request()
        let firstKey = try XCTUnwrap(request.key(for: first, url: reference))

        await reader.holdNextMarkdownImage()
        let pending = Task { await request.update(url: reference, loader: first, key: firstKey) }
        defer { Task { await reader.releaseMarkdownImage() } }
        for _ in 0..<100 where await !reader.isWaitingForMarkdownImage {
            try await Task.sleep(for: .milliseconds(5))
        }
        let hasDecoded = await reader.isWaitingForMarkdownImage
        XCTAssertTrue(hasDecoded)
        try writeReplacementMarkdownImage(to: imageFile)
        model.refresh()
        await request.update(url: reference, loader: nil, key: nil)
        let refreshed = try await waitFor { model.markdownImageLoader(for: document) }
        let refreshedKey = try XCTUnwrap(request.key(for: refreshed, url: reference))
        await request.update(url: reference, loader: refreshed, key: refreshedKey)
        await reader.releaseMarkdownImage()
        await pending.value
        guard case .loaded(let current) = request.status(for: refreshedKey) else {
            return XCTFail("The stale request replaced the refreshed outcome")
        }
        XCTAssertEqual(current.width, 1)
    }

    @MainActor func testMarkdownImageDropsRequestAfterSwitchingToSource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "# Sample".write(to: fixture.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let reader = DelayedReader(delaysReads: false)
        let model = ProjectFilesModel(reader: reader)
        let document = ProjectFilePath.root.appending("README.md")
        let reference = try XCTUnwrap(URL(string: "sample.png"))
        model.bind(root: .init(projectID: UUID(), path: fixture.path, displayName: "Fixture"), isOpen: true)
        model.open(.init(path: document, kind: .file))
        _ = try await previewText(model)
        model.toggleMarkdown()
        let loader = try XCTUnwrap(model.markdownImageLoader(for: document))

        await reader.holdNextValidation()
        let request = Task { try await loader.load(reference) }
        for _ in 0..<100 where await !reader.isWaitingForValidation {
            try await Task.sleep(for: .milliseconds(5))
        }
        let reachedValidation = await reader.isWaitingForValidation
        XCTAssertTrue(reachedValidation)
        model.toggleMarkdown()
        await reader.releaseValidation()
        do {
            _ = try await request.value
            XCTFail("Source mode must invalidate the pending image request")
        } catch is CancellationError {
        }
    }

    @MainActor func testFormattedPreviewDoesNotEnrichLocalFileReferences() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data().write(to: fixture.appending(path: "local.md"))
        let source = """
        [Local](local.md) [Website](https://example.com)
        [Mail](mailto:docs@example.com) [`Missing`](missing.swift) [Anchor](#heading) [Other](custom://example.com)
        """
        let cache = MarkdownContentCache()
        let transcript = cache.layout(for: source, typography: .init(), workspaceDirectory: fixture)
        let preview = cache.layout(for: source, typography: .init(),
                                   workspaceDirectory: fixture, enrichFileLinks: false)
        let transcriptContent = try XCTUnwrap(transcript.blocks.first).content
        let previewContent = try XCTUnwrap(preview.blocks.first).content
        let transcriptLinks = transcriptContent.runs.compactMap(\.link)
        let previewLinks = previewContent.runs.compactMap(\.link)
        XCTAssertTrue(transcriptLinks.contains(where: \.isFileURL))
        XCTAssertTrue(previewLinks.contains { $0.relativeString == "local.md" && !$0.isFileURL })
        XCTAssertFalse(previewLinks.contains(where: \.isFileURL))

        let fonts = MarkdownTextFonts(typography: .init())
        for (content, layout, expectedSchemes) in [
            (transcriptContent, transcript, ["file", "https", "mailto"]),
            (previewContent, preview, ["https", "mailto"]),
        ] {
            let styled = fonts.stylingInlineText(in: content, interactiveLinks: layout.interactiveLinks)
            XCTAssertEqual(String(styled.characters), String(content.characters))
            XCTAssertEqual(styled.runs.compactMap { $0.link?.scheme }, expectedSchemes)
            for run in styled.runs {
                XCTAssertEqual(run.swiftUI.foregroundColor, run.link == nil ? nil : PikachuTheme.infoText)
                XCTAssertEqual(run.swiftUI.underlineStyle, run.link == nil ? nil : .single)
            }
            let missing = try XCTUnwrap(styled.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
            XCTAssertNil(missing.link)
            XCTAssertNotNil(missing.swiftUI.font)
        }
    }

    func testDirectoryAndReadBoundaries() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "project", directoryHint: .isDirectory)
        let elsewhere = fixture.appending(path: "outside", directoryHint: .isDirectory)
        let docs = root.appending(path: "docs", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: docs, withIntermediateDirectories: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "secret".write(to: elsewhere.appending(path: "hidden"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: root.appending(path: "alias"), withDestinationURL: elsewhere)
        try manager.createSymbolicLink(at: root.appending(path: "linked.txt"),
                                       withDestinationURL: elsewhere.appending(path: "hidden"))
        try "草稿\r\n😀".write(to: docs.appending(path: "draft"), atomically: true, encoding: .utf16)
        try "".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: ".git"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x02]).write(to: root.appending(path: "binary"))
        let locked = root.appending(path: "locked")
        try "locked".write(to: locked, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        XCTAssertEqual(mkfifo(root.appending(path: "pipe").path, 0o600), 0)
        try Data(repeating: 65, count: ProjectFilesReader.maximumBytes)
            .write(to: root.appending(path: "limit"))
        try Data(repeating: 65, count: ProjectFilesReader.maximumBytes + 1)
            .write(to: root.appending(path: "oversized"))

        let reader = ProjectFilesReader()
        let binding = try await reader.bindRoot(at: root.path)
        let listing = try await reader.directory(at: binding, path: .root)
        XCTAssertEqual(listing.first?.path.name, "docs")
        XCTAssertFalse(listing.contains { $0.path.name == ".git" })
        XCTAssertTrue(listing.contains { $0.path.name == ".gitignore" })
        XCTAssertTrue(listing.contains { $0.path.name == "alias" && $0.kind == .link })
        let document = try await reader.read(at: binding, path: .init(components: ["docs", "draft"]))
        XCTAssertEqual(try document.contents.get().text, "草稿\r\n😀")
        XCTAssertEqual(try document.contents.get().lineStarts, [0, 4])
        let exact = try await reader.read(at: binding, path: .root.appending("limit"))
        XCTAssertEqual(try exact.contents.get().text.utf8.count, ProjectFilesReader.maximumBytes)
        let failures: [([String], ProjectFileIssue)] = [
            (["alias", "hidden"], .link), (["linked.txt"], .link), (["missing"], .missing),
            (["binary"], .unsupported), (["pipe"], .unsupported), (["locked"], .permission),
            (["oversized"], .tooLarge), (["..", "outside", "hidden"], .unsupported)
        ]
        for (components, expected) in failures {
            do {
                _ = try await reader.read(at: binding, path: .init(components: components)).contents.get()
                XCTFail("Unexpectedly read \(components)")
            } catch {
                XCTAssertEqual(error as? ProjectFileIssue, expected)
            }
        }

        // The row was listed as a directory before it was swapped for an external link.
        try manager.moveItem(at: docs, to: root.appending(path: "moved"))
        try manager.createSymbolicLink(at: docs, withDestinationURL: elsewhere)
        do {
            _ = try await reader.directory(at: binding, path: .root.appending("docs"))
            XCTFail("Directory swap escaped the project")
        } catch {
            XCTAssertEqual(error as? ProjectFileIssue, .link)
        }
    }

    @MainActor func testFinderOnlyRevealsTheSelectedFileIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, _, file) = try await selectedDraft(in: fixture)

        var revealed: [URL] = []
        var actions = TranscriptFileOpener.Actions()
        actions.revealInFinder = { revealed.append($0) }
        func reveal() async {
            await model.openSelection {
                await ProjectFilesOpenMethod.finder.open($0, configuration: .init(), actions: actions)
            }?.value
        }
        await reveal()
        XCTAssertEqual(revealed.map(\.path), [file.path])

        try "# Revised draft".write(to: file, atomically: true, encoding: .utf8)
        await reveal()
        XCTAssertEqual(revealed.count, 1)
        guard case .failure(.replaced) = model.preview else {
            return XCTFail("A different file identity should require refreshing the preview")
        }
        XCTAssertFalse(model.canOpenSelection)
        model.refresh()
        _ = try await waitFor { model.canOpenSelection ? true : nil }
        let refreshed = try await previewText(model)
        XCTAssertEqual(refreshed, "# Revised draft")
        await reveal()
        XCTAssertEqual(revealed.map(\.path), [file.path, file.path])
    }

    @MainActor func testCommandFailureOnlyFallsBackWhileThePanelAndFileAreCurrent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, _, file) = try await selectedDraft(in: fixture)
        let controls = ProjectFilesControls()
        controls.toggle()
        var opened: [URL] = []
        var launchCount = 0
        var pendingFailure: (@MainActor @Sendable () async -> Void)?
        var actions = TranscriptFileOpener.Actions()
        actions.launch = { _, failure in
            launchCount += 1
            pendingFailure = failure
        }
        actions.destination = { .application($0) }
        actions.openApplication = {
            opened.append($0)
            return true
        }
        let configuration = FileOpenConfiguration(preference: .custom, customCommand: "true")

        func requestOpen(using actions: TranscriptFileOpener.Actions) async {
            let openingID = controls.openingID
            await model.openSelection(canLaunch: { controls.openingID == openingID }) {
                await ProjectFilesOpenMethod.configured(.custom).open($0, configuration: configuration, actions: actions)
            }?.value
        }

        await requestOpen(using: actions)
        XCTAssertEqual(launchCount, 1)
        XCTAssertTrue(opened.isEmpty)
        let failure = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        await failure()
        XCTAssertEqual(opened.map(\.path), [file.path])

        await requestOpen(using: actions)
        let failureFromClosedPane = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        controls.close()
        controls.toggle()
        await failureFromClosedPane()
        XCTAssertEqual(launchCount, 2)
        XCTAssertEqual(opened.count, 1)

        await requestOpen(using: actions)
        let failureAfterRemoval = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        try FileManager.default.removeItem(at: file)
        await failureAfterRemoval()
        XCTAssertEqual(launchCount, 3)
        XCTAssertEqual(opened.count, 1)
        guard case .failure(.missing) = model.preview else { return XCTFail("Expected the removed-file state") }
        XCTAssertFalse(model.canOpenSelection)

        try "# Restored draft".write(to: file, atomically: true, encoding: .utf8)
        model.refresh()
        _ = try await waitFor { model.canOpenSelection ? true : nil }
        actions.launch = { _, _ in throw CocoaError(.fileNoSuchFile) }
        await requestOpen(using: actions)
        XCTAssertEqual(opened.map(\.path), [file.path, file.path])
    }

    @MainActor func testSystemOpenFailureRechecksContextBeforeRevealingInFinder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, root, file) = try await selectedDraft(in: fixture)
        var opened: [URL] = []
        var revealed: [URL] = []
        var actions = TranscriptFileOpener.Actions()
        actions.destination = { .application($0) }
        actions.openApplication = {
            opened.append($0)
            return false
        }
        actions.revealInFinder = { revealed.append($0) }
        let firstActions = actions

        await model.openSelection {
            await ProjectFilesOpenMethod.configured(.system).open($0, configuration: .init(), actions: firstActions)
        }?.value
        XCTAssertEqual(opened.map(\.path), [file.path])
        XCTAssertEqual(revealed.map(\.path), [file.path])

        actions.openApplication = {
            opened.append($0)
            model.bind(root: root, isOpen: false)
            return false
        }
        let closingActions = actions
        await model.openSelection {
            await ProjectFilesOpenMethod.configured(.system).open($0, configuration: .init(), actions: closingActions)
        }?.value
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(revealed.count, 1)
    }

    @MainActor func testShowingMoreFilesMovesKeyboardFocusWithoutSelectingAFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for index in 0...201 {
            let name = String(format: "file-%03d", index)
            try Data().write(to: fixture.appending(path: name))
        }
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        let moreID = ProjectFilesModel.TreeRow.ID.more(.root)
        _ = try await waitFor { model.rows.first { $0.id == moreID } }
        model.focusedRow = moreID

        model.showMore(in: .root, movesFocus: true)

        XCTAssertEqual(model.focusedRow, .entry(.root.appending("file-200")))
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.rows.contains { $0.id == moreID })

        model.focusedRow = moreID
        model.showMore(in: .root, movesFocus: true)
        XCTAssertEqual(model.focusedRow, .entry(.root.appending("file-201")))
        XCTAssertNil(model.selected)
    }

    @MainActor func testBreadcrumbRevealsNestedDirectoryBeyondVisiblePage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for index in 0..<201 {
            try FileManager.default.createDirectory(at: fixture.appending(path: "A\(index)"),
                                                    withIntermediateDirectories: false)
        }
        let file = ProjectFilePath(components: ["Z documentation", "Nested", "guide.md"])
        let url = fixture.appending(path: file.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Guide".write(to: url, atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.open(.init(path: file, kind: .file))
        _ = try await previewText(model)
        XCTAssertFalse(model.rows.contains { $0.path == file.parent })

        model.hidesDirectory = true
        model.revealDirectory(file.parent)
        let location = try await waitFor { model.directoryLocation }
        XCTAssertEqual(location.row, .entry(file.parent))
        XCTAssertEqual(model.region, .directory)
        XCTAssertTrue(model.expanded.contains(file.parent.parent))
        XCTAssertFalse(model.hidesDirectory)
        XCTAssertEqual(model.selected, file)
    }

    @MainActor func testChangingRootsAndClosingDropsInFlightResults() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let primary = fixture.appending(path: "project", directoryHint: .isDirectory)
        let worktree = fixture.appending(path: "preview-worktree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "old root".write(to: primary.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "worktree".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let id = UUID()
        let original = ProjectFilesRoot(projectID: id, path: primary.path, displayName: "Project")
        let next = ProjectFilesRoot(projectID: id, path: worktree.path, displayName: "preview-worktree")
        let item = ProjectFileEntry(path: .root.appending("README.md"), kind: .file)
        let model = ProjectFilesModel()
        model.bind(root: original, isOpen: true)
        model.open(item)
        model.bind(root: next, isOpen: true)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.tabLocation)
        model.open(item)
        let newText = try await previewText(model)
        XCTAssertEqual(newText, "worktree")

        try "changed".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)
        model.refresh()
        model.bind(root: next, isOpen: false)
        XCTAssertNil(model.preview)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.selected, item.path)
        XCTAssertEqual(model.tabs.map(\.id), [item.path])
        model.bind(root: next, isOpen: true)
        let updatedText = try await previewText(model)
        XCTAssertEqual(updatedText, "changed")
    }

    @MainActor func testTabsKeepPathIdentityModeAndChooseTheAdjacentFileWhenClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let docs = fixture.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "root".write(to: fixture.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "nested".write(to: docs.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "other".write(to: fixture.appending(path: "other.txt"), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let first = ProjectFilePath.root.appending("README.md")
        let second = ProjectFilePath(components: ["docs", "README.md"])
        let third = ProjectFilePath.root.appending("other.txt")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.open(.init(path: first, kind: .file))
        _ = try await previewText(model)
        model.toggleMarkdown()
        model.open(.init(path: second, kind: .file))
        XCTAssertFalse(model.rendersMarkdown)
        model.open(.init(path: third, kind: .file))
        model.open(.init(path: first, kind: .file))
        XCTAssertEqual(model.tabs.map(\.id), [first, second, third])
        XCTAssertTrue(model.rendersMarkdown)

        model.bind(root: root, isOpen: false)
        XCTAssertNil(model.preview)
        model.bind(root: root, isOpen: true)
        let read = try await previewText(model)
        XCTAssertEqual(read, "root")
        XCTAssertTrue(model.rendersMarkdown)
        XCTAssertEqual(model.tabs.map(\.id), [first, second, third])

        let beforeReopen = try XCTUnwrap(model.tabLocation)
        model.open(.init(path: first, kind: .file))
        let afterReopen = try XCTUnwrap(model.tabLocation)
        XCTAssertEqual(afterReopen.path, first)
        XCTAssertNotEqual(afterReopen, beforeReopen)
        model.activateTab(first)
        XCTAssertEqual(model.tabLocation?.path, first)
        XCTAssertNotEqual(model.tabLocation, afterReopen)
        XCTAssertEqual(model.tabs.map(\.id), [first, second, third])
        XCTAssertFalse(model.isLoadingFile)
        XCTAssertTrue(model.canOpenSelection)

        model.revealDirectory(.root)
        model.closeTab(second)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.region, .directory)
        model.closeTab(first)
        XCTAssertEqual(model.selected, third)
        XCTAssertEqual(model.region, .directory)
        let other = try await previewText(model)
        XCTAssertEqual(other, "other")

        model.open(.init(path: first, kind: .file))
        model.closeTab(first)
        XCTAssertEqual(model.selected, third)
        model.hidesDirectory = true
        model.closeTab(third)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.tabLocation)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.region, .directory)
        XCTAssertFalse(model.hidesDirectory)
    }

    @MainActor func testClosingLastTabInvalidatesInFlightRead() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "contents".write(to: fixture.appending(path: "pending.md"), atomically: true, encoding: .utf8)
        let reader = DelayedReader()
        defer { Task { await reader.releaseReads() } }
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let path = ProjectFilePath.root.appending("pending.md")
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: root, isOpen: true)
        model.open(.init(path: path, kind: .file))
        for _ in 0..<100 {
            if await reader.isWaitingForRead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await reader.isWaitingForRead
        XCTAssertTrue(waiting)

        model.closeTab(path)
        await reader.releaseReads()
        XCTAssertNil(model.selected)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.canOpenSelection)
        XCTAssertFalse(model.isLoadingFile)
    }

    @MainActor func testSwitchingTabsDuringExternalOpenKeepsTheOldFileFromLaunching() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "first".write(to: fixture.appending(path: "first.md"), atomically: true, encoding: .utf8)
        try "second".write(to: fixture.appending(path: "second.md"), atomically: true, encoding: .utf8)
        let reader = DelayedReader(delaysReads: false)
        defer { Task { await reader.releaseValidation() } }
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let first = ProjectFilePath.root.appending("first.md")
        let second = ProjectFilePath.root.appending("second.md")
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: root, isOpen: true)
        model.open(.init(path: second, kind: .file))
        model.open(.init(path: first, kind: .file))
        _ = try await previewText(model)

        await reader.holdNextValidation()
        var revealed: [URL] = []
        var actions = TranscriptFileOpener.Actions()
        actions.revealInFinder = { revealed.append($0) }
        let request = try XCTUnwrap(model.openSelection {
            await ProjectFilesOpenMethod.finder.open($0, configuration: .init(), actions: actions)
        })
        for _ in 0..<100 {
            if await reader.isWaitingForValidation { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await reader.isWaitingForValidation
        XCTAssertTrue(waiting)

        model.activateTab(second)
        await reader.releaseValidation()
        await request.value
        let preview = try await previewText(model)
        XCTAssertEqual(preview, "second")
        XCTAssertTrue(revealed.isEmpty)
    }

    @MainActor func testReplacingBoundRootClearsPreviewAndPreservesIdentityOnReopen() async throws {
        let fixture = try makeFixture()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: fixture) }
        let working = fixture.appending(path: "project", directoryHint: .isDirectory)
        let retired = fixture.appending(path: "previous-project", directoryHint: .isDirectory)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        try "original".write(to: working.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: working.path, displayName: "Project")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.open(.init(path: .root.appending("README.md"), kind: .file))
        let first = try await previewText(model)
        XCTAssertEqual(first, "original")

        try manager.moveItem(at: working, to: retired)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        try "replacement".write(to: working.appending(path: "README.md"), atomically: true, encoding: .utf8)
        model.refresh()
        try await assertRootUnavailable(model)
        model.bind(root: root, isOpen: false)
        model.bind(root: root, isOpen: true)
        try await assertRootUnavailable(model)

        try manager.removeItem(at: working)
        try manager.moveItem(at: retired, to: working)
        model.refresh()
        let recovered = try await waitFor { () -> String? in
            guard case .document(let doc) = model.preview else { return nil }
            return doc.text
        }
        XCTAssertEqual(recovered, "original")
    }

    @MainActor func testRootRecoveryReadsTheTabSelectedWhileTheListingIsPending() async throws {
        for closesActiveTab in [false, true] {
            let fixture = try makeFixture()
            let manager = FileManager.default
            defer { try? manager.removeItem(at: fixture) }
            let working = fixture.appending(path: "project", directoryHint: .isDirectory)
            let retired = fixture.appending(path: "retired", directoryHint: .isDirectory)
            try manager.createDirectory(at: working, withIntermediateDirectories: false)
            try "first".write(to: working.appending(path: "first.md"), atomically: true, encoding: .utf8)
            try "second".write(to: working.appending(path: "second.md"), atomically: true, encoding: .utf8)
            let root = ProjectFilesRoot(projectID: UUID(), path: working.path, displayName: "Project")
            let first = ProjectFilePath.root.appending("first.md")
            let second = ProjectFilePath.root.appending("second.md")
            let reader = DelayedReader(delaysReads: false)
            defer { Task { await reader.releaseRootListing() } }
            let model = ProjectFilesModel(reader: reader)
            model.bind(root: root, isOpen: true)
            model.open(.init(path: first, kind: .file))
            model.open(.init(path: second, kind: .file))
            model.activateTab(first)
            _ = try await previewText(model)

            try manager.moveItem(at: working, to: retired)
            model.refresh()
            try await assertRootUnavailable(model)
            try manager.moveItem(at: retired, to: working)
            await reader.holdNextRootListing()
            model.refresh()
            for _ in 0..<100 {
                if await reader.isWaitingForRootListing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let waiting = await reader.isWaitingForRootListing
            XCTAssertTrue(waiting)

            if closesActiveTab {
                model.closeTab(first)
            } else {
                model.activateTab(second)
            }
            XCTAssertEqual(model.selected, second)
            XCTAssertFalse(model.canOpenSelection)
            guard case .loading = model.preview else {
                return XCTFail("The active preview should wait for root recovery")
            }
            await reader.releaseRootListing()

            let recovered = try await previewText(model)
            XCTAssertEqual(recovered, "second")
            XCTAssertTrue(model.canOpenSelection)
        }
    }

    @MainActor func testDelayedKeyboardPreviewDoesNotTakeFocusFromEditor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "delay.md")
        try "Preview contents".write(to: file, atomically: true, encoding: .utf8)
        let reader = DelayedReader()
        defer { Task { await reader.releaseReads() } }
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: root, isOpen: true)
        let listed = try await waitFor {
            model.rows.contains { if case .entry = $0.content { true } else { false } } ? true : nil
        }
        XCTAssertTrue(listed)

        let host = NSHostingView(rootView: ProjectFilesPane(
            model: model, root: root, layout: .single(327), keyboardOpenRequest: 1, close: {}
        ))
        host.frame = NSRect(x: 400, y: 0, width: 327, height: 400)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 390, height: 400))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 727, height: 400))
        content.addSubview(editor)
        content.addSubview(host)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<12 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        window.sendEvent(enter)
        XCTAssertEqual(model.selected?.name, "delay.md")
        guard case .loading = model.preview else { return XCTFail("Return did not start a pending preview") }

        // Let the single-column navigation settle while the read is still held.
        for _ in 0..<6 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        await reader.releaseReads()
        let loaded = try await previewText(model)
        XCTAssertEqual(loaded, "Preview contents")
        for _ in 0..<12 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.firstResponder === editor,
                      "Expected the editor, got \(String(describing: window.firstResponder))")
    }

    func testLayoutBreakpointsAndContextMatching() {
        XCTAssertEqual(ProjectFilesLayout(available: 820, preferred: 600), .overlay(320))
        XCTAssertEqual(ProjectFilesLayout(available: 821, preferred: 600), .single(320))
        XCTAssertEqual(ProjectFilesLayout(available: 1100, preferred: 600), .single(460))
        XCTAssertEqual(ProjectFilesLayout(available: 1101, preferred: 700), .columns(600))
        XCTAssertEqual(ProjectFilesLayout(available: 1500, preferred: 920), .columns(780))

        let old = ProjectFileDocument("first\nbefore\nrepeat\nafter\nlast")
        let new = ProjectFileDocument("repeat\nnew\nfirst\nbefore\nrepeat\nafter\nlast")
        XCTAssertEqual(new.restoredLine(from: old, at: 2), 4)
        XCTAssertEqual(ProjectFileDocument("replacement").restoredLine(from: old, at: 2), 0)
    }

    @MainActor func testNativeReaderPreservesAnchorAcrossInsertionAndResize() throws {
        let reader = ProjectFileScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.orderOut(nil); window.contentView = nil }
        let body = (0..<180).map { "Line \($0) — preview sample" }.joined(separator: "\n")
        let original = ProjectFileDocument(body)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        reader.update(document: original, font: font)
        reader.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(reader.documentView as? NSTextView)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        let layout = try XCTUnwrap(text.layoutManager)
        let character = original.lineStarts[80]
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
        let y = rect.minY + text.textContainerOrigin.y + 2
        reader.contentView.scroll(to: NSPoint(x: 0, y: y))
        reader.reflectScrolledClipView(reader.contentView)
        XCTAssertEqual(topLine(reader, document: original), 80)

        let changed = ProjectFileDocument("Inserted A\nInserted B\n" + body)
        reader.update(document: changed, font: font)
        XCTAssertEqual(topLine(reader, document: changed), 82)
        window.setContentSize(NSSize(width: 320, height: 240))
        reader.layoutSubtreeIfNeeded()
        XCTAssertEqual(topLine(reader, document: changed), 82)
    }

    @MainActor func testNativeReaderTogglesWrappingWithFixedGutterAndReadingAnchor() throws {
        let reader = ProjectFileScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader
        defer { window.orderOut(nil); window.contentView = nil }
        let longLine = String(repeating: "long text ", count: 40)
        let original = ProjectFileDocument((0..<90).map { "\($0) \(longLine)" }.joined(separator: "\n"))
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        reader.update(document: original, font: font)
        reader.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(reader.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let glyph = layout.glyphIndexForCharacter(at: original.lineStarts[30])
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        reader.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + text.textContainerOrigin.y + 2))
        XCTAssertEqual(topLine(reader, document: original), 30)

        reader.update(document: original, font: font, wrapsLines: false)
        reader.layoutSubtreeIfNeeded()
        XCTAssertFalse(reader.hasHorizontalScroller)
        XCTAssertFalse(reader.hasVerticalScroller)
        XCTAssertGreaterThan(text.frame.width, reader.contentView.bounds.width)
        XCTAssertEqual(topLine(reader, document: original), 30)
        let gutter = try XCTUnwrap(reader.subviews.first { $0 is ProjectFileLineNumbers })
        let gutterFrame = gutter.frame
        reader.contentView.scroll(to: NSPoint(x: 120, y: reader.contentView.bounds.minY))
        reader.reflectScrolledClipView(reader.contentView)
        XCTAssertEqual(gutter.frame, gutterFrame)
        XCTAssertEqual(reader.contentView.bounds.minX, 120, accuracy: 1)

        let refreshed = ProjectFileDocument("Inserted\n" + original.text)
        reader.update(document: refreshed, font: font, wrapsLines: false)
        XCTAssertEqual(reader.contentView.bounds.minX, 120, accuracy: 1)
        XCTAssertEqual(topLine(reader, document: refreshed), 31)
        reader.update(document: refreshed, font: font, wrapsLines: true)
        XCTAssertEqual(text.frame.width, reader.contentView.bounds.width, accuracy: 1)
        XCTAssertEqual(reader.contentView.bounds.minX, 0)
        XCTAssertEqual(topLine(reader, document: refreshed), 31)
    }

    @MainActor func testNativeReaderKeepsReadingPositionAfterWrapLayout() async throws {
        let longLine = String(repeating: "prefix ", count: 380)
        let document = ProjectFileDocument((0..<75).map { "Line \($0) \(longLine)" }.joined(separator: "\n"))
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let readingLine = 30

        for style in [NSScroller.Style.overlay, .legacy] {
            let reader = ProjectFileScrollView()
            reader.scrollerStyle = style
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = reader
            defer { window.contentView = nil }
            reader.update(document: document, font: font, wrapsLines: false)
            reader.layoutSubtreeIfNeeded()
            let text = try XCTUnwrap(reader.documentView as? NSTextView)
            let layout = try XCTUnwrap(text.layoutManager)
            let glyph = layout.glyphIndexForCharacter(at: document.lineStarts[readingLine])
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            reader.contentView.scroll(to: NSPoint(x: 14_000, y: lineRect.minY + text.textContainerOrigin.y + 2))
            reader.reflectScrolledClipView(reader.contentView)
            XCTAssertGreaterThan(reader.contentView.bounds.minX, 0)
            XCTAssertEqual(topLine(reader, document: document), readingLine)

            for wrapsLines in [true, false] {
                reader.update(document: document, font: font, wrapsLines: wrapsLines)
                for _ in 0..<6 {
                    reader.layoutSubtreeIfNeeded()
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                }
                XCTAssertEqual(topLine(reader, document: document), readingLine,
                               "Scroller style \(style.rawValue), wrapping \(wrapsLines)")
            }
        }
    }

    @MainActor func testNativePaneKeepsReaderAcrossColumnAndCompactLayouts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let docs = fixture.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false)
        let name = "workbench.md"
        let source = "# Workbench\n\nThe right panel follows the viewed session.\n"
        try source.write(to: docs.appending(path: name), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "pikachu-preview")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.toggle(.root.appending("docs"))
        model.open(.init(path: .init(components: ["docs", name]), kind: .file))
        let launch = try await previewText(model)
        XCTAssertEqual(launch, source)

        let host = NSHostingView(rootView: GeometryReader { geometry in
            ProjectFilesPane(model: model, root: root,
                             layout: ProjectFilesLayout(available: geometry.size.width, preferred: 600),
                             keyboardOpenRequest: 0, close: {})
                .frame(maxWidth: .infinity, alignment: .trailing)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        func findReader(in view: NSView) -> ProjectFileScrollView? {
            if let reader = view as? ProjectFileScrollView { return reader }
            return view.subviews.lazy.compactMap { findReader(in: $0) }.first
        }

        var firstReader: ProjectFileScrollView?
        for (windowWidth, expectedReaderWidth, label) in [(1120.0, 399.0, "wide"), (828.0, 327.0, "compact"),
                                                           (680.0, 320.0, "overlay")] {
            window.setContentSize(NSSize(width: windowWidth, height: 600))
            for _ in 0..<6 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            if windowWidth < 1101 {
                model.region = .preview
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let reader = try XCTUnwrap(findReader(in: host))
            let gutter = try XCTUnwrap(reader.subviews.first { $0 is ProjectFileLineNumbers })
            XCTAssertTrue(gutter.window === window)
            let textView = try XCTUnwrap(reader.documentView as? NSTextView)
            let textOrigin = textView.convert(textView.textContainerOrigin, to: reader)
            XCTAssertGreaterThan(textOrigin.x, gutter.frame.maxX, "Line numbers must leave the full source line visible")
            if let firstReader { XCTAssertTrue(reader === firstReader, "Reader was replaced in \(label)") }
            else { firstReader = reader }
            XCTAssertEqual(reader.frame.width, expectedReaderWidth, accuracy: 1)
            XCTAssertEqual((reader.documentView as? NSTextView)?.string, source)
            XCTAssertEqual(model.selected?.relativePath, "docs/workbench.md")

            let captureRect = NSRect(x: host.bounds.maxX - (label == "wide" ? 600 : expectedReaderWidth),
                                     y: host.bounds.minY, width: label == "wide" ? 600 : expectedReaderWidth,
                                     height: host.bounds.height)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: captureRect),
               !captureRect.isEmpty {
                host.cacheDisplay(in: captureRect, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = "Project files — \(label)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor func testTabStripResizeScrollTargetPrioritizesValidAccessibilityFocus() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "first".write(to: fixture.appending(path: "first.md"), atomically: true, encoding: .utf8)
        try "second".write(to: fixture.appending(path: "second.md"), atomically: true, encoding: .utf8)
        try "third".write(to: fixture.appending(path: "third.md"), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let first = ProjectFilePath.root.appending("first.md")
        let second = ProjectFilePath.root.appending("second.md")
        let third = ProjectFilePath.root.appending("third.md")
        let stale = ProjectFilePath.root.appending("closed.md")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.open(.init(path: first, kind: .file))
        model.open(.init(path: second, kind: .file))
        model.open(.init(path: third, kind: .file))
        _ = try await previewText(model)

        XCTAssertEqual(ProjectFilesTabStrip.resizeScrollTarget(
            accessibilityPath: first, keyboardPath: second, selectedPath: third, tabs: model.tabs
        ), first)
        XCTAssertEqual(ProjectFilesTabStrip.resizeScrollTarget(
            accessibilityPath: first, keyboardPath: nil, selectedPath: third, tabs: model.tabs
        ), first)
        XCTAssertEqual(ProjectFilesTabStrip.resizeScrollTarget(
            accessibilityPath: stale, keyboardPath: second, selectedPath: third, tabs: model.tabs
        ), second)
        XCTAssertEqual(ProjectFilesTabStrip.resizeScrollTarget(
            accessibilityPath: stale, keyboardPath: stale, selectedPath: third, tabs: model.tabs
        ), third)
        XCTAssertNil(ProjectFilesTabStrip.resizeScrollTarget(
            accessibilityPath: first, keyboardPath: second, selectedPath: third, tabs: []
        ))
    }

    func testRelativePathResolvesProjectFilesAndRejectsOutsideOrInvalidPaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let project = fixture.appending(path: "project", directoryHint: .isDirectory)
        let sibling = fixture.appending(path: "project-other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project.appending(path: "Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let inside = project.appending(path: "Sources/App.swift")
        XCTAssertEqual(ProjectFilePath.relativePath(from: inside, within: project.path),
                       ProjectFilePath(components: ["Sources", "App.swift"]))
        let resolvedInside = inside.resolvingSymlinksInPath()
        XCTAssertEqual(ProjectFilePath.relativePath(from: resolvedInside, within: project.path),
                       ProjectFilePath(components: ["Sources", "App.swift"]))
        XCTAssertNil(ProjectFilePath.relativePath(from: project, within: project.path))
        XCTAssertNil(ProjectFilePath.relativePath(from: sibling.appending(path: "Other.swift"), within: project.path))
        XCTAssertNil(ProjectFilePath.relativePath(from: project.appending(path: ".git/HEAD"), within: project.path))
        XCTAssertNil(ProjectFilePath.relativePath(from: URL(string: "https://example.com/App.swift")!, within: project.path))
    }

    @MainActor func testTranscriptFileOpenerPreservesLineFragmentsForHandlers() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sub = fixture.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appending(path: "App.swift")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)

        var opened: [URL] = []
        let action = TranscriptFileOpener.openAction(workspaceDirectory: fixture) { opened.append($0) }
        action(URL(string: "Sources/App.swift:2:4")!)
        action(URL(string: file.absoluteString + "#L1-L2")!)
        action(file)

        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(TranscriptFileOpener.withoutFragment(opened[0]), file.standardizedFileURL)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: opened[0]), 2)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: opened[1]), 1)
        XCTAssertNil(TranscriptFileOpener.lineReference(in: opened[2]))
        XCTAssertEqual(opened[2], file.standardizedFileURL)
    }

    @MainActor func testOpenFromTranscriptLocatesProjectFileAndFallsBackForUnpreviewableTargets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let nestedDir = fixture.appending(path: "Sources/Feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let targetFile = nestedDir.appending(path: "Detail.swift")
        let lines = (1...80).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        try lines.write(to: targetFile, atomically: true, encoding: .utf8)
        let binaryFile = fixture.appending(path: "image.bin")
        try Data([0x00, 0xFF, 0x01]).write(to: binaryFile)

        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel()
        let controls = ProjectFilesControls()
        model.bind(root: root, isOpen: false)

        var fallbackCalls = 0
        let binaryOutcome = await model.openFromTranscript(
            path: .root.appending("image.bin"),
            in: root,
            activatePane: {
                controls.open()
                model.bind(root: root, isOpen: true)
            },
            onFallback: { fallbackCalls += 1 }
        ).value
        XCTAssertEqual(binaryOutcome, .fallback)
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertFalse(controls.isOpen)
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(model.tabs.isEmpty)

        let path = ProjectFilePath(components: ["Sources", "Feature", "Detail.swift"])
        let openOutcome = await model.openFromTranscript(
            path: path,
            in: root,
            line: 45,
            activatePane: {
                controls.open()
                model.bind(root: root, isOpen: true)
            },
            onFallback: { fallbackCalls += 1 }
        ).value
        XCTAssertEqual(openOutcome, .opened)
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertTrue(controls.isOpen)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.selected, path)
        XCTAssertEqual(model.region, .preview)
        XCTAssertEqual(model.lineTarget?.path, path)
        XCTAssertEqual(model.lineTarget?.line, 45)
        XCTAssertTrue(model.expanded.contains(ProjectFilePath(components: ["Sources"])))
        XCTAssertTrue(model.expanded.contains(ProjectFilePath(components: ["Sources", "Feature"])))
        let located = try await waitFor { model.directoryLocation?.row }
        XCTAssertEqual(located, .entry(path))

        let document = try XCTUnwrap({ () -> ProjectFileDocument? in
            if case .document(let doc) = model.preview { return doc }
            return nil
        }())
        let scrollView = ProjectFileScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        scrollView.update(document: document,
                          font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                          wrapsLines: true,
                          targetLine: model.lineTarget)
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(topLine(scrollView, document: document) ?? 0, 40)
    }

    @MainActor func testOpenFromTranscriptDoesNotFallbackWhenCancelledOrBlocked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "hello".write(to: fixture.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let reader = DelayedReader()
        let model = ProjectFilesModel(reader: reader)
        var fallbackCalls = 0
        var isAllowed = false
        let task = model.openFromTranscript(
            path: .root.appending("Note.md"),
            in: root,
            canOpen: { isAllowed },
            activatePane: {},
            onFallback: { fallbackCalls += 1 }
        )
        while await !reader.isWaitingForRead {
            try await Task.sleep(for: .milliseconds(5))
        }
        await reader.releaseReads()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertTrue(model.tabs.isEmpty)
        isAllowed = true
    }

    func testHandoffFileReferencesResolveWithinTheRecordedDirectory() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = ProjectFilePath(components: ["Sources", "Current #1.swift"])
        let path = "Sources/Current #1.swift"
        XCTAssertEqual(try ProjectFilePath.handoffReference(root.path + "/" + path, in: root), expected)
        XCTAssertEqual(try ProjectFilePath.handoffReference("./" + path, recordedBase: root.path, in: root), expected)
        for base in [nil, "Sources", root.path + "/../Another"] {
            XCTAssertThrowsError(try ProjectFilePath.handoffReference(path, recordedBase: base, in: root)) {
                XCTAssertEqual($0 as? ProjectFileIssue, .handoffPathUnknown)
            }
        }
        for path in ["../Current #1.swift", "Sources/../Current #1.swift", "/tmp/Current #1.swift",
                     ".git/config", "https://example.test/file", "Sources//File.swift", root.path] {
            XCTAssertThrowsError(try ProjectFilePath.handoffReference(path, recordedBase: root.path, in: root), path) {
                XCTAssertEqual($0 as? ProjectFileIssue, .handoffPathOutsideDirectory)
            }
        }
    }

    @MainActor func testHandoffUsesSavedBaseAfterGitRootChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let repo = fixture.appending(path: "Repo with spaces", directoryHint: .isDirectory)
        let directory = repo.appending(path: "Package", directoryHint: .isDirectory)
        let decoy = directory.appending(path: "Package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        func gitInit(_ checkout: URL) throws {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", checkout.path, "init", "--quiet", "--template="]
            git.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        try gitInit(repo)
        let filename = "Renamed #1.swift"
        let actual = directory.appending(path: filename)
        try "actual".write(to: actual, atomically: true, encoding: .utf8)
        try "decoy".write(to: decoy.appending(path: filename), atomically: true, encoding: .utf8)
        try "sibling".write(to: repo.appending(path: filename), atomically: true, encoding: .utf8)

        let model = ProjectFilesModel()
        let root = ProjectFilesRoot(projectID: UUID(), path: directory.path, displayName: "Package")
        model.bind(root: root, isOpen: false)
        func save(_ file: TurnFileChanges.File) throws -> SessionHandoffFile {
            let entry = SessionHandoffFile(path: file.path, changes: [.init(segmentID: UUID(), turnID: UUID(), file: file)])
            return try JSONDecoder().decode(SessionHandoffFile.self, from: JSONEncoder().encode(entry))
        }
        let storedPath = "Package/\(filename)"
        let saved = try save(.init(path: storedPath, previousPath: "Package/BeforeRename.swift",
                                   pathBase: repo.path, kind: .renamed, added: 1, deleted: 0))
        let legacy = try save(.init(path: storedPath, kind: .modified, added: 1, deleted: 0))
        XCTAssertEqual(saved.pathBase, repo.path)
        XCTAssertNil(legacy.pathBase)
        let nested = try save(.init(path: storedPath, pathBase: directory.path, kind: .modified, added: 1, deleted: 0))
        let ambiguous = SessionHandoffFile(path: storedPath, changes: saved.changes + nested.changes)
        XCTAssertNil(ambiguous.pathBase)

        func preview() async throws -> ProjectFilesModel.TranscriptOpenOutcome {
            let path = try ProjectFilePath.handoffReference(saved.path, recordedBase: saved.pathBase, in: directory)
            return await model.openFromTranscript(path: path, in: root,
                                                  activatePane: { model.bind(root: root, isOpen: true) }).value
        }
        func expectOriginalPreview() async throws {
            let opened = try await preview()
            XCTAssertEqual(opened, .opened)
            let contents = try await previewText(model)
            XCTAssertEqual(contents, "actual")
            XCTAssertThrowsError(try ProjectFilePath.handoffReference(legacy.path, recordedBase: legacy.pathBase,
                                                                     in: directory)) {
                XCTAssertEqual($0 as? ProjectFileIssue, .handoffPathUnknown)
            }
        }
        try await expectOriginalPreview()
        try gitInit(directory)
        try await expectOriginalPreview()
        try FileManager.default.removeItem(at: repo.appending(path: ".git"))
        try FileManager.default.removeItem(at: directory.appending(path: ".git"))
        try await expectOriginalPreview()

        XCTAssertThrowsError(try ProjectFilePath.handoffReference(filename, recordedBase: saved.pathBase,
                                                                 in: directory)) {
            XCTAssertEqual($0 as? ProjectFileIssue, .handoffPathOutsideDirectory)
        }
        try FileManager.default.removeItem(at: actual)
        let removed = try await preview()
        XCTAssertEqual(removed, .unavailable(.missing))
        XCTAssertEqual(model.tabs.map(\.id), [.root.appending(filename)])
    }

    @MainActor func testHandoffPreviewCancelsOnVisibilityAndTabChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for name in ["Current.swift", "Other.swift"] {
            try name.write(to: fixture.appending(path: name), atomically: true, encoding: .utf8)
        }
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let controls = ProjectFilesControls()
        let reader = DelayedReader(delaysReads: false)
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: root, isOpen: false)
        func request(_ name: String) throws -> Task<ProjectFilesModel.TranscriptOpenOutcome, Never> {
            let path = try ProjectFilePath.handoffReference(fixture.appending(path: name).path, in: fixture)
            let visibility = controls.visibilityRevision
            return model.openFromTranscript(path: path, in: root,
                                         canOpen: { controls.visibilityRevision == visibility },
                                         activatePane: {
                                             controls.open()
                                             model.bind(root: root, isOpen: true)
                                         })
        }
        func waitForRead() async -> Bool {
            for _ in 0..<100 {
                if await reader.isWaitingForRead { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        let first = try await request("Current.swift").value
        let second = try await request("Other.swift").value
        XCTAssertEqual(first, .opened)
        XCTAssertEqual(second, .opened)
        let other = ProjectFilePath.root.appending("Other.swift")

        await reader.holdReads()
        let lateSuccess = try request("Current.swift")
        let readingSuccess = await waitForRead()
        XCTAssertTrue(readingSuccess)
        model.activateTab(other)
        await reader.releaseReads()
        let selectionOutcome = await lateSuccess.value
        XCTAssertEqual(selectionOutcome, .cancelled)
        XCTAssertEqual(model.selected, other)

        await reader.holdReads()
        let lateFailure = try request("Gone.swift")
        let readingFailure = await waitForRead()
        XCTAssertTrue(readingFailure)
        controls.close()
        // A close and reopen may both arrive before view observation binds either transition.
        controls.open()
        await reader.releaseReads()
        let reopenOutcome = await lateFailure.value
        XCTAssertEqual(reopenOutcome, .cancelled)
        XCTAssertEqual(model.selected, other)

        await reader.holdReads()
        let lateOpen = try request("Current.swift")
        let readingOpen = await waitForRead()
        XCTAssertTrue(readingOpen)
        controls.close()
        model.bind(root: root, isOpen: false)
        await reader.releaseReads()
        let closeOutcome = await lateOpen.value
        XCTAssertEqual(closeOutcome, .cancelled)
        XCTAssertFalse(controls.isOpen)
        XCTAssertFalse(model.isOpen)
    }

    @MainActor func testHandoffPreviewReusesTabsAndKeepsTheCurrentPreviewOnFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appending(path: "Current #1.swift")
        try "let current = true".write(to: file, atomically: true, encoding: .utf8)
        try Data([0x00, 0xFF]).write(to: fixture.appending(path: "Blob.bin"))
        try FileManager.default.createSymbolicLink(at: fixture.appending(path: "Linked.swift"), withDestinationURL: file)

        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: false)
        var activations = 0
        func open(_ name: String) async -> ProjectFilesModel.TranscriptOpenOutcome {
            await model.openFromTranscript(path: .root.appending(name), in: root, activatePane: {
                activations += 1
                model.bind(root: root, isOpen: true)
            }).value
        }
        let missing = await open("Gone.swift")
        XCTAssertEqual(missing, .unavailable(.missing))
        XCTAssertFalse(model.isOpen)

        let first = await open("Current #1.swift")
        let again = await open("Current #1.swift")
        XCTAssertEqual(first, .opened)
        XCTAssertEqual(again, .opened)
        XCTAssertEqual(model.tabs.map(\.id), [.root.appending("Current #1.swift")])

        let unsupported = await open("Blob.bin")
        let link = await open("Linked.swift")
        XCTAssertEqual(unsupported, .unavailable(.unsupported))
        XCTAssertEqual(link, .unavailable(.link))
        XCTAssertEqual(model.selected, .root.appending("Current #1.swift"))
        XCTAssertEqual(activations, 2)
    }

    @MainActor func testHandoffPreviewDiscardsOutdatedSuccessAndFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "current".write(to: fixture.appending(path: "Current.md"), atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let reader = DelayedReader()
        let model = ProjectFilesModel(reader: reader)
        model.bind(root: root, isOpen: false)
        let stale = model.openFromTranscript(path: .root.appending("Gone.md"), in: root,
                                             canOpen: { false }, activatePane: { XCTFail("Stale preview") })
        await reader.releaseReads()
        let staleResult = await stale.value
        XCTAssertEqual(staleResult, .cancelled)

        let outdated = model.openFromTranscript(path: .root.appending("Current.md"), in: root,
                                                activatePane: { XCTFail("Cancelled preview") })
        let latest = model.openFromTranscript(path: .root.appending("Current.md"), in: root, activatePane: {
            model.bind(root: root, isOpen: true)
        })
        let outdatedResult = await outdated.value
        let latestResult = await latest.value
        XCTAssertEqual(outdatedResult, .cancelled)
        XCTAssertEqual(latestResult, .opened)
        XCTAssertEqual(model.tabs.map(\.id), [.root.appending("Current.md")])
    }

    @MainActor private func topLine(_ reader: ProjectFileScrollView, document: ProjectFileDocument) -> Int? {
        guard let text = reader.documentView as? NSTextView, let layout = text.layoutManager,
              let container = text.textContainer else { return nil }
        let top = reader.contentView.bounds.minY - text.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: top), in: container)
        return document.line(at: layout.characterIndexForGlyph(at: glyph))
    }

    @MainActor private func previewText(_ model: ProjectFilesModel) async throws -> String? {
        for _ in 0..<100 {
            if case .document(let document) = model.preview { return document.text }
            if case .failure(let error) = model.preview { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @MainActor private func assertRootUnavailable(_ model: ProjectFilesModel) async throws {
        _ = try await waitFor {
            guard case .failure(.rootUnavailable) = model.preview else { return nil as Bool? }
            return true
        }
        XCTAssertEqual(model.rows.count, 1)
        guard case .failure(.rootUnavailable) = model.rows.first?.content else {
            return XCTFail("The directory tree should be replaced with the unavailable state")
        }
    }

    @MainActor private func waitFor<Value>(_ check: () -> Value?) async throws -> Value {
        for _ in 0..<100 {
            if let value = check() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(check(), "Timed out waiting for fixture state")
    }

    @MainActor private func selectedDraft(in fixture: URL) async throws -> (ProjectFilesModel, ProjectFilesRoot, URL) {
        let file = fixture.appending(path: "draft.md")
        try "# Draft".write(to: file, atomically: true, encoding: .utf8)
        let root = ProjectFilesRoot(projectID: UUID(), path: fixture.path, displayName: "Project")
        let model = ProjectFilesModel()
        model.bind(root: root, isOpen: true)
        model.open(.init(path: .root.appending("draft.md"), kind: .file))
        let contents = try await previewText(model)
        XCTAssertEqual(contents, "# Draft")
        return (model, root, file)
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pikachu-file-preview-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private var markdownImageSample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Verification/Fixtures/markdown-typography/sample.png")
    }

    private func writeReplacementMarkdownImage(to url: URL) throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"))
        try png.write(to: url, options: .atomic)
    }
}

actor DelayedReader: ProjectFilesReading {
    private let reader = ProjectFilesReader()
    private var isReleased: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var holdValidation = false
    private var validation: CheckedContinuation<Void, Never>?
    private var holdsMarkdownImage = false
    private var markdownImage: CheckedContinuation<Void, Never>?
    private var holdsRootListing = false
    private var rootListing: CheckedContinuation<Void, Never>?

    init(delaysReads: Bool = true) {
        isReleased = !delaysReads
    }

    func bindRoot(at path: String) async throws -> ProjectFilesReader.Root {
        try await reader.bindRoot(at: path)
    }

    func directory(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> [ProjectFileEntry] {
        if path == .root, holdsRootListing {
            holdsRootListing = false
            await withCheckedContinuation { rootListing = $0 }
        }
        return try await reader.directory(at: root, path: path)
    }

    func read(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> ProjectFilePreview {
        if !isReleased { await withCheckedContinuation { waiting.append($0) } }
        try Task.checkCancellation()
        return try await reader.read(at: root, path: path)
    }

    func readMarkdownImage(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> CGImage {
        let image = try await reader.readMarkdownImage(at: root, path: path)
        if holdsMarkdownImage {
            holdsMarkdownImage = false
            await withCheckedContinuation { markdownImage = $0 }
        }
        return image
    }

    func validateOpenTarget(_ target: ProjectFilesReader.OpenTarget) async throws {
        if holdValidation {
            holdValidation = false
            await withCheckedContinuation { validation = $0 }
        }
        try await reader.validateOpenTarget(target)
    }

    var isWaitingForValidation: Bool { validation != nil }
    var isWaitingForMarkdownImage: Bool { markdownImage != nil }
    var isWaitingForRead: Bool { !waiting.isEmpty }
    var isWaitingForRootListing: Bool { rootListing != nil }

    func holdNextValidation() { holdValidation = true }
    func holdNextMarkdownImage() { holdsMarkdownImage = true }

    func releaseMarkdownImage() {
        markdownImage?.resume()
        markdownImage = nil
    }

    func holdNextRootListing() { holdsRootListing = true }

    func releaseRootListing() {
        rootListing?.resume()
        rootListing = nil
    }

    func releaseValidation() {
        validation?.resume()
        validation = nil
    }

    func releaseReads() {
        isReleased = true
        for request in waiting { request.resume() }
        waiting.removeAll()
    }

    func holdReads() { isReleased = false }
}
