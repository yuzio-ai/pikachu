import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import PiRuntimeAdapter
@testable import Pikachu

private final class TestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var mono: ContinuousClock.Instant

    init(wall: Date = Date(timeIntervalSince1970: 1_795_000_000), mono: ContinuousClock.Instant = ContinuousClock.now) {
        self.wall = wall
        self.mono = mono
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            mono = mono.advanced(by: .milliseconds(Int64((seconds * 1000).rounded())))
        }
    }

    func now() -> Date { lock.withLock { wall } }
    func monotonicNow() -> ContinuousClock.Instant { lock.withLock { mono } }
}

private actor MemoryStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private final class StubSessionRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    let sessionID: String
    let file: URL?
    let disposition: @Sendable (UserPrompt) -> PromptDisposition
    var usageResponses: [Result<RuntimeUsage, Error>] = []
    private let lock = NSLock()

    init(sessionID: String = "stub-session", file: URL? = nil,
         disposition: @escaping @Sendable (UserPrompt) -> PromptDisposition = { _ in .started }) {
        self.sessionID = sessionID
        self.file = file
        self.disposition = disposition
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: sessionID, model: "GPT-5.4", thinking: "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: "openai", modelID: "gpt-5.4")
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { disposition(prompt) }
    func stop() async throws { emit(.settled(aborted: true)) }
    func close(force: Bool) async throws { emit(.disconnected(cleanupConfirmed: true)); continuation.finish() }
    func configurationOptions() async throws -> RuntimeConfigurationOptions {
        .init(models: [.init(provider: "openai", modelID: "gpt-5.4", name: "GPT-5.4")], thinkingLevels: ["low", "high"])
    }
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        .init(id: sessionID, model: selection.modelID, thinking: selection.thinking ?? "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: selection.provider, modelID: selection.modelID)
    }
    func enqueueUsage(_ result: Result<RuntimeUsage, Error>) {
        lock.withLock { usageResponses.append(result) }
    }
    func usage() async throws -> RuntimeUsage {
        let next = lock.withLock { usageResponses.isEmpty ? nil : usageResponses.removeFirst() }
        if let next { return try next.get() }
        return RuntimeUsage(sessionID: sessionID)
    }
    func emit(_ event: AgentEvent) { continuation.yield(.init(instanceID: instanceID, event: event)) }
}

@MainActor @Observable private final class TestExtensionStatusExpansion {
    var expanded = false
}

final class SessionDetailUITests: XCTestCase {
    func testCodexQuotaUsesOnlyCodexWindowsAndPreservesResetTime() throws {
        let payload = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1795250809},"secondary":{"usedPercent":71}},"other":{"primary":{"usedPercent":100}}}}"#
        let observed = Date(timeIntervalSince1970: 1_795_250_000)
        let windows = try CodexQuotaClient.windows(from: Data(payload.utf8), observedAt: observed)
        XCTAssertEqual(windows.map(\.value), ["1%", "29%"])
        XCTAssertEqual(windows.first?.resetAt, Date(timeIntervalSince1970: 1_795_250_809))
        XCTAssertTrue(windows.allSatisfy { $0.expiresAt == observed.addingTimeInterval(300) })
        let unknown = #"{"rateLimits":{"limitId":"other","primary":{"usedPercent":100}}}"#
        XCTAssertTrue(try CodexQuotaClient.windows(from: Data(unknown.utf8), observedAt: observed).isEmpty)
    }

    func testSidebarUpgradeOnlyOffersNewerStableVersions() {
        XCTAssertEqual(PikachuReleaseCheck.newerVersion(tag: "v0.10.0", installed: "0.9.9"), "0.10.0")
        XCTAssertNil(PikachuReleaseCheck.newerVersion(tag: "v1.2.0", installed: "1.2"))
        XCTAssertNil(PikachuReleaseCheck.newerVersion(tag: "v1.2.9", installed: "1.10.0"))
        XCTAssertNil(PikachuReleaseCheck.newerVersion(tag: "v2.0.0-beta.1", installed: "1.2.0"))
        XCTAssertNil(PikachuReleaseCheck.newerVersion(tag: "v2..1", installed: "1.2.0"))
    }

    func testProviderLogosMapKnownProvidersAndFallBackToTheGenericChip() throws {
        XCTAssertEqual(ProviderLogo.assetName(for: "deepseek"), "deepseek")
        XCTAssertEqual(ProviderLogo.assetName(for: "DeepSeek"), "deepseek")
        XCTAssertEqual(ProviderLogo.assetName(for: "openai-codex"), "openai")
        XCTAssertEqual(ProviderLogo.assetName(for: "google-vertex"), "googlegemini")
        XCTAssertNil(ProviderLogo.assetName(for: ""))
        XCTAssertNil(ProviderLogo.assetName(for: "unverified-provider"))
        // Wide or thin-stroked marks fill the 13 pt frame; square marks keep 12 pt.
        XCTAssertEqual(ProviderLogo.drawSide(for: "deepseek"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "google"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "openai"), 12)
        XCTAssertEqual(ProviderLogo.drawSide(for: "unverified-provider"), 12)
        let bundle = Bundle(for: AppDelegate.self)
        for name in ["openai", "anthropic", "googlegemini", "deepseek"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"), name)
            let image = try XCTUnwrap(NSImage(contentsOf: url), name)
            // Templates must carry at least 2x pixels of their draw box so thin strokes survive.
            XCTAssertGreaterThanOrEqual(image.size.width, 26, name)
        }
    }

    @MainActor func testTranscriptScrollerFollowsSessionDetailWidth() async throws {
        let workspace = WorkspaceController(store: MemoryStore(), reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        let presentation = SessionPresentation(id: UUID())
        presentation.controller.showHistory((0..<30).map { .init(id: "layout-\($0)", kind: .assistant, text: "Message \($0)") })
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(), presentation: presentation, openSettings: {}, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func transcriptScroll(in view: NSView) -> NativeTranscript.TranscriptScroll? {
            if let scroll = view as? NativeTranscript.TranscriptScroll { return scroll }
            return view.subviews.lazy.compactMap { transcriptScroll(in: $0) }.first
        }

        for width: CGFloat in [1200, 520] {
            window.setContentSize(.init(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(transcriptScroll(in: host))
            scroll.scrollerStyle = .legacy
            scroll.layoutSubtreeIfNeeded()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            XCTAssertEqual(scroll.bounds.width, width, accuracy: 1)
            XCTAssertEqual(scroll.bounds.height, host.bounds.height, accuracy: 1)
            XCTAssertGreaterThan(scroll.contentInsets.bottom, 70)
            XCTAssertEqual(scroller.convert(scroller.bounds, to: host).maxX, host.bounds.maxX, accuracy: 1)
        }
    }

    @MainActor func testWorkbenchInstallsSessionAndSidebarToggleInNativeToolbar() async throws {
        let workspace = await newConversationWorkspace()
        let visibility = TestSidebarVisibility()
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 })
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for (width, showSidebar) in [(1200.0, true), (860.0, true), (860.0, false), (860.0, true), (1200.0, true)] {
            visibility.value = showSidebar ? .all : .detailOnly
            window.setContentSize(NSSize(width: width, height: 620))
            await settleWindow(window)
            await settleWindow(window)

            let toolbar = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            let identifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
            XCTAssertEqual(identifiers.last, "PikachuSessionHeader")
            XCTAssertTrue(identifiers.contains("PikachuSidebarToggle"))
            XCTAssertEqual(identifiers.contains("PikachuSidebarHeading"), showSidebar)
            XCTAssertEqual(toolbar.items.contains { $0.itemIdentifier == .sidebarTrackingSeparator }, showSidebar)

            let visibleIdentifiers = (toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue }
            let itemWidths = toolbar.items.map { "\($0.itemIdentifier.rawValue): \($0.view?.frame.width ?? 0)" }
            XCTAssertTrue(visibleIdentifiers.contains("PikachuSessionHeader"), "Session header overflowed at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers), widths=\(itemWidths)")
            XCTAssertTrue(visibleIdentifiers.contains("PikachuSidebarToggle"), "Sidebar toggle overflowed at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers)")
            XCTAssertEqual(visibleIdentifiers.contains("PikachuSidebarHeading"), showSidebar, "Sidebar heading visibility mismatch at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers)")

            let session = try XCTUnwrap(toolbar.items.last?.view)
            XCTAssertTrue(session.window === window)
            XCTAssertGreaterThan(session.bounds.width, 350)
            XCTAssertLessThan(session.bounds.width, width)
            XCTAssertLessThanOrEqual(session.convert(session.bounds, to: nil).maxX, width + 1)
        }
    }

    @MainActor func testWorkbenchProjectNameCreatesSessionWithoutOpeningSidebar() async throws {
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let otherProject = ProjectRecord(path: NSHomeDirectory())
        let original = SessionReference(projectID: project.id)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [otherProject, project]
        snapshot.sessions = [SessionReference(projectID: otherProject.id), original]
        snapshot.selectedSessionID = original.id
        let store = MemoryStore(snapshot)
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in FakeRuntime() }
        await workspace.start()
        let visibility = TestSidebarVisibility()
        visibility.value = .detailOnly
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 })
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        let toolbarView = try XCTUnwrap(window.toolbar?.items.last?.view)
        // The project badge is the leading control in the session header.
        let location = toolbarView.convert(NSPoint(x: toolbarView.bounds.minX + 14, y: toolbarView.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        for _ in 0..<10 {
            await settleWindow(window)
            if (await store.load()).sessions.count == 3 { break }
        }
        await settleWindow(window)
        XCTAssertEqual(workspace.state.sessions.count, 3)
        XCTAssertNotEqual(workspace.selected?.id, original.id)
        XCTAssertEqual(workspace.selected?.projectID, project.id)
        XCTAssertEqual(workspace.viewed?.id, workspace.selected?.id)
        XCTAssertEqual(visibility.value, .detailOnly)
    }

    @MainActor func testWorkbenchSidebarKeepsRoomForSearchAtNarrowWidths() async throws {
        let workspace = await newConversationWorkspace()
        let visibility = TestSidebarVisibility()
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 })
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host

        func splitView(in view: NSView) -> NSSplitView? {
            (view as? NSSplitView) ?? view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }

        func sidebarItem() throws -> NSSplitViewItem {
            let split = try XCTUnwrap(splitView(in: host))
            let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
            return try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        }

        for width: CGFloat in [900, 1200, 860] {
            window.setContentSize(.init(width: width, height: 780))
            await settleWindow(window)
            let sidebar = try sidebarItem()
            XCTAssertFalse(sidebar.isCollapsed)
            XCTAssertGreaterThanOrEqual(sidebar.viewController.view.bounds.width, 204.5,
                                        "Sidebar at window width \(width) pt")
        }

        visibility.value = .detailOnly
        await settleWindow(window)
        XCTAssertTrue(try sidebarItem().isCollapsed)
        visibility.value = .all
        await settleWindow(window)
        let reopened = try sidebarItem()
        XCTAssertFalse(reopened.isCollapsed)
        XCTAssertGreaterThanOrEqual(reopened.viewController.view.bounds.width, 204.5)
    }

    @MainActor func testManyBackgroundRunsLeaveRoomForTheTranscript() async throws {
        let workspace = WorkspaceController(store: MemoryStore(), reader: PiHistoryReader(roots: [])) { _, _ in
            StubSessionRuntime(sessionID: UUID().uuidString)
        }
        await workspace.start()
        let added = await workspace.addProject(FileManager.default.temporaryDirectory)
        let project = try XCTUnwrap(added)
        for index in 0..<18 {
            let selected = await workspace.createSession(in: project)
            let id = try XCTUnwrap(selected)
            await workspace.send(id, submitted: .init(text: "Task \(index)"))
        }
        XCTAssertEqual(workspace.executionIDs.count, 18)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all)
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)

        func findTranscript(in view: NSView) -> NativeTranscript.TranscriptScroll? {
            if let scroll = view as? NativeTranscript.TranscriptScroll { return scroll }
            return view.subviews.lazy.compactMap { findTranscript(in: $0) }.first
        }
        let transcript = try XCTUnwrap(findTranscript(in: host))
        XCTAssertGreaterThan(transcript.contentSize.height, 300, "Background banners must not crowd out the conversation")
        let clean = await workspace.disconnectAll()
        XCTAssertTrue(clean)
        window.contentView = nil
    }

    @MainActor func testStarterCentersHeadingAndComposerAcrossWindowHeights() async throws {
        var titleFrame = CGRect.zero
        var composerFrame = CGRect.zero
        var viewport = CGRect.zero
        let host = NSHostingView(rootView: SessionDetailViewport(isStarter: true) { _ in
            Color.clear.frame(width: 200, height: 44)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { titleFrame = $0 }
            Color.clear.frame(maxWidth: .infinity).frame(height: 110)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { composerFrame = $0 }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { viewport = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for height: CGFloat in [620, 920] {
            window.setContentSize(NSSize(width: 790, height: height))
            await settleWindow(window)

            XCTAssertEqual(viewport.height, height, accuracy: 1)
            XCTAssertEqual(titleFrame.maxY, composerFrame.minY, accuracy: 1)
            XCTAssertEqual(composerFrame.midX, viewport.midX, accuracy: 1)
            XCTAssertEqual(titleFrame.union(composerFrame).midY - viewport.minY, height * 0.44, accuracy: 1)
        }
    }

    @MainActor func testReadingColumnCentersBothComposersWithoutNarrowingTheViewport() async {
        for isStarter in [true, false] {
            var transcriptFrame = CGRect.zero
            var composerFrame = CGRect.zero
            let host = NSHostingView(rootView: SessionDetailViewport(isStarter: isStarter) { _ in
                Color.clear.frame(maxWidth: .infinity)
                    .frame(height: isStarter ? 44 : nil)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { transcriptFrame = $0 }
                Color.clear.frame(maxWidth: .infinity).frame(height: 110)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { composerFrame = $0 }
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 620),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for (width, column): (CGFloat, CGFloat) in [(1280, 800), (1000, 800), (600, 552)] {
                window.setContentSize(NSSize(width: width, height: 620))
                await settleWindow(window)
                XCTAssertEqual(transcriptFrame.width, width, accuracy: 1)
                XCTAssertEqual(composerFrame.width, column, accuracy: 1)
                XCTAssertEqual(composerFrame.midX, transcriptFrame.midX, accuracy: 1)
            }
            window.contentView = nil
        }
    }

    @MainActor func testComposerControlsCompressBeforeWrappingTrailingGroup() async {
        var leading = CGRect.zero
        var trailing = CGRect.zero
        let host = NSHostingView(rootView: ComposerControlsLayout {
            Color.clear.frame(minWidth: 180, idealWidth: 260, maxWidth: 260)
                .frame(height: 24)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { leading = $0 }
            Color.clear.frame(minWidth: 72, idealWidth: 100, maxWidth: 100)
                .frame(height: 32)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { trailing = $0 }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        for (width, expectedLeading, expectedTrailing): (CGFloat, CGFloat, CGFloat) in
            [(450, 260, 100), (365, 260, 89), (320, 232, 72), (250, 250, 100), (450, 260, 100)] {
            window.setContentSize(NSSize(width: width, height: 200))
            await settleWindow(window)
            XCTAssertEqual(leading.width, expectedLeading, accuracy: 1)
            XCTAssertEqual(trailing.width, expectedTrailing, accuracy: 1)
            XCTAssertEqual(trailing.maxX - leading.minX, width, accuracy: 1)
            if width == 250 {
                XCTAssertEqual(trailing.minY - leading.maxY, 6, accuracy: 1)
            } else {
                XCTAssertEqual(leading.midY, trailing.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(trailing.minX - leading.maxX, 15)
            }
        }
    }

    @MainActor func testOversizedStarterCanScrollToSendRow() async throws {
        var sendFrame = CGRect.zero
        let host = NSHostingView(rootView: SessionDetailViewport(isStarter: true) { _ in
            Color.clear.frame(height: 44)
            VStack(spacing: 0) {
                Color.clear.frame(height: 688)
                Button("Send") {}
                    .frame(height: 32)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { sendFrame = $0 }
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        XCTAssertGreaterThan(sendFrame.minY, host.bounds.height)

        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(findScrollView(in: host))
        let clip = scroll.contentView
        let bottom = clip.constrainBoundsRect(NSRect(x: 0, y: 1_000, width: clip.bounds.width, height: clip.bounds.height))
        XCTAssertGreaterThan(bottom.minY, clip.bounds.minY)
        clip.scroll(to: bottom.origin)
        scroll.reflectScrolledClipView(clip)
        await settleWindow(window)
        XCTAssertGreaterThanOrEqual(sendFrame.minY, 0)
        XCTAssertLessThanOrEqual(sendFrame.maxY, host.bounds.height + 1)
    }

    @MainActor func testComposerReturnKeysInsertNewlinesAndCommandReturnSends() async throws {
        let runtime = StubSessionRuntime { $0.mode == .followUp ? .queued : .started }
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        presentation.controller.draft = "abcd"
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(), presentation: presentation, openSettings: {}, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)
        workspace.focusInput()
        await settleWindow(window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        func editorFrame() throws -> CGRect {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            return editor.convert(editor.bounds, to: host)
        }

        func pressReturn(_ modifiers: NSEvent.ModifierFlags) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.sendEvent(event)
            await settleWindow(window)
        }

        try await pressReturn([.shift])
        XCTAssertEqual(presentation.controller.draft, "ab\ncd")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        try await pressReturn([])
        XCTAssertEqual(presentation.controller.draft, "ab\n\ncd")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(presentation.controller.transcript.isEmpty)

        try await pressReturn([.command])
        for _ in 0..<10 where presentation.controller.transcript.isEmpty { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.transcript.first?.editableText, "ab\n\ncd")
        XCTAssertTrue(presentation.controller.draft.isEmpty)

        // During execution the visible primary button is Stop, but the editor still sends with ⌘↩.
        for _ in 0..<10 where presentation.controller.phase != .running { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.phase, .running)
        workspace.focusInput()
        await settleWindow(window)
        let runningFrame = try editorFrame()

        presentation.controller.draft = "Run next\non another line"
        await settleWindow(window)
        XCTAssertEqual(try editorFrame().minX, runningFrame.minX, accuracy: 1)

        presentation.controller.mode = .followUp
        try await pressReturn([.command])
        for _ in 0..<10 where presentation.controller.transcript.last?.delivery != .queued { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.transcript.last?.editableText, "Run next\non another line")
        XCTAssertEqual(presentation.controller.transcript.last?.delivery, .queued)
        XCTAssertEqual(presentation.controller.phase, .running)

        await presentation.controller.stop()
        workspace.focusInput()
        await settleWindow(window)
        // Hiding the inline capsule gives its width back to the editor.
        let idleFrame = try editorFrame()
        XCTAssertLessThan(idleFrame.minX, runningFrame.minX)
        XCTAssertEqual(idleFrame.maxX, runningFrame.maxX, accuracy: 1)
    }

    @MainActor func testFirstSubmissionMovesLocalDraftIntoTranscript() async throws {
        let workspace = await newConversationWorkspace()
        let presentation = try XCTUnwrap(workspace.viewed)
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(), presentation: presentation, openSettings: {}, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        XCTAssertFalse(containsTranscript(in: host))

        presentation.controller.draft = "First message"
        await settleWindow(window)
        XCTAssertFalse(containsTranscript(in: host))

        await workspace.send(presentation.id)
        await settleWindow(window)
        XCTAssertTrue(presentation.controller.transcript.contains { $0.kind == .user && $0.text == "First message" })
        XCTAssertTrue(containsTranscript(in: host))
        XCTAssertTrue(presentation.controller.draft.isEmpty)
    }

    @MainActor func testLongExtensionStatusStaysCollapsibleAcrossFirstSend() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        let controller = presentation.controller
        @Bindable var expansion = TestExtensionStatusExpansion()
        var panelFrame = CGRect.zero
        var inputFrame = CGRect.zero
        let host = NSHostingView(rootView: GeometryReader { _ in
            SessionDetailViewport(isStarter: controller.transcript.isEmpty) { viewportHeight in
                if controller.transcript.isEmpty {
                    Text("Starter").frame(height: 44)
                } else {
                    TranscriptView(items: controller.transcript)
                }
                VStack(spacing: 0) {
                    if !controller.extensionStatus.isEmpty {
                        ExtensionStatusView(controller: controller, viewportHeight: viewportHeight, expanded: $expansion.expanded)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { panelFrame = $0 }
                    }
                    TextField("Input", text: Bindable(controller).draft)
                        .frame(height: 36)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { inputFrame = $0 }
                }
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        let activated = await workspace.activate(presentation.id)
        XCTAssertTrue(activated)
        runtime.emit(.extensionStatus("long-widget", (1...90).map { "Extension status line \($0)" }.joined(separator: "\n")))
        await settleWindow(window)
        XCTAssertEqual(controller.extensionStatus.count, 1)
        XCTAssertFalse(containsTranscript(in: host))

        func detailsScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.height <= 156,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 500 {
                return scroll
            }
            return view.subviews.lazy.compactMap { detailsScroll(in: $0) }.first
        }

        func assertPanelAndInputVisible() {
            XCTAssertGreaterThan(panelFrame.height, 0)
            XCTAssertGreaterThan(inputFrame.height, 0)
            XCTAssertGreaterThan(panelFrame.minY, 0)
            XCTAssertLessThanOrEqual(panelFrame.maxY, inputFrame.minY + 1)
            XCTAssertLessThanOrEqual(inputFrame.maxY, host.bounds.height + 1)
        }

        expansion.expanded = true
        await settleWindow(window)
        XCTAssertNotNil(detailsScroll(in: host))
        assertPanelAndInputVisible()

        controller.draft = "First message with extension feedback"
        await workspace.send(presentation.id)
        await settleWindow(window)
        XCTAssertTrue(containsTranscript(in: host))
        XCTAssertTrue(expansion.expanded)
        let details = try XCTUnwrap(detailsScroll(in: host))
        assertPanelAndInputVisible()

        let panelTop = panelFrame.minY
        let clip = details.contentView
        let bottom = clip.constrainBoundsRect(NSRect(x: 0, y: 10_000, width: clip.bounds.width, height: clip.bounds.height))
        XCTAssertGreaterThan(bottom.minY, 500)
        clip.scroll(to: bottom.origin)
        details.reflectScrolledClipView(clip)
        await settleWindow(window)
        XCTAssertEqual(panelFrame.minY, panelTop, accuracy: 1)
        assertPanelAndInputVisible()

        for shouldExpand in [false, true, false] {
            expansion.expanded = shouldExpand
            await settleWindow(window)
            XCTAssertEqual(detailsScroll(in: host) != nil, shouldExpand)
            assertPanelAndInputVisible()
        }
    }

    @MainActor func testTerminationConfirmsRunningWorkButNotIdleConnection() async throws {
        let workspace = await newConversationWorkspace()
        let id = try XCTUnwrap(workspace.selected?.id)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)

        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)

        let controller = try XCTUnwrap(workspace.execution(for: id))
        controller.draft = "Run the termination fixture"
        await workspace.send(id)
        XCTAssertTrue(workspace.terminationWouldInterruptWork)

        controller.draft = "Keep this draft"
        let disconnected = await workspace.disconnectAll()
        XCTAssertTrue(disconnected)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)
        XCTAssertEqual(workspace.selected?.draft, "Keep this draft")
    }

    @MainActor private func newConversationWorkspace(runtime: StubSessionRuntime = StubSessionRuntime()) async -> WorkspaceController {
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let reference = SessionReference(projectID: project.id)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [reference]
        snapshot.selectedSessionID = reference.id
        let workspace = WorkspaceController(store: MemoryStore(snapshot), reader: PiHistoryReader(roots: [])) { _, _ in
            runtime
        }
        await workspace.start()
        return workspace
    }

    @MainActor private func settleWindow(_ window: NSWindow) async {
        for _ in 0..<8 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor private func containsTranscript(in view: NSView) -> Bool {
        view is NativeTranscript.TranscriptScroll || view.subviews.contains { containsTranscript(in: $0) }
    }

    func testGitInspectorCoversUnbornDetachedUpstreamChangesAndDeduplication() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Pikachu-Git-Test-\(UUID())")
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        let nonRepo = root.appendingPathComponent("plain")
        let missing = root.appendingPathComponent("does-not-exist")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let missingState = await GitRepositoryInspector.inspect(directory: missing, now: fixedNow)
        XCTAssertEqual(missingState, .directoryMissing(directoryPath: GitRepositoryInspector.normalizedPath(missing.path), reason: String(localized: "工作目录不存在或已移动。"), updatedAt: fixedNow))
        if case .notRepository = GitRepositoryInspector.inspectSync(directoryPath: nonRepo.path) {} else {
            XCTFail("Expected non-repository state")
        }

        try runGit(["init", "--bare", "-q"], cwd: remote)
        try runGit(["init", "-q", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test"], cwd: repo)

        // Unborn repo keeps branch name and marks ahead unavailable.
        let unbornState = GitRepositoryInspector.inspectSync(directoryPath: repo.path)
        let unbornSnap = try XCTUnwrap(unbornState.snapshot)
        XCTAssertEqual(unbornSnap.branch, .branch(name: "main", hasCommits: false))
        if case .unavailable = unbornSnap.ahead {} else { XCTFail("Unborn repo should have unavailable ahead count") }

        try "keep\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "del\n".write(to: repo.appendingPathComponent("del.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "rename line\n", count: 8).write(to: repo.appendingPathComponent("ren.txt"), atomically: true, encoding: .utf8)
        try "recreate\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)
        try "*.ignored\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-q", "-m", "initial"], cwd: repo)

        // No upstream yet.
        let noUpstream = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(noUpstream.branch, .branch(name: "main", hasCommits: true))
        XCTAssertEqual(noUpstream.ahead.displayText, "—")
        XCTAssertEqual(noUpstream.changes.totalCount, 0)

        // Configure local bare upstream: 0 ahead, then 2 ahead.
        try runGit(["remote", "add", "origin", remote.path], cwd: repo)
        try runGit(["push", "-q", "-u", "origin", "main"], cwd: repo)
        let zeroAhead = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(zeroAhead.ahead, .count(0, upstream: "origin/main"))

        try "c1\n".write(to: repo.appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c1.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c1"], cwd: repo)
        try "c2\n".write(to: repo.appendingPathComponent("c2.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c2.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c2"], cwd: repo)

        // Staged + unstaged duplicate modification on keep.txt -> 1 modified.
        try "keep staged\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "keep.txt"], cwd: repo)
        try "keep worktree\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        // Deleted del.txt -> 1 deleted.
        try fm.removeItem(at: repo.appendingPathComponent("del.txt"))

        // Renamed ren.txt -> ren2.txt -> 1 renamed.
        try runGit(["mv", "ren.txt", "ren2.txt"], cwd: repo)

        // Staged delete + recreated untracked at same path -> 1 modified (deduplicated).
        try runGit(["rm", "-q", "recreate.txt"], cwd: repo)
        try "recreated\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)

        // Staged add + unstaged modify -> 1 added; untracked -> 1 added; ignored -> excluded.
        try "new staged\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "new_staged.txt"], cwd: repo)
        try "new staged edited\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: repo.appendingPathComponent("skip.ignored"), atomically: true, encoding: .utf8)

        let dirty = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(dirty.ahead, .count(2, upstream: "origin/main"))
        XCTAssertEqual(dirty.changes.addedCount, 2) // new_staged.txt, untracked.txt
        XCTAssertEqual(dirty.changes.deletedCount, 1) // del.txt
        XCTAssertEqual(dirty.changes.modifiedCount, 2) // keep.txt, recreate.txt
        XCTAssertEqual(dirty.changes.renamedCount, 1) // ren.txt -> ren2.txt
        XCTAssertEqual(dirty.changes.totalCount, 6)

        // Detached HEAD shows short SHA and unavailable ahead.
        try runGit(["checkout", "-q", "--detach", "HEAD"], cwd: repo)
        let detached = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        if case .detached(let sha) = detached.branch {
            XCTAssertFalse(sha.isEmpty)
        } else {
            XCTFail("Expected detached HEAD")
        }
        if case .unavailable = detached.ahead {} else { XCTFail("Detached HEAD should have unavailable ahead count") }
    }

    @MainActor func testGitStoreDiscardsStaleResponsesAndNeverBorrowsOtherProjectOnFailure() async throws {
        let dirA = "/tmp/git-store-a-\(UUID().uuidString)"
        let dirB = "/tmp/git-store-b-\(UUID().uuidString)"
        let snapA = GitRepositorySnapshot(
            directoryPath: GitRepositoryInspector.normalizedPath(dirA),
            checkoutRoot: GitRepositoryInspector.normalizedPath(dirA),
            branch: .branch(name: "main", hasCommits: true),
            ahead: .count(2, upstream: "origin/main"),
            changes: .init(addedFiles: ["a.swift"], deletedFiles: [], modifiedFiles: [], renamedFiles: []),
            updatedAt: Date()
        )
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
        }
        let counter = Counter()
        let firstInspectionStarted = expectation(description: "First inspection entered")
        let staleResponseReturned = expectation(description: "Superseded inspection returned")
        let staleResponseGate = AsyncStream<Void>.makeStream()
        // Keep the first inspector suspended even after the store cancels its refresh task.
        let waitForStaleResponse = Task {
            for await _ in staleResponseGate.stream {}
        }
        defer { staleResponseGate.continuation.finish() }

        let store = GitStatusStore { url in
            let path = url.path
            if path.hasSuffix(URL(fileURLWithPath: dirA).lastPathComponent) {
                let step = counter.next()
                if step == 1 {
                    firstInspectionStarted.fulfill()
                    await waitForStaleResponse.value
                    staleResponseReturned.fulfill()
                    return .loaded(snapA, isStale: false, refreshError: nil)
                }
                return .notRepository(directoryPath: path, reason: "不再是仓库", updatedAt: Date())
            }
            return .failed(directoryPath: path, reason: "读取失败", updatedAt: Date())
        }

        store.refresh(directory: dirA, force: true)
        await fulfillment(of: [firstInspectionStarted], timeout: 1)
        store.refresh(directory: dirA, force: true)
        store.refresh(directory: dirB, force: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if case .notRepository = store.state(for: dirA), case .failed = store.state(for: dirB) { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case .notRepository = store.state(for: dirA) else {
            XCTFail("Expected newer generation result for dirA, got \(store.state(for: dirA))")
            return
        }
        guard case .failed = store.state(for: dirB) else {
            XCTFail("Expected failed state for dirB without borrowing dirA values")
            return
        }

        let staleStateWrite = expectation(description: "Superseded inspection changes Git state")
        staleStateWrite.isInverted = true
        withObservationTracking {
            _ = store.state(for: dirA)
        } onChange: {
            staleStateWrite.fulfill()
        }
        staleResponseGate.continuation.finish()
        await fulfillment(of: [staleResponseReturned], timeout: 1)
        await fulfillment(of: [staleStateWrite], timeout: 0.2)
    }

    @MainActor func testClockRoundsFollowUpSplitAttributionAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-SD03-Test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionFile = root.appendingPathComponent("session.jsonl")
        let userTsMs: Int64 = 1_795_000_000_000
        let assistant1TsMs: Int64 = 1_795_000_002_000
        let assistant2TsMs: Int64 = 1_795_000_138_000

        let clock = TestClock(wall: Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))
        let runtime = StubSessionRuntime(sessionID: "sd03-session", file: sessionFile)
        let store = MemoryStore()
        let reader = PiHistoryReader(roots: [root])
        let workspace = WorkspaceController(store: store, reader: reader, clock: clock) { _, _ in runtime }
        await workspace.start()
        _ = await workspace.addProject(root)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(sessionID)
        XCTAssertTrue(activated)

        let controller = try XCTUnwrap(workspace.execution(for: sessionID))
        let attachment = root.appendingPathComponent("notes.txt")
        controller.draft = "排查顶栏"
        controller.draftFiles = [attachment]
        await workspace.send(sessionID)
        XCTAssertEqual(controller.transcript.first?.sentAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))

        // Live round 1 with steer + multiple assistant blocks + tool group.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        controller.receive(.init(instanceID: runtime.instanceID, event: .userMessageTimestamp(userTsMs)))
        let a1 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a1)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantTimestamp(a1, assistant1TsMs)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a1, "第一段分析")))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "t1", name: "read", state: .completed))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "t2", name: "grep", state: .completed))))
        let a2 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a2)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantTimestamp(a2, assistant2TsMs)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a2, "第二段结论")))

        clock.advance(by: 138) // 2 min 18 sec
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        try await Task.sleep(for: .milliseconds(30))

        let liveRows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        let liveHeaders = projectedTurns(liveRows)
        XCTAssertEqual(liveHeaders.count, 1)
        guard case .turnHeader(let round1) = liveRows[1], case .item(let firstReply) = liveRows[2] else {
            return XCTFail("Expected the current turn header between the user and first reply")
        }
        XCTAssertEqual(liveRows[0].id, controller.transcript.first?.id)
        XCTAssertEqual(firstReply.text, "第一段分析")
        XCTAssertEqual(round1.status, .completed)
        XCTAssertEqual(try XCTUnwrap(round1.durationSeconds), 138, accuracy: 0.01)
        XCTAssertEqual(round1.endedAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0 + 138))

        // Persist matching Pi v3 JSONL and reload in a fresh WorkspaceController.
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "sd03-session", "cwd": root.resolvingSymlinksInPath().path, "timestamp": "2026-11-18T12:26:40.000Z"],
            ["type": "message", "id": "u1", "parentId": NSNull(), "timestamp": "2026-11-18T12:26:40.000Z",
             "message": ["role": "user", "content": [["type": "text", "text": UserPrompt(text: "排查顶栏", files: [attachment]).runtimeText]], "timestamp": userTsMs]],
            ["type": "message", "id": "a1", "parentId": "u1", "timestamp": "2026-11-18T12:26:42.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "第一段分析"], ["type": "toolCall", "id": "t1", "name": "read", "arguments": [:]], ["type": "toolCall", "id": "t2", "name": "grep", "arguments": [:]]], "stopReason": "toolUse", "timestamp": assistant1TsMs]],
            ["type": "message", "id": "tr1", "parentId": "a1", "timestamp": "2026-11-18T12:26:43.000Z",
             "message": ["role": "toolResult", "toolCallId": "t1", "toolName": "read", "content": "ok", "isError": false]],
            ["type": "message", "id": "tr2", "parentId": "tr1", "timestamp": "2026-11-18T12:26:44.000Z",
             "message": ["role": "toolResult", "toolCallId": "t2", "toolName": "grep", "content": "ok", "isError": false]],
            ["type": "message", "id": "a2", "parentId": "tr2", "timestamp": "2026-11-18T12:28:58.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "第二段结论"]], "stopReason": "stop", "timestamp": assistant2TsMs]],
        ]
        let jsonl = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        _ = await workspace.disconnectAll()
        _ = await workspace.flush()

        let reopened = WorkspaceController(store: store, reader: reader, clock: clock) { _, _ in FakeRuntime() }
        await reopened.start()
        let reloadedTranscript = try XCTUnwrap(reopened.viewed?.controller.transcript)
        let reloadedUser = try XCTUnwrap(reloadedTranscript.first(where: { $0.kind == .user }))
        XCTAssertEqual(reloadedUser.editableText, "排查顶栏")
        XCTAssertEqual(reloadedUser.editableFiles, [attachment])
        XCTAssertEqual(reloadedUser.sentAt, Date(timeIntervalSince1970: Double(userTsMs) / 1000.0))

        let reloadedRows = TranscriptDisplayRow.project(reloadedTranscript)
        let reloadedHeaders = projectedTurns(reloadedRows)
        XCTAssertEqual(reloadedHeaders.count, 1)
        guard case .turnHeader(let restoredRound) = reloadedRows[1] else {
            return XCTFail("Expected restored header immediately after the user")
        }
        XCTAssertEqual(restoredRound.status, .completed)
        XCTAssertEqual(try XCTUnwrap(restoredRound.durationSeconds), 138, accuracy: 0.01)
    }

    @MainActor func testToolOnlyTurnFollowUpSplitStopAndDisconnectUncertainty() async throws {
        let clock = TestClock()
        let controller = SessionController(clock: clock)
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)

        // The tool-only execution gets a standalone header.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-1", name: "read", state: .completed))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-2", name: "bash", state: .completed))))
        clock.advance(by: 12)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))

        let rows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        let headers = projectedTurns(rows)
        XCTAssertEqual(headers.count, 1)
        let toolTurn = try XCTUnwrap(headers.first)
        XCTAssertEqual(try XCTUnwrap(toolTurn.durationSeconds), 12, accuracy: 0.01)
        XCTAssertEqual(toolTurn.status, .completed)

        // Stop round records stopped status + duration.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let stoppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(stoppedAssistant)))
        clock.advance(by: 5)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        let stoppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(stoppedTurn.status, .stopped)
        XCTAssertEqual(try XCTUnwrap(stoppedTurn.durationSeconds), 5, accuracy: 0.01)

        // Disconnect mid-round marks uncertain without guessing end time.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let droppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(droppedAssistant)))
        clock.advance(by: 9)
        controller.receive(.init(instanceID: runtime.instanceID, event: .disconnected(cleanupConfirmed: false)))
        let droppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(droppedTurn.status, .uncertain)
        XCTAssertNil(droppedTurn.endedAt)
        XCTAssertNil(droppedTurn.durationSeconds)
    }

    @MainActor func testLiveHeaderSurvivesEmptyAssistantAndStopWithoutReplacingTheDraft() async throws {
        let controller = SessionController(clock: TestClock())
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        controller.draft = "Run with no visible reply"
        await controller.sendDraft()

        let before = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        XCTAssertEqual(before.count, 2)
        guard case .turnHeader(let turn) = before[1] else { return XCTFail("Expected a running header") }
        XCTAssertEqual(turn.status, .running)
        let assistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(assistant)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(assistant, "")))
        let file = URL(fileURLWithPath: "/tmp/an-unsent-attachment")
        controller.draft = "Keep editing"
        controller.draftFiles = [file]
        await controller.stop()

        let after = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(turn.status, .stopped)
        XCTAssertEqual(controller.draft, "Keep editing")
        XCTAssertEqual(controller.draftFiles, [file])
        XCTAssertFalse(controller.isStopping)
        _ = await controller.disconnect()
    }

    @MainActor func testStopOnlyTargetsItsBoundSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceController(store: MemoryStore(), reader: PiHistoryReader(roots: [])) { _, _ in
            StubSessionRuntime()
        }
        await workspace.start()
        let addedProject = await workspace.addProject(root)
        let projectID = try XCTUnwrap(addedProject)
        let running = try XCTUnwrap(workspace.selected?.id)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.draft = "Start a run"
        await workspace.send(running)
        await workspace.createSession(in: projectID)
        let browsed = try XCTUnwrap(workspace.selected?.id)
        XCTAssertNotEqual(browsed, running)

        await workspace.stop(browsed)
        XCTAssertEqual(workspace.executionIDs, [running])
        XCTAssertEqual(controller.phase, .running)
        await workspace.stop(running)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(workspace.selected?.id, browsed)
        _ = await workspace.disconnectAll()
    }

    @MainActor func testDuplicateFollowUpsAcquireDistinctHeadersOnlyWhenDequeued() async throws {
        let controller = SessionController(clock: TestClock())
        let runtime = StubSessionRuntime(disposition: { $0.mode == .followUp ? .queued : .started })
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Start"))
        let first = UserPrompt(text: "repeat", mode: .followUp)
        let second = UserPrompt(text: "repeat", mode: .followUp)
        await controller.sendDraft(first)
        await controller.sendDraft(second)

        func project() -> [TranscriptDisplayRow] {
            TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        }
        func queue(_ pending: [String]) {
            controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(followUp: pending))))
        }
        queue(["repeat", "repeat"])
        XCTAssertEqual(projectedTurns(project()).count, 1)
        queue(["repeat"])
        let inputs = controller.transcript.filter { $0.kind == .user }
        XCTAssertEqual(inputs.map(\.delivery), [.accepted, .accepted, .queued])
        let firstHeaders = projectedTurns(project())
        XCTAssertEqual(firstHeaders.map(\.status), [.completed, .running])

        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "between", name: "read", state: .completed))))
        queue([])
        let rows = project()
        let finalHeaders = projectedTurns(rows)
        XCTAssertEqual(finalHeaders.map(\.status), [.completed, .completed, .running])
        XCTAssertEqual(Set(finalHeaders.map(\.id)).count, 3)
        XCTAssertEqual(finalHeaders.first?.id, firstHeaders.first?.id)
        XCTAssertEqual(finalHeaders.dropFirst().first?.id, firstHeaders.last?.id)
        _ = await controller.disconnect()
    }

    func testTimestampFormattingSameYearAndCrossYearAndDuration() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10, minute: 0))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 46, second: 12))!
        let prevYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 58, second: 0))!

        let chinese = Locale(identifier: "zh_Hans_CN")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(sameDay, relativeTo: now, calendar: cal, timeZone: tz, locale: chinese), "11月19日 09:46")
        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(prevYear, relativeTo: now, calendar: cal, timeZone: tz, locale: chinese), "2025年12月31日 23:58")
        let sameYearEnglish = TranscriptTimestampFormatter.shortTime(sameDay, relativeTo: now, calendar: cal, timeZone: tz, locale: english)
        XCTAssertTrue(sameYearEnglish.contains("Nov 19"))
        XCTAssertFalse(sameYearEnglish.contains("2026"))
        let previousYearEnglish = TranscriptTimestampFormatter.shortTime(prevYear, relativeTo: now, calendar: cal, timeZone: tz, locale: english)
        XCTAssertTrue(previousYearEnglish.contains("Dec 31, 2025"))
        for locale in [chinese, english] {
            XCTAssertTrue(TranscriptTimestampFormatter.fullTimeWithZone(sameDay, calendar: cal, timeZone: tz, locale: locale).contains("Asia/Shanghai"))
        }
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(138), String(localized: "\(2) 分 \(18) 秒"))
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(0.4), String(localized: "不足 1 秒"))
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(3665), String(localized: "\(1) 小时 \(1) 分 \(5) 秒"))
    }

    @MainActor func testRunningTurnFormatsElapsedDurationAndCompletedTurnStopsCounting() {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let monotonicStart = ContinuousClock.now
        let turn = TurnRecord(startedAt: start, monotonicStart: monotonicStart)
        let initial = TurnHeaderSummary(turn: turn, relativeTo: start, monotonicNow: monotonicStart)
        let running = TurnHeaderSummary(turn: turn, relativeTo: start.addingTimeInterval(-10),
                                        monotonicNow: monotonicStart.advanced(by: .milliseconds(3_850)))
        let initialElapsed = String(localized: "不足 1 秒")
        let runningElapsed = String(localized: "\(3) 秒")
        XCTAssertEqual(initial.title, "⚡️Pika Pika！")
        XCTAssertEqual(initial.displayText, String(localized: "执行中 ... \(initialElapsed)"))
        XCTAssertEqual(running.displayText, String(localized: "执行中 ... \(runningElapsed)"))
        XCTAssertEqual(running.accessibilityText, String(localized: "Pika Pika，执行中，已用时 \(runningElapsed)"))

        for (seconds, elapsedText) in [
            (59, String(localized: "\(59) 秒")),
            (60, String(localized: "\(1) 分 \(0) 秒")),
            (3600, String(localized: "\(1) 小时 \(0) 分 \(0) 秒"))
        ] {
            let summary = TurnHeaderSummary(turn: turn, relativeTo: start,
                                            monotonicNow: monotonicStart.advanced(by: .seconds(seconds)))
            XCTAssertEqual(summary.displayText, String(localized: "执行中 ... \(elapsedText)"))
            XCTAssertEqual(summary.accessibilityText, String(localized: "Pika Pika，执行中，已用时 \(elapsedText)"))
        }

        turn.status = .completed
        turn.durationSeconds = 3.85
        turn.endedAt = start.addingTimeInterval(3.85)
        let completed = TurnHeaderSummary(turn: turn, relativeTo: start.addingTimeInterval(61),
                                          monotonicNow: monotonicStart.advanced(by: .seconds(61)))
        XCTAssertEqual(completed.displayText, String(localized: "执行 \(TranscriptTimestampFormatter.durationText(3.85))"))
        XCTAssertEqual(completed.tooltipText, completed.displayText)
        XCTAssertEqual(completed.title, "⚡️Pika-CHUUU!")
        XCTAssertTrue(completed.accessibilityText.hasPrefix("Pika-CHUUU!"))
    }

    func testComposerPermissionsStatesForEffectiveVsNextRun() {
        let selected = AgentExecutionPolicy(mode: .interactive, approval: .everyCall)
        let active = AgentExecutionPolicy(mode: .interactive)
        let idleSwitched = ComposerApprovalPresentation(
            selected: selected,
            active: active,
            isRunning: false,
            isReadOnlyHistory: false
        )
        let everyCall = String(localized: "每次审批")
        XCTAssertEqual(idleSwitched.buttonText, String(localized: "\(everyCall)（下次执行）"))
        XCTAssertEqual(idleSwitched.effective, active)
        XCTAssertEqual(idleSwitched.pending, selected)

        let running = ComposerApprovalPresentation(
            selected: selected,
            active: active,
            isRunning: true,
            isReadOnlyHistory: false
        )
        XCTAssertEqual(running.buttonText, String(localized: "工具审批"))
        XCTAssertEqual(running.effective, active)
        XCTAssertNil(running.pending)

        let automatic = ComposerApprovalPresentation(
            selected: .init(mode: .automatic),
            active: nil,
            isRunning: false,
            isReadOnlyHistory: true
        )
        XCTAssertEqual(automatic.buttonText, String(localized: "无需审批"))
    }

    @MainActor func testUsagePresentationAndLateResponseRejection() async {
        let usage = RuntimeUsage(
            sessionID: "s1",
            tokens: .init(input: 1_212_641, output: 127_445, cacheRead: 89_359_488, cacheWrite: 0, total: 90_699_574, inputIsUncached: true),
            estimatedCostUSD: nil,
            context: .init(tokens: 285_400, window: 475_000, percent: 60.08),
            observedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
        let normal = UsagePresentationSnapshot(usage: usage, isConnected: true, isStale: false, isLoading: false, isCompacting: false)
        XCTAssertEqual(normal.summaryText, "285k / 475k")
        XCTAssertEqual(normal.percentText, "\(60.1.formatted(.number))%")
        XCTAssertFalse(normal.isContextPending)
        XCTAssertEqual(normal.totalTokensText, "90.70M")
        XCTAssertTrue(normal.cacheHitRateText?.contains(0.987.formatted(.percent.precision(.fractionLength(1)))) == true)
        XCTAssertEqual(normal.costText, String(localized: "无法估算"))
        XCTAssertFalse(normal.isOverCapacity)

        let zero = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", tokens: .init(total: 0, inputIsUncached: true), context: .init(tokens: 0, window: 475_000, percent: 0)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertEqual(zero.summaryText, "0 / 475k")
        XCTAssertEqual(zero.percentText, "0%")

        let compacted = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: nil, window: 475_000, percent: nil)),
            isConnected: true, isStale: true, isLoading: false, isCompacting: true
        )
        XCTAssertEqual(compacted.summaryText, String(localized: "待更新"))
        XCTAssertTrue(compacted.isContextPending)
        XCTAssertNil(compacted.summaryRatio)

        let unavailable = UsagePresentationSnapshot(
            usage: nil, isConnected: false, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertEqual(unavailable.summaryText, String(localized: "不可用"))
        XCTAssertFalse(unavailable.isContextPending)

        let over = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: 500_000, window: 475_000, percent: 105.3)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertTrue(over.isOverCapacity)
        XCTAssertEqual(over.summaryRatio, 1.0)
        XCTAssertEqual(over.percentText, "\(105.3.formatted(.number))%")

        // Late usage response from another session ID is discarded.
        let controller = SessionController()
        let runtime = StubSessionRuntime(sessionID: "real-session")
        await controller.connect(runtime)
        runtime.enqueueUsage(.success(RuntimeUsage(sessionID: "stale-session", tokens: .init(total: 999))))
        await controller.refreshUsage()
        XCTAssertNil(controller.usage?.tokens.total)
        _ = await controller.disconnect()
    }

    @MainActor func testFollowUpStartsNewRoundAndLegacyHistoryPreservesOnlyTrustedFields() async throws {
        // 1. Follow-up dequeuing starts a distinct round.
        let clock = TestClock()
        let runtime = StubSessionRuntime(disposition: { $0.mode == .followUp ? .queued : .started })
        let controller = SessionController(clock: clock)
        await controller.connect(runtime)

        controller.draft = "round 1"
        await controller.sendDraft()
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let a1 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a1)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a1, "first reply")))
        clock.advance(by: 10)

        let followPrompt = UserPrompt(text: "round 2", mode: .followUp)
        controller.draft = followPrompt.text
        controller.mode = .followUp
        await controller.sendDraft(followPrompt)
        controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(followUp: [followPrompt.runtimeText]))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "previous-turn-tail", name: "read", state: .completed))))
        let pendingRows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        XCTAssertEqual(projectedTurns(pendingRows).count, 1)
        clock.advance(by: 5)
        controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(steering: [], followUp: []))))
        let a2 = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(a2)))
        clock.advance(by: 7)
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(a2, "follow-up reply")))
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))

        let rows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        let turns = projectedTurns(rows)
        XCTAssertEqual(turns.count, 2)
        let tailIndex = try XCTUnwrap(rows.firstIndex { $0.contains("tool:previous-turn-tail") })
        guard case .turnHeader(let followUpTurn) = rows[tailIndex + 1] else {
            return XCTFail("Expected follow-up header after previous-turn output")
        }
        XCTAssertTrue(followUpTurn === turns[1])
        XCTAssertEqual(try XCTUnwrap(turns[0].durationSeconds), 15, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(turns[1].durationSeconds), 7, accuracy: 0.01)
        _ = await controller.disconnect()

        // 2. Legacy JSONL with synthetic numeric timestamp=1 falls back to ISO entry timestamp and keeps duration nil.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pikachu-Legacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.jsonl")
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "legacy", "cwd": root.path, "timestamp": "2026-11-18T00:00:00Z"],
            ["type": "message", "id": "u1", "parentId": NSNull(), "timestamp": "2026-11-18T00:00:01Z",
             "message": ["role": "user", "content": "hello", "timestamp": 1]],
            ["type": "message", "id": "a1", "parentId": "u1", "timestamp": "2026-11-18T00:01:00Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "world"]], "stopReason": "stop"]]
        ]
        let data = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try data.write(to: file, atomically: true, encoding: .utf8)

        let history = try await PiHistoryReader(roots: []).read(file)
        XCTAssertEqual(history.items.first?.sentAt, try Date.ISO8601FormatStyle().parse("2026-11-18T00:00:01Z"))
        XCTAssertEqual(history.turns.count, 1)
        XCTAssertEqual(history.turns.first?.status, .completed)
        XCTAssertEqual(history.turns.first?.endedAt, try Date.ISO8601FormatStyle().parse("2026-11-18T00:01:00Z"))
        XCTAssertNil(history.turns.first?.durationSeconds)

        let summary = TurnHeaderSummary(turn: TurnRecord(status: .completed, endedAt: history.turns.first?.endedAt, durationSeconds: nil),
                                        relativeTo: try Date.ISO8601FormatStyle().parse("2026-11-18T00:02:00Z"))
        XCTAssertEqual(summary.displayText, String(localized: "执行完成"))
        XCTAssertEqual(summary.tooltipText, summary.displayText)
    }

    @MainActor private func projectedTurns(_ rows: [TranscriptDisplayRow]) -> [TurnRecord] {
        rows.compactMap { row in
            guard case .turnHeader(let turn) = row else { return nil }
            return turn
        }
    }

    func testWorktreeChoicesAndCreationUseTheSelectedCommitAndPreserveLocalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "worktree@example.test"], cwd: repo)
        try runGit(["config", "user.name", "Worktree Test"], cwd: repo)
        let source = repo.appendingPathComponent("source.txt")
        try "committed".write(to: source, atomically: true, encoding: .utf8)
        try runGit(["add", "source.txt"], cwd: repo)
        try runGit(["commit", "-m", "base"], cwd: repo)
        let initial = await GitRepositoryInspector.worktrees(in: repo.path)
        let head = try XCTUnwrap(initial?.first?.commit)
        XCTAssertEqual(initial?.map(\.branch), ["main"])
        try "local edit".write(to: source, atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("task checkout")
        let worktree = try await GitRepositoryInspector.createWorktree(
            in: repo.path, destination: destination.path, branch: "task/checkout", base: head
        )
        let listed = await GitRepositoryInspector.worktrees(in: repo.path)
        XCTAssertEqual(Set(listed?.compactMap(\.branch) ?? []), Set(["main", "task/checkout"]))
        XCTAssertEqual(worktree.path, destination.resolvingSymlinksInPath().path)
        XCTAssertEqual(worktree.commit, head)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "local edit")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8), "committed")

        do {
            _ = try await GitRepositoryInspector.createWorktree(in: repo.path, destination: destination.path,
                                                                branch: "other", base: head)
            XCTFail("An existing directory was accepted")
        } catch GitWorktreeError.invalidDestination {}
    }

    @MainActor func testReplacedLockedWorktreeIsRejectedBySelectionAndRuntimeLaunch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Pikachu-Locked-Worktree-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("project")
        let checkout = root.appendingPathComponent("locked checkout")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["-c", "user.email=worktree@example.test", "-c", "user.name=Worktree Test", "commit",
                    "--allow-empty", "-m", "base"], cwd: repo)
        try runGit(["worktree", "add", "--lock", "-b", "locked", checkout.path], cwd: repo)

        var launchedPaths: [String] = []
        let workspace = WorkspaceController(store: MemoryStore(), reader: PiHistoryReader(roots: []), validateWorktree: { project, path in
            await GitRepositoryInspector.isUsableWorktree(path, in: project)
        }) { project, session in
            launchedPaths.append(session.workingDirectory(in: project))
            return StubSessionRuntime()
        }
        await workspace.start()
        let addedProject = await workspace.addProject(repo)
        let projectID = try XCTUnwrap(addedProject)
        let originalID = try XCTUnwrap(workspace.selected?.id)
        let chosen = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: originalID)
        XCTAssertTrue(chosen)
        let available = await GitRepositoryInspector.worktrees(in: repo.path)
        let canonicalCheckout = checkout.resolvingSymlinksInPath().path
        XCTAssertTrue(available?.contains(where: { $0.path == canonicalCheckout }) == true)
        await workspace.send(originalID, submitted: .init(text: "run in locked checkout"))
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        await workspace.stop(originalID)
        let closed = await workspace.disconnect(originalID)
        XCTAssertTrue(closed)

        try fm.moveItem(at: checkout, to: root.appendingPathComponent("moved checkout"))
        try fm.createDirectory(at: checkout, withIntermediateDirectories: false)
        let remaining = await GitRepositoryInspector.worktrees(in: repo.path)
        XCTAssertFalse(remaining?.contains(where: { $0.path == canonicalCheckout }) ?? true)

        let originalController = try XCTUnwrap(workspace.viewed?.controller)
        originalController.draft = "keep this draft"
        await workspace.send(originalID)
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        XCTAssertEqual(workspace.workingDirectory(for: originalID), canonicalCheckout)
        XCTAssertEqual(originalController.draft, "keep this draft")
        XCTAssertNotNil(workspace.viewed?.executionError)

        // A checkout from another repository cannot satisfy the original registration either.
        try runGit(["init"], cwd: checkout)
        let createdSession = await workspace.createSession(in: projectID)
        let newID = try XCTUnwrap(createdSession)
        let replacement = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: newID)
        XCTAssertFalse(replacement)
        XCTAssertEqual(workspace.workingDirectory(for: newID), repo.resolvingSymlinksInPath().path)

        try fm.removeItem(at: checkout)
        await workspace.send(originalID)
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        XCTAssertEqual(originalController.draft, "keep this draft")
    }

    @MainActor func testSymlinkReplacementCannotRedirectASavedWorktree() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("Pikachu-Worktree-Redirect-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("project")
        let checkout = root.appendingPathComponent("locked checkout")
        let other = root.appendingPathComponent("other checkout")
        try fm.createDirectory(at: repo, withIntermediateDirectories: false)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["-c", "user.email=worktree@example.test", "-c", "user.name=Worktree Test", "commit",
                    "--allow-empty", "-m", "base"], cwd: repo)
        try runGit(["worktree", "add", "--lock", "-b", "locked", checkout.path], cwd: repo)
        try runGit(["worktree", "add", "-b", "other", other.path], cwd: repo)

        let historyFile = root.appendingPathComponent("original.jsonl")
        let header: [String: Any] = ["type": "session", "version": 3, "id": "locked-session",
                                      "cwd": checkout.path, "timestamp": "2026-11-18T00:00:00Z"]
        var history = try JSONSerialization.data(withJSONObject: header)
        history.append(0x0A)
        try history.write(to: historyFile)
        let store = MemoryStore()
        var launchedPaths: [String] = []
        func makeWorkspace() -> WorkspaceController {
            WorkspaceController(store: store, reader: PiHistoryReader(roots: []), validateWorktree: { project, path in
                await GitRepositoryInspector.isUsableWorktree(path, in: project)
            }) { project, session in
                let path = session.workingDirectory(in: project)
                launchedPaths.append(path)
                if path == checkout.path { return StubSessionRuntime(sessionID: "locked-session", file: historyFile) }
                return StubSessionRuntime(sessionID: session.id.uuidString)
            }
        }
        let workspace = makeWorkspace()
        await workspace.start()
        let addedProject = await workspace.addProject(repo)
        let projectID = try XCTUnwrap(addedProject)
        let originalID = try XCTUnwrap(workspace.selected?.id)
        let chosen = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: originalID)
        XCTAssertTrue(chosen)
        await workspace.send(originalID, submitted: .init(text: "initial launch"))
        XCTAssertEqual(launchedPaths, [checkout.path])
        await workspace.stop(originalID)
        let closed = await workspace.disconnect(originalID)
        XCTAssertTrue(closed)

        let newSession = await workspace.createSession(in: projectID)
        let unlaunchedID = try XCTUnwrap(newSession)
        let prepared = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: unlaunchedID)
        XCTAssertTrue(prepared)
        await workspace.select(originalID)
        let original = try XCTUnwrap(workspace.viewed)
        original.controller.draft = "keep the draft"
        let attachment = root.appendingPathComponent("notes.txt")
        original.controller.draftFiles = [attachment]
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        try fm.moveItem(at: checkout, to: root.appendingPathComponent("moved checkout"))

        for replacement in [other, repo] {
            try fm.createSymbolicLink(at: checkout, withDestinationURL: replacement)

            let worktrees = await GitRepositoryInspector.worktrees(in: repo.path)
            let listed = try XCTUnwrap(worktrees)
            XCTAssertEqual(listed.count, 2)
            XCTAssertEqual(Set(listed.map(\.path)), Set([repo.path, other.path]))
            XCTAssertEqual(listed.first { $0.path == repo.path }?.branch, "main")
            XCTAssertEqual(listed.first { $0.path == other.path }?.branch, "other")
            XCTAssertFalse(listed.contains { $0.branch == "locked" })

            let chosenAlias = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: unlaunchedID)
            XCTAssertFalse(chosenAlias)
            XCTAssertEqual(workspace.workingDirectory(for: unlaunchedID), checkout.path)
            await workspace.send(originalID)
            XCTAssertEqual(launchedPaths, [checkout.path])
            XCTAssertTrue(original.executionError?.contains(checkout.path) == true)
            XCTAssertEqual(original.controller.draft, "keep the draft")
            XCTAssertEqual(original.controller.draftFiles, [attachment])

            let reopened = makeWorkspace()
            await reopened.start()
            await reopened.select(originalID)
            XCTAssertEqual(reopened.selected?.worktreePath, checkout.path)
            XCTAssertEqual(reopened.viewed?.history?.sessionID, "locked-session")
            let activated = await reopened.activate(originalID)
            XCTAssertFalse(activated)
            XCTAssertTrue(reopened.viewed?.executionError?.contains(checkout.path) == true)
            XCTAssertEqual(reopened.viewed?.controller.draft, "keep the draft")
            XCTAssertEqual(launchedPaths, [checkout.path])

            if replacement == other { try fm.removeItem(at: checkout) }
        }

        // Explicit project selection clears an unlaunched choice and forks a bound session.
        let reset = await workspace.chooseWorkingDirectory(worktree: nil, for: unlaunchedID)
        XCTAssertTrue(reset)
        XCTAssertEqual(workspace.workingDirectory(for: unlaunchedID), repo.path)
        XCTAssertNil(workspace.state.sessions.first { $0.id == unlaunchedID }?.worktreePath)

        let forked = await workspace.chooseWorkingDirectory(worktree: nil, for: originalID)
        XCTAssertTrue(forked)
        let recoveryID = try XCTUnwrap(workspace.selected?.id)
        XCTAssertNotEqual(recoveryID, originalID)
        XCTAssertNil(workspace.selected?.worktreePath)
        XCTAssertEqual(workspace.workingDirectory(for: recoveryID), repo.path)
        XCTAssertEqual(workspace.viewed?.controller.draft, "keep the draft")
        XCTAssertEqual(workspace.viewed?.controller.draftFiles, [attachment])
        XCTAssertEqual(workspace.workingDirectory(for: originalID), checkout.path)
        XCTAssertEqual(original.controller.draft, "keep the draft")
        XCTAssertEqual(try Data(contentsOf: historyFile), history)
        await workspace.send(recoveryID)
        XCTAssertEqual(launchedPaths, [checkout.path, repo.path])
        _ = await workspace.disconnect(recoveryID)
    }

    @MainActor func testCurrentApprovalOpensAutomaticallyAfterAnotherSheetCloses() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let instance = runtime.instanceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)

        let blockingSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(blockingSheet, completionHandler: nil)
        await settleWindow(window)
        let request = RuntimeInteraction(instanceID: instance, requestID: "auto-approval", kind: .confirm, title: "Confirm fixture",
                                         toolApproval: .init(workingDirectory: "/fixture/" + String(repeating: "long-directory/", count: 12),
                                                             operation: .command(text: "printf fixture", timeoutSeconds: nil)))
        controller.receive(.init(instanceID: instance, event: .interaction(request)))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === blockingSheet)
        XCTAssertEqual(controller.interactions, [request])

        window.endSheet(blockingSheet)
        for _ in 0..<30 where window.attachedSheet == nil || window.attachedSheet === blockingSheet {
            try await Task.sleep(for: .milliseconds(30))
            await settleWindow(window)
        }
        let approvalSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(approvalSheet === blockingSheet)
        XCTAssertEqual(approvalSheet.frame.width, 640, accuracy: 1)
        XCTAssertLessThan(approvalSheet.frame.height, 250, "A short command should fit its contents")
        XCTAssertEqual(controller.interactions, [request], "Automatically showing an approval must not answer it")
        let activeHeight = approvalSheet.frame.height
        controller.receive(.init(instanceID: instance, event: .interactionEnded(request.id, .expired)))
        try await settleApprovalResize(approvalSheet, from: activeHeight)
        XCTAssertTrue(controller.didExpire(request))
        XCTAssertTrue(window.attachedSheet === approvalSheet)
        XCTAssertEqual(approvalSheet.frame.width, 640, accuracy: 1)
        let expiredContent = try XCTUnwrap(approvalSheet.contentView)
        XCTAssertGreaterThan(approvalSheet.frame.height, activeHeight)
        XCTAssertGreaterThanOrEqual(expiredContent.bounds.height + 1, expiredContent.fittingSize.height)
        try clickApproval(in: expiredContent, x: expiredContent.bounds.width - 40,
                          fromTop: expiredContent.bounds.height - 34)
        try await awaitApprovalSheetDismissal(in: window)
        _ = await workspace.disconnect(id)
    }

    @MainActor func testInteractionCountdownTicksAndStopsAtZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = InteractionCountdown(expiresAt: now.addingTimeInterval(65))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now), .seconds(65))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(1)), .seconds(64))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(64.75)), .seconds(1))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(65)), .zero)
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(66)), .zero)
    }

    @MainActor func testEditApprovalPreviewFitsShortChangesAndScrollsLongChanges() throws {
        func replacement(old: String, new: String) throws -> RuntimeToolApproval.Replacement {
            let data = try JSONSerialization.data(withJSONObject: ["oldText": old, "newText": new])
            return try JSONDecoder().decode(RuntimeToolApproval.Replacement.self, from: data)
        }
        let short = try replacement(old: "let n = 1", new: "let n = 2")
        let long = try replacement(old: Array(repeating: "let n = 1", count: 40).joined(separator: "\n"), new: "let n = 2")
        func height(_ replacements: [RuntimeToolApproval.Replacement], expanded: Bool) -> CGFloat {
            NSHostingView(rootView: EditApprovalPreview(replacements: replacements, isExpanded: .constant(expanded))
                .frame(width: 580)).fittingSize.height
        }
        let collapsed = height([short], expanded: false)
        XCTAssertLessThan(collapsed, 44)
        XCTAssertEqual(height([long, short], expanded: false), collapsed, accuracy: 1)
        let expandedShort = height([short], expanded: true) - collapsed
        XCTAssertGreaterThan(expandedShort, 60)
        XCTAssertLessThan(expandedShort, 196)
        XCTAssertEqual(height([long, short], expanded: true) - collapsed, 250, accuracy: 1)

        let request = RuntimeInteraction(
            instanceID: StubSessionRuntime().instanceID, requestID: "edit-approval", kind: .confirm, title: "Edit fixture",
            toolApproval: .init(workingDirectory: "/fixture", operation: .edit(path: "file.swift", replacements: [long, short]))
        )
        let sheet = NSHostingView(rootView: InteractionView(request: request, controller: SessionController(), sessionTitle: "Fixture"))
        XCTAssertEqual(sheet.fittingSize.width, 640, accuracy: 1)
        XCTAssertLessThan(sheet.fittingSize.height, 250, "Editing details should start collapsed")
    }

    @MainActor func testApprovalWidthUsesPrimaryContentAndRestoresThePreferredTier() {
        let standard = PikachuTypography()
        func width(_ command: String, typography: PikachuTypography = .init()) -> CGFloat? {
            ApprovalSheetLayout.preferredWidth(for: .command(text: command, timeoutSeconds: nil), typography: typography)
        }
        XCTAssertEqual(width("printf fixture"), 640)
        XCTAssertEqual(width(Array(repeating: "printf fixture", count: 12).joined(separator: "\n")), 640)
        XCTAssertEqual(width(String(repeating: "x", count: 200)), 700)
        XCTAssertEqual(width(String(repeating: "foo ", count: 28)), 640)
        XCTAssertEqual(width(String(repeating: "foo ", count: 28), typography: .init(size: .extraLarge)), 700)
        XCTAssertEqual(ApprovalSheetLayout.preferredWidth(for: .edit(path: "file.swift", replacements: []), typography: standard), 640)
        XCTAssertEqual(ApprovalSheetLayout.preferredWidth(for: .edit(path: String(repeating: "dir/", count: 30) + "file.swift",
                                                                      replacements: []), typography: standard), 700)
        XCTAssertNil(ApprovalSheetLayout.preferredWidth(for: .write(path: "file.swift", content: ""), typography: standard))
        XCTAssertNil(ApprovalSheetLayout.preferredWidth(for: .inspect(.read, arguments: []), typography: standard))
        XCTAssertEqual(ApprovalSheetLayout.width(preferred: 700, available: 640), 592)
        XCTAssertEqual(ApprovalSheetLayout.width(preferred: 700, available: 860), 700)
    }

    @MainActor func testCommandPreviewWrapTogglePreservesOriginalClipboardText() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let command = "printf " + String(repeating: "x", count: 200) + "\r\n  printf '尾部'\n"
        let host = NSHostingView(rootView: CommandApprovalPreview(command: command, wrapsLines: .constant(true), pasteboard: pasteboard)
            .frame(width: 592).pikachuTypography(.extraLarge))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)

        for wrapsLines in [true, false] {
            host.rootView = CommandApprovalPreview(command: command, wrapsLines: .constant(wrapsLines), pasteboard: pasteboard)
                .frame(width: 592).pikachuTypography(.extraLarge)
            pasteboard.clearContents()
            await settleWindow(window)
            let scroll = try XCTUnwrap(approvalScrollViews(in: host).first)
            try clickApproval(in: host, x: host.bounds.width - ApprovalSheetLayout.previewInset - ApprovalSheetLayout.previewActionSize / 2,
                              fromTop: approvalTop(of: scroll, in: host) + ApprovalSheetLayout.previewActionSize / 2)
            await settleWindow(window)
            let copied = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertEqual(Array(copied.utf8), Array(command.utf8))
        }
    }

    @MainActor func testAdaptiveApprovalSheetsThroughWorkbench() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        func present(_ operation: RuntimeToolApproval.Operation, id: String) async throws -> (RuntimeInteraction, NSWindow) {
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: id, kind: .confirm,
                                             title: "Approval fixture",
                                             toolApproval: .init(workingDirectory: "/fixture/pikachu", operation: operation))
            runtime.emit(.interaction(request))
            let sheet = try await awaitApprovalSheet(in: window)
            XCTAssertEqual(controller.interactions, [request])
            return (request, sheet)
        }

        let command = "printf 'first line'\nprintf " + String(repeating: "x", count: 250) + "\nprintf 'last line'"
        let (commandRequest, commandSheet) = try await present(.command(text: command, timeoutSeconds: 10), id: "long-command")
        XCTAssertEqual(commandSheet.frame.width, 700, accuracy: 1)
        let commandContent = try XCTUnwrap(commandSheet.contentView)
        let initialHeight = commandSheet.frame.height
        let wrappedScroll = try XCTUnwrap(approvalScrollViews(in: commandContent).first { !$0.hasHorizontalScroller })
        addApprovalScreenshot(of: commandContent, name: "Command approval · light · wrap on")
        let wrapFromRight = ApprovalSheetLayout.inset + ApprovalSheetLayout.previewInset
            + ApprovalSheetLayout.previewActionSize * 1.5 + ApprovalSheetLayout.previewActionSpacing
        try clickApproval(in: commandContent, x: commandContent.bounds.width - wrapFromRight,
                          fromTop: approvalTop(of: wrappedScroll, in: commandContent) + ApprovalSheetLayout.previewActionSize / 2)
        try await settleApprovalResize(commandSheet, from: initialHeight)
        XCTAssertEqual(commandSheet.frame.width, 700, accuracy: 1)
        XCTAssertLessThan(commandSheet.frame.height, initialHeight)
        let unwrappedScroll = try XCTUnwrap(approvalScrollViews(in: commandContent).first {
            $0.hasHorizontalScroller && $0.hasVerticalScroller
        })
        addApprovalScreenshot(of: commandContent, name: "Command approval · light · wrap off")
        let document = try XCTUnwrap(unwrappedScroll.documentView)
        let horizontalOverflow = document.frame.width - unwrappedScroll.contentView.bounds.width
        XCTAssertGreaterThan(horizontalOverflow, 100)
        unwrappedScroll.contentView.scroll(to: NSPoint(x: horizontalOverflow, y: 0))
        XCTAssertGreaterThan(unwrappedScroll.contentView.bounds.minX, 0)

        window.setContentSize(CGSize(width: 720, height: 620))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === commandSheet)
        XCTAssertEqual(commandSheet.frame.width, 672, accuracy: 1)
        window.setContentSize(CGSize(width: 1120, height: 760))
        await settleWindow(window)
        XCTAssertEqual(commandSheet.frame.width, 700, accuracy: 1)

        runtime.emit(.interactionEnded(commandRequest.id, .expired))
        for _ in 0..<25 where !controller.didExpire(commandRequest) {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        await settleWindow(commandSheet)
        XCTAssertTrue(controller.didExpire(commandRequest))
        XCTAssertTrue(window.attachedSheet === commandSheet)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: commandSheet.windowNumber, context: nil, characters: "\u{1B}",
                                                  charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        commandSheet.sendEvent(escape)
        try await awaitApprovalSheetDismissal(in: window)

        let path = String(repeating: "long-directory/", count: 12) + "Target.swift"
        let old = Array(repeating: "let n = 1", count: 40).joined(separator: "\n")
        let replacements = try JSONDecoder().decode([RuntimeToolApproval.Replacement].self, from: JSONSerialization.data(withJSONObject: [
            ["oldText": old, "newText": "let n = 2"],
            ["oldText": "let m = 1", "newText": "let m = 2"]
        ]))
        let (editRequest, editSheet) = try await present(.edit(path: path, replacements: replacements), id: "long-edit")
        editSheet.appearance = NSAppearance(named: .darkAqua)
        await settleWindow(editSheet)
        let editContent = try XCTUnwrap(editSheet.contentView)
        XCTAssertEqual(editSheet.frame.width, 700, accuracy: 1)
        let collapsedHeight = editSheet.frame.height
        XCTAssertLessThan(collapsedHeight, 250)
        let targetPath = try XCTUnwrap(approvalScrollViews(in: editContent).first {
            ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 100
        })
        addApprovalScreenshot(of: editContent, name: "Edit approval · dark · collapsed")
        try clickApproval(in: editContent, x: editContent.bounds.midX,
                          fromTop: approvalTop(of: targetPath, in: editContent) + targetPath.bounds.height + 26)
        try await settleApprovalResize(editSheet, from: collapsedHeight)
        XCTAssertEqual(editSheet.frame.width, 700, accuracy: 1)
        XCTAssertGreaterThan(editSheet.frame.height, collapsedHeight + 200)
        XCTAssertLessThan(editSheet.frame.height, window.frame.height)
        addApprovalScreenshot(of: editContent, name: "Edit approval · dark · expanded")
        let expandedHeight = editSheet.frame.height
        let expandedPath = try XCTUnwrap(approvalScrollViews(in: editContent).first {
            ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 100
        })
        try clickApproval(in: editContent, x: editContent.bounds.midX,
                          fromTop: approvalTop(of: expandedPath, in: editContent) + expandedPath.bounds.height + 26)
        try await settleApprovalResize(editSheet, from: expandedHeight)
        XCTAssertEqual(editSheet.frame.width, 700, accuracy: 1)
        XCTAssertEqual(editSheet.frame.height, collapsedHeight, accuracy: 1)
        runtime.emit(.interactionEnded(editRequest.id, .cancelled))
        try await awaitApprovalSheetDismissal(in: window)
        _ = await workspace.disconnect(id)
    }

    @MainActor private func awaitApprovalSheet(in window: NSWindow) async throws -> NSWindow {
        for _ in 0..<25 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        await settleWindow(sheet)
        return sheet
    }

    @MainActor private func awaitApprovalSheetDismissal(in window: NSWindow) async throws {
        for _ in 0..<25 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor private func settleApprovalResize(_ sheet: NSWindow, from previousHeight: CGFloat) async throws {
        for _ in 0..<25 where sheet.frame.height == previousHeight {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(sheet)
        }
        await settleWindow(sheet)
    }

    @MainActor private func addApprovalScreenshot(of view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func approvalScrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { approvalScrollViews(in: $0) }
    }

    @MainActor private func approvalTop(of view: NSView, in root: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: root)
        return root.isFlipped ? rect.minY - root.bounds.minY : root.bounds.maxY - rect.maxY
    }

    @MainActor private func clickApproval(in view: NSView, x: CGFloat, fromTop: CGFloat) throws {
        let window = try XCTUnwrap(view.window)
        let y = view.isFlipped ? view.bounds.minY + fromTop : view.bounds.maxY - fromTop
        let location = view.convert(NSPoint(x: x, y: y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    @MainActor func testInteractionViewsDoNotCaptureTheWorkbenchStopShortcut() async throws {
        var controlInvoked = false
        let control = Button("Shortcut control") { controlInvoked = true }
            .keyboardShortcut(".", modifiers: .command)
        let host = NSHostingView(rootView: AnyView(control))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                   characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47))
        XCTAssertTrue(host.performKeyEquivalent(with: event))
        XCTAssertTrue(controlInvoked)

        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Background session"))
        let toolApproval = RuntimeToolApproval(workingDirectory: "/tmp", operation: .write(path: "/tmp/fixture.txt", content: "fixture"))
        for (index, approval) in [nil, toolApproval].enumerated() {
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "\(index)", kind: .confirm,
                                             title: "Background request", toolApproval: approval)
            controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
            XCTAssertTrue(controller.canStop)
            host.rootView = AnyView(InteractionView(request: request, controller: controller, sessionTitle: "A"))
            await settleWindow(window)
            XCTAssertFalse(host.performKeyEquivalent(with: event))
            XCTAssertTrue(controller.interactions.contains(request))
        }
        _ = await controller.disconnect()
    }

    @MainActor func testSettingsSheetGrowsAndShrinksWithWorkbench() async throws {
        let workspace = await newConversationWorkspace()
        let settings = AppSettings()
        func root(openRequest: Int) -> WorkbenchView {
            WorkbenchView(workspace: workspace, settings: settings, quitRequest: 0, openSettingsRequest: openRequest,
                          terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all))
        }
        let host = NSHostingView(rootView: root(openRequest: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)
        host.rootView = root(openRequest: 1)
        for _ in 0..<30 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        await settleWindow(window)
        let compact = sheet.frame.size
        XCTAssertLessThan(compact.width, window.frame.width)
        XCTAssertLessThan(compact.height, window.frame.height)

        window.setContentSize(CGSize(width: 1120, height: 760))
        await settleWindow(window)
        let expanded = sheet.frame.size
        XCTAssertGreaterThan(expanded.width, compact.width + 100)
        XCTAssertGreaterThan(expanded.height, compact.height + 75)
        XCTAssertLessThan(expanded.width, window.frame.width)
        XCTAssertLessThan(expanded.height, window.frame.height)

        window.setContentSize(CGSize(width: 860, height: 620))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(sheet.frame.width, compact.width, accuracy: 1)
        XCTAssertEqual(sheet.frame.height, compact.height, accuracy: 1)
    }

    @MainActor func testSettingsPanelProjectPiConfigToggleAndLateWorktreeGuard() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("Pikachu-Settings-UI-\(UUID())")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let root = temp.resolvingSymlinksInPath()
        let projectADir = root.appendingPathComponent("project-a")
        let projectBDir = root.appendingPathComponent("project-b")
        let worktreeBDir = root.appendingPathComponent("project-b-wt")
        try fm.createDirectory(at: projectADir, withIntermediateDirectories: false)
        try fm.createDirectory(at: projectBDir, withIntermediateDirectories: false)
        try runGit(["init", "-b", "main"], cwd: projectBDir)
        try runGit(["-c", "user.email=settings@example.test", "-c", "user.name=Settings Test", "commit", "--allow-empty", "-m", "base"], cwd: projectBDir)
        try runGit(["worktree", "add", "-b", "feature-wt", worktreeBDir.path], cwd: projectBDir)

        let workspace = WorkspaceController(store: MemoryStore(), reader: PiHistoryReader(roots: [])) { _, _ in
            StubSessionRuntime()
        }
        await workspace.start()
        let addedProjectA = await workspace.addProject(projectADir, createInitialSession: false)
        let projectA = try XCTUnwrap(addedProjectA)
        let addedProjectB = await workspace.addProject(projectBDir, createInitialSession: false)
        let projectB = try XCTUnwrap(addedProjectB)
        XCTAssertTrue(workspace.state.sessions.isEmpty)

        actor LookupGate {
            private var continuation: CheckedContinuation<[GitWorktree]?, Never>?
            private var pausedOnce = false
            func waitForFirstProjectAResult(onStart: @Sendable () -> Void) async -> [GitWorktree]? {
                guard !pausedOnce else { return nil }
                pausedOnce = true
                onStart()
                return await withCheckedContinuation { continuation = $0 }
            }
            func resolveStale(_ value: [GitWorktree]?) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let gate = LookupGate()
        let startedA = expectation(description: "Started worktree query for project A")
        let projectState = SettingsProjectState(selectedID: projectA)
        let settingsPanel = SettingsPanel(
            workspace: workspace,
            settings: AppSettings(),
            initialSection: .projects,
            preferredProjectID: projectA,
            projectState: projectState,
            worktreesForProject: { path in
                if WorkspaceController.canonicalPath(path) == projectADir.path {
                    return await gate.waitForFirstProjectAResult { startedA.fulfill() }
                }
                return await GitRepositoryInspector.worktrees(in: path)
            },
            close: {},
            restart: {}
        )

        let host = NSHostingView(rootView: settingsPanel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await fulfillment(of: [startedA], timeout: 2)
        await settleWindow(window)

        func selectableTexts(in view: NSView) -> [String] {
            var values: [String] = []
            if String(describing: type(of: view)).contains("AppKitTextInteractionView"),
               let text = view.accessibilityValue() as? String {
                values.append(text)
            }
            for child in view.subviews {
                values.append(contentsOf: selectableTexts(in: child))
            }
            return values
        }

        let recordA = try XCTUnwrap(workspace.state.projects.first { $0.id == projectA })
        let recordB = try XCTUnwrap(workspace.state.projects.first { $0.id == projectB })

        XCTAssertEqual(projectState.targetDirectory(for: recordA), projectADir.path)
        XCTAssertTrue(projectState.extraWorktrees(for: recordA).isEmpty)
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: projectADir.path))
        XCTAssertTrue(selectableTexts(in: host).contains(projectADir.path))

        // Switch to project B before project A's worktree lookup completes.
        projectState.selectedID = projectB
        await settleWindow(window)

        // Deliver a stale worktree result for project A; it must not overwrite project B.
        await gate.resolveStale([GitWorktree(path: "/stale/worktree/from-a", branch: "stale", commit: nil)])
        let deadline = Date().addingTimeInterval(2)
        while projectState.loadedWorktreesProjectID != projectB && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await settleWindow(window)

        XCTAssertNotEqual(projectState.loadedWorktreesProjectID, projectA)
        XCTAssertEqual(projectState.loadedWorktreesProjectID, projectB)
        XCTAssertEqual(projectState.targetDirectory(for: recordB), projectBDir.path)
        XCTAssertEqual(projectState.extraWorktrees(for: recordB).map(\.path), [worktreeBDir.path])
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: projectBDir.path))
        XCTAssertTrue(selectableTexts(in: host).contains(projectBDir.path))

        // Select worktree in project B: only updates target directory, enables worktree independently.
        projectState.selectConfigDirectory(worktreeBDir.path, for: recordB)
        await settleWindow(window)
        XCTAssertEqual(projectState.targetDirectory(for: recordB), worktreeBDir.path)
        XCTAssertTrue(selectableTexts(in: host).contains(worktreeBDir.path))
        let toggleWT = await workspace.setProjectPiConfigTrusted(true, forProject: projectB, directory: worktreeBDir.path)
        XCTAssertNil(toggleWT)
        XCTAssertTrue(workspace.isProjectPiConfigTrusted(for: worktreeBDir.path))
        XCTAssertFalse(workspace.isProjectPiConfigTrusted(for: projectBDir.path))

        // Relocate project A -> target resets to relocated path and ignores stale lookups.
        let movedADir = root.appendingPathComponent("project-a-moved")
        try fm.createDirectory(at: movedADir, withIntermediateDirectories: false)
        projectState.selectedID = projectA
        await settleWindow(window)
        let relocatedA = await workspace.relocateProject(projectA, to: movedADir)
        XCTAssertEqual(relocatedA?.warning, false)
        await settleWindow(window)
        let movedRecordA = try XCTUnwrap(workspace.state.projects.first { $0.id == projectA })
        XCTAssertEqual(projectState.targetDirectory(for: movedRecordA), movedADir.path)
        XCTAssertTrue(selectableTexts(in: host).contains(movedADir.path))
    }

    private func runGit(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "GitTest", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}


@MainActor @Observable private final class TestSidebarVisibility {
    var value: NavigationSplitViewVisibility = .all
}
