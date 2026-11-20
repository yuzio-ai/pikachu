import Foundation
import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
import OrchestrationCore
@testable import PiRuntimeAdapter
@testable import Pikachu

final class TurnFileChangesTests: XCTestCase {
    func testGitFollowUpClosesPreviousTurnAndSteeringKeepsItsBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let folder = scratch.appendingPathComponent("round-ABC123", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        func checkpoint(_ phase: String, _ tree: String) -> [String: Any] {
            ["type": "extension_ui_request", "method": "setStatus", "statusKey": PiTurnFileChanges.statusKey,
             "statusText": #"{"phase":"\#(phase)","tree":"\#(tree)","folder":"round-ABC123"}"#]
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func tree(_ paths: String...) throws -> String {
            _ = try git(["add", "--"] + paths)
            return try git(["write-tree"])
        }

        _ = try git(["init", "-q"])
        _ = try git(["init", "-q", "--bare", "--template=", folder.path])
        let alternates = folder.appendingPathComponent("objects/info/alternates")
        try (root.appendingPathComponent(".git/objects").path + "\n").write(to: alternates, atomically: true, encoding: .utf8)
        try write("existing.txt", "before turn\n")
        let start = try tree("existing.txt")
        try write("first.txt", "first\n")
        let steering = try tree("first.txt")
        _ = try git(["mv", "existing.txt", "renamed\tfile.txt"])
        try Data([0, 1]).write(to: root.appendingPathComponent("data.bin"))
        let followUp = try tree("data.bin")
        try write("second.txt", "second\n")
        let end = try tree("second.txt")

        var reporter = PiTurnFileChanges(scratch: scratch)
        XCTAssertTrue(reporter.map(checkpoint("start", start), events: []).isEmpty)
        XCTAssertTrue(reporter.map([:], events: [.queue(.init(steering: ["interrupt"], followUp: ["next"]))]).count == 1)
        XCTAssertTrue(reporter.map([:], events: [.queue(.init(followUp: ["next"]))]).count == 1)
        XCTAssertTrue(reporter.map(checkpoint("user", steering), events: []).isEmpty)
        XCTAssertTrue(reporter.map([:], events: [.queue(.init())]).isEmpty)
        XCTAssertTrue(reporter.map([:], events: [.queue(.init(followUp: ["later"]))]).isEmpty)
        let first = try XCTUnwrap(reporter.map(checkpoint("user", followUp), events: []).first)
        guard case .turnFileChanges(let firstChanges) = first else { return XCTFail("Expected changes before dequeue") }
        XCTAssertEqual(Set(firstChanges.files.map(\.path)), ["first.txt", "data.bin", "renamed\tfile.txt"])
        XCTAssertEqual(firstChanges.files.first { $0.kind == .renamed }?.previousPath, "existing.txt")
        XCTAssertEqual(firstChanges.files.first { $0.path == "first.txt" }?.added, 1)
        XCTAssertNil(firstChanges.files.first { $0.path == "data.bin" }?.added)
        let next = reporter.map([:], events: [.userMessageTimestamp(1_795_000_000_000)])
        XCTAssertEqual(next.count, 3)
        guard case .queue(let release) = next.first else { return XCTFail("Expected original queue removal") }
        XCTAssertTrue(release.isEmpty)

        let second = try XCTUnwrap(reporter.map(checkpoint("end", end), events: []).first)
        guard case .turnFileChanges(let secondChanges) = second else { return XCTFail("Expected second turn changes") }
        XCTAssertEqual(secondChanges.files.map(\.path), ["second.txt"])
        XCTAssertEqual(secondChanges.files.first?.added, 1)
        _ = reporter.map([:], events: [.settled(aborted: false)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
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
}
