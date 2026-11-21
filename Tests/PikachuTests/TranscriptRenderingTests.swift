import XCTest
import SwiftUI
import AgentRuntimeCore
@testable import PiRuntimeAdapter
@testable import OrchestrationCore
@testable import Pikachu

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

    @MainActor func testMarkdownTableMeasuresVisibleGlyphsAndScalesWithTypography() throws {
        let blocks = MarkdownBlocks.parse("""
        | | | | | |
        | --- | --- | --- | --- | --- |
        | iii | WWW | 界界界 | `iii` | |
        """)
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected a table")
        }

        let standard = MarkdownTableLayout.naturalWidths(of: table, typography: .init(size: .standard))
        let large = MarkdownTableLayout.naturalWidths(of: table, typography: .init(size: .extraLarge))
        XCTAssertGreaterThan(standard[1], standard[0])
        XCTAssertGreaterThan(standard[2], standard[0])
        XCTAssertGreaterThan(standard[3], standard[0])
        XCTAssertEqual(standard[4], 0)
        for column in 0..<4 {
            XCTAssertGreaterThan(large[column], standard[column])
        }
    }

    @MainActor func testMarkdownContentCacheUpdatesNestedTableWidthsForSourceAndTypography() throws {
        let cache = MarkdownContentCache()
        let quote = "> | H |\n> | --- |\n> | `x` |"
        let initial = cache.layout(for: quote, typography: .init())
        XCTAssertEqual(initial.tableWidths.count, 1)
        XCTAssertEqual(cache.layout(for: quote, typography: .init()).tableWidths, initial.tableWidths)

        let longer = quote.replacingOccurrences(of: "`x`", with: "`long_identifier`")
        let updated = cache.layout(for: longer, typography: .init())
        let enlarged = cache.layout(for: longer, typography: .init(size: .extraLarge))
        let initialWidth = try XCTUnwrap(initial.tableWidths.values.first?.first)
        let updatedWidth = try XCTUnwrap(updated.tableWidths.values.first?.first)
        let enlargedWidth = try XCTUnwrap(enlarged.tableWidths.values.first?.first)
        XCTAssertGreaterThan(updatedWidth, initialWidth)
        XCTAssertGreaterThan(enlargedWidth, updatedWidth)
    }

    @MainActor func testMarkdownContentCacheKeepsTheExactSourceBytes() throws {
        let cache = MarkdownContentCache()
        let composed = "`\u{00E9}`"
        let decomposed = "`e\u{0301}`"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))

        _ = cache.layout(for: composed, typography: .init())
        let updated = try XCTUnwrap(cache.layout(for: decomposed, typography: .init()).blocks.first)
        XCTAssertEqual(Array(updated.text.utf8), Array("e\u{0301}".utf8))
    }

    func testMarkdownTableFitsShortColumnsAndScrollsOnlyBelowTheMinimum() {
        let short = MarkdownTableLayout(naturalWidths: [22, 41, 0], bodySize: 14, availableWidth: 800)
        XCTAssertEqual(short.columnWidths, [22, 41, 0])
        XCTAssertFalse(short.needsHorizontalScroll)

        for available: CGFloat in [237, 238] {
            let layout = MarkdownTableLayout(naturalWidths: [16, 333, 0, 333], bodySize: 14, availableWidth: available)
            XCTAssertEqual(layout.columnWidths, [16, 84, 0, 84])
            XCTAssertEqual(layout.needsHorizontalScroll, available < 238)
        }
    }

    func testMarkdownTableCapsTheInfluenceOfLongTokensAndRedistributesSurplus() {
        let widths: [CGFloat] = [140, 9_900, 224]
        let narrow = MarkdownTableLayout(naturalWidths: widths, bodySize: 14, availableWidth: 480)
        let capped = MarkdownTableLayout(naturalWidths: [140, 392, 224], bodySize: 14, availableWidth: 480)
        XCTAssertFalse(narrow.needsHorizontalScroll)
        XCTAssertEqual(narrow.columnWidths, capped.columnWidths)
        XCTAssertEqual(narrow.columnWidths.reduce(0, +) + 36, 480, accuracy: 0.001)

        let wide = MarkdownTableLayout(naturalWidths: widths, bodySize: 14, availableWidth: 1_040)
        for (actual, expected) in zip(wide.columnWidths, [140.0, 640.0, 224.0]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    @MainActor func testMarkdownTableCodeStylingPreservesTextAndLinkAttributes() throws {
        let blocks = MarkdownBlocks.parse("""
        | Cell |
        | --- |
        | `select_this` [Open link](https://example.com/table-link) **bold** |
        """)
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("Expected a table")
        }

        let cell = table.rows[1].cells[0]
        let styled = MarkdownTableFonts(typography: .init(), isHeader: false).stylingCode(in: cell)
        XCTAssertEqual(String(styled.characters), "select_this Open link bold")
        XCTAssertEqual(styled.runs.map(\.inlinePresentationIntent), cell.runs.map(\.inlinePresentationIntent))
        XCTAssertEqual(styled.runs.compactMap(\.link), cell.runs.compactMap(\.link))
        XCTAssertNotNil(styled.runs.first?.swiftUI.font)
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

    @MainActor func testToolSummariesDecodeCommandsEditsAndFallBackToAvailableArguments() throws {
        for name in ["bash", "pikachu_bash"] {
            let raw = #"{"command":"git status --short\nsecond line"}"#
            let presentation = try toolPresentation(name, arguments: raw)
            XCTAssertEqual(presentation.object, "git status --short")
            guard case .command(let command) = presentation.parameters else { return XCTFail("Expected command") }
            XCTAssertEqual(command, "git status --short\nsecond line")
        }

        for name in ["edit", "pikachu_edit"] {
            let raw = #"{"path":"Pikachu/View.swift","edits":[{"oldText":"context\nold","newText":"context\nnew"}]}"#
            let presentation = try toolPresentation(name, arguments: raw, state: .failed)
            XCTAssertEqual(presentation.object, "View.swift")
            XCTAssertTrue(presentation.accessibilityDescription.contains("View.swift"))
            XCTAssertTrue(presentation.accessibilityDescription.contains(String(localized: ToolState.failed.statusLabel)))
            guard case .edit(let edit) = presentation.parameters else { return XCTFail("Expected edit") }
            XCTAssertEqual(edit.path, "Pikachu/View.swift")
            XCTAssertEqual(edit.edits.count, 1)
            XCTAssertEqual(ToolEditDiff.lines(for: edit.edits[0]), [
                .init(kind: .context, text: "context"),
                .init(kind: .removal, text: "old"),
                .init(kind: .insertion, text: "new")
            ])
        }

        for raw in [#"{"path":"View.swift","oldText":"old","newText":"new"}"#,
                    #"{"path":"View.swift","edits":{"oldText":"old","newText":"new"}}"#,
                    #"{"path":"View.swift","edits":"[{\"oldText\":\"old\",\"newText\":\"new\"}]"}"#] {
            let presentation = try toolPresentation("edit", arguments: raw)
            guard case .edit(let edit) = presentation.parameters else { return XCTFail("Expected a compatible edit") }
            XCTAssertEqual(edit.edits.map(\.oldText), ["old"])
            XCTAssertEqual(edit.edits.map(\.newText), ["new"])
        }

        for (name, raw) in [("bash", ""), ("bash", #"{"command":42}"#), ("edit", "{"),
                            ("pikachu_edit", #"{"path":"View.swift","edits":[{}]}"#),
                            ("read", #"{"offset":30,"limit":268}"#),
                            ("custom", #"{"command":"unrecognized"}"#)] {
            let presentation = try toolPresentation(name, arguments: raw)
            guard case .raw = presentation.parameters else { return XCTFail("Expected raw arguments for \(name)") }
            XCTAssertNil(presentation.operationLabel)
            XCTAssertEqual(presentation.object, raw)
            XCTAssertTrue(presentation.accessibilityDescription.hasPrefix(name))
        }
    }

    @MainActor func testReadSummariesUseFileNameAndOptionalLineRange() throws {
        for name in ["read", "pikachu_read"] {
            let raw = #"{"limit":268,"offset":30,"path":"Pikachu\/Features\/Workbench\/WorkbenchView.swift"}"#
            let presentation = try toolPresentation(name, arguments: raw)
            guard case .read(let read) = presentation.parameters else { return XCTFail("Expected a file read") }
            XCTAssertEqual(read.path, "Pikachu/Features/Workbench/WorkbenchView.swift")
            XCTAssertEqual(presentation.object, "WorkbenchView.swift")
            XCTAssertEqual(read.offset, 30)
            XCTAssertEqual(read.limit, 268)
            XCTAssertEqual(presentation.qualifiers.count, 2)
            XCTAssertFalse(presentation.accessibilityDescription.contains("\"path\""))
        }

        let presentation = try toolPresentation("read", arguments: #"{"offset":"unknown","path":"README.md"}"#)
        XCTAssertEqual(presentation.object, "README.md")
        XCTAssertTrue(presentation.qualifiers.isEmpty)
    }

    @MainActor func testMixedToolGroupCountsAliasesAndExposesOnlyExceptionalStates() {
        let states: [(String, ToolState)] = [
            ("pikachu_bash", .completed), ("edit", .failed), ("read", .interrupted),
            ("pikachu_read", .completed), ("custom", .completed), ("grep", .completed), ("pikachu_grep", .completed)
        ]
        let group = states.map { name, state in
            TranscriptItem(id: name, kind: .tool, tool: .init(id: name, name: name, state: state))
        }
        let summary = ToolCallsSummary(items: group)
        XCTAssertEqual(summary.total, 7)
        XCTAssertEqual(summary.commands, 1)
        XCTAssertEqual(summary.edits, 1)
        XCTAssertEqual(summary.reads, 2)
        XCTAssertEqual(summary.searches, 2)
        XCTAssertEqual(summary.composition.count, 5)
        XCTAssertEqual(String(localized: summary.composition[3]), String(localized: "\(2) 次搜索"))
        XCTAssertEqual(String(localized: summary.statuses[0].label), String(localized: "失败 \(1) 项"))
        XCTAssertEqual(summary.statuses.map(\.state), [.failed, .interrupted])
        XCTAssertTrue(ToolCallsSummary(items: [group[4]]).composition.isEmpty)
    }

    func testToolGroupLightningVariesAcrossCyclesAndFadesInPlace() {
        let cycles = (0..<24).map { ToolCallLightningPattern.arcs(seed: 42, cycle: UInt64($0)) }
        XCTAssertEqual(cycles[0], ToolCallLightningPattern.arcs(seed: 42, cycle: 0))
        XCTAssertEqual(cycles[0].first?.opacity(at: 0), 1, "Short calls should show a discharge immediately")
        XCTAssertEqual(Set(cycles.map(\.count)), [2, 3, 4])
        XCTAssertTrue(cycles.allSatisfy { Set($0.map(\.start)).count == 2 })
        let arcs = cycles.flatMap { $0 }
        XCTAssertTrue(arcs.contains { abs($0.angle) < 0.17 })
        XCTAssertTrue(arcs.contains { abs($0.angle - .pi / 2) < 0.17 })
        XCTAssertTrue(arcs.contains { abs(abs($0.angle) - .pi / 4) < 0.17 })
        XCTAssertGreaterThan(Set(arcs.map(\.position)).count, 3)
        for arc in arcs {
            XCTAssertEqual(arc.opacity(at: arc.start - 0.001), 0)
            XCTAssertEqual(arc.opacity(at: arc.start), 1)
            XCTAssertGreaterThan(arc.opacity(at: arc.start + 0.07), arc.opacity(at: arc.start + 0.2))
            XCTAssertEqual(arc.opacity(at: arc.start + arc.duration + 0.01), 0)
            XCTAssertLessThan(arc.start + arc.duration, ToolCallLightningPattern.period)
        }
    }

    @MainActor func testThinkingFollowsLatestToolGroupOnlyWhileWaitingForModelOutput() {
        let turn = TurnRecord(startedAt: .now)
        let item = TranscriptItem(id: "read", kind: .tool,
                                  tool: .init(id: "read", name: "read", state: .running), turn: turn)
        let reply = TranscriptItem(id: "reply", kind: .assistant, streaming: true, turn: turn)
        func showsIndicator(_ items: [TranscriptItem], live: Bool = true) -> Bool {
            TranscriptDisplayRow.project(items, showsThinking: live).contains {
                if case .thinking = $0 { return true }
                return false
            }
        }
        XCTAssertFalse(showsIndicator([item, reply]))
        item.tool?.state = .completed
        guard case .thinking(let thinkingTurn) = TranscriptDisplayRow.project([item, reply], showsThinking: true).last else {
            return XCTFail("Expected thinking just below the last tool group")
        }
        XCTAssertTrue(thinkingTurn === turn)
        XCTAssertFalse(showsIndicator([item, reply], live: false))

        reply.append(index: 0, delta: "Reply")
        XCTAssertFalse(showsIndicator([item, reply]))
        let next = TranscriptItem(id: "grep", kind: .tool,
                                  tool: .init(id: "grep", name: "grep", state: .completed), turn: turn)
        XCTAssertTrue(showsIndicator([item, reply, next]))
        item.tool?.state = .running
        XCTAssertFalse(showsIndicator([item, reply, next]), "A parallel tool in an earlier group is still running")
    }

    @MainActor func testToolGroupIconFollowsLastRunningToolInTranscriptOrder() {
        func runningToolName(readState: ToolState, searchState: ToolState) -> String? {
            let states: [(String, ToolState)] = [
                ("pikachu_read", readState), ("grep", searchState), ("bash", .completed)
            ]
            let items = states.map { name, state in
                TranscriptItem(id: name, kind: .tool, tool: .init(id: name, name: name, state: state))
            }
            return ToolCallsSummary(items: items).runningToolName
        }
        XCTAssertEqual(runningToolName(readState: .running, searchState: .running), "grep")
        XCTAssertEqual(runningToolName(readState: .running, searchState: .completed), "pikachu_read")
        XCTAssertNil(runningToolName(readState: .interrupted, searchState: .completed))
    }

    @MainActor func testGrepSummariesUseThePatternAndOptionalScope() throws {
        for name in ["grep", "pikachu_grep"] {
            let raw = #"{"pattern":"first|第二","path":"Pikachu\/Features","glob":"*.swift","limit":30}"#
            let presentation = try toolPresentation(name, arguments: raw)
            guard case .search(let search) = presentation.parameters else { return XCTFail("Expected a search") }
            XCTAssertEqual(presentation.operationLabel.map { String(localized: $0) }, String(localized: "搜索"))
            XCTAssertEqual(presentation.object, "first|第二")
            XCTAssertEqual(search.path, "Pikachu/Features")
            XCTAssertEqual(search.glob, "*.swift")
            XCTAssertEqual(search.limit, 30)
            XCTAssertTrue(presentation.accessibilityDescription.contains("Pikachu/Features"))
        }
        let presentation = try toolPresentation("grep", arguments: #"{"pattern":"test","limit":"unknown"}"#)
        guard case .search(let search) = presentation.parameters else { return XCTFail("Expected a search") }
        XCTAssertEqual(presentation.object, "test")
        XCTAssertNil(search.limit)
        XCTAssertTrue(presentation.qualifiers.isEmpty)
    }

    @MainActor func testDirectoryFindAndWriteSummariesRecognizePiToolAliases() throws {
        for prefix in ["", "pikachu_"] {
            let list = try toolPresentation(prefix + "ls", arguments: #"{"path":"Pikachu\/Features","limit":20}"#)
            guard case .list(let directory) = list.parameters else { return XCTFail("Expected a directory listing") }
            XCTAssertEqual(list.operationLabel.map { String(localized: $0) }, String(localized: "列出目录"))
            XCTAssertEqual(list.object, "Pikachu/Features")
            XCTAssertEqual(directory.limit, 20)
            XCTAssertEqual(try toolPresentation(prefix + "ls", arguments: "{}").object, String(localized: "当前目录"))

            let find = try toolPresentation(prefix + "find", arguments: #"{"pattern":"**/*.swift","path":"Pikachu","limit":10}"#)
            guard case .find(let search) = find.parameters else { return XCTFail("Expected a file search") }
            XCTAssertEqual(find.operationLabel.map { String(localized: $0) }, String(localized: "查找文件"))
            XCTAssertEqual(find.object, "**/*.swift")
            XCTAssertEqual(search.limit, 10)
            XCTAssertTrue(find.accessibilityDescription.contains("Pikachu"))

            let write = try toolPresentation(prefix + "write", arguments: #"{"path":"Pikachu/View.swift","content":"body"}"#)
            guard case .write(let path) = write.parameters else { return XCTFail("Expected a file write") }
            XCTAssertEqual(write.operationLabel.map { String(localized: $0) }, String(localized: "写入文件"))
            XCTAssertEqual(path, "Pikachu/View.swift")
            XCTAssertEqual(write.object, "View.swift")
            XCTAssertFalse(write.accessibilityDescription.contains("body"))

            var tool = RuntimeTool(id: "long-write", name: prefix + "write")
            PiEventMapper.setToolArguments(["path": "Pikachu/View.swift", "content": String(repeating: "x", count: 20_000)], on: &tool)
            XCTAssertEqual(tool.argumentsTruncated, true)
            let item = TranscriptItem(id: tool.id, kind: .tool, tool: tool)
            let longWrite = ToolCallPresentation(try XCTUnwrap(item.toolSummary))
            XCTAssertEqual(longWrite.object, "View.swift")
        }
    }

    @MainActor func testDirectoryFindAndWriteAreNotCountedAsOther() {
        let names = ["ls", "pikachu_ls", "find", "pikachu_find", "write", "pikachu_write"]
        let items = names.map { TranscriptItem(id: $0, kind: .tool, tool: .init(id: $0, name: $0)) }
        let summary = ToolCallsSummary(items: items)
        XCTAssertEqual(summary.listings, 2)
        XCTAssertEqual(summary.finds, 2)
        XCTAssertEqual(summary.writes, 2)
        XCTAssertEqual(summary.composition.map { String(localized: $0) }, [
            String(localized: "\(2) 次列目录"), String(localized: "\(2) 次文件查找"), String(localized: "\(2) 次写入")
        ])
    }

    func testToolOutputPreviewLimitsLinesAndFindsDiagnosticsBeyondThePreview() {
        let firstEight = (1...8).map { "  line \($0)" }.joined(separator: "\r\n")
        let output = firstEight + "\r\nView.swift:12:4: error: build failed\r\n"
        let presentation = ToolOutputPresentation(output: output, failed: true)
        XCTAssertEqual(presentation.preview, firstEight)
        XCTAssertTrue(presentation.hasMore)
        XCTAssertEqual(presentation.diagnostic, "View.swift:12:4: error: build failed")
        XCTAssertNil(ToolOutputPresentation(output: output, failed: false).diagnostic)
        XCTAssertNil(ToolOutputPresentation(output: "no diagnostic", failed: true).diagnostic)
        let timeout = "ordinary output\n\nCommand timed out after 2 seconds"
        XCTAssertEqual(ToolOutputPresentation(output: timeout, failed: true).diagnostic, "Command timed out after 2 seconds")
        XCTAssertEqual(ToolOutputPresentation(output: "\n\nend\n", failed: false).preview, "\n\nend\n")
        XCTAssertFalse(ToolOutputPresentation(output: "", failed: true).hasMore)
        XCTAssertTrue(ToolOutputPresentation(output: String(repeating: "x", count: 5_000), failed: false).hasMore)
    }

    @MainActor func testLiveAndRestoredLongEditsUseStructuredArguments() async throws {
        let old = String(repeating: "x", count: 9_000)
        let new = String(repeating: "y", count: 9_000)
        let oversized = String(repeating: "z", count: 1_048_576)
        let overLineLimit = String(repeating: "old\n", count: 257)
        let overRemainingBudget = String(repeating: "a", count: 50_000)
        let arguments: [String: Any] = [
            "path": "Example.swift",
            "replacementCount": 99,
            "edits": [
                ["oldText": oversized, "newText": oversized],
                ["oldText": overLineLimit, "newText": "new"],
                ["oldText": old, "newText": new],
                ["oldText": overRemainingBudget, "newText": "new"],
                ["oldText": "tail before", "newText": "tail after"]
            ]
        ]
        var mapper = PiEventMapper()
        _ = mapper.map(["type": "tool_execution_start", "toolCallId": "edit", "toolName": "pikachu_edit", "args": arguments])
        let events = mapper.map(["type": "tool_execution_end", "toolCallId": "edit", "result": ["content": "OK"]])
        guard case .tool(let live) = try XCTUnwrap(events.first) else { return XCTFail("Expected a tool result") }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let argumentData = try JSONSerialization.data(withJSONObject: arguments)
        let argumentJSON = String(decoding: argumentData, as: UTF8.self)
        let source = """
        {"type":"session","version":3,"id":"long-edit","cwd":"/tmp"}
        {"type":"message","id":"answer","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"edit","name":"pikachu_edit","arguments":\(argumentJSON)}]}}
        {"type":"message","id":"result","parentId":"answer","message":{"role":"toolResult","toolCallId":"edit","toolName":"pikachu_edit","content":"OK","isError":false}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let history = try await PiHistoryReader(roots: []).read(url)
        let controller = SessionController()
        controller.showHistory(history.items, turns: history.turns)
        let restored = try XCTUnwrap(controller.transcript.last?.tool)

        for tool in [live, restored] {
            XCTAssertEqual(tool.state, .completed)
            XCTAssertEqual(tool.arguments.count, 16_384)
            XCTAssertEqual(tool.argumentsTruncated, true)
            let item = TranscriptItem(id: tool.id, kind: .tool, tool: tool)
            let presentation = ToolCallPresentation(try XCTUnwrap(item.toolSummary))
            guard case .edit(let edit) = presentation.parameters else { return XCTFail("Expected structured edit") }
            XCTAssertEqual(edit.path, "Example.swift")
            XCTAssertEqual(edit.replacementCount, 5)
            XCTAssertEqual(edit.omittedPreviewCount, 3)
            XCTAssertEqual(edit.edits.map(\.oldText), [old, "tail before"])
            let replacement = try XCTUnwrap(edit.edits.first)
            XCTAssertEqual(ToolEditDiff.lines(for: replacement), [
                .init(kind: .removal, text: old),
                .init(kind: .insertion, text: new)
            ])
        }
    }

    @MainActor func testEditPreviewKeepsPathAndCountWhenAllReplacementsAreOmitted() throws {
        let overLineLimit = String(repeating: "old\n", count: 257)
        let arguments = ["path": "Example.swift", "edits": [["oldText": overLineLimit, "newText": "new"]]] as [String: Any]
        var tool = RuntimeTool(id: "edit", name: "edit", state: .completed)
        PiEventMapper.setToolArguments(arguments, on: &tool)
        let encoded = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(RuntimeTool.self, from: encoded)
        let item = TranscriptItem(id: decoded.id, kind: .tool, tool: decoded)
        let presentation = ToolCallPresentation(try XCTUnwrap(item.toolSummary))
        guard case .edit(let edit) = presentation.parameters else { return XCTFail("Expected an edit without previews") }
        XCTAssertEqual(edit.path, "Example.swift")
        XCTAssertEqual(edit.replacementCount, 1)
        XCTAssertEqual(edit.omittedPreviewCount, 1)
        XCTAssertTrue(edit.edits.isEmpty)
    }

    @MainActor func testRawEditSummaryDerivesReplacementCountFromActualArguments() throws {
        let oneReplacement = #"{"path":"Example.swift","replacementCount":99,"edits":[{"oldText":"old","newText":"new"}]}"#
        let one = try toolPresentation("edit", arguments: oneReplacement)
        guard case .edit(let edit) = one.parameters else { return XCTFail("Expected an edit") }
        XCTAssertEqual(edit.replacementCount, 1)
        XCTAssertEqual(edit.omittedPreviewCount, 0)

        let metadataOnly = #"{"path":"Example.swift","replacementCount":99}"#
        let none = try toolPresentation("edit", arguments: metadataOnly)
        guard case .raw = none.parameters else { return XCTFail("Expected raw arguments without replacements") }
    }

    func testToolEditDiffShowsLineEndingOnlyChanges() throws {
        func diff(_ old: String, _ new: String) throws -> [ToolEditDiff.Line] {
            let data = try JSONSerialization.data(withJSONObject: ["oldText": old, "newText": new])
            let edit = try JSONDecoder().decode(RuntimeToolApproval.Replacement.self, from: data)
            return try XCTUnwrap(ToolEditDiff.lines(for: edit))
        }
        let lineEndings = try diff("first\r\nsecond\r\nshared\n", "first\nsecond\nshared\n")
        XCTAssertEqual(lineEndings, [
            .init(kind: .removal, text: "first", ending: .crlf),
            .init(kind: .removal, text: "second", ending: .crlf),
            .init(kind: .insertion, text: "first", ending: .lf),
            .init(kind: .insertion, text: "second", ending: .lf),
            .init(kind: .context, text: "shared")
        ])
        let trailingNewline = try diff("line", "line\n")
        XCTAssertEqual(trailingNewline, [
            .init(kind: .removal, text: "line", ending: ToolEditDiff.Ending.none),
            .init(kind: .insertion, text: "line", ending: .lf)
        ])
    }

    @MainActor private func toolPresentation(_ name: String, arguments: String, state: ToolState = .completed) throws -> ToolCallPresentation {
        let item = TranscriptItem(id: name, kind: .tool, tool: .init(id: name, name: name, arguments: arguments, state: state))
        return ToolCallPresentation(try XCTUnwrap(item.toolSummary))
    }

    @MainActor func testRestoredBashOutputPreservesPiTruncationBelowTheAppLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        {"type":"session","version":3,"id":"truncated-tool","cwd":"/tmp"}
        {"type":"message","id":"answer","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"bash-call","name":"bash","arguments":{"command":"fixture"}}]}}
        {"type":"message","id":"result","parentId":"answer","message":{"role":"toolResult","toolCallId":"bash-call","toolName":"bash","content":"retained output","isError":false,"details":{"truncation":{"truncated":true}}}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)

        let reader = PiHistoryReader(roots: [])
        let controller = SessionController()
        let history = try await reader.read(url)
        controller.showHistory(history.items, turns: history.turns)
        let tool = try XCTUnwrap(controller.transcript.last?.tool)
        XCTAssertEqual(tool.output, "retained output")
        XCTAssertTrue(tool.truncated)
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
        controller.showHistory(initial.items, turns: initial.turns)
        let previousRows = TranscriptDisplayRow.project(controller.transcript)
        let previousIDs = previousRows.map(\.id)
        XCTAssertEqual(previousIDs.count, 2)
        XCTAssertEqual(Set(previousIDs).count, previousIDs.count)
        XCTAssertEqual(controller.transcript.compactMap { $0.tool?.state }, [.interrupted, .completed])
        XCTAssertEqual(Set(controller.transcript.map(\.id)).count, 2)
        XCTAssertEqual(controller.transcript.last?.tool?.output, "local fixture")
        let legacySummary = try XCTUnwrap(controller.transcript.last?.toolSummary)
        let legacy = ToolCallPresentation(legacySummary)
        guard case .read(let read) = legacy.parameters else { return XCTFail("Expected a restored read summary") }
        XCTAssertEqual(read.path, "second")
        XCTAssertEqual(legacy.object, "second")

        let refreshed = try await reader.read(url)
        controller.showHistory(refreshed.items, turns: refreshed.turns)
        let refreshedRows = TranscriptDisplayRow.project(controller.transcript)
        XCTAssertEqual(refreshedRows.map(\.id), previousIDs)
        XCTAssertFalse(try XCTUnwrap(previousRows.first).hasSameItems(as: XCTUnwrap(refreshedRows.first)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    @MainActor func testRunningToolsShareAStableGroupAndUpdateItsIconAsTheyFinish() {
        let user = TranscriptItem(id: "user", kind: .user, text: "Question")
        let first = tool("first", state: .completed)
        let second = tool("second", state: .completed)
        let running = tool("running", state: .running)
        let parallel = tool("parallel", state: .running)
        let failed = tool("failed", state: .failed)
        let interrupted = tool("interrupted", state: .interrupted)
        let response = TranscriptItem(id: "response", kind: .assistant, text: "Answer")
        let next = tool("next", state: .completed)
        let items = [user, first, second, running, parallel, failed, interrupted, response, next]

        parallel.tool?.name = "grep"
        running.tool?.name = "bash"
        let before = TranscriptDisplayRow.project(items)
        XCTAssertEqual(before.map(\.id), ["user", "first", "response", "next"])
        guard before.count == 4, case .toolCalls(let active) = before[1] else {
            return XCTFail("Expected a single group for consecutive tools")
        }
        let activeSummary = ToolCallsSummary(items: active)
        XCTAssertEqual(activeSummary.runningToolName, "grep")
        let search = String(localized: "搜索")
        XCTAssertTrue(activeSummary.description.contains(String(localized: "正在执行：\(search)")))

        parallel.tool?.state = .completed
        let during = TranscriptDisplayRow.project(items)
        XCTAssertEqual(during.map(\.id), before.map(\.id))
        guard during.count == 4, case .toolCalls(let partial) = during[1] else { return XCTFail("Expected the same group") }
        XCTAssertTrue(during[1].hasSameItems(as: before[1]))
        let partialSummary = ToolCallsSummary(items: partial)
        XCTAssertEqual(partialSummary.runningToolName, "bash")
        let command = String(localized: "运行命令")
        XCTAssertTrue(partialSummary.description.contains(String(localized: "正在执行：\(command)")))

        running.tool?.state = .completed
        let after = TranscriptDisplayRow.project(items)
        XCTAssertEqual(after.map(\.id), ["user", "first", "response", "next"])
        guard after.count == 4, case .toolCalls(let group) = after[1] else { return XCTFail("Expected a merged group") }
        XCTAssertEqual(group.map(\.id), ["first", "second", "running", "parallel", "failed", "interrupted"])
        XCTAssertTrue(after[1].contains("running"))
        XCTAssertNil(ToolCallsSummary(items: group).runningToolName)
        XCTAssertEqual(ToolCallsSummary(items: group).statuses.map(\.state), [.failed, .interrupted])
        XCTAssertEqual(group[0].tool?.arguments, "arguments for first")
        XCTAssertEqual(group[0].tool?.output, "output from first")
    }

    @MainActor func testSingleToolExpansionSurvivesAppendingAndClosingItsGroup() {
        let first = tool("first", state: .running)
        let next = tool("next", state: .failed)
        let expansion = ToolCallExpansion()
        let single = expansion.detailBinding(for: first, isSingle: true)
        XCTAssertFalse(single.wrappedValue)
        single.wrappedValue = true

        let group = expansion.groupBinding(for: [first, next])
        let detail = expansion.detailBinding(for: first, isSingle: false)
        XCTAssertTrue(group.wrappedValue)
        XCTAssertTrue(detail.wrappedValue)
        XCTAssertFalse(expansion.detailBinding(for: next, isSingle: false).wrappedValue)
        group.wrappedValue = false
        XCTAssertFalse(single.wrappedValue)
        XCTAssertTrue(detail.wrappedValue)
        group.wrappedValue = true
        XCTAssertTrue(detail.wrappedValue)
    }

    @MainActor func testHistoryUsesUserEntryIDsForToolFirstAndEmptyRoundsWithEqualTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = """
        {"type":"session","version":3,"id":"turn-anchors","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"same text","timestamp":1795000000000}}
        {"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"toolCall","id":"first","name":"read","arguments":{}}],"stopReason":"toolUse","timestamp":1795000001000}}
        {"type":"message","id":"r1","parentId":"a1","message":{"role":"toolResult","toolCallId":"first","toolName":"read","content":"failed","isError":true}}
        {"type":"message","id":"retry","parentId":"r1","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"UND_ERR_SOCKET","timestamp":1795000001500}}
        {"type":"message","id":"a2","parentId":"retry","message":{"role":"assistant","content":"first response","stopReason":"stop","timestamp":1795000002000}}
        {"type":"message","id":"u2","parentId":"a2","message":{"role":"user","content":"same text","timestamp":1795000000000}}
        {"type":"message","id":"a3","parentId":"u2","message":{"role":"assistant","content":[],"stopReason":"stop","timestamp":1795000003000}}

        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let history = try await PiHistoryReader(roots: []).read(url)
        XCTAssertEqual(history.turns.map(\.firstUserItemID), ["history:u1", "history:u2"])
        let controller = SessionController()
        let first = RecordedTurnRecord(anchorAssistantTimestampMs: 1_795_000_001_000,
                                       endAssistantTimestampMs: 1_795_000_002_000,
                                       endedAt: Date(), durationSeconds: 5, status: .failed)
        controller.showHistory(history.items, turns: history.turns, recordedTurns: [first])
        let rows = TranscriptDisplayRow.project(controller.transcript)
        XCTAssertEqual(rows.map(\.id), [
            "history:u1", "turn-header:turn:a1", "history-tool:0:history:a1", "history-end:history:retry", "history:a2",
            "history:u2", "turn-header:turn:a3",
        ])
        guard case .turnHeader(let firstTurn) = rows[1], case .turnHeader(let secondTurn) = rows[6] else {
            return XCTFail("Expected two distinct headers")
        }
        XCTAssertEqual(firstTurn.status, .completed)
        XCTAssertTrue(controller.transcript.contains { $0.kind == .notice && $0.text.contains("UND_ERR_SOCKET") })
        XCTAssertEqual(firstTurn.durationSeconds, 5)
        XCTAssertNil(secondTurn.durationSeconds)
    }

    @MainActor func testLateQueuedAcknowledgementKeepsIdenticalFollowUpsInOrder() async throws {
        let first = UserPrompt(text: "repeat", mode: .followUp)
        let second = UserPrompt(text: "repeat", mode: .followUp)
        let runtime = TranscriptQueueRuntime(delayedPrompt: second.id)
        let controller = SessionController()
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        receive(.assistantCompleted(UUID(), "Initial reply"))
        await controller.sendDraft(first)
        receive(.queue(.init(followUp: ["repeat"])))

        let pending = Task { await controller.sendDraft(second) }
        await runtime.gate.waitForSend()
        receive(.queue(.init(followUp: ["repeat"])))
        XCTAssertEqual(controller.transcript.last?.delivery, .pending)
        receive(.queue(.init(followUp: ["repeat", "repeat"])))
        receive(.queue(.init(followUp: ["repeat"])))
        receive(.userMessageTimestamp(1_795_000_001_000, text: "repeat"))
        receive(.assistantCompleted(UUID(), "First follow-up reply"))
        let users = controller.transcript.filter { $0.kind == .user }
        XCTAssertEqual(users.map(\.delivery), [.accepted, .accepted, .queued])
        XCTAssertEqual(users[1].messageTimestampMs, 1_795_000_001_000)
        XCTAssertNil(users[2].messageTimestampMs)

        await runtime.gate.acknowledge()
        await pending.value
        receive(.queue(.init()))
        receive(.userMessageTimestamp(1_795_000_002_000, text: "repeat"))
        receive(.assistantCompleted(UUID(), "Second follow-up reply"))
        let turns: [TurnRecord] = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts).compactMap { row in
            if case .turnHeader(let turn) = row { return turn }
            return nil
        }
        XCTAssertEqual(turns.map(\.status), [.completed, .completed, .running])
        XCTAssertEqual(Set(turns.map(\.id)).count, 3)
        let replies = controller.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(replies.compactMap { $0.turn?.id }, turns.map(\.id))
        XCTAssertEqual(users[2].messageTimestampMs, 1_795_000_002_000)
        _ = await controller.disconnect()
    }

    @MainActor func testPiUserStartsKeepSteeringAndFollowUpHistoryAttachmentsWithTheirInputs() async throws {
        let steer = UserPrompt(text: "steer", files: [URL(fileURLWithPath: "/tmp/steer.txt")])
        let follow = UserPrompt(text: "follow", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/follow.txt")])
        let runtime = TranscriptQueueRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        var mapper = PiEventMapper()
        func userStart(_ text: String, _ timestamp: Int64) {
            let events = mapper.map(["type": "message_start", "message": [
                "role": "user", "timestamp": timestamp, "content": [["type": "text", "text": text]],
            ]])
            XCTAssertEqual(events.count, 1)
            events.forEach(receive)
        }
        let prompts = [steer.id: steer, follow.id: follow]
        var stored: [RecordedMessageRecord] = []
        controller.onUserMessageTimestamp = { id, timestamp in
            guard let id, let prompt = prompts[id] else { return }
            stored.append(.init(id: id, text: prompt.text, files: prompt.files, sentAt: nil, messageTimestampMs: timestamp))
        }
        await controller.sendDraft(.init(text: "initial"))
        userStart("initial", 1_795_000_000_000)
        receive(.assistantCompleted(UUID(), "Working"))
        await controller.sendDraft(steer)
        receive(.queue(.init(steering: [steer.runtimeText])))
        await controller.sendDraft(follow)
        receive(.queue(.init(steering: [steer.runtimeText], followUp: [follow.runtimeText])))
        userStart(follow.runtimeText, 1_795_000_000_999)
        XCTAssertTrue(stored.isEmpty, "A payload still in the queue cannot acquire a timestamp")

        let steeringTime: Int64 = 1_795_000_001_000
        let followUpTime: Int64 = 1_795_000_002_000
        receive(.queue(.init(followUp: [follow.runtimeText])))
        userStart("Unrelated user message", 1_795_000_001_001)
        userStart(steer.runtimeText, steeringTime)
        receive(.assistantCompleted(UUID(), "Steering reply"))
        receive(.queue(.init()))
        userStart(follow.runtimeText, followUpTime)
        receive(.assistantCompleted(UUID(), "Follow-up reply"))
        receive(.settled(aborted: false))
        XCTAssertEqual(stored.map(\.id), [steer.id, follow.id])
        XCTAssertEqual(stored.map(\.messageTimestampMs), [steeringTime, followUpTime])

        let history = SessionController()
        let items: [HistoryItem] = [
            .init(id: "history:steer", kind: .user, text: steer.runtimeText, messageTimestampMs: steeringTime),
            .init(id: "history:follow", kind: .user, text: follow.runtimeText, messageTimestampMs: followUpTime),
        ]
        history.showHistory(items, recordedMessages: stored)
        XCTAssertEqual(history.transcript.map(\.editableText), [steer.text, follow.text])
        XCTAssertEqual(history.transcript.map(\.editableFiles), [steer.files, follow.files])

        let incorrect = stored.map { record in
            var incorrectRecord = record
            incorrectRecord.messageTimestampMs = record.id == steer.id ? followUpTime : steeringTime
            return incorrectRecord
        }
        history.showHistory(items, recordedMessages: incorrect)
        XCTAssertEqual(history.transcript.map(\.editableText), [steer.runtimeText, follow.runtimeText])
        XCTAssertEqual(history.transcript.map(\.editableFiles), [[], []])
        _ = await controller.disconnect()
    }

    @MainActor func testQueuedAcknowledgementBeforeOlderDequeueKeepsFollowUpIdentity() async {
        for firstMode in [SendMode.followUp, .steer] {
            var userStarts: [Int64: UUID] = [:]
            let replay = await replayAcknowledgementBeforeOlderDequeue(firstMode: firstMode) { id, timestamp in
                userStarts[timestamp] = id
            }
            let controller = replay.controller
            let timestamp: Int64 = 1_795_000_002_000
            controller.receive(.init(instanceID: replay.instanceID, event: .queue(.init())))
            controller.receive(.init(instanceID: replay.instanceID, event: .userMessageTimestamp(timestamp, text: replay.second.runtimeText)))
            controller.receive(.init(instanceID: replay.instanceID, event: .assistantCompleted(UUID(), "Second reply")))
            XCTAssertEqual(replay.secondRow.messageTimestampMs, timestamp)
            XCTAssertEqual(userStarts, [1_795_000_001_000: replay.first.id, timestamp: replay.second.id])
            let turns = controller.transcriptTurnStarts.map(\.turn.id)
            XCTAssertEqual(turns.count, firstMode == .steer ? 2 : 3)
            let replies = controller.transcript.filter { $0.kind == .assistant }.compactMap { $0.turn?.id }
            XCTAssertEqual(replies, firstMode == .steer ? Array(turns.prefix(1)) + turns : turns)
            _ = await controller.disconnect()
        }
    }

    @MainActor func testStopRecoversExactFollowUpAfterAcknowledgementOvertakesOlderDequeue() async {
        let replay = await replayAcknowledgementBeforeOlderDequeue(firstMode: .followUp)
        let controller = replay.controller
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: replay.instanceID, event: event)) }
        receive(.phase(.stopping))
        receive(.queue(.init()))
        receive(.recoveredDrafts(UUID(), [.init(text: replay.second.runtimeText, mode: .followUp)]))
        receive(.settled(aborted: true))
        XCTAssertEqual(replay.secondRow.delivery, .recovered)
        XCTAssertEqual(controller.recoveredDrafts, [
            .init(id: replay.second.id, text: replay.second.text, mode: .followUp, files: replay.second.files),
        ])
        controller.restoreDraft(replay.second.id)
        XCTAssertEqual(controller.draft, replay.second.text)
        XCTAssertEqual(controller.draftFiles, replay.second.files)
        XCTAssertEqual(controller.mode, .followUp)
        _ = await controller.disconnect()
    }

    @MainActor private func replayAcknowledgementBeforeOlderDequeue(
        firstMode: SendMode, onUserStart: (@MainActor (UUID?, Int64) -> Void)? = nil
    ) async -> (controller: SessionController, instanceID: UUID, first: UserPrompt, second: UserPrompt, secondRow: TranscriptItem) {
        let second = UserPrompt(text: "repeat", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/repeat.txt")])
        let first = firstMode == .followUp
            ? UserPrompt(text: second.text, mode: firstMode, files: second.files)
            : UserPrompt(text: "steering", mode: firstMode, files: [URL(fileURLWithPath: "/tmp/steering.txt")])
        let runtime = TranscriptQueueRuntime(delayedPrompt: second.id)
        let controller = SessionController()
        controller.onUserMessageTimestamp = onUserStart
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        receive(.assistantCompleted(UUID(), "Initial reply"))
        await controller.sendDraft(first)
        let firstQueue = firstMode == .steer ? RuntimeQueue(steering: [first.runtimeText]) : RuntimeQueue(followUp: [first.runtimeText])
        receive(.queue(firstQueue))
        let pending = Task { await controller.sendDraft(second) }
        await runtime.gate.waitForSend()
        await runtime.gate.acknowledge()
        await pending.value

        let users = controller.transcript.filter { $0.kind == .user }
        receive(.queue(firstQueue))
        XCTAssertEqual(users.map(\.delivery), [.accepted, .queued, .queued])
        receive(.queue(.init()))
        let timestamp: Int64 = 1_795_000_001_000
        receive(.userMessageTimestamp(timestamp, text: first.runtimeText))
        XCTAssertEqual(users.map(\.delivery), [.accepted, .accepted, .queued])
        XCTAssertEqual(users[1].messageTimestampMs, timestamp)
        XCTAssertNil(users[2].messageTimestampMs)
        receive(.queue(.init(followUp: [second.runtimeText])))
        receive(.assistantCompleted(UUID(), "First reply"))
        return (controller, runtime.instanceID, first, second, users[2])
    }

    @MainActor func testRecoveredInputDoesNotReturnToQueueOnLateAcknowledgement() async {
        let prompt = UserPrompt(text: "keep", mode: .followUp, files: [URL(fileURLWithPath: "/tmp/keep.txt")])
        let controller = SessionController()
        let runtime = TranscriptQueueRuntime(delayedPrompt: prompt.id)
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        await controller.sendDraft(.init(text: "initial"))
        let pending = Task { await controller.sendDraft(prompt) }
        await runtime.gate.waitForSend()
        receive(.phase(.stopping))
        receive(.queue(.init()))
        receive(.recoveredDrafts(UUID(), [.init(text: prompt.runtimeText, mode: .followUp)]))
        await runtime.gate.acknowledge()
        await pending.value
        receive(.settled(aborted: true))
        XCTAssertEqual(controller.transcript.last?.delivery, .recovered)
        XCTAssertEqual(controller.recoveredDrafts.first?.id, prompt.id)
        XCTAssertEqual(controller.recoveredDrafts.first?.files, prompt.files)
        XCTAssertEqual(controller.transcriptTurnStarts.count, 1)
        _ = await controller.disconnect()
    }

    @MainActor func testWorkspacePersistsEarlyTimestampOnlyForItsSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = UserPrompt(text: "initial")
        let follow = UserPrompt(text: "follow", mode: .followUp, files: [root.appendingPathComponent("follow.txt")])
        let runtime = TranscriptQueueRuntime(delayedPrompt: follow.id)
        let store = TranscriptWorkspaceStore()
        let workspace = WorkspaceController(store: store, reader: PiHistoryReader(roots: [])) { _, _ in runtime }
        await workspace.start()
        _ = await workspace.addProject(root)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        await workspace.send(sessionID, submitted: initial)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        receive(.assistantCompleted(UUID(), "Initial reply without a timestamp"))

        let pending = Task { await workspace.send(sessionID, submitted: follow) }
        await runtime.gate.waitForSend()
        receive(.queue(.init(followUp: [follow.runtimeText])))
        receive(.queue(.init()))
        let timestamp: Int64 = 1_795_000_003_000
        receive(.userMessageTimestamp(timestamp, text: follow.runtimeText))
        XCTAssertNil(workspace.selected?.recordedMessages?.first { $0.id == initial.id }?.messageTimestampMs)
        await runtime.gate.acknowledge()
        await pending.value
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)

        let snapshot = await store.load()
        let messages = try XCTUnwrap(snapshot.sessions.first { $0.id == sessionID }?.recordedMessages)
        XCTAssertNil(messages.first { $0.id == initial.id }?.messageTimestampMs)
        XCTAssertEqual(messages.first { $0.id == follow.id }?.messageTimestampMs, timestamp)
        XCTAssertEqual(messages.first { $0.id == follow.id }?.files, follow.files)
        _ = await controller.disconnect()
    }

    @MainActor func testStopInterleavedWithBufferedDequeuePreservesFirstAndRecoversSecond() async {
        for dequeueBeforeStop in [true, false] {
            let attachment = URL(fileURLWithPath: "/tmp/stop-interleave.txt")
            let first = UserPrompt(text: "repeat", mode: .followUp, files: [attachment])
            let second = UserPrompt(text: "repeat", mode: .followUp, files: [attachment])
            let firstTime: Int64 = 1_795_000_004_000
            let runtime = StopInterleaveRuntime()
            let controller = SessionController()
            var recordedStarts: [Int64: UUID] = [:]
            controller.onUserMessageTimestamp = { id, ts in
                if let id { recordedStarts[ts] = id }
            }
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) {
                controller.receive(.init(instanceID: runtime.instanceID, event: event))
            }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) {
                raw(["type": "queue_update", "steering": [String](), "followUp": followUp])
            }
            func previousDequeue() {
                queue([second.runtimeText])
                raw(["type": "message_start", "message": [
                    "role": "user", "timestamp": firstTime,
                    "content": [["type": "text", "text": first.runtimeText]],
                ]])
            }
            func row(_ prompt: UserPrompt) -> TranscriptItem? {
                controller.transcript.first { $0.id == "user:\(prompt.id)" }
            }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])
            await controller.sendDraft(second)
            queue([first.runtimeText, second.runtimeText])
            if dequeueBeforeStop { previousDequeue() }
            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            if !dequeueBeforeStop { previousDequeue() }
            queue([])
            receive(.recoveredDrafts(UUID(), [.init(text: second.runtimeText, mode: .followUp)]))
            raw(["type": "agent_settled", "aborted": true])
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(row(first)?.delivery, .accepted)
            XCTAssertEqual(row(first)?.messageTimestampMs, firstTime)
            XCTAssertEqual(recordedStarts, [firstTime: first.id])
            XCTAssertEqual(row(second)?.delivery, .recovered)
            XCTAssertEqual(controller.recoveredDrafts, [
                .init(id: second.id, text: second.text, mode: .followUp, files: second.files),
            ])

            await controller.sendDraft(.init(text: "fresh execution"))
            receive(.assistantCompleted(UUID(), "Fresh reply"))
            let freshTurn = controller.activeTurn?.id
            let third = UserPrompt(text: "next queued", mode: .followUp)
            await controller.sendDraft(third)
            queue([third.runtimeText])
            XCTAssertEqual(controller.activeTurn?.id, freshTurn)
            _ = await controller.disconnect(force: true)
        }
    }

    @MainActor func testStopRecoveryOrderAndSingleQueuedDequeueAndAbortFailure() async {
        // 1. recoveredDrafts arrives before buffered queue/user-start events drain.
        do {
            let file1 = URL(fileURLWithPath: "/tmp/first.txt")
            let file2 = URL(fileURLWithPath: "/tmp/second.txt")
            let first = UserPrompt(text: "same", mode: .followUp, files: [file1])
            let second = UserPrompt(text: "same", mode: .followUp, files: [file2])
            let firstTime: Int64 = 1_795_000_005_000
            let runtime = StopInterleaveRuntime()
            let controller = SessionController()
            var recordedStarts: [Int64: UUID] = [:]
            controller.onUserMessageTimestamp = { id, ts in
                if let id { recordedStarts[ts] = id }
            }
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) { raw(["type": "queue_update", "steering": [String](), "followUp": followUp]) }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])
            await controller.sendDraft(second)
            queue([first.runtimeText, second.runtimeText])

            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            receive(.recoveredDrafts(UUID(), [.init(text: second.runtimeText, mode: .followUp)]))
            queue([second.runtimeText])
            raw(["type": "message_start", "message": [
                "role": "user", "timestamp": firstTime,
                "content": [["type": "text", "text": first.runtimeText]],
            ]])
            queue([])
            raw(["type": "agent_settled", "aborted": true])
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.delivery, .accepted)
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.messageTimestampMs, firstTime)
            XCTAssertEqual(recordedStarts, [firstTime: first.id])
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(second.id)" }?.delivery, .recovered)
            XCTAssertEqual(controller.recoveredDrafts, [
                .init(id: second.id, text: second.text, mode: .followUp, files: second.files),
            ])
            _ = await controller.disconnect(force: true)
        }

        // 2. Single queued item dequeued right before stop (empty buffered queue_update) and abort failure.
        for stopFailure in [false, true] {
            let file = URL(fileURLWithPath: "/tmp/single.txt")
            let first = UserPrompt(text: "only", mode: .followUp, files: [file])
            let firstTime: Int64 = 1_795_000_006_000
            let runtime = StopInterleaveRuntime(stopFailure: stopFailure)
            let controller = SessionController()
            await controller.connect(runtime)
            var mapper = PiEventMapper()
            func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
            func raw(_ record: [String: Any]) { mapper.map(record).forEach(receive) }
            func queue(_ followUp: [String]) { raw(["type": "queue_update", "steering": [String](), "followUp": followUp]) }

            await controller.sendDraft(.init(text: "initial"))
            receive(.assistantCompleted(UUID(), "Initial reply"))
            await controller.sendDraft(first)
            queue([first.runtimeText])

            let stop = Task { await controller.stop() }
            await runtime.gate.waitForStop()
            receive(.phase(.stopping))
            queue([])
            raw(["type": "message_start", "message": [
                "role": "user", "timestamp": firstTime,
                "content": [["type": "text", "text": first.runtimeText]],
            ]])
            receive(.recoveredDrafts(UUID(), []))
            if !stopFailure { raw(["type": "agent_settled", "aborted": true]) }
            await runtime.gate.finishStop()
            await stop.value

            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.delivery, .accepted)
            XCTAssertEqual(controller.transcript.first { $0.id == "user:\(first.id)" }?.messageTimestampMs, firstTime)
            XCTAssertTrue(controller.recoveredDrafts.isEmpty)
            XCTAssertEqual(controller.phase, stopFailure ? .uncertain : .idle)
            _ = await controller.disconnect(force: true)
        }
    }

    func testMarkdownFileLinksEnrichWorkspacePathsInlineCodeRelativeLinksAndPreserveCodeBlocks() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Pikachu/Features/Composer"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("dir with space"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let readme = workspace.appendingPathComponent("README.md").standardizedFileURL
        let composer = workspace.appendingPathComponent("Pikachu/Features/Composer/ComposerView.swift").standardizedFileURL
        let spaced = workspace.appendingPathComponent("dir with space/note.txt").standardizedFileURL
        try Data("# README\n".utf8).write(to: readme)
        try Data("struct ComposerView {}\n".utf8).write(to: composer)
        try Data("hello\n".utf8).write(to: spaced)

        let markdown = """
        - Pikachu/Features/Composer/ComposerView.swift: updated mapping
        - Check `README.md` and `dir with space/note.txt:42` and 在Pikachu/Features/Composer/ComposerView.swift中
        - See [Composer](Pikachu/Features/Composer/ComposerView.swift#L12) and missing/file.swift and v1.0
        - Web URL https://example.com/Pikachu/Features/Composer/ComposerView.swift

        | File | Notes |
        | --- | --- |
        | README.md | ok |

        ```
        Pikachu/Features/Composer/ComposerView.swift
        ```
        """

        let blocks = MarkdownBlocks.parse(markdown, workspaceDirectory: workspace)
        XCTAssertEqual(blocks.count, 3)

        guard case .list(_, let items) = blocks[0].kind else {
            return XCTFail("Expected bullet list")
        }
        XCTAssertEqual(items.count, 4)

        let firstRuns = items[0].blocks[0].content.runs.filter { $0.link != nil }
        XCTAssertEqual(firstRuns.map { String(items[0].blocks[0].content[$0.range].characters) },
                       ["Pikachu/Features/Composer/ComposerView.swift"])
        XCTAssertEqual(firstRuns.first?.link?.path, composer.path)

        let secondContent = items[1].blocks[0].content
        let secondLinks = secondContent.runs.compactMap { run -> (String, URL)? in
            guard let link = run.link else { return nil }
            return (String(secondContent[run.range].characters), link)
        }
        XCTAssertEqual(secondLinks.map(\.0), [
            "README.md",
            "dir with space/note.txt:42",
            "Pikachu/Features/Composer/ComposerView.swift"
        ])
        XCTAssertEqual(secondLinks[0].1.path, readme.path)
        XCTAssertEqual(secondLinks[1].1.path, spaced.path)
        XCTAssertEqual(secondLinks[1].1.fragment, "L42")
        XCTAssertEqual(secondLinks[2].1.path, composer.path)

        let thirdContent = items[2].blocks[0].content
        let thirdLinks = thirdContent.runs.compactMap { run -> (String, URL)? in
            guard let link = run.link else { return nil }
            return (String(thirdContent[run.range].characters), link)
        }
        XCTAssertEqual(thirdLinks.map(\.0), ["Composer"])
        XCTAssertEqual(thirdLinks[0].1.path, composer.path)
        XCTAssertEqual(thirdLinks[0].1.fragment, "L12")

        let fourthLinks = items[3].blocks[0].content.runs.compactMap(\.link)
        XCTAssertEqual(fourthLinks.map(\.scheme), ["https"])

        guard case .table(let table) = blocks[1].kind else {
            return XCTFail("Expected table")
        }
        let tableLink = table.rows[1].cells[0].runs.compactMap(\.link).first
        XCTAssertEqual(tableLink?.path, readme.path)

        guard case .code = blocks[2].kind else {
            return XCTFail("Expected fenced code block")
        }
    }

    @MainActor func testTranscriptFileLinksOpenableURLAndCacheInvalidation() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Pikachu"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let target = workspace.appendingPathComponent("Pikachu/App.swift").standardizedFileURL
        try Data("struct App {}\n".utf8).write(to: target)

        let withFragment = URL(string: target.absoluteString + "#L10-L20")!
        XCTAssertEqual(TranscriptFileLinks.openableFileURL(for: withFragment, workspaceDirectory: workspace), target)

        let relative = URL(string: "Pikachu/App.swift#L8")!
        XCTAssertEqual(TranscriptFileLinks.openableFileURL(for: relative, workspaceDirectory: workspace), target)

        let web = URL(string: "https://example.com/Pikachu/App.swift")!
        XCTAssertNil(TranscriptFileLinks.openableFileURL(for: web, workspaceDirectory: workspace))

        let missing = workspace.appendingPathComponent("Pikachu/Missing.swift")
        XCTAssertNil(TranscriptFileLinks.openableFileURL(for: missing, workspaceDirectory: workspace))

        let cache = MarkdownContentCache()
        let withoutWorkspace = cache.layout(for: "See Pikachu/App.swift", typography: .init(), workspaceDirectory: nil)
        XCTAssertTrue(withoutWorkspace.blocks[0].content.runs.compactMap(\.link).isEmpty)

        let withWorkspace = cache.layout(for: "See Pikachu/App.swift", typography: .init(), workspaceDirectory: workspace)
        XCTAssertEqual(withWorkspace.blocks[0].content.runs.compactMap(\.link).map(\.path), [target.path])
    }

    @MainActor func testTranscriptFileOpenerRevealsFilesWithoutAnApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Catalog.xcassets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Directories and files without a default app are revealed rather than launched.
        XCTAssertEqual(TranscriptFileOpener.destination(for: root), .revealInFinder(root))
        XCTAssertEqual(TranscriptFileOpener.destination(for: root.appendingPathComponent("Catalog.xcassets")),
                       .revealInFinder(root.appendingPathComponent("Catalog.xcassets")))
        let orphan = root.appendingPathComponent("output.pikachuunmapped")
        try Data("x".utf8).write(to: orphan)
        XCTAssertEqual(TranscriptFileOpener.destination(for: orphan), .revealInFinder(orphan))
        XCTAssertEqual(TranscriptFileOpener.destination(for: root.appendingPathComponent("Missing.swift")), .unsupported)

        // A click on an unresolved relative reference is swallowed instead of reaching Launch Services.
        XCTAssertEqual(TranscriptFileOpener.clickedLink(for: URL(string: "Pikachu/Missing.swift:12")!,
                                                        workspaceDirectory: root), .ignored)
        XCTAssertEqual(TranscriptFileOpener.clickedLink(for: URL(string: "https://example.com")!,
                                                        workspaceDirectory: root), .system)
        XCTAssertEqual(TranscriptFileOpener.clickedLink(for: URL(string: "slack://channel")!,
                                                        workspaceDirectory: root), .ignored)
        let catalog = root.appendingPathComponent("Catalog.xcassets")
        XCTAssertEqual(TranscriptFileOpener.clickedLink(for: catalog, workspaceDirectory: root), .file(catalog, line: nil))
        var opened: [URL] = []
        let handled = TranscriptFileOpener.openAction(workspaceDirectory: root, openFile: { opened.append($0) })
        handled(catalog)
        XCTAssertEqual(opened, [catalog])
    }

    func testTranscriptFileLinksCarryTheirLineAndUseTheChosenOpener() throws {
        let file = URL(fileURLWithPath: "/tmp/Pikachu/App.swift")
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: file.absoluteString + "#L12-L20")!), 12)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: file.absoluteString + "#L7")!), 7)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: "Pikachu/App.swift:9")!), 9)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: "Pikachu/App.swift:9:3")!), 9)
        XCTAssertNil(TranscriptFileOpener.lineReference(in: URL(string: "Pikachu/App.swift")!))

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-xcode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let xcode = sandbox.appendingPathComponent("Xcode.app", isDirectory: true)
        let xed = xcode.appendingPathComponent("Contents/Developer/usr/bin/xed")
        try FileManager.default.createDirectory(at: xed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: xed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xed.path)
        let vscode = sandbox.appendingPathComponent("Visual Studio Code.app", isDirectory: true)
        let codeCLI = vscode.appendingPathComponent("Contents/Resources/app/bin/code")
        try FileManager.default.createDirectory(at: codeCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: codeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeCLI.path)
        let vscodeWithoutCLI = sandbox.appendingPathComponent("VSCodeNoCLI.app", isDirectory: true)
        func plan(_ preference: FileOpenPreference, line: Int? = 12, custom: String = "",
                  xcode: URL? = xcode,
                  vscode: URL? = vscode) -> FileOpenPlan {
            FileOpenConfiguration.plan(for: file, line: line,
                                       configuration: .init(preference: preference, customCommand: custom),
                                       xcode: xcode, visualStudioCode: vscode)
        }

        XCTAssertEqual(plan(.system), .system)
        XCTAssertEqual(plan(.xcode, xcode: nil), .system)
        XCTAssertEqual(plan(.xcode, line: 12, xcode: xcode), .run(.init(
            executable: xed, arguments: ["--line", "12", file.path])))
        XCTAssertEqual(plan(.xcode, line: nil, xcode: xcode), .run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-b", "com.apple.dt.Xcode", file.path])))
        XCTAssertEqual(plan(.visualStudioCode, line: 12, vscode: nil), .system)
        XCTAssertEqual(plan(.visualStudioCode, line: nil, vscode: vscode), .run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-b", "com.microsoft.VSCode", file.path])))
        XCTAssertEqual(plan(.visualStudioCode, vscode: vscode), .run(.init(
            executable: codeCLI, arguments: ["-g", "\(file.path):12"])))
        XCTAssertEqual(plan(.visualStudioCode, vscode: vscodeWithoutCLI), .run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-b", "com.microsoft.VSCode", "--args", "-g", "\(file.path):12"])))
        XCTAssertEqual(FileOpenConfiguration.customScript("code -g {path}:{line}", path: "/tmp/a b.swift", line: 3),
                       "code -g '/tmp/a b.swift':3")
        XCTAssertEqual(FileOpenConfiguration.customScript("code -g {path}:{line}", path: "/tmp/a b.swift", line: nil),
                       "code -g '/tmp/a b.swift'")
        XCTAssertEqual(FileOpenConfiguration.customScript("code -g {path}:{line}", path: "/tmp/{line}/a.swift", line: 3),
                       "code -g '/tmp/{line}/a.swift':3")
        XCTAssertEqual(FileOpenConfiguration.customScript("open {path}", path: "/tmp/it's.swift", line: nil),
                       "open '/tmp/it'\\''s.swift'")
        XCTAssertEqual(plan(.custom, custom: "  "), .system)
        XCTAssertEqual(plan(.custom, custom: "true"), .run(.init(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "true"])))
    }

    @MainActor private func tool(_ id: String, state: ToolState) -> TranscriptItem {
        .init(id: id, kind: .tool, tool: .init(id: id, name: "read", arguments: "arguments for \(id)", output: "output from \(id)", state: state))
    }
}

private actor TranscriptWorkspaceStore: WorkspaceStore {
    private var snapshot = WorkspaceSnapshot()

    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private actor TranscriptAcknowledgementGate {
    private var sender: CheckedContinuation<Void, Never>?
    private var acknowledgement: CheckedContinuation<PromptDisposition, Never>?

    func waitForSend() async {
        if acknowledgement != nil { return }
        await withCheckedContinuation { sender = $0 }
    }

    func suspendSend() async -> PromptDisposition {
        await withCheckedContinuation {
            acknowledgement = $0
            sender?.resume()
            sender = nil
        }
    }

    func acknowledge() {
        acknowledgement?.resume(returning: .queued)
        acknowledgement = nil
    }
}

private final class TranscriptQueueRuntime: AgentRuntime, Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let gate = TranscriptAcknowledgementGate()
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    private let delayedPrompt: UUID?

    init(delayedPrompt: UUID? = nil) {
        self.delayedPrompt = delayedPrompt
        let stream = AsyncStream<RuntimeEnvelope>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: "transcript-queue", model: "fixture", thinking: "none", capabilities: [.queuedPrompts])
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        if prompt.id == delayedPrompt { return await gate.suspendSend() }
        return prompt.text == "initial" ? .started : .queued
    }

    func stop() async throws {}
    func close(force: Bool) async throws { continuation.finish() }
}

private actor StopInterleaveGate {
    private var waitForEntry: CheckedContinuation<Void, Never>?
    private var waitForCompletion: CheckedContinuation<Void, Never>?

    func waitForStop() async {
        if waitForCompletion != nil { return }
        await withCheckedContinuation { waitForEntry = $0 }
    }

    func pauseStop() async {
        await withCheckedContinuation {
            waitForCompletion = $0
            waitForEntry?.resume()
            waitForEntry = nil
        }
    }

    func finishStop() {
        waitForCompletion?.resume()
        waitForCompletion = nil
    }
}

private final class StopInterleaveRuntime: AgentRuntime, Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let gate = StopInterleaveGate()
    private let stopFailure: Bool
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation

    init(stopFailure: Bool = false) {
        self.stopFailure = stopFailure
        let stream = AsyncStream<RuntimeEnvelope>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: "stop-interleave", model: "fixture", thinking: "none", capabilities: [.queuedPrompts])
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        prompt.mode == .followUp ? .queued : .started
    }

    func stop() async throws {
        await gate.pauseStop()
        if stopFailure { throw RuntimeFailure(.outcomeUnknown, "abort timed out") }
    }

    func close(force: Bool) async throws { continuation.finish() }
}
