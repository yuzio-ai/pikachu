import XCTest
import AgentRuntimeCore
import PiRuntimeAdapter
@testable import OrchestrationCore

final class TranscriptRenderingTests: XCTestCase {
    func testMarkdownTableKeepsAlignmentEmptyCellsAndInlineFormatting() throws {
        let blocks = MarkdownBlocks.parse("""
        | 功能 | RPC | 说明 |
        | :--- | :---: | ---: |
        | 发送 | `prompt` | **开始** |
        | 读取\\|状态 | [文档](https://example.com) |
        """)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(table.columns.map(\.alignment), [.left, .center, .right])
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false])
        XCTAssertEqual(table.rows[2].cells.map { String($0.characters) }, ["读取|状态", "文档", ""])
        XCTAssertEqual(table.rows[1].cells[1].runs.first?.inlinePresentationIntent, .code)
        XCTAssertEqual(table.rows[1].cells[2].runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(table.rows[2].cells[1].runs.first?.link?.absoluteString, "https://example.com")
    }

    func testMarkdownListsKeepStartingNumberNestingAndContinuation() throws {
        let blocks = MarkdownBlocks.parse("""
        3. 一项 **说明**
           同一项续行
           - 子项
           - 第二个子项
        4. 另一项

        普通段落。
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .list(ordered: true, let items) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected an ordered list")
        }
        XCTAssertEqual(items.map(\.ordinal), [3, 4])
        let firstItem = try XCTUnwrap(items.first)
        XCTAssertEqual(firstItem.blocks.first?.text, "一项 说明\n同一项续行")
        guard case .list(ordered: false, let subitems) = try XCTUnwrap(firstItem.blocks.last).kind else {
            return XCTFail("Expected a nested unordered list")
        }
        XCTAssertEqual(subitems.flatMap(\.blocks).map(\.text), ["子项", "第二个子项"])
        XCTAssertEqual(blocks.last?.text, "普通段落。")
    }

    func testMarkdownKeepsLiteralHTMLBetweenFormattedBlocks() throws {
        let blocks = MarkdownBlocks.parse("""
        **Run this:**

        <command>

        <div>**Visible text**</div>

        > <example>
        > body

        [After](https://example.com)
        """)

        XCTAssertEqual(blocks.map(\.text), ["Run this:", "<command>", "<div>**Visible text**</div>", "", "After"])
        guard blocks.count == 5 else { return }
        XCTAssertEqual(blocks.first?.content.runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNil(blocks[2].content.runs.first?.inlinePresentationIntent)
        guard case .quote(let quote) = blocks[3].kind else { return XCTFail("Expected a quote") }
        XCTAssertEqual(quote.map(\.text), ["<example>\nbody"])
        XCTAssertEqual(blocks.last?.content.runs.first?.link?.absoluteString, "https://example.com")
    }

    func testMarkdownKeepsCompletelyEmptyTableRows() throws {
        let blocks = MarkdownBlocks.parse("""
        | | |
        | :--- | ---: |
        | 甲 | 乙 |
        | | |
        | 丙 | 丁 |
        | | |

        > | |
        > | --- |
        > | |

        Plain pipes:
        | | |

        ```text
        | | |
        ```
        """)

        XCTAssertEqual(blocks.count, 4)
        guard blocks.count == 4,
              case .table(let table) = try XCTUnwrap(blocks.first).kind,
              case .quote(let quote) = blocks[1].kind,
              case .table(let emptyTable) = try XCTUnwrap(quote.first).kind else {
            return XCTFail("Expected two tables")
        }
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false, false, false])
        XCTAssertEqual(table.rows.map { $0.cells.map { String($0.characters) } },
                       [["", ""], ["甲", "乙"], ["", ""], ["丙", "丁"], ["", ""]])
        XCTAssertEqual(table.columns.map(\.alignment), [.left, .right])
        XCTAssertEqual(emptyTable.rows.map(\.isHeader), [true, false])
        XCTAssertEqual(emptyTable.rows.map { $0.cells.map { String($0.characters) } }, [[""], [""]])
        XCTAssertEqual(blocks[2].text, "Plain pipes:\n| | |")
        XCTAssertEqual(blocks[3].text, "| | |")
    }

    @MainActor func testDuplicateProtocolToolIDsHaveDistinctStableDisplayIDsOnRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        {"type":"session","version":3,"id":"duplicate-tools","cwd":"/tmp"}
        {"type":"message","id":"answer","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"reused","name":"read","arguments":{"path":"first"}},{"type":"toolCall","id":"reused","name":"read","arguments":{"path":"second"}}]}}
        {"type":"message","id":"result","parentId":"answer","message":{"role":"toolResult","toolCallId":"reused","toolName":"read","content":"local fixture","isError":false}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)

        let reader = PiHistoryReader(roots: [])
        let controller = SessionController()
        let initial = try await reader.read(url)
        controller.showHistory(initial.items)
        let previousRows = TranscriptDisplayRow.grouped(controller.transcript)
        let previousIDs = previousRows.map(\.id)
        XCTAssertEqual(previousIDs.count, 2)
        XCTAssertEqual(Set(previousIDs).count, previousIDs.count)
        XCTAssertEqual(controller.transcript.compactMap { $0.tool?.state }, [.interrupted, .completed])
        XCTAssertEqual(controller.transcript.last?.tool?.output, "local fixture")

        let refreshed = try await reader.read(url)
        controller.showHistory(refreshed.items)
        let refreshedRows = TranscriptDisplayRow.grouped(controller.transcript)
        XCTAssertEqual(refreshedRows.map(\.id), previousIDs)
        XCTAssertFalse(try XCTUnwrap(previousRows.first).hasSameItems(as: XCTUnwrap(refreshedRows.first)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    @MainActor func testCompletedToolsGroupWithoutCrossingMessagesOrOtherStatuses() {
        let user = TranscriptItem(id: "user", kind: .user, text: "Question")
        let first = tool("first", state: .completed)
        let second = tool("second", state: .completed)
        let running = tool("running", state: .running)
        let third = tool("third", state: .completed)
        let failed = tool("failed", state: .failed)
        let interrupted = tool("interrupted", state: .interrupted)
        let response = TranscriptItem(id: "response", kind: .assistant, text: "Answer")
        let next = tool("next", state: .completed)
        let items = [user, first, second, running, third, failed, interrupted, response, next]

        let before = TranscriptDisplayRow.grouped(items)
        XCTAssertEqual(before.map(\.id), ["user", "first", "running", "third", "failed", "interrupted", "response", "next"])
        guard case .completedTools(let group) = before[1] else { return XCTFail("Expected a completed tool group") }
        XCTAssertEqual(group.map(\.id), ["first", "second"])

        running.tool?.state = .completed
        let after = TranscriptDisplayRow.grouped(items)
        XCTAssertEqual(after.map(\.id), ["user", "first", "failed", "interrupted", "response", "next"])
        guard case .completedTools(let expandedGroup) = after[1] else { return XCTFail("Expected a merged tool group") }
        XCTAssertEqual(expandedGroup.map(\.id), ["first", "second", "running", "third"])
        XCTAssertTrue(after[1].contains("running"))
        XCTAssertEqual(expandedGroup[0].tool?.arguments, "arguments for first")
        XCTAssertEqual(expandedGroup[0].tool?.output, "output from first")
    }

    @MainActor private func tool(_ id: String, state: ToolState) -> TranscriptItem {
        .init(id: id, kind: .tool, tool: .init(id: id, name: "read", arguments: "arguments for \(id)", output: "output from \(id)", state: state))
    }
}
