import SwiftUI
import XCTest
import OrchestrationCore
@testable import Zivvi

@MainActor
final class SwiftUITranscriptTests: XCTestCase {
    private struct Harness: View {
        let rows: [TranscriptDisplayRow]
        let state: TranscriptScrollState
        var historyLoading = false
        var body: some View {
            SwiftUITranscript(entries: NativeTranscriptRow.project(rows, footers: [:]), scrollState: state,
                              historyLoading: historyLoading, composerClearance: 100)
        }
    }

    private func rows(_ count: Int) -> [TranscriptDisplayRow] {
        (0..<count).map { .item(.init(id: "message-\($0)", kind: .assistant, text: "Message \($0)")) }
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    @MainActor private struct Fixture {
        let window: NSWindow
        let host: NSHostingView<Harness>
        let state: TranscriptScrollState
        let scroll: NSScrollView

        var isAtBottom: Bool {
            guard let document = scroll.documentView else { return false }
            return scroll.contentView.bounds.maxY >= document.frame.maxY - 8
        }
    }

    private func makeWindow(contentView: NSView? = nil, styleMask: NSWindow.StyleMask = [.borderless]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: styleMask, backing: .buffered, defer: false)
        window.contentView = contentView
        addTeardownBlock { [weak window] in
            await MainActor.run {
                window?.contentView = nil
                window?.orderOut(nil)
            }
        }
        return window
    }

    private func makeFixture(rowCount: Int = 40) async throws -> Fixture {
        let state = TranscriptScrollState()
        let host = NSHostingView(rootView: Harness(rows: rows(rowCount), state: state))
        let window = makeWindow(contentView: host)
        await settle(host)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host), "transcript scroll view is missing")
        return Fixture(window: window, host: host, state: state, scroll: scroll)
    }

    func testTranscriptStartsAtNewestContentAndFollowsAppendedRows() async throws {
        let fixture = try await makeFixture()
        XCTAssertTrue(fixture.state.follow)
        XCTAssertGreaterThan(fixture.scroll.contentView.bounds.minY, 100)
        XCTAssertTrue(fixture.isAtBottom)

        fixture.host.rootView = Harness(rows: rows(46), state: fixture.state)
        await settle(fixture.host)
        XCTAssertTrue(fixture.state.follow)
        XCTAssertTrue(fixture.isAtBottom, "appended rows must keep a following viewport at the bottom")
    }

    func testReleasedFollowIsNotPulledBackByAppendedRows() async throws {
        let fixture = try await makeFixture()
        fixture.state.requestJump(to: "message-3")
        await settle(fixture.host)
        XCTAssertFalse(fixture.state.follow)
        let readingY = fixture.scroll.contentView.bounds.minY

        fixture.host.rootView = Harness(rows: rows(46), state: fixture.state)
        await settle(fixture.host)
        XCTAssertFalse(fixture.state.follow)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, readingY, accuracy: 2)
    }

    func testJumpMovesToTheMessageAndLatestReturnsToTheBottom() async throws {
        let fixture = try await makeFixture()
        let bottomY = fixture.scroll.contentView.bounds.minY
        fixture.state.requestJump(to: "message-3")
        await settle(fixture.host)
        XCTAssertFalse(fixture.state.follow)
        XCTAssertEqual(fixture.state.jump?.messageID, "message-3")
        XCTAssertLessThan(fixture.scroll.contentView.bounds.minY, bottomY - 100)

        fixture.state.requestFollow()
        await settle(fixture.host)
        XCTAssertTrue(fixture.state.follow)
        XCTAssertTrue(fixture.isAtBottom)
        XCTAssertNil(fixture.state.jump)
    }

    func testJumpToAppendedMessageUsesCurrentRows() async throws {
        let fixture = try await makeFixture(rowCount: 20)
        fixture.host.rootView = Harness(rows: rows(80), state: fixture.state)
        await settle(fixture.host)
        let bottom = fixture.scroll.contentView.bounds.minY
        fixture.state.requestJump(to: "message-40")
        await settle(fixture.host)
        XCTAssertLessThan(fixture.scroll.contentView.bounds.minY, bottom - 100)
        XCTAssertFalse(fixture.state.follow)
    }

    func testRepeatedJumpPreservesReadingPosition() async throws {
        let fixture = try await makeFixture()
        fixture.state.requestJump(to: "message-15")
        await settle(fixture.host)
        let anchor = try XCTUnwrap(fixture.state.readingAnchor)
        fixture.state.requestJump(to: "message-15")
        await settle(fixture.host)
        XCTAssertEqual(fixture.state.readingAnchor, anchor)
    }

    func testReadingPositionSurvivesTranscriptRemount() async throws {
        let fixture = try await makeFixture(rowCount: 60)
        fixture.state.requestJump(to: "message-15")
        await settle(fixture.host)
        let clip = fixture.scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: clip.bounds.minY + 9))
        fixture.scroll.reflectScrolledClipView(clip)
        await settle(fixture.host)
        let savedY = clip.bounds.minY
        XCTAssertNotNil(fixture.state.readingAnchor)
        fixture.window.contentView = nil
        let replacement = NSHostingView(rootView: Harness(rows: rows(60), state: fixture.state))
        fixture.window.contentView = replacement
        await settle(replacement)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: replacement))
        XCTAssertFalse(fixture.state.follow)
        XCTAssertEqual(scroll.contentView.bounds.minY, savedY, accuracy: 2)
    }

    func testReturningToDeletedAnchorRemembersTheSurvivingNeighbors() async throws {
        let state = TranscriptScrollState()
        state.follow = false
        state.readingAnchor = .init(id: "removed", offset: 50, next: "message-30", previous: nil)
        let window = makeWindow()
        let history = rows(65)
        let host = NSHostingView(rootView: Harness(rows: history, state: state))
        window.contentView = host
        await settle(host)
        XCTAssertEqual(state.readingAnchor?.id, "message-30")
        XCTAssertEqual(state.readingAnchor?.next, "message-31")
        window.contentView = nil
        let replacement = NSHostingView(rootView: Harness(rows: history.filter { $0.id != "message-30" }, state: state))
        window.contentView = replacement
        await settle(replacement)
        XCTAssertEqual(state.readingAnchor?.id, "message-31")
        XCTAssertEqual(state.readingAnchor?.next, "message-32")
    }

    func testUserJumpCancelsRestoreWhileHistoryLoads() async throws {
        try await checkNavigationDuringHistoryLoad(returnToLatest: false)
    }

    func testReturnToLatestCancelsRestoreWhileHistoryLoads() async throws {
        try await checkNavigationDuringHistoryLoad(returnToLatest: true)
    }

    private func checkNavigationDuringHistoryLoad(returnToLatest: Bool) async throws {
        let state = TranscriptScrollState()
        state.follow = false
        state.readingAnchor = .init(id: "message-45", offset: 9, next: nil, previous: nil)
        let history = rows(65)
        let host = NSHostingView(rootView: Harness(rows: history, state: state, historyLoading: true))
        let window = makeWindow()
        window.contentView = host
        await settle(host)
        if returnToLatest {
            state.requestFollow()
        } else {
            state.requestJump(to: "message-3")
        }
        await settle(host)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        let requestedY = scroll.contentView.bounds.minY
        host.rootView = Harness(rows: history, state: state)
        await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minY, requestedY, accuracy: 2)
        XCTAssertEqual(state.follow, returnToLatest)
        XCTAssertEqual(state.jump?.messageID, returnToLatest ? nil : "message-3")
        if returnToLatest {
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.frame.maxY - 4)
            XCTAssertNil(state.readingAnchor)
        }
    }

    func testDiagnosticsUseCurrentRowsInEventWindowAndReleaseClosedSession() async throws {
        let metrics = DiagnosticMetrics.shared
        try XCTSkipUnless(metrics.measuresPixels, "Requires the isolated diagnostics configuration")
        func window() -> NSWindow {
            NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 340),
                     styleMask: [.titled], backing: .buffered, defer: false)
        }
        let first = window(), second = window()
        defer { first.orderOut(nil); second.orderOut(nil) }
        let otherHost = NSHostingView(rootView: Harness(rows: rows(20), state: TranscriptScrollState()))
        weak var released: TranscriptScrollState?
        do {
            let state = TranscriptScrollState()
            released = state
            let host = NSHostingView(rootView: Harness(rows: rows(20), state: state))
            first.contentView = host
            first.makeKeyAndOrderFront(nil)
            await settle(host)
            second.contentView = otherHost
            second.makeKeyAndOrderFront(nil)
            await settle(otherHost)
            host.rootView = Harness(rows: rows(70), state: state)
            await settle(host)
            XCTAssertFalse(try XCTUnwrap(metrics.scrollTarget(in: second)).positionScrollSample(at: 40))
            first.makeKeyAndOrderFront(nil)
            await settle(host)
            XCTAssertTrue(try XCTUnwrap(metrics.scrollTarget(in: first)).positionScrollSample(at: 40))
            await settle(host)
            XCTAssertFalse(state.follow)
            XCTAssertEqual(state.readingAnchor?.id, "message-40")
            first.contentView = nil
            first.orderOut(nil)
        }
        await settle(otherHost)
        XCTAssertNil(released)
        XCTAssertNil(metrics.scrollTarget(in: first))
        XCTAssertFalse(try XCTUnwrap(metrics.scrollTarget(in: second)).positionScrollSample(at: 40))
    }

    func testSecondOccurrenceRestoresEvenWhenAnotherIDLooksLikeASuffix() async throws {
        let state = TranscriptScrollState()
        var history = rows(60)
        history[35] = .item(.init(id: "message-8", kind: .assistant, text: "Duplicate"))
        history[17] = .item(.init(id: "message-8#1", kind: .assistant, text: "Literal suffix"))
        let duplicate = TranscriptReadingID("message-8", occurrence: 1)
        state.follow = false
        state.readingAnchor = .init(id: duplicate, offset: 9, next: "message-36", previous: "message-34")
        let host = NSHostingView(rootView: Harness(rows: history, state: state))
        let window = makeWindow()
        window.contentView = host
        await settle(host)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        let clip = scroll.contentView
        let restored = clip.bounds.minY
        clip.scroll(to: .init(x: 0, y: restored + 3))
        scroll.reflectScrolledClipView(clip)
        await settle(host)
        let captured = try XCTUnwrap(state.readingAnchor)
        XCTAssertEqual(captured.id, duplicate)
        XCTAssertEqual(captured.offset, 12, accuracy: 2)
        state.requestJump(to: "message-34")
        await settle(host)
        XCTAssertLessThan(clip.bounds.minY, restored)
        state.requestJump(to: "message-36")
        await settle(host)
        XCTAssertGreaterThan(clip.bounds.minY, restored)
    }

    func testFallbackRestorePlacesNeighborBelowTopClearance() async throws {
        let state = TranscriptScrollState()
        state.follow = false
        state.readingAnchor = .init(id: "removed", offset: 80, next: "message-20", previous: nil)
        let host = NSHostingView(rootView: Harness(rows: rows(65), state: state))
        let window = makeWindow()
        window.contentView = host
        await settle(host)
        let captured = try XCTUnwrap(state.readingAnchor)
        XCTAssertEqual(captured.id, "message-20")
        XCTAssertEqual(captured.offset, 0, accuracy: 2)
    }

    func testLongMessageOffsetRestoreDoesNotDoubleApply() async throws {
        var history = rows(50)
        let longText = (0..<35).map { "Line \($0) of a long assistant message." }.joined(separator: "\n")
        history[20] = .item(.init(id: "message-20", kind: .assistant, text: longText))
        let state = TranscriptScrollState()
        state.follow = false
        state.readingAnchor = .init(id: "message-20", offset: 140, next: "message-21", previous: "message-19")
        let host = NSHostingView(rootView: Harness(rows: history, state: state))
        let window = makeWindow()
        window.contentView = host
        await settle(host)
        let captured = try XCTUnwrap(state.readingAnchor)
        XCTAssertEqual(captured.id, "message-20")
        XCTAssertEqual(captured.offset, 140, accuracy: 3)
        // Confirm restore actually settled by nudging +4pt and verifying rememberPosition updates it.
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        let clip = scroll.contentView
        clip.scroll(to: .init(x: 0, y: clip.bounds.minY + 4))
        scroll.reflectScrolledClipView(clip)
        await settle(host)
        XCTAssertEqual(try XCTUnwrap(state.readingAnchor).offset, 144, accuracy: 3)
    }

    func testPreMountJumpIsHonoredOnAppear() async throws {
        let state = TranscriptScrollState()
        state.requestJump(to: "message-3")
        let host = NSHostingView(rootView: Harness(rows: rows(50), state: state))
        let window = makeWindow()
        window.contentView = host
        await settle(host)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertFalse(state.follow)
        XCTAssertEqual(state.jump?.messageID, "message-3")
        XCTAssertLessThan(scroll.contentView.bounds.maxY, document.frame.maxY - 200)
    }

    func testRemountKeepsScrollToLatestHandlerAcrossOutOfOrderTeardown() async throws {
        let state = TranscriptScrollState()
        let firstHost = NSHostingView(rootView: Harness(rows: rows(50), state: state))
        let firstWindow = makeWindow(contentView: firstHost)
        await settle(firstHost)
        state.requestJump(to: "message-12")
        await settle(firstHost)

        // Mount replacement before tearing down the previous instance, simulating SwiftUI view replacement.
        let secondHost = NSHostingView(rootView: Harness(rows: rows(50), state: state))
        let secondWindow = makeWindow(contentView: secondHost)
        await settle(secondHost)
        let replacementAnchor = try XCTUnwrap(state.readingAnchor)
        let firstScroll = try XCTUnwrap(findTranscriptScrollView(in: firstHost))
        firstScroll.contentView.scroll(to: .zero)
        firstScroll.reflectScrolledClipView(firstScroll.contentView)
        await settle(firstHost)
        XCTAssertEqual(state.readingAnchor, replacementAnchor)
        firstWindow.contentView = nil
        await settle(secondHost)

        state.requestJump(to: "message-3")
        await settle(secondHost)
        XCTAssertFalse(state.follow)
        state.requestFollow()
        await settle(secondHost)
        XCTAssertTrue(state.follow)
        let scroll = try XCTUnwrap(findTranscriptScrollView(in: secondHost))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.frame.maxY - 8)
        withExtendedLifetime(secondWindow) {}
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class SyntheticWheelEvent: NSEvent {
        private let eventWindow: NSWindow?
        private let windowLocation: NSPoint
        private let wheelDeltaX: CGFloat
        private let wheelDeltaY: CGFloat
        private let eventTimestamp: TimeInterval

        init(window: NSWindow?, location: NSPoint, deltaX: CGFloat, deltaY: CGFloat, timestamp: TimeInterval) {
            self.eventWindow = window
            self.windowLocation = location
            self.wheelDeltaX = deltaX
            self.wheelDeltaY = deltaY
            self.eventTimestamp = timestamp
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var type: NSEvent.EventType { .scrollWheel }
        override var window: NSWindow? { eventWindow }
        override var locationInWindow: NSPoint { windowLocation }
        override var scrollingDeltaX: CGFloat { wheelDeltaX }
        override var scrollingDeltaY: CGFloat { wheelDeltaY }
        override var timestamp: TimeInterval { eventTimestamp }
    }

    func testConsumeDirectScrollInputHandlesNonMouseAndRepeatedEvents() async throws {
        let fixture = try await makeFixture()
        let handle = TranscriptScrollHandle()
        handle.scroll = fixture.scroll

        let now = ProcessInfo.processInfo.systemUptime
        let kitDefined = try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: now,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            subtype: 23,
            data1: 0,
            data2: 0
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(kitDefined))

        let returnKeyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: now,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(returnKeyUp))

        let responder = FocusableView(frame: .zero)
        (fixture.scroll.documentView ?? fixture.scroll).addSubview(responder)
        XCTAssertTrue(fixture.window.makeFirstResponder(responder))
        let arrowDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: now,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        ))
        // `markConsumed: false` must not burn the event before an offset delta arrives.
        XCTAssertTrue(handle.consumeDirectScrollInput(arrowDown, markConsumed: false))
        XCTAssertTrue(handle.consumeDirectScrollInput(arrowDown))
        XCTAssertFalse(handle.consumeDirectScrollInput(arrowDown))

        let nonScrollKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: now + 0.005,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(nonScrollKey))

        let nextArrowDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: now + 0.01,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        ))
        XCTAssertTrue(handle.consumeDirectScrollInput(nextArrowDown))

        let outsideResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        // Add above the hosting view in its common superview; NSHostingView rejects direct subviews.
        let outsideParent = fixture.window.contentView?.superview ?? fixture.host.superview
        outsideParent?.addSubview(outsideResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(outsideResponder))
        let outsideArrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: now + 0.015,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(outsideArrow))

        let scroller = try XCTUnwrap(fixture.scroll.verticalScroller)
        scroller.isHidden = false
        scroller.alphaValue = 1
        let scrollerPoint = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: scrollerPoint,
            modifierFlags: [],
            timestamp: now + 0.02,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 7,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertTrue(handle.consumeDirectScrollInput(mouseDown))
        XCTAssertFalse(handle.consumeDirectScrollInput(mouseDown))

        // Dragging the scroller knob stays active even if the cursor drifts horizontally outside the track,
        // and clears once the primary mouse button is no longer pressed.
        let outsideTrackPoint = NSPoint(x: max(0, scrollerPoint.x - 40), y: scrollerPoint.y)
        let mouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: outsideTrackPoint,
            modifierFlags: [],
            timestamp: now + 0.03,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 8,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertTrue(handle.consumeDirectScrollInput(mouseDragged, isPrimaryButtonPressed: true))

        let releasedMouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: outsideTrackPoint,
            modifierFlags: [],
            timestamp: now + 0.035,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 9,
            clickCount: 1,
            pressure: 0
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(releasedMouseDragged, isPrimaryButtonPressed: false))

        // Confirm `isDraggingVerticalScroller` was cleared by the unpressed drag above.
        let postReleaseMouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: outsideTrackPoint,
            modifierFlags: [],
            timestamp: now + 0.038,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 10,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(postReleaseMouseDragged, isPrimaryButtonPressed: true))

        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: outsideTrackPoint,
            modifierFlags: [],
            timestamp: now + 0.04,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 9,
            clickCount: 1,
            pressure: 0
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(mouseUp))

        let nonScrollerMouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: outsideTrackPoint,
            modifierFlags: [],
            timestamp: now + 0.05,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 10,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertFalse(handle.consumeDirectScrollInput(nonScrollerMouseDown))
    }

    func testConsumeDirectScrollInputWheelAndNestedHorizontalScrollHitTest() {
        let window = makeWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 340))
        window.contentView = root

        // Offset `scroll` from `.zero` inside its superview so `scroll.hitTest` requires superview coordinates.
        let scroll = NSScrollView(frame: NSRect(x: 160, y: 40, width: 400, height: 260))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        let nestedScroll = NSScrollView(frame: NSRect(x: 20, y: 80, width: 320, height: 120))
        let nestedDoc = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 120))
        nestedScroll.documentView = nestedDoc
        document.addSubview(nestedScroll)
        scroll.documentView = document
        root.addSubview(scroll)

        let handle = TranscriptScrollHandle()
        handle.scroll = scroll
        let now = ProcessInfo.processInfo.systemUptime

        let insidePoint = scroll.convert(NSPoint(x: 10, y: 10), to: nil)
        let verticalWheel = SyntheticWheelEvent(window: window, location: insidePoint, deltaX: 0, deltaY: 12, timestamp: now)
        XCTAssertTrue(handle.consumeDirectScrollInput(verticalWheel))
        XCTAssertFalse(handle.consumeDirectScrollInput(verticalWheel))

        let zeroDeltaWheel = SyntheticWheelEvent(window: window, location: insidePoint, deltaX: 5, deltaY: 0, timestamp: now)
        XCTAssertFalse(handle.consumeDirectScrollInput(zeroDeltaWheel))

        let staleWheel = SyntheticWheelEvent(window: window, location: insidePoint, deltaX: 0, deltaY: 12, timestamp: now - 0.5)
        XCTAssertFalse(handle.consumeDirectScrollInput(staleWheel))

        let otherWindow = makeWindow()
        let wrongWindowWheel = SyntheticWheelEvent(window: otherWindow, location: insidePoint, deltaX: 0, deltaY: 12, timestamp: now)
        XCTAssertFalse(handle.consumeDirectScrollInput(wrongWindowWheel))

        let outsideWheel = SyntheticWheelEvent(window: window, location: NSPoint(x: 20, y: 20), deltaX: 0, deltaY: 12, timestamp: now)
        XCTAssertFalse(handle.consumeDirectScrollInput(outsideWheel))

        let nestedPoint = nestedScroll.convert(NSPoint(x: 40, y: 40), to: nil)
        let diagonalNestedWheel = SyntheticWheelEvent(window: window, location: nestedPoint, deltaX: 18, deltaY: 4, timestamp: now)
        XCTAssertFalse(handle.consumeDirectScrollInput(diagonalNestedWheel))
    }

    func testMarkAppKitLiveScrollGenerationAndResetLifecycle() async {
        let handle = TranscriptScrollHandle()
        handle.markAppKitLiveScroll()
        let sawBetweenGenerations = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    continuation.resume(returning: handle.consumeDirectScrollInput(nil))
                }
            }
            handle.markAppKitLiveScroll()
        }
        XCTAssertTrue(sawBetweenGenerations, "stale async reset must not clear a newer live scroll marker")

        handle.markAppKitLiveScroll()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(handle.consumeDirectScrollInput(nil))

        handle.isAppKitLiveScrolling = true
        XCTAssertTrue(handle.consumeDirectScrollInput(nil))
        handle.endLiveScrollTracking()
        XCTAssertFalse(handle.isAppKitLiveScrolling)
        XCTAssertFalse(handle.consumeDirectScrollInput(nil))
    }

    func testSwiftUITranscriptHostsUserMessageWithTopClearance() async throws {
        let user = TranscriptDisplayRow.item(.init(id: "user-0", kind: .user, text: "First prompt"))
        let reply = TranscriptDisplayRow.item(.init(id: "assistant-0", kind: .assistant, text: "Reply text"))
        let state = TranscriptScrollState()
        state.follow = false
        let host = NSHostingView(rootView: Harness(rows: [user, reply], state: state))
        let window = makeWindow()
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)

        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        XCTAssertGreaterThanOrEqual(scroll.contentInsets.top, NativeTranscript.topClearance)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, 80)
    }
}
