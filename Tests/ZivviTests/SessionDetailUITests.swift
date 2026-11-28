import AppKit
import Foundation
import Observation
import os
import SwiftUI
import Vision
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

private final class TestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var mono: ContinuousClock.Instant

    init(wall: Date = Date(timeIntervalSince1970: 1_795_000_000), mono: ContinuousClock.Instant = ContinuousClock.now) {
        self.wall = wall
        self.mono = mono
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            mono = mono.advanced(by: .milliseconds(Int64((seconds * 1000).rounded())))
        }
    }

    func now() -> Date { lock.withLock { wall } }
    func monotonicNow() -> ContinuousClock.Instant { lock.withLock { mono } }
}

private actor MemoryStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private actor PausedACPSettingsProbe {
    private var pending: CheckedContinuation<RuntimeConnectionCheckResult, Never>?
    private var earlyResult: RuntimeConnectionCheckResult?

    func run(started: XCTestExpectation) async -> RuntimeConnectionCheckResult {
        if let earlyResult {
            started.fulfill()
            return earlyResult
        }
        return await withCheckedContinuation {
            pending = $0
            started.fulfill()
        }
    }

    func complete(_ result: RuntimeConnectionCheckResult) {
        if let pending {
            pending.resume(returning: result)
            self.pending = nil
        } else {
            earlyResult = result
        }
    }
}

private actor PausedACPSettingsStore: WorkspaceStore {
    private var snapshot: WorkspaceSnapshot
    private var savingStarted: XCTestExpectation?
    private var resumeSave: CheckedContinuation<Void, Never>?
    private var failNext = false

    init(snapshot: WorkspaceSnapshot) { self.snapshot = snapshot }

    func load() -> WorkspaceSnapshot { snapshot }

    func pauseNextSave(started: XCTestExpectation) { savingStarted = started }

    func failNextSave() { failNext = true }

    func save(_ value: WorkspaceSnapshot) async throws {
        if let savingStarted {
            self.savingStarted = nil
            await withCheckedContinuation { resume in
                resumeSave = resume
                savingStarted.fulfill()
            }
        }
        if failNext {
            failNext = false
            throw CocoaError(.fileWriteUnknown)
        }
        snapshot = value
    }

    func releaseSave() {
        savingStarted = nil
        resumeSave?.resume()
        resumeSave = nil
    }
}

private final class StubSessionRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    let sessionID: String
    let resumable: Bool
    let file: URL?
    let connectionFailure: RuntimeFailure?
    let runtimeID: String?
    let disposition: @Sendable (UserPrompt) -> PromptDisposition
    var usageResponses: [Result<RuntimeUsage, Error>] = []
    private let lock = NSLock()
    private var interactionReplies: [InteractionResponse] = []
    var recordedInteractionReplies: [InteractionResponse] { lock.withLock { interactionReplies } }

    init(sessionID: String = "stub-session", file: URL? = nil, resumable: Bool = false, connectionFailure: RuntimeFailure? = nil,
         runtimeID: String? = nil,
         disposition: @escaping @Sendable (UserPrompt) -> PromptDisposition = { _ in .started }) {
        self.sessionID = sessionID
        self.file = file
        self.resumable = resumable
        self.connectionFailure = connectionFailure
        self.runtimeID = runtimeID
        self.disposition = disposition
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        if let connectionFailure { throw connectionFailure }
        return .init(id: sessionID, model: "GPT-5.4", thinking: "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: "openai", modelID: "gpt-5.4", runtimeID: runtimeID, resumable: resumable)
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { disposition(prompt) }
    func stop() async throws { emit(.settled(aborted: true)) }
    func close(force: Bool) async throws { emit(.disconnected(cleanupConfirmed: true)); continuation.finish() }
    func respond(to request: RuntimeInteraction, with response: InteractionResponse) async throws {
        lock.withLock { interactionReplies.append(response) }
        emit(.interactionEnded(request.id, response == .cancelled ? .cancelled : .answered))
    }
    func configurationOptions() async throws -> RuntimeConfigurationOptions {
        .init(models: [.init(provider: "openai", modelID: "gpt-5.4", name: "GPT-5.4")], thinkingLevels: ["low", "high"])
    }
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        .init(id: sessionID, model: selection.modelID, thinking: selection.thinking ?? "high", capabilities: [.streaming, .tools, .interruption, .queuedPrompts], file: file, provider: selection.provider, modelID: selection.modelID)
    }
    func enqueueUsage(_ result: Result<RuntimeUsage, Error>) {
        lock.withLock { usageResponses.append(result) }
    }
    func usage() async throws -> RuntimeUsage {
        let next = lock.withLock { usageResponses.isEmpty ? nil : usageResponses.removeFirst() }
        if let next { return try next.get() }
        return RuntimeUsage(sessionID: sessionID)
    }
    func emit(_ event: AgentEvent) { continuation.yield(.init(instanceID: instanceID, event: event)) }
}

@MainActor @Observable private final class TestExtensionStatusExpansion {
    var expanded = false
}

final class SessionDetailUITests: XCTestCase {
    func testFlatMenuExecutesOnlyTheFirstActionAfterClosing() {
        var pending = FlatMenuPendingAction()
        var executed: [Int] = []
        XCTAssertTrue(pending.schedule { executed.append(1) })
        XCTAssertFalse(pending.schedule { executed.append(2) })
        XCTAssertTrue(executed.isEmpty)
        pending.take()?()
        XCTAssertNil(pending.take())
        XCTAssertEqual(executed, [1])
    }

    func testHiddenDefaultModelRetainsItsRowBadgesWhenUnavailable() {
        let model = RuntimeModel(provider: "openai", modelID: "snapshot", name: "Snapshot")
        var preferences = WorkspaceModelPreferences()
        preferences.defaultModel = model
        preferences.favorites = [model]
        preferences.hiddenModelIDs = [model.id]
        let catalogue = ModelSettingsCatalogue(models: [], preferences: preferences)

        for (verified, availability) in [(true, ModelSettingsRowStatus.Availability.unavailable), (false, .unverified)] {
            let status = catalogue.rowStatus(for: model.id, verified: verified)
            XCTAssertTrue(status.favorite)
            XCTAssertTrue(status.isDefault)
            XCTAssertEqual(status.availability, availability)
            XCTAssertNotNil(status.availability.title)
        }
    }


    func testModelSettingsKeepStarAndSectionConsistent() {
        let sol = RuntimeModel(provider: "openai", modelID: "gpt-6.2-sol", name: "GPT-6.2 Sol")
        let flash = RuntimeModel(provider: "deepseek", modelID: "deepseek-flash", name: "DeepSeek V4.1 Flash")
        let other = RuntimeModel(provider: "openai", modelID: "gpt-4.1", name: "GPT-4.1")
        let groups = ModelListSection.group([sol, flash, other], favorites: [sol.id, flash.id], hidden: [other.id])
        XCTAssertEqual(groups.map(\.section), [.favorites, .hidden])
        XCTAssertEqual(groups[0].models.map(\.id), [sol.id, flash.id])
        XCTAssertEqual(groups[1].models.map(\.id), [other.id])

        // Switching a favorite off must not duplicate it, and it keeps its star.
        let toggledOff = ModelListSection.group([sol, flash], favorites: [sol.id, flash.id], hidden: [flash.id])
        XCTAssertEqual(toggledOff.map(\.section), [.favorites, .hidden])
        XCTAssertEqual(toggledOff.flatMap(\.models).filter { $0.id == flash.id }.count, 1)
    }

    @MainActor func testModelDirectorySearchRestoresManualDisclosure() {
        let directory = ModelDirectoryState()
        XCTAssertFalse(directory.hiddenExpanded)
        directory.search = " GPT "
        XCTAssertTrue(directory.hiddenExpanded)
        directory.toggleHidden()
        XCTAssertFalse(directory.hiddenExpanded)
        directory.search = "latest"
        XCTAssertTrue(directory.hiddenExpanded)
        directory.search = ""
        XCTAssertFalse(directory.hiddenExpanded)
        directory.toggleHidden()
        directory.search = "Astra"
        directory.toggleHidden()
        XCTAssertFalse(directory.hiddenExpanded)
        directory.search = ""
        XCTAssertTrue(directory.hiddenExpanded)
    }

    @MainActor func testModelDirectoryRejectsResultsFromSupersededACPConfiguration() {
        let directory = ModelDirectoryState()
        let original = RuntimeModel(provider: "acp:test", modelID: "original", name: "Original")
        let late = RuntimeModel(provider: "acp:test", modelID: "late", name: "Late")
        let replacement = RuntimeModel(provider: "acp:test", modelID: "replacement", name: "Replacement")

        directory.beginLoad(revision: 0)
        directory.finishLoad(.models([original]), requested: 0, current: 0)
        XCTAssertEqual(directory.loadStatus(for: 0), .ready)
        XCTAssertEqual(directory.loadStatus(for: 1), .outdated)

        directory.beginLoad(revision: 0)
        directory.finishLoad(.models([late]), requested: 0, current: 1)
        XCTAssertEqual(directory.models, [original])
        XCTAssertEqual(directory.loadStatus(for: 1), .outdated)

        directory.beginLoad(revision: 1)
        directory.finishLoad(.failed("Superseded request"), requested: 0, current: 1)
        XCTAssertEqual(directory.loadStatus(for: 1), .loading)
        directory.finishLoad(.models([replacement]), requested: 1, current: 1)
        XCTAssertEqual(directory.loadStatus(for: 1), .ready)
        XCTAssertEqual(directory.models, [replacement])
    }

    func testModelDirectoryKeepsSavedRowsAndPickerHonorsVisibilityAndScope() {
        let favorite = RuntimeModel(provider: "openai", modelID: "one", name: "Shared name")
        let other = RuntimeModel(provider: "openai-codex", modelID: "two", name: favorite.name)
        let hidden = RuntimeModel(provider: "openai", modelID: "hidden", name: "Hidden")
        let current = RuntimeModel(provider: "openai", modelID: "current", name: "Current")
        let missing = RuntimeModel(provider: "legacy", modelID: "missing", name: "Unavailable")
        var prefs = WorkspaceModelPreferences()
        prefs.favorites = [favorite, hidden, missing]
        prefs.defaultModel = missing
        prefs.hiddenModelIDs = [hidden.id, current.id]
        let models = [favorite, favorite, other, hidden, current]
        let settings = ModelSettingsCatalogue(models: models, preferences: prefs)
        XCTAssertEqual(settings.all, [favorite, other, hidden, current, missing])
        XCTAssertFalse(settings.available.contains(missing.id))

        let picker = ModelPickerCatalogue(models: settings.all.filter { settings.available.contains($0.id) },
                                          preferences: prefs, retaining: [current.id])
        XCTAssertEqual(picker.initialScope, .favorites)
        XCTAssertEqual(picker.rows(scope: .favorites, query: ""), [favorite, current])
        XCTAssertEqual(picker.rows(scope: .all, query: "OpenAI Codex"), [other])
        XCTAssertTrue(picker.rows(scope: .all, query: "Hidden").isEmpty)
        XCTAssertEqual(ModelPickerCatalogue(models: [other], preferences: prefs, retaining: []).initialScope, .all)
    }

    func testModelPickerKeepsScopeAndScrollAnchorWhenCatalogueRefreshes() {
        let favorite = RuntimeModel(provider: "fixture", modelID: "favorite", name: "Favorite model")
        let visible = RuntimeModel(provider: "fixture", modelID: "visible", name: "Visible model")
        let added = RuntimeModel(provider: "fixture", modelID: "added", name: "Added model")
        var preferences = WorkspaceModelPreferences()
        preferences.favorites = [favorite]
        let catalogue = ModelPickerCatalogue(models: [favorite, visible], preferences: preferences, retaining: [])
        var browsing = ModelPickerBrowsingPosition()
        browsing.update(catalogue: catalogue, sameCatalogue: false, query: "", selectedModelID: favorite.id)
        XCTAssertEqual(browsing.selectedScope(query: ""), .favorites)
        XCTAssertEqual(browsing.topModelID, favorite.id)

        browsing.scope = .all
        browsing.topModelID = visible.id
        let refreshed = ModelPickerCatalogue(models: [favorite, added, visible], preferences: preferences, retaining: [])
        browsing.update(catalogue: refreshed, sameCatalogue: true, query: "", selectedModelID: favorite.id)
        XCTAssertEqual(browsing.selectedScope(query: ""), .all)
        XCTAssertEqual(browsing.topModelID, visible.id)

        let removed = ModelPickerCatalogue(models: [favorite, added], preferences: preferences, retaining: [])
        browsing.update(catalogue: removed, sameCatalogue: true, query: "", selectedModelID: added.id)
        XCTAssertEqual(browsing.selectedScope(query: ""), .all)
        XCTAssertEqual(browsing.topModelID, added.id)

        browsing.update(catalogue: removed, sameCatalogue: false, query: "", selectedModelID: added.id)
        XCTAssertEqual(browsing.selectedScope(query: ""), .favorites)
        XCTAssertEqual(browsing.topModelID, favorite.id)
    }

    @MainActor func testSavedHiddenModelsCanBeRestoredWhenCatalogueReturnsEmpty() async throws {
        let model = RuntimeModel(provider: "isolated-source", modelID: "group/solo", name: "Solo Hidden")
        let favorite = RuntimeModel(provider: "favorite-source", modelID: "missing", name: "Hidden Favorite")
        let store = MemoryStore()
        let result = OSAllocatedUnfairLock(initialState: Result<[RuntimeModel], RuntimeFailure>.success([model, favorite]))
        let workspace = WorkspaceController(store: store, inspectModels: { _ in
            .init(models: try result.withLock { try $0.get() }, thinkingLevels: [])
        }) { _, _ in FakeRuntime() }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let hidModel = await workspace.setModelVisible(model, isVisible: false, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let hidFavorite = await workspace.setModelVisible(favorite, isVisible: false, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let markedFavorite = await workspace.setFavoriteModel(favorite, isFavorite: true, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertTrue(hidModel && hidFavorite && markedFavorite)
        let persisted = try await store.load()
        let preferences = try XCTUnwrap(persisted.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID])
        XCTAssertEqual(preferences.hiddenModelIDs, [model.id, favorite.id])
        XCTAssertEqual(preferences.hiddenModelReferences?[model.id], model)

        result.withLock { $0 = .failure(.init(.connection, "synthetic catalogue failure")) }
        do {
            _ = try await workspace.modelCatalogue(forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
            XCTFail("A catalogue failure should remain an error")
        } catch is RuntimeFailure {}
        let unverified = ModelSettingsCatalogue(models: [], preferences: preferences)
        XCTAssertEqual(Set(unverified.all.map(\.id)), [model.id, favorite.id])

        result.withLock { $0 = .success([]) }
        let refreshed = try await workspace.modelCatalogue(forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let after = ModelSettingsCatalogue(models: refreshed, preferences: preferences)
        XCTAssertTrue(after.available.isEmpty)
        let groups = ModelListSection.group(after.all, favorites: after.favorites, hidden: after.hidden)
        XCTAssertEqual(groups.map(\.section), [.hidden])
        XCTAssertEqual(Set(groups.flatMap(\.models).map(\.id)), [model.id, favorite.id])
        XCTAssertTrue(after.rowStatus(for: favorite.id, verified: true).favorite)

        let restored = await workspace.setModelVisible(model, isVisible: true, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let restoredFavorite = await workspace.setModelVisible(favorite, isVisible: true, forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        XCTAssertTrue(restored && restoredFavorite)
        let updated = try XCTUnwrap(workspace.state.modelPreferencesByRuntime?[RuntimeAgentProfile.antigravityRuntimeID])
        XCTAssertTrue(updated.hiddenModelIDs.isEmpty)
        XCTAssertNil(updated.hiddenModelReferences)
        XCTAssertEqual(updated.favorites, [favorite])
        XCTAssertEqual(ModelSettingsCatalogue(models: [], preferences: updated).all, [favorite])

        result.withLock { $0 = .success([model, favorite]) }
        let returned = try await workspace.modelCatalogue(forRuntime: RuntimeAgentProfile.antigravityRuntimeID)
        let picker = ModelPickerCatalogue(models: returned, preferences: updated, retaining: [])
        XCTAssertEqual(picker.rows(scope: .all, query: ""), [favorite, model])

        let legacy = try JSONDecoder().decode(WorkspaceModelPreferences.self, from:
            Data(#"{"favorites":[],"hiddenModelIDs":["isolated-source/group/solo"]}"#.utf8))
        let legacyModel = try XCTUnwrap(ModelSettingsCatalogue(models: [], preferences: legacy).all.first)
        XCTAssertEqual(legacyModel.id, model.id)
        XCTAssertEqual(legacyModel.modelID, "group/solo")
    }

    @MainActor func testACPSettingsModelStateRetainsFailureAcrossPaneReplacement() {
        let first = ACPAgentSettingsPresentation()
        let other = ACPAgentSettingsPresentation()
        first.modelDirectory.search = "hidden"
        first.modelDirectory.toggleHidden()
        first.modelDirectory.saveFailure = .init(source: .model("hidden"), message: "Synthetic failure")
        let reopened = first.modelDirectory
        XCTAssertEqual(reopened.search, "hidden")
        XCTAssertFalse(reopened.hiddenExpanded)
        XCTAssertEqual(reopened.saveFailure?.message, "Synthetic failure")
        XCTAssertNil(other.modelDirectory.saveFailure)
        reopened.saveFailure = nil
        XCTAssertNil(reopened.saveFailure)
    }

    @MainActor func testACPEnvironmentDraftClearsValidationWhenRestoredToSavedValues() {
        let presentation = ACPAgentSettingsPresentation()
        presentation.environmentDraft.rows = [.init(name: "INVALID=NAME", value: "original")]
        presentation.environmentDraft.validationError = "Synthetic validation failure"

        presentation.environmentDraft.rows?[0].name = "VALID_NAME"

        XCTAssertNil(presentation.environmentDraft.validationError)
        XCTAssertEqual(ACPEnvironmentRow.values(from: presentation.environmentDraft.rows ?? []), ["VALID_NAME": "original"])
    }

    @MainActor func testACPAuthenticationInvalidatesOnlyTheAgentConnectionAndModelDirectory() async throws {
        let settings = AppSettings()
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let other = RuntimeAgentProfile(id: "acp:other", name: "Other", executablePath: "/unused")
        settings.acpAgents = [first, other]
        let initialRevision = settings.acpConfigurationRevision(for: first.id)
        let otherRevision = settings.acpConfigurationRevision(for: other.id)
        let directory = ModelDirectoryState()
        directory.beginLoad(revision: initialRevision)
        directory.finishLoad(.models([]), requested: initialRevision, current: initialRevision)

        let check = try XCTUnwrap(settings.checkACPConnection(for: first) { configuration in
            .init(runtimeID: configuration.runtimeID, executablePath: "/unused", protocolVersion: .compatible(1))
        })
        await check.value
        XCTAssertFalse(settings.acpCheckIsOutdated(first.id))
        let previousResult = settings.acpCheckResult(for: first.id)
        let queued = try XCTUnwrap(settings.checkACPConnection(for: first) { configuration in
            XCTFail("A check queued before authentication must not start during authentication")
            return .init(runtimeID: configuration.runtimeID, executablePath: "/unused")
        })
        do {
            try await settings.performACPAuthentication(for: first.id) {
                XCTAssertTrue(settings.isChangingACPConfiguration(for: first.id))
                XCTAssertTrue(settings.acpCheckIsOutdated(first.id))
                XCTAssertFalse(settings.beginACPModelPreferencesWrite(for: first.id))
                XCTAssertNil(settings.checkACPConnection(for: first))
                await queued.value
                XCTAssertFalse(settings.isCheckingACP(first.id))
                XCTAssertTrue(settings.acpCheckIsOutdated(first.id))
                XCTAssertEqual(settings.acpCheckResult(for: first.id), previousResult)
                throw RuntimeFailure(.connection, "Synthetic reconnect failure after terminal login")
            }
            XCTFail("The reconnect failure must be returned to the caller")
        } catch let failure as RuntimeFailure {
            XCTAssertEqual(failure.detail, "Synthetic reconnect failure after terminal login")
        }
        XCTAssertTrue(settings.acpCheckIsOutdated(first.id))
        XCTAssertEqual(directory.loadStatus(for: settings.acpConfigurationRevision(for: first.id)), .outdated)
        XCTAssertEqual(settings.acpConfigurationRevision(for: other.id), otherRevision)
        XCTAssertFalse(settings.isWritingACPSettings(for: first.id))
        let beforeSuccessfulAuthentication = settings.acpConfigurationRevision(for: first.id)
        try await settings.performACPAuthentication(for: first.id) {}
        XCTAssertGreaterThan(settings.acpConfigurationRevision(for: first.id), beforeSuccessfulAuthentication)
    }

    @MainActor func testACPTerminalCleanupBlocksNewCheckAndModelInspectionForOnlyItsAgent() async throws {
        let settings = AppSettings()
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let other = RuntimeAgentProfile(id: "acp:other", name: "Other", executablePath: "/unused")
        settings.acpAgents = [first, other]
        let otherRevision = settings.acpConfigurationRevision(for: other.id)
        let cleanupConfirmed = OSAllocatedUnfairLock(initialState: false)
        let cleanup = RuntimeTerminalCleanupPending(failure: .init(.supervision, "Synthetic cleanup pending")) {
            cleanupConfirmed.withLock { $0 }
        }
        let authenticate = try XCTUnwrap(settings.trackedACPTerminalAuthenticator(for: first.id, using: { _ in
            throw cleanup
        }))
        let launch = RuntimeTerminalAuthenticationLaunch(
            name: "Synthetic login", executable: URL(fileURLWithPath: "/unused"),
            workingDirectory: FileManager.default.temporaryDirectory, arguments: [], environment: [:],
            appendedArguments: [], environmentOverrides: [:]
        )
        let authenticateInSession = settings.acpAuthenticationTransaction(for: first.id)
        do {
            try await authenticateInSession {
                try await authenticate(launch)
            }
            XCTFail("The adapter must receive the original cleanup-pending error")
        } catch let pending as RuntimeTerminalCleanupPending {
            XCTAssertEqual(pending.failure.detail, cleanup.failure.detail)
        }
        XCTAssertFalse(settings.isWritingACPSettings(for: first.id))
        let blockedCheck = try XCTUnwrap(settings.checkACPConnection(for: first) { configuration in
            XCTFail("A check must not start an agent while credential changes can still be in progress")
            return .init(runtimeID: configuration.runtimeID, executablePath: "/unused")
        })
        await blockedCheck.value
        XCTAssertEqual(settings.acpCheckResult(for: first.id)?.cleanupUnconfirmed, true)
        XCTAssertEqual(settings.acpCheckResult(for: first.id)?.isReady, false)
        do {
            _ = try await settings.inspectACPModels(for: first.id, model: nil)
            XCTFail("Model verification must wait for confirmed cleanup")
        } catch let failure as RuntimeFailure {
            XCTAssertEqual(failure.kind, .supervision)
            XCTAssertEqual(failure.detail, cleanup.failure.detail)
        }
        let otherCheck = try XCTUnwrap(settings.checkACPConnection(for: other) { configuration in
            .init(runtimeID: configuration.runtimeID, executablePath: "/unused", protocolVersion: .compatible(1))
        })
        await otherCheck.value
        XCTAssertEqual(settings.acpCheckResult(for: other.id)?.isReady, true)
        XCTAssertEqual(settings.acpConfigurationRevision(for: other.id), otherRevision)
        cleanupConfirmed.withLock { $0 = true }
        let retry = try XCTUnwrap(settings.checkACPConnection(for: first) { configuration in
            .init(runtimeID: configuration.runtimeID, executablePath: "/unused", protocolVersion: .compatible(1))
        })
        await retry.value
        XCTAssertEqual(settings.acpCheckResult(for: first.id)?.isReady, true)
        XCTAssertFalse(settings.acpCheckIsOutdated(first.id))
    }

    @MainActor func testACPModelWriteRemainsExclusiveWithARecreatedSettingsPresentation() async {
        let settings = AppSettings()
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let other = RuntimeAgentProfile(id: "acp:other", name: "Other", executablePath: "/unused")
        settings.acpAgents = [first, other]
        var snapshot = WorkspaceSnapshot()
        snapshot.preferences = settings.preferences
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        snapshot.projects = [project]
        let store = PausedACPSettingsStore(snapshot: snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()

        let started = expectation(description: "First default model is writing to the store")
        await store.pauseNextSave(started: started)
        XCTAssertTrue(settings.beginACPModelPreferencesWrite(for: first.id))
        let model = RuntimeModel(provider: "acp:first", modelID: "available", name: "Available")
        let saving = Task {
            defer { settings.endACPModelPreferencesWrite(for: first.id) }
            return await workspace.setDefaultModel(model, forRuntime: first.id)
        }
        await fulfillment(of: [started], timeout: 2)

        let reopened = ACPAgentSettingsPresentation()
        XCTAssertTrue(reopened.modelDirectory.search.isEmpty)
        XCTAssertTrue(settings.isWritingACPSettings(for: first.id))
        XCTAssertFalse(settings.beginACPModelPreferencesWrite(for: first.id))
        var changed = first
        changed.arguments = ["new"]
        settings.updateACPAgent(changed)
        XCTAssertEqual(settings.acpAgents.first?.arguments, first.arguments)
        let duplicate = await workspace.setDefaultModel(nil, forRuntime: first.id)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(settings.beginACPModelPreferencesWrite(for: other.id))
        let otherModel = RuntimeModel(provider: "acp:other", modelID: "second", name: "Second")
        let otherStarted = expectation(description: "Second agent requested its own default")
        let otherSaving = Task {
            defer { settings.endACPModelPreferencesWrite(for: other.id) }
            otherStarted.fulfill()
            return await workspace.setDefaultModel(otherModel, forRuntime: other.id)
        }
        await fulfillment(of: [otherStarted], timeout: 2)
        XCTAssertTrue(settings.isWritingACPSettings(for: other.id))
        let creatingStarted = expectation(description: "New session requested while its default is pending")
        let newSession = Task {
            creatingStarted.fulfill()
            return await workspace.createSession(in: project.id, runtimeID: other.id)
        }
        await fulfillment(of: [creatingStarted], timeout: 2)
        XCTAssertTrue(workspace.state.sessions.isEmpty)

        await store.releaseSave()
        let modelSaved = await saving.value
        let otherSaved = await otherSaving.value
        XCTAssertTrue(modelSaved)
        XCTAssertTrue(otherSaved)
        XCTAssertEqual(workspace.modelPreferences(forRuntime: first.id).defaultModel, model)
        XCTAssertEqual(workspace.modelPreferences(forRuntime: other.id).defaultModel, otherModel)
        let sessionID = await newSession.value
        XCTAssertNotNil(sessionID)
        let session = workspace.state.sessions.first { $0.id == sessionID }
        XCTAssertEqual(session?.runtimeID, other.id)
        XCTAssertEqual(session?.pendingSelection?.modelID, otherModel.modelID)
        XCTAssertFalse(settings.isWritingACPSettings(for: first.id))
        XCTAssertFalse(settings.isWritingACPSettings(for: other.id))
        settings.updateACPAgent(changed)
        XCTAssertEqual(settings.acpAgents.first?.arguments, ["new"])

        await store.failNextSave()
        XCTAssertTrue(settings.beginACPModelPreferencesWrite(for: first.id))
        let failingSave = Task {
            defer { settings.endACPModelPreferencesWrite(for: first.id) }
            return await workspace.setDefaultModel(nil, forRuntime: first.id)
        }
        let didSave = await failingSave.value
        XCTAssertFalse(didSave)
        XCTAssertEqual(workspace.modelPreferences(forRuntime: first.id).defaultModel, model)
        XCTAssertFalse(settings.isWritingACPSettings(for: first.id))
    }

    @MainActor func testRemovedAgentProbeCannotPublishOrClearReaddedAgentCheck() async throws {
        let settings = AppSettings()
        let agent = RuntimeAgentProfile(id: "acp:reused", name: "Agent", executablePath: "/unused")
        settings.addACPAgent(agent)
        let oldRevision = settings.acpConfigurationRevision(for: agent.id)
        let oldProbe = PausedACPSettingsProbe()
        let oldStarted = expectation(description: "Old check started")
        let old = try XCTUnwrap(settings.checkACPConnection(for: agent) { _ in await oldProbe.run(started: oldStarted) })
        await fulfillment(of: [oldStarted], timeout: 2)

        settings.acpAgents = []
        XCTAssertFalse(settings.isCheckingACP(agent.id))
        XCTAssertNil(settings.acpCheckResult(for: agent.id))
        settings.addACPAgent(agent)
        XCTAssertNotEqual(settings.acpConfigurationRevision(for: agent.id), oldRevision)
        let newProbe = PausedACPSettingsProbe()
        let newStarted = expectation(description: "Replacement check started")
        let new = try XCTUnwrap(settings.checkACPConnection(for: agent) { _ in await newProbe.run(started: newStarted) })
        await fulfillment(of: [newStarted], timeout: 2)

        await oldProbe.complete(.init(runtimeID: agent.id, executablePath: "/old", protocolVersion: .compatible(1)))
        await old.value
        XCTAssertTrue(settings.isCheckingACP(agent.id))
        XCTAssertNil(settings.acpCheckResult(for: agent.id))

        await newProbe.complete(.init(runtimeID: agent.id, executablePath: "/new", protocolVersion: .compatible(1)))
        await new.value
        XCTAssertFalse(settings.isCheckingACP(agent.id))
        XCTAssertEqual(settings.acpCheckResult(for: agent.id)?.executablePath, "/new")

        let removedProbe = PausedACPSettingsProbe()
        let removedStarted = expectation(description: "Final check started")
        let removed = try XCTUnwrap(settings.checkACPConnection(for: agent) { _ in
            await removedProbe.run(started: removedStarted)
        })
        await fulfillment(of: [removedStarted], timeout: 2)
        settings.acpAgents = []
        await removedProbe.complete(.init(runtimeID: agent.id, executablePath: "/removed"))
        await removed.value
        XCTAssertFalse(settings.isCheckingACP(agent.id))
        XCTAssertNil(settings.acpCheckResult(for: agent.id))
        XCTAssertNil(settings.acpCheckFinishedAt(for: agent.id))
    }

    func testProviderConnectionRequestsSelectAndReturnToTheTargetOnce() {
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused")
        let second = RuntimeAgentProfile(id: "acp:second", name: "Second", executablePath: "/unused", enabled: false)
        let agents = [first, second]
        let initial = ProviderConnectionRequest(runtimeID: first.id, sequence: 1)
        var reopened = SettingsPanelNavigation(section: .providers, connectionRequest: initial, agents: agents)
        XCTAssertEqual(reopened.section, .providers)
        XCTAssertEqual(reopened.selectedAgentID, first.id)
        XCTAssertTrue(reopened.consumeConnection(initial))
        XCTAssertFalse(reopened.consumeConnection(initial))

        var open = SettingsPanelNavigation(section: .general, connectionRequest: nil, agents: agents)
        XCTAssertEqual(open.section, .general)
        XCTAssertNil(open.selectedAgentID)
        open.section = .projects
        open.openConnection(initial, agents: agents)
        XCTAssertEqual(open.section, .providers)
        XCTAssertEqual(open.selectedAgentID, first.id)
        XCTAssertTrue(open.consumeConnection(initial))

        let switchAgent = ProviderConnectionRequest(runtimeID: second.id, sequence: 2)
        open.openConnection(switchAgent, agents: agents)
        XCTAssertEqual(open.selectedAgentID, second.id)
        open.agentRemoved(first.id)
        XCTAssertEqual(open.selectedAgentID, second.id)
        XCTAssertTrue(open.consumeConnection(switchAgent))

        let repeatAgent = ProviderConnectionRequest(runtimeID: second.id, sequence: 3)
        open.openConnection(repeatAgent, agents: agents)
        XCTAssertFalse(open.consumeConnection(switchAgent))
        XCTAssertTrue(open.consumeConnection(repeatAgent))
        open.selectedAgentID = first.id
        open.openConnection(repeatAgent, agents: agents)
        XCTAssertEqual(open.selectedAgentID, first.id)
        XCTAssertNil(open.connectionRequest)

        let removed = ProviderConnectionRequest(runtimeID: "acp:removed", sequence: 4)
        open.openConnection(removed, agents: agents)
        XCTAssertEqual(open.selectedAgentID, first.id)
        XCTAssertNil(open.connectionRequest)

        open.agentRemoved(first.id)
        XCTAssertNil(open.selectedAgentID)
    }

    @MainActor func testConnectionSettingsShortcutTargetsTheFailedSession() async throws {
        let first = RuntimeAgentProfile(id: "acp:first", name: "First", executablePath: "/unused", enabled: false)
        let second = RuntimeAgentProfile(id: "acp:second", name: "Second", executablePath: "/unused")
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let failed = SessionReference(projectID: project.id, runtimeID: first.id)
        let selected = SessionReference(projectID: project.id, runtimeID: second.id)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [failed, selected]
        snapshot.selectedSessionID = selected.id
        let workspace = WorkspaceController(store: MemoryStore(snapshot)) { _, _ in FakeRuntime() }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        XCTAssertEqual(workspace.selected?.runtimeID, second.id)

        let settings = AppSettings()
        let presentation = SessionPresentation(id: failed.id)
        let detail = SessionDetail(workspace: workspace, settings: settings, presentation: presentation,
                                   openConnectionSettings: { _ in }, presentConfirmation: { _ in })
        let agents = [first, second]
        XCTAssertNil(detail.connectionSettingsRuntimeID(agents: agents))
        await presentation.controller.connect(StubSessionRuntime(connectionFailure: .init(.setup, "Synthetic ACP launch failure")))
        XCTAssertEqual(detail.connectionSettingsRuntimeID(agents: agents), first.id)
        XCTAssertNil(detail.connectionSettingsRuntimeID(agents: [second]))
        XCTAssertEqual(presentation.controller.failure?.detail, "Synthetic ACP launch failure")

    }

    @MainActor func testModelSnapshotDateOnlySplitsDocumentedProviderIdentifiers() {
        let qwen = RuntimeModel(provider: "qwen-token-plan-individual-cn", modelID: "deepseek-v4.1-flash-1017",
                                name: "DeepSeek V4.1 Flash 1017")
        XCTAssertEqual(ModelPresentation.snapshot(qwen)?.date, "10-17")
        XCTAssertEqual(ModelPresentation.snapshot(qwen)?.displayDate, "1017")
        XCTAssertEqual(ModelPresentation.snapshot(qwen)?.name, "DeepSeek V4.1 Flash")
        XCTAssertTrue(ModelPresentation.matches(qwen, query: "1017"))
        XCTAssertTrue(ModelPresentation.matches(qwen, query: "10-17"))
        let openAI = RuntimeModel(provider: "openai", modelID: "gpt-4o-2024-08-06", name: "GPT-4o (2024-08-06)")
        XCTAssertEqual(ModelPresentation.snapshot(openAI)?.name, "GPT-4o")
        XCTAssertEqual(ModelPresentation.snapshot(openAI)?.date, "2024-08-06")
        XCTAssertEqual(ModelPresentation.snapshot(openAI)?.displayDate, "20240806")
        XCTAssertTrue(ModelPresentation.matches(openAI, query: "20240806"))
        let version = RuntimeModel(provider: "openai", modelID: "gpt-4-1106-preview", name: "Preview 1106")
        let invalid = RuntimeModel(provider: "openai", modelID: "gpt-4o-2024-02-31", name: "Invalid date")
        XCTAssertNil(ModelPresentation.snapshot(version))
        XCTAssertNil(ModelPresentation.snapshot(invalid))
        XCTAssertEqual(CodingAgentLabel.initials(for: "Claude Code"), "CL")
    }

    func testCodexQuotaUsesOnlyCodexWindowsAndPreservesResetTime() throws {
        let payload = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1795250809},"secondary":{"usedPercent":71}},"other":{"primary":{"usedPercent":100}}}}"#
        let observed = Date(timeIntervalSince1970: 1_795_250_000)
        let windows = try CodexQuotaClient.windows(from: Data(payload.utf8), observedAt: observed)
        XCTAssertEqual(windows.map(\.value), ["1%", "29%"])
        XCTAssertEqual(windows.first?.resetAt, Date(timeIntervalSince1970: 1_795_250_809))
        XCTAssertTrue(windows.allSatisfy { $0.expiresAt == observed.addingTimeInterval(300) })
        let unknown = #"{"rateLimits":{"limitId":"other","primary":{"usedPercent":100}}}"#
        XCTAssertTrue(try CodexQuotaClient.windows(from: Data(unknown.utf8), observedAt: observed).isEmpty)
    }

    func testSidebarUpgradeOnlyOffersNewerStableVersions() {
        XCTAssertEqual(ZivviReleaseCheck.newerVersion(tag: "v0.10.0", installed: "0.9.9"), "0.10.0")
        XCTAssertNil(ZivviReleaseCheck.newerVersion(tag: "v1.2.0", installed: "1.2"))
        XCTAssertNil(ZivviReleaseCheck.newerVersion(tag: "v1.2.9", installed: "1.10.0"))
        XCTAssertNil(ZivviReleaseCheck.newerVersion(tag: "v2.0.0-beta.1", installed: "1.2.0"))
        XCTAssertNil(ZivviReleaseCheck.newerVersion(tag: "v2..1", installed: "1.2.0"))
    }

    @MainActor func testProviderLogosMapKnownProvidersAndFallBackToTheGenericChip() throws {
        XCTAssertEqual(ProviderLogo.assetName(for: "deepseek"), "deepseek")
        XCTAssertEqual(ProviderLogo.assetName(for: "DeepSeek"), "deepseek")
        XCTAssertEqual(ProviderLogo.assetName(for: "openai-codex"), "openai")
        XCTAssertEqual(ProviderLogo.assetName(for: "google-vertex"), "googlegemini")
        XCTAssertEqual(ProviderLogo.assetName(for: "zai-coding-cn"), "zai")
        XCTAssertEqual(ProviderLogo.assetName(for: "glm"), "zai")
        XCTAssertEqual(ProviderLogo.assetName(for: "qwen-token-plan-individual-cn"), "qwen")
        XCTAssertEqual(ProviderLogo.assetName(for: "QWEN"), "qwen")
        XCTAssertEqual(ProviderLogo.assetName(for: "gemini"), "googlegemini")
        XCTAssertEqual(ProviderLogo.assetName(for: "antigravity"), "antigravity")
        XCTAssertEqual(ProviderLogo.assetName(for: "acp:antigravity"), "antigravity")
        XCTAssertEqual(ProviderLogo.assetName(for: "Antigravity", model: "Gemini 4 Hydrogen"), "googlegemini")
        XCTAssertEqual(ProviderLogo.assetName(for: "Antigravity", model: "Claude Sonnet 4.5"), "anthropic")
        XCTAssertEqual(ProviderLogo.assetName(for: "Antigravity", model: "Custom Agent Model"), "antigravity")
        XCTAssertNil(ProviderLogo.assetName(for: ""))
        XCTAssertNil(ProviderLogo.assetName(for: "unverified-provider"))
        // Wide or thin-stroked marks fill the 13 pt frame; square marks keep 12 pt.
        XCTAssertEqual(ProviderLogo.drawSide(for: "deepseek"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "google"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "antigravity"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "Antigravity", model: "Gemini 4 Hydrogen"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "qwen-token-plan"), 13)
        XCTAssertEqual(ProviderLogo.drawSide(for: "openai"), 12)
        XCTAssertEqual(ProviderLogo.drawSide(for: "zai"), 12)
        XCTAssertEqual(ProviderLogo.drawSide(for: "unverified-provider"), 12)
        let bundle = Bundle(for: AppDelegate.self)
        for name in ["openai", "anthropic", "googlegemini", "deepseek", "qwen", "zai", "antigravity"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"), name)
            let image = try XCTUnwrap(NSImage(contentsOf: url), name)
            // Templates must carry at least 2x pixels of their draw box so thin strokes survive.
            XCTAssertGreaterThanOrEqual(image.size.width, 26, name)
        }
    }

    @MainActor func testTranscriptScrollerFollowsSessionDetailWidth() async throws {
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in FakeRuntime() }
        let presentation = SessionPresentation(id: UUID())
        presentation.controller.showHistory((0..<30).map { .init(id: "layout-\($0)", kind: .assistant, text: "Message \($0)") })
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(), presentation: presentation, openConnectionSettings: { _ in }, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func transcriptScroll(in view: NSView) -> NSScrollView? { findTranscriptScrollView(in: view) }

        for width: CGFloat in [1200, 520] {
            window.setContentSize(.init(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(transcriptScroll(in: host))
            scroll.scrollerStyle = .legacy
            scroll.layoutSubtreeIfNeeded()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            XCTAssertEqual(scroll.bounds.width, width, accuracy: 1)
            // Workbench 2.0 Section 13.3: Adaptive Composer Dock participates in vertical layout below the transcript.
            XCTAssertGreaterThan(scroll.bounds.height, host.bounds.height - 160)
            XCTAssertLessThan(scroll.bounds.height, host.bounds.height)
            XCTAssertLessThanOrEqual(scroll.contentInsets.bottom, 24)
            XCTAssertEqual(scroller.convert(scroller.bounds, to: host).maxX, host.bounds.maxX, accuracy: 1)
        }
    }

    @MainActor func testWorkbenchInstallsSessionAndSidebarToggleInNativeToolbar() async throws {
        let workspace = await newConversationWorkspace()
        let visibility = TestSidebarVisibility()
        let projectFiles = ProjectFilesControls()
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.draft = "Draft stays in the session"
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 }), projectFiles: projectFiles
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        var retainedSidebarToggle: NSToolbarItem?
        for (width, showSidebar) in [(1200.0, true), (860.0, true), (860.0, false), (860.0, true), (1200.0, true)] {
            visibility.value = showSidebar ? .all : .detailOnly
            window.setContentSize(NSSize(width: width, height: 620))
            await settleWindow(window)
            await settleWindow(window)

            let toolbar = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            let identifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
            // Workbench 2.0: Conversation + Editor dual tab bar is hosted natively in the top titlebar row.
            XCTAssertEqual(identifiers.last, "ZivviTabBars")
            let sidebarToggle = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "ZivviSidebarToggle" })
            if let retainedSidebarToggle {
                XCTAssertTrue(sidebarToggle === retainedSidebarToggle, "The sidebar toggle must remain attached when its neighbors change")
            } else {
                retainedSidebarToggle = sidebarToggle
            }
            XCTAssertEqual(identifiers.contains("ZivviSidebarHeading"), showSidebar)
            XCTAssertEqual(toolbar.items.contains { $0.itemIdentifier == .sidebarTrackingSeparator }, showSidebar)

            let visibleIdentifiers = (toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue }
            XCTAssertTrue(visibleIdentifiers.contains("ZivviTabBars"), "Dual tab bar overflowed at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers)")
            XCTAssertTrue(visibleIdentifiers.contains("ZivviSidebarToggle"), "Sidebar toggle overflowed at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers)")
            XCTAssertEqual(visibleIdentifiers.contains("ZivviSidebarHeading"), showSidebar, "Sidebar heading visibility mismatch at width=\(width), showSidebar=\(showSidebar): visible=\(visibleIdentifiers)")

            let tabBarsView = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "ZivviTabBars" }?.view)
            XCTAssertTrue(tabBarsView.window === window)
            XCTAssertGreaterThan(tabBarsView.bounds.width, 350)
            XCTAssertLessThan(tabBarsView.bounds.width, width)
            XCTAssertLessThanOrEqual(tabBarsView.convert(tabBarsView.bounds, to: nil).maxX, width + 1)
        }

        projectFiles.open()
        await settleWindow(window)
        XCTAssertTrue(projectFiles.isOpen)
        window.setContentSize(NSSize(width: 860, height: 620))
        await settleWindow(window)
        XCTAssertTrue(workspace.viewed?.controller === controller)
        XCTAssertEqual(controller.draft, "Draft stays in the session")
        projectFiles.close()
        await settleWindow(window)
        XCTAssertFalse(projectFiles.isOpen)
        XCTAssertEqual(controller.draft, "Draft stays in the session")
    }

    @MainActor func testWorkbenchRemainsInteractiveDuringExternalOpenValidation() async throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "Zivvi-Open-Test-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "Preview".write(to: fixture.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        let workspace = await newConversationWorkspace(projectPath: fixture.path)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.draft = "Keep editing"
        let controls = ProjectFilesControls()
        let reader = DelayedReader()
        let model = WorkbenchTabsModel(reader: reader)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.detailOnly),
            projectFiles: controls, tabsModel: model
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            Task { await reader.releaseValidation() }
        }

        func waitFor(_ condition: () async -> Bool) async throws {
            for _ in 0..<100 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try XCTUnwrap(nil as Bool?, "Timed out waiting for the open-validation fixture")
        }

        await settleWindow(window)
        controls.open()
        await settleWindow(window)
        XCTAssertTrue(controls.isOpen)
        let project = try XCTUnwrap(workspace.selectedProject)
        model.openFile(project: project, entry: .init(path: .root.appending("notes.md"), kind: .file))
        let tab = try XCTUnwrap(model.activeEditorTab)
        try await waitFor { tab.openTarget != nil }

        var pendingFailure: (@MainActor @Sendable () async -> Void)?
        var launches = 0
        var fallbackOpens = 0
        var actions = TranscriptFileOpener.Actions()
        actions.launch = { _, failure in
            launches += 1
            pendingFailure = failure
        }
        actions.destination = { .application($0) }
        actions.openApplication = { _ in
            fallbackOpens += 1
            return true
        }
        let configuration = FileOpenConfiguration(preference: .custom, customCommand: "true")
        let request = try XCTUnwrap(model.externalOpenRequest(for: tab) { controls.isOpen })
        await reader.holdNextValidation()
        let initialOpen = Task {
            await TranscriptFileOpener.open(request, configuration: configuration, actions: actions)
        }
        try await waitFor { await reader.isWaitingForValidation }
        XCTAssertEqual(launches, 0)
        workspace.focusInput()
        await settleWindow(window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isEditable)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(event)
        await settleWindow(window)
        XCTAssertEqual(controller.draft, "Keep editing\n")
        let stillWaiting = await reader.isWaitingForValidation
        XCTAssertTrue(stillWaiting)
        XCTAssertEqual(launches, 0)

        await reader.releaseValidation()
        await initialOpen.value
        XCTAssertEqual(launches, 1)
        let failure = try XCTUnwrap(pendingFailure)
        pendingFailure = nil
        await reader.holdNextValidation()
        let fallback = Task { await failure() }
        try await waitFor { await reader.isWaitingForValidation }
        controls.close()
        await settleWindow(window)
        XCTAssertFalse(controls.isOpen)
        XCTAssertFalse(model.isEditorVisible)
        XCTAssertEqual(controller.draft, "Keep editing\n")
        await reader.releaseValidation()
        await fallback.value
        XCTAssertEqual(fallbackOpens, 0)
    }

    @MainActor func testWorkbenchProjectNameCreatesSessionWithoutOpeningSidebar() async throws {
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let otherProject = ProjectRecord(path: NSHomeDirectory())
        let original = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [otherProject, project]
        snapshot.sessions = [SessionReference(projectID: otherProject.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID), original]
        snapshot.selectedSessionID = original.id
        let store = MemoryStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let visibility = TestSidebarVisibility()
        visibility.value = .detailOnly
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 })
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        workspace.newSessionRequest += 1
        for _ in 0..<10 {
            await settleWindow(window)
            if (await store.load()).sessions.count == 3 { break }
        }
        await settleWindow(window)
        XCTAssertEqual(workspace.state.sessions.count, 3)
        XCTAssertNotEqual(workspace.selected?.id, original.id)
        XCTAssertEqual(workspace.selected?.projectID, project.id)
        XCTAssertEqual(workspace.viewed?.id, workspace.selected?.id)
        XCTAssertEqual(visibility.value, .detailOnly)
    }

    @MainActor func testWorkbenchSidebarKeepsRoomForSearchAtNarrowWidths() async throws {
        let workspace = await newConversationWorkspace()
        let visibility = TestSidebarVisibility()
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 })
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host

        func splitView(in view: NSView) -> NSSplitView? {
            (view as? NSSplitView) ?? view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }

        func sidebarItem() throws -> NSSplitViewItem {
            let split = try XCTUnwrap(splitView(in: host))
            let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
            return try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        }

        for width: CGFloat in [900, 1200, 860] {
            window.setContentSize(.init(width: width, height: 780))
            await settleWindow(window)
            let sidebar = try sidebarItem()
            XCTAssertFalse(sidebar.isCollapsed)
            XCTAssertGreaterThanOrEqual(sidebar.viewController.view.bounds.width, 204.5,
                                        "Sidebar at window width \(width) pt")
        }

        visibility.value = .detailOnly
        await settleWindow(window)
        XCTAssertTrue(try sidebarItem().isCollapsed)
        visibility.value = .all
        await settleWindow(window)
        let reopened = try sidebarItem()
        XCTAssertFalse(reopened.isCollapsed)
        XCTAssertGreaterThanOrEqual(reopened.viewController.view.bounds.width, 204.5)
    }

    @MainActor func testSidebarDividerHighlightPreservesSplitViewHitTestingAndStyle() async throws {
        XCTAssertEqual(ResizeDividerStyle.color(hovering: false, dragging: false), ZivviTheme.subtleDivider)
        XCTAssertEqual(ResizeDividerStyle.color(hovering: true, dragging: false), ZivviTheme.selectionBorder)
        XCTAssertEqual(ResizeDividerStyle.color(hovering: true, dragging: true), ZivviTheme.focusBorder)
        XCTAssertGreaterThan(ResizeDividerStyle.activeWidth, ResizeDividerStyle.restingWidth)

        let workspace = await newConversationWorkspace()
        let visibility = TestSidebarVisibility()
        let projectFiles = ProjectFilesControls()
        projectFiles.toggle()
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 }),
            projectFiles: projectFiles
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1500, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)

        func splitView(in view: NSView) -> NSSplitView? {
            (view as? NSSplitView) ?? view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }

        let split = try XCTUnwrap(splitView(in: host))
        let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        XCTAssertFalse(sidebar.isCollapsed)

        let dividerPoint = host.convert(NSPoint(x: sidebar.viewController.view.bounds.maxX, y: 200),
                                        from: sidebar.viewController.view)
        XCTAssertTrue(host.hitTest(dividerPoint) === split,
                      "Divider overlay must stay mouse-transparent so NSSplitView keeps native resize hit-testing")

        func highlightOverlay(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("HighlightView") { return view }
            return view.subviews.lazy.compactMap { highlightOverlay(in: $0) }.first
        }

        let overlay = try XCTUnwrap(highlightOverlay(in: host))
        let trackingArea = try XCTUnwrap(overlay.trackingAreas.first)
        XCTAssertEqual(trackingArea.rect.width, ResizeDividerStyle.hitWidth, accuracy: 0.5)
        XCTAssertEqual(trackingArea.rect.midX, dividerPoint.x, accuracy: 2)
        let bar = try XCTUnwrap(overlay.subviews.first)
        XCTAssertEqual(bar.alphaValue, 0, accuracy: 0.01)

        let windowPoint = host.convert(dividerPoint, to: nil)
        let moveEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        overlay.mouseMoved(with: moveEvent)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(bar.alphaValue, 0.9)

        overlay.mouseExited(with: moveEvent)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(bar.alphaValue, 0, accuracy: 0.01)

        visibility.value = .detailOnly
        await settleWindow(window)
        XCTAssertTrue(overlay.trackingAreas.isEmpty)
    }

    @MainActor func testManyBackgroundRunsLeaveRoomForTheTranscript() async throws {
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in
            StubSessionRuntime(sessionID: UUID().uuidString)
        }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(FileManager.default.temporaryDirectory)
        let project = try XCTUnwrap(added)
        for index in 0..<18 {
            let selected = await workspace.createSession(in: project)
            let id = try XCTUnwrap(selected)
            await workspace.send(id, submitted: .init(text: "Task \(index)"))
        }
        XCTAssertEqual(workspace.executionIDs.count, 18)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all)
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)

        func findTranscript(in view: NSView) -> NSScrollView? { findTranscriptScrollView(in: view) }
        let transcript = try XCTUnwrap(findTranscript(in: host))
        XCTAssertGreaterThan(transcript.contentSize.height, 300, "Background banners must not crowd out the conversation")
        let clean = await workspace.disconnectAll()
        XCTAssertTrue(clean)
        window.contentView = nil
    }

    @MainActor func testBackgroundRunShowsActionsOnlyWhenApprovalArrives() async throws {
        let runtime = StubSessionRuntime()
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in runtime }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(FileManager.default.temporaryDirectory)
        let project = try XCTUnwrap(added)
        let background = await workspace.createSession(in: project)
        let id = try XCTUnwrap(background)
        await workspace.send(id, submitted: .init(text: "Background fixture"))
        let controller = try XCTUnwrap(workspace.execution(for: id))
        XCTAssertEqual(controller.phase, .running)
        var presented = false
        let host = NSHostingView(rootView: ActiveRunBanner(workspace: workspace, sessionID: id) {
            presented = true
        }.frame(width: 600, height: 38, alignment: .top).background(ZivviTheme.pageBackground))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 38),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        func hasMenuPixels() throws -> Bool {
            let bounds = NSRect(x: host.bounds.maxX - 14 - IconButtonLabel.side,
                                y: host.bounds.minY, width: IconButtonLabel.side, height: host.bounds.height)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.redComponent < 0.5, color.greenComponent < 0.5, color.blueComponent < 0.5 {
                        return true
                    }
                }
            }
            return false
        }
        XCTAssertFalse(try hasMenuPixels())

        let request = RuntimeInteraction(
            instanceID: runtime.instanceID, requestID: "background-approval", kind: .confirm, title: "Approval fixture",
            toolApproval: .init(workingDirectory: "/fixture", operation: .command(text: "echo hi", timeoutSeconds: nil))
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
        await settleWindow(window)
        let approvalX = host.bounds.maxX - 14 - 20
        try clickApproval(in: host, x: approvalX, fromTop: host.bounds.height / 2)
        XCTAssertTrue(presented)
        _ = await workspace.disconnectAll()
    }

    @MainActor func testStarterCentersHeadingAndComposerHorizontallyAcrossWindowHeights() async throws {
        var titleFrame = CGRect.zero
        var composerFrame = CGRect.zero
        var viewport = CGRect.zero
        let host = NSHostingView(rootView: SessionDetailLayout(isStarter: true) {
            Color.clear.frame(width: 200, height: 44)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { titleFrame = $0 }
        } footer: { _ in
            Color.clear.frame(maxWidth: .infinity).frame(height: 110)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { composerFrame = $0 }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { viewport = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for height: CGFloat in [620, 920] {
            window.setContentSize(NSSize(width: 790, height: height))
            await settleWindow(window)

            XCTAssertEqual(viewport.height, height, accuracy: 1)
            XCTAssertEqual(titleFrame.maxY, composerFrame.minY, accuracy: 1)
            XCTAssertEqual(composerFrame.midX, viewport.midX, accuracy: 1)
            XCTAssertEqual(titleFrame.midX, viewport.midX, accuracy: 1)
            XCTAssertGreaterThan(titleFrame.minY, viewport.minY)
            XCTAssertLessThan(composerFrame.maxY, viewport.maxY)
        }
    }

    @MainActor func testReadingColumnCentersBothComposersWithoutNarrowingTheViewport() async {
        for isStarter in [true, false] {
            var transcriptFrame = CGRect.zero
            var composerFrame = CGRect.zero
            let host = NSHostingView(rootView: SessionDetailLayout(isStarter: isStarter) {
                Color.clear.frame(maxWidth: .infinity)
                    .frame(height: isStarter ? 44 : nil)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { transcriptFrame = $0 }
            } footer: { _ in
                Color.clear.frame(maxWidth: .infinity).frame(height: 110)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { composerFrame = $0 }
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 620),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for (width, column): (CGFloat, CGFloat) in [(1280, 800), (1000, 800), (600, 552)] {
                window.setContentSize(NSSize(width: width, height: 620))
                await settleWindow(window)
                XCTAssertEqual(transcriptFrame.width, width, accuracy: 1)
                XCTAssertEqual(composerFrame.width, column, accuracy: 1)
                XCTAssertEqual(composerFrame.midX, transcriptFrame.midX, accuracy: 1)
            }
            window.contentView = nil
        }
    }

    @MainActor func testComposerControlsCompressBeforeWrappingTrailingGroup() async {
        var leading = CGRect.zero
        var trailing = CGRect.zero
        let host = NSHostingView(rootView: ComposerControlsLayout {
            Color.clear.frame(minWidth: 180, idealWidth: 260, maxWidth: 260)
                .frame(height: 24)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { leading = $0 }
            Color.clear.frame(minWidth: 72, idealWidth: 100, maxWidth: 100)
                .frame(height: 32)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { trailing = $0 }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        for (width, expectedLeading, expectedTrailing): (CGFloat, CGFloat, CGFloat) in
            [(450, 260, 100), (365, 260, 89), (320, 232, 72), (250, 250, 100), (450, 260, 100)] {
            window.setContentSize(NSSize(width: width, height: 200))
            await settleWindow(window)
            XCTAssertEqual(leading.width, expectedLeading, accuracy: 1)
            XCTAssertEqual(trailing.width, expectedTrailing, accuracy: 1)
            XCTAssertEqual(trailing.maxX - leading.minX, width, accuracy: 1)
            if width == 250 {
                XCTAssertEqual(trailing.minY - leading.maxY, 6, accuracy: 1)
            } else {
                XCTAssertEqual(leading.midY, trailing.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(trailing.minX - leading.maxX, 15)
            }
        }
    }

    @MainActor func testOversizedStarterCanScrollToSendRow() async throws {
        var sendFrame = CGRect.zero
        let host = NSHostingView(rootView: SessionDetailLayout(isStarter: true) {
            Color.clear.frame(height: 44)
        } footer: { _ in
            VStack(spacing: 0) {
                Color.clear.frame(height: 688)
                Button("Send") {}
                    .frame(height: 32)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { sendFrame = $0 }
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        XCTAssertGreaterThan(sendFrame.minY, host.bounds.height)

        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(findScrollView(in: host))
        let clip = scroll.contentView
        let bottom = clip.constrainBoundsRect(NSRect(x: 0, y: 1_000, width: clip.bounds.width, height: clip.bounds.height))
        XCTAssertGreaterThan(bottom.minY, clip.bounds.minY)
        clip.scroll(to: bottom.origin)
        scroll.reflectScrolledClipView(clip)
        await settleWindow(window)
        XCTAssertGreaterThanOrEqual(sendFrame.minY, 0)
        XCTAssertLessThanOrEqual(sendFrame.maxY, host.bounds.height + 1)
    }

    @MainActor func testComposerReturnKeysInsertNewlinesAndCommandReturnSends() async throws {
        let runtime = StubSessionRuntime { $0.mode == .followUp ? .queued : .started }
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        presentation.controller.draft = "abcd"
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(composerSendShortcut: .commandReturn),
            presentation: presentation, openConnectionSettings: { _ in }, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)
        workspace.focusInput()
        await settleWindow(window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        func editorFrame() throws -> CGRect {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            return editor.convert(editor.bounds, to: host)
        }

        func pressReturn(_ modifiers: NSEvent.ModifierFlags) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.sendEvent(event)
            await settleWindow(window)
        }

        try await pressReturn([.shift])
        XCTAssertEqual(presentation.controller.draft, "ab\ncd")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        try await pressReturn([])
        XCTAssertEqual(presentation.controller.draft, "ab\n\ncd")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(presentation.controller.transcript.isEmpty)

        try await pressReturn([.command])
        for _ in 0..<10 where presentation.controller.transcript.isEmpty { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.transcript.first?.editableText, "ab\n\ncd")
        XCTAssertTrue(presentation.controller.draft.isEmpty)

        // During execution the visible primary button is Stop, but the editor still sends with ⌘↩.
        for _ in 0..<10 where presentation.controller.phase != .running { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.phase, .running)
        workspace.focusInput()
        await settleWindow(window)
        let runningFrame = try editorFrame()

        presentation.controller.draft = "Run next\non another line"
        await settleWindow(window)
        XCTAssertEqual(try editorFrame().minX, runningFrame.minX, accuracy: 1)

        presentation.controller.mode = .followUp
        try await pressReturn([.command])
        for _ in 0..<10 where presentation.controller.transcript.last?.delivery != .queued { await settleWindow(window) }
        XCTAssertEqual(presentation.controller.transcript.last?.editableText, "Run next\non another line")
        XCTAssertEqual(presentation.controller.transcript.last?.delivery, .queued)
        XCTAssertEqual(presentation.controller.phase, .running)

        await presentation.controller.stop()
        workspace.focusInput()
        await settleWindow(window)
        // Hiding the inline capsule gives its width back to the editor.
        let idleFrame = try editorFrame()
        XCTAssertLessThan(idleFrame.minX, runningFrame.minX)
        XCTAssertEqual(idleFrame.maxX, runningFrame.maxX, accuracy: 1)
    }

    @MainActor func testFirstSubmissionMovesLocalDraftIntoTranscript() async throws {
        let workspace = await newConversationWorkspace()
        let presentation = try XCTUnwrap(workspace.viewed)
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace, settings: AppSettings(), presentation: presentation, openConnectionSettings: { _ in }, presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        XCTAssertFalse(containsTranscript(in: host))

        presentation.controller.draft = "First message"
        await settleWindow(window)
        XCTAssertFalse(containsTranscript(in: host))

        await workspace.send(presentation.id)
        await settleWindow(window)
        XCTAssertTrue(presentation.controller.transcript.contains { $0.kind == .user && $0.text == "First message" })
        XCTAssertTrue(containsTranscript(in: host))
        XCTAssertTrue(presentation.controller.draft.isEmpty)
    }

    @MainActor func testLongExtensionStatusStaysCollapsibleAcrossFirstSend() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        let controller = presentation.controller
        @Bindable var expansion = TestExtensionStatusExpansion()
        var panelFrame = CGRect.zero
        var inputFrame = CGRect.zero
        let host = NSHostingView(rootView: GeometryReader { _ in
            SessionDetailLayout(isStarter: controller.transcript.isEmpty) {
                if controller.transcript.isEmpty {
                    Text("Starter").frame(height: 44)
                } else {
                    TranscriptView(items: controller.transcript)
                }
            } footer: { viewportHeight in
                VStack(spacing: 0) {
                    if !controller.extensionStatus.isEmpty {
                        ExtensionStatusView(controller: controller, viewportHeight: viewportHeight, expanded: $expansion.expanded)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { panelFrame = $0 }
                    }
                    TextField("Input", text: Bindable(controller).draft)
                        .frame(height: 36)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { inputFrame = $0 }
                }
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        let activated = await workspace.activate(presentation.id)
        XCTAssertTrue(activated)
        runtime.emit(.extensionStatus("long-widget", (1...90).map { "Extension status line \($0)" }.joined(separator: "\n")))
        await settleWindow(window)
        XCTAssertEqual(controller.extensionStatus.count, 1)
        XCTAssertFalse(containsTranscript(in: host))

        func detailsScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.height <= 156,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 500 {
                return scroll
            }
            return view.subviews.lazy.compactMap { detailsScroll(in: $0) }.first
        }

        func assertPanelAndInputVisible() {
            XCTAssertGreaterThan(panelFrame.height, 0)
            XCTAssertGreaterThan(inputFrame.height, 0)
            XCTAssertGreaterThan(panelFrame.minY, 0)
            XCTAssertLessThanOrEqual(panelFrame.maxY, inputFrame.minY + 1)
            XCTAssertLessThanOrEqual(inputFrame.maxY, host.bounds.height + 1)
        }

        expansion.expanded = true
        await settleWindow(window)
        XCTAssertNotNil(detailsScroll(in: host))
        assertPanelAndInputVisible()

        controller.draft = "First message with extension feedback"
        await workspace.send(presentation.id)
        await settleWindow(window)
        XCTAssertTrue(containsTranscript(in: host))
        XCTAssertTrue(expansion.expanded)
        let details = try XCTUnwrap(detailsScroll(in: host))
        assertPanelAndInputVisible()

        let panelTop = panelFrame.minY
        let clip = details.contentView
        let bottom = clip.constrainBoundsRect(NSRect(x: 0, y: 10_000, width: clip.bounds.width, height: clip.bounds.height))
        XCTAssertGreaterThan(bottom.minY, 500)
        clip.scroll(to: bottom.origin)
        details.reflectScrolledClipView(clip)
        await settleWindow(window)
        XCTAssertEqual(panelFrame.minY, panelTop, accuracy: 1)
        assertPanelAndInputVisible()

        for shouldExpand in [false, true, false] {
            expansion.expanded = shouldExpand
            await settleWindow(window)
            XCTAssertEqual(detailsScroll(in: host) != nil, shouldExpand)
            assertPanelAndInputVisible()
        }
    }

    @MainActor func testTerminationConfirmsRunningWorkButNotIdleConnection() async throws {
        let workspace = await newConversationWorkspace()
        let id = try XCTUnwrap(workspace.selected?.id)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)

        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)

        let controller = try XCTUnwrap(workspace.execution(for: id))
        controller.draft = "Run the termination fixture"
        await workspace.send(id)
        XCTAssertTrue(workspace.terminationWouldInterruptWork)

        controller.draft = "Keep this draft"
        let disconnected = await workspace.disconnectAll()
        XCTAssertTrue(disconnected)
        XCTAssertFalse(workspace.terminationWouldInterruptWork)
        XCTAssertEqual(workspace.selected?.draft, "Keep this draft")
    }

    @MainActor func testACPThoughtAndTaskPlanDoNotPopulateExtensionStatus() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        let controller = presentation.controller
        let activated = await workspace.activate(presentation.id)
        XCTAssertTrue(activated)

        runtime.emit(.runStarted)
        runtime.emit(.thought("Analyzing repository structure"))
        runtime.emit(.plan([
            .init(id: "0", content: "Inspect code", status: .completed),
            .init(id: "1", content: "Update UI", status: .inProgress)
        ]))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(controller.extensionStatus.isEmpty)
        XCTAssertEqual(controller.activeTurn?.thoughtText, "Analyzing repository structure")
        XCTAssertEqual(controller.plan.map(\.content), ["Inspect code", "Update UI"])
        XCTAssertEqual(controller.plan.map(\.status), [.completed, .inProgress])

        // In Workbench 2.0, task plan progress is rendered in ComposerNoticesStack above ComposerView.
        let planNotice = ComposerNoticeItem(
            id: "task-plan",
            priority: 70,
            severity: .information,
            text: "任务计划 · 已完成 1/2",
            interaction: .actionableRow(hint: "查看任务计划", action: {})
        )
        let host = NSHostingView(rootView: ComposerNoticesStack(items: [planNotice], maxHeight: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)
        let heightWithPlan = host.fittingSize.height
        XCTAssertGreaterThan(heightWithPlan, 0)

        // Verify TaskPlanDetailsSheet renders plan entries and adjusts when cleared.
        let sheetHost = NSHostingView(rootView: TaskPlanDetailsSheet(controller: controller, close: {}))
        let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        sheetWindow.contentView = sheetHost
        await settleWindow(sheetWindow)
        let populatedSheetHeight = sheetHost.fittingSize.height
        XCTAssertGreaterThan(populatedSheetHeight, 0)

        runtime.emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.transcriptTurnStarts.allSatisfy { $0.turn.thoughtText.isEmpty })
        XCTAssertEqual(controller.plan.count, 2)

        runtime.emit(.plan([]))
        try await Task.sleep(for: .milliseconds(30))
        host.rootView = ComposerNoticesStack(items: [], maxHeight: 120)
        await settleWindow(window)
        await settleWindow(sheetWindow)
        XCTAssertTrue(controller.plan.isEmpty)
        XCTAssertEqual(host.fittingSize.height, 0, accuracy: 0.5)
        XCTAssertLessThan(sheetHost.fittingSize.height, populatedSheetHeight)
    }

    @MainActor func testEmptyThoughtDisplaysWaitingLabel() async throws {
        let turn = TurnRecord(startedAt: .now)
        turn.thoughtText = "  \n"
        let host = NSHostingView(rootView: TranscriptThinkingRow(turn: turn, expanded: .constant(false), contentChanged: {})
            .zivviTypography(.extraLarge))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)
        let visibleText = try recognizedTexts(in: host).map(\.text).joined(separator: " ")
        XCTAssertTrue(visibleText.localizedCaseInsensitiveContains(String(localized: "等待回复")), visibleText)
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains(String(localized: "思考中")))
        XCTAssertFalse(TranscriptThinkingRow.isWaiting("真实内容"))
    }

    @MainActor func testCollapsibleThinkingRowRendersThoughtDetailsBelowToolCalls() async throws {
        let turn = TurnRecord(startedAt: .now)
        turn.thoughtText = "Inspecting ACPEventMapper and TranscriptView"
        var expanded = false
        var contentChanges = 0
        let host = NSHostingView(rootView: TranscriptThinkingRow(
            turn: turn,
            expanded: Binding(get: { expanded }, set: { expanded = $0 }),
            contentChanged: { contentChanges += 1 }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settleWindow(window)

        let collapsedHeight = host.fittingSize.height
        XCTAssertGreaterThan(collapsedHeight, 0)

        expanded = true
        host.rootView = TranscriptThinkingRow(
            turn: turn,
            expanded: Binding(get: { expanded }, set: { expanded = $0 }),
            contentChanged: { contentChanges += 1 }
        )
        await settleWindow(window)
        XCTAssertGreaterThan(host.fittingSize.height, collapsedHeight)
    }

    @MainActor func testWorkbenchRestoresShortAndLongMessagesAtSameScreenPosition() async throws {
        let workspace = await newConversationWorkspace()
        let first = try XCTUnwrap(workspace.viewed)
        let project = try XCTUnwrap(workspace.selected?.projectID)
        let positions = WindowTranscriptPositions()
        let state = positions.state(for: first.id)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all), readingPositions: positions))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        let longMessage = (0..<30).map { $0 == 12 ? "MidpointMarker" : "Paragraph \($0)" }.joined(separator: "\n\n")
        func populate(_ controller: SessionController) {
            controller.showHistory((0..<60).map { index in
                let text = switch index {
                case 18: "ShortMarker"
                case 40: longMessage
                default: "Message \(index)"
                }
                return .init(id: "reading-\(index)", kind: .assistant, text: text)
            })
        }
        func settle() async throws {
            await settleWindow(window)
            try await Task.sleep(for: .milliseconds(450))
        }
        func screenY(_ marker: String) throws -> CGFloat {
            let line = try XCTUnwrap(try recognizedTexts(in: host).first { $0.text.localizedCaseInsensitiveContains(marker) },
                                     "Expected visible text: \(marker)")
            return line.box.midY * host.bounds.height
        }

        populate(first.controller)
        try await settle()
        var secondID: UUID?
        for (index, marker) in [(18, "ShortMarker"), (40, "MidpointMarker")] {
            state.requestJump(to: "reading-\(index)")
            try await settle()
            if index == 40 {
                let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
                let clip = scroll.contentView
                clip.scroll(to: .init(x: 0, y: clip.bounds.minY + 220))
                scroll.reflectScrolledClipView(clip)
                try await settle()
                XCTAssertGreaterThan(try XCTUnwrap(state.readingAnchor).offset, 100)
            }
            let before = try screenY(marker)
            for _ in 0..<2 {
                if let secondID {
                    await workspace.select(secondID)
                } else {
                    _ = await workspace.createSession(in: project)
                    let second = try XCTUnwrap(workspace.viewed)
                    XCTAssertNotEqual(second.id, first.id)
                    secondID = second.id
                    populate(second.controller)
                }
                try await settle()
                XCTAssertTrue(positions.state(for: try XCTUnwrap(secondID)).follow)
                await workspace.select(first.id)
                let resumed = try XCTUnwrap(workspace.viewed)
                XCTAssertEqual(resumed.id, first.id)
                if resumed.controller.transcript.isEmpty { populate(resumed.controller) }
                try await settle()
                XCTAssertFalse(state.follow)
                let restored = try screenY(marker)
                print("DS22 \(marker): \(before) -> \(restored) pt")
                XCTAssertEqual(restored, before, accuracy: 3)
            }
        }
    }

    @MainActor private func newConversationWorkspace(runtime: StubSessionRuntime = StubSessionRuntime(),
                                                       projectPath: String = FileManager.default.temporaryDirectory.path) async -> WorkspaceController {
        let project = ProjectRecord(path: projectPath)
        let reference = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [reference]
        snapshot.selectedSessionID = reference.id
        let workspace = WorkspaceController(store: MemoryStore(snapshot)) { _, _ in
            runtime
        }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        return workspace
    }

    @MainActor private func settleWindow(_ window: NSWindow) async {
        for _ in 0..<8 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor private func containsTranscript(in view: NSView) -> Bool {
        isTranscriptScrollView(view) || view.subviews.contains { containsTranscript(in: $0) }
    }

    func testGitInspectorCoversUnbornDetachedUpstreamChangesAndDeduplication() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Zivvi-Git-Test-\(UUID())")
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        let nonRepo = root.appendingPathComponent("plain")
        let missing = root.appendingPathComponent("does-not-exist")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let missingState = await GitRepositoryInspector.inspect(directory: missing, now: fixedNow)
        XCTAssertEqual(missingState, .directoryMissing(directoryPath: GitRepositoryInspector.normalizedPath(missing.path), reason: String(localized: "工作目录不存在或已移动。"), updatedAt: fixedNow))
        if case .notRepository = GitRepositoryInspector.inspectSync(directoryPath: nonRepo.path) {} else {
            XCTFail("Expected non-repository state")
        }

        try runGit(["init", "--bare", "-q"], cwd: remote)
        try runGit(["init", "-q", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test"], cwd: repo)

        // Unborn repo keeps branch name and marks ahead unavailable.
        let unbornState = GitRepositoryInspector.inspectSync(directoryPath: repo.path)
        let unbornSnap = try XCTUnwrap(unbornState.snapshot)
        XCTAssertEqual(unbornSnap.branch, .branch(name: "main", hasCommits: false))
        if case .unavailable = unbornSnap.ahead {} else { XCTFail("Unborn repo should have unavailable ahead count") }

        try "keep\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "del\n".write(to: repo.appendingPathComponent("del.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "rename line\n", count: 8).write(to: repo.appendingPathComponent("ren.txt"), atomically: true, encoding: .utf8)
        try "recreate\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)
        try "*.ignored\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-q", "-m", "initial"], cwd: repo)

        // No upstream yet.
        let noUpstream = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(noUpstream.branch, .branch(name: "main", hasCommits: true))
        XCTAssertEqual(noUpstream.ahead.displayText, "—")
        XCTAssertEqual(noUpstream.changes.totalCount, 0)

        // Configure local bare upstream: 0 ahead, then 2 ahead.
        try runGit(["remote", "add", "origin", remote.path], cwd: repo)
        try runGit(["push", "-q", "-u", "origin", "main"], cwd: repo)
        let zeroAhead = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(zeroAhead.ahead, .count(0, upstream: "origin/main"))

        try "c1\n".write(to: repo.appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c1.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c1"], cwd: repo)
        try "c2\n".write(to: repo.appendingPathComponent("c2.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "c2.txt"], cwd: repo)
        try runGit(["commit", "-q", "-m", "c2"], cwd: repo)

        // Staged + unstaged duplicate modification on keep.txt -> 1 modified.
        try "keep staged\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "keep.txt"], cwd: repo)
        try "keep worktree\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        // Deleted del.txt -> 1 deleted.
        try fm.removeItem(at: repo.appendingPathComponent("del.txt"))

        // Renamed ren.txt -> ren2.txt -> 1 renamed.
        try runGit(["mv", "ren.txt", "ren2.txt"], cwd: repo)

        // Staged delete + recreated untracked at same path -> 1 modified (deduplicated).
        try runGit(["rm", "-q", "recreate.txt"], cwd: repo)
        try "recreated\n".write(to: repo.appendingPathComponent("recreate.txt"), atomically: true, encoding: .utf8)

        // Staged add + unstaged modify -> 1 added; untracked -> 1 added; ignored -> excluded.
        try "new staged\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "new_staged.txt"], cwd: repo)
        try "new staged edited\n".write(to: repo.appendingPathComponent("new_staged.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: repo.appendingPathComponent("skip.ignored"), atomically: true, encoding: .utf8)

        let dirty = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        XCTAssertEqual(dirty.ahead, .count(2, upstream: "origin/main"))
        XCTAssertEqual(dirty.changes.addedCount, 2) // new_staged.txt, untracked.txt
        XCTAssertEqual(dirty.changes.deletedCount, 1) // del.txt
        XCTAssertEqual(dirty.changes.modifiedCount, 2) // keep.txt, recreate.txt
        XCTAssertEqual(dirty.changes.renamedCount, 1) // ren.txt -> ren2.txt
        XCTAssertEqual(dirty.changes.totalCount, 6)

        // Detached HEAD shows short SHA and unavailable ahead.
        try runGit(["checkout", "-q", "--detach", "HEAD"], cwd: repo)
        let detached = try XCTUnwrap(GitRepositoryInspector.inspectSync(directoryPath: repo.path).snapshot)
        if case .detached(let sha) = detached.branch {
            XCTAssertFalse(sha.isEmpty)
        } else {
            XCTFail("Expected detached HEAD")
        }
        if case .unavailable = detached.ahead {} else { XCTFail("Detached HEAD should have unavailable ahead count") }
    }

    @MainActor func testGitStoreDiscardsStaleResponsesAndNeverBorrowsOtherProjectOnFailure() async throws {
        let dirA = "/tmp/git-store-a-\(UUID().uuidString)"
        let dirB = "/tmp/git-store-b-\(UUID().uuidString)"
        let snapA = GitRepositorySnapshot(
            directoryPath: GitRepositoryInspector.normalizedPath(dirA),
            checkoutRoot: GitRepositoryInspector.normalizedPath(dirA),
            branch: .branch(name: "main", hasCommits: true),
            ahead: .count(2, upstream: "origin/main"),
            changes: .init(addedFiles: ["a.swift"], deletedFiles: [], modifiedFiles: [], renamedFiles: []),
            updatedAt: Date()
        )
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
        }
        let counter = Counter()
        let firstInspectionStarted = expectation(description: "First inspection entered")
        let staleResponseReturned = expectation(description: "Superseded inspection returned")
        let staleResponseGate = AsyncStream<Void>.makeStream()
        // Keep the first inspector suspended even after the store cancels its refresh task.
        let waitForStaleResponse = Task {
            for await _ in staleResponseGate.stream {}
        }
        defer { staleResponseGate.continuation.finish() }

        let store = GitStatusStore { url in
            let path = url.path
            if path.hasSuffix(URL(fileURLWithPath: dirA).lastPathComponent) {
                let step = counter.next()
                if step == 1 {
                    firstInspectionStarted.fulfill()
                    await waitForStaleResponse.value
                    staleResponseReturned.fulfill()
                    return .loaded(snapA, isStale: false, refreshError: nil)
                }
                return .notRepository(directoryPath: path, reason: "不再是仓库", updatedAt: Date())
            }
            return .failed(directoryPath: path, reason: "读取失败", updatedAt: Date())
        }

        store.refresh(directory: dirA, force: true)
        await fulfillment(of: [firstInspectionStarted], timeout: 1)
        store.refresh(directory: dirA, force: true)
        store.refresh(directory: dirB, force: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if case .notRepository = store.state(for: dirA), case .failed = store.state(for: dirB) { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case .notRepository = store.state(for: dirA) else {
            XCTFail("Expected newer generation result for dirA, got \(store.state(for: dirA))")
            return
        }
        guard case .failed = store.state(for: dirB) else {
            XCTFail("Expected failed state for dirB without borrowing dirA values")
            return
        }

        let staleStateWrite = expectation(description: "Superseded inspection changes Git state")
        staleStateWrite.isInverted = true
        withObservationTracking {
            _ = store.state(for: dirA)
        } onChange: {
            staleStateWrite.fulfill()
        }
        staleResponseGate.continuation.finish()
        await fulfillment(of: [staleResponseReturned], timeout: 1)
        await fulfillment(of: [staleStateWrite], timeout: 0.2)
    }


    @MainActor func testToolOnlyTurnFollowUpSplitStopAndDisconnectUncertainty() async throws {
        let clock = TestClock()
        let controller = SessionController(clock: clock)
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)

        // The tool-only execution gets a standalone header.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-1", name: "read", state: .completed))))
        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "only-2", name: "bash", state: .completed))))
        clock.advance(by: 12)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))

        let rows = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        let headers = projectedTurns(rows)
        XCTAssertEqual(headers.count, 1)
        let toolTurn = try XCTUnwrap(headers.first)
        XCTAssertEqual(try XCTUnwrap(toolTurn.durationSeconds), 12, accuracy: 0.01)
        XCTAssertEqual(toolTurn.status, .completed)

        // Stop round records stopped status + duration.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let stoppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(stoppedAssistant)))
        clock.advance(by: 5)
        controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: true)))
        let stoppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(stoppedTurn.status, .stopped)
        XCTAssertEqual(try XCTUnwrap(stoppedTurn.durationSeconds), 5, accuracy: 0.01)

        // Disconnect mid-round marks uncertain without guessing end time.
        controller.receive(.init(instanceID: runtime.instanceID, event: .runStarted))
        let droppedAssistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(droppedAssistant)))
        clock.advance(by: 9)
        controller.receive(.init(instanceID: runtime.instanceID, event: .disconnected(cleanupConfirmed: false)))
        let droppedTurn = try XCTUnwrap(controller.transcript.last?.turn)
        XCTAssertEqual(droppedTurn.status, .uncertain)
        XCTAssertNil(droppedTurn.endedAt)
        XCTAssertNil(droppedTurn.durationSeconds)
    }

    @MainActor func testLiveHeaderSurvivesEmptyAssistantAndStopWithoutReplacingTheDraft() async throws {
        let controller = SessionController(clock: TestClock())
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        controller.draft = "Run with no visible reply"
        await controller.sendDraft()

        let before = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        XCTAssertEqual(before.count, 2)
        guard case .turnHeader(let turn) = before[1] else { return XCTFail("Expected a running header") }
        XCTAssertEqual(turn.status, .running)
        let assistant = UUID()
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantStarted(assistant)))
        controller.receive(.init(instanceID: runtime.instanceID, event: .assistantCompleted(assistant, "")))
        let file = URL(fileURLWithPath: "/tmp/an-unsent-attachment")
        controller.draft = "Keep editing"
        controller.draftFiles = [file]
        await controller.stop()

        let after = TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(turn.status, .stopped)
        XCTAssertEqual(controller.draft, "Keep editing")
        XCTAssertEqual(controller.draftFiles, [file])
        XCTAssertFalse(controller.isStopping)
        _ = await controller.disconnect()
    }

    @MainActor func testStopOnlyTargetsItsBoundSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in
            StubSessionRuntime()
        }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let addedProject = await workspace.addProject(root)
        let projectID = try XCTUnwrap(addedProject)
        let running = try XCTUnwrap(workspace.selected?.id)
        let controller = try XCTUnwrap(workspace.viewed?.controller)
        controller.draft = "Start a run"
        await workspace.send(running)
        await workspace.createSession(in: projectID)
        let browsed = try XCTUnwrap(workspace.selected?.id)
        XCTAssertNotEqual(browsed, running)

        await workspace.stop(browsed)
        XCTAssertEqual(workspace.executionIDs, [running])
        XCTAssertEqual(controller.phase, .running)
        await workspace.stop(running)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(workspace.selected?.id, browsed)
        _ = await workspace.disconnectAll()
    }

    @MainActor func testDuplicateFollowUpsAcquireDistinctHeadersOnlyWhenDequeued() async throws {
        let controller = SessionController(clock: TestClock())
        let runtime = StubSessionRuntime(disposition: { $0.mode == .followUp ? .queued : .started })
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Start"))
        let first = UserPrompt(text: "repeat", mode: .followUp)
        let second = UserPrompt(text: "repeat", mode: .followUp)
        await controller.sendDraft(first)
        await controller.sendDraft(second)

        func project() -> [TranscriptDisplayRow] {
            TranscriptDisplayRow.project(controller.transcript, turnStarts: controller.transcriptTurnStarts)
        }
        func queue(_ pending: [String]) {
            controller.receive(.init(instanceID: runtime.instanceID, event: .queue(.init(followUp: pending))))
        }
        queue(["repeat", "repeat"])
        XCTAssertEqual(projectedTurns(project()).count, 1)
        queue(["repeat"])
        let inputs = controller.transcript.filter { $0.kind == .user }
        XCTAssertEqual(inputs.map(\.delivery), [.accepted, .accepted, .queued])
        let firstHeaders = projectedTurns(project())
        XCTAssertEqual(firstHeaders.map(\.status), [.completed, .running])

        controller.receive(.init(instanceID: runtime.instanceID, event: .tool(.init(id: "between", name: "read", state: .completed))))
        queue([])
        let rows = project()
        let finalHeaders = projectedTurns(rows)
        XCTAssertEqual(finalHeaders.map(\.status), [.completed, .completed, .running])
        XCTAssertEqual(Set(finalHeaders.map(\.id)).count, 3)
        XCTAssertEqual(finalHeaders.first?.id, firstHeaders.first?.id)
        XCTAssertEqual(finalHeaders.dropFirst().first?.id, firstHeaders.last?.id)
        _ = await controller.disconnect()
    }

    func testTimestampFormattingSameYearAndCrossYearAndDuration() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10, minute: 0))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 46, second: 12))!
        let prevYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 58, second: 0))!

        let chinese = Locale(identifier: "zh_Hans_CN")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(sameDay, relativeTo: now, calendar: cal, timeZone: tz, locale: chinese), "11月19日 09:46")
        XCTAssertEqual(TranscriptTimestampFormatter.shortTime(prevYear, relativeTo: now, calendar: cal, timeZone: tz, locale: chinese), "2025年12月31日 23:58")
        let sameYearEnglish = TranscriptTimestampFormatter.shortTime(sameDay, relativeTo: now, calendar: cal, timeZone: tz, locale: english)
        XCTAssertTrue(sameYearEnglish.contains("Nov 19"))
        XCTAssertFalse(sameYearEnglish.contains("2026"))
        let previousYearEnglish = TranscriptTimestampFormatter.shortTime(prevYear, relativeTo: now, calendar: cal, timeZone: tz, locale: english)
        XCTAssertTrue(previousYearEnglish.contains("Dec 31, 2025"))
        for locale in [chinese, english] {
            XCTAssertTrue(TranscriptTimestampFormatter.fullTimeWithZone(sameDay, calendar: cal, timeZone: tz, locale: locale).contains("Asia/Shanghai"))
        }
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(138), String(localized: "\(2) 分 \(18) 秒"))
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(0.4), String(localized: "不足 1 秒"))
        XCTAssertEqual(TranscriptTimestampFormatter.durationText(3665), String(localized: "\(1) 小时 \(1) 分 \(5) 秒"))
    }

    func testApprovalDeadlineShowsJustTimeTodayAndDatesForEarlierDays() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 18))!
        let locale = Locale(identifier: "zh_Hans_CN")
        for (year, day, expected) in [(2026, 27, "15:17"), (2026, 26, "11月26日 15:17"), (2025, 26, "2025年11月26日 15:17")] {
            let deadline = calendar.date(from: DateComponents(year: year, month: 11, day: day, hour: 15, minute: 17, second: 31))!
            XCTAssertEqual(TranscriptTimestampFormatter.approvalDeadline(deadline, relativeTo: now,
                                                                          calendar: calendar, timeZone: timeZone, locale: locale),
                           expected)
        }
    }

    func testApprovalDeadlineReformatsTheSameDateWhenReferenceCrossesMidnight() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let locale = Locale(identifier: "zh_Hans_CN")
        let deadline = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 12, day: 31, hour: 23, minute: 58)))
        let afterMidnight = deadline.addingTimeInterval(120)
        XCTAssertEqual(TranscriptTimestampFormatter.approvalDeadline(deadline, relativeTo: deadline,
                                                                      calendar: calendar, timeZone: timeZone, locale: locale),
                       "23:58")
        XCTAssertEqual(TranscriptTimestampFormatter.approvalDeadline(deadline, relativeTo: afterMidnight,
                                                                      calendar: calendar, timeZone: timeZone, locale: locale),
                       "2026年12月31日 23:58")
    }

    @MainActor func testRunningTurnFormatsElapsedDurationAndCompletedTurnStopsCounting() {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let monotonicStart = ContinuousClock.now
        let turn = TurnRecord(startedAt: start, monotonicStart: monotonicStart)
        let initial = TurnHeaderSummary(turn: turn, relativeTo: start, monotonicNow: monotonicStart)
        let running = TurnHeaderSummary(turn: turn, relativeTo: start.addingTimeInterval(-10),
                                        monotonicNow: monotonicStart.advanced(by: .milliseconds(3_850)))
        let initialElapsed = String(localized: "不足 1 秒")
        let runningElapsed = String(localized: "\(3) 秒")
        XCTAssertEqual(initial.title, "Zap!")
        XCTAssertEqual(initial.brandState, .starting)
        XCTAssertEqual(initial.displayText, String(localized: "执行中"))
        XCTAssertEqual(initial.elapsedText, initialElapsed)
        XCTAssertEqual(running.title, "Zap…")
        XCTAssertEqual(running.brandState, .running)
        XCTAssertEqual(running.displayText, String(localized: "执行中"))
        XCTAssertEqual(running.elapsedText, runningElapsed)
        XCTAssertEqual(running.accessibilityLabel, String(localized: "智能体正在执行"))
        XCTAssertEqual(running.accessibilityValue, String(localized: "用时 \(runningElapsed)"))

        for (seconds, elapsedText) in [
            (59, String(localized: "\(59) 秒")),
            (60, String(localized: "\(1) 分 \(0) 秒")),
            (3600, String(localized: "\(1) 小时 \(0) 分 \(0) 秒"))
        ] {
            let summary = TurnHeaderSummary(turn: turn, relativeTo: start,
                                            monotonicNow: monotonicStart.advanced(by: .seconds(seconds)))
            XCTAssertEqual(summary.elapsedText, elapsedText)
            XCTAssertEqual(summary.accessibilityLabel, running.accessibilityLabel)
            XCTAssertEqual(summary.accessibilityValue, String(localized: "用时 \(elapsedText)"))
        }

        turn.status = .completed
        turn.durationSeconds = 3.85
        turn.endedAt = start.addingTimeInterval(3.85)
        let completed = TurnHeaderSummary(turn: turn, relativeTo: start.addingTimeInterval(61),
                                          monotonicNow: monotonicStart.advanced(by: .seconds(61)))
        XCTAssertEqual(completed.displayText, String(localized: "执行 \(TranscriptTimestampFormatter.durationText(3.85))"))
        XCTAssertEqual(completed.tooltipText, completed.displayText)
        XCTAssertNil(completed.elapsedText)
        XCTAssertEqual(completed.title, "Zzzap!")
        XCTAssertEqual(completed.brandState, .completed)
        XCTAssertEqual(completed.accessibilityLabel, String(localized: "智能体执行完成"))
        XCTAssertEqual(completed.accessibilityValue,
                       String(localized: "用时 \(TranscriptTimestampFormatter.durationText(3.85))"))
    }

    @MainActor func testBrandTurnStatesLocalizeWithAndWithoutDurations() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let cases: [(TurnStatus, String, String, String, String, String)] = [
            (.running, "Zap…", "执行中", "Running", "智能体正在执行", "Agent running"),
            (.completed, "Zzzap!", "执行完成", "Completed", "智能体执行完成", "Agent completed"),
            (.stopped, "", "已停止", "Stopped", "智能体已停止", "Agent stopped"),
            (.failed, "Zzzzt…", "执行失败", "Failed", "智能体执行失败", "Agent failed"),
            (.uncertain, "", "待核实", "Unconfirmed", "智能体执行状态待核实", "Agent status unconfirmed"),
        ]
        for (status, title, chineseStatus, englishStatus, chineseLabel, englishLabel) in cases {
            let turn = TurnRecord(status: status)
            for (language, expectedStatus, expectedLabel) in [
                ("zh-Hans", chineseStatus, chineseLabel), ("en", englishStatus, englishLabel),
            ] {
                let locale = Locale(identifier: language)
                turn.startedAt = nil
                turn.durationSeconds = nil
                let unknown = TurnHeaderSummary(turn: turn, relativeTo: now, locale: locale)
                XCTAssertEqual(unknown.title, title)
                XCTAssertEqual(unknown.displayText, expectedStatus)
                XCTAssertEqual(unknown.accessibilityLabel, expectedLabel)
                XCTAssertNil(unknown.accessibilityValue)

                turn.startedAt = now.addingTimeInterval(-12)
                turn.durationSeconds = status == .running ? nil : 12
                let known = TurnHeaderSummary(turn: turn, relativeTo: now, locale: locale)
                let duration = TranscriptTimestampFormatter.durationText(12, locale: locale)
                XCTAssertEqual(known.title, title)
                XCTAssertEqual(known.accessibilityLabel, expectedLabel)
                XCTAssertTrue(known.accessibilityValue?.contains(duration) == true)
                if status == .running {
                    XCTAssertEqual(known.displayText, expectedStatus)
                    XCTAssertEqual(known.elapsedText, duration)
                } else {
                    XCTAssertTrue(known.displayText.contains(duration))
                    XCTAssertNil(known.elapsedText)
                }
            }
        }
    }

    @MainActor func testBrandComponentsRenderInNativeHostingView() async throws {
        let project = ProjectRecord(path: "/tmp/Zivvi")
        let session = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in FakeRuntime() }
        let composer = ComposerView(controller: SessionController(), workspace: workspace,
                                    isViewedSessionActive: false,
                                    sessionConfigurationDisabled: false, model: nil, reference: session, project: project,
                                    panelsBlocked: false, onPickFiles: {}, onSend: {}, onStop: {},
                                    sendEnabled: false, isStarter: true)
        let sizes: [(String, CGFloat, InterfaceFontSize, ColorScheme, NSAppearance.Name)] = [
            ("zh-Hans", 736, .standard, .light, .aqua),
            ("en", 736, .compact, .dark, .darkAqua),
            ("zh-Hans", 326, .large, .dark, .darkAqua),
            ("en", 326, .extraLarge, .light, .aqua),
        ]
        for (language, width, fontSize, scheme, appearance) in sizes {
            let chinese = language == "zh-Hans"
            let short = TranscriptItem(id: "short", kind: .user, text: chinese ? "继续" : "Continue")
            let longer = TranscriptItem(id: "longer", kind: .user, text: chinese
                ? "请先核对现有实现，再对照测试结果列出会影响旧会话的改动。\n保留已有的键盘快捷键。"
                : "Check the existing implementation and list the changes that affect earlier sessions.\nKeep the keyboard shortcuts.")
            let files = TranscriptItem(id: "files", kind: .user,
                                            attachedFiles: [
                                                URL(fileURLWithPath: "/tmp/session-regression-and-attachment-layout-results.txt"),
                                                URL(fileURLWithPath: "/tmp/previous-message-and-keyboard-shortcut-evidence.log"),
                                            ])
            let pending = TranscriptItem(id: "pending", kind: .user, text: chinese ? "检查附件" : "Check attachments",
                                        delivery: .queued)
            let running = TurnRecord(status: .running, startedAt: Date.now.addingTimeInterval(-12))
            let rows = [running, TurnRecord(status: .completed, durationSeconds: 12),
                        TurnRecord(status: .stopped), TurnRecord(status: .failed, durationSeconds: 62),
                        TurnRecord(status: .uncertain)]
            let contentWidth = width - 2 * WorkbenchReadingColumn.minimumGutter
            let content = VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    SessionStarterTitle()
                    composer
                }
                ForEach([short, longer, files, pending]) { item in
                    TranscriptRow(item: item, width: contentWidth, contentChanged: {})
                }
                ForEach(rows) { turn in TurnHeaderView(turn: turn, locale: Locale(identifier: language)) }
            }
            .frame(width: contentWidth)
            .padding(WorkbenchReadingColumn.minimumGutter)
            .zivviTypography(fontSize)
            .background(ZivviTheme.pageBackground)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 880),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            await settleWindow(window)
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertGreaterThan(size.height, 0)
            window.setContentSize(size)
            await settleWindow(window)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Zivvi Brand \(language) \(Int(width)) \(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testUsagePresentationAndLateResponseRejection() async {
        let usage = RuntimeUsage(
            sessionID: "s1",
            tokens: .init(input: 1_212_641, output: 127_445, cacheRead: 89_359_488, cacheWrite: 0, total: 90_699_574, inputIsUncached: true),
            estimatedCostUSD: nil,
            context: .init(tokens: 285_400, window: 475_000, percent: 60.08),
            observedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
        let normal = UsagePresentationSnapshot(usage: usage, isConnected: true, isStale: false, isLoading: false, isCompacting: false)
        XCTAssertEqual(normal.summaryText, "285k / 475k")
        XCTAssertEqual(normal.percentText, "\(60.1.formatted(.number))%")
        XCTAssertFalse(normal.isContextPending)
        XCTAssertEqual(normal.totalTokensText, "90.70M")
        XCTAssertTrue(normal.cacheHitRateText?.contains(0.987.formatted(.percent.precision(.fractionLength(1)))) == true)
        XCTAssertEqual(normal.costText, String(localized: "无法估算"))
        XCTAssertFalse(normal.isOverCapacity)

        let zero = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", tokens: .init(total: 0, inputIsUncached: true), context: .init(tokens: 0, window: 475_000, percent: 0)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertEqual(zero.summaryText, "0 / 475k")
        XCTAssertEqual(zero.percentText, "0%")

        let compacted = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: nil, window: 475_000, percent: nil)),
            isConnected: true, isStale: true, isLoading: false, isCompacting: true
        )
        XCTAssertEqual(compacted.summaryText, String(localized: "待更新"))
        XCTAssertTrue(compacted.isContextPending)
        XCTAssertNil(compacted.summaryRatio)

        let unavailable = UsagePresentationSnapshot(
            usage: nil, isConnected: false, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertEqual(unavailable.summaryText, String(localized: "不可用"))
        XCTAssertFalse(unavailable.isContextPending)

        let over = UsagePresentationSnapshot(
            usage: RuntimeUsage(sessionID: "s1", context: .init(tokens: 500_000, window: 475_000, percent: 105.3)),
            isConnected: true, isStale: false, isLoading: false, isCompacting: false
        )
        XCTAssertTrue(over.isOverCapacity)
        XCTAssertEqual(over.summaryRatio, 1.0)
        XCTAssertEqual(over.percentText, "\(105.3.formatted(.number))%")

        // Late usage response from another session ID is discarded.
        let controller = SessionController()
        let runtime = StubSessionRuntime(sessionID: "real-session")
        await controller.connect(runtime)
        runtime.enqueueUsage(.success(RuntimeUsage(sessionID: "stale-session", tokens: .init(total: 999))))
        await controller.refreshUsage()
        XCTAssertNil(controller.usage?.tokens.total)
        _ = await controller.disconnect()
    }


    @MainActor private func projectedTurns(_ rows: [TranscriptDisplayRow]) -> [TurnRecord] {
        rows.compactMap { row in
            guard case .turnHeader(let turn) = row else { return nil }
            return turn
        }
    }

    func testWorktreeChoicesAndCreationUseTheSelectedCommitAndPreserveLocalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "worktree@example.test"], cwd: repo)
        try runGit(["config", "user.name", "Worktree Test"], cwd: repo)
        let source = repo.appendingPathComponent("source.txt")
        try "committed".write(to: source, atomically: true, encoding: .utf8)
        try runGit(["add", "source.txt"], cwd: repo)
        try runGit(["commit", "-m", "base"], cwd: repo)
        let initial = await GitRepositoryInspector.worktrees(in: repo.path)
        let head = try XCTUnwrap(initial?.first?.commit)
        XCTAssertEqual(initial?.map(\.branch), ["main"])
        try "local edit".write(to: source, atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("task checkout")
        let worktree = try await GitRepositoryInspector.createWorktree(
            in: repo.path, destination: destination.path, branch: "task/checkout", base: head
        )
        let listed = await GitRepositoryInspector.worktrees(in: repo.path)
        XCTAssertEqual(Set(listed?.compactMap(\.branch) ?? []), Set(["main", "task/checkout"]))
        XCTAssertEqual(worktree.path, destination.resolvingSymlinksInPath().path)
        XCTAssertEqual(worktree.commit, head)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "local edit")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8), "committed")

        do {
            _ = try await GitRepositoryInspector.createWorktree(in: repo.path, destination: destination.path,
                                                                branch: "other", base: head)
            XCTFail("An existing directory was accepted")
        } catch GitWorktreeError.invalidDestination {}
    }

    @MainActor func testReplacedLockedWorktreeIsRejectedBySelectionAndRuntimeLaunch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Zivvi-Locked-Worktree-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("project")
        let checkout = root.appendingPathComponent("locked checkout")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["-c", "user.email=worktree@example.test", "-c", "user.name=Worktree Test", "commit",
                    "--allow-empty", "-m", "base"], cwd: repo)
        try runGit(["worktree", "add", "--lock", "-b", "locked", checkout.path], cwd: repo)

        var launchedPaths: [String] = []
        let workspace = WorkspaceController(store: MemoryStore(), validateWorktree: { project, path in
            await GitRepositoryInspector.isUsableWorktree(path, in: project)
        }) { project, session in
            launchedPaths.append(session.workingDirectory(in: project))
            return StubSessionRuntime()
        }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let addedProject = await workspace.addProject(repo)
        let projectID = try XCTUnwrap(addedProject)
        let originalID = try XCTUnwrap(workspace.selected?.id)
        let chosen = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: originalID)
        XCTAssertTrue(chosen)
        let available = await GitRepositoryInspector.worktrees(in: repo.path)
        let canonicalCheckout = checkout.resolvingSymlinksInPath().path
        XCTAssertTrue(available?.contains(where: { $0.path == canonicalCheckout }) == true)
        await workspace.send(originalID, submitted: .init(text: "run in locked checkout"))
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        await workspace.stop(originalID)
        let closed = await workspace.disconnect(originalID)
        XCTAssertTrue(closed)

        try fm.moveItem(at: checkout, to: root.appendingPathComponent("moved checkout"))
        try fm.createDirectory(at: checkout, withIntermediateDirectories: false)
        let remaining = await GitRepositoryInspector.worktrees(in: repo.path)
        XCTAssertFalse(remaining?.contains(where: { $0.path == canonicalCheckout }) ?? true)

        let originalController = try XCTUnwrap(workspace.viewed?.controller)
        originalController.draft = "keep this draft"
        await workspace.send(originalID)
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        XCTAssertEqual(workspace.workingDirectory(for: originalID), canonicalCheckout)
        XCTAssertEqual(originalController.draft, "keep this draft")
        XCTAssertNotNil(workspace.viewed?.executionError)

        // A checkout from another repository cannot satisfy the original registration either.
        try runGit(["init"], cwd: checkout)
        let createdSession = await workspace.createSession(in: projectID)
        let newID = try XCTUnwrap(createdSession)
        let replacement = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: newID)
        XCTAssertFalse(replacement)
        XCTAssertEqual(workspace.workingDirectory(for: newID), repo.resolvingSymlinksInPath().path)

        try fm.removeItem(at: checkout)
        await workspace.send(originalID)
        XCTAssertEqual(launchedPaths, [canonicalCheckout])
        XCTAssertEqual(originalController.draft, "keep this draft")
    }

    @MainActor func testSymlinkReplacementCannotRedirectASavedWorktree() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("Zivvi-Worktree-Redirect-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("project")
        let checkout = root.appendingPathComponent("locked checkout")
        let other = root.appendingPathComponent("other checkout")
        try fm.createDirectory(at: repo, withIntermediateDirectories: false)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["-c", "user.email=worktree@example.test", "-c", "user.name=Worktree Test", "commit",
                    "--allow-empty", "-m", "base"], cwd: repo)
        try runGit(["worktree", "add", "--lock", "-b", "locked", checkout.path], cwd: repo)
        try runGit(["worktree", "add", "-b", "other", other.path], cwd: repo)

        let store = MemoryStore()
        var launchedPaths: [String] = []
        func makeWorkspace() -> WorkspaceController {
            WorkspaceController(store: store, validateWorktree: { project, path in
                await GitRepositoryInspector.isUsableWorktree(path, in: project)
            }) { project, session in
                let path = session.workingDirectory(in: project)
                launchedPaths.append(path)
                if path == checkout.path { return StubSessionRuntime(sessionID: "locked-session", resumable: true) }
                return StubSessionRuntime(sessionID: session.id.uuidString)
            }
        }
        let workspace = makeWorkspace()
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let addedProject = await workspace.addProject(repo)
        let projectID = try XCTUnwrap(addedProject)
        let originalID = try XCTUnwrap(workspace.selected?.id)
        let chosen = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: originalID)
        XCTAssertTrue(chosen)
        await workspace.send(originalID, submitted: .init(text: "initial launch"))
        XCTAssertEqual(launchedPaths, [checkout.path])
        await workspace.stop(originalID)
        let closed = await workspace.disconnect(originalID)
        XCTAssertTrue(closed)

        let newSession = await workspace.createSession(in: projectID)
        let unlaunchedID = try XCTUnwrap(newSession)
        let prepared = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: unlaunchedID)
        XCTAssertTrue(prepared)
        await workspace.select(originalID)
        let original = try XCTUnwrap(workspace.viewed)
        original.controller.draft = "keep the draft"
        let attachment = root.appendingPathComponent("notes.txt")
        original.controller.draftFiles = [attachment]
        let saved = await workspace.flush()
        XCTAssertTrue(saved)
        try fm.moveItem(at: checkout, to: root.appendingPathComponent("moved checkout"))

        for replacement in [other, repo] {
            try fm.createSymbolicLink(at: checkout, withDestinationURL: replacement)

            let worktrees = await GitRepositoryInspector.worktrees(in: repo.path)
            let listed = try XCTUnwrap(worktrees)
            XCTAssertEqual(listed.count, 2)
            XCTAssertEqual(Set(listed.map(\.path)), Set([repo.path, other.path]))
            XCTAssertEqual(listed.first { $0.path == repo.path }?.branch, "main")
            XCTAssertEqual(listed.first { $0.path == other.path }?.branch, "other")
            XCTAssertFalse(listed.contains { $0.branch == "locked" })

            let chosenAlias = await workspace.chooseWorkingDirectory(worktree: checkout.path, for: unlaunchedID)
            XCTAssertFalse(chosenAlias)
            XCTAssertEqual(workspace.workingDirectory(for: unlaunchedID), checkout.path)
            await workspace.send(originalID)
            XCTAssertEqual(launchedPaths, [checkout.path])
            XCTAssertTrue(original.executionError?.contains(checkout.path) == true)
            XCTAssertEqual(original.controller.draft, "keep the draft")
            XCTAssertEqual(original.controller.draftFiles, [attachment])

            let reopened = makeWorkspace()
            await reopened.start(); reopened.setACPAgents([.antigravityPreset()])
            await reopened.select(originalID)
            XCTAssertEqual(reopened.selected?.worktreePath, checkout.path)
            XCTAssertEqual(reopened.selected?.runtimeSessionID, "locked-session")
            let activated = await reopened.activate(originalID)
            XCTAssertFalse(activated)
            XCTAssertTrue(reopened.viewed?.executionError?.contains(checkout.path) == true)
            XCTAssertEqual(reopened.viewed?.controller.draft, "keep the draft")
            XCTAssertEqual(launchedPaths, [checkout.path])

            if replacement == other { try fm.removeItem(at: checkout) }
        }

        // Explicit project selection clears an unlaunched choice and forks a bound session.
        let reset = await workspace.chooseWorkingDirectory(worktree: nil, for: unlaunchedID)
        XCTAssertTrue(reset)
        XCTAssertEqual(workspace.workingDirectory(for: unlaunchedID), repo.path)
        XCTAssertNil(workspace.state.sessions.first { $0.id == unlaunchedID }?.worktreePath)

        let forked = await workspace.chooseWorkingDirectory(worktree: nil, for: originalID)
        XCTAssertTrue(forked)
        let recoveryID = try XCTUnwrap(workspace.selected?.id)
        XCTAssertNotEqual(recoveryID, originalID)
        XCTAssertNil(workspace.selected?.worktreePath)
        XCTAssertEqual(workspace.workingDirectory(for: recoveryID), repo.path)
        XCTAssertEqual(workspace.viewed?.controller.draft, "keep the draft")
        XCTAssertEqual(workspace.viewed?.controller.draftFiles, [attachment])
        XCTAssertEqual(workspace.workingDirectory(for: originalID), checkout.path)
        XCTAssertEqual(original.controller.draft, "keep the draft")
        XCTAssertEqual(workspace.state.sessions.first { $0.id == originalID }?.runtimeSessionID, "locked-session")
        await workspace.send(recoveryID)
        XCTAssertEqual(launchedPaths, [checkout.path, repo.path])
        _ = await workspace.disconnect(recoveryID)
    }

    @MainActor func testCurrentApprovalOpensAutomaticallyAfterAnotherSheetCloses() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let instance = runtime.instanceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)

        let blockingSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(blockingSheet, completionHandler: nil)
        await settleWindow(window)
        let request = RuntimeInteraction(instanceID: instance, requestID: "auto-approval", kind: .confirm, title: "Confirm fixture",
                                         toolApproval: .init(workingDirectory: "/fixture/" + String(repeating: "long-directory/", count: 12),
                                                             operation: .command(text: "printf fixture", timeoutSeconds: nil)))
        controller.receive(.init(instanceID: instance, event: .interaction(request)))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === blockingSheet)
        XCTAssertEqual(controller.interactions, [request])

        window.endSheet(blockingSheet)
        for _ in 0..<30 where window.attachedSheet == nil || window.attachedSheet === blockingSheet {
            try await Task.sleep(for: .milliseconds(30))
            await settleWindow(window)
        }
        let approvalSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(approvalSheet === blockingSheet)
        XCTAssertEqual(approvalSheet.frame.width, 640, accuracy: 1)
        XCTAssertLessThan(approvalSheet.frame.height, 380, "A short command with wrapped path should fit tightly")
        XCTAssertEqual(controller.interactions, [request], "Automatically showing an approval must not answer it")
        let activeHeight = approvalSheet.frame.height
        controller.receive(.init(instanceID: instance, event: .interactionEnded(request.id, .expired)))
        for _ in 0..<25 where !controller.didExpire(request) {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        await settleWindow(approvalSheet)
        XCTAssertTrue(controller.didExpire(request))
        XCTAssertTrue(window.attachedSheet === approvalSheet)
        XCTAssertEqual(approvalSheet.frame.width, 640, accuracy: 1)
        let expiredContent = try XCTUnwrap(approvalSheet.contentView)
        XCTAssertLessThanOrEqual(abs(approvalSheet.frame.height - activeHeight), 16)
        XCTAssertGreaterThanOrEqual(expiredContent.bounds.height + 1, expiredContent.fittingSize.height)
        let expiredTexts = (try recognizedTexts(in: expiredContent)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(expiredTexts.contains("已超时"), "Expected timeout status in: \(expiredTexts)")
        XCTAssertTrue(expiredTexts.contains("关闭"), "Expected close button in: \(expiredTexts)")
        try clickApproval(in: expiredContent, x: expiredContent.bounds.width - 40,
                          fromTop: expiredContent.bounds.height - 34)
        try await awaitApprovalSheetDismissal(in: window)
        _ = await workspace.disconnect(id)
    }

    @MainActor func testInteractionCountdownTicksAndStopsAtZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = InteractionCountdown(expiresAt: now.addingTimeInterval(65))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now), .seconds(65))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(1)), .seconds(64))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(64.75)), .seconds(1))
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(65)), .zero)
        XCTAssertEqual(countdown.remainingDuration(relativeTo: now.addingTimeInterval(66)), .zero)
    }

    @MainActor func testEditApprovalPreviewFitsShortChangesAndScrollsLongChanges() throws {
        func replacement(old: String, new: String) throws -> RuntimeToolApproval.Replacement {
            let data = try JSONSerialization.data(withJSONObject: ["oldText": old, "newText": new])
            return try JSONDecoder().decode(RuntimeToolApproval.Replacement.self, from: data)
        }
        let short = try replacement(old: "let n = 1", new: "let n = 2")
        let long = try replacement(old: Array(repeating: "let n = 1", count: 40).joined(separator: "\n"), new: "let n = 2")
        func height(_ replacements: [RuntimeToolApproval.Replacement], expanded: Bool) -> CGFloat {
            NSHostingView(rootView: EditApprovalPreview(replacements: replacements, isExpanded: .constant(expanded))
                .frame(width: 580)).fittingSize.height
        }
        let collapsed = height([short], expanded: false)
        XCTAssertLessThan(collapsed, 44)
        XCTAssertEqual(height([long, short], expanded: false), collapsed, accuracy: 1)
        let expandedShort = height([short], expanded: true) - collapsed
        XCTAssertGreaterThan(expandedShort, 60)
        XCTAssertLessThan(expandedShort, 196)
        XCTAssertEqual(height([long, short], expanded: true) - collapsed, 244 + ZivviSpacing.dialogItemGap, accuracy: 1)

        let request = RuntimeInteraction(
            instanceID: StubSessionRuntime().instanceID, requestID: "edit-approval", kind: .confirm, title: "Edit fixture",
            toolApproval: .init(workingDirectory: "/fixture", operation: .edit(path: "file.swift", replacements: [long, short]))
        )
        let availableSize = CGSize(width: 860, height: 420)
        let sheet = NSHostingView(rootView: InteractionView(request: request, controller: SessionController(),
                                                             sessionTitle: "Fixture", availableSize: availableSize))
        XCTAssertEqual(sheet.fittingSize.width, 640, accuracy: 1)
        let expectedMaxHeight = min(floor(availableSize.height * 0.8), availableSize.height - 2 * ApprovalSheetLayout.inset)
        XCTAssertEqual(sheet.fittingSize.height, expectedMaxHeight, accuracy: 1)
    }

    func testApprovalIntentResolverPrefersSummariesAndAvoidsDuplicatingCommandOrPath() {
        let cmdWithSummary = ApprovalIntentResolver.resolve(
            category: .command,
            requestTitle: "find Zivvi Modules",
            toolTitle: "find Zivvi Modules",
            toolSummary: "查找图标和 Logo 资源",
            summary: nil,
            message: "",
            command: "find Zivvi Modules",
            filePaths: []
        )
        XCTAssertEqual(cmdWithSummary.primary, "查找图标和 Logo 资源")
        XCTAssertNil(cmdWithSummary.secondary)

        let cmdDuplicateFallback = ApprovalIntentResolver.resolve(
            category: .command,
            requestTitle: "find Zivvi Modules",
            toolTitle: nil,
            toolSummary: nil,
            summary: nil,
            message: "",
            command: "find   Zivvi\nModules",
            filePaths: []
        )
        XCTAssertEqual(cmdDuplicateFallback.primary, String(localized: "执行 Shell 命令"))

        let editDuplicateFallback = ApprovalIntentResolver.resolve(
            category: .edit,
            requestTitle: "修改 ACPEnvironmentKeychain.swift",
            toolTitle: "Edit zivvi/Zivvi/App/ACPEnvironmentKeychain.swift",
            toolSummary: nil,
            summary: nil,
            message: "",
            command: nil,
            filePaths: ["zivvi/Zivvi/App/ACPEnvironmentKeychain.swift"]
        )
        XCTAssertEqual(editDuplicateFallback.primary, String(localized: "修改文件"))

        let editDistinctTitle = ApprovalIntentResolver.resolve(
            category: .edit,
            requestTitle: "更新钥匙串服务标识",
            toolTitle: nil,
            toolSummary: nil,
            summary: nil,
            message: "",
            command: nil,
            filePaths: ["zivvi/Zivvi/App/ACPEnvironmentKeychain.swift"]
        )
        XCTAssertEqual(editDistinctTitle.primary, "更新钥匙串服务标识")
    }

    func testToolEditDiffComputesApprovalLinesInlineRangesAndUnifiedCopyText() {
        let oldLine = "let service = \"zivvi\""
        let newLine = "let service = \"ai.yuzio.zivvi\""
        let lines = ToolEditDiff.approvalLines(oldText: oldLine, newText: newLine)
        XCTAssertEqual(lines, [
            .init(kind: .removal, text: oldLine),
            .init(kind: .insertion, text: newLine),
        ])
        let ranges = ToolEditDiff.inlineChangedRanges(oldLine: oldLine, newLine: newLine)
        XCTAssertNil(ranges.oldRange)
        XCTAssertEqual(ranges.newRange.map { String(newLine[$0]) }, "ai.yuzio.")

        let twoSided = ToolEditDiff.inlineChangedRanges(oldLine: "let mode = .fast", newLine: "let mode = .accurate")
        XCTAssertEqual(twoSided.oldRange.map { String("let mode = .fast"[$0]) }, "fast")
        XCTAssertEqual(twoSided.newRange.map { String("let mode = .accurate"[$0]) }, "accurate")

        let replaced = ToolEditDiff.inlineChangedRanges(oldLine: "foo", newLine: "bar")
        XCTAssertNil(replaced.oldRange)
        XCTAssertNil(replaced.newRange)

        let newFileLines = ToolEditDiff.approvalLines(oldText: nil, newText: "line1\nline2")
        XCTAssertEqual(newFileLines, [
            .init(kind: .insertion, text: "line1"),
            .init(kind: .insertion, text: "line2"),
        ])
        XCTAssertEqual(ToolEditDiff.unifiedText(for: lines), "- \(oldLine)\n+ \(newLine)")

        // Verify prefix/suffix trimming and hunk context collapsing on a large multi-thousand-line file.
        let prefixLines = (0..<1_500).map { "let unchangedPrefix\($0) = \($0)" }
        let suffixLines = (0..<1_500).map { "let unchangedSuffix\($0) = \($0)" }
        let largeOld = (prefixLines + ["let edited = 1"] + suffixLines).joined(separator: "\n")
        let largeNew = (prefixLines + ["let edited = 2"] + suffixLines).joined(separator: "\n")
        let largeDiffLines = ToolEditDiff.approvalLines(oldText: largeOld, newText: largeNew)
        XCTAssertEqual(largeDiffLines.count, 3_002)
        XCTAssertEqual(largeDiffLines.filter { $0.kind != .context }.count, 2)
        let segments = ToolEditDiff.approvalSegments(from: largeDiffLines)
        XCTAssertEqual(segments.count, 3)
        if case .collapsedContext(let before) = segments[0].content {
            XCTAssertEqual(before.count, 1_497)
        } else {
            XCTFail("Expected collapsed leading context")
        }
        if case .lines(let hunk) = segments[1].content {
            XCTAssertEqual(hunk.count, 8) // 3 context + 1 removal + 1 insertion + 3 context
        } else {
            XCTFail("Expected active diff hunk")
        }
        if case .collapsedContext(let after) = segments[2].content {
            XCTAssertEqual(after.count, 1_497)
        } else {
            XCTFail("Expected collapsed trailing context")
        }
    }

    @MainActor func testUnifiedApprovalSheetsRenderCommandAndEditModesInLightAndDark() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let diffCard = ApprovalUnifiedDiffCard(
            changes: [.init(path: "Zivvi/App/ACPEnvironmentKeychain.swift",
                            oldText: "let service = \"zivvi\"\n",
                            newText: "let service = \"ai.yuzio.zivvi\"\n")],
            pasteboard: pasteboard
        ).frame(width: 560)
        let diffHost = NSHostingView(rootView: diffCard)
        let diffWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        diffWindow.contentView = diffHost
        diffWindow.makeKeyAndOrderFront(nil)
        defer { diffWindow.orderOut(nil); diffWindow.contentView = nil }
        await settleWindow(diffWindow)
        let diffTexts = (try recognizedTexts(in: diffHost)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(diffTexts.contains("Diff"), "Expected Diff header in: \(diffTexts)")
        XCTAssertTrue(diffTexts.contains("+1") && diffTexts.contains("1"), "Expected diff stats in: \(diffTexts)")
        let diffHeader = try XCTUnwrap(try recognizedTexts(in: diffHost, matching: "Diff").first)
        try clickApproval(in: diffHost, x: diffHost.bounds.width - ZivviSpacing.contentInset - 12,
                          fromTop: (1 - diffHeader.box.midY) * diffHost.bounds.height)
        await settleWindow(diffWindow)
        let copiedDiff = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copiedDiff.contains("- let service = \"zivvi\""))
        XCTAssertTrue(copiedDiff.contains("+ let service = \"ai.yuzio.zivvi\""))

        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Edit keychain"))

        let acpEdit = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "acp-edit-unified",
            kind: .select,
            title: "修改 ACPEnvironmentKeychain.swift",
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce),
            ],
            permissionContext: .init(
                toolCallID: "call-1",
                toolTitle: "修改 ACPEnvironmentKeychain.swift",
                toolName: "edit_file",
                toolKind: "edit",
                workingDirectory: "/work/zivvi",
                sessionDirectory: "/work/zivvi",
                paths: ["/work/zivvi/Zivvi/App/ACPEnvironmentKeychain.swift"],
                toolSummary: "更新 ACP 环境变量的钥匙串服务标识",
                rawInputJSON: "{\n  \"Path\": \"/work/zivvi/Zivvi/App/ACPEnvironmentKeychain.swift\"\n}",
                diffs: [.init(path: "/work/zivvi/Zivvi/App/ACPEnvironmentKeychain.swift",
                              oldText: "let service = \"zivvi\"",
                              newText: "let service = \"ai.yuzio.zivvi\"")]
            )
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(acpEdit)))
        let editHost = NSHostingView(rootView: InteractionView(
            request: acpEdit, controller: controller, sessionTitle: "Zivvi",
            availableSize: CGSize(width: 900, height: 700), projectDirectory: "/work/zivvi"
        ).background(ZivviTheme.pageBackground))
        let editWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 340),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        editWindow.appearance = NSAppearance(named: .aqua)
        editWindow.contentView = editHost
        editWindow.makeKeyAndOrderFront(nil)
        defer { editWindow.orderOut(nil); editWindow.contentView = nil }
        await settleWindow(editWindow)
        let lightRendered = (try recognizedTexts(in: editHost)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(lightRendered.contains("修改文件"))
        XCTAssertTrue(lightRendered.contains("更新 ACP 环境变量的钥匙串服务标识"))
        XCTAssertTrue(lightRendered.contains("ACPEnvironmentKeychain.swift"))
        XCTAssertTrue(lightRendered.contains("允许本次"))
        XCTAssertTrue(lightRendered.contains("拒绝"))
        XCTAssertTrue(lightRendered.contains("技术详情"))
        addWindowScreenshot(of: editHost, name: "Unified edit approval · light")
        editWindow.appearance = NSAppearance(named: .darkAqua)
        await settleWindow(editWindow)
        addWindowScreenshot(of: editHost, name: "Unified edit approval · dark")
        _ = await controller.disconnect()
    }

    @MainActor func testApprovalDiffShowsEndingsForEOFNewlineChanges() {
        typealias Ending = ToolEditDiff.Ending
        func change(_ old: String?, _ new: String) -> RuntimePermissionContext.FileDiff {
            .init(path: "/fixture/file", oldText: old, newText: new)
        }
        let added = ApprovalDiffLines.changedEndings(for: change("a", "a\n"))
        XCTAssertEqual(added.old, Ending.none)
        XCTAssertEqual(added.new, .lf)
        let removed = ApprovalDiffLines.changedEndings(for: change("a\n", "a"))
        XCTAssertEqual(removed.old, .lf)
        XCTAssertEqual(removed.new, Ending.none)
        let styleChanged = ApprovalDiffLines.changedEndings(for: change("a\r\n", "a\n"))
        XCTAssertEqual(styleChanged.old, .crlf)
        XCTAssertEqual(styleChanged.new, .lf)
        let previousEmpty = ApprovalDiffLines.changedEndings(for: change("", "\n"))
        XCTAssertEqual(previousEmpty.old, Ending.none)
        XCTAssertEqual(previousEmpty.new, .lf)
        let newFile = ApprovalDiffLines.changedEndings(for: change(nil, "a\n"))
        XCTAssertNil(newFile.old)
        XCTAssertNil(newFile.new)
        XCTAssertNil(ApprovalDiffLines.changedEndings(for: change("a\n", "b\n")).new)
        let emptyRow = ApprovalDiffLines(text: "", isAddition: false, ending: previousEmpty.old)
        XCTAssertEqual(String(emptyRow.markedText("− ", color: .red).characters), "−  [\(Ending.none.label)]")
        let addedRow = ApprovalDiffLines(text: "a\n", isAddition: true, ending: added.new)
        XCTAssertEqual(String(addedRow.markedText("+ ", color: .green).characters), "+ a [LF]")
    }

    @MainActor func testApprovalHeaderSummariesPreserveStandardContentAndDeduplicate() {
        func summaries(_ standard: String?, _ raw: String?, fallback: String = "", kind: String? = "execute",
                       diffs: [RuntimePermissionContext.FileDiff] = []) -> [String] {
            let details = ActiveApprovalDetails(approval: nil, context: .init(toolTitle: "Tool title", toolKind: kind,
                                                                             summary: standard, toolSummary: raw, diffs: diffs),
                                                message: fallback, projectDirectory: nil, wrapsPreviewLines: .constant(true))
            return details.headerSummaries(excluding: "Request title", fallback: fallback)
        }
        XCTAssertEqual(summaries("Standard ACP summary", nil), ["Standard ACP summary"])
        XCTAssertEqual(summaries("Same", "Same  "), ["Same  "])
        XCTAssertEqual(summaries("Standard", "Raw"), ["Raw", "Standard"])
        XCTAssertEqual(summaries("Tool title", "Raw"), ["Raw"])
        XCTAssertTrue(summaries("Tool title", "Request title").isEmpty)
        XCTAssertEqual(summaries(nil, nil, fallback: "Message"), ["Message"])
        XCTAssertEqual(summaries("  ", nil, fallback: "Message"), ["Message"])
        XCTAssertEqual(summaries("Edit summary", "Raw edit summary", kind: "edit"), ["Raw edit summary", "Edit summary"])
        XCTAssertTrue(summaries(nil, "\n", kind: "edit").isEmpty)
        XCTAssertEqual(summaries("Diff summary", nil, kind: nil,
                                 diffs: [.init(path: "Example.swift", oldText: nil, newText: "let n = 1")]), ["Diff summary"])
        XCTAssertTrue(summaries("Generic permission explanation", nil, kind: "read").isEmpty)
    }

    @MainActor func testApprovalWidthUsesPrimaryContentAndRestoresThePreferredTier() {
        let standard = ZivviTypography()
        func width(_ command: String, typography: ZivviTypography = .init()) -> CGFloat? {
            ApprovalSheetLayout.preferredWidth(for: .command(text: command, timeoutSeconds: nil), typography: typography)
        }
        XCTAssertEqual(width("printf fixture"), 640)
        XCTAssertEqual(width(Array(repeating: "printf fixture", count: 12).joined(separator: "\n")), 640)
        XCTAssertEqual(width(String(repeating: "x", count: 200)), 700)
        XCTAssertEqual(width(String(repeating: "foo ", count: 28)), 640)
        XCTAssertEqual(width(String(repeating: "foo ", count: 40), typography: .init(size: .extraLarge)), 700)
        XCTAssertEqual(ApprovalSheetLayout.preferredWidth(for: .edit(path: "file.swift", replacements: []), typography: standard), 640)
        XCTAssertEqual(ApprovalSheetLayout.preferredWidth(for: .edit(path: String(repeating: "dir/", count: 30) + "file.swift",
                                                                      replacements: []), typography: standard), 700)
        XCTAssertNil(ApprovalSheetLayout.preferredWidth(for: .write(path: "file.swift", content: ""), typography: standard))
        XCTAssertNil(ApprovalSheetLayout.preferredWidth(for: .inspect(.read, arguments: []), typography: standard))
        XCTAssertEqual(ApprovalSheetLayout.width(preferred: 700, available: 640), 592)
        XCTAssertEqual(ApprovalSheetLayout.width(preferred: 700, available: 860), 700)
    }

    @MainActor func testUnwrappedCommandPreviewFitsAnEntireLine() {
        let typography = ZivviTypography(size: .extraLarge)
        func size(_ command: String) -> CGSize {
            NSHostingView(rootView: CommandApprovalPreview(command: command, wrapsLines: .constant(false))
                .frame(width: 440).zivviTypography(.extraLarge)).fittingSize
        }

        let short = size("printf x")
        let long = size("printf " + String(repeating: "x", count: 220))
        let multiline = size("printf x\nprintf y")
        let minimumHeight = ApprovalSheetLayout.previewLineHeight(typography: typography)
            + IconButtonLabel.side + ZivviSpacing.dialogItemGap + 2 * ZivviSpacing.contentInset
        XCTAssertEqual(long.width, 440, accuracy: 1)
        XCTAssertGreaterThanOrEqual(long.height, minimumHeight - 1)
        XCTAssertEqual(long.height, short.height, accuracy: 1)
        XCTAssertGreaterThan(multiline.height, long.height)
    }

    @MainActor func testCommandPreviewWrapsAcrossFullWidth() async throws {
        let command = "printf " + String(repeating: "x", count: 200)
        struct Preview: View {
            let command: String
            @State private var wrapsLines = true

            var body: some View {
                CommandApprovalPreview(command: command, wrapsLines: $wrapsLines)
                    .frame(width: 592)
                    .zivviTypography(.extraLarge)
            }
        }
        let host = NSHostingView(rootView: Preview(command: command))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)

        let scroll = try XCTUnwrap(approvalScrollViews(in: host).first)
        XCTAssertEqual(scroll.contentView.bounds.width, 592 - 2 * ZivviSpacing.contentInset, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentView.bounds.width + 1)
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        let wrapButtonX = scrollFrame.maxX - 1.5 * IconButtonLabel.side - 4
        let headerCenter = approvalTop(of: scroll, in: host) - ZivviSpacing.dialogItemGap - IconButtonLabel.side / 2
        try clickApproval(in: host, x: wrapButtonX, fromTop: headerCenter)
        await settleWindow(window)

        let unwrappedScroll = try XCTUnwrap(approvalScrollViews(in: host).first)
        let lineHeight = ApprovalSheetLayout.previewLineHeight(typography: .init(size: .extraLarge))
        XCTAssertGreaterThanOrEqual(unwrappedScroll.contentView.bounds.height, lineHeight - 1)
        XCTAssertTrue(unwrappedScroll.horizontalScroller?.isHidden ?? true)
        XCTAssertTrue(unwrappedScroll.verticalScroller?.isHidden ?? true)
        let overflow = try XCTUnwrap(unwrappedScroll.documentView).frame.width - unwrappedScroll.contentView.bounds.width
        XCTAssertGreaterThan(overflow, 100)
        unwrappedScroll.contentView.scroll(to: NSPoint(x: overflow, y: 0))
        XCTAssertEqual(unwrappedScroll.contentView.bounds.minX, overflow, accuracy: 1)

        let unwrappedHeaderCenter = approvalTop(of: unwrappedScroll, in: host) - ZivviSpacing.dialogItemGap - IconButtonLabel.side / 2
        try clickApproval(in: host, x: wrapButtonX, fromTop: unwrappedHeaderCenter)
        await settleWindow(window)
        let rewrappedScroll = try XCTUnwrap(approvalScrollViews(in: host).first)
        XCTAssertEqual(rewrappedScroll.contentView.bounds.minX, 0, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rewrappedScroll.documentView).frame.width, rewrappedScroll.contentView.bounds.width + 1)
    }

    @MainActor func testApprovalCopySitsAboveScrollableFullWidthText() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "Start\r\n" + String(repeating: "  长行 approval details\n", count: 35) + "End\n"
        let host = NSHostingView(rootView: ApprovalCodePreview(
            text: text, title: "写入内容", icon: "doc.text", copyLabel: "复制写入内容", identifier: "file-approval",
            wrapsLines: .constant(true), pasteboard: pasteboard
        ).frame(width: 440))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let scroll = try XCTUnwrap(approvalScrollViews(in: host).first)
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        XCTAssertEqual(scroll.contentView.bounds.width, 440 - 2 * ZivviSpacing.contentInset, accuracy: 1)
        XCTAssertTrue(scroll.verticalScroller?.isHidden ?? true)
        let overflow = try XCTUnwrap(scroll.documentView).frame.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(overflow, 100)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow))
        XCTAssertEqual(scroll.contentView.bounds.minY, overflow, accuracy: 1)

        // The copy button must be clickable above the preview and aligned to its right edge.
        let withCopyHeight = host.fittingSize.height
        try clickApproval(in: host, x: scrollFrame.maxX - 12, fromTop: approvalTop(of: scroll, in: host) - 20)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(Array(copied.utf8), Array(text.utf8))

        let summaryHost = NSHostingView(rootView: ApprovalTextPreview(text: text, identifier: "permission-summary").frame(width: 440))
        XCTAssertLessThan(summaryHost.fittingSize.height, withCopyHeight)
    }

    @MainActor func testLargeApprovalDiffAndCommandPreviewsRenderAndCopyFullContent() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        // Large command (> 100 KiB) renders via native scroll view with full copy preserved.
        let largeCommand = Array(repeating: "echo 'approval line payload'", count: 5_000).joined(separator: "\n")
        let commandHost = NSHostingView(rootView: ApprovalCodePreview(
            text: largeCommand, title: "Shell", icon: "terminal", copyLabel: "复制命令",
            identifier: "command-approval", wrapsLines: .constant(true), pasteboard: pasteboard
        ).frame(width: 560))
        let commandWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        commandWindow.contentView = commandHost
        commandWindow.makeKeyAndOrderFront(nil)
        defer { commandWindow.orderOut(nil); commandWindow.contentView = nil }
        await settleWindow(commandWindow)

        let commandScroll = try XCTUnwrap(approvalScrollViews(in: commandHost).first)
        XCTAssertTrue(commandScroll is ApprovalScrollView)
        let commandOverflow = try XCTUnwrap(commandScroll.documentView).frame.height - commandScroll.contentView.bounds.height
        XCTAssertGreaterThan(commandOverflow, 100)
        let commandFrame = commandScroll.convert(commandScroll.bounds, to: commandHost)
        try clickApproval(in: commandHost, x: commandFrame.maxX - 12, fromTop: approvalTop(of: commandScroll, in: commandHost) - 20)
        XCTAssertEqual(pasteboard.string(forType: .string), largeCommand)

        // Non-contiguous layout (> 512 KiB) preserves full-document scroll bounds instead of clamping to 32K chars.
        let hugeCommand = Array(repeating: "echo 'non-contiguous approval line payload'", count: 16_000).joined(separator: "\n")
        let hugeHost = NSHostingView(rootView: ApprovalCodePreview(
            text: hugeCommand, title: "Shell", icon: "terminal", copyLabel: "复制命令",
            identifier: "command-approval", wrapsLines: .constant(true), pasteboard: pasteboard
        ).frame(width: 560))
        let hugeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        hugeWindow.contentView = hugeHost
        hugeWindow.makeKeyAndOrderFront(nil)
        defer { hugeWindow.orderOut(nil); hugeWindow.contentView = nil }
        await settleWindow(hugeWindow)
        let hugeScroll = try XCTUnwrap(approvalScrollViews(in: hugeHost).first)
        XCTAssertTrue(hugeScroll is ApprovalScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(hugeScroll.documentView).frame.height, 10_000)

        // Large new-file diff (> 600 lines) switches cleanly to native attributed scroll view and handles appearance switches.
        let largeNewFile = (0..<700).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let largeDiffHost = NSHostingView(rootView: ApprovalUnifiedDiffCard(
            changes: [.init(path: "LargeNewFile.swift", oldText: nil, newText: largeNewFile)],
            pasteboard: pasteboard
        ).frame(width: 560))
        let diffWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        diffWindow.appearance = NSAppearance(named: .aqua)
        diffWindow.contentView = largeDiffHost
        diffWindow.makeKeyAndOrderFront(nil)
        defer { diffWindow.orderOut(nil); diffWindow.contentView = nil }
        await settleWindow(diffWindow)

        let diffScroll = try XCTUnwrap(approvalScrollViews(in: largeDiffHost).first)
        XCTAssertTrue(diffScroll is ApprovalScrollView)
        diffScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        diffWindow.appearance = NSAppearance(named: .darkAqua)
        await settleWindow(diffWindow)
        XCTAssertEqual(diffScroll.contentView.bounds.minY, 120, accuracy: 2)
        let diffTexts = (try recognizedTexts(in: largeDiffHost)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(diffTexts.contains("+700"), "Expected +700 stats in: \(diffTexts)")

        // Pressing Esc while ApprovalScrollView's NSTextView is firstResponder still cancels/dismisses the sheet.
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let sessionID = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(sessionID)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: sessionID))
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        hostWindow.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak hostWindow] in hostWindow?.attachedSheet == nil }
        ))
        hostWindow.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = hostWindow.attachedSheet { hostWindow.endSheet(sheet) }
            hostWindow.orderOut(nil)
            hostWindow.contentView = nil
        }
        await settleWindow(hostWindow)

        let escRequest = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "large-cmd-esc",
            kind: .confirm,
            title: "Run large command",
            toolApproval: .init(workingDirectory: "/fixture", operation: .command(text: largeCommand, timeoutSeconds: nil))
        )
        runtime.emit(.interaction(escRequest))
        let sheet = try await awaitApprovalSheet(in: hostWindow)
        let sheetContent = try XCTUnwrap(sheet.contentView)
        let sheetScroll = try XCTUnwrap(approvalScrollViews(in: sheetContent).first { $0 is ApprovalScrollView })
        let sheetTextView = try XCTUnwrap(sheetScroll.documentView)
        XCTAssertTrue(sheet.makeFirstResponder(sheetTextView))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(escape)
        try await awaitApprovalSheetDismissal(in: hostWindow)
        XCTAssertTrue(controller.interactions.isEmpty)
        XCTAssertEqual(runtime.recordedInteractionReplies, [.confirmed(false)])
        _ = await workspace.disconnect(sessionID)
    }

    @MainActor func testAdaptiveApprovalSheetsThroughWorkbench() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        func present(_ operation: RuntimeToolApproval.Operation, id: String) async throws -> (RuntimeInteraction, NSWindow) {
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: id, kind: .confirm,
                                             title: "Approval fixture",
                                             toolApproval: .init(workingDirectory: "/fixture/zivvi", operation: operation))
            runtime.emit(.interaction(request))
            let sheet = try await awaitApprovalSheet(in: window)
            XCTAssertEqual(controller.interactions, [request])
            return (request, sheet)
        }

        let command = "printf 'first line'\nprintf " + String(repeating: "x", count: 250) + "\nprintf 'last line'"
        let (commandRequest, commandSheet) = try await present(.command(text: command, timeoutSeconds: 10), id: "long-command")
        XCTAssertEqual(commandSheet.frame.width, 700, accuracy: 1)
        let commandContent = try XCTUnwrap(commandSheet.contentView)
        let wrappedScroll = try XCTUnwrap(approvalScrollViews(in: commandContent).first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wrappedScroll.documentView).frame.width,
                                 wrappedScroll.contentView.bounds.width + 1)
        addWindowScreenshot(of: commandContent, name: "Command approval · light")

        window.setContentSize(CGSize(width: 720, height: 620))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === commandSheet)
        XCTAssertEqual(commandSheet.frame.width, 672, accuracy: 1)
        window.setContentSize(CGSize(width: 1120, height: 760))
        await settleWindow(window)
        XCTAssertEqual(commandSheet.frame.width, 700, accuracy: 1)

        runtime.emit(.interactionEnded(commandRequest.id, .expired))
        for _ in 0..<25 where !controller.didExpire(commandRequest) {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        await settleWindow(commandSheet)
        XCTAssertTrue(controller.didExpire(commandRequest))
        XCTAssertTrue(window.attachedSheet === commandSheet)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: commandSheet.windowNumber, context: nil, characters: "\u{1B}",
                                                  charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        commandSheet.sendEvent(escape)
        try await awaitApprovalSheetDismissal(in: window)

        let path = String(repeating: "long-directory/", count: 12) + "Target.swift"
        let old = Array(repeating: "let n = 1", count: 40).joined(separator: "\n")
        let replacements = try JSONDecoder().decode([RuntimeToolApproval.Replacement].self, from: JSONSerialization.data(withJSONObject: [
            ["oldText": old, "newText": "let n = 2"],
            ["oldText": "let m = 1", "newText": "let m = 2"]
        ]))
        let (editRequest, editSheet) = try await present(.edit(path: path, replacements: replacements), id: "long-edit")
        editSheet.appearance = NSAppearance(named: .darkAqua)
        await settleWindow(editSheet)
        let editContent = try XCTUnwrap(editSheet.contentView)
        XCTAssertEqual(editSheet.frame.width, 700, accuracy: 1)
        XCTAssertLessThan(editSheet.frame.height, window.frame.height)
        let editPathText = (try recognizedTexts(in: editContent)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(editPathText.contains("Target.swift"), "Expected wrapped target filename in: \(editPathText)")
        XCTAssertTrue(editPathText.contains("long-directory"), "Expected wrapped directory path in: \(editPathText)")
        let diff = try XCTUnwrap(approvalScrollViews(in: editContent).first {
            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100
        })
        let diffOverflow = try XCTUnwrap(diff.documentView).frame.height - diff.contentView.bounds.height
        XCTAssertTrue(diff.verticalScroller?.isHidden ?? true)
        diff.contentView.scroll(to: NSPoint(x: 0, y: diffOverflow))
        XCTAssertEqual(diff.contentView.bounds.minY, diffOverflow, accuracy: 1)
        addWindowScreenshot(of: editContent, name: "Edit approval · dark")
        runtime.emit(.interactionEnded(editRequest.id, .cancelled))
        try await awaitApprovalSheetDismissal(in: window)
        _ = await workspace.disconnect(id)
    }

    @MainActor func testLargeDiffAppearanceChangeUpdatesColorsAndTogglingDetailsPreservesScrollAndSelection() async throws {
        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Edit large file"))

        let oldLines = (1...450).map { "let line\($0) = \($0)" }
        var newLines = oldLines
        for index in stride(from: 0, to: 450, by: 25) {
            newLines[index] = "let line\(index + 1) = \(index + 1000)"
        }
        let diff = RuntimePermissionContext.FileDiff(
            path: "Sources/LargeDiffFixture.swift",
            oldText: oldLines.joined(separator: "\n"),
            newText: newLines.joined(separator: "\n")
        )
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "large-diff-appearance-scroll",
            kind: .confirm,
            title: "Edit large file",
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce)
            ],
            permissionContext: .init(
                toolTitle: "Edit Sources/LargeDiffFixture.swift",
                toolName: "edit_file",
                toolKind: "edit",
                workingDirectory: "/fixture",
                rawInputJSON: "{\"RawFixture\": \"/fixture/large-diff\"}",
                diffs: [diff]
            )
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(
            rootView: InteractionView(request: request, controller: controller, sessionTitle: "Fixture")
                .background(ZivviTheme.pageBackground)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let diffScroll = try XCTUnwrap(approvalScrollViews(in: host).first { $0 is ApprovalScrollView })
        let textView = try XCTUnwrap(diffScroll.documentView as? NSTextView)
        let lightSample = try pixelColor(in: host, at: NSPoint(x: 40, y: 40))

        window.appearance = NSAppearance(named: .darkAqua)
        await settleWindow(window)
        let darkSample = try pixelColor(in: host, at: NSPoint(x: 40, y: 40))
        let colorDistance = abs(lightSample.redComponent - darkSample.redComponent)
            + abs(lightSample.greenComponent - darkSample.greenComponent)
            + abs(lightSample.blueComponent - darkSample.blueComponent)
        XCTAssertGreaterThan(colorDistance, 0.2, "Expected rendered diff surface to adapt between Light and Dark appearance")

        let maxScroll = max(0, textView.frame.height - diffScroll.contentView.bounds.height)
        XCTAssertGreaterThan(maxScroll, 100)
        diffScroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        await settleWindow(window)

        let texts = try recognizedTexts(in: host)
        let details = try XCTUnwrap(texts.first { $0.text.contains("技术详情") })
        let fromTop = (1 - details.box.midY) * host.bounds.height
        try clickApproval(in: host, x: details.box.midX * host.bounds.width, fromTop: fromTop)
        try await Task.sleep(for: .milliseconds(250))
        await settleWindow(window)

        XCTAssertEqual(diffScroll.contentView.bounds.minY, 80, accuracy: 2)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 6))
        _ = await controller.disconnect()
    }

    @MainActor func testApprovalKeyboardShortcutsReturnDoesNotAllowAndEscapeDismisses() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "multi-option-shortcuts",
            kind: .confirm,
            title: "Run shortcut command",
            expiresAt: Date().addingTimeInterval(20),
            createdAt: Date().addingTimeInterval(-10),
            toolApproval: .init(workingDirectory: "/fixture/zivvi", operation: .command(text: "echo shortcut", timeoutSeconds: 30)),
            permissionOptions: [
                .init(id: "allow-alt", name: "Allow alt", kind: .allowOnce),
                .init(id: "allow-once", name: "Allow once", kind: .allowOnce),
                .init(id: "reject-once", name: "Reject once", kind: .rejectOnce)
            ]
        )
        runtime.emit(.interaction(request))
        let sheet = try await awaitApprovalSheet(in: window)
        let content = try XCTUnwrap(sheet.contentView)
        let rendered = (try recognizedTexts(in: content)).map(\.text).joined(separator: "\n")
        XCTAssertNotNil(rendered.range(of: #"\b00:[0-2]\d\b"#, options: .regularExpression),
                        "Expected the urgent countdown in: \(rendered)")

        sheet.makeKey()
        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        NSApp.sendEvent(returnEvent)
        try await Task.sleep(for: .milliseconds(50))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(controller.interactions, [request])
        XCTAssertTrue(runtime.recordedInteractionReplies.isEmpty)

        let escapeEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(escapeEvent)
        try await awaitApprovalSheetDismissal(in: window)
        XCTAssertTrue(controller.interactions.isEmpty)
        XCTAssertEqual(runtime.recordedInteractionReplies, [.permissionOption("reject-once")])
        _ = await workspace.disconnect(id)
    }

    @MainActor func testExpiredApprovalTechnicalDetailsShowsOptionsRowAndLocalizedCloseButton() async throws {
        if let enPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let enBundle = Bundle(path: enPath) {
            XCTAssertEqual(enBundle.localizedString(forKey: "dialog.close", value: nil, table: nil), "Close")
        }

        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let id = try XCTUnwrap(workspace.selected?.id)
        let connected = await workspace.activate(id)
        XCTAssertTrue(connected)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all),
            canAutomaticallyPresentInteraction: { [weak window] in window?.attachedSheet == nil }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)

        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "expired-options-row",
            kind: .confirm,
            title: "Run expired command",
            toolApproval: .init(workingDirectory: "/fixture/zivvi", operation: .command(text: "echo expired", timeoutSeconds: 5)),
            permissionOptions: [
                .init(id: "allow", name: "Allow once", kind: .allowOnce),
                .init(id: "reject", name: "Reject once", kind: .rejectOnce)
            ],
            permissionContext: .init(
                toolTitle: "Run expired command",
                toolName: "bash",
                toolKind: "execute",
                workingDirectory: "/fixture/zivvi",
                rawInputJSON: "{\"RawFixture\": \"expired\"}"
            )
        )
        runtime.emit(.interaction(request))
        let sheet = try await awaitApprovalSheet(in: window)
        runtime.emit(.interactionEnded(request.id, .expired))
        for _ in 0..<25 where !controller.didExpire(request) {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        await settleWindow(sheet)
        XCTAssertTrue(controller.didExpire(request))

        let content = try XCTUnwrap(sheet.contentView)
        let collapsedTexts = try recognizedTexts(in: content)
        let details = try XCTUnwrap(collapsedTexts.first { $0.text.contains("技术详情") })
        let fromTop = (1 - details.box.midY) * content.bounds.height
        try clickApproval(in: content, x: details.box.midX * content.bounds.width, fromTop: fromTop)
        try await Task.sleep(for: .milliseconds(250))
        await settleWindow(sheet)

        let expandedTexts = try recognizedTexts(in: content)
        let joined = expandedTexts.map(\.text).joined(separator: "\n")
        XCTAssertTrue(joined.contains("已超时"), "Expected timeout status in: \(joined)")
        XCTAssertTrue(joined.contains("关闭"), "Expected localized close button in: \(joined)")
        let optionsLabel = try XCTUnwrap(expandedTexts.first { $0.text.contains("选项") }, "Expected 选项 row in: \(joined)")
        let optionValue = try XCTUnwrap(
            expandedTexts.first { $0.text.contains("Allow once") || $0.text.contains("允许本次") },
            "Expected expired option names in: \(joined)"
        )
        XCTAssertLessThan(abs(optionsLabel.box.midY - optionValue.box.midY), 0.08)
        _ = await workspace.disconnect(id)
    }

    @MainActor func testMultiFileEditApprovalAndInteractiveContextExpansion() async throws {
        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Edit multiple files"))

        let oldFirst = (0..<40).map { "context line \($0)" }
        var newFirst = oldFirst
        newFirst[0] = "updated first line"
        newFirst[39] = "updated last line"
        let firstDiff = RuntimePermissionContext.FileDiff(
            path: "Sources/First.swift",
            oldText: oldFirst.joined(separator: "\n"),
            newText: newFirst.joined(separator: "\n")
        )
        let secondDiff = RuntimePermissionContext.FileDiff(
            path: "Sources/Second.swift",
            oldText: "let second = 1",
            newText: "let second = 2"
        )
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "multi-file-context-expansion",
            kind: .confirm,
            title: "Modify Files",
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce)
            ],
            permissionContext: .init(
                toolTitle: "Modify Files",
                toolKind: "edit",
                workingDirectory: "/fixture",
                diffs: [firstDiff, secondDiff]
            )
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(
            rootView: InteractionView(request: request, controller: controller, sessionTitle: "Fixture")
                .background(ZivviTheme.pageBackground)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let initialTexts = try recognizedTexts(in: host)
        let initialJoined = initialTexts.map(\.text).joined(separator: "\n")
        let paths = selectableApprovalTexts(in: host)
        XCTAssertTrue(paths.contains("First.swift"), "Expected First.swift in: \(paths)")
        XCTAssertTrue(paths.contains("Second.swift"), "Expected Second.swift in: \(paths)")
        XCTAssertFalse(initialJoined.contains("context line 20"), "Expected middle context collapsed initially in: \(initialJoined)")

        let expandButton = try XCTUnwrap(
            try recognizedTexts(in: host, matching: "展开上下文").first,
            "Expected context expand control in: \(initialJoined)"
        )
        let fromTop = (1 - expandButton.box.midY) * host.bounds.height
        try clickApproval(in: host, x: expandButton.box.midX * host.bounds.width, fromTop: fromTop)
        try await Task.sleep(for: .milliseconds(250))
        await settleWindow(window)

        let expanded = selectableApprovalTexts(in: host)
        XCTAssertTrue(expanded.contains { $0.contains("context line 20") },
                      "Expected expanded middle context in: \(expanded)")
        XCTAssertFalse(try recognizedTexts(in: host, matching: "收起上下文").isEmpty)
        _ = await controller.disconnect()
    }

    @MainActor private func awaitApprovalSheet(in window: NSWindow) async throws -> NSWindow {
        for _ in 0..<25 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        await settleWindow(sheet)
        return sheet
    }

    @MainActor private func awaitApprovalSheetDismissal(in window: NSWindow) async throws {
        for _ in 0..<25 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor private func settleApprovalResize(_ sheet: NSWindow, from previousHeight: CGFloat) async throws {
        for _ in 0..<25 where sheet.frame.height == previousHeight {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(sheet)
        }
        await settleWindow(sheet)
    }

    @MainActor private func addWindowScreenshot(of view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func approvalScrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { approvalScrollViews(in: $0) }
    }

    @MainActor private func approvalTop(of view: NSView, in root: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: root)
        return root.isFlipped ? rect.minY - root.bounds.minY : root.bounds.maxY - rect.maxY
    }

    @MainActor private func clickApproval(in view: NSView, x: CGFloat, fromTop: CGFloat) throws {
        let window = try XCTUnwrap(view.window)
        let y = view.isFlipped ? view.bounds.minY + fromTop : view.bounds.maxY - fromTop
        let location = view.convert(NSPoint(x: x, y: y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    @MainActor func testInteractionViewsDoNotCaptureTheWorkbenchStopShortcut() async throws {
        var controlInvoked = false
        let control = Button("Shortcut control") { controlInvoked = true }
            .keyboardShortcut(".", modifiers: .command)
        let host = NSHostingView(rootView: AnyView(control))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settleWindow(window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                   characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47))
        XCTAssertTrue(host.performKeyEquivalent(with: event))
        XCTAssertTrue(controlInvoked)

        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Background session"))
        let toolApproval = RuntimeToolApproval(workingDirectory: "/tmp", operation: .write(path: "/tmp/fixture.txt", content: "fixture"))
        for (index, approval) in [nil, toolApproval].enumerated() {
            let request = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "\(index)", kind: .confirm,
                                             title: "Background request", toolApproval: approval)
            controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))
            XCTAssertTrue(controller.canStop)
            host.rootView = AnyView(InteractionView(request: request, controller: controller, sessionTitle: "A"))
            await settleWindow(window)
            XCTAssertFalse(host.performKeyEquivalent(with: event))
            XCTAssertTrue(controller.interactions.contains(request))
        }
        _ = await controller.disconnect()
    }

    @MainActor func testSettingsSheetGrowsAndShrinksWithWorkbench() async throws {
        let workspace = await newConversationWorkspace()
        let settings = AppSettings()
        func root(openRequest: Int) -> WorkbenchView {
            WorkbenchView(workspace: workspace, settings: settings, quitRequest: 0, openSettingsRequest: openRequest,
                          terminate: { _, cancel in cancel() }, sidebarVisibility: .constant(.all))
        }
        let host = NSHostingView(rootView: root(openRequest: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentView = nil
        }
        await settleWindow(window)
        host.rootView = root(openRequest: 1)
        for _ in 0..<30 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
            await settleWindow(window)
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        await settleWindow(window)
        let compact = sheet.frame.size
        XCTAssertLessThan(compact.width, window.frame.width)
        XCTAssertLessThan(compact.height, window.frame.height)

        window.setContentSize(CGSize(width: 1120, height: 760))
        await settleWindow(window)
        let expanded = sheet.frame.size
        XCTAssertGreaterThan(expanded.width, compact.width + 100)
        XCTAssertGreaterThan(expanded.height, compact.height + 75)
        XCTAssertLessThan(expanded.width, window.frame.width)
        XCTAssertLessThan(expanded.height, window.frame.height)

        window.setContentSize(CGSize(width: 860, height: 620))
        await settleWindow(window)
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(sheet.frame.width, compact.width, accuracy: 1)
        XCTAssertEqual(sheet.frame.height, compact.height, accuracy: 1)
    }


    @MainActor func testSettingsPanelLargeWindowCapsAndReadingColumn() async throws {
        let workspace = await newConversationWorkspace()
        let settings = AppSettings()

        XCTAssertEqual(SettingsPanel.panelSize(for: .zero), CGSize(width: 780, height: 460))
        XCTAssertEqual(SettingsPanel.panelSize(for: CGSize(width: 860, height: 620)), CGSize(width: 788, height: 548))
        XCTAssertEqual(SettingsPanel.panelSize(for: CGSize(width: 1120, height: 780)), CGSize(width: 1048, height: 708))
        XCTAssertEqual(SettingsPanel.panelSize(for: CGSize(width: 1740, height: 1130)), CGSize(width: 1600, height: 1058))
        XCTAssertEqual(SettingsPanel.panelSize(for: CGSize(width: 2560, height: 1440)), CGSize(width: 1600, height: 1060))
        XCTAssertEqual(SettingsPanel.navigationWidth(for: 788), 157.6, accuracy: 0.1)
        XCTAssertEqual(SettingsPanel.navigationWidth(for: 1048), 209.6, accuracy: 0.1)
        XCTAssertEqual(SettingsPanel.navigationWidth(for: 1600), 216, accuracy: 0.1)

        let designPanelWidth: CGFloat = 1600
        let designPanelHeight: CGFloat = 1060
        let designNavWidth: CGFloat = 216
        let designReadingWidth: CGFloat = 880
        let designRightPaneWidth = designPanelWidth - designNavWidth - 1

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("Zivvi-LargeSettings-\(UUID())")
        let projectDir1 = tempRoot.appendingPathComponent("Project-" + String(repeating: "w", count: 160))
        let projectDir2 = tempRoot.appendingPathComponent("Project-Two")
        let projectDir3 = tempRoot.appendingPathComponent("Project-Three")
        for dir in [projectDir1, projectDir2, projectDir3] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: tempRoot) }
        let selectedProjectID = await workspace.addProject(projectDir1.resolvingSymlinksInPath(), createInitialSession: false)
        _ = await workspace.addProject(projectDir2.resolvingSymlinksInPath(), createInitialSession: false)
        _ = await workspace.addProject(projectDir3.resolvingSymlinksInPath(), createInitialSession: false)

        let panel = SettingsPanel(
            workspace: workspace,
            settings: settings,
            initialSection: .projects,
            preferredProjectID: selectedProjectID,
            availableSize: CGSize(width: 2560, height: 1440),
            worktreesForProject: { _ in nil },
            close: {},
            restart: {}
        )
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1640, height: 1100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        XCTAssertEqual(host.fittingSize.width, designPanelWidth, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, designPanelHeight, accuracy: 1)

        func allScrollViews(in view: NSView) -> [NSScrollView] {
            var result: [NSScrollView] = []
            if let scroll = view as? NSScrollView { result.append(scroll) }
            for subview in view.subviews {
                result.append(contentsOf: allScrollViews(in: subview))
            }
            return result
        }

        func textInteractionRects(in view: NSView) -> [NSRect] {
            var rects: [NSRect] = []
            if String(describing: type(of: view)).contains("AppKitTextInteractionView") {
                rects.append(view.convert(view.bounds, to: host))
            }
            for subview in view.subviews {
                rects.append(contentsOf: textInteractionRects(in: subview))
            }
            return rects
        }

        let scrollViews = allScrollViews(in: host)
        let outerScrollView = try XCTUnwrap(scrollViews.max(by: { $0.bounds.height < $1.bounds.height }))
        let scrollRect = outerScrollView.convert(outerScrollView.bounds, to: host)
        let panelMinX = host.bounds.minX + (host.bounds.width - designPanelWidth) / 2
        let panelMaxX = panelMinX + designPanelWidth
        XCTAssertEqual(scrollRect.minX, panelMinX + designNavWidth + 1, accuracy: 2)
        XCTAssertEqual(scrollRect.maxX, panelMaxX, accuracy: 2)
        XCTAssertEqual(scrollRect.width, designRightPaneWidth, accuracy: 2)

        XCTAssertEqual(scrollViews.count, 1, "Projects are listed only when the pinned project menu opens.")

        let rects = textInteractionRects(in: host)
        let contentLeftEdge = try XCTUnwrap(rects.map(\.minX).min())
        let contentRightEdge = try XCTUnwrap(rects.map(\.maxX).max())
        let clipRect = outerScrollView.contentView.convert(outerScrollView.contentView.bounds, to: host)
        let expectedReadingMinX = clipRect.minX + (clipRect.width - designReadingWidth) / 2
        XCTAssertEqual(contentLeftEdge, expectedReadingMinX, accuracy: 8)
        XCTAssertLessThanOrEqual(contentRightEdge, expectedReadingMinX + designReadingWidth + 4)
        XCTAssertLessThanOrEqual(contentRightEdge - contentLeftEdge, designReadingWidth + 4)
        addWindowScreenshot(of: host, name: "Project settings · large window")
    }

    @MainActor func testPermissionApprovalShowsSummaryAndTogglesRawInput() async throws {
        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Run command"))
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "acp-cmd-approval",
            kind: .confirm,
            title: "Run command",
            toolApproval: .init(workingDirectory: "/fixture", operation: .command(text: "echo hi", timeoutSeconds: 10)),
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce)
            ],
            permissionContext: .init(toolTitle: "Run command", toolName: "run_command", toolKind: "execute",
                                     workingDirectory: "/fixture", toolSummary: "Details fixture body",
                                     rawInputJSON: "{\"RawFixture\": \"/fixture/path\"}")
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(rootView: InteractionView(request: request, controller: controller, sessionTitle: "Fixture"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        func selectableTexts(in view: NSView) -> [String] {
            var values: [String] = []
            if String(describing: type(of: view)).contains("AppKitTextInteractionView"),
               let text = view.accessibilityValue() as? String {
                values.append(text)
            }
            for child in view.subviews {
                values.append(contentsOf: selectableTexts(in: child))
            }
            return values
        }

        let initialTexts = try recognizedTexts(in: host)
        let joinedInitial = initialTexts.map(\.text).joined(separator: "\n")
        XCTAssertFalse(joinedInitial.contains("取消"), "Unexpected cancel button in: \(joinedInitial)")
        XCTAssertFalse(joinedInitial.contains("停止任务"), "Unexpected stop button in: \(joinedInitial)")
        XCTAssertTrue(joinedInitial.contains("拒绝"), "Expected reject button in: \(joinedInitial)")
        XCTAssertTrue(joinedInitial.contains("允许本次"), "Expected allow button in: \(joinedInitial)")
        XCTAssertTrue(selectableTexts(in: host).contains("Details fixture body"))
        XCTAssertFalse(joinedInitial.contains("run_command"), "Tool identity should be folded inside 技术详情")
        let detailsObservation = try XCTUnwrap(initialTexts.first { $0.text.contains("技术详情") })
        XCTAssertFalse(selectableTexts(in: host).contains { $0.contains("RawFixture") })

        let collapsedHeight = host.fittingSize.height
        let box = detailsObservation.box
        let fromTop = (1 - box.midY) * host.bounds.height

        // Hovering across the "技术详情" row must not paint a gray hover background.
        let hoverPoint = NSPoint(x: box.maxX * host.bounds.width + 60, y: (1 - fromTop / host.bounds.height) * host.bounds.height)
        let beforeHoverColor = try pixelColor(in: host, at: hoverPoint)
        window.acceptsMouseMovedEvents = true
        let moveEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: host.convert(hoverPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        window.sendEvent(moveEvent)
        await settleWindow(window)
        let afterHoverColor = try pixelColor(in: host, at: hoverPoint)
        XCTAssertEqual(afterHoverColor.redComponent, beforeHoverColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(afterHoverColor.greenComponent, beforeHoverColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(afterHoverColor.blueComponent, beforeHoverColor.blueComponent, accuracy: 0.01)

        // Click on the "技术详情" text.
        try clickApproval(in: host, x: box.midX * host.bounds.width, fromTop: fromTop)
        try await Task.sleep(for: .milliseconds(250))
        await settleWindow(window)
        XCTAssertGreaterThan(host.fittingSize.height, collapsedHeight)
        let expandedSelectable = selectableTexts(in: host)
        XCTAssertTrue(expandedSelectable.contains { $0.contains("RawFixture") })
        XCTAssertTrue(expandedSelectable.contains("run_command"))

        // Click on the "技术详情" row again to collapse.
        let expandedTexts = try recognizedTexts(in: host)
        let expandedDetails = try XCTUnwrap(expandedTexts.first { $0.text.contains("技术详情") })
        let expandedBox = expandedDetails.box
        let expandedFromTop = (1 - expandedBox.midY) * host.bounds.height
        try clickApproval(in: host, x: expandedBox.midX * host.bounds.width, fromTop: expandedFromTop)
        try await Task.sleep(for: .milliseconds(250))
        await settleWindow(window)
        XCTAssertEqual(host.fittingSize.height, collapsedHeight, accuracy: 1)
        XCTAssertFalse(selectableTexts(in: host).contains { $0.contains("RawFixture") })

        _ = await controller.disconnect()
    }

    @MainActor func testModelConfigurationPanelHidesAntigravityACPServerSubtitle() async throws {
        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let acpSession = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [acpSession]
        snapshot.selectedSessionID = acpSession.id
        snapshot.preferences.acpAgents = [RuntimeAgentProfile.antigravityPreset()]

        let acpModel = RuntimeModel(provider: "Antigravity ACP Server", modelID: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen")
        let workspace = WorkspaceController(
            store: MemoryStore(snapshot),
            inspectRuntimeModels: { runtimeID, _ in
                if runtimeID == RuntimeAgentProfile.antigravityRuntimeID {
                    return .init(models: [acpModel], thinkingLevels: ["low", "high"])
                }
                return .init(models: [], thinkingLevels: ["low", "high"])
            },
            runtimeFactory: { _, _, _ in StubSessionRuntime() }
        )
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: ModelConfigurationPanel(
            workspace: workspace, reference: acpSession, saving: .constant(false), width: 420, close: {}
        ))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        var acpTexts = ""
        for _ in 0..<40 {
            await settleWindow(window)
            acpTexts = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
            if acpTexts.contains("Gemini 4 Hydrogen") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(acpTexts.contains("Gemini 4 Hydrogen"), "Expected Gemini 4 Hydrogen in: \(acpTexts)")
        XCTAssertFalse(acpTexts.localizedCaseInsensitiveContains("Antigravity ACP Server"), "Unexpected ACP server subtitle in: \(acpTexts)")
        XCTAssertFalse(acpTexts.localizedCaseInsensitiveContains("ACP Server"), "Unexpected ACP server subtitle in: \(acpTexts)")

    }

    @MainActor func testActiveRunBannerShowsCountdownSecondsOnReviewButton() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ActiveRunBanner.remainingSeconds(until: now.addingTimeInterval(65), relativeTo: now), 65)
        XCTAssertEqual(ActiveRunBanner.remainingSeconds(until: now.addingTimeInterval(64.2), relativeTo: now), 65)
        XCTAssertEqual(ActiveRunBanner.remainingSeconds(until: now, relativeTo: now), 0)
        XCTAssertEqual(ActiveRunBanner.remainingSeconds(until: now.addingTimeInterval(-5), relativeTo: now), 0)

        XCTAssertEqual(ActiveRunBanner.remainingFraction(from: now, until: now.addingTimeInterval(100), relativeTo: now), 1.0, accuracy: 0.001)
        XCTAssertEqual(ActiveRunBanner.remainingFraction(from: now, until: now.addingTimeInterval(100), relativeTo: now.addingTimeInterval(40)), 0.6, accuracy: 0.001)
        XCTAssertEqual(ActiveRunBanner.remainingFraction(from: now, until: now.addingTimeInterval(100), relativeTo: now.addingTimeInterval(120)), 0.0, accuracy: 0.001)
        XCTAssertEqual(ActiveRunBanner.remainingFraction(from: now, until: now, relativeTo: now), 0.0, accuracy: 0.001)

        let runtime = StubSessionRuntime()
        let workspace = WorkspaceController(store: MemoryStore()) { _, _ in runtime }
        await workspace.start(); workspace.setACPAgents([.antigravityPreset()])
        let added = await workspace.addProject(FileManager.default.temporaryDirectory)
        let project = try XCTUnwrap(added)
        let created = await workspace.createSession(in: project)
        let sessionID = try XCTUnwrap(created)
        await workspace.send(sessionID, submitted: .init(text: "Background fixture"))
        let controller = try XCTUnwrap(workspace.execution(for: sessionID))

        let requestCreatedAt = Date().addingTimeInterval(-150)
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "background-countdown",
            kind: .confirm,
            title: "Approval fixture",
            expiresAt: requestCreatedAt.addingTimeInterval(300),
            createdAt: requestCreatedAt,
            toolApproval: .init(workingDirectory: "/fixture", operation: .command(text: "echo hi", timeoutSeconds: nil))
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(rootView: ActiveRunBanner(workspace: workspace, sessionID: sessionID) {}
            .frame(width: 600, height: 38, alignment: .top)
            .background(ZivviTheme.pageBackground))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 38),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let rendered = (try recognizedTexts(in: host)).map(\.text).joined(separator: " ")
        XCTAssertTrue(rendered.contains("去处理"), "Expected 去处理 in: \(rendered)")
        XCTAssertTrue(rendered.range(of: #"\b\d+s\b"#, options: .regularExpression) != nil,
                      "Expected countdown seconds in: \(rendered)")

        let midpoint = host.bounds.midX
        let sampleY = host.bounds.midY
        let leading = try pixelColor(in: host, at: .init(x: 1, y: sampleY))
        let insideProgress = try pixelColor(in: host, at: .init(x: midpoint - 12, y: sampleY))
        let outsideProgress = try pixelColor(in: host, at: .init(x: midpoint + 12, y: sampleY))
        let trailing = try pixelColor(in: host, at: .init(x: host.bounds.maxX - 1, y: sampleY))
        XCTAssertEqual(leading, insideProgress)
        XCTAssertEqual(trailing, outsideProgress)
        XCTAssertNotEqual(insideProgress, outsideProgress)
        _ = await workspace.disconnectAll()
    }

    @MainActor func testRecentToolFailuresScopesToLatestLiveTurnAndPersistsDismissal() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        let controller = presentation.controller

        let historicalFailure = HistoryItem(
            id: "hist-tool-fail",
            kind: .tool,
            tool: RuntimeTool(id: "hist-t0", name: "bash", arguments: "{}", output: "old error", state: .failed)
        )
        controller.showHistory([historicalFailure])
        XCTAssertTrue(controller.recentToolFailures.isEmpty)

        let activated = await workspace.activate(presentation.id)
        XCTAssertTrue(activated)

        let failedTool1 = RuntimeTool(id: "t1", name: "bash", arguments: "{}", output: "err1", state: .failed)
        runtime.emit(.runStarted)
        runtime.emit(.tool(failedTool1))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.recentToolFailures.map(\.id), ["tool:t1"])

        func makeDetailHost() -> NSHostingView<SessionDetail> {
            NSHostingView(rootView: SessionDetail(
                workspace: workspace,
                settings: AppSettings(),
                presentation: presentation,
                openConnectionSettings: { _ in },
                presentConfirmation: { _ in }
            ))
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        var host = makeDetailHost()
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)
        let textsWithOneFailure = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(textsWithOneFailure.filter { !$0.isWhitespace }.contains("1项工具调用失败"),
                      "Expected failure count 1 in: \(textsWithOneFailure)")

        // Emitting a second failed tool in the same turn increments the count in the notice row.
        let failedTool1B = RuntimeTool(id: "t1b", name: "read", arguments: "{}", output: "err1b", state: .failed)
        runtime.emit(.tool(failedTool1B))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(Set(controller.recentToolFailures.map(\.id)), ["tool:t1", "tool:t1b"])
        await settleWindow(window)
        let textsWithTwoFailures = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(textsWithTwoFailures.filter { !$0.isWhitespace }.contains("2项工具调用失败"),
                      "Expected failure count 2 in: \(textsWithTwoFailures)")

        // Settle the turn; the failures from that turn remain inspectable until dismissed or next turn.
        runtime.emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(Set(controller.recentToolFailures.map(\.id)), ["tool:t1", "tool:t1b"])

        // Dismissing persists on SessionController across view recreation (e.g. session switch).
        controller.dismissToolFailures(controller.recentToolFailures)
        XCTAssertTrue(controller.recentToolFailures.isEmpty)
        host = makeDetailHost()
        window.contentView = host
        await settleWindow(window)
        let textsAfterDismiss = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertFalse(textsAfterDismiss.contains("工具调用失败"), "Unexpected failure notice after dismiss: \(textsAfterDismiss)")

        // Another failed tool in a new turn surfaces again, then clears when the user sends a new prompt.
        let failedTool2 = RuntimeTool(id: "t2", name: "bash", arguments: "{}", output: "err2", state: .failed)
        runtime.emit(.runStarted)
        runtime.emit(.tool(failedTool2))
        runtime.emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.recentToolFailures.map(\.id), ["tool:t2"])

        await controller.sendDraft(UserPrompt(text: "Next question"))
        XCTAssertTrue(controller.recentToolFailures.isEmpty)
        await settleWindow(window)
        let textsNextTurn = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertFalse(textsNextTurn.contains("工具调用失败"), "Unexpected failure pill on next turn: \(textsNextTurn)")

        runtime.emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.recentToolFailures.isEmpty)

        _ = await workspace.disconnectAll()
    }

    @MainActor func testToolFailureDetailsSheetHidesScrollbarsAndPagesMultipleFailures() async throws {
        let longArg = "{\"command\":\"" + String(repeating: "x", count: 240) + "\"}"
        let longOutput = (1...24).map { "error line \($0): something failed in step \($0)" }.joined(separator: "\n")
        let failures = [
            TranscriptItem(
                id: "tool:f1",
                kind: .tool,
                tool: RuntimeTool(id: "f1", name: "first_bash", arguments: longArg, output: longOutput, state: .failed)
            ),
            TranscriptItem(
                id: "tool:f2",
                kind: .tool,
                tool: RuntimeTool(id: "f2", name: "second_read", arguments: "{\"path\":\"/tmp/missing.txt\"}", output: "second failure marker", state: .failed)
            )
        ]

        let host = NSHostingView(rootView: ToolFailureDetailsSheet(failures: failures, close: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let scrollViews = approvalScrollViews(in: host)
        XCTAssertFalse(scrollViews.isEmpty)
        for scroll in scrollViews {
            XCTAssertFalse(scroll.hasHorizontalScroller)
            XCTAssertFalse(scroll.hasVerticalScroller)
            XCTAssertTrue(scroll.horizontalScroller?.isHidden ?? true)
            XCTAssertTrue(scroll.verticalScroller?.isHidden ?? true)
        }

        // Outer horizontal pager must overflow across the 2 pages, while keeping card contents scrollable.
        let pagerScroll = try XCTUnwrap(scrollViews.first { scroll in
            guard let doc = scroll.documentView else { return false }
            return doc.frame.width > scroll.contentView.bounds.width + 200
                && scroll.contentView.bounds.height >= 200
        })
        XCTAssertTrue(try XCTUnwrap(scrollViews.first {
            guard let doc = $0.documentView else { return false }
            return doc.frame.height > $0.contentView.bounds.height + 20
        }).documentView != nil)

        let initialTexts = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(initialTexts.filter { !$0.isWhitespace }.contains("1/2"),
                      "Expected 1 / 2 page counter in: \(initialTexts)")
        XCTAssertTrue(initialTexts.contains("first_bash"), "Expected first failed tool in: \(initialTexts)")

        let pageWidth = pagerScroll.contentView.bounds.width
        pagerScroll.contentView.scroll(to: NSPoint(x: pageWidth, y: 0))
        pagerScroll.reflectScrolledClipView(pagerScroll.contentView)
        await settleWindow(window)

        let pagedTexts = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(pagedTexts.contains("second_read"), "Expected second failed tool after horizontal scroll in: \(pagedTexts)")
        XCTAssertTrue(pagedTexts.contains("second failure marker"), "Expected second tool output in: \(pagedTexts)")
    }

    @MainActor func testACPModePopoverHidesHeaderFooterAndAdaptsWidthToFullDescription() throws {
        let modes = [
            RuntimeModeOption(id: "default", name: "Default", description: "Ask before edits and commands, and confirm changes"),
            RuntimeModeOption(id: "auto", name: "Auto", description: "Approve edits and safe commands automatically")
        ]
        // Simulate ComposerControlsLayout's `.lineLimit(1)` environment inherited by the popover.
        let host = NSHostingView(rootView: ACPModePopoverContent(
            availableModes: modes,
            activeModeID: "auto",
            maxWidth: 460,
            select: { _ in }
        ).lineLimit(1))
        let width = host.fittingSize.width
        XCTAssertGreaterThan(width, 280, "Popover should expand beyond the old 280pt fixed width")
        XCTAssertLessThanOrEqual(width, 460)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let rendered = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertFalse(rendered.contains("ACP 执行模式"), "Unexpected header in: \(rendered)")
        XCTAssertFalse(rendered.contains("权限审批"), "Unexpected footer in: \(rendered)")
        XCTAssertTrue(rendered.contains("and confirm changes"), "Expected full description without truncation in: \(rendered)")
        XCTAssertTrue(rendered.contains("safe commands automatically"), "Expected full description without truncation in: \(rendered)")
    }

    @MainActor func testApprovalTimeoutPillRequestsConfirmationAndRevealsExpiredRecord() async throws {
        let runtime = StubSessionRuntime(runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        let workspace = await newConversationWorkspace(runtime: runtime)
        let presentation = try XCTUnwrap(workspace.viewed)
        let controller = presentation.controller
        let activated = await workspace.activate(presentation.id)
        XCTAssertTrue(activated)

        let expired = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "expired-pill-target",
            kind: .confirm,
            title: "Run targeted check",
            toolApproval: .init(workingDirectory: "/fixture", operation: .command(text: "echo check", timeoutSeconds: 10))
        )
        runtime.emit(.runStarted)
        runtime.emit(.interaction(expired))
        runtime.emit(.interactionEnded(expired.id, .expired))
        for index in 1...15 {
            runtime.emit(.assistantCompleted(UUID(), String(repeating: "Following turn line \(index).\n", count: 4)))
        }
        runtime.emit(.settled(aborted: true))
        try await Task.sleep(for: .milliseconds(50))

        let expiredItem = try XCTUnwrap(controller.transcript.last { $0.expiredInteraction?.requestID == "expired-pill-target" })

        let scrollState = TranscriptScrollState()
        var confirmation: ConfirmationRequest?
        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace,
            settings: AppSettings(),
            presentation: presentation,
            windowScrollState: scrollState,
            openConnectionSettings: { _ in },
            presentConfirmation: { confirmation = $0 }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let transcriptScroll = try XCTUnwrap(approvalScrollViews(in: host).first { isTranscriptScrollView($0) })
        let initialY = transcriptScroll.contentView.bounds.minY
        XCTAssertGreaterThan(initialY, 100, "Transcript should start scrolled near bottom away from the expired row")

        let texts = try recognizedTexts(in: host)
        let joined = texts.map(\.text).joined(separator: "\n")
        let pill = try XCTUnwrap(texts.first { $0.text.contains("继续任务") },
                               "Expected updated pill title in: \(joined)")
        let fromTop = (1 - pill.box.midY) * host.bounds.height
        try clickApproval(in: host, x: pill.box.midX * host.bounds.width, fromTop: fromTop)
        await settleWindow(window)

        XCTAssertEqual(transcriptScroll.contentView.bounds.minY, initialY, accuracy: 3)
        XCTAssertFalse(scrollState.approvalExpansion.binding(for: expiredItem.timelineID).wrappedValue)
        let viewRecord = try XCTUnwrap(confirmation?.alternative?.perform)
        viewRecord()
        await settleWindow(window)

        XCTAssertTrue(scrollState.approvalExpansion.binding(for: expiredItem.timelineID).wrappedValue)
        let jumpedY = transcriptScroll.contentView.bounds.minY
        XCTAssertLessThan(jumpedY, initialY - 100, "Viewing the approval should scroll to the expired row (\(expiredItem.id))")
        _ = await workspace.disconnectAll()
    }

    @MainActor func testGenericToolPermissionApprovalHidesSessionInfo() async throws {
        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Edit file"))
        let uniqueSessionTitle = "UniqueApprovalSessionTitle-9482"
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "acp-generic-approval",
            kind: .confirm,
            title: "Edit file",
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce)
            ],
            permissionContext: .init(toolTitle: "File SessionController.swift", workingDirectory: "/fixture")
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(rootView: InteractionView(request: request, controller: controller, sessionTitle: uniqueSessionTitle)
            .background(ZivviTheme.pageBackground))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let rendered = (try recognizedTexts(in: host)).map(\.text).joined(separator: "\n")
        XCTAssertTrue(rendered.contains("Edit file"), "Expected the approval title in: \(rendered)")
        XCTAssertFalse(rendered.contains("会话"), "Did not expect session label in: \(rendered)")
        XCTAssertFalse(rendered.contains(uniqueSessionTitle), "Did not expect session title in: \(rendered)")

        _ = await controller.disconnect()
    }

    func testApprovalPathsKeepDistinctUTF8BytesForGroupingAndCopy() {
        let composed = "caf\u{00E9}/file"
        let decomposed = "cafe\u{0301}/file"
        XCTAssertEqual(composed, decomposed)
        let diffs: [RuntimePermissionContext.FileDiff] = [
            .init(path: composed, oldText: "1", newText: "2"),
            .init(path: decomposed, oldText: "3", newText: "4"),
            .init(path: composed, oldText: "5", newText: "6")
        ]
        let groups = ApprovalPathFormatter.diffGroups(diffs)
        XCTAssertEqual(Set(groups.map(\.id)), Set([Data(composed.utf8), Data(decomposed.utf8)]))
        let copies = groups.map { group in
            Data(ApprovalPathFormatter.absolutePath(group.path, relativeTo: "/project").utf8)
        }
        XCTAssertEqual(Set(copies), Set([Data("/project/\(composed)".utf8), Data("/project/\(decomposed)".utf8)]))
        XCTAssertEqual(groups.first { $0.id == Data(composed.utf8) }?.changes.map(\.newText), ["2", "6"])
        XCTAssertEqual(groups.first { $0.id == Data(decomposed.utf8) }?.changes.map(\.newText), ["4"])
        let related = ApprovalPathFormatter.relatedPaths([composed, decomposed, decomposed], excluding: [diffs[0]])
        XCTAssertEqual(related.map(\.id), [Data(decomposed.utf8)])
        XCTAssertEqual(Data(ApprovalPathFormatter.displayPath("/project/\(composed)", projectDirectory: "/project/caf\u{00E9}").utf8),
                       Data(composed.utf8))
        XCTAssertEqual(Data(ApprovalPathFormatter.displayPath("/project/\(decomposed)", projectDirectory: "/project/caf\u{00E9}").utf8),
                       Data("/project/\(decomposed)".utf8))
    }

    @MainActor func testApprovalDetailsDistinguishCommandScopeAndResolveRelatedCopyPaths() {
        let session = "/fixture/caf\u{00E9}"
        let explicitDirectory = "/fixture/cafe\u{0301}"
        let path = "src/main.swift"
        let absolutePath = session + "/" + path
        for directory in [session, explicitDirectory] {
            let context = RuntimePermissionContext(toolTitle: "Run", toolKind: "execute", workingDirectory: directory,
                                                   sessionDirectory: session, paths: [path, "/outside/file"])
            let approval = RuntimeToolApproval(workingDirectory: directory,
                                               operation: .command(text: "pwd", timeoutSeconds: nil))
            let request = RuntimeInteraction(instanceID: UUID(), requestID: "command", kind: .select, title: "Run",
                                             toolApproval: approval, permissionContext: context)
            let active = ActiveApprovalDetails(approval: approval, context: context, message: "", projectDirectory: nil,
                                               wrapsPreviewLines: .constant(true))
            let expired = ExpiredInteractionDetails(request: request)
            let expectedDirectory = directory.utf8.elementsEqual(session.utf8) ? nil : Data(directory.utf8)
            XCTAssertEqual(active.commandDirectory.map { Data($0.utf8) }, expectedDirectory)
            XCTAssertEqual(expired.additionalWorkingDirectory.map { Data($0.utf8) }, expectedDirectory)

            let contextDetails = PermissionContextDetails(context: context, projectDirectory: nil,
                                                          excludingWorkingDirectory: session)
            XCTAssertNil(contextDetails.displayedWorkingDirectory)
            let copyValues = Set([absolutePath, "/outside/file"].map { Data($0.utf8) })
            XCTAssertEqual(Set(active.relatedPaths.map { Data($0.path.utf8) }), copyValues)
            XCTAssertEqual(Set(contextDetails.relatedPaths.map { Data($0.path.utf8) }), copyValues)
        }
    }

    @MainActor func testExpiredGenericApprovalKeepsTheOperationTitleWhenLocationsAreAvailable() {
        let path = "src/main.swift"
        let option = RuntimePermissionOption(id: "allow", name: "Allow", kind: .allowOnce)
        let diff = RuntimePermissionContext.FileDiff(path: path, oldText: "old", newText: "new")
        func approval(_ kind: String?, title: String, diffs: [RuntimePermissionContext.FileDiff],
                      operation: RuntimeToolApproval.Operation? = nil) -> RuntimeInteraction {
            RuntimeInteraction(instanceID: UUID(), requestID: kind ?? "fixture", kind: .select, title: title,
                               toolApproval: operation.map { .init(workingDirectory: "/repo", operation: $0) },
                               permissionOptions: [option], permissionContext: .init(
                                toolTitle: title, toolKind: kind, paths: [path], diffs: diffs))
        }

        for (kind, title) in [("read", "Read source"), ("delete", "Delete source")] {
            for diffs in [[], [diff]] {
                let request = approval(kind, title: title, diffs: diffs)
                XCTAssertFalse(request.isExpiredFileEditApproval)
                XCTAssertTrue(ExpiredInteractionDetails(request: request).showsRequestTitle)
            }
        }
        let read = approval(nil, title: "Read source", diffs: [diff], operation: .inspect(.read, arguments: []))
        XCTAssertFalse(read.isExpiredFileEditApproval)
        XCTAssertTrue(ExpiredInteractionDetails(request: read).showsRequestTitle)
        let edits = [
            approval("edit", title: "Edit source", diffs: [diff]),
            approval(nil, title: "Edit source", diffs: [diff]),
            approval(nil, title: "Edit source", diffs: [], operation: .edit(path: path, replacements: []))
        ]
        for request in edits {
            XCTAssertTrue(request.isExpiredFileEditApproval)
            XCTAssertFalse(ExpiredInteractionDetails(request: request).showsRequestTitle)
        }
        let editWithPathOnly = approval("edit", title: "Edit source", diffs: [])
        XCTAssertTrue(editWithPathOnly.isExpiredFileEditApproval)
        XCTAssertTrue(ExpiredInteractionDetails(request: editWithPathOnly).showsRequestTitle)
    }

    @MainActor func testExpiredApprovalDeduplicatesResolvedLocationsAndDiffPathsByBytes() {
        let directory = "/fixture"
        let composed = "caf\u{00E9}.swift"
        let decomposed = "cafe\u{0301}.swift"
        let resolvedComposed = "\(directory)/\(composed)"
        let resolvedDecomposed = "\(directory)/\(decomposed)"
        for diffPath in [composed, resolvedComposed] {
            let context = RuntimePermissionContext(toolTitle: "Edit", toolKind: "edit", sessionDirectory: directory,
                                                   paths: [composed, resolvedComposed, decomposed, resolvedDecomposed],
                                                   diffs: [.init(path: diffPath, oldText: "old", newText: "new")])
            let expired = PermissionContextDetails(context: context, projectDirectory: directory, compactFilePaths: true)
            XCTAssertEqual(expired.relatedPaths.map(\.id), [Data(resolvedDecomposed.utf8)])
            XCTAssertEqual(expired.relatedPaths.map { Data($0.path.utf8) }, [Data(resolvedDecomposed.utf8)])

            let active = PermissionContextDetails(context: context, projectDirectory: directory)
            let expectedActive = [composed, resolvedComposed, decomposed, resolvedDecomposed]
                .map { Data($0.utf8) }.filter { $0 != Data(diffPath.utf8) }
            XCTAssertEqual(Set(active.relatedPaths.map(\.id)), Set(expectedActive))
        }

        let diffs = zip([composed, resolvedComposed, resolvedDecomposed, decomposed], ["first", "second", "third", "fourth"])
            .map { path, update in RuntimePermissionContext.FileDiff(path: path, oldText: "old", newText: update) }
        let groups = ApprovalPathFormatter.diffGroups(diffs, relativeTo: directory, deduplicateResolvedPaths: true)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.id == Data(resolvedComposed.utf8) }?.changes.map(\.newText), ["first", "second"])
        XCTAssertEqual(groups.first { $0.id == Data(resolvedDecomposed.utf8) }?.changes.map(\.newText), ["third", "fourth"])
        let activeGroups = ApprovalPathFormatter.diffGroups(diffs, relativeTo: directory)
        XCTAssertEqual(Set(activeGroups.map(\.id)), Set(diffs.map { Data($0.path.utf8) }))
    }

    func testApprovalPathFormatterPrefixesProjectPathsAndKeepsOutsidePathsAbsolute() {
        let root = "/Users/fixture/Documents/zivvi"
        XCTAssertEqual(ApprovalPathFormatter.displayPath(root, projectDirectory: root), "zivvi")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("\(root)/Verification", projectDirectory: root), "zivvi/Verification")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("\(root)/Zivvi/App.swift", projectDirectory: root), "zivvi/Zivvi/App.swift")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("\(root)/Zivvi/App.swift", projectDirectory: root,
                                                        includesProjectName: false), "Zivvi/App.swift")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("\(root)-other/file", projectDirectory: root), "\(root)-other/file")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("/tmp/outside.txt", projectDirectory: root), "/tmp/outside.txt")
        let worktreePath = ApprovalPathFormatter.absolutePath("Zivvi/App.swift", relativeTo: "/tmp/zivvi-worktree")
        XCTAssertEqual(ApprovalPathFormatter.displayPath(worktreePath, projectDirectory: root, includesProjectName: false),
                       "/tmp/zivvi-worktree/Zivvi/App.swift")
        XCTAssertEqual(ApprovalPathFormatter.displayPath("\(root)/../out.txt", projectDirectory: root), "\(root)/../out.txt")
        XCTAssertEqual(ApprovalPathFormatter.absolutePath("Zivvi/App.swift", relativeTo: root), "\(root)/Zivvi/App.swift")
    }

    @MainActor func testApprovalMetadataPrefixesProjectPaths() async throws {
        let project = "/fixture/zivvi"
        let controller = SessionController()
        let runtime = StubSessionRuntime()
        await controller.connect(runtime)
        await controller.sendDraft(UserPrompt(text: "Edit file"))
        let affectedFile = "\(project)/Modules/OrchestrationCore/SessionController.swift"
        let request = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "acp-relative-paths",
            kind: .confirm,
            title: "Edit file",
            permissionOptions: [
                .init(id: "reject", name: "Reject once", kind: .rejectOnce),
                .init(id: "allow", name: "Allow once", kind: .allowOnce)
            ],
            permissionContext: .init(
                toolTitle: "File Modules/OrchestrationCore/SessionController.swift",
                workingDirectory: project,
                paths: [affectedFile]
            )
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(request)))

        let host = NSHostingView(
            rootView: InteractionView(
                request: request,
                controller: controller,
                sessionTitle: "Fixture",
                projectDirectory: project
            ).background(ZivviTheme.pageBackground)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        let displayedValues = selectableApprovalTexts(in: host)
        XCTAssertTrue(displayedValues.contains("zivvi/Modules/OrchestrationCore/SessionController.swift"),
                      "Expected the project-root prefix in: \(displayedValues)")
        XCTAssertFalse(displayedValues.contains(project), "Did not expect absolute working directory in: \(displayedValues)")
        XCTAssertFalse(displayedValues.contains(affectedFile), "Did not expect absolute affected path in: \(displayedValues)")

        _ = await controller.disconnect()
    }

    @MainActor private func selectableApprovalTexts(in view: NSView) -> [String] {
        let text = (view as? NSTextView)?.string ?? view.accessibilityValue() as? String
        let ownText = text.map { [$0] } ?? []
        return ownText + view.subviews.flatMap { selectableApprovalTexts(in: $0) }
    }

    @MainActor private func recognizedTexts(in view: NSView, matching substring: String? = nil) throws -> [(text: String, box: CGRect)] {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let cgImage = try XCTUnwrap(rep.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            if let substring {
                guard let range = candidate.string.range(of: substring),
                      let region = try? candidate.boundingBox(for: range) else { return nil }
                return (substring, region.boundingBox)
            }
            return (candidate.string, observation.boundingBox)
        }
    }

    @MainActor private func pixelColor(in view: NSView, at point: NSPoint) throws -> NSColor {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        let x = max(0, min(bitmap.pixelsWide - 1, Int(round(point.x * CGFloat(bitmap.pixelsWide) / max(1, bounds.width)))))
        let y = max(0, min(bitmap.pixelsHigh - 1, Int(round((bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / max(1, bounds.height)))))
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func runGit(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "GitTest", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    @MainActor func testClickingConversationAreaAcknowledgesUnreadCompletionExcludingFloatingOverlay() async throws {
        let runtime = StubSessionRuntime()
        let workspace = await newConversationWorkspace(runtime: runtime)
        workspace.isForegroundWindowActive = { false }
        let id = try XCTUnwrap(workspace.selected?.id)
        let activated = await workspace.activate(id)
        XCTAssertTrue(activated)
        let controller = try XCTUnwrap(workspace.execution(for: id))
        let presentation = try XCTUnwrap(workspace.viewed)

        func finishTurn() {
            controller.receive(.init(instanceID: runtime.instanceID, event: .phase(.running)))
            controller.receive(.init(instanceID: runtime.instanceID, event: .settled(aborted: false)))
        }

        finishTurn()
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)

        let host = NSHostingView(rootView: SessionDetail(
            workspace: workspace,
            settings: AppSettings(),
            presentation: presentation,
            blocksComposerPanels: false,
            excludedTrailingWidth: 200,
            openConnectionSettings: { _ in },
            presentConfirmation: { _ in }
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settleWindow(window)

        func findMonitor(in view: NSView) -> SessionDetailClickMonitor.Anchor? {
            if let anchor = view as? SessionDetailClickMonitor.Anchor { return anchor }
            for subview in view.subviews {
                if let found = findMonitor(in: subview) { return found }
            }
            return nil
        }
        func makeClick(at pointInWindow: NSPoint, in targetWindow: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pointInWindow,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: targetWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        let monitor = try XCTUnwrap(findMonitor(in: host))
        let otherWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        defer { otherWindow.orderOut(nil) }

        // Clicks in another window or inside the floating files overlay do not clear unread.
        monitor.handleMouseDown(try makeClick(at: NSPoint(x: 120, y: 200), in: otherWindow))
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)

        monitor.handleMouseDown(try makeClick(at: NSPoint(x: 720, y: 200), in: window))
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)

        // Clicking inside the conversation area clears the unread indicator.
        monitor.handleMouseDown(try makeClick(at: NSPoint(x: 120, y: 200), in: window))
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, false)

        // Blocked panels (e.g. sheet or lightbox) suppress click acknowledgement.
        finishTurn()
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)
        host.rootView = SessionDetail(
            workspace: workspace,
            settings: AppSettings(),
            presentation: presentation,
            blocksComposerPanels: true,
            excludedTrailingWidth: 0,
            openConnectionSettings: { _ in },
            presentConfirmation: { _ in }
        )
        await settleWindow(window)
        monitor.handleMouseDown(try makeClick(at: NSPoint(x: 120, y: 200), in: window))
        XCTAssertEqual(workspace.selected?.hasUnreadCompletion, true)

        _ = await workspace.disconnectAll()
    }
}


@MainActor @Observable private final class TestSidebarVisibility {
    var value: NavigationSplitViewVisibility = .all
}
