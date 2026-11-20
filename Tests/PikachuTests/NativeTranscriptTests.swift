import AppKit
import AgentRuntimeCore
import ImageIO
import OrchestrationCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Pikachu

@MainActor final class NativeTranscriptTests: XCTestCase {
    func testMarkdownTableCodeBackgroundFollowsChineseTextWrapping() throws {
        let width: CGFloat = 105
        let padding: CGFloat = 2
        let source = """
            | H |
            | --- |
            | 这是一段文本`X123`后面跟着文字 |
            """
        let view = MarkdownContent(text: source, streaming: false, width: width)
            .pikachuTypography(.standard)
            .padding(padding)
            .background(.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(width: width + 2 * padding, height: nil)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

        func backgroundPixels(at x: CGFloat) -> Int {
            let pixel = Int(x * renderer.scale)
            return (0..<bitmap.pixelsHigh).count { y in
                guard let color = bitmap.colorAt(x: pixel, y: y)?.usingColorSpace(.sRGB) else { return false }
                return (0.89...0.94).contains(color.redComponent)
                    && abs(color.redComponent - color.greenComponent) < 0.01
                    && abs(color.redComponent - color.blueComponent) < 0.01
            }
        }

        let typography = PikachuTypography()
        let font = NSFont.monospacedSystemFont(ofSize: typography.pointSize(for: .callout), weight: .regular)
        let codeWidth = ("X123" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(backgroundPixels(at: padding + 2), 8, "The background starts behind the first code glyph.")
        XCTAssertLessThan(backgroundPixels(at: padding + codeWidth + 4), 8, "The background ends before the following Chinese text.")
    }

    func testMarkdownReferenceTablesWrapInNativeTranscript() async throws {
        let references = [
            """
            ## 四种交接方式

            | 方式 | 适合 | 操作 | 注意 |
            | --- | --- | --- | --- |
            | **A. 新顶层 thread + worktree** | 让另一个 agent 独立接手整个项目（推荐） | `t3_thread_launch`，`workspaceStrategy:` `worktree`，message 指向 handoff | 新分支，互不干扰；需要完整 brief |
            | **B. 子 agent** | 在当前 thread 里派一个 agent 做具体任务 | `delegate_task`，`role:` `implementation`，`isolation: shared` 或 `worktree` | 子 agent 没有父历史，brief 必须自包含 |
            | **C. 当前 thread 移到 worktree** | 保留这段对话，但换到新分支继续 | `t3_worktree_handoff`，branch + continuationPrompt | 当前会话结束，下一轮在新 worktree 继续 |
            | **D. 已有 thread** | 你已经有另一个 agent/thread | `t3_thread_send`，把 handoff 文档内容发过去 | 不会自动带历史；先让它读 handoff |
            """,
            """
            | 类别 | 建议尺寸 | Pikachu 里的用法 |
            | --- | ---: | --- |
            | 展开指示 | 固定 8 pt | 侧栏「已处理」、文件夹、工具调用、用量明细、设置下拉。单箭头用整行点击，双箭头用 26 × 26 pt 按钮。 |
            | 行内辅助 | 默认 11.5 pt，随 `caption` 缩放 | 文件状态、选中勾、时钟、附件标记，以及嵌在消息或标签里的复制、编辑、移除。 |
            | 独立操作 | 默认 13 pt，随 `callout` 缩放 | 搜索、筛选、新建、刷新、更多、面板关闭。普通按钮用 26 × 26 pt；发送和停止用 28 / 30 / 32 pt 的按钮档位体现主操作层级。 |
            | 空状态主图标 | 默认 18 pt，随 `title2` 缩放 | 无项目、新会话、启动失败。沿用 42 × 42 pt 底框。 |
            | 品牌与状态 | 按用途固定 | 服务商 Logo 用 13 × 13 pt 框，按可见轮廓校准透明留白，保留原始比例。Pikachu 品牌标记用 16 × 16 pt。状态点和加载环沿用各自的尺寸。 |
            """
        ]
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let view = try XCTUnwrap(coordinator.table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 848, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(PikachuTheme.workspace)
        window.contentView = scroll
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for (index, markdown) in references.enumerated() {
            let parsed = MarkdownBlocks.parse(markdown).compactMap { block -> MarkdownTable? in
                if case .table(let table) = block.kind { return table }
                return nil
            }
            let markdownTable = try XCTUnwrap(parsed.first)
            let item = TranscriptItem(id: "markdown-reference-\(index)", kind: .assistant, text: markdown)
            var wideHeight: CGFloat = 0

            for (width, appearance, size) in [(800.0, NSAppearance.Name.aqua, InterfaceFontSize.standard),
                                               (480.0, .aqua, .standard), (480.0, .darkAqua, .extraLarge)] {
                window.setContentSize(.init(width: width + 2 * WorkbenchReadingColumn.minimumGutter, height: 620))
                window.appearance = NSAppearance(named: appearance)
                coordinator.update([.item(item)], follow: .constant(false), fontSize: size)
                await settleLayout(scroll)
                for _ in 0..<12 where view.rect(ofRow: 0).height <= 120 {
                    try await Task.sleep(for: .milliseconds(25))
                    await settleLayout(scroll)
                }

                let typography = PikachuTypography(size: size)
                let layout = MarkdownTableLayout(naturalWidths: MarkdownTableLayout.naturalWidths(of: markdownTable, typography: typography),
                                                 bodySize: typography.pointSize(for: .body), availableWidth: width)
                let widestColumn = index == 0 ? 2 : markdownTable.columns.count - 1
                XCTAssertEqual(layout.columnWidths.max(), layout.columnWidths[widestColumn])
                if index == 1 {
                    XCTAssertEqual(markdownTable.columns[1].alignment, .right)
                }
                let rowView = try XCTUnwrap(view.view(atColumn: 0, row: 0, makeIfNecessary: false))
                XCTAssertNil(horizontalScroll(in: rowView))
                let height = view.rect(ofRow: 0).height
                XCTAssertGreaterThan(height, 120)
                if width == 800 {
                    wideHeight = height
                } else {
                    XCTAssertGreaterThan(height, wideHeight)
                }
                let cropHeight = min(scroll.bounds.height, ceil(height + 12))
                let crop = NSRect(x: 0, y: scroll.isFlipped ? 0 : scroll.bounds.height - cropHeight,
                                  width: scroll.bounds.width, height: cropHeight)
                try attachScreenshot(scroll, name: "markdown-table-\(index + 1)-\(Int(width))-\(size.rawValue)", bounds: crop)
            }
        }
    }

    func testMarkdownTableOverflowKeepsVerticalScrollingAndResizeKeepsReadingPosition() async throws {
        let headers = (1...7).map { "Header \($0) with long identifier" }
        let values = (1...7).map { "`path/\(String(repeating: "filename", count: 5))/\($0)`" }
        let markdown = [headers, Array(repeating: "---", count: headers.count), values]
            .map { "| " + $0.joined(separator: " | ") + " |" }
            .joined(separator: "\n")
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(coordinator.table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 528, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(PikachuTheme.workspace)
        window.contentView = scroll
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let index = 1
        var rows = messages
        rows[index] = .item(.init(id: "wide-markdown", kind: .assistant, text: markdown))
        coordinator.update(rows, follow: .constant(false))
        await settleLayout(scroll)
        for _ in 0..<12 where table.rect(ofRow: index).height <= 120 {
            try await Task.sleep(for: .milliseconds(25))
            await settleLayout(scroll)
        }
        XCTAssertGreaterThan(table.rect(ofRow: index).height, 120)
        scroll.contentView.scroll(to: .init(x: 0, y: max(0, table.rect(ofRow: index).minY - 12)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleLayout(scroll)

        let message = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: false))
        let innerScroll = try XCTUnwrap(horizontalScroll(in: message))
        let rightEdge = try XCTUnwrap(innerScroll.documentView).bounds.maxX
        XCTAssertGreaterThan(rightEdge, innerScroll.documentVisibleRect.width)
        innerScroll.contentView.scroll(to: .init(x: rightEdge - innerScroll.documentVisibleRect.width, y: 0))
        innerScroll.reflectScrolledClipView(innerScroll.contentView)
        XCTAssertEqual(innerScroll.documentVisibleRect.maxX, rightEdge, accuracy: 1)
        try attachScreenshot(scroll, name: "markdown-table-overflow-right-edge")

        let point = innerScroll.convert(NSPoint(x: 40, y: innerScroll.bounds.midY), to: nil)
        let initialY = scroll.contentView.bounds.minY
        XCTAssertTrue(scroll.routeScrollEvent(try wheelEvent(vertical: -3), at: point))
        await settleLayout(scroll)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialY)
        XCTAssertEqual(innerScroll.documentVisibleRect.maxX, rightEdge, accuracy: 1)

        let narrowHeight = table.rect(ofRow: index).height
        let readingOffset: CGFloat = 12
        scroll.contentView.scroll(to: .init(x: 0, y: table.rect(ofRow: index).minY + readingOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleLayout(scroll)
        window.setContentSize(.init(width: 848, height: 340))
        await settleLayout(scroll)
        XCTAssertLessThan(table.rect(ofRow: index).height, narrowHeight)
        let resized = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: false))
        XCTAssertNil(horizontalScroll(in: resized))
        XCTAssertEqual(scroll.contentView.bounds.minY, table.rect(ofRow: index).minY + readingOffset, accuracy: 1)
    }

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

    func testReplyFootersCopyOnlyTheirTurnAndKeepRawMarkdown() throws {
        let end = Date(timeIntervalSince1970: 1_750_000_000)
        let first = TurnRecord(status: .completed, endedAt: end)
        let second = TurnRecord(status: .completed, endedAt: end.addingTimeInterval(10))
        let running = TurnRecord(status: .running)
        let answer = "**结果**\n\n```swift\nlet answer = 42\n```"
        let items = [
            TranscriptItem(id: "prompt", kind: .user, text: "请给出示例", turn: first),
            TranscriptItem(id: "intro", kind: .assistant, text: "先看示例", turn: first),
            TranscriptItem(id: "tool", kind: .tool, text: "不复制工具输出", turn: first),
            TranscriptItem(id: "reply", kind: .assistant, text: answer, turn: first),
            TranscriptItem(id: "tail-tool", kind: .tool, text: "也不复制", turn: first),
            TranscriptItem(id: "empty", kind: .assistant, text: " \n", turn: first),
            TranscriptItem(id: "followup", kind: .user, text: "谢谢", turn: second),
            TranscriptItem(id: "second-reply", kind: .assistant, text: "不客气", turn: second),
            TranscriptItem(id: "running-reply", kind: .assistant, text: "生成中", streaming: true, turn: running)
        ]
        let footers = TranscriptReplyFooter.project(TranscriptDisplayRow.project(items))
        XCTAssertEqual(Set(footers.keys), ["reply", "second-reply"])
        let reply = try XCTUnwrap(footers["reply"])
        XCTAssertEqual(reply.markdown, "先看示例\n\n\(answer)")
        XCTAssertEqual(reply.endedAt, first.endedAt)
        XCTAssertEqual(footers["second-reply"]?.markdown, "不客气")
        XCTAssertEqual(footers["second-reply"]?.endedAt, second.endedAt)
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

    func testToolCopyPreservesExactCommandAndRetainedOutput() throws {
        let output = "  first line\r\n\r\n第二行\t \n"
        let command = "printf '%s\\n' 'first'\nprintf '%s\\n' 'second'\n"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let samples: [(String, ToolTextCopyButton.Kind)] = [(command, .command), (output, .output)]
        for (text, kind) in samples {
            ToolTextCopyButton(text: text, kind: kind).copy(to: pasteboard)
            let copied = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertEqual(Array(copied.utf8), Array(text.utf8))
        }
    }

    func testToolOutputPanelAndDisclosureInNativeTranscript() async throws {
        let longLine = "Start of the line " + String(repeating: "and more output ", count: 12) + "end of the line"
        let output = ([longLine] + (1...12).map { "build progress \($0)" } + ["error: Final failure"]).joined(separator: "\n")
        let failed = TranscriptItem(id: "fixture-command", kind: .tool, tool: .init(
            id: "fixture-command", name: "pikachu_bash", arguments: #"{"command":"xcodebuild -scheme Pikachu build"}"#,
            output: output, state: .failed, truncated: true))
        let edited = TranscriptItem(id: "fixture-edit", kind: .tool, tool: .init(
            id: "fixture-edit", name: "edit",
            arguments: #"{"path":"Pikachu/DesignSystem/FlatControlButtonStyle.swift","edits":[{"oldText":"\#(longLine)","newText":"a short replacement"},{"oldText":"var radius = 8","newText":"var radius = 6\nvar height: CGFloat? = nil"}]}"#,
            output: "Successfully replaced 2 blocks", state: .completed))
        let search = TranscriptItem(id: "fixture-search", kind: .tool, tool: .init(
            id: "fixture-search", name: "grep", arguments: #"{"path":"Pikachu","pattern":"struct .*View","glob":"*.swift","limit":30}"#,
            output: "Pikachu/WorkbenchView.swift:1:struct WorkbenchView", state: .completed))
        let host = NSHostingView(rootView: TranscriptView(items: [edited, search, failed], diagnosticSession: "fixture")
            .background(PikachuTheme.workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        window.appearance = NSAppearance(named: .aqua)
        await settleLayout(host)
        let table = try XCTUnwrap(findTable(in: host))
        let collapsed = table.rect(ofRow: 0)
        try clickToolFixture(in: table, x: 115, y: collapsed.midY)
        await settleLayout(host)
        let group = table.rect(ofRow: 0)
        XCTAssertGreaterThan(group.height, collapsed.height)
        let childHeight = (group.height - collapsed.height) / 3
        let editY = group.minY + collapsed.height + childHeight / 2
        try clickToolFixture(in: table, x: 115, y: editY)
        await settleLayout(host)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, group.height + 50)
        try attachScreenshot(host, name: "tool-edit-light-narrow")

        try clickToolFixture(in: table, x: 115, y: editY)
        await settleLayout(host)
        XCTAssertEqual(table.rect(ofRow: 0).height, group.height, accuracy: 1)
        try clickToolFixture(in: table, x: 115, y: group.maxY - childHeight / 2)
        window.appearance = NSAppearance(named: .darkAqua)
        await settleLayout(host)
        let command = table.rect(ofRow: 0)
        XCTAssertGreaterThan(command.height, group.height + 120)
        try attachScreenshot(host, name: "tool-command-dark-narrow")

        let showY = command.maxY - 47
        try clickToolFixture(in: table, x: 118, y: showY)
        try await waitForToolSheet(in: window, presented: true)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let panel = try XCTUnwrap(sheet.contentView)
        await settleLayout(panel)
        XCTAssertNil(horizontalScroll(in: panel))
        try attachScreenshot(panel, name: "tool-retained-output-panel")
        let toolbarY = panel.isFlipped ? 29 : panel.bounds.height - 29
        try clickToolFixture(in: panel, x: panel.bounds.width - 118, y: toolbarY)
        await settleLayout(panel)
        let unwrapped = try XCTUnwrap(horizontalScroll(in: panel))
        XCTAssertGreaterThan(try XCTUnwrap(unwrapped.documentView).bounds.width, unwrapped.documentVisibleRect.width)
        XCTAssertLessThanOrEqual(unwrapped.documentVisibleRect.minX, 0)
        try attachScreenshot(panel, name: "tool-retained-output-panel-unwrapped")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}",
                                                  charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        sheet.sendEvent(escape)
        try await waitForToolSheet(in: window, presented: false)

        try clickToolFixture(in: table, x: 118, y: showY)
        try await waitForToolSheet(in: window, presented: true)
        host.rootView = TranscriptView(items: [], diagnosticSession: "another-session").background(PikachuTheme.workspace)
        try await waitForToolSheet(in: window, presented: false)
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }

    func testToolOutputWrappingKeepsTheVisibleSourceLine() async throws {
        let output = (0..<100).map { index in
            "Line \(index) " + String(repeating: "甲 and more output ", count: index.isMultiple(of: 3) ? 12 : 8)
        }.joined(separator: "\n")
        let host = NSHostingView(rootView: ToolOutputPanel(selection: .init(output: output, truncated: false)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleLayout(host)
        let scroll = try XCTUnwrap(scrollViews(in: host).first { $0.documentView is NSTextView })
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let source = output as NSString
        let target = source.range(of: "Line 45 ")
        let glyph = layout.glyphIndexForCharacter(at: target.location)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let selection = NSRange(location: 2, length: 8)
        text.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + text.textContainerOrigin.y + 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleLayout(host)

        func visibleLineStart() -> Int {
            let point = NSPoint(x: 0, y: scroll.documentVisibleRect.minY - text.textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: point, in: container)
            return source.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: glyph), length: 0)).location
        }

        XCTAssertEqual(visibleLineStart(), target.location)
        let toolbarY = host.isFlipped ? 29 : host.bounds.height - 29
        for horizontal in [true, false] {
            try clickToolFixture(in: host, x: host.bounds.width - 118, y: toolbarY)
            await settleLayout(host)
            XCTAssertEqual(scroll.hasHorizontalScroller, horizontal)
            XCTAssertEqual(visibleLineStart(), target.location)
            XCTAssertEqual(text.selectedRange(), selection)
        }
    }

    func testToolOutputWrapKeepsTheHorizontallyVisibleCharacter() async throws {
        let marker = "VISIBLE-COLUMN-MARKER"
        let wide = String(repeating: "prefix ", count: 350) + marker + String(repeating: "suffix ", count: 30)
        let source = ((0..<30).map { "before \($0)" } + [wide] + (0..<30).map { "after \($0)" }).joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = ToolOutputScrollView()
        window.contentView = scroll
        defer { window.contentView = nil }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.update(text: source, font: font, wrapsLines: false)
        await settleLayout(scroll)

        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let markerLocation = (source as NSString).range(of: marker).location
        func markerRect() -> NSRect {
            let glyph = layout.glyphIndexForCharacter(at: markerLocation)
            return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        }
        func scrollTo(_ point: NSPoint) {
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let before = markerRect()
        let previousLocation = (source as NSString).range(of: "before 29").location
        let previousGlyph = layout.glyphIndexForCharacter(at: previousLocation)
        let previousLine = layout.lineFragmentRect(forGlyphAt: previousGlyph, effectiveRange: nil)
        scrollTo(NSPoint(x: before.minX - 24, y: previousLine.minY + text.textContainerOrigin.y))
        await settleLayout(scroll)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 500)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect()))

        scroll.update(text: source, font: font, wrapsLines: true)
        await settleLayout(scroll)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect()))

        let wrappedGlyph = layout.glyphIndexForCharacter(at: markerLocation)
        let wrappedLine = layout.lineFragmentRect(forGlyphAt: wrappedGlyph, effectiveRange: nil)
        scrollTo(NSPoint(x: 0, y: wrappedLine.minY + text.textContainerOrigin.y))
        scroll.update(text: source, font: font, wrapsLines: false)
        await settleLayout(scroll)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 500)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect()))
    }

    func testToolOutputWrappingFitsTheViewportWithLegacyScrollbars() async throws {
        let marker = "VISIBLE-COLUMN-MARKER"
        let earlier = "EARLIER-COLUMN-MARKER"
        let source = String(repeating: "X", count: 8_000) + earlier
            + String(repeating: "X", count: 48_000) + marker + String(repeating: "Y", count: 7_000)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = ToolOutputScrollView()
        scroll.scrollerStyle = .legacy
        window.contentView = scroll
        defer { window.contentView = nil }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.update(text: source, font: font, wrapsLines: false)
        await settleLayout(scroll)

        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        func markerRect(_ marker: String) -> NSRect {
            let location = (source as NSString).range(of: marker).location
            let glyph = layout.glyphIndexForCharacter(at: location)
            return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        }
        let originalWidth = scroll.documentVisibleRect.width
        scroll.contentView.scroll(to: NSPoint(x: markerRect(marker).minX - 24, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleLayout(scroll)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect(marker)))

        for wraps in [true, false, true, false, true] {
            scroll.update(text: source, font: font, wrapsLines: wraps)
            await settleLayout(scroll)
            XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect(marker)), "Reader moved when wrapsLines was \(wraps)")
        }
        let visible = scroll.documentVisibleRect
        XCTAssertLessThan(visible.width, originalWidth, "The newly visible scrollbar should narrow the viewport")
        XCTAssertEqual(container.containerSize.width, visible.width - 2 * text.textContainerInset.width, accuracy: 0.5)
        var rightEdge: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { line, used, _, _, _ in
            let y = text.textContainerOrigin.y
            if line.maxY + y > visible.minY, line.minY + y < visible.maxY {
                rightEdge = max(rightEdge, used.maxX + text.textContainerOrigin.x)
            }
        }
        XCTAssertGreaterThan(rightEdge, 0)
        XCTAssertLessThanOrEqual(rightEdge, visible.maxX + 0.5)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: markerRect(earlier).minY + 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleLayout(scroll)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect(earlier)))
        scroll.update(text: source, font: font, wrapsLines: false)
        await settleLayout(scroll)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(markerRect(earlier)))
        XCTAssertFalse(scroll.documentVisibleRect.intersects(markerRect(marker)))

        scroll.update(text: "New output", font: font, wrapsLines: true)
        await settleLayout(scroll)
        XCTAssertEqual(scroll.documentVisibleRect.origin, .zero)
    }

    func testToolDiffHunksKeepIndependentHorizontalOffsets() async throws {
        let long = String(repeating: "long ", count: 100)
        let raw = #"{"path":"Example.swift","edits":[{"oldText":"\#(long)","newText":"long replacement"},{"oldText":"short before","newText":"short after"}]}"#
        let item = TranscriptItem(id: "edit", kind: .tool, tool: .init(id: "edit", name: "edit", arguments: raw, state: .completed))
        let host = NSHostingView(rootView: ToolRow(item: item, expanded: .constant(true)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settleLayout(host)

        let horizontal = scrollViews(in: host).filter { $0.hasHorizontalScroller }
        XCTAssertEqual(horizontal.count, 3, "Expected the file path and two independently scrollable hunks")
        let longHunk = try XCTUnwrap(horizontal.first {
            ($0.documentView?.bounds.width ?? 0) > $0.documentVisibleRect.width + 500
        })
        let shortHunk = try XCTUnwrap(horizontal.last)
        XCTAssertFalse(longHunk === shortHunk)
        XCTAssertEqual(longHunk.frame.width, shortHunk.frame.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(shortHunk.documentView).bounds.width, shortHunk.documentVisibleRect.width, accuracy: 1)

        longHunk.contentView.scroll(to: NSPoint(x: 600, y: 0))
        longHunk.reflectScrolledClipView(longHunk.contentView)
        await settleLayout(host)
        XCTAssertGreaterThan(longHunk.documentVisibleRect.minX, 500)
        XCTAssertEqual(shortHunk.documentVisibleRect.minX, 0, accuracy: 1)
        try attachScreenshot(host, name: "tool-diff-independent-offsets")
    }

    private func clickToolFixture(in view: NSView, x: CGFloat, y: CGFloat) throws {
        let window = try XCTUnwrap(view.window)
        let location = view.convert(NSPoint(x: x, y: y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func waitForToolSheet(in window: NSWindow, presented: Bool) async throws {
        for _ in 0..<25 {
            if (window.attachedSheet != nil) == presented { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Expected output sheet presented: \(presented)")
    }

    private func attachScreenshot(_ view: NSView, name: String, bounds: NSRect? = nil) throws {
        let bounds = bounds ?? view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    func testRunningToolHeaderRendersColoredLightning() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let tool = TranscriptItem(id: "command", kind: .tool, tool: .init(
            id: "command", name: "bash", arguments: #"{"command":"sleep 3"}"#, state: .running))
        let host = NSHostingView(rootView: TranscriptView(items: [tool])
            .background(PikachuTheme.workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleLayout(host)

        let table = try XCTUnwrap(findTable(in: host))
        func hasLightning() throws -> Bool {
            let rect = table.convert(table.rect(ofRow: 0), to: host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                    if (r - g > 0.12 && g - b > 0.12) || (b - g > 0.10 && g - r > 0.19) { return true }
                }
            }
            return false
        }
        var visible = false
        for _ in 0..<15 {
            if try hasLightning() { visible = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(visible, "The native transcript should paint the first arc without waiting for a later cycle")
        tool.tool?.state = .completed
        await settleLayout(host)
        XCTAssertFalse(try hasLightning())
    }

    func testSingleToolKeepsItsDetailsExpandedWhenItFinishes() async throws {
        let tool = TranscriptItem(id: "command", kind: .tool, tool: .init(
            id: "command", name: "bash", arguments: #"{"command":"sleep 3"}"#,
            output: "Retained command output", state: .running))
        let host = NSHostingView(rootView: TranscriptView(items: [tool]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleLayout(host)

        let table = try XCTUnwrap(findTable(in: host))
        let collapsed = table.rect(ofRow: 0)
        try clickToolFixture(in: table, x: 115, y: collapsed.midY)
        await settleLayout(host)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, collapsed.height + 25)

        tool.tool?.state = .completed
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, collapsed.height + 25)
        try clickToolFixture(in: table, x: 115, y: table.rect(ofRow: 0).minY + collapsed.height / 2)
        await settleLayout(host)
        XCTAssertEqual(table.rect(ofRow: 0).height, collapsed.height, accuracy: 2)
    }

    func testTranscriptKeepsToolGroupStableWhileToolsFinish() async throws {
        let turn = TurnRecord(startedAt: .now)
        let first = TranscriptItem(id: "first", kind: .tool, tool: .init(id: "first", name: "read", state: .completed), turn: turn)
        let running = TranscriptItem(id: "running", kind: .tool, tool: .init(id: "running", name: "bash"), turn: turn)
        let parallel = TranscriptItem(id: "parallel", kind: .tool, tool: .init(id: "parallel", name: "grep"), turn: turn)
        let generating = TranscriptItem(id: "reply", kind: .assistant, streaming: true, turn: turn)
        let items = [first, running, parallel, generating]
        let host = NSHostingView(rootView: TranscriptView(items: items))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settleLayout(host)

        let table = try XCTUnwrap(findTable(in: host))
        XCTAssertEqual(table.numberOfRows, 2, "Turn header and tool group only, before the streaming reply has text")
        XCTAssertEqual(table.intercellSpacing.height, 4)
        // The turn header reserves space for its divider and top inset;
        // tool rows must remain compact independently of the header.
        XCTAssertLessThanOrEqual(table.rect(ofRow: 0).height, 42, "Turn header")
        for row in 1..<table.numberOfRows {
            XCTAssertLessThanOrEqual(table.rect(ofRow: row).height, 34, "Compact tool row \(row)")
        }

        running.tool?.output = String(repeating: "partial output ", count: 40)
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertNil(horizontalScroll(in: table))

        running.tool?.state = .completed
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        parallel.tool?.state = .interrupted
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertLessThanOrEqual(table.rect(ofRow: 1).height, 34, "Collapsed group stays compact")
        XCTAssertNil(horizontalScroll(in: table), "The group's details are collapsed by default")

        generating.append(index: 0, delta: "\n ")
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 2)
        generating.append(index: 0, delta: "Reply")
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 3, "First visible text inserts only the reply row while execution is active")

        let replyHeight = table.rect(ofRow: 2).height
        generating.streaming = false
        turn.endedAt = .now
        turn.status = .completed
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 3, "The copy footer is part of the reply row")
        XCTAssertGreaterThan(table.rect(ofRow: 2).height, replyHeight)

        let next = TurnRecord(status: .running)
        let nextReply = TranscriptItem(id: "next-reply", kind: .assistant, text: "Still generating", streaming: true, turn: next)
        host.rootView = TranscriptView(items: items + [nextReply])
        await settleLayout(host)
        XCTAssertEqual(table.numberOfRows, 5)
        XCTAssertGreaterThan(table.rect(ofRow: 2).height, replyHeight, "Earlier reply actions remain available")
    }

    func testTranscriptDrawsImageThumbnailsAboveLiveAndRestoredMessageBubbles() async throws {
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
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        func attachmentPixels() -> (imageBottom: Int?, bubbleTop: Int?) {
            guard let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (nil, nil) }
            host.cacheDisplay(in: host.bounds, to: snapshot)
            guard let data = snapshot.representation(using: .png, properties: [:]),
                  let bitmap = NSBitmapImageRep(data: data) else { return (nil, nil) }
            var imageBottom: Int?
            var bubbleTop: Int?
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                var bubblePixels = 0
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                    if color.redComponent - color.greenComponent > 0.45,
                       color.blueComponent - color.greenComponent > 0.45 { imageBottom = y }
                    // The fixture's wide file chip makes the bubble extend into the left half,
                    // away from the thumbnail's light background. Allow for color conversion.
                    if x < bitmap.pixelsWide / 2, (0.90...0.94).contains(color.redComponent),
                       abs(color.redComponent - color.greenComponent) < 0.01,
                       abs(color.redComponent - color.blueComponent) < 0.01 { bubblePixels += 1 }
                }
                if bubbleTop == nil && bubblePixels >= 6 { bubbleTop = y }
            }
            return (imageBottom, bubbleTop)
        }

        for item in [liveItem, restoredItem] {
            host.rootView = TranscriptView(items: [item])
            var pixels: (imageBottom: Int?, bubbleTop: Int?) = (nil, nil)
            for _ in 0..<30 {
                await settleLayout(host)
                pixels = attachmentPixels()
                if pixels.imageBottom != nil && pixels.bubbleTop != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if (pixels.imageBottom == nil || pixels.bubbleTop == nil), let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: snapshot)
                if let data = snapshot.representation(using: .png, properties: [:]) {
                    add(XCTAttachment(data: data, uniformTypeIdentifier: UTType.png.identifier))
                }
            }
            let imageBottom = try XCTUnwrap(pixels.imageBottom, "Expected actual image pixels for \(item.id)")
            let bubbleTop = try XCTUnwrap(pixels.bubbleTop, "Expected a separate message bubble for \(item.id)")
            XCTAssertLessThan(imageBottom, bubbleTop, "The image belongs above, not inside, the message bubble")
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

    func testFinishingToolKeepsViewportInsideItsGroup() async throws {
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
        let readingPosition = table.rect(ofRow: 1).minY + 230
        scroll.contentView.scroll(to: .init(x: 0, y: readingPosition))
        XCTAssertEqual(table.visibleRect.minY, readingPosition, accuracy: 1)

        running.tool?.state = .completed
        coordinator.update(TranscriptDisplayRow.project(items), follow: .constant(false))
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.minY, readingPosition, accuracy: 1)
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

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
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
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == 1 ? 350 : 64
    }
}
