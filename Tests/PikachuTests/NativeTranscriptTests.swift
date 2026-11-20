import AppKit
import AgentRuntimeCore
import ImageIO
import OrchestrationCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Pikachu

@MainActor final class NativeTranscriptTests: XCTestCase {
    func testQueueFooterPrefersLatestQueuedSteerAndDisappearsWhenQueueClears() throws {
        let first = TranscriptItem(id: "first", kind: .user, delivery: .queued,
                                   submission: .init(text: "Earlier steer", mode: .steer))
        let steer = TranscriptItem(id: "steer", kind: .user, delivery: .queued,
                                   submission: .init(text: "Recent steer", mode: .steer))
        let followUp = TranscriptItem(id: "followUp", kind: .user, delivery: .queued,
                                      submission: .init(text: "Follow-up", mode: .followUp))
        let items = [first, steer, followUp]
        let queue = RuntimeQueue(steering: ["Earlier steer", "Recent steer"], followUp: ["Follow-up"])
        let footer = try XCTUnwrap(TranscriptQueueFooter.project(items, queue: queue, isKnown: true))
        XCTAssertEqual(footer.itemID, steer.id)
        XCTAssertEqual(footer.text, String(localized: "等待交付：补充 \(queue.steering.count) · 后续 \(queue.followUp.count)"))
        XCTAssertNil(TranscriptQueueFooter.project(items, queue: .init(), isKnown: true))

        first.delivery = .accepted
        steer.delivery = .accepted
        let remaining = RuntimeQueue(followUp: ["Follow-up"])
        XCTAssertEqual(TranscriptQueueFooter.project(items, queue: remaining, isKnown: true)?.itemID, followUp.id)
    }

    func testCopyConversationPreservesMessageOrderAndRawMarkdown() {
        let answer = "**结果**\n\n```swift\nlet answer = 42\n```"
        let items = [
            TranscriptItem(id: "prompt", kind: .user, text: "请给出示例"),
            TranscriptItem(id: "tool", kind: .tool, text: "不复制工具输出"),
            TranscriptItem(id: "reply", kind: .assistant, text: answer),
            TranscriptItem(id: "empty", kind: .assistant, streaming: true),
            TranscriptItem(id: "followup", kind: .user, text: "谢谢")
        ]
        let user = String(localized: "你")
        let assistant = String(localized: "助手")
        XCTAssertEqual(CopyConversationButton.markdown(for: items),
                       "## \(user)\n\n请给出示例\n\n## \(assistant)\n\n\(answer)\n\n## \(user)\n\n谢谢")
    }

    func testCopyConversationOccupiesTheLastTranscriptRow() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let table = try XCTUnwrap(coordinator.table)
        let first = TranscriptItem(id: "first", kind: .user, text: "问题")
        let reply = TranscriptItem(id: "reply", kind: .assistant, text: "回答")

        for items in [[first], [first, reply]] {
            coordinator.update(TranscriptDisplayRow.project(items), follow: .constant(true), copyableConversation: items)
            await settleLayout(scroll)
            XCTAssertEqual(table.numberOfRows, items.count + 1)
            let footer = try XCTUnwrap(table.view(atColumn: 0, row: items.count, makeIfNecessary: true) as? NativeTranscript.HostCell)
            XCTAssertEqual(footer.representedID, "transcript:copy-conversation")
            XCTAssertGreaterThan(table.rect(ofRow: items.count).minY, table.rect(ofRow: items.count - 1).minY)
        }

        coordinator.update(TranscriptDisplayRow.project([first, reply]), follow: .constant(true))
        XCTAssertEqual(table.numberOfRows, 2)
    }

    func testMouseWheelOverCodeBlockScrollsTranscript() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        let scroll = fixture.scroll
        let point = fixture.codePoint

        let initialOffset = scroll.contentView.bounds.minY
        let down = try wheelEvent(vertical: -3)
        XCTAssertTrue(scroll.routeScrollEvent(down, at: point))
        await settleLayout(scroll)
        let lowerOffset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(lowerOffset, initialOffset)

        let up = try wheelEvent(vertical: 3)
        XCTAssertTrue(scroll.routeScrollEvent(up, at: point))
        await settleLayout(scroll)
        XCTAssertLessThan(scroll.contentView.bounds.minY, lowerOffset)

        let right = try wheelEvent(vertical: 0, horizontal: -3)
        XCTAssertFalse(scroll.routeScrollEvent(right, at: point))
        XCTAssertFalse(scroll.routeScrollEvent(down, at: NSPoint(x: -10, y: -10)))
    }

    func testVerticalTrackpadGestureOverCodeBlockScrollsTranscript() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        let scroll = fixture.scroll
        let initialOffset = scroll.contentView.bounds.minY

        // AppKit delivers the gesture to the scroll view under the initial pointer.
        func send(_ event: NSEvent, at point: NSPoint) {
            if !scroll.routeScrollEvent(event, at: point) {
                fixture.codeScroll.scrollWheel(with: event)
            }
        }

        send(try wheelEvent(vertical: 0, phase: .began), at: fixture.codePoint)
        send(try wheelEvent(vertical: -20, horizontal: 1, phase: .changed), at: fixture.codePoint)
        send(try wheelEvent(vertical: -8, horizontal: 16, phase: .changed), at: fixture.codePoint)
        send(try wheelEvent(vertical: 0, phase: .ended), at: fixture.codePoint)
        let afterGesture = scroll.contentView.bounds.minY
        XCTAssertEqual(afterGesture, initialOffset + 28, accuracy: 1)
        XCTAssertEqual(fixture.codeScroll.contentView.bounds.minX, 0, accuracy: 1)

        let outside = NSPoint(x: -10, y: -10)
        let continuingMomentum = try XCTUnwrap(CGMomentumScrollPhase(rawValue: 2))
        send(try wheelEvent(vertical: -12, momentum: .begin), at: outside)
        send(try wheelEvent(vertical: -7, momentum: continuingMomentum), at: outside)
        send(try wheelEvent(vertical: 0, momentum: .end), at: outside)
        XCTAssertEqual(scroll.contentView.bounds.minY, afterGesture + 19, accuracy: 1)

        send(try wheelEvent(vertical: 16, phase: .began), at: fixture.codePoint)
        send(try wheelEvent(vertical: 7, phase: .changed), at: fixture.codePoint)
        send(try wheelEvent(vertical: 0, phase: .ended), at: fixture.codePoint)
        XCTAssertEqual(scroll.contentView.bounds.minY, afterGesture - 4, accuracy: 1)
    }

    func testVerticalTrackpadGestureOverCodeBlockScrollerScrollsTranscript() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        fixture.codeScroll.scrollerStyle = .legacy
        fixture.codeScroll.autohidesScrollers = false
        await settleLayout(fixture.scroll)

        let scroller = try XCTUnwrap(fixture.codeScroll.horizontalScroller)
        let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        let hitPoint = fixture.scroll.superview?.convert(point, from: nil) ?? point
        XCTAssertTrue(fixture.scroll.hitTest(hitPoint) === scroller)

        let initialY = fixture.scroll.contentView.bounds.minY
        let initialX = fixture.codeScroll.contentView.bounds.minX
        XCTAssertTrue(fixture.scroll.routeScrollEvent(try wheelEvent(vertical: -24, phase: .began), at: point))
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, initialY + 24, accuracy: 1)
        XCTAssertEqual(fixture.codeScroll.contentView.bounds.minX, initialX, accuracy: 1)
    }

    func testHorizontalTrackpadGestureOverCodeBlockKeepsNativeScrolling() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        let transcriptOffset = fixture.scroll.contentView.bounds.minY
        let events = try [
            wheelEvent(vertical: 0, phase: .mayBegin),
            wheelEvent(vertical: 0, horizontal: -26, phase: .began),
            wheelEvent(vertical: 0, horizontal: -26, phase: .changed),
            wheelEvent(vertical: -20, horizontal: -7, phase: .changed),
            wheelEvent(vertical: 0, phase: .ended),
            wheelEvent(vertical: -8, horizontal: -4, momentum: .begin),
            wheelEvent(vertical: 0, momentum: .end)
        ]
        for event in events {
            XCTAssertFalse(fixture.scroll.routeScrollEvent(event, at: fixture.codePoint))
            fixture.codeScroll.scrollWheel(with: event)
            try await Task.sleep(for: .milliseconds(35))
        }
        XCTAssertGreaterThan(fixture.codeScroll.contentView.bounds.minX, 0)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, transcriptOffset, accuracy: 1)
    }

    func testVerticalTrackpadGestureSurvivesSmallHorizontalStart() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        let initialY = fixture.scroll.contentView.bounds.minY
        let initialX = fixture.codeScroll.contentView.bounds.minX

        try await fixture.replay([
            wheelEvent(vertical: 0, phase: .mayBegin),
            wheelEvent(vertical: 0, phase: .began),
            wheelEvent(vertical: 0, horizontal: -1, phase: .changed),
            wheelEvent(vertical: -24, phase: .changed),
            wheelEvent(vertical: -24, phase: .changed),
            wheelEvent(vertical: -24, phase: .changed),
            wheelEvent(vertical: 0, phase: .ended)
        ])

        XCTAssertGreaterThan(fixture.scroll.contentView.bounds.minY - initialY, 48)
        XCTAssertEqual(fixture.codeScroll.contentView.bounds.minX, initialX, accuracy: 1)
    }

    func testHorizontalTrackpadGestureSurvivesSmallVerticalStart() async throws {
        for jitterPhase in [CGScrollPhase.began, .changed] {
            let fixture = try await makeCodeBlockFixture()
            defer { fixture.window.contentView = nil }
            let initialY = fixture.scroll.contentView.bounds.minY
            let initialX = fixture.codeScroll.contentView.bounds.minX
            var events = try [wheelEvent(vertical: 0, phase: .mayBegin)]
            if jitterPhase == .changed {
                events.append(try wheelEvent(vertical: 0, phase: .began))
            }
            events.append(try wheelEvent(vertical: -1, phase: jitterPhase))
            if jitterPhase == .began {
                events.append(try wheelEvent(vertical: 0, horizontal: -3, phase: .changed))
                events.append(try wheelEvent(vertical: -3, horizontal: -2, phase: .changed))
            }
            let finish: CGScrollPhase = jitterPhase == .began ? .cancelled : .ended
            events.append(contentsOf: try [
                wheelEvent(vertical: 0, horizontal: -24, phase: .changed),
                wheelEvent(vertical: 0, horizontal: -24, phase: .changed),
                wheelEvent(vertical: 0, horizontal: -24, phase: .changed),
                wheelEvent(vertical: 0, phase: finish)
            ])

            try await fixture.replay(events)
            XCTAssertGreaterThan(fixture.codeScroll.contentView.bounds.minX - initialX, 48, "Jitter during \(jitterPhase)")

            let outside = NSPoint(x: -10, y: -10)
            let momentum = try wheelEvent(vertical: -8, horizontal: -12, momentum: .begin)
            if finish == .ended {
                XCTAssertTrue(fixture.scroll.routeScrollEvent(momentum, at: outside))
                let momentumEnd = try wheelEvent(vertical: 0, momentum: .end)
                XCTAssertTrue(fixture.scroll.routeScrollEvent(momentumEnd, at: outside))
            }
            XCTAssertFalse(fixture.scroll.routeScrollEvent(momentum, at: outside))
            XCTAssertEqual(fixture.scroll.contentView.bounds.minY, initialY, accuracy: 0.01)
        }
    }

    func testSlowVerticalTrackpadMovementAccumulatesAndResetsBetweenGestures() async throws {
        let fixture = try await makeCodeBlockFixture()
        defer { fixture.window.contentView = nil }
        let scroll = fixture.scroll
        let initialY = scroll.contentView.bounds.minY
        let start = try wheelEvent(vertical: 0, phase: .began)
        let step = try wheelEvent(vertical: -1, phase: .changed)
        let cancel = try wheelEvent(vertical: 0, phase: .cancelled)
        let momentum = try wheelEvent(vertical: -12, momentum: .begin)

        XCTAssertTrue(scroll.routeScrollEvent(start, at: fixture.codePoint))
        XCTAssertTrue(scroll.routeScrollEvent(step, at: fixture.codePoint))
        XCTAssertFalse(scroll.routeScrollEvent(cancel, at: fixture.codePoint))
        XCTAssertFalse(scroll.routeScrollEvent(momentum, at: fixture.codePoint))

        XCTAssertTrue(scroll.routeScrollEvent(start, at: fixture.codePoint))
        for _ in 0..<3 {
            XCTAssertTrue(scroll.routeScrollEvent(step, at: fixture.codePoint))
        }
        XCTAssertEqual(scroll.contentView.bounds.minY, initialY, accuracy: 0.01)
        XCTAssertTrue(scroll.routeScrollEvent(step, at: fixture.codePoint))
        XCTAssertEqual(scroll.contentView.bounds.minY, initialY + 4, accuracy: 0.01)

        fixture.window.contentView = nil
        XCTAssertFalse(scroll.routeScrollEvent(momentum, at: fixture.codePoint))
        XCTAssertEqual(scroll.contentView.bounds.minY, initialY + 4, accuracy: 0.01)
    }

    func testTrackpadGesturesOverExpandedToolOutput() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 580, height: 900))
        scroll.documentView = document
        let output = String(repeating: "long tool output ", count: 40)
        let tool = TranscriptItem(id: "tool", kind: .tool, tool: .init(id: "tool", name: "sample", output: output))
        let host = NSHostingView(rootView: ToolRow(item: tool, expanded: .constant(true))
            .disclosureGroupStyle(FlatDisclosureStyle()))
        host.frame = NSRect(x: 20, y: 250, width: 540, height: 140)
        document.addSubview(host)
        await settleLayout(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        await settleLayout(scroll)
        let outputScroll = try XCTUnwrap(horizontalScroll(in: host))
        let outputClip = outputScroll.contentView
        let point = outputClip.convert(NSPoint(x: 20, y: outputClip.bounds.midY), to: nil)

        let horizontalEvents = try [
            wheelEvent(vertical: 0, phase: .mayBegin),
            wheelEvent(vertical: 0, horizontal: -24, phase: .began),
            wheelEvent(vertical: 0, horizontal: -18, phase: .changed),
            wheelEvent(vertical: 0, phase: .ended)
        ]
        for event in horizontalEvents {
            XCTAssertFalse(scroll.routeScrollEvent(event, at: point))
            outputScroll.scrollWheel(with: event)
            try await Task.sleep(for: .milliseconds(35))
        }
        XCTAssertGreaterThan(outputClip.bounds.minX, 0)

        let initialOffset = scroll.contentView.bounds.minY
        XCTAssertTrue(scroll.routeScrollEvent(try wheelEvent(vertical: -24, phase: .began), at: point))
        XCTAssertFalse(scroll.routeScrollEvent(try wheelEvent(vertical: 0, phase: .ended), at: point))
        XCTAssertEqual(scroll.contentView.bounds.minY, initialOffset + 24, accuracy: 1)
        withExtendedLifetime(coordinator) {}
    }

    func testToolOutputAppearsOnlyAfterOpeningGroupAndItem() async throws {
        let output = String(repeating: "long tool output ", count: 40)
        let first = TranscriptItem(id: "first", kind: .tool, tool: .init(id: "first", name: "read", output: output, state: .completed))
        let second = TranscriptItem(id: "second", kind: .tool, tool: .init(id: "second", name: "bash", state: .completed))
        let items = [first, second]
        let expansion = ToolCallExpansion()
        let host = NSHostingView(rootView: ToolCallsRow(items: items, expansion: expansion, contentChanged: {})
            .disclosureGroupStyle(FlatDisclosureStyle()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settleLayout(host)
        XCTAssertNil(horizontalScroll(in: host))

        let group = expansion.groupBinding(for: items)
        group.wrappedValue = true
        await settleLayout(host)
        XCTAssertNil(horizontalScroll(in: host))

        expansion.detailBinding(for: first, isSingle: false).wrappedValue = true
        await settleLayout(host)
        XCTAssertNotNil(horizontalScroll(in: host))
        group.wrappedValue = false
        await settleLayout(host)
        XCTAssertNil(horizontalScroll(in: host))
    }

    func testTranscriptRegroupsWhenRunningToolsFinishWithoutReplacingItems() async throws {
        let turn = TurnRecord(startedAt: .now)
        let first = TranscriptItem(id: "first", kind: .tool, tool: .init(id: "first", name: "read", state: .completed), turn: turn)
        let running = TranscriptItem(id: "running", kind: .tool, tool: .init(id: "running", name: "bash"), turn: turn)
        let parallel = TranscriptItem(id: "parallel", kind: .tool, tool: .init(id: "parallel", name: "grep"), turn: turn)
        let generating = TranscriptItem(id: "reply", kind: .assistant, streaming: true, turn: turn)
        let items = [first, running, parallel, generating]
        let host = NSHostingView(rootView: TranscriptView(items: items, isExecuting: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settleLayout(host)

        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        let table = try XCTUnwrap(findTable(in: host))
        XCTAssertEqual(table.numberOfRows, 4, "No placeholder row before the streaming reply has text")
        XCTAssertEqual(table.intercellSpacing.height, 4)
        for row in 0..<table.numberOfRows {
            XCTAssertLessThanOrEqual(table.rect(ofRow: row).height, 34, "Compact row \(row)")
        }

        running.tool?.output = String(repeating: "partial output ", count: 40)
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertNil(horizontalScroll(in: table))

        running.tool?.state = .completed
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 3)
        parallel.tool?.state = .interrupted
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertLessThanOrEqual(table.rect(ofRow: 1).height, 34, "Collapsed group stays compact")
        XCTAssertNil(horizontalScroll(in: table), "The merged group's details are collapsed by default")

        generating.append(index: 0, delta: "\n ")
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        generating.append(index: 0, delta: "Reply")
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 3, "First visible text inserts only the reply row while execution is active")

        host.rootView = TranscriptView(items: items, isExecuting: false)
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 4, "The copy footer becomes available after execution finishes")

        host.rootView = TranscriptView(items: items, isExecuting: true)
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 3, "Starting another execution removes the copy footer")
    }

    func testTranscriptDrawsImageThumbnailsForLiveAndRestoredAttachments() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prompt = UserPrompt(text: "Screenshot", files: [file, file.deletingPathExtension().appendingPathExtension("txt")])
        let live = SessionController()
        await live.connect(FakeRuntime())
        await live.sendDraft(prompt)
        let liveItem = try XCTUnwrap(live.transcript.first)
        _ = await live.disconnect()

        let restored = SessionController()
        restored.showHistory([.init(id: "history:user", kind: .user, text: prompt.runtimeText, messageTimestampMs: 1_795_000_000_000)],
                             recordedMessages: [.init(id: prompt.id, text: prompt.text, files: prompt.files,
                                                      messageTimestampMs: 1_795_000_000_000)])
        let restoredItem = try XCTUnwrap(restored.transcript.first)
        XCTAssertEqual(restoredItem.attachedFiles, prompt.files)
        let host = NSHostingView(rootView: TranscriptView(items: [liveItem]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        func showsImagePixels() -> Bool {
            guard let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: snapshot)
            guard let data = snapshot.representation(using: .png, properties: [:]),
                  let bitmap = NSBitmapImageRep(data: data) else { return false }
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                       color.redComponent - color.greenComponent > 0.45,
                       color.blueComponent - color.greenComponent > 0.45 { return true }
                }
            }
            return false
        }

        for item in [liveItem, restoredItem] {
            host.rootView = TranscriptView(items: [item])
            var rendered = false
            for _ in 0..<30 {
                await settleLayout(host)
                if showsImagePixels() { rendered = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if !rendered, let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: snapshot)
                if let data = snapshot.representation(using: .png, properties: [:]) {
                    add(XCTAttachment(data: data, uniformTypeIdentifier: UTType.png.identifier))
                }
            }
            XCTAssertTrue(rendered, "Expected actual image pixels for \(item.id), not only an attachment label")
        }
    }

    @MainActor private struct CodeBlockFixture {
        let window: NSWindow
        let coordinator: NativeTranscript.Coordinator
        let scroll: NativeTranscript.TranscriptScroll
        let codeScroll: NSScrollView

        var codePoint: NSPoint {
            let clip = codeScroll.contentView
            return clip.convert(NSPoint(x: clip.bounds.minX + 20, y: clip.bounds.midY), to: nil)
        }

        @MainActor func replay(_ events: [NSEvent]) async throws {
            for event in events {
                if !scroll.routeScrollEvent(event, at: codePoint) {
                    codeScroll.scrollWheel(with: event)
                }
                try await Task.sleep(for: .milliseconds(35))
            }
        }
    }

    private func makeCodeBlockFixture() async throws -> CodeBlockFixture {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll

        var rows = messages
        let codeRow = 1
        let code = String(repeating: "let value = 123; ", count: 30)
        rows[codeRow] = .item(.init(id: "code", kind: .assistant, text: "```swift\n\(code)\n```"))
        coordinator.update(rows, follow: .constant(false))
        await settleLayout(scroll)

        let table = try XCTUnwrap(coordinator.table)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: codeRow).minY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(300))
        await settleLayout(scroll)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: codeRow, makeIfNecessary: false))
        let codeScroll = try XCTUnwrap(horizontalScroll(in: cell))
        return .init(window: window, coordinator: coordinator, scroll: scroll, codeScroll: codeScroll)
    }

    func testHeightChangesKeepFollowingOrPreservePausedReading() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.frame.size = .init(width: 600, height: 340)
        let rows = messages
        coordinator.update(rows, follow: .constant(true))
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.maxY, table.rect(ofRow: rows.count - 1).maxY, accuracy: 1)

        scroll.frame.size.height = 210
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.height, 210, accuracy: 1)
        XCTAssertEqual(table.visibleRect.maxY, table.rect(ofRow: rows.count - 1).maxY, accuracy: 1)

        coordinator.update(rows, follow: .constant(false))
        let readingStart = table.rect(ofRow: 3).minY + 8
        scroll.contentView.scroll(to: .init(x: 0, y: readingStart))
        await settleLayout(scroll)
        scroll.frame.size.height = 280
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.minY, readingStart, accuracy: 1)
    }

    func testGroupingKeepsFormerToolAtGroupHeader() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.frame.size = .init(width: 600, height: 200)
        let heights = ToolDetailHeights()
        table.delegate = heights

        let first = TranscriptItem(id: "first", kind: .tool, tool: .init(id: "first", name: "read", state: .completed))
        let running = TranscriptItem(id: "running", kind: .tool, tool: .init(id: "running", name: "read", state: .running))
        let rest = (0..<40).map { TranscriptItem(id: "message-\($0)", kind: .assistant, text: "Message \($0)") }
        let items = [rest[0], first, running] + Array(rest.dropFirst())
        coordinator.update(TranscriptDisplayRow.project(items), follow: .constant(false))
        await settleLayout(scroll)
        scroll.contentView.scroll(to: .init(x: 0, y: table.rect(ofRow: 2).minY + 230))

        running.tool?.state = .completed
        heights.grouped = true
        coordinator.update(TranscriptDisplayRow.project(items), follow: .constant(false))
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.minY, table.rect(ofRow: 1).minY, accuracy: 1)
    }

    func testMessageJumpKeepsTopClearanceAndLatestClearsComposer() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.frame.size = .init(width: 600, height: 340)
        var rows = messages
        rows[6] = .item(.init(id: "prompt", kind: .user, text: "Locate this message"))
        coordinator.update(rows, follow: .constant(false))
        await settleLayout(scroll)

        let jump = NativeTranscript.Jump(messageID: "prompt")
        coordinator.updateViewport(composerClearance: 108, jump: jump)
        await settleLayout(scroll)
        XCTAssertEqual(scroll.contentInsets.top, NativeTranscript.topClearance, accuracy: 1)
        XCTAssertEqual(table.rect(ofRow: 6).minY - scroll.contentView.bounds.minY,
                       NativeTranscript.topClearance, accuracy: 1)

        coordinator.scrollByUser(-120)
        let readingStart = scroll.contentView.bounds.minY
        coordinator.updateViewport(composerClearance: 108, jump: jump)
        XCTAssertEqual(scroll.contentView.bounds.minY, readingStart, accuracy: 1)

        coordinator.update(rows, follow: .constant(true))
        await settleLayout(scroll)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY - table.rect(ofRow: rows.count - 1).maxY, 115)
    }

    func testReadingColumnReflowsVisibleRowsAndKeepsLatestAboveComposer() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let last = messages.count - 1
        var rows = messages
        rows[last] = .item(.init(id: "wrapped", kind: .assistant,
                                text: String(repeating: "这是一段用于验证窗口缩放后重新折行的正文。", count: 10)))
        scroll.frame.size = .init(width: 1280, height: 520)
        coordinator.update(rows, follow: .constant(true))
        coordinator.updateViewport(composerClearance: 124, jump: nil)

        var tallHeight: CGFloat = 0
        for (width, column): (CGFloat, CGFloat) in [(1280, 800), (1024, 800), (480, 432), (1280, 800)] {
            scroll.frame.size.width = width
            await settleLayout(scroll)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: last, makeIfNecessary: false) as? NativeTranscript.HostCell)
            let hosted = try XCTUnwrap(cell.subviews.first)
            XCTAssertEqual(hosted.frame.width, column, accuracy: 1)
            XCTAssertEqual(cell.convert(hosted.frame, to: scroll).midX, width / 2, accuracy: 1)
            let rect = table.rect(ofRow: last)
            if tallHeight == 0 { tallHeight = rect.height }
            if width == 480 { XCTAssertGreaterThan(rect.height, tallHeight + 20) }
            else { XCTAssertEqual(rect.height, tallHeight, accuracy: 1) }
            XCTAssertEqual(scroll.contentView.bounds.maxY - rect.maxY, 132, accuracy: 1)
        }
    }

    func testScrollbarThumbUsesNeutralTonesWithDistinctContrastInBothAppearances() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var values: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                for (active, increasedContrast) in [(false, false), (true, false), (false, true)] {
                    guard let color = PikachuTheme.scrollbarThumbColor(active: active, increasedContrast: increasedContrast)
                        .usingColorSpace(.sRGB) else { return XCTFail("Expected an sRGB scrollbar color") }
                    XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.001)
                    XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.001)
                    values.append(color.redComponent)
                }
            }
            let sorted = name == .aqua ? values.sorted(by: >) : values.sorted()
            XCTAssertEqual(values, sorted)
            XCTAssertEqual(Set(values).count, 3)
        }
    }

    func testOffscreenSummaryUsesCurrentRowSize() {
        let cell = NativeTranscript.SummaryCell()

        cell.setFrameSize(.init(width: 600, height: 54))
        XCTAssertEqual(cell.label.frame, NSRect(x: 24, y: 3, width: 552, height: 48))

        cell.setFrameSize(.init(width: 320, height: 170))
        XCTAssertEqual(cell.label.frame, NSRect(x: 24, y: 3, width: 272, height: 164))

        cell.setFrameSize(.init(width: 1280, height: 54))
        XCTAssertEqual(cell.label.frame, NSRect(x: 240, y: 3, width: 800, height: 48))
    }

    func testReloadDoesNotTrapIfDisplayIDsRepeat() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.frame.size = .init(width: 600, height: 200)

        let first = TranscriptItem(id: "repeated", kind: .assistant, text: "First")
        let second = TranscriptItem(id: "repeated", kind: .assistant, text: "Second")
        coordinator.update([.item(first), .item(second)], follow: .constant(false))
        let refreshed = TranscriptItem(id: "repeated", kind: .assistant, text: "Second, refreshed")
        coordinator.update([.item(first), .item(refreshed)], follow: .constant(false))
        await settleLayout(scroll)
        XCTAssertEqual(table.numberOfRows, 2)
    }

    private var messages: [TranscriptDisplayRow] {
        (0..<40).map { .item(.init(id: "message-\($0)", kind: .assistant, text: "Message \($0)")) }
    }

    private func horizontalScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller { return scroll }
        return view.subviews.lazy.compactMap { self.horizontalScroll(in: $0) }.first
    }

    private func wheelEvent(vertical: Int32, horizontal: Int32 = 0, phase: CGScrollPhase? = nil,
                            momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let units: CGScrollEventUnit = phase == nil && momentum == .none ? .line : .pixel
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                         wheel1: vertical, wheel2: horizontal, wheel3: 0))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func settleLayout(_ view: NSView) async {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class ToolDetailHeights: NSObject, NSTableViewDelegate {
    var grouped = false

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if !grouped && row == 2 { return 350 }
        return 64
    }
}
