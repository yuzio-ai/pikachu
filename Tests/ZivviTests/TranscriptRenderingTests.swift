import XCTest
import SwiftUI
import os
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

final class TranscriptRenderingTests: XCTestCase {
    @MainActor func testReplayedInputDoesNotInheritAnotherInputsOutcomeFromTheSameLiveTurn() async throws {
        let firstID = UUID(), secondID = UUID()
        let messages = [
            RecordedMessageRecord(id: firstID, text: "Start", messageTimestampMs: 100),
            RecordedMessageRecord(id: secondID, text: "Add a detail", messageTimestampMs: 200),
        ]
        let items: [HistoryItem] = [
            .init(id: "first-user", kind: .user, text: "Start", messageTimestampMs: 100),
            .init(id: "first-reply", kind: .assistant, text: "First part"),
            .init(id: "second-user", kind: .user, text: "Add a detail", messageTimestampMs: 200),
            .init(id: "second-reply", kind: .assistant, text: "Second part"),
        ]
        var local = RecordedTurnRecord(anchorUserTimestampMs: 100, status: .completed)
        local.modelSubmissionID = firstID
        let controller = SessionController()
        controller.showHistory(items, turns: [
            .init(id: "turn", itemIDs: ["first-reply", "second-reply"], firstUserTimestampMs: 100, status: .completed),
        ], recordedTurns: [local], recordedMessages: messages)
        let initial = controller.transcript.filter { $0.kind == .assistant }.compactMap(\.turn)
        XCTAssertEqual(initial.count, 2)
        XCTAssertTrue(initial.first === initial.last)

        let runtime = FakeRuntime()
        await controller.connect(runtime, recordedMessages: messages)
        controller.receive(.init(instanceID: runtime.instanceID, event: .historyReplayed(items)))
        let replayed = controller.transcript.filter { $0.kind == .assistant }.compactMap(\.turn)
        XCTAssertEqual(replayed.map(\.status), [.completed, .uncertain])
        XCTAssertEqual(replayed.map(\.isHistoricalOutcomeMissing), [false, true])
        _ = await controller.disconnect()
    }

    @MainActor func testHistoryRestoresTimingAndChangesFromTheSameRecordAsTheOutcome() throws {
        let firstID = UUID(), secondID = UUID()
        let firstChanges = TurnFileChanges(files: [.init(path: "first.swift", kind: .modified, added: 1, deleted: 1)])
        let secondChanges = TurnFileChanges(files: [.init(path: "second.swift", kind: .modified, added: 2, deleted: 1)])
        let unrelatedChanges = TurnFileChanges(files: [.init(path: "unrelated.swift", kind: .added, added: 1, deleted: 0)])
        let firstEnd = Date(timeIntervalSince1970: 1_795_000_000)
        let secondEnd = firstEnd.addingTimeInterval(15)
        var first = RecordedTurnRecord(endedAt: firstEnd, durationSeconds: 3, status: .failed, fileChanges: firstChanges)
        var second = RecordedTurnRecord(endedAt: secondEnd, durationSeconds: 8, status: .completed, fileChanges: secondChanges)
        first.modelSubmissionID = firstID
        second.modelSubmissionID = secondID
        let controller = SessionController()
        controller.showCachedHistory([
            .init(id: "request-one", kind: .user, text: "First request", submissionID: firstID),
            .init(id: "reply-one", kind: .assistant, text: "First reply"),
            .init(id: "request-two", kind: .user, text: "Second request", submissionID: secondID),
            .init(id: "reply-two", kind: .assistant, text: "Second reply"),
            .init(id: "unanchored", kind: .user, text: "Imported request"),
            .init(id: "unanchored-reply", kind: .assistant, text: "Imported reply"),
        ], recordedTurns: [second, first, .init(status: .completed, fileChanges: unrelatedChanges)])

        let turns = controller.transcript.filter { $0.kind == .assistant }.compactMap(\.turn)
        XCTAssertEqual(turns.map(\.status), [.failed, .completed, .uncertain])
        XCTAssertEqual(turns.map(\.endedAt), [firstEnd, secondEnd, nil])
        XCTAssertEqual(turns.map(\.durationSeconds), [3, 8, nil])
        XCTAssertEqual(turns.map(\.fileChanges), [firstChanges, secondChanges, nil])
    }

    @MainActor func testCachedAndFrozenMessagesPreserveDeliveryForBrandMarkers() throws {
        let pending = UserPrompt(text: "Unconfirmed request")
        var submission = SubmissionRecord(pending)
        submission.delivery = .unknown
        var prematureTurn = RecordedTurnRecord(status: .completed)
        prematureTurn.modelSubmissionID = pending.id
        let cache: [CachedTranscriptItem] = [
            .init(id: "user:\(pending.id)", kind: .user, text: pending.text),
            .init(id: "uncertain-reply", kind: .assistant, text: "Unattributed reply"),
            .init(id: "queued", kind: .user, text: "Waiting request", delivery: .queued),
            .init(id: "recovered", kind: .user, text: "Recovered request", delivery: .recovered),
            .init(id: "accepted", kind: .user, text: "Accepted request"),
        ]
        let cached = try JSONDecoder().decode([CachedTranscriptItem].self, from: JSONEncoder().encode(cache))
        let controller = SessionController()
        controller.showCachedHistory(cached, recordedTurns: [prematureTurn], submissions: [submission])
        XCTAssertTrue(try XCTUnwrap(controller.transcript.first { $0.kind == .assistant }?.turn).isHistoricalOutcomeMissing)
        let snapshot = SessionHistorySnapshot(transcript: controller.transcript, coverage: .partial)
        let restored = try JSONDecoder().decode(SessionHistorySnapshot.self, from: JSONEncoder().encode(snapshot))
        for rows in [controller.transcript, restored.timeline().items] {
            let deliveries = rows.filter { $0.kind == .user }.map(\.delivery)
            XCTAssertEqual(deliveries, [.unknown, .queued, .recovered, .accepted])
            XCTAssertEqual(deliveries.map(\.showsBrandMessageMarker), [false, false, false, true])
        }
    }

    @MainActor func testFrozenTranscriptPreservesImageOnlyMessages() throws {
        let image = Data([1, 2, 3])
        let source = SessionController()
        source.showHistory([
            .init(id: "user-image", kind: .user, images: [image]),
            .init(id: "reply-image", kind: .assistant, images: [image]),
        ])
        let snapshot = SessionHistorySnapshot(transcript: source.transcript, coverage: .available)
        let restored = try JSONDecoder().decode(SessionHistorySnapshot.self, from: JSONEncoder().encode(snapshot)).timeline()
        XCTAssertEqual(restored.items.map(\.id), ["user-image", "reply-image"])
        XCTAssertEqual(restored.items.map { $0.images.map(\.data) }, [[image], [image]])
        XCTAssertEqual(restored.rows.compactMap { row in
            if case .item(let item) = row { return item.id }
            return nil
        }, ["user-image", "reply-image"])
    }

    func testReplayImageDeduplicationKeepsDistinctLocalAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replayed = Data([1, 2, 3])
        let duplicate = directory.appendingPathComponent("replayed.png")
        let anotherCopy = directory.appendingPathComponent("same-bytes.png")
        let additional = directory.appendingPathComponent("additional.png")
        let missing = directory.appendingPathComponent("missing.png")
        try replayed.write(to: duplicate)
        try replayed.write(to: anotherCopy)
        try Data([3, 2, 1]).write(to: additional)
        XCTAssertEqual(TranscriptImageFiles.duplicates(in: [duplicate, additional, anotherCopy, missing], images: [replayed]),
                       [duplicate])
    }

    @MainActor func testOpenToolOutputTracksReplacementAndClear() {
        let item = TranscriptItem(id: "tool", kind: .tool,
                                  tool: .init(id: "tool", name: "bash", output: "Old output", truncated: true))
        let opened = ToolOutputSelection(item: item)
        XCTAssertEqual(opened.output, "Old output")
        XCTAssertTrue(opened.truncated)
        item.tool = .init(id: "tool", name: "bash", output: "Replacement")
        XCTAssertEqual(opened.output, "Replacement")
        XCTAssertFalse(opened.truncated)
        item.tool?.output = ""
        XCTAssertEqual(opened.output, "")
    }

    @MainActor func testOpenToolImageIsInvalidatedWhenResultChangesOrClears() {
        let data = Data([1, 2, 3])
        var tool = RuntimeTool(id: "tool", name: "read")
        tool.outputImage = data
        let item = TranscriptItem(id: "tool", kind: .tool, tool: tool)
        let standalone = ImagePreviewSelection.embedded(data, name: "Old")
        let opened = standalone.trackingToolOutput(item)
        XCTAssertTrue(opened.isCurrent)
        item.tool?.outputImage = Data([4, 5, 6])
        XCTAssertFalse(opened.isCurrent)
        let replacement = ImagePreviewSelection.embedded(Data([4, 5, 6]), name: "New").trackingToolOutput(item)
        XCTAssertTrue(replacement.isCurrent)
        item.tool?.outputImage = nil
        XCTAssertFalse(replacement.isCurrent)
        XCTAssertTrue(standalone.isCurrent)
    }

    @MainActor func testOpenToolOutputAndImageAreInvalidatedWhenReplayReplacesTheirRow() {
        let image = Data([1, 2, 3])
        var tool = RuntimeTool(id: "tool", name: "read", output: "Old output")
        tool.outputImage = image
        let row = TranscriptItem(id: "tool", kind: .tool, tool: tool)
        let session = SessionPresentation(id: UUID())
        session.setFrozenTranscript([row], rows: [], segmentIDs: [])
        let includesItem: ToolResultSource.Validator = { item in
            session.frozenTranscript.contains { $0 === item }
        }
        var output = ToolOutputSelection(item: row)
        output.source.includesItem = includesItem
        var preview = ImagePreviewSelection.embedded(image, name: "Old").trackingToolOutput(row)
        preview.toolResult?.includesItem = includesItem
        XCTAssertEqual(output.output, "Old output")
        XCTAssertTrue(preview.isCurrent)

        session.setFrozenTranscript([TranscriptItem(id: row.id, kind: .tool)], rows: [], segmentIDs: [])
        XCTAssertEqual(output.output, "")
        XCTAssertFalse(preview.isCurrent)
    }

    @MainActor func testHistoryOutcomeRequiresAUniqueAnchorAndSurvivesFreezing() throws {
        let endedAt = Date(timeIntervalSince1970: 1_795_000_000)
        let submission = UUID()
        var uncertain = RecordedTurnRecord(status: .uncertain)
        uncertain.modelSubmissionID = submission
        let items: [CachedTranscriptItem] = [
            .init(id: "user-1", kind: .user, text: "Live request"),
            .init(id: "assistant:\(UUID())", kind: .assistant, text: "Known completion", endedAt: endedAt),
            .init(id: "user-2", kind: .user, text: "Unknown execution result", submissionID: submission),
            .init(id: "assistant-2", kind: .assistant, text: "The runtime disconnected"),
            .init(id: "user-3", kind: .user, text: "Imported request"),
            .init(id: "acp-replay-3", kind: .assistant, text: "Historical reply", endedAt: endedAt),
            .init(id: "user-4", kind: .user, text: "Ambiguous tool record"),
            .init(id: "tool", kind: .tool, tool: .init(id: "shared", name: "read", state: .completed)),
            .init(id: "assistant-4", kind: .assistant, text: "Ambiguous outcome"),
        ]
        let controller = SessionController()
        controller.showCachedHistory(items, recordedTurns: [
            .init(endedAt: endedAt, status: .completed), uncertain,
            .init(anchorToolCallID: "shared", status: .completed),
            .init(anchorToolCallID: "shared", status: .failed),
        ])
        func assertOutcomes(_ items: [TranscriptItem]) {
            let turns = items.filter { $0.kind == .assistant }.compactMap(\.turn)
            XCTAssertEqual(turns.map(\.status), [.completed, .uncertain, .uncertain, .uncertain])
            XCTAssertEqual(turns.map(\.isHistoricalOutcomeMissing), [false, false, true, true])
        }
        assertOutcomes(controller.transcript)
        let snapshot = SessionHistorySnapshot(transcript: controller.transcript, coverage: .partial)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionHistorySnapshot.self, from: encoded)
        assertOutcomes(decoded.timeline().items)

        // Older frozen snapshots recorded synthesized outcomes as completed.
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let oldTurns = try XCTUnwrap(legacyJSON["turns"] as? [[String: Any]])
        legacyJSON["turns"] = try oldTurns.map { turn in
            var legacy = turn
            if legacy.removeValue(forKey: "outcomeMissing") as? Bool == true {
                var record = try XCTUnwrap(legacy["record"] as? [String: Any])
                record["status"] = "completed"
                legacy["record"] = record
            }
            return legacy
        }
        let savedFailure = RecordedTurnRecord(anchorToolCallID: "shared", status: .failed)
        legacyJSON["fileChangeRecords"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([savedFailure]))
        let legacy = try JSONDecoder().decode(SessionHistorySnapshot.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        let legacyItems = legacy.timeline().items
        let legacyImported = try XCTUnwrap(legacyItems.first { $0.id == "acp-replay-3" }?.turn)
        XCTAssertTrue(legacyImported.isHistoricalOutcomeMissing)
        XCTAssertEqual(legacyImported.status, .uncertain)
        let legacyFailed = try XCTUnwrap(legacyItems.first { $0.id == "assistant-4" }?.turn)
        XCTAssertEqual(legacyFailed.status, .failed)
        XCTAssertFalse(legacyFailed.isHistoricalOutcomeMissing)

        let summary = TurnHeaderSummary(turn: legacyImported, locale: Locale(identifier: "en"))
        XCTAssertEqual(summary.title, "")
        XCTAssertEqual(summary.displayText, "Historical outcome not recorded")
        XCTAssertNil(summary.accessibilityValue)
        XCTAssertEqual(TurnHeaderSummary(turn: legacyImported, locale: Locale(identifier: "zh-Hans")).displayText, "历史结果未记录")
    }

    func testLegacyHandoffSummaryKeepsRequestAndPathsSeparate() {
        let paths = (1...8).map { "Sources/Module \($0).swift" }
        let context = "最近的用户请求\n继续\n\n相关文件\n" + paths.joined(separator: "\n")
        let summary = LegacyHandoffSummary(context: context)
        XCTAssertEqual(summary.request, "继续")
        XCTAssertNil(summary.reply)
        XCTAssertNil(summary.excerpt)
        XCTAssertEqual(summary.relatedPaths, paths)

        let pathWithTrailingSpace = LegacyHandoffSummary(context: "相关文件\nSources/Exact name.swift ")
        XCTAssertEqual(pathWithTrailingSpace.relatedPaths, ["Sources/Exact name.swift "])

        let english = LegacyHandoffSummary(context: """
        Latest user request
        Continue the work

        Keep this paragraph

        Latest agent response
        Finished the first step

        Related files
        README
        Sources/A.swift
        README
        """.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(english.request, "Continue the work\n\nKeep this paragraph")
        XCTAssertEqual(english.reply, "Finished the first step")
        XCTAssertEqual(english.relatedPaths, ["README", "Sources/A.swift"])
    }

    func testLegacyHandoffSummaryTreatsUnrecognizedFileSectionAsText() {
        let text = "Custom notes\n\nRelated files\nCheck the build after the next edit."
        let summary = LegacyHandoffSummary(context: text)
        XCTAssertEqual(summary.excerpt, text)
        XCTAssertTrue(summary.relatedPaths.isEmpty)
    }

    @MainActor func testLegacyHandoffFileListExpandsInTheTimeline() throws {
        let disclosure = HandoffRowExpansion()
        let shortID = UUID(), eightID = UUID(), manyID = UUID()
        let shortDetails = disclosure.binding(for: shortID)
        let eightDetails = disclosure.binding(for: eightID)
        let manyDetails = disclosure.binding(for: manyID)
        let eightFiles = disclosure.filesBinding(for: eightID)
        let manyFiles = disclosure.filesBinding(for: manyID)

        func height(_ count: Int, id: UUID, request: String = "继续") throws -> Int {
            let paths = (1...count).map { "Modules/OrchestrationCore/File\($0).swift" }
            return try legacyHandoffHeight(paths: paths, id: id, disclosure: disclosure, request: request)
        }

        let collapsed = try height(8, id: eightID)
        shortDetails.wrappedValue = true
        eightDetails.wrappedValue = true
        manyDetails.wrappedValue = true
        let one = try height(1, id: shortID)
        let three = try height(3, id: shortID)
        let preview = try height(8, id: eightID)
        XCTAssertGreaterThan(one, collapsed)
        XCTAssertGreaterThan(three, one)
        XCTAssertGreaterThan(preview, three)
        XCTAssertEqual(try height(30, id: manyID), preview)

        eightFiles.wrappedValue = true
        let expandedEight = try height(8, id: eightID)
        XCTAssertGreaterThan(expandedEight, preview)
        XCTAssertEqual(try height(30, id: manyID), preview)

        manyFiles.wrappedValue = true
        let expandedMany = try height(30, id: manyID)
        XCTAssertGreaterThan(expandedMany, expandedEight)
        eightFiles.wrappedValue = false
        XCTAssertEqual(try height(8, id: eightID), preview)

        manyDetails.wrappedValue = false
        XCTAssertEqual(try height(30, id: manyID), collapsed)
        manyDetails.wrappedValue = true
        XCTAssertEqual(try height(30, id: manyID), preview)

        let paragraphs = (1...6).map { "第 \($0) 段" }.joined(separator: "\n\n")
        XCTAssertGreaterThan(try height(8, id: eightID, request: paragraphs) - preview, 80)
    }

    @MainActor func testLegacyHandoffOmitsTheIssueLineForAnUnknownPathBase() throws {
        let id = UUID()
        let disclosure = HandoffRowExpansion()
        disclosure.binding(for: id).wrappedValue = true

        let unknownBase = try legacyHandoffHeight(paths: ["Sources/Main.swift"], id: id, disclosure: disclosure)
        let outsideDirectory = try legacyHandoffHeight(paths: ["/outside/Main.swift"], id: id, disclosure: disclosure)
        XCTAssertGreaterThan(outsideDirectory, unknownBase)
    }

    @MainActor private func legacyHandoffHeight(paths: [String], id: UUID, disclosure: HandoffRowExpansion,
                                               request: String = "继续") throws -> Int {
        let context = "最近的用户请求\n\(request)\n\n相关文件\n" + paths.joined(separator: "\n")
        let handoff = SessionHandoff(id: id, source: UUID(), sourceAgent: "Alternate", targetAgent: "Antigravity",
                                     coverage: .available, context: context, delivered: true)
        let item = TranscriptItem(id: handoff.id.uuidString, kind: .notice, text: "Alternate → Antigravity")
        item.handoff = handoff
        let directory = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let row = TranscriptRow(item: item, width: 530, workspaceDirectory: directory,
                                onOpenHandoffFile: { _, _ in .cancelled }, handoffExpansion: disclosure,
                                contentChanged: {}).frame(width: 530)
        return try XCTUnwrap(ImageRenderer(content: row).cgImage).height
    }

    @MainActor func testHandoffEditorKeepsLongFileListsInABoundedViewport() throws {
        func render(fileCount: Int) throws -> CGImage {
            let source = UUID()
            let files = (1...fileCount).map { index in
                let path = "Modules/OrchestrationCore/File\(index).swift"
                return SessionHandoffFile(path: path, changes: [
                    .init(segmentID: source, turnID: UUID(),
                          file: .init(path: path, kind: .modified, added: 4, deleted: 1))
                ])
            }
            let draft = SessionHandoffDraft(userRequest: "继续", notes: "", files: files,
                                           hasIncompleteFileHistory: false, segmentCount: 1)
            let preview = SessionHandoffPreview(sourceAgent: "Antigravity", directory: "/tmp/project",
                                               coverage: .available, draft: draft, excerpts: [],
                                               source: source, history: nil, token: UUID())
            let view = HandoffContextEditor(preview: preview, target: "Alternate", draft: .constant(draft),
                                            context: .constant(""), omitHistory: .constant(false))
                .frame(width: 530)
            return try XCTUnwrap(ImageRenderer(content: view).cgImage)
        }

        let threeFiles = try render(fileCount: 3)
        let sixFiles = try render(fileCount: 6)
        let twentyFourFiles = try render(fileCount: 24)
        XCTAssertGreaterThan(sixFiles.height, threeFiles.height)
        XCTAssertEqual(sixFiles.height, twentyFourFiles.height)
    }

    @MainActor func testHandoffUserBubbleRendersOriginalTextForLiveAndReplayedRows() throws {
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000)
        let file = URL(fileURLWithPath: "/tmp/handoff-fixture.txt")
        let context = String(repeating: "Prior agent's handoff notes. ", count: 30)

        func render(_ item: TranscriptItem) throws -> CGImage {
            let renderer = ImageRenderer(content: TranscriptRow(item: item, width: 530, contentChanged: {})
                .frame(width: 530))
            return try XCTUnwrap(renderer.cgImage)
        }

        for files: [URL] in [[], [file]] {
            for message in ["Continue the task", String(repeating: "Another line of the user's request.\n", count: 6) + "Last line."] {
                let prompt = UserPrompt(text: message, files: files, handoffContext: context)
                let expected = TranscriptItem(id: "user", kind: .user, text: prompt.text, sentAt: sentAt, attachedFiles: files)
                let live = TranscriptItem(id: "user", kind: .user, text: prompt.runtimeText, sentAt: sentAt,
                                          submission: prompt, originalText: prompt.text, attachedFiles: files)
                let controller = SessionController()
                controller.showHistory([.init(id: "user", kind: .user, text: prompt.runtimeText, sentAt: sentAt)],
                                       recordedMessages: [.init(id: prompt.id, text: prompt.text, files: files,
                                                                sentAt: sentAt, handoffContext: context)])
                let replayed = try XCTUnwrap(controller.transcript.first)
                XCTAssertEqual(replayed.editableText, prompt.text)

                // Check that rendering the merged payload takes only the space of the user's original text.
                let expectedHeight = try render(expected).height
                for item in [live, replayed] {
                    XCTAssertEqual(try render(item).height, expectedHeight)
                }
            }
        }
    }

    @MainActor func testUserMessageMarkerUsesAvailableWidthAndConfirmedDelivery() throws {
        func render(_ text: String, width: CGFloat, fontSize: InterfaceFontSize = .standard,
                    delivery: DeliveryState = .accepted) throws -> CGImage {
            let item = TranscriptItem(id: "message", kind: .user, text: text, delivery: delivery)
            let view = TranscriptRow(item: item, width: width, contentChanged: {})
                .frame(width: width)
                .background(ZivviTheme.pageBackground)
                .zivviTypography(fontSize)
                .environment(\.colorScheme, .light)
            return try XCTUnwrap(ImageRenderer(content: view).cgImage)
        }

        func height(_ text: String, width: CGFloat) throws -> Int {
            try render(text, width: width).height
        }

        let message = "Read the prior results."
        let shortHeight = try height("Continue", width: 540)
        XCTAssertEqual(try height(message, width: 540), shortHeight)
        // Removing the inline marker keeps full-width single-line text on one line without vertical jump.
        let nearFullLine = "Read the prior results carefully before editing the layout."
        XCTAssertEqual(try height(nearFullLine, width: 540), shortHeight)
        XCTAssertGreaterThan(try height(message, width: 172), shortHeight)
        let twoLineHeight = try height("Line one\nLine two", width: 540)
        XCTAssertGreaterThan(twoLineHeight, shortHeight)
        XCTAssertGreaterThan(try height("- First item\n- Second item\n- Third item", width: 540), twoLineHeight)
        XCTAssertTrue(DeliveryState.accepted.showsBrandMessageMarker)
        XCTAssertTrue(DeliveryState.handled.showsBrandMessageMarker)
        for state: DeliveryState in [.pending, .queued, .recovered, .rejected, .unknown] {
            XCTAssertFalse(state.showsBrandMessageMarker)
        }

        // Verify fit-content width rules, left-alignment, reading-column max width, and floating badge bounds.
        for size in InterfaceFontSize.allCases {
            let typography = ZivviTypography(size: size)
            let badgeHeight = UserMessageBrandBadge.height(for: typography)
            XCTAssertGreaterThanOrEqual(badgeHeight, 22)
            XCTAssertLessThanOrEqual(badgeHeight, 24)
            XCTAssertGreaterThan(UserMessageBrandBadge.bubbleTopInset(for: typography),
                                 UserMessageBrandBadge.topOverhang(for: typography))
            XCTAssertGreaterThanOrEqual(UserMessageBrandBadge.minimumBubbleWidth(for: typography), 72)
        }

        func pixelBounds(in cgImage: CGImage, matching predicate: (NSColor) -> Bool) -> CGRect? {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if predicate(color) {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        func yellowPixelBounds(in cgImage: CGImage) -> CGRect? {
            pixelBounds(in: cgImage) { $0.redComponent > 0.85 && $0.greenComponent > 0.55 && $0.blueComponent < 0.30 }
        }

        let swatchImage = try XCTUnwrap(ImageRenderer(content: Rectangle().fill(ZivviTheme.userMessageSurface).frame(width: 10, height: 10)).cgImage)
        let swatchColor = try XCTUnwrap(NSBitmapImageRep(cgImage: swatchImage).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))

        func bubblePixelBounds(in cgImage: CGImage) -> CGRect? {
            pixelBounds(in: cgImage) { color in
                abs(color.redComponent - swatchColor.redComponent) < 0.015
                    && abs(color.greenComponent - swatchColor.greenComponent) < 0.015
                    && abs(color.blueComponent - swatchColor.blueComponent) < 0.015
            }
        }

        let shortImage = try render("Hi", width: 540, delivery: .accepted)
        let shortBubble = try XCTUnwrap(bubblePixelBounds(in: shortImage))
        let shortYellow = try XCTUnwrap(yellowPixelBounds(in: shortImage))
        XCTAssertGreaterThan(shortYellow.minY, 0, "Badge top must leave room for the isolation stroke without clipping")
        XCTAssertLessThan(shortYellow.minY, shortBubble.minY, "Top half of Zip! must extend above the bubble top edge")
        XCTAssertGreaterThan(shortYellow.maxY, shortBubble.minY, "Bottom half of Zip! must sit inside the bubble")
        XCTAssertEqual(shortYellow.midY, shortBubble.minY, accuracy: 2,
                       "Zip! vertical center must align with the bubble top edge")
        XCTAssertGreaterThanOrEqual(shortBubble.width, 72)
        XCTAssertLessThan(shortBubble.width, 160, "Short message bubble should fit content instead of spanning full width")
        XCTAssertLessThan(shortBubble.minX, 10, "Short message bubble must align to leading edge")
        XCTAssertGreaterThan(shortYellow.minX, shortBubble.minX)
        XCTAssertLessThan(shortYellow.maxX, shortBubble.maxX)
        XCTAssertEqual(shortYellow.minX - shortBubble.minX, UserMessageBrandBadge.leadingOffset, accuracy: 3,
                       "Zip! badge should sit at the bubble's leading top corner")

        let longText = "This is a longer multi-word prompt that should expand up to the full reading column width before wrapping onto a second line."
        let longImage = try render(longText, width: 540, delivery: .accepted)
        let longBubble = try XCTUnwrap(bubblePixelBounds(in: longImage))
        let longYellow = try XCTUnwrap(yellowPixelBounds(in: longImage))
        XCTAssertGreaterThan(longBubble.width, ceil(540 * 0.85),
                             "Long prose should use the full reading column width without wrapping early at 85%")
        XCTAssertLessThanOrEqual(longBubble.width, 540)
        XCTAssertLessThan(longBubble.minX, 10)
        XCTAssertEqual(longYellow.minX - longBubble.minX, UserMessageBrandBadge.leadingOffset, accuracy: 3)

        // Verify body text inside the bubble stays strictly below the badge + isolation stroke
        // across short single-line, long single-line, and Markdown list scenarios.
        func bodyTextMinY(in image: CGImage, bubble: CGRect, yellow: CGRect) -> Int? {
            let rep = NSBitmapImageRep(cgImage: image)
            var minY = Int.max
            let startY = Int(yellow.maxY + UserMessageBrandBadge.strokeWidth)
            let preStartY = Int(bubble.minY)
            for y in preStartY...Int(bubble.maxY) {
                for x in Int(bubble.minX)..<Int(bubble.maxX) {
                    // Exclude the badge and its isolation stroke region so only body text pixels are sampled.
                    let insideBadge = CGFloat(x) >= yellow.minX - UserMessageBrandBadge.strokeWidth - 1
                        && CGFloat(x) <= yellow.maxX + UserMessageBrandBadge.strokeWidth + 1
                        && y <= startY
                    if insideBadge { continue }
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let isNeutral = abs(color.redComponent - color.greenComponent) < 0.03
                        && abs(color.greenComponent - color.blueComponent) < 0.03
                    if isNeutral, abs(color.redComponent - swatchColor.redComponent) > 0.25 {
                        minY = min(minY, y)
                    }
                }
            }
            return minY == Int.max ? nil : minY
        }

        for (sample, label) in [(shortImage, "short"), (longImage, "long")] {
            let bubble = try XCTUnwrap(bubblePixelBounds(in: sample))
            let yellow = try XCTUnwrap(yellowPixelBounds(in: sample))
            let bodyY = try XCTUnwrap(bodyTextMinY(in: sample, bubble: bubble, yellow: yellow),
                                    "Expected body text pixels inside \(label) bubble")
            XCTAssertGreaterThan(CGFloat(bodyY), yellow.maxY + UserMessageBrandBadge.strokeWidth,
                                 "Body text must sit below the badge and isolation stroke in \(label) bubble")
        }

        let listImage = try render("- First item\n- Second item\n- Third item", width: 540, delivery: .accepted)
        let listBubble = try XCTUnwrap(bubblePixelBounds(in: listImage))
        let listYellow = try XCTUnwrap(yellowPixelBounds(in: listImage))
        let listBodyY = try XCTUnwrap(bodyTextMinY(in: listImage, bubble: listBubble, yellow: listYellow))
        XCTAssertGreaterThan(CGFloat(listBodyY), listYellow.maxY + UserMessageBrandBadge.strokeWidth,
                             "Markdown list first line must sit below the badge and isolation stroke")

        let wideCode = "```swift\nlet longIdentifier = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n```"
        let codeImage = try render(wideCode, width: 540, delivery: .accepted)
        let codeBubble = try XCTUnwrap(bubblePixelBounds(in: codeImage))
        XCTAssertGreaterThan(codeBubble.width, ceil(540 * 0.85),
                             "Wide fenced code block should be allowed to expand past 85% up to 100%")
        XCTAssertLessThanOrEqual(codeBubble.width, 540)

        // Verify extreme narrow widths (< 72 pt and < 32 pt) never overflow container bounds.
        for narrowWidth: CGFloat in [56, 24] {
            let narrowImage = try render("Hi", width: narrowWidth, delivery: .accepted)
            XCTAssertLessThanOrEqual(narrowImage.width, Int(narrowWidth))
            XCTAssertNil(yellowPixelBounds(in: narrowImage))
        }

        // Verify Increase Contrast renders a 1 pt border outline on UserMessageSurface while standard contrast does not.
        // Render an empty surface box so text anti-aliasing cannot produce border-toned gray fringes.
        let borderImage = try XCTUnwrap(ImageRenderer(
            content: Rectangle().fill(ZivviTheme.border).frame(width: 10, height: 10).environment(\.colorScheme, .light)
        ).cgImage)
        let borderColor = try XCTUnwrap(NSBitmapImageRep(cgImage: borderImage).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        func hasBorderPixel(in cgImage: CGImage) -> Bool {
            pixelBounds(in: cgImage) { color in
                abs(color.redComponent - borderColor.redComponent) < 0.015
                    && abs(color.greenComponent - borderColor.greenComponent) < 0.015
                    && abs(color.blueComponent - borderColor.blueComponent) < 0.015
            } != nil
        }
        let surface = Color.clear
            .frame(width: 120, height: 32)
            .modifier(UserMessageSurface(isVisible: true, reservesTopBadgeInset: true))
            .padding(8)
            .background(ZivviTheme.pageBackground)
            .zivviTypography(.standard)
            .environment(\.colorScheme, .light)
        let standardContrastSurface = surface.environment(\._colorSchemeContrast, .standard)
        let increasedContrastSurface = surface.environment(\._colorSchemeContrast, .increased)
        XCTAssertFalse(hasBorderPixel(in: try XCTUnwrap(ImageRenderer(content: standardContrastSurface).cgImage)))
        XCTAssertTrue(hasBorderPixel(in: try XCTUnwrap(ImageRenderer(content: increasedContrastSurface).cgImage)))

        // Verify unconfirmed delivery states, queue footer, and file-only attachments render cleanly without badge.
        for state: DeliveryState in [.pending, .queued, .recovered, .rejected, .unknown] {
            let unconfirmed = try render("Unconfirmed prompt", width: 420, delivery: state)
            XCTAssertNil(yellowPixelBounds(in: unconfirmed))
        }

        let fileA = URL(fileURLWithPath: "/tmp/first.swift")
        let fileB = URL(fileURLWithPath: "/tmp/second.md")
        let fileOnlyItem = TranscriptItem(id: "files-only", kind: .user, text: "", attachedFiles: [fileA, fileB])
        let fileOnlyView = TranscriptRow(item: fileOnlyItem, width: 320, queueFooter: "等待交付：补充 1 · 后续 0",
                                         contentChanged: {})
            .frame(width: 320)
            .background(ZivviTheme.pageBackground)
            .zivviTypography(.standard)
            .environment(\.colorScheme, .light)
        let fileOnlyImage = try XCTUnwrap(ImageRenderer(content: fileOnlyView).cgImage)
        let fileBubble = try XCTUnwrap(bubblePixelBounds(in: fileOnlyImage))
        XCTAssertLessThan(fileBubble.minX, 10)
        XCTAssertNotNil(yellowPixelBounds(in: fileOnlyImage))

        // Verify dark/light appearance token resolution for the bubble, isolation stroke, and badge ink.
        for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                let page = NSColor(ZivviTheme.pageBackground).usingColorSpace(.sRGB)
                let surface = NSColor(ZivviTheme.userMessageSurface).usingColorSpace(.sRGB)
                let badgeBg = NSColor(ZivviTheme.lightningYellow).usingColorSpace(.sRGB)
                let badgeInk = NSColor(ZivviTheme.brandBadgeText).usingColorSpace(.sRGB)
                XCTAssertNotNil(page)
                XCTAssertNotNil(surface)
                XCTAssertNotNil(badgeBg)
                XCTAssertNotNil(badgeInk)
                if let page, let surface, let badgeBg, let badgeInk {
                    XCTAssertGreaterThan(abs(surface.redComponent - page.redComponent), 0.02)
                    XCTAssertGreaterThan(badgeBg.redComponent - badgeInk.redComponent, 0.7)
                    XCTAssertLessThan(badgeInk.redComponent, 0.2)
                }
            }
        }
    }

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

    func testMarkdownBlockSpacingUsesOneGapAndSupportsListParagraphs() {
        let chat = MarkdownStyle(profile: .conversation, width: .wide, typography: .init())
        let document = MarkdownStyle(profile: .editorial, width: .wide, typography: .init())
        XCTAssertEqual(MarkdownBlockSpacing.between(nil, .heading(1), style: chat), 0)
        XCTAssertEqual(MarkdownBlockSpacing.between(.paragraph, .paragraph, style: chat), 12)
        XCTAssertEqual(MarkdownBlockSpacing.between(.paragraph, .paragraph, style: document), 16)
        XCTAssertEqual(MarkdownBlockSpacing.between(.paragraph, .paragraph, style: chat, paragraphGap: 8), 8)
        XCTAssertEqual(MarkdownBlockSpacing.between(.heading(1), .paragraph, style: chat), 16)
        XCTAssertEqual(MarkdownBlockSpacing.between(.heading(1), .heading(2), style: chat), 12)
        XCTAssertEqual(MarkdownBlockSpacing.between(.heading(1), .heading(2), style: document), 16)
        XCTAssertEqual(MarkdownBlockSpacing.between(.paragraph, .heading(3), style: chat), 20)
        XCTAssertEqual(MarkdownBlockSpacing.between(.heading(4), .quote([]), style: chat), 8)
    }

    func testMarkdownProfilesResolveWidthBeforeTextScale() {
        for scale in [1.0, 1.25, 1.5] {
            let chat = MarkdownStyle(profile: .conversation, width: MarkdownWidth(720), typography: .init(), scale: scale)
            let document = MarkdownStyle(profile: .editorial, width: MarkdownWidth(1000), typography: .init(), scale: scale)
            let narrow = MarkdownStyle(profile: .editorial, width: MarkdownWidth(319), typography: .init(), scale: scale)
            XCTAssertEqual(chat.heading(1).size, 24 * scale)
            XCTAssertEqual(document.heading(1).size, 28 * scale)
            XCTAssertEqual(narrow.heading(1).size, 22 * scale)
            XCTAssertEqual(narrow.heading(2).size, 18 * scale)
            XCTAssertEqual(narrow.body.size, 14 * scale)
            XCTAssertEqual(narrow.heading(6).weight, .medium)
            XCTAssertGreaterThan(document.body.lineHeight, chat.body.lineHeight)
        }
        XCTAssertEqual(MarkdownWidth(320).editorialContentWidth(in: 320), 288)
        XCTAssertEqual(MarkdownWidth(480).editorialContentWidth(in: 480), 440)
        XCTAssertEqual(MarkdownWidth(1000).editorialContentWidth(in: 1000), 720)
    }

    func testMarkdownFixturePreservesRichBlocksAndUnsupportedLiteralContent() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Verification/Fixtures/markdown-typography/README.md")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let blocks = MarkdownBlocks.parse(source)
        let headings = blocks.compactMap { block -> Int? in
            if case .heading(let level) = block.kind { return level }
            return nil
        }
        XCTAssertEqual(headings, [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(blocks.contains { $0.text == "<aside>HTML remains literal.</aside>" })
        XCTAssertTrue(blocks.contains { $0.text.contains("[^note]: 脚注定义") })
        XCTAssertTrue(blocks.contains { $0.text.contains("脚注引用 [^note]") })
        XCTAssertTrue(blocks.contains { $0.content.runs.contains { $0.link?.absoluteString == "https://example.invalid/guide" } })
        XCTAssertEqual(blocks.flatMap { $0.content.runs.compactMap(\.imageURL) }.count, 3)
        XCTAssertTrue(blocks.contains { if case .code("rust") = $0.kind { return $0.text.contains("\tfn") && $0.text.contains("\n\n") }; return false })

        let lists = blocks.filter { if case .list = $0.kind { return true }; return false }
        XCTAssertTrue(try XCTUnwrap(lists.first).isLooseList)
        guard case .list(false, let tasks) = try XCTUnwrap(lists.last).kind else {
            return XCTFail("Expected task list")
        }
        XCTAssertEqual(tasks.map(\.taskChecked), [true, false])
        XCTAssertEqual(tasks[0].blocks.first?.text, "Parse Markdown")

        let literal = MarkdownBlocks.parse("- \\[x] literal\r\n\r\n```\r\n[^literal]: code\r\n```")
        guard case .list(false, let items) = try XCTUnwrap(literal.first).kind else {
            return XCTFail("Expected literal list")
        }
        XCTAssertNil(items.first?.taskChecked)
        XCTAssertEqual(literal.last?.text, "[^literal]: code")
    }

    func testMarkdownBlockIdentitySurvivesLateReferencesAndEmptyTableRows() throws {
        let prefix = "# 稳定 👩🏽‍💻\r\n\r\n| a | b |\r\n| - | - |\r\n| | |\r\n\r\nSee [the guide][guide]."
        let final = prefix + "\r\n\r\n[guide]: https://example.invalid/"
        let stable = MarkdownBlockID.entries(MarkdownBlocks.parse(prefix), sourceOffset: \.sourceOffset)
        let updated = MarkdownBlockID.entries(MarkdownBlocks.parse(final), sourceOffset: \.sourceOffset)
        XCTAssertEqual(updated.map(\.id), stable.map(\.id))
        XCTAssertEqual(Set(stable.map(\.id)).count, stable.count)
        XCTAssertEqual(updated.last?.value.content.runs.compactMap(\.link).first?.absoluteString, "https://example.invalid/")
        XCTAssertEqual(updated.last?.value.sourceOffset, prefix.utf8.count - "See [the guide][guide].".utf8.count)

        let before = MarkdownBlockID.documentEntries(MarkdownBlocks.parse("# Guide\n\nSection one"))
        let after = MarkdownBlockID.documentEntries(MarkdownBlocks.parse("New intro\n\n# Guide\n\nSection one"))
        XCTAssertEqual(before.map(\.id), after.dropFirst().map(\.id))
    }

    func testMarkdownDistinguishesCaretReferencesFromLiteralNotes() throws {
        let linked = MarkdownBlocks.parse("""
        [label][^NOTE] and [^note] and [^note][] and [relative][^path].

        [^note]: <https://example.invalid/guide> "Guide"
        [^path]: docs/README.md
        """)
        let paragraph = try XCTUnwrap(linked.first)
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(paragraph.text, "label and ^note and ^note and relative.")
        XCTAssertEqual(paragraph.content.runs.compactMap(\.link).map(\.absoluteString), [
            "https://example.invalid/guide", "https://example.invalid/guide", "https://example.invalid/guide", "docs/README.md"
        ])

        let literal = MarkdownBlocks.parse("""
        Paragraph with a note[^read].

        [^read]: Footnote explanation.

        ```text
        [^code]: https://example.invalid/code
        ```

        <pre>
        [^html]: https://example.invalid/html
        </pre>
        """)
        XCTAssertEqual(literal.map(\.text), [
            "Paragraph with a note[^read].",
            "[^read]: Footnote explanation.",
            "[^code]: https://example.invalid/code",
            "<pre>\n[^html]: https://example.invalid/html\n</pre>"
        ])
    }

    @MainActor func testMarkdownStreamingUsesLatestCanonicalSourceAndResetsPendingWork() async throws {
        let stale = DispatchSemaphore(value: 0)
        let parsing = OSAllocatedUnfairLock(initialState: "")
        let state = MarkdownStreamingState(interval: .zero) { source in
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Stale" || trimmed == "Abandoned" {
                parsing.withLock { $0 = trimmed }
                _ = stale.wait(timeout: .now() + 2)
            }
            return MarkdownBlocks.parse(source)
        }
        defer { state.reset(); stale.signal() }
        state.submit(.init(text: "Stale\n\n", streaming: true))
        for _ in 0..<100 where parsing.withLock({ $0 }) != "Stale" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(parsing.withLock { $0 }, "Stale")
        let source = "# Guide\n\n```swift\n    let value = 1\n\n```"
        state.submit(.init(text: source, streaming: false))
        stale.signal()
        for _ in 0..<100 where state.snapshot?.matches(source) != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.snapshot?.blocks, MarkdownBlocks.parse(source))
        let completed = try XCTUnwrap(state.snapshot)
        XCTAssertFalse(state.releaseCompletedSnapshot(revision: completed.revision &+ 1))
        XCTAssertTrue(state.releaseCompletedSnapshot(revision: completed.revision))
        XCTAssertNil(state.snapshot)
        XCTAssertFalse(state.isActive)

        state.submit(.init(text: "Abandoned\n\n", streaming: true))
        for _ in 0..<100 where parsing.withLock({ $0 }) != "Abandoned" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(parsing.withLock { $0 }, "Abandoned")
        state.reset()
        state.submit(.init(text: "# New run\n", streaming: true))
        stale.signal()
        for _ in 0..<100 where state.snapshot?.matches("# New run\n") != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.snapshot?.source, "# New run\n")
        XCTAssertEqual(state.snapshot?.blocks.first?.kind, .heading(1))
    }

    @MainActor func testMarkdownTableInlineStylingPreservesTextAndLinkedCode() throws {
        let layout = MarkdownContentCache().layout(for: """
        | Cell |
        | --- |
        | [`select_this`](https://example.com/code-link) [Open link](https://example.com/table-link) **bold** |
        """, typography: .init())
        guard case .table(let table) = try XCTUnwrap(layout.blocks.first).kind else {
            return XCTFail("Expected a table")
        }

        let cell = table.rows[1].cells[0]
        let styled = MarkdownTextFonts(typography: .init())
            .stylingInlineText(in: cell, interactiveLinks: layout.interactiveLinks)
        XCTAssertEqual(String(styled.characters), "select_this Open link bold")
        XCTAssertEqual(styled.runs.map(\.inlinePresentationIntent), cell.runs.map(\.inlinePresentationIntent))
        XCTAssertEqual(styled.runs.compactMap(\.link), cell.runs.compactMap(\.link))
        let code = try XCTUnwrap(styled.runs.first)
        XCTAssertEqual(code.link?.absoluteString, "https://example.com/code-link")
        XCTAssertNotNil(code.swiftUI.font)
        for run in styled.runs where run.link != nil {
            XCTAssertEqual(run.swiftUI.foregroundColor, ZivviTheme.infoText)
            XCTAssertEqual(run.swiftUI.underlineStyle, .single)
        }
    }

    func testMarkdownLinkLabelsRetainNestedInlineSemantics() throws {
        let source = "中文 [**bold** and *emphasis* and `` code ``](https://example.invalid) [`unresolved`](missing.md)"
        let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
        XCTAssertEqual(block.text, "中文 bold and emphasis and code unresolved")
        let linkedRuns = block.content.runs.filter { $0.link?.scheme == "https" }
        XCTAssertTrue(linkedRuns.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(linkedRuns.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(linkedRuns.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(block.content.runs.contains {
            $0.link?.relativeString == "missing.md" && $0.inlinePresentationIntent?.contains(.code) == true
        })
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
        for name in ["bash", "zivvi_bash"] {
            let raw = #"{"command":"git status --short\nsecond line"}"#
            let presentation = try toolPresentation(name, arguments: raw)
            XCTAssertEqual(presentation.object, "git status --short")
            guard case .command(let command) = presentation.parameters else { return XCTFail("Expected command") }
            XCTAssertEqual(command, "git status --short\nsecond line")
        }

        for name in ["edit", "zivvi_edit"] {
            let raw = #"{"path":"Zivvi/View.swift","edits":[{"oldText":"context\nold","newText":"context\nnew"}]}"#
            let presentation = try toolPresentation(name, arguments: raw, state: .failed)
            XCTAssertEqual(presentation.object, "View.swift")
            XCTAssertTrue(presentation.accessibilityDescription.contains("View.swift"))
            XCTAssertTrue(presentation.accessibilityDescription.contains(String(localized: ToolState.failed.statusLabel)))
            guard case .edit(let edit) = presentation.parameters else { return XCTFail("Expected edit") }
            XCTAssertEqual(edit.path, "Zivvi/View.swift")
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
                            ("zivvi_edit", #"{"path":"View.swift","edits":[{}]}"#),
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
        for name in ["read", "zivvi_read"] {
            let raw = #"{"limit":268,"offset":30,"path":"Zivvi\/Features\/Workbench\/WorkbenchView.swift"}"#
            let presentation = try toolPresentation(name, arguments: raw)
            guard case .read(let read) = presentation.parameters else { return XCTFail("Expected a file read") }
            XCTAssertEqual(read.path, "Zivvi/Features/Workbench/WorkbenchView.swift")
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
            ("zivvi_bash", .completed), ("edit", .failed), ("read", .interrupted),
            ("zivvi_read", .completed), ("custom", .completed), ("grep", .completed), ("zivvi_grep", .completed)
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

    @MainActor func testDocumentGroupSpacingAndIconRoles() {
        let user = TranscriptDisplayRow.item(.init(id: "user", kind: .user))
        let pendingUser = TranscriptDisplayRow.item(.init(id: "pending", kind: .user, delivery: .pending))
        let reply = TranscriptDisplayRow.item(.init(id: "reply", kind: .assistant))
        let turn = TranscriptDisplayRow.turnHeader(.init(status: .completed))
        let tool = TranscriptDisplayRow.toolCalls([.init(id: "tool", kind: .tool)])
        let ordinaryGap = ZivviSpacing.timelineRowGap + 2 * ZivviSpacing.timelineRowInset
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: user, after: nil), 0)
        for size in InterfaceFontSize.allCases {
            let typography = ZivviTypography(size: size)
            let badgeOverhang = UserMessageBrandBadge.topOverhang(for: typography)
            XCTAssertEqual(NativeTranscriptRow.groupInset(before: user, after: reply, typography: typography)
                           + ordinaryGap + badgeOverhang,
                           ZivviSpacing.messageGroup)
        }
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: pendingUser, after: reply) + ordinaryGap,
                       ZivviSpacing.messageGroup)
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: reply, after: user) + ordinaryGap,
                       ZivviSpacing.messageAfterUserGroup)
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: turn, after: user) + ordinaryGap,
                       ZivviSpacing.messageAfterUserGroup)
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: turn, after: reply) + ordinaryGap,
                       ZivviSpacing.messageGroup)
        XCTAssertEqual(NativeTranscriptRow.groupInset(before: tool, after: reply), 0)
        XCTAssertEqual(ToolCallKind(name: "zivvi_bash").glyph, .terminal)
        XCTAssertEqual(ToolCallKind(name: "find").glyph, .search)
        XCTAssertEqual(ToolCallKind(name: "unknown").glyph, .generic)
    }

    @MainActor func testSessionReadingAnchorResolvesGroupedAndMissingRows() {
        let calls = TranscriptDisplayRow.toolCalls([.init(id: "a", kind: .tool), .init(id: "b", kind: .tool)])
        let remaining = TranscriptDisplayRow.item(.init(id: "next", kind: .assistant))
        let anchor = TranscriptReadingAnchor(id: "b", offset: 7, next: "next", previous: "prev")
        XCTAssertEqual(anchor.resolve(in: [calls, remaining]), 0)
        XCTAssertEqual(anchor.resolve(in: [remaining]), 0)
        XCTAssertNil(anchor.resolve(in: []))
        let secondNext = TranscriptReadingID("next", occurrence: 1)
        let suffix = TranscriptDisplayRow.item(.init(id: "next#1", kind: .assistant))
        let repeated = [remaining, suffix, remaining]
        let projected = NativeTranscriptRow.project(repeated, footers: [:])
        XCTAssertEqual(Set(projected.map(\.readingID)).count, 3)
        XCTAssertEqual(TranscriptReadingAnchor(id: "gone", offset: 7, next: secondNext, previous: nil)
            .resolve(in: repeated), 2)
        let memory = WindowTranscriptPositions()
        let session = UUID()
        memory.state(for: session).readingAnchor = anchor
        XCTAssertEqual(memory.state(for: session).readingAnchor, anchor)
        XCTAssertNil(memory.state(for: UUID()).readingAnchor)
    }

    @MainActor func testProjectionRecognizesNewSegmentForSameMessageObject() {
        let item = TranscriptItem(id: "message", kind: .assistant)
        let rows = [TranscriptDisplayRow.item(item)]
        let original = NativeTranscriptRow.project(rows, footers: [:])[0]
        item.timelineSegmentID = UUID()
        let updated = NativeTranscriptRow.project(rows, footers: [:])[0]
        XCTAssertEqual(original.id, "message")
        XCTAssertEqual(updated.id, item.timelineID)
        XCTAssertFalse(original.hasSameItems(as: updated))
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
        turn.liveStage = .streaming
        XCTAssertFalse(showsIndicator([item, reply, next]), "An identified reply continues in its earlier row")
        turn.liveStage = .running
        item.tool?.state = .running
        XCTAssertFalse(showsIndicator([item, reply, next]), "A parallel tool in an earlier group is still running")

        turn.thoughtText = "Checking remaining diffs"
        XCTAssertTrue(showsIndicator([item, reply, next]), "Live thought text keeps thinking row visible below tool group")

        let headerOnlyTurn = TurnRecord(startedAt: .now)
        headerOnlyTurn.thoughtText = "Planning approach"
        let headerOnly = TranscriptDisplayRow.project(
            [TranscriptItem(id: "user", kind: .user, text: "Help", turn: nil)],
            turnStarts: [.init(turn: headerOnlyTurn, precedingItemID: "user")],
            showsThinking: true
        )
        guard case .thinking(let initialThinkingTurn) = headerOnly.last else {
            return XCTFail("Expected thinking below turn header when thought text is present")
        }
        XCTAssertTrue(initialThinkingTurn === headerOnlyTurn)
    }

    @MainActor func testToolGroupIconFollowsLastRunningToolInTranscriptOrder() {
        func runningToolName(readState: ToolState, searchState: ToolState) -> String? {
            let states: [(String, ToolState)] = [
                ("zivvi_read", readState), ("grep", searchState), ("bash", .completed)
            ]
            let items = states.map { name, state in
                TranscriptItem(id: name, kind: .tool, tool: .init(id: name, name: name, state: state))
            }
            return ToolCallsSummary(items: items).runningToolName
        }
        XCTAssertEqual(runningToolName(readState: .running, searchState: .running), "grep")
        XCTAssertEqual(runningToolName(readState: .running, searchState: .completed), "zivvi_read")
        XCTAssertNil(runningToolName(readState: .interrupted, searchState: .completed))
    }

    @MainActor func testGrepSummariesUseThePatternAndOptionalScope() throws {
        for name in ["grep", "zivvi_grep"] {
            let raw = #"{"pattern":"first|第二","path":"Zivvi\/Features","glob":"*.swift","limit":30}"#
            let presentation = try toolPresentation(name, arguments: raw)
            guard case .search(let search) = presentation.parameters else { return XCTFail("Expected a search") }
            XCTAssertEqual(presentation.operationLabel.map { String(localized: $0) }, String(localized: "搜索"))
            XCTAssertEqual(presentation.object, "first|第二")
            XCTAssertEqual(search.path, "Zivvi/Features")
            XCTAssertEqual(search.glob, "*.swift")
            XCTAssertEqual(search.limit, 30)
            XCTAssertTrue(presentation.accessibilityDescription.contains("Zivvi/Features"))
        }
        let presentation = try toolPresentation("grep", arguments: #"{"pattern":"test","limit":"unknown"}"#)
        guard case .search(let search) = presentation.parameters else { return XCTFail("Expected a search") }
        XCTAssertEqual(presentation.object, "test")
        XCTAssertNil(search.limit)
        XCTAssertTrue(presentation.qualifiers.isEmpty)
    }


    @MainActor func testDirectoryFindAndWriteAreNotCountedAsOther() {
        let names = ["ls", "zivvi_ls", "find", "zivvi_find", "write", "zivvi_write"]
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
        let workspace = WorkspaceController(store: store) { _, _ in runtime }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
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



    func testMarkdownFileLinksEnrichWorkspacePathsInlineCodeRelativeLinksAndPreserveCodeBlocks() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Zivvi/Features/Composer"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("dir with space"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let readme = workspace.appendingPathComponent("README.md").standardizedFileURL
        let composer = workspace.appendingPathComponent("Zivvi/Features/Composer/ComposerView.swift").standardizedFileURL
        let spaced = workspace.appendingPathComponent("dir with space/note.txt").standardizedFileURL
        try Data("# README\n".utf8).write(to: readme)
        try Data("struct ComposerView {}\n".utf8).write(to: composer)
        try Data("hello\n".utf8).write(to: spaced)

        let markdown = """
        - Zivvi/Features/Composer/ComposerView.swift: updated mapping
        - Check `README.md` and `dir with space/note.txt:42` and 在Zivvi/Features/Composer/ComposerView.swift中
        - See [Composer](Zivvi/Features/Composer/ComposerView.swift#L12) and missing/file.swift and v1.0
        - Web URL https://example.com/Zivvi/Features/Composer/ComposerView.swift

        | File | Notes |
        | --- | --- |
        | README.md | ok |

        ```
        Zivvi/Features/Composer/ComposerView.swift
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
                       ["Zivvi/Features/Composer/ComposerView.swift"])
        XCTAssertEqual(firstRuns.first?.link?.path, composer.path)

        let secondContent = items[1].blocks[0].content
        let secondLinks = secondContent.runs.compactMap { run -> (String, URL)? in
            guard let link = run.link else { return nil }
            return (String(secondContent[run.range].characters), link)
        }
        XCTAssertEqual(secondLinks.map(\.0), [
            "README.md",
            "dir with space/note.txt:42",
            "Zivvi/Features/Composer/ComposerView.swift"
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
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Zivvi"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let target = workspace.appendingPathComponent("Zivvi/App.swift").standardizedFileURL
        try Data("struct App {}\n".utf8).write(to: target)

        let withFragment = URL(string: target.absoluteString + "#L10-L20")!
        XCTAssertEqual(TranscriptFileLinks.openableFileURL(for: withFragment, workspaceDirectory: workspace), target)

        let relative = URL(string: "Zivvi/App.swift#L8")!
        XCTAssertEqual(TranscriptFileLinks.openableFileURL(for: relative, workspaceDirectory: workspace), target)

        let web = URL(string: "https://example.com/Zivvi/App.swift")!
        XCTAssertNil(TranscriptFileLinks.openableFileURL(for: web, workspaceDirectory: workspace))

        let missing = workspace.appendingPathComponent("Zivvi/Missing.swift")
        XCTAssertNil(TranscriptFileLinks.openableFileURL(for: missing, workspaceDirectory: workspace))

        let cache = MarkdownContentCache()
        let withoutWorkspace = cache.layout(for: "See Zivvi/App.swift", typography: .init(), workspaceDirectory: nil)
        XCTAssertTrue(withoutWorkspace.blocks[0].content.runs.compactMap(\.link).isEmpty)

        let withWorkspace = cache.layout(for: "See Zivvi/App.swift", typography: .init(), workspaceDirectory: workspace)
        XCTAssertEqual(withWorkspace.blocks[0].content.runs.compactMap(\.link).map(\.path), [target.path])
    }

    @MainActor func testTranscriptFileOpenerRevealsFilesWithoutAnApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Catalog.xcassets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Directories and files without a default app are revealed rather than launched.
        XCTAssertEqual(TranscriptFileOpener.destination(for: root), .revealInFinder(root))
        XCTAssertEqual(TranscriptFileOpener.destination(for: root.appendingPathComponent("Catalog.xcassets")),
                       .revealInFinder(root.appendingPathComponent("Catalog.xcassets")))
        let orphan = root.appendingPathComponent("output.zivviunmapped")
        try Data("x".utf8).write(to: orphan)
        XCTAssertEqual(TranscriptFileOpener.destination(for: orphan), .revealInFinder(orphan))
        XCTAssertEqual(TranscriptFileOpener.destination(for: root.appendingPathComponent("Missing.swift")), .unsupported)

        // A click on an unresolved relative reference is swallowed instead of reaching Launch Services.
        XCTAssertEqual(TranscriptFileOpener.clickedLink(for: URL(string: "Zivvi/Missing.swift:12")!,
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
        let file = URL(fileURLWithPath: "/tmp/Zivvi/App.swift")
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: file.absoluteString + "#L12-L20")!), 12)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: file.absoluteString + "#L7")!), 7)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: "Zivvi/App.swift:9")!), 9)
        XCTAssertEqual(TranscriptFileOpener.lineReference(in: URL(string: "Zivvi/App.swift:9:3")!), 9)
        XCTAssertNil(TranscriptFileOpener.lineReference(in: URL(string: "Zivvi/App.swift")!))

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-xcode-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor func testTranscriptMarkdownStoreCachesAcrossReuseAndValidatesLinksAsynchronously() async throws {
        final class DiskCheckRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var checkedPaths: [String] = []
            func record(_ path: String) -> Bool {
                lock.lock()
                checkedPaths.append(path)
                lock.unlock()
                return FileManager.default.fileExists(atPath: path)
            }
            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return checkedPaths.count
            }
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zivvi-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Zivvi"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let existing = workspace.appendingPathComponent("Zivvi/App.swift").standardizedFileURL
        try Data("struct App {}\n".utf8).write(to: existing)

        let recorder = DiskCheckRecorder()
        let store = TranscriptMarkdownStore(capacity: 32, pathTTL: .seconds(5)) { path in
            recorder.record(path)
        }

        let source = "Check Zivvi/App.swift and Zivvi/Missing.swift"
        let first = store.layout(for: source, typography: .init(), workspaceDirectory: workspace)
        XCTAssertEqual(recorder.count, 0, "Synchronous scroll layout must not hit disk fileExists")
        XCTAssertTrue(first.layout.interactiveLinks.isEmpty)
        let initialVersion = first.revision.version

        for _ in 0..<40 where store.hasPendingLinkChecks {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(store.hasPendingLinkChecks)
        XCTAssertGreaterThan(recorder.count, 0)
        XCTAssertEqual(first.revision.version, initialVersion + 1)

        let countAfterResolve = recorder.count
        let second = store.layout(for: source, typography: .init(), workspaceDirectory: workspace)
        XCTAssertEqual(store.cachedLayoutCount, 1)
        XCTAssertEqual(recorder.count, countAfterResolve, "Cached layout hit must not re-check disk")
        XCTAssertEqual(second.layout.interactiveLinks.map(\.path), [existing.path])

        // A message containing only non-existent paths must not trigger an extra UI revision bump.
        let missingOnly = store.layout(for: "Only Zivvi/NeverCreated.swift", typography: .init(), workspaceDirectory: workspace)
        let missingInitialVersion = missingOnly.revision.version
        for _ in 0..<40 where store.hasPendingLinkChecks {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(missingOnly.revision.version, missingInitialVersion)
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
