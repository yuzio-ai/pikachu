import Foundation
import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Pikachu

final class TurnFileChangesTests: XCTestCase {

    @MainActor func testHandoffFileCoverageKeepsVisibleUnknownTurnsInEarlierSnapshots() {
        let old = TurnRecord(status: .completed)
        let captured = RecordedTurnRecord(status: .completed,
                                          fileChanges: .init(files: [.init(path: "new", kind: .added, added: 1, deleted: 0)]))
        var snapshot = SessionHistorySnapshot(transcript: [
            .init(id: "old-reply", kind: .assistant, text: "Older reply", turn: old)
        ], coverage: .available)
        snapshot.fileChangeRecords = [captured]
        let id = UUID()
        let history = SessionHandoffFileHistory(id: id, coverage: .available, turns: snapshot.fileRecords)
        let mixed = snapshot.preview(source: id, agent: "Alternate", directory: "/tmp", token: UUID(),
                                     retainingHistory: false, fileHistory: [history]).draft
        XCTAssertTrue(mixed.hasIncompleteFileHistory)
        XCTAssertEqual(mixed.selectedFiles.map(\.path), ["new"])

        let knownEmpty = RecordedTurnRecord(id: old.id, status: .completed, fileChanges: .init(files: []))
        let completeHistory = SessionHandoffFileHistory(id: id, coverage: .available,
                                                        turns: snapshot.fileRecords(including: [knownEmpty]))
        let complete = snapshot.preview(source: id, agent: "Alternate", directory: "/tmp", token: UUID(),
                                        retainingHistory: false, fileHistory: [completeHistory]).draft
        XCTAssertFalse(complete.hasIncompleteFileHistory)
        XCTAssertEqual(complete.selectedFiles.map(\.path), ["new"])
    }


    @MainActor func testOnlyFinishedTurnsWithChangesGetASeparateFooter() {
        let changes = TurnFileChanges(files: [.init(path: "a.txt", kind: .added, added: 1, deleted: 0)])
        let first = TurnRecord(displayID: "first", fileChanges: changes)
        let second = TurnRecord(status: .completed, displayID: "second")
        let items: [TranscriptItem] = [
            .init(id: "user-1", kind: .user, text: "First", turn: first),
            .init(id: "reply-1", kind: .assistant, text: "Done", turn: first),
            .init(id: "user-2", kind: .user, text: "Second", turn: second),
            .init(id: "reply-2", kind: .assistant, text: "No edits", turn: second)
        ]
        XCTAssertEqual(TranscriptDisplayRow.project(items).map(\.id), [
            "user-1", "turn-header:first", "reply-1", "user-2", "turn-header:second", "reply-2"
        ])
        first.status = .completed
        XCTAssertEqual(TranscriptDisplayRow.project(items).map(\.id), [
            "user-1", "turn-header:first", "reply-1", "turn-changes:first", "user-2", "turn-header:second", "reply-2"
        ])
    }

    @MainActor func testReloadedTurnRestoresItsSummaryAndDecodesOlderRecords() throws {
        let changes = TurnFileChanges(files: [.init(path: "a.txt", kind: .added, added: 1, deleted: 0)])
        let timestamp: Int64 = 1_795_000_000_000
        let legacy = Data(#"{"id":"CC4A925A-F691-4B4F-AE98-DD4D731ECBFD","status":"completed"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RecordedTurnRecord.self, from: legacy).fileChanges)
        let legacySummary = Data("""
        {"id":"CC4A925A-F691-4B4F-AE98-DD4D731ECBFD","status":"completed","anchorAssistantTimestampMs":\(timestamp),
         "fileChanges":{"files":[{"path":"a.txt","kind":"added","added":1,"deleted":0}],"patch":"+a","patchTruncated":false}}
        """.utf8)
        let decoded = try JSONDecoder().decode(RecordedTurnRecord.self, from: legacySummary)
        XCTAssertEqual(try JSONDecoder().decode(RecordedTurnRecord.self, from: JSONEncoder().encode(decoded)), decoded)
        let controller = SessionController()
        controller.showHistory([.init(id: "reply", kind: .assistant, text: "Done", messageTimestampMs: timestamp)],
                               turns: [.init(id: "previous", itemIDs: ["reply"], firstAssistantTimestampMs: timestamp, status: .completed)],
                               recordedTurns: [decoded])
        guard case .turnChanges(let turn) = TranscriptDisplayRow.project(controller.transcript).last else {
            return XCTFail("Expected historical turn changes")
        }
        XCTAssertEqual(turn.fileChanges, changes)
    }

    @MainActor func testBulkFolderToggleTracksPartialExpansionAndKeepsTurnsIndependent() {
        let expansion = TurnChangesExpansion()
        let folders: Set<String> = ["Modules", "Pikachu"]
        let modules = expansion.folder("Modules", in: "first")
        let pikachu = expansion.folder("Pikachu", in: "first")
        XCTAssertFalse(modules.wrappedValue)
        XCTAssertFalse(pikachu.wrappedValue)

        modules.wrappedValue = true
        XCTAssertFalse(expansion.allExpanded(folders, in: "first"))
        expansion.toggleAll(folders, in: "first")
        XCTAssertTrue(expansion.allExpanded(folders, in: "first"))
        XCTAssertTrue(pikachu.wrappedValue)
        XCTAssertFalse(expansion.folder("Modules", in: "second").wrappedValue)

        expansion.toggleAll(folders, in: "first")
        XCTAssertFalse(modules.wrappedValue)
        XCTAssertFalse(pikachu.wrappedValue)
    }

    @MainActor func testNativeTranscriptPlacesReplyActionsOnChangeRow() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let changes = TurnFileChanges(files: [.init(path: "src/a.txt", kind: .modified, added: 1, deleted: 1)])
        let turn = TurnRecord(status: .completed, displayID: "fixture", fileChanges: changes)
        let reply = TranscriptItem(id: "reply", kind: .assistant, text: "Updated the file.", turn: turn)
        let rows = TranscriptDisplayRow.project([reply])
        let footers = TranscriptReplyFooter.project(rows)
        XCTAssertNil(footers[reply.id])
        XCTAssertEqual(footers["turn-changes:fixture"]?.markdown, reply.text)
        coordinator.update(rows, follow: .constant(true), replyFooters: footers)
        for _ in 0..<4 {
            scroll.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        let table = try XCTUnwrap(coordinator.table)
        XCTAssertEqual(table.numberOfRows, 3)
        let footer = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? NativeTranscript.HostCell)
        XCTAssertEqual(footer.representedID, "turn-changes:fixture")
        XCTAssertGreaterThan(table.rect(ofRow: 2).height, 38)
        XCTAssertGreaterThan(table.rect(ofRow: 2).minY, table.rect(ofRow: 1).minY)
        // NSTableView's row rectangle already includes its intercell spacing.
        XCTAssertEqual(table.rect(ofRow: 2).minY, table.rect(ofRow: 1).maxY, accuracy: 1)
    }

    @MainActor func testTurnChangedFilesResolveExistingFilesForClickToOpen() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-turn-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let existing = workspace.appendingPathComponent("src/a.txt").standardizedFileURL
        let deleted = workspace.appendingPathComponent("src/deleted.txt").standardizedFileURL
        try Data("hello\n".utf8).write(to: existing)
        try Data("stale\n".utf8).write(to: deleted)

        let modifiedFile = TurnFileChanges.File(path: "src/a.txt", kind: .modified, added: 1, deleted: 0)
        let deletedFile = TurnFileChanges.File(path: "src/deleted.txt", kind: .deleted, added: 0, deleted: 3)
        let missingFile = TurnFileChanges.File(path: "src/missing.txt", kind: .added, added: 2, deleted: 0)

        XCTAssertEqual(TurnChangesRow.openableURL(for: modifiedFile, workspaceDirectory: workspace), existing)
        XCTAssertNil(TurnChangesRow.openableURL(for: deletedFile, workspaceDirectory: workspace))
        XCTAssertNil(TurnChangesRow.openableURL(for: missingFile, workspaceDirectory: workspace))
        XCTAssertNil(TurnChangesRow.openableURL(for: modifiedFile, workspaceDirectory: nil))

        var opened: [URL] = []
        if let url = TurnChangesRow.openableURL(for: modifiedFile, workspaceDirectory: workspace) {
            TranscriptFileOpener.open(url) { opened.append($0) }
        }
        XCTAssertEqual(opened, [existing])

        let changes = TurnFileChanges(files: [modifiedFile, deletedFile])
        let expansion = TurnChangesExpansion()
        expansion.folder("src", in: "turn-1").wrappedValue = true
        let row = TurnChangesRow(changes: changes, id: "turn-1", expansion: expansion,
                                 workspaceDirectory: workspace, onOpenFile: { opened.append($0) }, contentChanged: {})
            .disclosureGroupStyle(FlatDisclosureStyle())
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 40)
    }
}
