import AppKit
import AgentRuntimeCore
import OrchestrationCore
import SwiftUI
import XCTest
@testable import Pikachu

@MainActor final class NativeTranscriptTests: XCTestCase {
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
        let rest = messages
        coordinator.update([rest[0], .item(first), .item(running)] + Array(rest.dropFirst()), follow: .constant(false))
        await settleLayout(scroll)
        scroll.contentView.scroll(to: .init(x: 0, y: table.rect(ofRow: 2).minY + 230))

        running.tool?.state = .completed
        heights.grouped = true
        coordinator.update([rest[0], .completedTools([first, running])] + Array(rest.dropFirst()), follow: .constant(false))
        await settleLayout(scroll)
        XCTAssertEqual(table.visibleRect.minY, table.rect(ofRow: 1).minY, accuracy: 1)
    }

    func testOffscreenSummaryUsesCurrentRowSize() {
        let cell = NativeTranscript.SummaryCell()

        cell.setFrameSize(.init(width: 600, height: 54))
        XCTAssertEqual(cell.label.frame, NSRect(x: 24, y: 8, width: 552, height: 38))

        cell.setFrameSize(.init(width: 320, height: 170))
        XCTAssertEqual(cell.label.frame, NSRect(x: 24, y: 8, width: 272, height: 154))
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

    private func settleLayout(_ scroll: NSScrollView) async {
        for _ in 0..<4 {
            scroll.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class ToolDetailHeights: NSObject, NSTableViewDelegate {
    var grouped = false

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if !grouped && row == 2 { return 350 }
        return 64
    }
}
