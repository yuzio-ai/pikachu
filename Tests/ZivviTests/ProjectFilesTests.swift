import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

final class ProjectFilesTests: XCTestCase {
    @MainActor func testEditorMarkdownImageUsesBoundReaderInPreviewMode() async throws {
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
        let model = WorkbenchTabsModel()
        let tab = try await openEditorFile(document, in: fixture, model: model)
        XCTAssertNotNil(model.markdownImageLoader(for: tab))
        tab.isMarkdownPreview = false
        XCTAssertNil(model.markdownImageLoader(for: tab))
        tab.isMarkdownPreview = true
        let loader = try XCTUnwrap(model.markdownImageLoader(for: tab))
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
        let (model, tab, _) = try await selectedDraft(in: fixture)
        let imageFile = fixture.appending(path: "sample.png")
        let reference = try XCTUnwrap(URL(string: "sample.png"))
        try FileManager.default.copyItem(at: markdownImageSample, to: imageFile)
        let first = try XCTUnwrap(model.markdownImageLoader(for: tab))
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
        model.reloadTab(tab)
        guard case .placeholder = request.status(for: nil) else {
            return XCTFail("Refreshing must stop displaying the previous image")
        }
        await request.update(url: reference, loader: nil, key: nil)
        let missing = try await waitFor { () -> MarkdownImageLoader? in
            guard let loader = model.markdownImageLoader(for: tab), loader.revision != first.revision else { return nil }
            return loader
        }
        XCTAssertNotEqual(missing.revision, first.revision)
        XCTAssertNil(MarkdownImageRequest().key(for: missing, url: reference))
        let missingKey = try XCTUnwrap(request.key(for: missing, url: reference))
        await request.update(url: reference, loader: missing, key: missingKey)
        guard case .failed = request.status(for: missingKey) else {
            return XCTFail("The removed image must report an unavailable state")
        }

        try writeReplacementMarkdownImage(to: imageFile)
        model.reloadTab(tab)
        let recovered = try await waitFor { () -> MarkdownImageLoader? in
            guard let loader = model.markdownImageLoader(for: tab), loader.revision != missing.revision else { return nil }
            return loader
        }
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
        let reader = DelayedReader()
        let model = WorkbenchTabsModel(reader: reader)
        let tab = try await openEditorFile(document, in: fixture, model: model)
        let first = try XCTUnwrap(model.markdownImageLoader(for: tab))
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
        model.reloadTab(tab)
        await request.update(url: reference, loader: nil, key: nil)
        let refreshed = try await waitFor { () -> MarkdownImageLoader? in
            guard let loader = model.markdownImageLoader(for: tab), loader.revision != first.revision else { return nil }
            return loader
        }
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
        try FileManager.default.copyItem(at: markdownImageSample, to: fixture.appending(path: "sample.png"))
        let reader = DelayedReader()
        let model = WorkbenchTabsModel(reader: reader)
        let tab = try await openEditorFile(.root.appending("README.md"), in: fixture, model: model)
        let reference = try XCTUnwrap(URL(string: "sample.png"))
        let loader = try XCTUnwrap(model.markdownImageLoader(for: tab))
        let request = MarkdownImageRequest()
        request.request()
        let key = try XCTUnwrap(request.key(for: loader, url: reference))

        await reader.holdNextMarkdownImage()
        let pending = Task { await request.update(url: reference, loader: loader, key: key) }
        defer { Task { await reader.releaseMarkdownImage() } }
        try await waitForReader { await reader.isWaitingForMarkdownImage }
        tab.isMarkdownPreview = false
        let sourceLoader = model.markdownImageLoader(for: tab)
        XCTAssertNil(sourceLoader)
        await request.update(url: reference, loader: sourceLoader, key: request.key(for: sourceLoader, url: reference))
        await reader.releaseMarkdownImage()
        await pending.value
        guard case .placeholder = request.status(for: key) else {
            return XCTFail("An earlier preview request must not restore the image in source mode")
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
                XCTAssertEqual(run.swiftUI.foregroundColor, run.link == nil ? nil : ZivviTheme.infoText)
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
        let (model, tab, file) = try await selectedDraft(in: fixture)

        var revealed: [URL] = []
        var actions = TranscriptFileOpener.Actions()
        actions.revealInFinder = { revealed.append($0) }
        func reveal() async {
            guard let request = model.externalOpenRequest(for: tab) else { return }
            await TranscriptFileOpener.reveal(request, actions: actions)
        }
        await reveal()
        XCTAssertEqual(revealed.map(\.path), [file.path])

        try "# Revised draft".write(to: file, atomically: true, encoding: .utf8)
        await reveal()
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(tab.saveError, ProjectFileIssue.replaced.message)
        XCTAssertNil(model.externalOpenRequest(for: tab))
        model.reloadTab(tab)
        _ = try await waitFor { tab.openTarget }
        XCTAssertEqual(tab.savedDocument?.text, "# Revised draft")
        await reveal()
        XCTAssertEqual(revealed.map(\.path), [file.path, file.path])
    }

    @MainActor func testCommandFailureOnlyFallsBackWhileTheEditorAndFileAreCurrent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, tab, file) = try await selectedDraft(in: fixture)
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
            guard let request = model.externalOpenRequest(for: tab) else { return }
            await TranscriptFileOpener.open(request, configuration: configuration, actions: actions)
        }

        await requestOpen(using: actions)
        XCTAssertEqual(launchCount, 1)
        XCTAssertTrue(opened.isEmpty)
        let failure = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        await failure()
        XCTAssertEqual(opened.map(\.path), [file.path])

        await requestOpen(using: actions)
        let failureFromClosedEditor = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        model.isEditorVisible = false
        model.isEditorVisible = true
        await failureFromClosedEditor()
        XCTAssertEqual(launchCount, 2)
        XCTAssertEqual(opened.count, 1)

        await requestOpen(using: actions)
        let failureAfterRemoval = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        try FileManager.default.removeItem(at: file)
        await failureAfterRemoval()
        XCTAssertEqual(launchCount, 3)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(tab.saveError, ProjectFileIssue.missing.message)
        XCTAssertNil(model.externalOpenRequest(for: tab))

        try "# Restored draft".write(to: file, atomically: true, encoding: .utf8)
        model.reloadTab(tab)
        _ = try await waitFor { tab.openTarget }
        actions.launch = { _, _ in throw CocoaError(.fileNoSuchFile) }
        await requestOpen(using: actions)
        XCTAssertEqual(opened.map(\.path), [file.path, file.path])
    }

    @MainActor func testSystemOpenFailureRechecksContextBeforeRevealingInFinder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (model, tab, file) = try await selectedDraft(in: fixture)
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

        let first = try XCTUnwrap(model.externalOpenRequest(for: tab))
        await TranscriptFileOpener.open(first, configuration: .init(preference: .system), actions: firstActions)
        XCTAssertEqual(opened.map(\.path), [file.path])
        XCTAssertEqual(revealed.map(\.path), [file.path])

        actions.openApplication = {
            opened.append($0)
            model.isEditorVisible = false
            return false
        }
        let closingActions = actions
        let closing = try XCTUnwrap(model.externalOpenRequest(for: tab))
        await TranscriptFileOpener.open(closing, configuration: .init(preference: .system), actions: closingActions)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(revealed.count, 1)
    }

    @MainActor func testProjectNavigatorPaginatesWithinTheExpandedDirectory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = ProjectFilePath.root.appending("Sources")
        let sources = fixture.appending(path: directory.relativePath)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        for index in 0...201 {
            try Data().write(to: sources.appending(path: String(format: "file-%03d", index)))
        }
        let model = ProjectNavigatorModel().fileTree(for: ProjectRecord(id: UUID(), path: fixture.path))
        let directoryID = ProjectFilesModel.TreeRow.ID.entry(directory)
        _ = try await waitFor { model.rows.first { $0.id == directoryID } }
        model.toggle(directory)
        let moreID = ProjectFilesModel.TreeRow.ID.more(directory)
        _ = try await waitFor { model.rows.first { $0.id == moreID } }
        let firstHidden = ProjectFilesModel.TreeRow.ID.entry(directory.appending("file-200"))
        XCTAssertFalse(model.rows.contains { $0.id == firstHidden })

        model.showMore(in: directory)
        XCTAssertTrue(model.rows.contains { $0.id == firstHidden })
        XCTAssertTrue(model.rows.contains { $0.id == .entry(directory.appending("file-201")) })
        XCTAssertFalse(model.rows.contains { $0.id == moreID })

        model.toggle(directory)
        XCTAssertEqual(model.rows.map(\.id), [directoryID])
        model.toggle(directory)
        _ = try await waitFor { model.rows.first { $0.id == moreID } }
        XCTAssertFalse(model.rows.contains { $0.id == firstHidden })
    }

    @MainActor func testProjectNavigatorDiscardsListingFromPreviousProjectRoot() async throws {
        let previous = try makeFixture()
        let current = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.removeItem(at: current)
        }
        try Data().write(to: previous.appending(path: "old.md"))
        try Data().write(to: current.appending(path: "new.md"))
        let reader = DelayedReader()
        let navigator = ProjectNavigatorModel(reader: reader)
        let id = UUID()

        await reader.holdNextRootListing()
        let tree = navigator.fileTree(for: ProjectRecord(id: id, path: previous.path))
        defer { Task { await reader.releaseRootListing() } }
        try await waitForReader { await reader.isWaitingForRootListing }

        XCTAssertTrue(navigator.fileTree(for: ProjectRecord(id: id, path: current.path)) === tree)
        let newID = ProjectFilesModel.TreeRow.ID.entry(.root.appending("new.md"))
        _ = try await waitFor { tree.rows.first { $0.id == newID } }
        await reader.releaseRootListing()
        try await waitForReader { await reader.didFinishPausedRootListing }
        // Observe the tree while the cancelled task resumes with its old snapshot.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(tree.rows.map(\.id), [newID])
        }
    }

    @MainActor func testProjectNavigatorRejectsReplacementRootAndRecoversOriginal() async throws {
        let fixture = try makeFixture()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: fixture) }
        let working = fixture.appending(path: "project", directoryHint: .isDirectory)
        let retired = fixture.appending(path: "previous-project", directoryHint: .isDirectory)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        try Data().write(to: working.appending(path: "original.md"))
        let tree = ProjectNavigatorModel().fileTree(for: ProjectRecord(id: UUID(), path: working.path))
        let original = ProjectFilesModel.TreeRow.ID.entry(.root.appending("original.md"))
        _ = try await waitFor { tree.rows.first { $0.id == original } }

        try manager.moveItem(at: working, to: retired)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        try Data().write(to: working.appending(path: "replacement.md"))
        tree.refresh()
        _ = try await waitFor { tree.rows.first { if case .failure(.rootUnavailable) = $0.content { true } else { false } } }
        XCTAssertEqual(tree.rows.count, 1)

        try manager.removeItem(at: working)
        try manager.moveItem(at: retired, to: working)
        tree.refresh()
        _ = try await waitFor { tree.rows.first { $0.id == original } }
        XCTAssertEqual(tree.rows.map(\.id), [original])
    }

    @MainActor func testEditorTabsPreserveModeAndSelectAdjacentTabOnClose() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = WorkbenchTabsModel()
        let project = ProjectRecord(id: UUID(), path: fixture.path)
        let paths = ["One.md", "Two.md", "Three.md"].map { ProjectFilePath.root.appending($0) }
        for path in paths {
            try Data(path.name.utf8).write(to: fixture.appending(path: path.name))
            model.openFile(project: project, entry: .init(path: path, kind: .file))
        }
        XCTAssertEqual(model.editorTabs.count, 3)
        let first = model.editorTabs[0]
        let middle = model.editorTabs[1]
        let last = model.editorTabs[2]
        first.isMarkdownPreview = false
        model.activateEditorTab(middle.id)
        model.forceCloseEditorTab(middle.id)
        XCTAssertTrue(model.activeEditorTab === last)
        model.forceCloseEditorTab(last.id)
        XCTAssertTrue(model.activeEditorTab === first)
        XCTAssertFalse(first.isMarkdownPreview)
        model.forceCloseEditorTab(first.id)
        XCTAssertFalse(model.isEditorVisible)
        XCTAssertNil(model.activeEditorTab)
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

        let model = WorkbenchTabsModel()
        let project = ProjectRecord(id: UUID(), path: directory.path)
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

        func preview() async throws -> WorkbenchTabsModel.LinkedFileOpenOutcome {
            let path = try ProjectFilePath.handoffReference(saved.path, recordedBase: saved.pathBase, in: directory)
            let isCurrent = model.beginLinkedFileOpen { true }
            return await model.openLinkedFile(project: project, rootPath: directory.path, path: path, isCurrent: isCurrent)
        }
        func expectOriginalPreview() async throws {
            let opened = try await preview()
            XCTAssertEqual(opened, .opened)
            XCTAssertEqual(model.activeEditorTab?.savedDocument?.text, "actual")
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
        XCTAssertEqual(model.editorTabs.count, 1)
        XCTAssertEqual(model.activeEditorTab?.savedDocument?.text, "actual")
    }

    @MainActor private func topLine(_ reader: ProjectFileScrollView, document: ProjectFileDocument) -> Int? {
        guard let text = reader.documentView as? NSTextView, let layout = text.layoutManager,
              let container = text.textContainer else { return nil }
        let top = reader.contentView.bounds.minY - text.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: top), in: container)
        return document.line(at: layout.characterIndexForGlyph(at: glyph))
    }

    @MainActor private func waitForReader(_ check: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(nil as Bool?, "Timed out waiting for the reader fixture")
    }

    @MainActor private func waitFor<Value>(_ check: () -> Value?) async throws -> Value {
        for _ in 0..<100 {
            if let value = check() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(check(), "Timed out waiting for fixture state")
    }

    @MainActor private func openEditorFile(_ path: ProjectFilePath, in fixture: URL,
                                           model: WorkbenchTabsModel) async throws -> WorkbenchTabsModel.EditorTab {
        let project = ProjectRecord(id: UUID(), path: fixture.path)
        model.openFile(project: project, entry: .init(path: path, kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        _ = try await waitFor { tab.savedDocument }
        return tab
    }

    @MainActor private func selectedDraft(in fixture: URL) async throws -> (WorkbenchTabsModel, WorkbenchTabsModel.EditorTab, URL) {
        let file = fixture.appending(path: "draft.md")
        try "# Draft".write(to: file, atomically: true, encoding: .utf8)
        let model = WorkbenchTabsModel()
        let tab = try await openEditorFile(.root.appending("draft.md"), in: fixture, model: model)
        XCTAssertEqual(tab.savedDocument?.text, "# Draft")
        return (model, tab, file)
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "zivvi-file-preview-\(UUID())", directoryHint: .isDirectory)
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
    private var holdValidation = false
    private var validation: CheckedContinuation<Void, Never>?
    private var holdsMarkdownImage = false
    private var markdownImage: CheckedContinuation<Void, Never>?
    private var holdsRootListing = false
    private var rootListing: CheckedContinuation<Void, Never>?

    private(set) var didFinishPausedRootListing = false

    func bindRoot(at path: String) async throws -> ProjectFilesReader.Root {
        try await reader.bindRoot(at: path)
    }

    func directory(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> [ProjectFileEntry] {
        guard path == .root, holdsRootListing else {
            return try await reader.directory(at: root, path: path)
        }
        holdsRootListing = false
        let listing = try await reader.directory(at: root, path: path)
        await withCheckedContinuation { rootListing = $0 }
        didFinishPausedRootListing = true
        return listing
    }

    func read(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> ProjectFilePreview {
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
}
