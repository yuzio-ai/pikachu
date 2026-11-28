import XCTest
import Foundation
import os
import AgentRuntimeCore
import OrchestrationCore
import WorkspacePersistence
@testable import ACPRuntimeAdapter

private actor HandoffRuntime: AgentRuntime {
    nonisolated let instanceID = UUID()
    nonisolated let events: AsyncStream<RuntimeEnvelope>
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    private var session: RuntimeSession
    private let replay: [HistoryItem]?
    private let publishesReplay: Bool
    private let sendFailure: RuntimeFailure?
    private let firstSendFailure: RuntimeFailure?
    private let refusesClose: Bool
    private let awaitsAcceptance: Bool
    private let fileChanges: [[TurnFileChanges.File]]
    private(set) var prompts: [UserPrompt] = []

    init(agent: String, sessionID: String? = nil, replay: [HistoryItem]? = nil, publishesReplay: Bool = true,
         sendFailure: RuntimeFailure? = nil, refusesClose: Bool = false,
         resumable: Bool = true, replaysHistory: Bool = true, awaitsAcceptance: Bool = false,
         fileChanges: [[TurnFileChanges.File]] = [], firstSendFailure: RuntimeFailure? = nil,
         canDelete: Bool = false) {
        let channel = AsyncStream<RuntimeEnvelope>.makeStream()
        events = channel.stream
        continuation = channel.continuation
        session = RuntimeSession(id: sessionID ?? UUID().uuidString, model: "Model", thinking: "off",
                                 capabilities: canDelete ? [.sessionDelete] : [], provider: agent, modelID: "model", runtimeID: agent,
                                 resumable: resumable, replaysHistory: replaysHistory)
        self.replay = replay
        self.publishesReplay = publishesReplay
        self.sendFailure = sendFailure
        self.firstSendFailure = firstSendFailure
        self.refusesClose = refusesClose
        self.awaitsAcceptance = awaitsAcceptance
        self.fileChanges = fileChanges
    }

    func connect() async throws -> RuntimeSession {
        if publishesReplay, let replay { emit(.historyReplayed(replay)) }
        return session
    }

    func loadedSessionHistory() async -> [HistoryItem]? { replay }
    func currentSession() async throws -> RuntimeSession { session }

    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        if selection.modelID == "unavailable" { throw RuntimeFailure(.model, "Unavailable test model") }
        session = RuntimeSession(id: session.id, model: selection.modelID, thinking: selection.thinking ?? "off",
                                 capabilities: session.capabilities, provider: selection.provider,
                                 modelID: selection.modelID, runtimeID: session.runtimeID,
                                 resumable: session.resumable, replaysHistory: session.replaysHistory)
        return session
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        prompts.append(prompt)
        if prompts.count == 1, let firstSendFailure { throw firstSendFailure }
        if let sendFailure { throw sendFailure }
        if awaitsAcceptance { return .awaitingAcceptance }
        emit(.phase(.running))
        emit(.assistantCompleted(UUID(), "Completed the task."))
        if fileChanges.indices.contains(prompts.count - 1) {
            emit(.turnFileChanges(.init(files: fileChanges[prompts.count - 1])))
        }
        emit(.settled(aborted: false))
        return .started
    }

    func stop() async throws { emit(.settled(aborted: true)) }
    func close(force: Bool) async throws {
        if refusesClose && !force { throw RuntimeFailure(.supervision, "Source cleanup unconfirmed") }
        continuation.finish()
    }
    func cancelInteractions() async {}
    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {}

    private func emit(_ event: AgentEvent) {
        continuation.yield(.init(instanceID: instanceID, event: event))
    }
}

@MainActor final class SessionHandoffTests: XCTestCase {
    private let acp = RuntimeAgentProfile.antigravityRuntimeID

    func testRemoteHistoryConfirmationCannotDeleteReplacementHandoffBinding() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = HandoffRuntime(agent: acp, sessionID: "same-remote-id", canDelete: true)
        let nextAgent = "acp:alternate"
        let next = HandoffRuntime(agent: nextAgent, sessionID: "same-remote-id", canDelete: true)
        let store = try SwiftDataWorkspaceStore(url: directory.appendingPathComponent("workspace.store"))
        let workspace = makeWorkspace(store) { _, reference, _ in reference.runtimeID == nextAgent ? next : source }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: .init(text: "Before handoff"))
        try await waitUntilIdle(workspace, id: id)
        let previous = try XCTUnwrap(workspace.remoteHistoryDeletionTarget(for: id))

        let preview = try await workspace.prepareHandoff(for: id)
        let switched = try await workspace.commitHandoff(preview, to: nextAgent, selection: nil, modelName: nil, context: "", for: id)
        XCTAssertTrue(switched)
        await workspace.send(id, submitted: .init(text: "After handoff"))
        try await waitUntilIdle(workspace, id: id)
        let current = try XCTUnwrap(workspace.remoteHistoryDeletionTarget(for: id))
        XCTAssertEqual(previous.remoteID, current.remoteID)
        XCTAssertNotEqual(previous.agentID, current.agentID)
        do {
            try await workspace.deleteRemoteHistory(previous) { _ in XCTFail("A stale confirmation sent a deletion") }
            XCTFail("The deleted target no longer matches the confirmation")
        } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .setup) }
        XCTAssertEqual(workspace.remoteHistoryDeletionTarget(for: id), current)
        _ = await workspace.disconnectAll()
    }

    func testStructuredHandoffSendsAllSelectedFilesAcrossSegmentsWithoutTruncating() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let before = "Sources/Before.swift"
        let after = "Sources/After.swift"
        let excludedPath = "Sources/ExcludeThis.swift"
        let shared = String(repeating: "a-long-folder-name-with-context/", count: 32)
        let manyFiles: [TurnFileChanges.File] = (0..<20).map {
            .init(path: "Sources/\(shared)\($0).swift", kind: .modified, added: 1, deleted: 0)
        }
        let source = HandoffRuntime(agent: acp, fileChanges: [
            manyFiles + [.init(path: before, kind: .added, added: 5, deleted: 0)],
            [.init(path: before, kind: .modified, added: 2, deleted: 1),
             .init(path: excludedPath, kind: .deleted, added: 0, deleted: 4)]
        ])
        let next = HandoffRuntime(agent: "acp:alternate", fileChanges: [[
            .init(path: after, previousPath: before, kind: .renamed, added: 1, deleted: 0)
        ]])
        let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
            reference.runtimeID == "acp:alternate" ? next : source
        }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: .init(text: "Original task"))
        try await waitUntilIdle(workspace, id: id)
        await workspace.send(id, submitted: .init(text: "Another original request"))
        try await waitUntilIdle(workspace, id: id)

        let first = try await workspace.prepareHandoff(for: id)
        XCTAssertEqual(first.draft.selectedFiles.count, 22)
        let switched = try await workspace.commitHandoff(first, to: "acp:alternate", selection: nil, modelName: nil,
                                                         context: "", draft: first.draft, for: id)
        XCTAssertTrue(switched)
        await workspace.send(id, submitted: .init(text: "Continue with Alternate"))
        try await waitUntilIdle(workspace, id: id)

        let preview = try await workspace.prepareHandoff(for: id)
        var draft = preview.draft
        XCTAssertEqual(draft.segmentCount, 2)
        XCTAssertEqual(draft.selectedFiles.count, 22)
        let renamed = try XCTUnwrap(draft.files.first { $0.path == after })
        XCTAssertEqual(renamed.previousPaths, [before])
        XCTAssertEqual(renamed.added, 8)
        XCTAssertEqual(renamed.deleted, 1)
        XCTAssertEqual(renamed.changes.count, 3)
        XCTAssertEqual(Set(renamed.changes.map(\.segmentID)).count, 2)
        draft.userRequest = "Continue the revised implementation"
        draft.excludedPaths.insert(excludedPath)
        let returned = try await workspace.commitHandoff(preview, to: acp, selection: nil, modelName: nil,
                                                          context: "", draft: draft, for: id)
        XCTAssertTrue(returned)

        let destination = HandoffRuntime(agent: acp)
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in destination }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.handoff?.draft, draft)
        await reopened.send(id, submitted: .init(text: "继续"))
        try await waitUntilIdle(reopened, id: id)
        let prompts = await destination.prompts
        XCTAssertEqual(prompts.first?.text, "继续")
        let sent = try XCTUnwrap(prompts.first?.handoffContext)
        XCTAssertGreaterThan(sent.utf8.count, 16 * 1024)
        XCTAssertTrue(sent.contains("Continue the revised implementation"))
        XCTAssertTrue(sent.contains(after))
        XCTAssertTrue(sent.contains("[added → modified → renamed]"))
        XCTAssertFalse(sent.contains(excludedPath))
        XCTAssertTrue(manyFiles.allSatisfy { sent.contains($0.path) })
        XCTAssertEqual(reopened.viewed?.activeHandoffMarker?.handoff?.context, sent)
        XCTAssertEqual(reopened.viewed?.activeHandoffMarker?.handoff?.draft?.selectedFiles.count, 21)
        let user = try XCTUnwrap(reopened.viewed?.controller.transcript.first { $0.kind == .user })
        XCTAssertEqual(user.editableText, "继续")
    }

    func testModelsAreRecordedOnlyWhenUsedAndPlacedBeforeTheAssociatedInput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let runtime = HandoffRuntime(agent: acp)
        let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in runtime }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: .init(text: "继续"))
        try await waitUntilIdle(workspace, id: id)

        let intermediate = await workspace.saveSelection(.init(provider: acp, modelID: "intermediate"), for: id)
        let final = await workspace.saveSelection(.init(provider: acp, modelID: "final"), for: id)
        XCTAssertTrue(intermediate && final)
        let second = UserPrompt(text: "继续")
        await workspace.send(id, submitted: second)
        try await waitUntilIdle(workspace, id: id)
        let reasoning = await workspace.saveSelection(.init(provider: acp, modelID: "final", thinking: "high"), for: id)
        XCTAssertTrue(reasoning)
        await workspace.send(id, submitted: .init(text: "Reasoning only"))
        try await waitUntilIdle(workspace, id: id)
        let rejected = await workspace.saveSelection(.init(provider: acp, modelID: "unavailable"), for: id)
        XCTAssertFalse(rejected)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        let rows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        let marker = try XCTUnwrap(rows.firstIndex { if case .modelChange = $0 { true } else { false } })
        XCTAssertEqual(rows.filter { if case .modelChange = $0 { true } else { false } }.count, 1)
        if case .modelChange(_, let change) = rows[marker] { XCTAssertEqual(change.title, "Model → final") }
        if case .item(let user) = rows[marker + 1] { XCTAssertEqual(user.submissionID, second.id) }
        else { XCTFail("Model event must immediately precede the input it applies to") }

        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in runtime }
        await reopened.start()
        await reopened.refreshHistory(id)
        let cached = try XCTUnwrap(reopened.viewed?.controller.transcript)
        XCTAssertEqual(cached.filter { $0.modelChange != nil }.compactMap(\.submissionID), [second.id])
        let reference = try XCTUnwrap(reopened.selected)
        for (messages, useCache, expectedRows) in [
            (["继续", "继续", "Reasoning only"], false, ["acp-replay-2"]),
            (["继续", "Reasoning only"], false, []),
            (["继续", "Reasoning only"], true, []),
            (["Unrelated", "继续", "Reasoning only"], true, [])
        ] {
            let history = messages.enumerated().flatMap { index, message in
                [
                    HistoryItem(id: "acp-replay-\(index * 2)", kind: .user, text: message),
                    HistoryItem(id: "acp-replay-\(index * 2 + 1)", kind: .assistant, text: "Done")
                ]
            }
            let replayController = SessionController()
            if useCache {
                replayController.showCachedHistory(reference.cachedHistoryItems ?? [],
                                                   recordedTurns: reference.recordedTurns ?? [],
                                                   recordedMessages: reference.recordedMessages ?? [])
            }
            await replayController.connect(HandoffRuntime(agent: acp, replay: history),
                                           recordedTurns: reference.recordedTurns ?? [],
                                           recordedMessages: reference.recordedMessages ?? [])
            try await waitUntil { replayController.transcript.first?.id == history.first?.id }
            XCTAssertEqual(replayController.transcript.filter { $0.modelChange != nil }.map(\.id), expectedRows)
            if expectedRows.isEmpty {
                XCTAssertTrue(replayController.transcript.filter { $0.editableText == "继续" }.allSatisfy { $0.submissionID == nil })
            }
            await replayController.disconnect(force: true)
        }
    }

    func testACPModelChangeSurvivesReplayCacheTruncationAndAgentSwitch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let sessionID = UUID().uuidString
        let source = HandoffRuntime(agent: acp, sessionID: sessionID)
        let original = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in source }
        let id = try await startSession(original, in: directory)
        let prior = (0..<31).map { index in UserPrompt(text: index >= 29 ? "继续" : "Request \(index)") }
        let changedInput = try XCTUnwrap(prior.last)
        let newModel = RuntimeSelection(provider: acp, modelID: "new-model")
        for prompt in prior {
            if prompt.id == changedInput.id {
                let applied = await original.saveSelection(newModel, for: id)
                XCTAssertTrue(applied)
            }
            await original.send(id, submitted: prompt)
            try await waitUntilIdle(original, id: id)
        }
        let firstClosed = await original.disconnectAll()
        XCTAssertTrue(firstClosed)
        let firstSaved = await original.flush()
        XCTAssertTrue(firstSaved)

        func replayHistory(_ prompts: [UserPrompt]) -> [HistoryItem] {
            prompts.enumerated().flatMap { index, prompt in
                [
                    .init(id: "acp-replay-\(index * 2)", kind: .user, text: prompt.text),
                    .init(id: "acp-replay-\(index * 2 + 1)", kind: .assistant, text: "Done")
                ]
            }
        }
        let onlineRuntime = HandoffRuntime(agent: acp, sessionID: sessionID, replay: replayHistory(prior))
        _ = try await onlineRuntime.applyConfiguration(newModel)
        let online = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in onlineRuntime }
        await online.start()
        let activated = await online.activate(id)
        XCTAssertTrue(activated)
        try await waitUntil { online.viewed?.controller.transcript.first?.id == "acp-replay-0" }
        let followUp = UserPrompt(text: "After online replay")
        await online.send(id, submitted: followUp)
        try await waitUntilIdle(online, id: id)
        let onlineMarkers = online.viewed?.controller.transcript.filter { $0.modelChange != nil }
        XCTAssertEqual(onlineMarkers?.compactMap(\.submissionID), [changedInput.id])
        XCTAssertEqual(onlineMarkers?.map(\.id), ["acp-replay-60"])
        XCTAssertEqual(online.selected?.cachedHistoryItems?.count, CachedTranscriptItem.maximumItemCount)
        let secondClosed = await online.disconnectAll()
        XCTAssertTrue(secondClosed)
        let secondSaved = await online.flush()
        XCTAssertTrue(secondSaved)

        let allPrompts = prior + [followUp]
        let partialHistory = replayHistory(Array(allPrompts.dropFirst()))
        let partialRuntime = HandoffRuntime(agent: acp, sessionID: sessionID, replay: partialHistory)
        _ = try await partialRuntime.applyConfiguration(newModel)
        let offline = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in partialRuntime }
        await offline.start()
        await offline.refreshHistory(id)
        XCTAssertEqual(offline.viewed?.controller.connection, .disconnected)
        let offlineMarkers = offline.viewed?.controller.transcript.filter { $0.modelChange != nil }
        XCTAssertEqual(offlineMarkers?.compactMap(\.submissionID), [changedInput.id])
        XCTAssertEqual(offlineMarkers?.map(\.id), ["acp-replay-60"])
        let reopenedOnline = await offline.activate(id)
        XCTAssertTrue(reopenedOnline)
        try await waitUntil { offline.viewed?.controller.transcript.count == partialHistory.count }
        let partialMarkers = offline.viewed?.controller.transcript.filter { $0.modelChange != nil }
        XCTAssertEqual(partialMarkers?.compactMap(\.submissionID), [changedInput.id])
        XCTAssertEqual(partialMarkers?.map(\.id), ["acp-replay-58"])
        let partialClosed = await offline.disconnectAll()
        XCTAssertTrue(partialClosed)
        let partialSaved = await offline.flush()
        XCTAssertTrue(partialSaved)

        let freezingHistory = replayHistory(Array(allPrompts.dropFirst(6)))
        let freezingReplay = HandoffRuntime(agent: acp, sessionID: sessionID, replay: freezingHistory, publishesReplay: false)
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in freezingReplay }
        await reopened.start()
        await reopened.refreshHistory(id)
        let reopenedMarkers = reopened.viewed?.controller.transcript.filter { $0.modelChange != nil }
        XCTAssertEqual(reopenedMarkers?.compactMap(\.submissionID), [changedInput.id])
        XCTAssertEqual(reopenedMarkers?.map(\.id), ["acp-replay-58"])
        let preview = try await reopened.prepareHandoff(for: id)
        let switched = try await reopened.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil,
                                                        context: "", draft: preview.draft, for: id)
        XCTAssertTrue(switched)
        let frozenMarkers = reopened.viewed?.frozenTranscript.filter { $0.modelChange != nil }
        XCTAssertEqual(frozenMarkers?.compactMap(\.submissionID), [changedInput.id])
        XCTAssertEqual(frozenMarkers?.map(\.id), ["acp-replay-48"])
    }

    func testSuccessfulHandoffMarkerFollowsARejectedAttempt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataWorkspaceStore(url: directory.appendingPathComponent("workspace.store"))
        let source = HandoffRuntime(agent: acp)
        let destination = HandoffRuntime(agent: "acp:alternate", firstSendFailure: .init(.model, "Request too large"))
        let workspace = makeWorkspace(store) { _, reference, _ in reference.runtimeID == "acp:alternate" ? destination : source }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: .init(text: "Original task"))
        try await waitUntilIdle(workspace, id: id)
        let preview = try await workspace.prepareHandoff(for: id)
        let switched = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil,
                                                         context: "", draft: preview.draft, for: id)
        XCTAssertTrue(switched)

        let rejected = UserPrompt(text: "First try")
        await workspace.send(id, submitted: rejected)
        XCTAssertEqual(workspace.selected?.handoff?.lastRejectedSubmissionID, rejected.id)
        XCTAssertEqual(workspace.selected?.handoff?.draft, preview.draft)
        XCTAssertEqual(workspace.viewed?.controller.recoveredDrafts.last?.text, rejected.text)
        XCTAssertNil(workspace.viewed?.activeHandoffMarker)

        let updated = UserPrompt(text: "Second try")
        await workspace.send(id, submitted: updated)
        try await waitUntilIdle(workspace, id: id)
        let view = try XCTUnwrap(workspace.viewed)
        let marker = try XCTUnwrap(view.activeHandoffMarker)
        let rows = TranscriptDisplayRow.placingHandoff(marker, in: TranscriptDisplayRow.project(view.controller.transcript))
        let index = try XCTUnwrap(rows.firstIndex { $0.id == marker.timelineID })
        XCTAssertEqual(marker.handoff?.firstSubmissionID, updated.id)
        XCTAssertGreaterThan(index, 0)
        if case .item(let user) = rows[index + 1] { XCTAssertEqual(user.submissionID, updated.id) }
        else { XCTFail("The handoff marker must precede the delivered input") }
    }

    func testTwoACPProcessesHandOffAConversationOverStdio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Fixtures/fake-acp.py")
        var launchedAgents: [String] = []
        let store = try SwiftDataWorkspaceStore(url: directory.appendingPathComponent("workspace.store"))
        let workspace = makeWorkspace(store) { _, reference, launch in
            launchedAgents.append(reference.runtimeID)
            let configuration = ACPConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                                 arguments: ["-u", fixture.path],
                                                 workspace: URL(fileURLWithPath: launch.workingDirectory),
                                                 runtimeID: reference.runtimeID)
            return ACPRuntime(configuration: configuration)
        }
        let id = try await startSession(workspace, in: directory)
        do {
            await workspace.send(id, submitted: .init(text: "Source milestone"))
            try await waitUntilIdle(workspace, id: id)
            let preview = try await workspace.prepareHandoff(for: id)
            let committed = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil,
                                                              modelName: nil, context: "Source milestone", for: id)
            XCTAssertTrue(committed)
            await workspace.send(id, submitted: .init(text: "Continue the work"))
            try await waitUntilIdle(workspace, id: id)
            XCTAssertEqual(launchedAgents, [acp, "acp:alternate"])
            XCTAssertEqual(workspace.selected?.id, id)
            XCTAssertEqual(workspace.selected?.handoff?.delivered, true)
            XCTAssertTrue(workspace.viewed?.frozenTranscript.contains { $0.text.contains("Source milestone") } == true)
            // The fixture echoes what it received over ACP, including the transferred context.
            XCTAssertTrue(workspace.viewed?.controller.transcript.contains {
                $0.kind == .assistant && $0.text.contains("Source milestone") && $0.text.contains("Continue the work")
            } == true)
        } catch {
            _ = await workspace.disconnectAll()
            throw error
        }
        let closed = await workspace.disconnectAll()
        XCTAssertTrue(closed)
    }

    func testHandoffPreservesConversationAndSendsContextOnlyOnce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let store = try SwiftDataWorkspaceStore(url: storeURL)
        var runtimes: [HandoffRuntime] = []
        let workspace = makeWorkspace(store) { _, reference, _ in
            let runtime = HandoffRuntime(agent: reference.runtimeID)
            runtimes.append(runtime)
            return runtime
        }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: UserPrompt(text: "Implement the original task"))
        try await waitUntilIdle(workspace, id: id)
        let originalRowIDs = workspace.viewed?.controller.transcript.map(\.timelineID)
        let file = directory.appendingPathComponent("attachment.txt")
        workspace.viewed?.controller.draft = "Continue with the next part"
        workspace.viewed?.controller.draftFiles = [file]

        let preview = try await workspace.prepareHandoff(for: id)
        XCTAssertEqual(preview.coverage, .available)
        XCTAssertTrue(preview.context.contains("Implement the original task"))
        let switched = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil, context: "Carry these results", for: id)
        XCTAssertTrue(switched)
        XCTAssertEqual(workspace.selected?.id, id)
        XCTAssertEqual(workspace.workingDirectory(for: id), directory.path)
        XCTAssertEqual(workspace.viewed?.controller.draft, "Continue with the next part")
        XCTAssertEqual(workspace.viewed?.controller.draftFiles, [file])
        XCTAssertEqual(workspace.viewed?.frozenTranscript.map(\.timelineID), originalRowIDs)
        XCTAssertEqual(runtimes.count, 1)

        let target = HandoffRuntime(agent: "acp:alternate")
        let returningAgent = HandoffRuntime(agent: acp)
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
            reference.runtimeID == "acp:alternate" ? target : returningAgent
        }
        await reopened.start()
        let activated = await reopened.activate(id)
        XCTAssertFalse(activated)
        await reopened.send(id)
        try await waitUntilIdle(reopened, id: id)
        await reopened.send(id, submitted: UserPrompt(text: "Next request"))
        try await waitUntilIdle(reopened, id: id)
        let prompts = await target.prompts
        XCTAssertEqual(prompts.map(\.text), ["Continue with the next part", "Next request"])
        XCTAssertEqual(prompts.map(\.handoffContext), ["Carry these results", nil])
        XCTAssertEqual(prompts.first?.files, [file])
        XCTAssertTrue(prompts[0].runtimeText.contains("Carry these results"))
        XCTAssertEqual(reopened.viewed?.frozenTranscript.map(\.timelineID), originalRowIDs)
        XCTAssertTrue(reopened.selected?.handoff?.delivered == true)
        XCTAssertEqual(reopened.viewed?.activeHandoffMarker?.handoff?.context, "Carry these results")

        let outgoing = try await reopened.prepareHandoff(for: id)
        let returned = try await reopened.commitHandoff(outgoing, to: acp, selection: nil, modelName: nil,
                                                        context: "Alternate completed its part", for: id)
        XCTAssertTrue(returned)
        XCTAssertEqual(reopened.selected?.id, id)
        XCTAssertNil(reopened.selected?.runtimeSessionID)
        await reopened.send(id, submitted: UserPrompt(text: "Continue from Alternate"))
        try await waitUntilIdle(reopened, id: id)
        let returnedPrompts = await returningAgent.prompts
        XCTAssertEqual(returnedPrompts.map(\.handoffContext), ["Alternate completed its part"])
        let frozen = try XCTUnwrap(reopened.viewed?.frozenTranscript)
        XCTAssertEqual(frozen.compactMap(\.handoff).map(\.targetAgent), ["Alternate"])
        XCTAssertEqual(Set(frozen.map(\.timelineID)).count, frozen.count)
        XCTAssertEqual(reopened.viewed?.activeHandoffMarker?.handoff?.targetAgent, "Antigravity")
    }

    func testOfflineACPReplayAndRetargetReuseOriginalSegment() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataWorkspaceStore(url: directory.appendingPathComponent("workspace.store"))
        let remote = HandoffRuntime(agent: acp, sessionID: "remote", replay: [
            .init(id: "request", kind: .user, text: "Keep my history"),
            .init(id: "response", kind: .assistant, text: "Original response.")
        ])
        let workspace = makeWorkspace(store) { _, _, _ in remote }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset(), .customACP(id: "acp:alternate", name: "Alternate", executablePath: "/unused"), .customACP(id: "acp:other", name: "Other", executablePath: "/unused")])
        let project = await workspace.addProject(directory, createInitialSession: false)
        let projectID = try XCTUnwrap(project)
        let remoteSession = RuntimeRemoteSession(id: "remote", directory: directory.path, title: "Old task")
        let imported = await workspace.importRemoteSession(remoteSession, projectID: projectID, agentID: acp, canRestore: true, canDelete: false)
        let id = try XCTUnwrap(imported)
        let preview = try await workspace.prepareHandoff(for: id)
        XCTAssertEqual(preview.coverage, .available)
        XCTAssertTrue(preview.context.contains("Original response"))
        let switched = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil, context: "", for: id)
        XCTAssertTrue(switched)
        let retargetPreview = try await workspace.prepareHandoff(for: id)
        let retargeted = try await workspace.commitHandoff(retargetPreview, to: "acp:other", selection: nil, modelName: nil, context: "edited", for: id)
        XCTAssertTrue(retargeted)
        XCTAssertEqual(workspace.viewed?.frozenTranscript.count, 2)
        XCTAssertEqual(workspace.selected?.handoff?.sourceAgent, "Antigravity")
        XCTAssertEqual(workspace.selected?.handoff?.targetAgent, "Other")
        let duplicate = await workspace.importRemoteSession(remoteSession, projectID: projectID, agentID: acp, canRestore: true, canDelete: false)
        XCTAssertEqual(duplicate, id)
        XCTAssertEqual(workspace.state.sessions.count, 1)
        let prompts = await remote.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testUnconfirmedCleanupLeavesSourceAndDraftInPlace() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = HandoffRuntime(agent: acp, refusesClose: true)
        let store = try SwiftDataWorkspaceStore(url: directory.appendingPathComponent("workspace.store"))
        let workspace = makeWorkspace(store) { _, _, _ in source }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: UserPrompt(text: "Run the source task"))
        try await waitUntilIdle(workspace, id: id)
        workspace.viewed?.controller.draft = "Pending draft"
        let preview = try await workspace.prepareHandoff(for: id)
        do {
            _ = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil, context: "", for: id)
            XCTFail("Expected source cleanup to fail")
        } catch {
            XCTAssertEqual(workspace.selected?.runtimeID, acp)
            XCTAssertEqual(workspace.viewed?.controller.draft, "Pending draft")
            XCTAssertNil(workspace.selected?.handoff)
            XCTAssertEqual(workspace.viewed?.controller.connection, .blocked)
        }
        _ = await workspace.disconnect(id, force: true)
    }

    func testUnknownFirstDeliveryIsNotResentAfterRestart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let store = try SwiftDataWorkspaceStore(url: storeURL)
        let workspace = makeWorkspace(store) { _, reference, _ in
            HandoffRuntime(agent: reference.runtimeID,
                           sendFailure: reference.runtimeID == "acp:alternate" ? RuntimeFailure(.outcomeUnknown, "Transport lost") : nil)
        }
        let id = try await startSession(workspace, in: directory)
        await workspace.send(id, submitted: UserPrompt(text: "Source request"))
        try await waitUntilIdle(workspace, id: id)
        let preview = try await workspace.prepareHandoff(for: id)
        let switched = try await workspace.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil, context: "old context", for: id)
        XCTAssertTrue(switched)
        await workspace.send(id, submitted: UserPrompt(text: "Possibly sent"))
        let pendingID = try XCTUnwrap(workspace.selected?.handoff?.firstSubmissionID)
        let target = HandoffRuntime(agent: "acp:alternate")
        let receipt = try XCTUnwrap(workspace.selected?.handoffCleanupID)
        let cleanupConfirmed = OSAllocatedUnfairLock(initialState: false)
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL),
                                     verifyHandoffCleanup: { $0 == receipt && cleanupConfirmed.withLock { $0 } }) { _, _, _ in target }
        await reopened.start()
        await reopened.send(id, submitted: UserPrompt(text: "Do not resend pending work"))
        let prompts = await target.prompts
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(reopened.selected?.handoff?.firstSubmissionID, pendingID)
        XCTAssertNotNil(reopened.handoffBlockReason(for: id))
        await reopened.reviewSubmission(pendingID, in: id)
        await reopened.restoreReviewedSubmission(pendingID, in: id)
        XCTAssertEqual(reopened.selected?.handoff?.firstSubmissionID, pendingID)
        cleanupConfirmed.withLock { $0 = true }
        await reopened.reviewSubmission(pendingID, in: id)
        await reopened.restoreReviewedSubmission(pendingID, in: id)
        XCTAssertNil(reopened.selected?.handoff?.firstSubmissionID)
        XCTAssertEqual(reopened.viewed?.controller.draft, "Possibly sent")
    }

    func testACPPromptKeepsHandoffAndFileReferenceInSingleSubmission() throws {
        let prompt = UserPrompt(text: "Run the next check", files: [URL(fileURLWithPath: "/tmp/example.txt")],
                                handoffContext: "Previously ran the first check")
        let blocks = ACPConnection.buildPromptBlocks(prompt: prompt, supportsImage: false)
        XCTAssertEqual(blocks.count, 1)
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertTrue(text.contains("Previously ran the first check"))
        XCTAssertTrue(text.contains("Run the next check"))
        XCTAssertTrue(text.contains("/tmp/example.txt"))
    }

    func testEmptyACPReplayKeepsPartialHistoryThroughHandoffAndRestart() async throws {
        for replay in [nil, [HistoryItem]()] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let storeURL = directory.appendingPathComponent("workspace.store")
            let source = HandoffRuntime(agent: acp, sessionID: "source")
            let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in source }
            let id = try await startSession(workspace, in: directory)
            await workspace.send(id, submitted: .init(text: "Cached request"))
            try await waitUntilIdle(workspace, id: id)
            let closed = await workspace.disconnect(id)
            XCTAssertTrue(closed)

            let emptyReplay = HandoffRuntime(agent: acp, sessionID: "source", replay: replay)
            let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in emptyReplay }
            await reopened.start()
            let preview = try await reopened.prepareHandoff(for: id)
            XCTAssertEqual(preview.coverage, .partial)
            XCTAssertTrue(preview.excerpts.contains { $0.text == "Cached request" })
            let switched = try await reopened.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil, context: "", for: id)
            XCTAssertTrue(switched)
            XCTAssertTrue(reopened.viewed?.frozenTranscript.contains { $0.editableText == "Cached request" } == true)

            let restored = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in emptyReplay }
            await restored.start()
            XCTAssertEqual(restored.selected?.handoff?.coverage, .partial)
            XCTAssertTrue(restored.viewed?.frozenTranscript.contains { $0.editableText == "Cached request" } == true)
        }
    }

    func testLateAcceptanceAfterDisconnectPreservesConfirmedReceiptAcrossRestart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let source = HandoffRuntime(agent: acp)
        let target = HandoffRuntime(agent: "acp:other", awaitsAcceptance: true)
        let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
            reference.runtimeID == "acp:other" ? target : source
        }
        let id = try await startOtherACPHandoff(workspace, in: directory)
        let prompt = UserPrompt(text: "Target accepts just before disconnect")
        await workspace.send(id, submitted: prompt)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.receive(.init(instanceID: target.instanceID, event: .disconnected(cleanupConfirmed: true)))
        try await waitUntil { workspace.selected?.submissions.first?.delivery == .unknown }
        controller.receive(.init(instanceID: source.instanceID, event: .promptAcceptance(prompt.id, .accepted)))
        XCTAssertEqual(controller.transcript.last?.delivery, .unknown)
        controller.receive(.init(instanceID: target.instanceID, event: .promptAcceptance(prompt.id, .accepted)))
        controller.receive(.init(instanceID: target.instanceID, event: .promptAcceptance(prompt.id, .unknown)))
        try await waitUntil { workspace.selected?.handoff?.delivered == true }
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(controller.transcript.last?.delivery, .accepted)

        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, _, _ in target }
        await reopened.start()
        XCTAssertEqual(reopened.selected?.handoff?.delivered, true)
        await reopened.reviewSubmission(prompt.id, in: id)
        await reopened.restoreReviewedSubmission(prompt.id, in: id)
        XCTAssertEqual(reopened.viewed?.controller.draft, "")
        let sent = await target.prompts
        XCTAssertEqual(sent.count, 1)
    }

    func testConfirmedNonDeliveryLetsNonResumableACPCreateAFreshSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("workspace.store")
        let source = HandoffRuntime(agent: acp)
        let oldTarget = HandoffRuntime(agent: "acp:other", sessionID: "old-target",
                                       sendFailure: .init(.outcomeUnknown, "Transport disconnected"), resumable: false)
        let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
            reference.runtimeID == "acp:other" ? oldTarget : source
        }
        let id = try await startOtherACPHandoff(workspace, in: directory)
        let file = directory.appendingPathComponent("prompt.txt")
        let prompt = UserPrompt(text: "This did not arrive", files: [file])
        await workspace.send(id, submitted: prompt)
        XCTAssertEqual(workspace.selected?.runtimeSessionID, "old-target")
        let closed = await workspace.disconnect(id, force: true)
        XCTAssertTrue(closed)

        let freshTarget = HandoffRuntime(agent: "acp:other", sessionID: "new-target", resumable: false)
        var attemptedBindings: [String?] = []
        let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
            attemptedBindings.append(reference.runtimeSessionID)
            return freshTarget
        }
        await reopened.start()
        await reopened.reviewSubmission(prompt.id, in: id)
        await reopened.restoreReviewedSubmission(prompt.id, in: id)
        XCTAssertNil(reopened.selected?.runtimeSessionID)
        XCTAssertNil(reopened.selected?.handoff?.firstSubmissionID)
        XCTAssertNil(reopened.viewed?.executionIssue)
        XCTAssertEqual(reopened.viewed?.controller.draft, prompt.text)
        XCTAssertEqual(reopened.viewed?.controller.draftFiles, prompt.files)
        await reopened.send(id)
        try await waitUntilIdle(reopened, id: id)
        let sent = await freshTarget.prompts
        XCTAssertEqual(attemptedBindings, [nil])
        XCTAssertEqual(sent.map(\.text), [prompt.text])
        XCTAssertEqual(sent.first?.files, prompt.files)
        XCTAssertEqual(sent.first?.handoffContext, "Carry this context")
        XCTAssertEqual(reopened.selected?.runtimeSessionID, "new-target")
        XCTAssertTrue(reopened.viewed?.frozenTranscript.contains { $0.editableText == "Seed" } == true)
    }


    func testLateExplicitRejectionLetsNonResumableACPCreateAFreshSession() async throws {
        for cleanupConfirmed in [true, false] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let storeURL = directory.appendingPathComponent("workspace.store")
            let source = HandoffRuntime(agent: acp)
            let target = HandoffRuntime(agent: "acp:other", sessionID: "old-target",
                                        resumable: false, awaitsAcceptance: true)
            let workspace = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
                reference.runtimeID == "acp:other" ? target : source
            }
            let id = try await startOtherACPHandoff(workspace, in: directory)
            let prompt = UserPrompt(text: "The runtime eventually rejects this")
            await workspace.send(id, submitted: prompt)
            let controller = try XCTUnwrap(workspace.viewed?.controller)
            controller.receive(.init(instanceID: target.instanceID, event: .disconnected(cleanupConfirmed: cleanupConfirmed)))
            try await waitUntil {
                workspace.selected?.submissions.first?.delivery == .unknown &&
                    workspace.selected?.recordedMessages?.contains { $0.id == prompt.id } == true
            }
            let unknownSaved = await workspace.flush()
            XCTAssertTrue(unknownSaved)
            XCTAssertEqual(workspace.selected?.runtimeSessionID, "old-target")
            controller.receive(.init(instanceID: target.instanceID, event: .promptAcceptance(prompt.id, .rejected)))
            try await waitUntil { workspace.selected?.handoff?.firstSubmissionID == nil }
            XCTAssertEqual(controller.recoveredDrafts.first?.id, prompt.id)
            controller.restoreDraft(prompt.id)
            if !cleanupConfirmed {
                XCTAssertEqual(workspace.selected?.runtimeSessionID, "old-target")
                await workspace.send(id)
                let attempted = await target.prompts
                XCTAssertEqual(attempted.map(\.id), [prompt.id])
                XCTAssertEqual(controller.draft, prompt.text)
                let closed = await workspace.disconnect(id, force: true)
                XCTAssertTrue(closed)
            }
            XCTAssertNil(workspace.selected?.runtimeSessionID)
            let draftSaved = await workspace.flush()
            XCTAssertTrue(draftSaved)

            let fresh = HandoffRuntime(agent: "acp:other", sessionID: "new-target", resumable: false)
            var attemptedBindings: [String?] = []
            let reopened = makeWorkspace(try SwiftDataWorkspaceStore(url: storeURL)) { _, reference, _ in
                attemptedBindings.append(reference.runtimeSessionID)
                return fresh
            }
            await reopened.start()
            XCTAssertEqual(reopened.viewed?.controller.draft, prompt.text)
            XCTAssertNil(reopened.selected?.runtimeSessionID)
            XCTAssertFalse(reopened.selected?.cachedHistoryItems?.contains { $0.text == prompt.text } == true)
            await reopened.send(id)
            let sent = await fresh.prompts
            XCTAssertEqual(attemptedBindings, [nil])
            XCTAssertEqual(sent.map(\.text), [prompt.text])
            XCTAssertEqual(sent.first?.handoffContext, "Carry this context")
        }
    }

    func testRestartBlocksExecutionAndRetargetUntilMatchingACPCleanupIsConfirmed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rejected = try await persistRejectedHandoffWithUnknownCleanup(in: directory)
        let store = try SwiftDataWorkspaceStore(url: rejected.storeURL)
        var launched: [String] = []
        let next = HandoffRuntime(agent: "acp:alternate")
        let restarted = makeWorkspace(store, verifyHandoffCleanup: {
            ACPHandoffCleanup(root: directory, id: $0).isConfirmed
        }) { _, reference, _ in
            launched.append(reference.runtimeID)
            return next
        }
        await restarted.start()

        let receipt = ACPHandoffCleanup(root: directory, id: rejected.cleanupID).directory
        let terminal = receipt.appendingPathComponent("zivvi-terminal-\(UUID().uuidString)")
        for status in ["missing", "different instance", "terminal still cleaning"] {
            if status == "different instance" {
                try writeCleanupReport(in: receipt, supervisionID: UUID().uuidString)
            } else if status == "terminal still cleaning" {
                try writeCleanupReport(in: receipt)
                try writeCleanupReport(in: terminal, clean: false)
            }
            await restarted.refreshHistory(rejected.id)
            XCTAssertTrue(restarted.isHandoffCleanupPending(for: rejected.id), status)
            XCTAssertNotNil(restarted.viewed?.executionIssue, status)
            XCTAssertNotNil(restarted.handoffBlockReason(for: rejected.id), status)
            do {
                _ = try await restarted.prepareHandoff(for: rejected.id)
                XCTFail("Allowed preview with \(status) cleanup")
            } catch let failure as RuntimeFailure {
                XCTAssertEqual(failure.kind, .setup)
            }
            await restarted.send(rejected.id)
            XCTAssertEqual(restarted.selected?.runtimeID, "acp:other")
            XCTAssertEqual(restarted.selected?.runtimeSessionID, "old-target")
            XCTAssertEqual(restarted.viewed?.controller.draft, rejected.prompt.text)
            XCTAssertTrue(launched.isEmpty)
        }

        try writeCleanupReport(in: terminal)
        await restarted.refreshHistory(rejected.id)
        XCTAssertNil(restarted.viewed?.executionIssue)
        let preview = try await restarted.prepareHandoff(for: rejected.id)
        let changed = try await restarted.commitHandoff(preview, to: "acp:alternate", selection: nil, modelName: nil,
                                                        context: "Retarget", for: rejected.id)
        XCTAssertTrue(changed)
        XCTAssertTrue(launched.isEmpty)
        await restarted.send(rejected.id)
        XCTAssertEqual(launched, ["acp:alternate"])
        let prompts = await next.prompts
        XCTAssertEqual(prompts.map(\.text), [rejected.prompt.text])
        XCTAssertEqual(prompts.first?.handoffContext, "Retarget")
    }

    func testRestartWithMatchingACPCleanupLetsOriginalTargetRetryOnce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rejected = try await persistRejectedHandoffWithUnknownCleanup(in: directory)
        let receipt = ACPHandoffCleanup(root: directory, id: rejected.cleanupID).directory
        try writeCleanupReport(in: receipt)
        try writeCleanupReport(in: receipt.appendingPathComponent("zivvi-terminal-\(UUID().uuidString)"))
        let store = try SwiftDataWorkspaceStore(url: rejected.storeURL)
        let fresh = HandoffRuntime(agent: "acp:other", sessionID: "new-target", resumable: false)
        var bindings: [String?] = []
        let restarted = makeWorkspace(store, verifyHandoffCleanup: {
            ACPHandoffCleanup(root: directory, id: $0).isConfirmed
        }) { _, reference, _ in
            XCTAssertEqual(reference.runtimeID, "acp:other")
            bindings.append(reference.runtimeSessionID)
            return fresh
        }
        await restarted.start()
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertNil(restarted.selected?.runtimeSessionID)
        XCTAssertNil(restarted.selected?.handoffCleanupID)
        XCTAssertNil(restarted.handoffBlockReason(for: rejected.id))
        XCTAssertEqual(restarted.viewed?.controller.draft, rejected.prompt.text)
        XCTAssertEqual(restarted.viewed?.controller.draftFiles, rejected.prompt.files)
        let restored = try await store.load()
        XCTAssertNil(restored.sessions.first { $0.id == rejected.id }?.handoffCleanupID)

        await restarted.send(rejected.id)
        let prompts = await fresh.prompts
        XCTAssertEqual(bindings, [nil])
        XCTAssertEqual(prompts.map(\.text), [rejected.prompt.text])
        XCTAssertEqual(prompts.first?.files, rejected.prompt.files)
        XCTAssertEqual(prompts.first?.handoffContext, "Carry this context")
    }

    func testHandoffContextEditKeepsACPCleanupAcrossRestart() async throws {
        for resumable in [false, true] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let context = "Edited before the target finished cleaning up"
            let rejected = try await persistRejectedHandoffWithUnknownCleanup(in: directory, resumable: resumable,
                                                                            editedContext: context)
            let fresh = HandoffRuntime(agent: "acp:other", sessionID: "replacement", resumable: resumable)
            var launched: [String] = []
            let restarted = makeWorkspace(try SwiftDataWorkspaceStore(url: rejected.storeURL), verifyHandoffCleanup: {
                ACPHandoffCleanup(root: directory, id: $0).isConfirmed
            }) { _, reference, _ in
                launched.append(reference.runtimeID)
                return fresh
            }
            await restarted.start()
            XCTAssertEqual(restarted.selected?.handoff?.context, context)
            XCTAssertEqual(restarted.selected?.handoffCleanupID, rejected.cleanupID)
            XCTAssertTrue(restarted.isHandoffCleanupPending(for: rejected.id))
            XCTAssertNotNil(restarted.handoffBlockReason(for: rejected.id))
            await restarted.send(rejected.id)
            XCTAssertTrue(launched.isEmpty)

            let receipt = ACPHandoffCleanup(root: directory, id: rejected.cleanupID)
            try writeCleanupReport(in: receipt.directory)
            await restarted.refreshHistory(rejected.id)
            XCTAssertNil(restarted.selected?.handoffCleanupID)
            XCTAssertNil(restarted.handoffBlockReason(for: rejected.id))
            XCTAssertTrue(launched.isEmpty)
            await restarted.send(rejected.id)
            let prompts = await fresh.prompts
            XCTAssertEqual(launched, ["acp:other"])
            XCTAssertEqual(prompts.map(\.text), [rejected.prompt.text])
            XCTAssertEqual(prompts.first?.handoffContext, context)
        }
    }

    private func persistRejectedHandoffWithUnknownCleanup(in directory: URL, resumable: Bool = false,
                                                         editedContext: String? = nil) async throws
        -> (storeURL: URL, id: UUID, cleanupID: UUID, prompt: UserPrompt) {
        let storeURL = directory.appendingPathComponent("workspace.store")
        let store = try SwiftDataWorkspaceStore(url: storeURL)
        weak var previousWorkspace: WorkspaceController?
        let rejected: (id: UUID, cleanupID: UUID, prompt: UserPrompt)
        do {
            let result = try await persistRejectedHandoff(in: directory, using: store, resumable: resumable,
                                                          editedContext: editedContext)
            previousWorkspace = result.workspace
            rejected = (result.id, result.cleanupID, result.prompt)
        }
        // The real app has an exclusive workspace lock. Wait for the old
        // controller's queued saves to finish before opening the same database.
        try await waitUntil { previousWorkspace == nil }
        return (storeURL, rejected.id, rejected.cleanupID, rejected.prompt)
    }

    private func persistRejectedHandoff(in directory: URL, using store: SwiftDataWorkspaceStore,
                                        resumable: Bool, editedContext: String?) async throws
        -> (workspace: WorkspaceController, id: UUID, cleanupID: UUID, prompt: UserPrompt) {
        let source = HandoffRuntime(agent: acp)
        let target = HandoffRuntime(agent: "acp:other", sessionID: "old-target",
                                    resumable: resumable, awaitsAcceptance: true)
        var targetLaunchID: UUID?
        let workspace = makeWorkspace(store) { _, reference, launch in
            guard reference.runtimeID == "acp:other" else { return source }
            targetLaunchID = launch.handoffCleanupID
            return target
        }
        let id = try await startOtherACPHandoff(workspace, in: directory)
        let attachment = directory.appendingPathComponent("prompt.txt")
        let prompt = UserPrompt(text: "The target rejected this before cleanup", files: [attachment])
        await workspace.send(id, submitted: prompt)
        let cleanupID = try XCTUnwrap(targetLaunchID)
        let submitted = try await store.load()
        XCTAssertEqual(submitted.sessions.first { $0.id == id }?.handoffCleanupID, cleanupID)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        if editedContext == nil {
            controller.receive(.init(instanceID: target.instanceID, event: .disconnected(cleanupConfirmed: false)))
            try await waitUntil { workspace.selected?.submissions.first?.delivery == .unknown }
        }
        controller.receive(.init(instanceID: target.instanceID, event: .promptAcceptance(prompt.id, .rejected)))
        try await waitUntil { workspace.selected?.handoff?.firstSubmissionID == nil }
        controller.restoreDraft(prompt.id)
        if let editedContext {
            XCTAssertEqual(controller.connection, .connected)
            let edited = await workspace.updateHandoffContext(editedContext, for: id)
            XCTAssertTrue(edited)
        } else {
            XCTAssertEqual(controller.connection, .blocked)
            XCTAssertEqual(workspace.selected?.runtimeSessionID, "old-target")
        }
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        return (workspace, id, cleanupID, prompt)
    }

    private func writeCleanupReport(in directory: URL, supervisionID: String? = nil, clean: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["supervisionID": supervisionID ?? directory.lastPathComponent,
                                     "state": clean ? "clean" : "cleaning", "remaining": clean ? 0 : 1]
        try JSONSerialization.data(withJSONObject: report)
            .write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    private func makeWorkspace(
        _ store: SwiftDataWorkspaceStore,
        verifyHandoffCleanup: @escaping @MainActor (UUID) -> Bool = { _ in false },
        runtimeFactory: @escaping @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime
    ) -> WorkspaceController {
        WorkspaceController(store: store, verifyHandoffCleanup: verifyHandoffCleanup, inspectRuntimeModels: { _, _ in
            RuntimeConfigurationOptions(models: [], thinkingLevels: [])
        }, runtimeFactory: runtimeFactory)
    }

    private func startOtherACPHandoff(_ workspace: WorkspaceController, in directory: URL) async throws -> UUID {
        let id = try await startSession(workspace, in: directory)
        workspace.setACPAgents([.antigravityPreset(), .customACP(id: "acp:alternate", name: "Alternate", executablePath: "/unused"), .customACP(id: "acp:other", name: "Other", executablePath: "/unused")])
        await workspace.send(id, submitted: .init(text: "Seed"))
        try await waitUntilIdle(workspace, id: id)
        let preview = try await workspace.prepareHandoff(for: id)
        let switched = try await workspace.commitHandoff(preview, to: "acp:other", selection: nil, modelName: nil,
                                                         context: "Carry this context", for: id)
        XCTAssertTrue(switched)
        return id
    }


    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.resolvingSymlinksInPath()
    }

    private func startSession(_ workspace: WorkspaceController, in directory: URL) async throws -> UUID {
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset(), .customACP(id: "acp:alternate", name: "Alternate", executablePath: "/unused")])
        workspace.setDefaultRuntimeID(acp)
        _ = await workspace.addProject(directory)
        return try XCTUnwrap(workspace.selected?.id)
    }

    private func waitUntilIdle(_ workspace: WorkspaceController, id: UUID) async throws {
        for _ in 0..<100 {
            if workspace.execution(for: id)?.phase == .idle { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Runtime did not settle")
    }
}
