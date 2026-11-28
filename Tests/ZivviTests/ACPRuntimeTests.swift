import XCTest
import Foundation
import Darwin
import AgentRuntimeCore
import OrchestrationCore
import ProcessSupervision
@testable import ACPRuntimeAdapter
@testable import Zivvi

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }

    var value: T {
        lock.withLock { storage }
    }
}

private final class ACPEventRecorder: @unchecked Sendable {
    private let storage = LockedBox<[AgentEvent]>([])
    private var task: Task<Void, Never>?

    init(runtime: ACPRuntime) {
        let stream = runtime.events
        let storage = self.storage
        task = Task.detached {
            for await envelope in stream {
                storage.withValue { list in
                    if case .batch(let items) = envelope.event {
                        list.append(contentsOf: items)
                    } else {
                        list.append(envelope.event)
                    }
                }
            }
        }
    }

    var events: [AgentEvent] { storage.value }

    func waitUntil(timeout: TimeInterval = 10, _ predicate: @Sendable ([AgentEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return predicate(events)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

final class ACPRuntimeTests: XCTestCase {
    private var fakeACPURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Verification/Fixtures/fake-acp.py")
    }

    private func makeTempDir(prefix: String = "zivvi-acp-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func fakeConfig(
        workspace: URL,
        extraArgs: [String] = [],
        expectedSessionID: String? = nil,
        cancelTimeoutSeconds: TimeInterval = 5
    ) -> ACPConfiguration {
        ACPConfiguration(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", fakeACPURL.path] + extraArgs,
            workspace: workspace,
            runtimeID: "acp:fake",
            expectedSessionID: expectedSessionID,
            environmentOverrides: [:],
            cancelTimeoutSeconds: cancelTimeoutSeconds
        )
    }

    func testSharedConnectionRoutesWorktreesHistoryAndIndependentClose() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let directoryA = root.appendingPathComponent("worktree-a")
        let directoryB = root.appendingPathComponent("worktree-b")
        let receipts = root.appendingPathComponent("receipts")
        let log = root.appendingPathComponent("fixture.jsonl")
        for directory in [directoryA, directoryB] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("fixture.txt"))
        }
        var profile = fakeConfig(workspace: root.appendingPathComponent("application-directory"),
                                 extraArgs: ["--v1-extended", "--delay-prompt", "0.7", "--receipt-path", log.path])
        profile.clientPermissions = [.readFiles]
        var configA = profile
        configA.workspace = directoryA
        var configB = profile
        configB.workspace = directoryB
        let handoff = ACPHandoffCleanup(root: receipts, id: UUID())
        var handoffConfig = configA
        handoffConfig.handoffCleanup = handoff
        await pool.configure([profile], receipts: receipts, sequence: 1)
        let a = ACPRuntime(configuration: handoffConfig, pool: pool)
        let b = ACPRuntime(configuration: configB, pool: pool)
        let eventsA = ACPEventRecorder(runtime: a)
        let eventsB = ACPEventRecorder(runtime: b)
        defer { eventsA.cancel(); eventsB.cancel() }

        async let openA = a.connect()
        async let openB = b.connect()
        let (sessionA, sessionB) = try await (openA, openB)
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        let impactA = await a.sharedConnectionImpact()
        XCTAssertEqual(impactA?.runtimeIDs, [a.instanceID, b.instanceID])
        _ = try await a.send(.init(text: "verify-client-read-only"))
        _ = try await b.send(.init(text: "verify-client-read-only"))
        let doneA = await eventsA.waitUntil { $0.contains { if case .settled(aborted: false) = $0 { return true }; return false } }
        let doneB = await eventsB.waitUntil { $0.contains { if case .settled(aborted: false) = $0 { return true }; return false } }
        XCTAssertTrue(doneA && doneB)
        XCTAssertFalse((eventsA.events + eventsB.events).contains { if case .failure = $0 { return true }; return false })

        let sameDirectory = ACPRuntime(configuration: configA, pool: pool)
        let secondA = try await sameDirectory.connect()
        let control = try await ACPAgentConnection.open(configA, pool: pool)
        let first = try await control.list(cursor: nil)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await control.list(cursor: cursor)
        XCTAssertEqual(Set((first.sessions + second.sessions).map(\.id)), [sessionA.id, secondA.id])

        let priorEvents = eventsB.events.count
        _ = try await b.send(.init(text: "remains connected"))
        XCTAssertFalse(handoff.isConfirmed)
        try await a.close(force: false)
        XCTAssertTrue(handoff.isConfirmed)
        try await control.delete(sessionID: sessionA.id)
        try await control.close()
        try await sameDirectory.close(force: false)
        let stillRunning = await eventsB.waitUntil { events in
            events.dropFirst(priorEvents).contains { if case .settled(aborted: false) = $0 { return true }; return false }
        }
        XCTAssertTrue(stillRunning)
        let continued = try await b.currentSession()
        XCTAssertEqual(continued.id, sessionB.id)
        try await b.close(force: false)

        let afterZero = ACPRuntime(configuration: configA, pool: pool)
        _ = try await afterZero.connect()
        let afterImpact = await afterZero.sharedConnectionImpact()
        XCTAssertEqual(afterImpact?.connectionID, impactA?.connectionID)
        try await afterZero.close(force: false)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains(#""initialize""#) }.count, 1)
        let clean = await pool.shutdown()
        XCTAssertTrue(clean)
    }

    func testMissingAndRejectedSessionCloseUseDedicatedCompatibilityPath() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let receipts = root.appendingPathComponent("receipts")
        let withoutClose = fakeConfig(workspace: root)
        let rejectingClose = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--reject-session-close"])
        await pool.configure([withoutClose], receipts: receipts, sequence: 1)
        let dedicated = ACPRuntime(configuration: withoutClose, pool: pool)
        _ = try await dedicated.connect()
        let dedicatedImpact = await dedicated.sharedConnectionImpact()
        XCTAssertNil(dedicatedImpact)
        try await dedicated.close(force: false)

        await pool.configure([rejectingClose], receipts: receipts, sequence: 2)
        let first = ACPRuntime(configuration: rejectingClose, pool: pool)
        _ = try await first.connect()
        let firstImpact = await first.sharedConnectionImpact()
        XCTAssertNotNil(firstImpact)
        do {
            try await first.close(force: false)
            XCTFail("Not implemented must not be treated as a successful session close")
        } catch {}
        let fallback = ACPRuntime(configuration: rejectingClose, pool: pool)
        _ = try await fallback.connect()
        let fallbackImpact = await fallback.sharedConnectionImpact()
        XCTAssertNil(fallbackImpact)
        try await fallback.close(force: false)
        try await first.close(force: true)
    }

    func testSharedForceRequiresCurrentMembershipAndReopensAfterCleanup() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let profile = fakeConfig(workspace: root, extraArgs: ["--v1-extended"])
        await pool.configure([profile], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let a = ACPRuntime(configuration: profile, pool: pool)
        _ = try await a.connect()
        let initial = await a.sharedConnectionImpact()
        let beforeB = try XCTUnwrap(initial)
        let b = ACPRuntime(configuration: profile, pool: pool)
        let eventsB = ACPEventRecorder(runtime: b)
        defer { eventsB.cancel() }
        _ = try await b.connect()
        let oldConfirmation = try await a.forceEndSharedConnection(matching: beforeB)
        XCTAssertFalse(oldConfirmation)
        let updated = await a.sharedConnectionImpact()
        let current = try XCTUnwrap(updated)
        let didEnd = try await a.forceEndSharedConnection(matching: current)
        XCTAssertTrue(didEnd)
        let peerEnded = await eventsB.waitUntil { events in
            events.contains { if case .disconnected(cleanupConfirmed: true) = $0 { return true }; return false }
        }
        XCTAssertTrue(peerEnded)
        try await a.close(force: false)
        try await b.close(force: false)
        let replacement = ACPRuntime(configuration: profile, pool: pool)
        _ = try await replacement.connect()
        let replacementImpact = await replacement.sharedConnectionImpact()
        XCTAssertNotEqual(replacementImpact?.connectionID, current.connectionID)
        let replacementEvents = ACPEventRecorder(runtime: replacement)
        defer { replacementEvents.cancel() }
        await replacement.terminateRuntimeForVerification()
        let crashed = await replacementEvents.waitUntil { events in
            events.contains { if case .disconnected(cleanupConfirmed: true) = $0 { return true }; return false }
        }
        XCTAssertTrue(crashed)
        try await replacement.close(force: false)
        let recovered = ACPRuntime(configuration: profile, pool: pool)
        _ = try await recovered.connect()
        let recoveredImpact = await recovered.sharedConnectionImpact()
        XCTAssertNotEqual(recoveredImpact?.connectionID, replacementImpact?.connectionID)
        try await recovered.close(force: false)
    }

    func testUnconfirmedSharedCloseKeepsPeersOnTheSameConnection() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let profile = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--ignore-session-close"])
        await pool.configure([profile], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let a = ACPRuntime(configuration: profile, pool: pool)
        _ = try await a.connect()
        do {
            try await a.close(force: false)
            XCTFail("Closing without a response must remain unconfirmed")
        } catch {}
        let staying = await a.sharedConnectionImpact()
        let b = ACPRuntime(configuration: profile, pool: pool)
        _ = try await b.connect()
        let peer = await b.sharedConnectionImpact()
        XCTAssertEqual(staying?.connectionID, peer?.connectionID)
        XCTAssertEqual(peer?.runtimeIDs, [a.instanceID, b.instanceID])
        try await a.close(force: true)
        try await b.close(force: false)
    }

    func testSharedLoginReplacementDoesNotAttachAfterRuntimeClose() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let marker = root.appendingPathComponent("logged-in")
        let gate = root.appendingPathComponent("allow-replacement")
        let wire = root.appendingPathComponent("wire.jsonl")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--terminal-auth-state", marker.path,
            "--terminal-reconnect-gate", gate.path, "--receipt-path", wire.path])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let runtime = ACPRuntime(configuration: config, pool: pool, terminalAuthenticator: { _ in try Data().write(to: marker) })
        let events = ACPEventRecorder(runtime: runtime)
        defer { events.cancel() }
        let opening = Task { try await runtime.connect() }
        defer { opening.cancel() }
        _ = await events.waitUntil { events in events.contains { if case .interaction = $0 { true } else { false } } }
        let choice = try XCTUnwrap(events.events.compactMap { event in
            if case .interaction(let request) = event { return request }
            return nil
        }.first)
        try await runtime.respond(to: choice, with: .value("terminal-login"))
        _ = try await Self.initializedSupervisor(wire, attempt: 2)
        try await runtime.close(force: false)
        try Data().write(to: gate)
        guard case .failure(let error) = await opening.result else { return XCTFail("Closed runtime attached again") }
        XCTAssertTrue(error is CancellationError)
        let host = try await pool.connection(for: config)
        XCTAssertEqual(host?.endpointIDs, [])
        let peer = ACPRuntime(configuration: config, pool: pool)
        _ = try await peer.connect()
        try await peer.close(force: false)
    }

    func testGracefulCloseWaitsForSharedSessionNewAndReleasesIt() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let gate = root.appendingPathComponent("allow-new")
        let wire = root.appendingPathComponent("wire.jsonl")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--session-new-gate", gate.path, "--receipt-path", wire.path])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let runtime = ACPRuntime(configuration: config, pool: pool)
        let opening = Task { try await runtime.connect() }
        defer { opening.cancel() }
        try await Self.waitForWireEvent("session/new", at: wire)
        let closed = LockedBox(false)
        let closing = Task {
            try await runtime.close(force: false)
            closed.withValue { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(closed.value)
        try Data().write(to: gate)
        try await closing.value
        guard case .failure(let error) = await opening.result else { return XCTFail("Closed runtime completed opening") }
        XCTAssertTrue(error is CancellationError)
        try await Self.waitForWireEvent("session/close", at: wire)
        let host = try await pool.connection(for: config)
        XCTAssertEqual(host?.endpointIDs, [])
    }

    func testRetiredHostRejectsPromptsAndReleasesHistoryControls() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let gate = root.appendingPathComponent("allow-list")
        let wire = root.appendingPathComponent("wire.jsonl")
        let receipts = root.appendingPathComponent("receipts")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--session-list-gate", gate.path, "--receipt-path", wire.path])
        await pool.configure([config], receipts: receipts, sequence: 1)
        let control = try await ACPAgentConnection.open(config, pool: pool)
        let runtime = ACPRuntime(configuration: config, pool: pool)
        _ = try await runtime.connect()
        let listed = Task { try await control.list(cursor: nil) }
        defer { listed.cancel() }
        try await Self.waitForWireEvent("session/list", at: wire)
        let process = try await Self.initializedSupervisor(wire, attempt: 1)
        await pool.configure([], receipts: receipts, sequence: 2)
        guard case .failure = await listed.result else { return XCTFail("Retirement let a pending query finish") }
        let connected = await control.isConnected
        XCTAssertFalse(connected)
        do {
            _ = try await runtime.send(.init(text: "must never reach retired host"))
            XCTFail("Retired host accepted a prompt")
        } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .setup) }
        try Data().write(to: gate)
        try await runtime.close(force: false)
        try await Self.waitForExit(process)
        XCTAssertFalse(try String(contentsOf: wire, encoding: .utf8).contains(#""session/prompt""#))
        try await control.close()
    }

    func testSharedCleanupRetryRetainsEndpointUntilTerminalReceiptIsClean() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let receipts = root.appendingPathComponent("receipts")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended"])
        await pool.configure([config], receipts: receipts, sequence: 1)
        var sessionConfig = config
        let receipt = ACPHandoffCleanup(root: receipts, id: UUID())
        sessionConfig.handoffCleanup = receipt
        let runtime = ACPRuntime(configuration: sessionConfig, pool: pool)
        let events = ACPEventRecorder(runtime: runtime)
        defer { events.cancel() }
        _ = try await runtime.connect()
        let terminal = receipt.directory.appendingPathComponent("pikachu-terminal-injected")
        try FileManager.default.createDirectory(at: terminal, withIntermediateDirectories: false)
        let initial = await runtime.sharedConnectionImpact()
        let impact = try XCTUnwrap(initial)
        do {
            _ = try await runtime.forceEndSharedConnection(matching: impact)
            XCTFail("An unconfirmed terminal receipt must prevent complete cleanup")
        } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .supervision) }
        let pending = await runtime.sharedConnectionImpact()
        XCTAssertEqual(pending, impact)
        let unconfirmed = await events.waitUntil { $0.contains { if case .disconnected(cleanupConfirmed: false) = $0 { true } else { false } } }
        XCTAssertTrue(unconfirmed)
        try Data(#"{"supervisionID":"pikachu-terminal-injected","state":"clean","remaining":0}"#.utf8)
            .write(to: terminal.appendingPathComponent("status.json"))
        let retried = try await runtime.forceEndSharedConnection(matching: impact)
        XCTAssertTrue(retried)
        let confirmed = await events.waitUntil { $0.contains { if case .disconnected(cleanupConfirmed: true) = $0 { true } else { false } } }
        XCTAssertTrue(confirmed)
        try await runtime.close(force: false)
    }

    func testSharedCloseAndDeleteRequireValidACPResponses() async throws {
        for shape in ["null", "array", "number-meta", "null-meta"] {
            let root = try makeTempDir()
            let pool = ACPConnectionPool()
            addTeardownBlock {
                _ = await pool.shutdown(force: true)
                try FileManager.default.removeItem(at: root)
            }
            let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--session-mutation-result", shape])
            await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
            let runtime = ACPRuntime(configuration: config, pool: pool)
            let session = try await runtime.connect()
            let control = try await ACPAgentConnection.open(config, pool: pool)
            if shape == "null-meta" {
                try await runtime.close(force: false)
                try await control.delete(sessionID: session.id)
            } else {
                do {
                    try await runtime.close(force: false)
                    XCTFail("Invalid close was accepted: \(shape)")
                } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .protocolError) }
                let impact = await runtime.sharedConnectionImpact()
                XCTAssertEqual(impact?.runtimeIDs, [runtime.instanceID])
                do {
                    try await control.delete(sessionID: session.id)
                    XCTFail("Invalid delete was accepted: \(shape)")
                } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .protocolError) }
                try await runtime.close(force: true)
            }
            try await control.close()
        }
    }

    private static func waitForWireEvent(_ method: String, at receipt: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while .now < deadline {
            if let wire = try? String(contentsOf: receipt, encoding: .utf8), wire.contains("\"event\": \"\(method)\"") { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeFailure(.connection, "Fixture did not receive \(method)")
    }

    func testSharedForceInterruptsBackpressuredWriteAndRejectsQueuedSetup() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let wire = root.appendingPathComponent("wire.jsonl")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--receipt-path", wire.path])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let runtime = ACPRuntime(configuration: config, pool: pool)
        _ = try await runtime.connect()
        let connectedHost = try await pool.connection(for: config)
        let host = try XCTUnwrap(connectedHost)
        let receipt = try String(contentsOf: wire, encoding: .utf8).split(separator: "\n").first { $0.contains(#""initialize""#) }
        let initialize = try XCTUnwrap(receipt)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(initialize.utf8)) as? Record)
        let pid = try XCTUnwrap((record["detail"] as? Record)?["pid"] as? Int32)
        let agent = try XCTUnwrap(ProcessIdentity.read(pid))
        guard agent.parent == host.root.client.process.processIdentifier, agent.signal(SIGSTOP) else {
            return XCTFail("Cannot pause the synthetic Agent's stdin reader")
        }
        defer { _ = agent.signal(SIGCONT) }

        let prompt = Task { try await runtime.send(.init(text: String(repeating: "x", count: 1_048_576))) }
        defer { prompt.cancel() }
        let pending = ContinuousClock.now + .seconds(2)
        while host.root.client.bufferStatus.pendingRequests == 0 && .now < pending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.root.client.bufferStatus.pendingRequests, 1)
        let waiting = ACPRuntime(configuration: config, pool: pool)
        let setup = Task { try await waiting.connect() }
        defer { setup.cancel() }
        while host.root.client.bufferStatus.pendingRequests < 2 && .now < pending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.root.client.bufferStatus.pendingRequests, 2)
        let impact = await runtime.sharedConnectionImpact()
        let current = try XCTUnwrap(impact)
        let start = ContinuousClock.now
        let ended = try await runtime.forceEndSharedConnection(matching: current)
        XCTAssertTrue(ended)
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        guard case .failure = await prompt.result, case .failure = await setup.result else {
            return XCTFail("The stopped process accepted a complete request")
        }
        let recorded = try String(contentsOf: wire, encoding: .utf8)
        XCTAssertEqual(recorded.components(separatedBy: #""session/new""#).count - 1, 1)
        XCTAssertFalse(recorded.contains(#""session/prompt""#))
        try await runtime.close(force: false)
        try await waiting.close(force: false)
    }

    @MainActor
    func testSharedSessionCloseConvergesOnUnexpectedAgentEOF() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--exit-on-session-close"])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let runtime = ACPRuntime(configuration: config, pool: pool)
        let controller = SessionController()
        await controller.connect(runtime)
        XCTAssertEqual(controller.connection, .connected)
        let clean = await controller.disconnect()
        XCTAssertTrue(clean)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertNil(controller.runtimeInstanceID)
    }

    func testCloseDrainsQueuedUpdatesBeforeRebindingSameRemoteID() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--close-queued-update"])
        let host = try ACPSharedHost(configuration: config, receipts: root.appendingPathComponent("receipts"),
                                     terminalAuthentication: false, onChange: { _ in })
        defer { try? host.shutdown(force: true) }
        // Deliberately leave the pump stopped. A response can arrive with earlier notifications still queued.
        let original = try ACPConnection(configuration: config, instanceID: UUID(), sink: RuntimeEventChannel(),
                                         host: host, deferDisconnectEvents: true)
        let old = try original.openSession()
        try original.close(force: false)
        XCTAssertEqual(host.root.client.bufferStatus.inbound, 0)
        var restoredConfig = config
        restoredConfig.expectedSessionID = old.id
        let restored = try ACPConnection(configuration: restoredConfig, instanceID: UUID(), sink: RuntimeEventChannel(),
                                         host: host, deferDisconnectEvents: true)
        XCTAssertEqual(try restored.openSession().id, old.id)
        XCTAssertFalse((restored.takeLoadedHistory() ?? []).contains { $0.text.contains("stale-closed-endpoint") })
        try restored.close(force: false)
    }

    @MainActor
    func testGracefulShutdownCancelsHistoryQueriesInSharedAndDedicatedModes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = root.appendingPathComponent("hold-list")
        let sharedWire = root.appendingPathComponent("shared.jsonl")
        let pool = ACPConnectionPool()
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--session-list-gate", gate.path, "--receipt-path", sharedWire.path])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let shared = try await ACPAgentConnection.open(config, pool: pool)
        let sharedList = Task { try await shared.list(cursor: nil) }
        defer { sharedList.cancel() }
        try await Self.waitForWireEvent("session/list", at: sharedWire)
        let sharedClean = await pool.shutdown()
        XCTAssertTrue(sharedClean)
        guard case .failure = await sharedList.result else { return XCTFail("Old shared query finished during shutdown") }
        try await shared.close()

        let wire = root.appendingPathComponent("dedicated.jsonl")
        let profile = RuntimeAgentProfile.customACP(name: "Fixture", executablePath: "/usr/bin/python3",
            arguments: ["-u", fakeACPURL.path, "--v1-extended", "--session-list-gate", gate.path, "--receipt-path", wire.path])
        let settings = AppSettings()
        settings.acpAgents = [profile]
        let dedicated = try await settings.openACPControl(agentID: profile.id, directory: root)
        let list = Task { try await dedicated.list(cursor: nil) }
        defer { list.cancel() }
        try await Self.waitForWireEvent("session/list", at: wire)
        let supervisor = try await Self.initializedSupervisor(wire, attempt: 1)
        XCTAssertTrue(settings.hasHistoryControls)
        settings.beginAuthenticationShutdown()
        let dedicatedClean = await settings.stopAndConfirmHistoryCleanup()
        XCTAssertTrue(dedicatedClean)
        XCTAssertFalse(settings.hasHistoryControls)
        guard case .failure = await list.result else { return XCTFail("Old dedicated query finished during shutdown") }
        try await Self.waitForExit(supervisor)
    }

    @MainActor
    func testHistoryReloadUsesReplacementIdentityAndPreservesReconnectBackoff() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended"])
        await pool.configure([config], receipts: root.appendingPathComponent("receipts"), sequence: 1)
        let runtime = ACPRuntime(configuration: config, pool: pool)
        _ = try await runtime.connect()
        let previousImpact = await runtime.sharedConnectionImpact()
        let previous = try XCTUnwrap(previousImpact).connectionID
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: .ready(previous)), .waiting)
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: .reconnecting), .waiting)
        let statuses = pool.statuses
        let retryStarted = LockedBox<ContinuousClock.Instant?>(nil)
        let observe = Task {
            for await (id, status) in statuses where id == config.runtimeID && status == .reconnecting {
                retryStarted.withValue { $0 = .now }
                return
            }
        }
        defer { observe.cancel() }
        await runtime.terminateRuntimeForVerification()
        let deadline = ContinuousClock.now + .seconds(6)
        while retryStarted.value == nil && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let start = try XCTUnwrap(retryStarted.value)
        let host = try await pool.connection(for: config)
        let replacement = try XCTUnwrap(host).id
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(750))
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: .ready(replacement)), .reload)
        try await runtime.close(force: false)
    }

    @MainActor
    func testHistoryReplacementCanRecoverFromAuthenticationAndFailedHandshake() async throws {
        let root = try makeTempDir()
        let pool = ACPConnectionPool()
        addTeardownBlock {
            _ = await pool.shutdown(force: true)
            try FileManager.default.removeItem(at: root)
        }
        let receipts = root.appendingPathComponent("receipts")
        let config = fakeConfig(workspace: root, extraArgs: ["--v1-extended"])
        await pool.configure([config], receipts: receipts, sequence: 1)
        let original = try await ACPAgentConnection.open(config, pool: pool)
        let previousHost = await original.sharedConnectionID
        let previous = try XCTUnwrap(previousHost)
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: .needsLogin(previous)), .waiting)
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: .needsLogin(nil)), .loginInSettings)

        let observed = LockedBox<[ACPPoolStatus]>([])
        let statuses = pool.statuses
        let watch = Task {
            for await (id, status) in statuses where id == config.runtimeID {
                if let status { observed.withValue { $0.append(status) } }
            }
        }
        defer { watch.cancel() }
        let authenticating = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--require-auth"])
        await pool.configure([authenticating], receipts: receipts, sequence: 2)
        let probe = try await ACPAgentConnection.open(authenticating, pool: pool)
        let replacementHost = await probe.sharedConnectionID
        let replacement = try XCTUnwrap(replacementHost)
        do {
            _ = try await probe.list(cursor: nil)
            XCTFail("The replacement should require login before listing sessions")
        } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .authentication) }
        let authDeadline = ContinuousClock.now + .seconds(3)
        while !observed.value.contains(.needsLogin(replacement)) && .now < authDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let status = try XCTUnwrap(observed.value.first { $0 == .needsLogin(replacement) })
        XCTAssertEqual(ACPHistoryImportView.recovery(after: previous, status: status), .reload)
        let history = try await ACPAgentConnection.open(authenticating, pool: pool)
        let methods = await history.authentication.methods
        XCTAssertTrue(methods.contains { $0.id == "oauth-browser" })
        try await history.authenticate(methodID: "oauth-browser")
        _ = try await history.list(cursor: nil)
        try await probe.close()

        let unsupported = fakeConfig(workspace: root, extraArgs: ["--v1-extended", "--protocol-version", "2"])
        await pool.configure([unsupported], receipts: receipts, sequence: 3)
        do {
            _ = try await pool.connection(for: unsupported)
            XCTFail("A failed replacement handshake should not vend a connection")
        } catch let failure as RuntimeFailure { XCTAssertEqual(failure.kind, .unsupportedVersion) }
        let failureDeadline = ContinuousClock.now + .seconds(3)
        while !observed.value.contains(where: { if case .failed = $0 { true } else { false } }) && .now < failureDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let failed = try XCTUnwrap(observed.value.last { if case .failed = $0 { true } else { false } })
        guard case .failed(let detail) = failed else { return XCTFail("The startup error was discarded") }
        XCTAssertFalse(detail.isEmpty)
        XCTAssertEqual(ACPHistoryImportView.recovery(after: replacement, status: failed), .failed(detail))
        try await history.close()
        try await original.close()
    }

    private static func initializedSupervisor(_ receipt: URL, attempt: Int) async throws -> ProcessIdentity {
        let deadline = ContinuousClock.now + .seconds(6)
        while .now < deadline {
            let lines = (try? String(contentsOf: receipt, encoding: .utf8))?.split(separator: "\n") ?? []
            let records = lines.filter { $0.contains(#""initialize""#) }
            if records.count >= attempt,
               let entry = try JSONSerialization.jsonObject(with: Data(records[attempt - 1].utf8)) as? Record,
               let pid = (entry["detail"] as? Record)?["supervisorPID"] as? Int32,
               let identity = ProcessIdentity.read(pid) {
                return identity
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(nil as ProcessIdentity?, "The fixture did not report a live process")
    }

    private static func waitForExit(_ identity: ProcessIdentity) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline {
            guard let current = ProcessIdentity.read(identity.pid), current.sameProcess(as: identity), current.live else { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture process did not exit")
    }

    private static func waitForEndOfEvents(_ ended: LockedBox<Bool>) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ended.value, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ended.value, "The settings event consumer should see the connection close")
    }

    @MainActor
    func testTerminalLoginReconnectsAndRetriesSessionWithoutAuthenticateRPC() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let receipt = dir.appendingPathComponent("wire.jsonl")
        var config = fakeConfig(workspace: dir, extraArgs: ["--require-auth", "--terminal-auth-state", marker.path])
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path, "FAKE_LOGIN_FLAG": "base", "BASE": "retained"]

        let settings = AppSettings()
        let profile = RuntimeAgentProfile(id: config.runtimeID, name: "Synthetic ACP", executablePath: config.executable.path)
        settings.addACPAgent(profile)
        let previousRevision = settings.acpConfigurationRevision(for: profile.id)
        let runtime = ACPRuntime(configuration: config,
                                 authenticationTransaction: settings.acpAuthenticationTransaction(for: profile.id)) { launch in
            XCTAssertTrue(settings.isChangingACPConfiguration(for: profile.id))
            XCTAssertGreaterThan(settings.acpConfigurationRevision(for: profile.id), previousRevision)
            XCTAssertEqual(launch.appendedArguments, ["--terminal-login"])
            XCTAssertEqual(launch.environmentOverrides, ["FAKE_LOGIN_FLAG": "terminal"])
            XCTAssertEqual(launch.environment["FAKE_LOGIN_FLAG"], "terminal")
            XCTAssertEqual(launch.environment["BASE"], "retained")
            XCTAssertEqual(launch.workingDirectory, dir)
            let records = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n")
            let firstRecord = try XCTUnwrap(records.first)
            let initialize = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstRecord.utf8)) as? Record)
            let pid = try XCTUnwrap((initialize["detail"] as? Record)?["pid"] as? Int)
            XCTAssertNotEqual(ProcessIdentity.read(Int32(pid))?.live, true, "Old ACP process must be cleaned before terminal login")
            try Data().write(to: marker)
        }
        let controller = SessionController()
        let connecting = Task { await controller.connect(runtime) }
        defer { connecting.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.interactions.isEmpty, .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let choice = try XCTUnwrap(controller.interactions.first)
        XCTAssertEqual(choice.authenticationMethods.map(\.name), ["Browser Login", "Browser Login"])
        let answered = await controller.reply(choice, .value("terminal-login"))
        XCTAssertTrue(answered)
        await connecting.value
        XCTAssertFalse(settings.isWritingACPSettings(for: profile.id))
        XCTAssertGreaterThan(settings.acpConfigurationRevision(for: profile.id), previousRevision)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertNotNil(controller.session?.id)
        let disconnected = await controller.disconnect(force: true)
        XCTAssertTrue(disconnected)
        let wire = try String(contentsOf: receipt, encoding: .utf8)
        XCTAssertEqual(wire.components(separatedBy: #""initialize""#).count - 1, 2)
        XCTAssertFalse(wire.contains(#""authenticate""#))
    }

    func testTerminalLoginControlReconnectsOnlyAfterSuccessfulLogin() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let receipt = dir.appendingPathComponent("wire.jsonl")
        var config = fakeConfig(workspace: dir, extraArgs: ["--v1-extended", "--terminal-auth-state", marker.path])
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path]
        let attempts = LockedBox(0)
        let control = try await ACPAgentConnection.open(config) { _ in
            let attempt = attempts.withValue { $0 += 1; return $0 }
            if attempt == 1 { throw CancellationError() }
            try Data().write(to: marker)
        }
        do {
            try await control.authenticate(methodID: "terminal-login")
            XCTFail("Cancelled login should not complete")
        } catch is CancellationError {}
        let cancelledWire = try String(contentsOf: receipt, encoding: .utf8)
        XCTAssertEqual(cancelledWire.components(separatedBy: #""initialize""#).count - 1, 1)

        try await control.authenticate(methodID: "terminal-login")
        let refreshed = await control.authentication
        XCTAssertTrue(refreshed.methods.contains(where: { $0.kind == .terminal }))
        _ = try await control.list(cursor: nil)
        try await control.close()
        let wire = try String(contentsOf: receipt, encoding: .utf8)
        XCTAssertEqual(wire.components(separatedBy: #""initialize""#).count - 1, 2)
        XCTAssertFalse(wire.contains(#""authenticate""#))
    }

    func testSettingsTerminalReconnectCancellationAndFailureInvalidateClosedBridge() async throws {
        for fails in [false, true] {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let marker = dir.appendingPathComponent("signed-in")
            let receipt = dir.appendingPathComponent("wire.jsonl")
            let gate = dir.appendingPathComponent("allow-reconnect")
            let extraArgs = ["--v1-extended", "--terminal-auth-state", marker.path]
                + (fails ? ["--fail-terminal-reconnect"] : ["--terminal-reconnect-gate", gate.path])
            var config = fakeConfig(workspace: dir, extraArgs: extraArgs)
            config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path]
            let control = try await ACPAgentConnection.open(config) { _ in try Data().write(to: marker) }
            let login = Task { try await control.authenticate(methodID: "terminal-login") }
            defer { login.cancel() }
            if !fails {
                let deadline = ContinuousClock.now + .seconds(7)
                var observed = false
                while .now < deadline {
                    let wire = (try? String(contentsOf: receipt, encoding: .utf8)) ?? ""
                    if wire.components(separatedBy: #""initialize""#).count - 1 == 2 {
                        observed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(observed)
                login.cancel()
                try Data().write(to: gate)
            }
            do {
                try await login.value
                XCTFail("Cancelled or failed reconnect cannot report success")
            } catch {
                XCTAssertEqual(error is CancellationError, !fails)
            }
            let connected = await control.isConnected
            let authentication = await control.authentication
            XCTAssertFalse(connected)
            XCTAssertTrue(authentication.methods.isEmpty)
            XCTAssertFalse(authentication.canLogout)
            try await control.close()
        }
    }

    @MainActor
    func testAuthenticationSelectionSurvivesOldBridgeExit() async throws {
        for method in ["terminal-login", "oauth-browser"] {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let marker = dir.appendingPathComponent("signed-in")
            let gate = dir.appendingPathComponent("exit-old-bridge")
            let receipt = dir.appendingPathComponent("wire.jsonl")
            var config = fakeConfig(workspace: dir, extraArgs: [
                "--require-auth", "--terminal-auth-state", marker.path, "--terminal-old-exit-gate", gate.path
            ])
            config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path]
            let settings = AppSettings()
            let profile = RuntimeAgentProfile(id: config.runtimeID, name: "Synthetic ACP", executablePath: config.executable.path)
            settings.addACPAgent(profile)
            let previousRevision = settings.acpConfigurationRevision(for: profile.id)
            let runtime = ACPRuntime(configuration: config,
                                     authenticationTransaction: settings.acpAuthenticationTransaction(for: profile.id)) { _ in
                try Data().write(to: marker)
            }
            let controller = SessionController()
            let connecting = Task { await controller.connect(runtime) }
            defer { connecting.cancel() }
            let supervisor = try await Self.initializedSupervisor(receipt, attempt: 1)
            let deadline = ContinuousClock.now + .seconds(6)
            while controller.interactions.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let choice = try XCTUnwrap(controller.interactions.first)
            try Data().write(to: gate)
            try await Self.waitForExit(supervisor)
            let answered = await controller.reply(choice, .value(method))
            XCTAssertTrue(answered)
            await connecting.value
            XCTAssertFalse(settings.isWritingACPSettings(for: profile.id))
            XCTAssertGreaterThan(settings.acpConfigurationRevision(for: profile.id), previousRevision)
            if method == "terminal-login" {
                XCTAssertEqual(controller.connection, .connected)
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
                let closed = await controller.disconnect(force: true)
                XCTAssertTrue(closed)
            } else {
                XCTAssertEqual(controller.connection, .disconnected)
                XCTAssertEqual(controller.failure?.kind, .connection)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }
    }

    func testSettingsReplacementUsesNewEventConnectionIDAfterOldBridgeExit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let gate = dir.appendingPathComponent("exit-old-bridge")
        let receipt = dir.appendingPathComponent("wire.jsonl")
        var config = fakeConfig(workspace: dir, extraArgs: [
            "--v1-extended", "--terminal-auth-state", marker.path, "--terminal-old-exit-gate", gate.path
        ])
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path]
        let supervisor = LockedBox<ProcessIdentity?>(nil)
        let oldDisconnectID = LockedBox<UUID?>(nil)
        let control = try await ACPAgentConnection.open(config) { _ in
            try Data().write(to: gate)
            try await Self.waitForExit(XCTUnwrap(supervisor.value))
            let deadline = ContinuousClock.now + .seconds(5)
            while oldDisconnectID.value == nil, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            _ = try XCTUnwrap(oldDisconnectID.value)
            try Data().write(to: marker)
        }
        let events = Task {
            for await envelope in control.events {
                let events: [AgentEvent]
                if case .batch(let batch) = envelope.event { events = batch }
                else { events = [envelope.event] }
                let disconnected = events.contains {
                    if case .disconnected = $0 { return true }
                    return false
                }
                if disconnected {
                    oldDisconnectID.withValue { $0 = envelope.instanceID }
                    return
                }
            }
        }
        defer { events.cancel() }
        let process = try await Self.initializedSupervisor(receipt, attempt: 1)
        supervisor.withValue { $0 = process }
        let originalID = await control.authentication.connectionID
        try await control.authenticate(methodID: "terminal-login")
        let replacement = await control.authentication
        XCTAssertNotNil(replacement.connectionID)
        XCTAssertNotEqual(originalID, replacement.connectionID)
        XCTAssertEqual(oldDisconnectID.value, originalID)
        XCTAssertTrue(replacement.canLogout)
        try await control.close()
    }

    @MainActor
    func testFailedReplacementHandshakeRetainsCleanupInSettingsAndWorkspace() async throws {
        for settings in [true, false] {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let marker = dir.appendingPathComponent("signed-in")
            let gate = dir.appendingPathComponent("allow-reconnect")
            let receipt = dir.appendingPathComponent("wire.jsonl")
            var config = fakeConfig(workspace: dir, extraArgs: [
                "--v1-extended", "--terminal-auth-state", marker.path, "--terminal-reconnect-gate", gate.path,
                "--fail-terminal-reconnect"
            ])
            config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipt.path]
            let authenticate: RuntimeTerminalAuthenticator = { _ in try Data().write(to: marker) }
            let controller = SessionController()
            let control: ACPAgentConnection?
            let login: Task<Void, Error>
            if settings {
                let settingsControl = try await ACPAgentConnection.open(config, terminalAuthenticator: authenticate)
                control = settingsControl
                login = Task { try await settingsControl.authenticate(methodID: "terminal-login") }
            } else {
                control = nil
                let runtime = ACPRuntime(configuration: config, terminalAuthenticator: authenticate)
                login = Task { await controller.connect(runtime) }
                let deadline = ContinuousClock.now + .seconds(6)
                while controller.interactions.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                let choice = try XCTUnwrap(controller.interactions.first)
                _ = await controller.reply(choice, .value("terminal-login"))
            }
            defer { login.cancel() }
            let eventsEnded = LockedBox(false)
            let eventConsumer = control.map { control in
                Task {
                    for await _ in control.events {}
                    eventsEnded.withValue { $0 = true }
                }
            }
            defer { eventConsumer?.cancel() }

            let supervisor = try await Self.initializedSupervisor(receipt, attempt: 2)
            XCTAssertEqual(supervisor.parent, getpid())
            guard supervisor.parent == getpid(), supervisor.signal(SIGSTOP) else { throw CocoaError(.fileNoSuchFile) }
            defer { _ = supervisor.signal(SIGCONT) }
            try Data().write(to: gate)
            let result = await login.result
            if let control {
                guard case .failure(let error) = result else { return XCTFail("Failed handshake reported success") }
                XCTAssertEqual((error as? RuntimeFailure)?.kind, .supervision)
                do {
                    try await control.close()
                    XCTFail("Settings released cleanup before the replacement supervisor reported it")
                } catch let error as RuntimeFailure { XCTAssertEqual(error.kind, .supervision) }
                try await Self.waitForEndOfEvents(eventsEnded)
                let revokedAuthentication = await control.authentication
                XCTAssertTrue(revokedAuthentication.methods.isEmpty)
                XCTAssertFalse(revokedAuthentication.canLogout)
            } else {
                XCTAssertEqual(controller.connection, .blocked)
                let closed = await controller.disconnect(force: true)
                XCTAssertFalse(closed)
            }
            XCTAssertTrue(supervisor.signal(SIGCONT))
            try await Self.waitForExit(supervisor)
            if let control {
                try await control.close()
            } else {
                let closed = await controller.disconnect(force: true)
                XCTAssertTrue(closed)
            }
        }
    }

    @MainActor
    func testSettingsControlClosesWhenAppQuitIsAbortedAndCanBeReopened() async throws {
        let settings = AppSettings()
        let profile = RuntimeAgentProfile.customACP(
            name: "Synthetic ACP", executablePath: "/usr/bin/python3",
            arguments: ["-u", fakeACPURL.path, "--require-auth", "--v1-extended"]
        )
        settings.acpAgents = [profile]
        let control = try await settings.openACPControl(agentID: profile.id)
        let initial = await control.authentication
        XCTAssertFalse(initial.methods.isEmpty)
        XCTAssertTrue(initial.canLogout)
        let eventsEnded = LockedBox(false)
        let consumer = Task {
            for await _ in control.events {}
            eventsEnded.withValue { $0 = true }
        }
        defer { consumer.cancel() }

        settings.beginAuthenticationShutdown()
        let cleaned = await settings.stopAndConfirmAuthenticationCleanup()
        XCTAssertTrue(cleaned)
        settings.resumeAuthentication()
        try await Self.waitForEndOfEvents(eventsEnded)
        let revoked = await control.authentication
        XCTAssertTrue(revoked.methods.isEmpty)
        XCTAssertFalse(revoked.canLogout)

        let reopened = try await settings.openACPControl(agentID: profile.id)
        let fresh = await reopened.authentication
        XCTAssertNotEqual(initial.connectionID, fresh.connectionID)
        XCTAssertFalse(fresh.methods.isEmpty)
        XCTAssertTrue(fresh.canLogout)
        try await settings.closeACPAuthenticationControl(reopened)
    }

    @MainActor
    func testSettingsCannotReopenOrExitWithUnconfirmedControlCleanup() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let gate = dir.appendingPathComponent("allow-failure")
        let receipt = dir.appendingPathComponent("wire.jsonl")
        try Data().write(to: marker)
        let profile = RuntimeAgentProfile.customACP(
            name: "Synthetic ACP", executablePath: "/usr/bin/python3",
            arguments: ["-u", fakeACPURL.path, "--receipt-path", receipt.path,
                        "--terminal-auth-state", marker.path, "--terminal-reconnect-gate", gate.path,
                        "--fail-terminal-reconnect"]
        )
        let settings = AppSettings()
        settings.acpAgents = [profile]
        let opening = Task { try await settings.openACPControl(agentID: profile.id) }
        defer { opening.cancel() }
        let supervisor = try await Self.initializedSupervisor(receipt, attempt: 1)
        guard supervisor.parent == getpid(), supervisor.signal(SIGSTOP) else { throw CocoaError(.fileNoSuchFile) }
        defer { _ = supervisor.signal(SIGCONT) }
        try Data().write(to: gate)
        guard case .failure(let error) = await opening.result else { return XCTFail("Failed handshake returned a connection") }
        XCTAssertEqual((error as? RuntimeFailure)?.kind, .supervision)
        XCTAssertTrue(settings.hasAuthenticationControl)
        do {
            _ = try await settings.openACPControl(agentID: profile.id)
            XCTFail("Retry started a second control before cleanup")
        } catch let error as RuntimeFailure { XCTAssertEqual(error.kind, .supervision) }
        let wire = try String(contentsOf: receipt, encoding: .utf8)
        XCTAssertEqual(wire.components(separatedBy: #""initialize""#).count - 1, 1)
        settings.beginAuthenticationShutdown()
        let blocked = await settings.stopAndConfirmAuthenticationCleanup()
        XCTAssertFalse(blocked)
        XCTAssertTrue(supervisor.signal(SIGCONT))
        try await Self.waitForExit(supervisor)
        let closed = await settings.stopAndConfirmAuthenticationCleanup()
        XCTAssertTrue(closed)
        XCTAssertFalse(settings.hasAuthenticationControl)
    }

    func testTerminalLaunchConsentIncludesEveryEnvironmentOverride() {
        let location = URL(fileURLWithPath: "/")
        for changes in [[:], ["NODE_TLS_REJECT_UNAUTHORIZED": "0"], ["CUSTOM": ""]] {
            let launch = RuntimeTerminalAuthenticationLaunch(
                name: "Fixture", executable: location, workingDirectory: location,
                arguments: [], environment: changes, appendedArguments: [], environmentOverrides: changes
            )
            XCTAssertEqual(launch.requiresEnvironmentConsent, !changes.isEmpty)
        }
    }

    @MainActor
    func testTerminalCleanupFailureBlocksSettingsAndSessionUntilConfirmed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let config = fakeConfig(workspace: dir, extraArgs: ["--terminal-auth-state", marker.path])
        let clean = LockedBox(false)
        let failure = RuntimeFailure(.supervision, "Fixture terminal cleanup unconfirmed")
        let login: RuntimeTerminalAuthenticator = { _ in
            throw RuntimeTerminalCleanupPending(failure: failure) { clean.value }
        }

        let control = try await ACPAgentConnection.open(config, terminalAuthenticator: login)
        do {
            try await control.authenticate(methodID: "terminal-login")
            XCTFail("A missing clean report cannot authenticate")
        } catch let error as RuntimeFailure { XCTAssertEqual(error, failure) }
        let connected = await control.isConnected
        XCTAssertFalse(connected)
        do {
            try await control.close()
            XCTFail("Closing settings cannot discard terminal cleanup")
        } catch let error as RuntimeFailure { XCTAssertEqual(error, failure) }

        let runtime = ACPRuntime(configuration: config, terminalAuthenticator: login)
        let controller = SessionController()
        let connecting = Task { await controller.connect(runtime) }
        defer { connecting.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.interactions.isEmpty, .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let choice = try XCTUnwrap(controller.interactions.first)
        _ = await controller.reply(choice, .value("terminal-login"))
        await connecting.value
        XCTAssertEqual(controller.connection, .blocked)
        let forced = await controller.disconnect(force: true)
        XCTAssertFalse(forced)
        XCTAssertEqual(controller.connection, .blocked)

        clean.withValue { $0 = true }
        try await control.close()
        let recovered = await controller.disconnect(force: true)
        XCTAssertTrue(recovered)
        XCTAssertEqual(controller.connection, .disconnected)
    }

    func testAgentLoginAndLogoutCapabilityOnControlConnection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("signed-in")
        let config = fakeConfig(workspace: dir, extraArgs: ["--require-auth", "--v1-extended", "--terminal-auth-state", marker.path])
        let control = try await ACPAgentConnection.open(config)
        let authentication = await control.authentication
        XCTAssertTrue(authentication.canLogout)
        XCTAssertFalse(authentication.methods.contains(where: { $0.kind == .terminal }))
        try await control.authenticate(methodID: "oauth-browser")
        _ = try await control.list(cursor: nil)
        try await control.logout()
        do {
            _ = try await control.list(cursor: nil)
            XCTFail("Listing should require authentication after logout")
        } catch let error as RuntimeFailure {
            XCTAssertEqual(error.kind, .authentication)
        }
        try await control.close()
    }

    // MARK: - ACPConfiguration Tests

    func testConfigurationEnvironmentOverlayProxyAndSearchPaths() throws {
        let executable = URL(fileURLWithPath: "/opt/acp/bin/agy")
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        var config = ACPConfiguration(
            executable: executable,
            arguments: ["acp"],
            workspace: workspace,
            environmentOverrides: ["https_proxy": "", "CUSTOM_FLAG": "value=1"],
            proxy: "http://proxy.example:8080",
            toolSearchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        )

        let inherited = ["https_proxy": "http://stale.example:9090", "PATH": "/usr/bin:/bin", "KEEP": "yes"]
        let env = try config.launchEnvironment(inheriting: inherited)
        XCTAssertNil(env["https_proxy"])
        XCTAssertEqual(env["HTTPS_PROXY"], "")
        XCTAssertEqual(env["HTTP_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(env["NODE_USE_ENV_PROXY"], "1")
        XCTAssertEqual(env["CUSTOM_FLAG"], "value=1")
        XCTAssertEqual(env["KEEP"], "yes")
        XCTAssertEqual(env["PATH"], "/opt/acp/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")

        config.launchProxyOverride = "http://override.example:8888"
        let overridden = try config.launchEnvironment(inheriting: inherited)
        XCTAssertEqual(overridden["HTTPS_PROXY"], "http://override.example:8888")
        XCTAssertEqual(overridden["HTTP_PROXY"], "http://override.example:8888")

        config.launchProxyOverride = nil
        for invalid in [["HTTP_PROXY": "a", "http_proxy": "b"], ["PATH": "/bad"], ["BAD KEY": "1"], ["OK": "null\0byte"]] {
            config.environmentOverrides = invalid
            XCTAssertThrowsError(try config.launchEnvironment(inheriting: inherited))
        }
        config.environmentOverrides = nil
        XCTAssertThrowsError(try config.launchEnvironment(inheriting: inherited))

        config.environmentOverrides = [:]
        for badPath in ["", "relative/bin", "/bad:path", "/null\0path"] {
            config.toolSearchPaths = [badPath]
            XCTAssertThrowsError(try config.launchEnvironment(inheriting: inherited))
        }
    }

    func testDetectedAntigravityPathSearchesStandardAndPATHLocations() throws {
        let root = try makeTempDir(prefix: "zivvi-agy-detect")
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        let localBin = fakeHome.appendingPathComponent(".local/bin", isDirectory: true)
        let pathBin = root.appendingPathComponent("custom-path", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)

        // When nothing exists in temp home or PATH (skipping real machine's /opt/homebrew/bin if present)
        let pathAgy = pathBin.appendingPathComponent("agy")
        try "#!/bin/sh\nexit 0\n".write(to: pathAgy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathAgy.path)

        let localAgy = localBin.appendingPathComponent("agy")
        try "#!/bin/sh\nexit 0\n".write(to: localAgy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localAgy.path)

        // ~/.local/bin has highest priority over /opt/homebrew/bin and PATH
        let detected = ACPConfiguration.detectedAntigravityPath(
            environment: ["PATH": pathBin.path],
            homeDirectory: fakeHome
        )
        XCTAssertEqual(detected, localAgy.path)

        // Non-executable file in ~/.local/bin must be skipped
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localAgy.path)
        let fallbackDetected = ACPConfiguration.detectedAntigravityPath(
            environment: ["PATH": pathBin.path],
            homeDirectory: fakeHome
        )
        XCTAssertNotEqual(fallbackDetected, localAgy.path)
    }

    // MARK: - ACPProtocol Parsing Tests

    func testInitializeAndMetadataParsingSupportsConfigOptionsAndLegacyFallback() {
        let initRecord: Record = [
            "protocolVersion": 1,
            "agentInfo": ["name": "antigravity", "title": "Antigravity CLI", "version": "2.0.0"],
            "agentCapabilities": [
                "loadSession": true,
                "promptCapabilities": ["image": true, "audio": false, "embeddedContext": true],
                "mcpCapabilities": ["http": true, "sse": false]
            ],
            "authMethods": [["id": "browser", "name": "Browser", "description": "Run agy acp --login"]]
        ]
        let parsedInit = ACPInitializeResult.parse(initRecord)
        XCTAssertEqual(parsedInit?.protocolVersion, 1)
        XCTAssertEqual(parsedInit?.agentInfo?.displayName, "Antigravity CLI")
        XCTAssertEqual(parsedInit?.agentCapabilities.loadSession, true)
        XCTAssertEqual(parsedInit?.agentCapabilities.promptCapabilities.image, true)
        XCTAssertEqual(parsedInit?.authMethods.count, 1)
        XCTAssertNil(ACPInitializeResult.parse(["agentInfo": ["name": "no-version"]]))

        let groupedRecord: Record = [
            "configOptions": [
                [
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "vendor/model-a",
                    "options": [
                        [
                            "group": "g1",
                            "name": "Primary",
                            "options": [
                                ["value": "vendor/model-a", "name": "Model A"],
                                ["value": "vendor/model-b", "name": "Model B"]
                            ]
                        ]
                    ]
                ],
                [
                    "id": "thought",
                    "name": "Reasoning",
                    "category": "thought_level",
                    "type": "select",
                    "currentValue": "high",
                    "options": [
                        ["value": "low", "name": "Low"],
                        ["value": "high", "name": "High"]
                    ]
                ]
            ]
        ]
        let meta = ACPSessionMetadata.parse(groupedRecord)
        XCTAssertEqual(meta.currentModelID(), "vendor/model-a")
        XCTAssertEqual(meta.currentModelDisplayName(fallback: "Default"), "Model A")
        XCTAssertEqual(meta.availableRuntimeModels(defaultProvider: "antigravity").map(\.modelID), ["vendor/model-a", "vendor/model-b"])
        XCTAssertEqual(meta.availableThinkingLevels(), ["low", "high"])
        XCTAssertEqual(meta.currentThinkingLevel(), "high")

        let legacyRecord: Record = [
            "modes": [
                "currentModeId": "default",
                "availableModes": [["id": "default", "name": "Default"], ["id": "plan", "name": "Plan"]]
            ],
            "models": [
                "currentModelId": "gemini-2.5-pro",
                "availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]]
            ]
        ]
        let legacyMeta = ACPSessionMetadata.parse(legacyRecord)
        XCTAssertEqual(legacyMeta.currentModeID(), "default")
        XCTAssertEqual(legacyMeta.availableModesList().map(\.id), ["default", "plan"])
        XCTAssertEqual(legacyMeta.currentModelID(), "gemini-2.5-pro")
        XCTAssertEqual(legacyMeta.availableRuntimeModels(defaultProvider: "agy").first?.name, "Gemini 2.5 Pro")
    }

    // MARK: - ACPEventMapper Tests

    func testEventMapperStreamsTextSeparatesThoughtMapsNativeDiffAndPlan() throws {
        var mapper = ACPEventMapper()

        // Thought chunk must not mix into assistant body text.
        let thought = mapper.mapSessionUpdate([
            "sessionUpdate": "agent_thought_chunk",
            "content": ["type": "text", "text": "Internal reasoning step"]
        ])
        XCTAssertEqual(thought.events.count, 1)
        if case .thought(let value) = thought.events[0] {
            XCTAssertEqual(value, "Internal reasoning step")
        } else {
            XCTFail("Expected thought event for thought chunk")
        }

        // Streaming assistant text chunks
        let chunk1 = mapper.mapSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Hello "]
        ])
        XCTAssertEqual(chunk1.events.count, 2)
        guard case .assistantStarted(let firstID) = chunk1.events[0],
              case .textDelta(let deltaID, 0, "Hello ") = chunk1.events[1] else {
            return XCTFail("Expected assistantStarted + textDelta")
        }
        XCTAssertEqual(firstID, deltaID)

        let chunk2 = mapper.mapSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "world"]
        ])
        XCTAssertEqual(chunk2.events.count, 1)
        if case .textDelta(let id, 0, "world") = chunk2.events[0] {
            XCTAssertEqual(id, firstID)
        } else {
            XCTFail("Expected textDelta on same assistant ID")
        }

        // Tool call with native diff flushes active assistant message first and populates EditArguments
        let toolStart = mapper.mapSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-1",
            "title": "Edit Demo.swift",
            "kind": "edit",
            "status": "in_progress",
            "rawInput": ["path": "Sources/Demo.swift"]
        ])
        XCTAssertEqual(toolStart.events.count, 2)
        if case .assistantCompleted(let completedID, let text) = toolStart.events[0] {
            XCTAssertEqual(completedID, firstID)
            XCTAssertEqual(text, "Hello world")
        } else {
            XCTFail("Expected active assistant flush before tool call")
        }

        let toolUpdate = mapper.mapSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-1",
            "status": "completed",
            "content": [
                ["type": "content", "content": ["type": "text", "text": "Edited file"]],
                ["type": "diff", "path": "Sources/Demo.swift", "oldText": "let a = 1\n", "newText": "let a = 2\n"]
            ]
        ])
        guard case .tool(let tool) = try XCTUnwrap(toolUpdate.events.first) else {
            return XCTFail("Expected tool event")
        }
        XCTAssertEqual(tool.name, "edit")
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(tool.output, "Edited file")
        XCTAssertEqual(tool.editArguments?.path, "Sources/Demo.swift")
        XCTAssertEqual(tool.editArguments?.edits.first?.oldText, "let a = 1\n")
        XCTAssertEqual(tool.editArguments?.edits.first?.newText, "let a = 2\n")

        // Plan update
        let plan = mapper.mapSessionUpdate([
            "sessionUpdate": "plan",
            "entries": [
                ["content": "Inspect", "status": "completed"],
                ["content": "Patch", "status": "in_progress"]
            ]
        ])
        if case .plan(let entries) = plan.events.first {
            XCTAssertEqual(entries.map(\.content), ["Inspect", "Patch"])
            XCTAssertEqual(entries.map(\.status), [.completed, .inProgress])
        } else {
            XCTFail("Expected plan event")
        }

        // Mode update populates metadata without polluting extensionStatus
        let modeUpdate = mapper.mapSessionUpdate([
            "sessionUpdate": "current_mode_update",
            "currentModeId": "auto"
        ])
        XCTAssertEqual(modeUpdate.metadata.currentModeID, "auto")
        XCTAssertTrue(modeUpdate.events.isEmpty)

        // Usage update preserves nil fields and does not fabricate zero
        let usageUpdate = mapper.mapSessionUpdate([
            "sessionUpdate": "usage_update",
            "used": 1000,
            "size": 100000,
            "cost": ["amount": 0.05, "currency": "USD"]
        ])
        XCTAssertNotNil(usageUpdate.metadata.usage)
        let usage = ACPEventMapper.runtimeUsage(sessionID: "s1", snapshot: mapper.latestUsage, promptUsage: nil)
        XCTAssertNil(usage.tokens.input)
        XCTAssertNil(usage.tokens.output)
        XCTAssertEqual(usage.context?.tokens, 1000)
        XCTAssertEqual(usage.context?.window, 100000)
        XCTAssertEqual(usage.estimatedCostUSD, 0.05)

        // Live user_message_chunk must be ignored to avoid duplicating local user row
        let liveEcho = mapper.mapSessionUpdate([
            "sessionUpdate": "user_message_chunk",
            "content": ["type": "text", "text": "echoed user input"]
        ])
        XCTAssertTrue(liveEcho.events.isEmpty)

        // Finish turn clears thought status and settles
        let settled = mapper.finishTurn(stopReason: .endTurn)
        XCTAssertTrue(settled.contains { if case .thought(nil) = $0 { return true }; return false })
        XCTAssertTrue(settled.contains { if case .settled(aborted: false) = $0 { return true }; return false })
    }

    func testEventMapperReplayModeIsolatesHistoryAndBoundsToolPayloads() {
        var mapper = ACPEventMapper()
        mapper.beginHistoryReplay()

        XCTAssertTrue(mapper.mapSessionUpdate([
            "sessionUpdate": "user_message_chunk",
            "content": ["type": "text", "text": "Hello "]
        ]).events.isEmpty)
        XCTAssertTrue(mapper.mapSessionUpdate([
            "sessionUpdate": "user_message_chunk",
            "content": ["type": "text", "text": "agent"]
        ]).events.isEmpty)
        XCTAssertTrue(mapper.mapSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "t1",
            "title": "Run tests",
            "kind": "execute",
            "status": "in_progress"
        ]).events.isEmpty)
        let giantOutput = String(repeating: "z", count: 100_000)
        XCTAssertTrue(mapper.mapSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": giantOutput]]]
        ]).events.isEmpty)
        XCTAssertTrue(mapper.mapSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "All green."]
        ]).events.isEmpty)

        let items = mapper.finishHistoryReplay()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .user)
        XCTAssertEqual(items[0].text, "Hello agent")
        XCTAssertEqual(items[1].kind, .tool)
        XCTAssertEqual(items[1].tool?.state, .completed)
        XCTAssertEqual(items[1].tool?.output.count, ACPEventMapper.maximumOutputLength)
        XCTAssertEqual(items[1].tool?.truncated, true)
        XCTAssertEqual(items[2].kind, .assistant)
        XCTAssertEqual(items[2].text, "All green.")
    }

    func testReplayKeepsAdjacentUserMessagesAndTheirImagesSeparate() throws {
        let image = Data([1, 2, 3])
        var mapper = ACPEventMapper()
        mapper.beginHistoryReplay()
        let chunks: [(String, Record)] = [
            ("first", ["type": "text", "text": "First"]),
            ("first", ["type": "image", "mimeType": "image/png", "data": image.base64EncodedString()]),
            ("second", ["type": "text", "text": "Second"]),
        ]
        for (id, content) in chunks {
            let update = mapper.mapSessionUpdate(["sessionUpdate": "user_message_chunk", "messageId": id, "content": content])
            XCTAssertTrue(update.events.isEmpty)
        }
        let items = mapper.finishHistoryReplay()
        XCTAssertEqual(items.map(\.text), ["First", "Second"])
        XCTAssertEqual(items.map(\.images), [[image], nil])
        XCTAssertEqual(try JSONDecoder().decode([HistoryItem].self, from: JSONEncoder().encode(items)), items)
        let oldItem = #"{"id":"old","kind":"assistant","text":"Legacy reply"}"#
        XCTAssertNil(try JSONDecoder().decode(HistoryItem.self, from: Data(oldItem.utf8)).images)
    }

    func testToolContentReplacementClearsOutputImageAndDiff() throws {
        var mapper = ACPEventMapper()
        let image = Data([1, 2, 3])
        let previousContent: [Record] = [
            ["type": "content", "content": ["type": "text", "text": String(repeating: "x", count: ACPEventMapper.maximumOutputLength + 1)]],
            ["type": "content", "content": ["type": "image", "mimeType": "image/png", "data": image.base64EncodedString()]],
            ["type": "diff", "path": "Sources/Example.swift", "oldText": "old", "newText": "new"],
        ]

        func tool(from events: [AgentEvent]) throws -> RuntimeTool {
            try XCTUnwrap(events.compactMap { event in
                if case .tool(let tool) = event { return tool }
                return nil
            }.last)
        }

        let start = mapper.mapSessionUpdate(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run",
                                             "kind": "execute", "status": "in_progress", "content": previousContent,
                                             "rawInput": ["command": "fixture command"]])
        let original = try tool(from: start.events)
        XCTAssertEqual(original.output.count, ACPEventMapper.maximumOutputLength)
        XCTAssertEqual(original.outputImage, image)
        XCTAssertNotNil(original.editArguments)
        XCTAssertEqual(original.name, "edit")
        XCTAssertTrue(original.truncated)

        let complete = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"])
        let retained = try tool(from: complete.events)
        XCTAssertEqual(retained.output, original.output)
        XCTAssertEqual(retained.editArguments, original.editArguments)
        XCTAssertEqual(retained.outputImage, image)

        let nullPatch = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1",
                                                "content": NSNull(), "rawInput": NSNull(), "rawOutput": NSNull()])
        XCTAssertEqual(try tool(from: nullPatch.events), retained)

        let replace = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1",
                                              "content": [["type": "content", "content": ["type": "text", "text": "New"]]]])
        let replacement = try tool(from: replace.events)
        XCTAssertEqual(replacement.state, .completed)
        XCTAssertEqual(replacement.output, "New")
        XCTAssertNil(replacement.outputImage)
        XCTAssertNil(replacement.editArguments)
        XCTAssertFalse(replacement.truncated)
        XCTAssertEqual(replacement.name, "bash")
        XCTAssertTrue(replacement.arguments.contains("fixture command"))

        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "content": previousContent])
        let clear = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "content": [Record]()])
        let cleared = try tool(from: clear.events)
        XCTAssertEqual(cleared.state, .completed)
        XCTAssertTrue(cleared.output.isEmpty)
        XCTAssertNil(cleared.outputImage)
        XCTAssertNil(cleared.editArguments)
        XCTAssertFalse(cleared.truncated)

        let outputs: [(Any, String)] = [(42, "42"), (false, "false"), ("", "")]
        for (value, text) in outputs {
            let raw = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "rawOutput": value])
            XCTAssertEqual(try tool(from: raw.events).output, text)
        }
    }

    func testReplacingRawToolInputClearsDerivedPathAndRestoresTitleSummaryInLiveAndReplay() throws {
        var live = ACPEventMapper()
        var replay = ACPEventMapper()
        replay.beginHistoryReplay()

        func send(_ update: Record) throws -> RuntimeTool {
            let liveUpdate = live.mapSessionUpdate(update)
            XCTAssertTrue(replay.mapSessionUpdate(update).events.isEmpty)
            return try XCTUnwrap(liveUpdate.events.compactMap { event in
                if case .tool(let tool) = event { return tool }
                return nil
            }.last)
        }

        let initial = try send(["sessionUpdate": "tool_call", "toolCallId": "write-1", "title": "write",
                                "rawInput": ["path": "old.swift", "summary": "Old operation"]])
        XCTAssertEqual(initial.writePath, "old.swift")
        XCTAssertEqual(initial.summary, "Old operation")

        let titleUpdate = try send(["sessionUpdate": "tool_call_update", "toolCallId": "write-1", "title": " New title ",
                                    "rawInput": NSNull()])
        XCTAssertEqual(titleUpdate.writePath, "old.swift")
        XCTAssertEqual(titleUpdate.summary, "Old operation")

        let replaced = try send(["sessionUpdate": "tool_call_update", "toolCallId": "write-1", "rawInput": Record()])
        XCTAssertNil(replaced.writePath)
        XCTAssertFalse(replaced.arguments.contains("old.swift"))
        XCTAssertEqual(replaced.summary, "New title")

        let clearedTitle = try send(["sessionUpdate": "tool_call_update", "toolCallId": "write-1", "title": "write",
                                     "rawInput": ""])
        XCTAssertNil(clearedTitle.summary)
        XCTAssertTrue(clearedTitle.arguments.isEmpty)

        let renamed = try send(["sessionUpdate": "tool_call_update", "toolCallId": "write-1", "title": "Latest title",
                                "locations": [["path": "fallback.swift"]]])
        XCTAssertTrue(renamed.arguments.isEmpty)
        XCTAssertNil(renamed.writePath)
        XCTAssertEqual(renamed.summary, "Latest title")
        XCTAssertEqual(replay.finishHistoryReplay().first?.tool, renamed)
    }

    func testEmbeddedImageLimitIsAppliedToDecodedBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image.png")
        let atLimit = Data(repeating: 37, count: 8 * 1_024 * 1_024)
        try atLimit.write(to: file)
        let outbound = try XCTUnwrap(ACPConnection.encodeImageBlock(file))
        XCTAssertEqual(ACPJSON.imageDataFromContentBlock(outbound), atLimit)
        var oversized = outbound
        oversized["data"] = (atLimit + Data([37])).base64EncodedString()
        XCTAssertNil(ACPJSON.imageDataFromContentBlock(oversized))
    }

    func testToolContentClearKeepsInputEditsDuringReplay() throws {
        var mapper = ACPEventMapper()
        mapper.beginHistoryReplay()
        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call", "toolCallId": "edit", "kind": "edit", "status": "completed",
                                     "rawInput": ["path": "input.swift", "oldText": "before", "newText": "after"],
                                     "content": [["type": "diff", "path": "output.swift", "newText": "result"]]])
        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "content": [Record]()])
        let items = mapper.finishHistoryReplay()
        XCTAssertEqual(items.count, 1)
        let tool = try XCTUnwrap(items.first?.tool)
        XCTAssertEqual(tool.state, .completed)
        XCTAssertEqual(tool.editArguments?.path, "input.swift")
    }

    func testClearingResultDoesNotRestoreReplacedEditArguments() throws {
        var mapper = ACPEventMapper()
        mapper.beginHistoryReplay()
        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call", "toolCallId": "edit", "kind": "edit", "status": "completed",
                                     "rawInput": ["path": "old-input.swift", "oldText": "before", "newText": "after"]])
        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "rawInput": Record(),
                                     "content": [["type": "diff", "path": "output.swift", "newText": "result"]]])
        _ = mapper.mapSessionUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "content": [Record]()])
        let tool = try XCTUnwrap(mapper.finishHistoryReplay().first?.tool)
        XCTAssertNil(tool.editArguments)
        XCTAssertTrue(tool.output.isEmpty)
    }

    func testEventMapperStopReasonsAndSanitizedErrors() {
        var mapper = ACPEventMapper()
        let cancelled = mapper.finishTurn(stopReason: .cancelled)
        XCTAssertTrue(cancelled.contains { if case .settled(aborted: true) = $0 { return true }; return false })

        let maxTokens = mapper.finishTurn(stopReason: .maxTokens)
        XCTAssertTrue(maxTokens.contains { if case .notice = $0 { return true }; return false })
        XCTAssertTrue(maxTokens.contains { if case .settled(aborted: false) = $0 { return true }; return false })

        let refusal = mapper.finishTurn(stopReason: .refusal)
        XCTAssertTrue(refusal.contains { if case .failure(let f) = $0 { return f.kind == .model }; return false })

        let authErr = ACPEventMapper.failure(from: ACPJSONRPCError(code: -32000, message: "401 Bearer sk-secret-token"))
        XCTAssertEqual(authErr.kind, .authentication)
        XCTAssertFalse(authErr.detail.contains("secret"))
    }

    func testEventMapperOnlySettlesFailuresWithConfirmedOutcomes() {
        var mapper = ACPEventMapper()
        let kinds: [RuntimeFailureKind] = [.protocolError, .outcomeUnknown, .connection, .supervision, .unsupportedInteraction, .model]
        for kind in kinds {
            let failure = RuntimeFailure(kind, "Prompt response failed")
            let events = mapper.finishTurnWithError(failure)
            XCTAssertTrue(events.contains { if case .failure(let reported) = $0 { return reported == failure }; return false })
            let settled = events.contains { if case .settled = $0 { return true }; return false }
            XCTAssertEqual(settled, kind == .model, "Unexpected settlement for \(kind)")
        }
    }

    // MARK: - ACPInteractionBroker Tests

    func testInteractionBrokerPreservesRawIDTypesIsSingleClaimAndHandlesExpiry() throws {
        let instanceID = UUID()
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let events = LockedBox<[AgentEvent]>([])
        let broker = ACPInteractionBroker(
            instanceID: instanceID,
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )

        let options: [Record] = [
            ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "reject_once", "name": "Reject", "kind": "reject_once"]
        ]
        let toolCall: Record = [
            "toolCallId": "edit-1",
            "title": "Edit main.swift",
            "kind": "edit",
            "locations": [["path": "Sources/main.swift"]],
            "content": [["type": "diff", "path": "Sources/main.swift", "oldText": "a", "newText": "b"]]
        ]

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Integer ID 7 and String ID "7" must not collide.
        try broker.accept(JSONRPCRequest(id: .int(7), method: "session/request_permission", params: ["toolCall": toolCall, "options": options], paramsJSON: nil, raw: [:]), workingDirectory: "/repo", now: now)
        try broker.accept(JSONRPCRequest(id: .string("7"), method: "session/request_permission", params: ["toolCall": toolCall, "options": options], paramsJSON: nil, raw: [:]), workingDirectory: "/repo", now: now)

        XCTAssertEqual(broker.pendingCount, 2)
        let emittedInteractions = events.value.compactMap { event -> RuntimeInteraction? in
            if case .interaction(let req) = event { return req }
            return nil
        }
        XCTAssertEqual(emittedInteractions.count, 2)
        XCTAssertEqual(emittedInteractions[0].permissionContext?.fileDiffs.first?.path, "Sources/main.swift")
        XCTAssertEqual(emittedInteractions[0].permissionContext?.paths, ["Sources/main.swift"])

        // Answer integer ID with allow_once; second reply must be rejected without writing again.
        try broker.respond(emittedInteractions[0], .permissionOption("allow_once"), now: now.addingTimeInterval(1))
        XCTAssertThrowsError(try broker.respond(emittedInteractions[0], .cancelled, now: now.addingTimeInterval(2)))

        // Expire string ID "7" after 301 seconds -> sends cancelled outcome preserving .string("7").
        try broker.expire(now: now.addingTimeInterval(301))
        XCTAssertEqual(broker.pendingCount, 0)

        let recorded = replies.value
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0].0, .int(7))
        let outcome0 = recorded[0].1["outcome"] as? Record
        XCTAssertEqual(outcome0?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome0?["optionId"] as? String, "allow_once")

        XCTAssertEqual(recorded[1].0, .string("7"))
        let outcome1 = recorded[1].1["outcome"] as? Record
        XCTAssertEqual(outcome1?["outcome"] as? String, "cancelled")
    }

    func testInteractionBrokerPublishesEveryExpiryInOrderBeforeWritingReplies() throws {
        let events = LockedBox<[AgentEvent]>([])
        let eventsAtFirstReply = LockedBox<[AgentEvent]>([])
        let replyIDs = LockedBox<[JSONRPCID]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, _ in
                replyIDs.withValue { $0.append(id) }
                eventsAtFirstReply.withValue { $0 = events.value }
                throw CocoaError(.fileWriteUnknown)
            },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interactionIDs: [JSONRPCID] = [.int(7), .int(2), .int(1)]
        for (index, id) in interactionIDs.enumerated() {
            let request = JSONRPCRequest(
                id: id, method: "session/request_permission", params: [
                    "toolCall": ["toolCallId": "pending", "title": "Check", "kind": "execute",
                                 "rawInput": ["command": "pwd"]],
                    "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
                ], paramsJSON: nil, raw: [:]
            )
            try broker.accept(request, now: start.addingTimeInterval(index == 2 ? 5 : 0))
        }
        let idsInArrivalOrder = events.value.compactMap { event -> String? in
            if case .interaction(let interaction) = event { return interaction.id }
            return nil
        }
        guard idsInArrivalOrder.count == 3 else { return XCTFail("Expected all pending requests") }
        let sortedIDs = [idsInArrivalOrder[1], idsInArrivalOrder[0], idsInArrivalOrder[2]]

        XCTAssertThrowsError(try broker.expire(now: start.addingTimeInterval(310)))
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(replyIDs.value, [.int(2)])
        let expiredIDsAtFirstReply = eventsAtFirstReply.value.compactMap { event -> String? in
            if case .interactionEnded(let id, .expired) = event { return id }
            return nil
        }
        XCTAssertEqual(expiredIDsAtFirstReply, sortedIDs)
    }

    func testExecutePermissionExposesOriginalCommandWithoutChangingReplyOptions() throws {
        let replies = LockedBox<[Record]>([])
        let events = LockedBox<[AgentEvent]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { _, payload in replies.withValue { $0.append(payload) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let command = "  printf 'fixture'\n"
        let options: [Record] = [
            ["optionId": "execute-this-command", "name": "Allow", "kind": "allow_once"],
            ["optionId": "skip-command", "name": "Deny", "kind": "reject_once"]
        ]
        let toolCall: Record = [
            "title": "Run a command",
            "name": "run_command",
            "kind": "execute",
            "args": ["CommandLine": "printf unrelated", "Cwd": "/unrelated", "toolSummary": "Ignore"],
            "rawInput": ["CommandLine": command, "Cwd": "/actual", "toolSummary": "Inspect /actual", "WaitMsBeforeAsync": 5000,
                         "extra": ["nested": true]]
        ]
        let now = Date(timeIntervalSince1970: 100)
        try broker.accept(JSONRPCRequest(id: .int(1), method: "session/request_permission",
                                         params: ["toolCall": toolCall, "options": options], paramsJSON: nil, raw: [:]),
                          workingDirectory: "/session", now: now)

        guard case .interaction(let request)? = events.value.first else { return XCTFail("Missing permission request") }
        XCTAssertEqual(request.toolApproval, .init(workingDirectory: "/actual", operation: .command(text: command, timeoutSeconds: nil)))
        XCTAssertEqual(request.permissionContext?.sessionDirectory, "/session")
        XCTAssertEqual(request.permissionContext?.toolName, "run_command")
        XCTAssertEqual(request.permissionContext?.toolSummary, "Inspect /actual")
        XCTAssertNil(request.permissionContext?.summary)
        XCTAssertEqual(request.expiresAt.timeIntervalSince(now), ACPInteractionBroker.defaultTimeoutSeconds)
        let json = try XCTUnwrap(request.permissionContext?.rawInputJSON)
        XCTAssertTrue(json.contains(#""/actual""#))
        XCTAssertFalse(json.contains(#"\/actual"#))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? Record)
        XCTAssertEqual(decoded["WaitMsBeforeAsync"] as? Int, 5000)
        XCTAssertEqual(decoded["CommandLine"] as? String, command)
        XCTAssertEqual(decoded["extra"] as? [String: Bool], ["nested": true])
        XCTAssertEqual(request.permissionOptions.map(\.id), ["execute-this-command", "skip-command"])

        try broker.respond(request, .permissionOption("skip-command"), now: now)
        XCTAssertEqual((replies.value.first?["outcome"] as? Record)?["optionId"] as? String, "skip-command")
    }

    func testPermissionWaitsForMatchingToolDetailsAndCancelsWhenTheTargetChanges() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, response in replies.withValue { $0.append((id, response)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let now = Date()
        try broker.accept(JSONRPCRequest(id: .string("7"), method: "session/request_permission", params: [
            "sessionId": "session-a",
            "toolCall": ["toolCallId": "call-1"],
            "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"],
                        ["optionId": "d", "name": "Deny", "kind": "reject_once"]]
        ], paramsJSON: nil, raw: [:]), workingDirectory: "/fixture", now: now)
        guard case .interaction(let pending)? = events.value.first else { return XCTFail("Missing request") }
        XCTAssertEqual(pending.permissionContext?.awaitingToolDetails, true)
        XCTAssertThrowsError(try broker.respond(pending, .permissionOption("a"), now: now))
        XCTAssertEqual(broker.pendingCount, 1)

        let details: Record = [
            "sessionUpdate": "tool_call_update", "toolCallId": "call-1", "kind": "execute",
            "rawInput": ["command": "pwd"]
        ]
        broker.receiveToolUpdate(details, sessionID: "session-b")
        XCTAssertEqual(events.value.count, 1)
        broker.receiveToolUpdate(details, sessionID: "session-a")
        guard case .interactionUpdated(let ready)? = events.value.last else { return XCTFail("Missing updated request") }
        XCTAssertEqual(ready.id, pending.id)
        XCTAssertEqual(ready.expiresAt, pending.expiresAt)
        XCTAssertEqual(ready.permissionOptions, pending.permissionOptions)
        XCTAssertEqual(ready.toolApproval?.operation, .command(text: "pwd", timeoutSeconds: nil))

        broker.receiveToolUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "call-1",
                                  "status": "pending", "rawInput": NSNull()], sessionID: "session-a")
        XCTAssertEqual(replies.value.count, 0)
        broker.receiveToolUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "call-1",
                                  "rawInput": ["command": "ls"]], sessionID: "session-a")
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(replies.value.first?.0, .string("7"))
        XCTAssertEqual((replies.value.first?.1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        XCTAssertThrowsError(try broker.respond(ready, .permissionOption("a"), now: now))
        XCTAssertEqual(replies.value.count, 1)
    }

    func testClearingToolContentRevokesApprovalForThePreviousDiff() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[Record]>([])
        let broker = ACPInteractionBroker(instanceID: UUID(),
                                          sendResponse: { _, response in replies.withValue { $0.append(response) } },
                                          emit: { event in events.withValue { $0.append(event) } })
        let tool: Record = ["toolCallId": "edit", "kind": "edit", "title": "Edit file",
                            "content": [["type": "diff", "path": "/fixture/file.swift", "newText": "updated"]]]
        try broker.accept(.init(id: .string("approval"), method: "session/request_permission", params: [
            "sessionId": "session", "toolCall": tool,
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]), workingDirectory: "/fixture")
        guard case .interaction(let shown)? = events.value.first else { return XCTFail("Missing approval") }
        XCTAssertEqual(shown.permissionContext?.fileDiffs.count, 1)
        broker.receiveToolUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "edit",
                                  "content": NSNull()], sessionID: "session")
        XCTAssertEqual(broker.pendingCount, 1)
        broker.receiveToolUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "edit",
                                  "content": [Record]()], sessionID: "session")
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual((replies.value.first?["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        XCTAssertThrowsError(try broker.respond(shown, .permissionOption("allow")))
    }

    func testPermissionRejectsAllowUntilCommandOrFileDiffArrives() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let now = Date()
        let options: [Record] = [
            ["optionId": "a", "name": "Allow", "kind": "allow_once"],
            ["optionId": "d", "name": "Deny", "kind": "reject_once"]
        ]
        for (index, kind) in ["execute", "edit"].enumerated() {
            let id = JSONRPCID.int(index)
            let call: Record = ["toolCallId": kind]
            try broker.accept(.init(id: id, method: "session/request_permission", params: [
                "sessionId": "fixture", "toolCall": call, "options": options
            ], paramsJSON: nil, raw: [:]), now: now)
            guard case .interaction(let initial)? = events.value.last else { return XCTFail("Missing initial request") }
            let beforeReady: [Record] = [
                ["locations": [["path": "/fixture/file.txt"]]],
                ["kind": kind, "rawInput": [:] as Record],
                ["rawInput": ["toolSummary": "Update the fixture"]]
            ]
            for fields in beforeReady {
                var update = fields
                update["sessionUpdate"] = "tool_call_update"
                update["toolCallId"] = kind
                broker.receiveToolUpdate(update, sessionID: "fixture")
                guard case .interactionUpdated(let partial)? = events.value.last else {
                    return XCTFail("Missing partial update")
                }
                XCTAssertEqual(partial.permissionContext?.awaitingToolDetails, true)
                XCTAssertThrowsError(try broker.respond(partial, .permissionOption("a"), now: now))
                XCTAssertThrowsError(try broker.respond(partial, .confirmed(true), now: now))
                XCTAssertEqual(broker.pendingCount, 1)
            }
            XCTAssertEqual(replies.value.count, index)
            var update: Record = ["sessionUpdate": "tool_call_update", "toolCallId": kind]
            if kind == "execute" {
                update["rawInput"] = ["command": "pwd"]
            } else {
                update["content"] = [["type": "diff", "path": "/fixture/file.txt", "oldText": "", "newText": "updated"]]
            }
            broker.receiveToolUpdate(update, sessionID: "fixture")
            guard case .interactionUpdated(let ready)? = events.value.last else { return XCTFail("Missing operation") }
            XCTAssertEqual(ready.permissionContext?.awaitingToolDetails, false)
            XCTAssertEqual(ready.expiresAt, initial.expiresAt)
            XCTAssertEqual(ready.permissionOptions, initial.permissionOptions)
            try broker.respond(ready, .permissionOption("a"), now: now)
            XCTAssertEqual(replies.value.last?.0, id)
            XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["optionId"] as? String, "a")
        }

        for (index, response) in [InteractionResponse.permissionOption("d"), .cancelled].enumerated() {
            let id = JSONRPCID.int(index + 2)
            try broker.accept(.init(id: id, method: "session/request_permission", params: [
                "sessionId": "fixture", "options": options, "toolCall": ["toolCallId": "pending-\(index)", "kind": "edit"]
            ], paramsJSON: nil, raw: [:]), now: now)
            guard case .interaction(let waiting)? = events.value.last else { return XCTFail("Missing pending request") }
            XCTAssertEqual(waiting.permissionContext?.awaitingToolDetails, true)
            try broker.respond(waiting, response, now: now)
            XCTAssertEqual(replies.value.last?.0, id)
        }
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(replies.value.count, 4)
        XCTAssertEqual((replies.value[2].1["outcome"] as? Record)?["optionId"] as? String, "d")
        XCTAssertEqual((replies.value[3].1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
    }

    func testPendingApprovalPublishesByteDistinctPathChangesBeforeExpiry() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[JSONRPCID]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, _ in replies.withValue { $0.append(id) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let original = "/fixture/caf\u{00E9}.txt"
        let changed = "/fixture/cafe\u{0301}.txt"
        let rpcID = JSONRPCID.int(7)
        let now = Date()
        try broker.accept(.init(id: rpcID, method: "session/request_permission", params: [
            "sessionId": "session", "toolCall": [
                "toolCallId": "call", "kind": "execute", "locations": [["path": original]]
            ],
            "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]), now: now)
        guard case .interaction(let initial)? = events.value.last else { return XCTFail("Missing request") }
        let update: Record = ["sessionUpdate": "tool_call_update", "toolCallId": "call",
                              "locations": [["path": changed]]]
        broker.receiveToolUpdate(update, sessionID: "session")
        guard case .interactionUpdated(let current)? = events.value.last else {
            return XCTFail("Missing path update")
        }
        XCTAssertEqual(current.id, initial.id)
        XCTAssertEqual(current.expiresAt, initial.expiresAt)
        XCTAssertEqual(current.permissionContext?.awaitingToolDetails, true)
        XCTAssertEqual(current.permissionContext?.paths.map { Data($0.utf8) }, [Data(changed.utf8)])
        broker.receiveToolUpdate(update, sessionID: "session")
        XCTAssertEqual(events.value.count, 2)
        XCTAssertThrowsError(try broker.respond(current, .permissionOption("a"), now: now))
        XCTAssertTrue(replies.value.isEmpty)
        try broker.expire(now: initial.expiresAt)
        guard case .interactionEnded(let id, .expired)? = events.value.last else {
            return XCTFail("Missing expiry")
        }
        XCTAssertEqual(id, initial.id)
        XCTAssertEqual(replies.value, [rpcID])
        XCTAssertEqual(broker.pendingCount, 0)
    }

    func testSparseCommandPermissionWaitsForKindAndCommandInEitherOrder() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let now = Date()
        let command = "  printf 'fixture'\n"
        let sequences: [(Record, Record)] = [
            (["rawInput": ["command": command]], ["kind": "execute"]),
            (["kind": "execute"], ["rawInput": ["CommandLine": command]])
        ]
        for (index, sequence) in sequences.enumerated() {
            let callID = "call-\(index)"
            let rpcID = JSONRPCID.int(index)
            try broker.accept(.init(id: rpcID, method: "session/request_permission", params: [
                "sessionId": "fixture", "toolCall": ["toolCallId": callID],
                "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"]]
            ], paramsJSON: nil, raw: [:]), now: now)
            guard case .interaction(let initial)? = events.value.last else { return XCTFail("Missing initial request") }
            for (stage, fields) in [sequence.0, sequence.1].enumerated() {
                var update = fields
                update["sessionUpdate"] = "tool_call_update"
                update["toolCallId"] = callID
                broker.receiveToolUpdate(update, sessionID: "fixture")
                guard case .interactionUpdated(let current)? = events.value.last else {
                    return XCTFail("Missing tool detail update")
                }
                XCTAssertEqual(current.requestID, initial.requestID)
                XCTAssertEqual(current.expiresAt, initial.expiresAt)
                if stage == 0 {
                    XCTAssertEqual(current.permissionContext?.awaitingToolDetails, true)
                    XCTAssertNil(current.toolApproval)
                    XCTAssertThrowsError(try broker.respond(current, .permissionOption("a"), now: now))
                    XCTAssertThrowsError(try broker.respond(current, .confirmed(true), now: now))
                    XCTAssertEqual(replies.value.count, index)
                } else {
                    XCTAssertEqual(current.permissionContext?.awaitingToolDetails, false)
                    XCTAssertEqual(current.toolApproval?.operation, .command(text: command, timeoutSeconds: nil))
                    try broker.respond(current, .permissionOption("a"), now: now)
                    XCTAssertEqual(replies.value.last?.0, rpcID)
                    XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["optionId"] as? String, "a")
                }
            }
        }
        XCTAssertEqual(broker.pendingCount, 0)
    }

    func testApprovalCancelsOnlyTheMatchingRPCStringID() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let params: Record = [
            "toolCall": ["kind": "execute", "rawInput": ["command": "pwd"]],
            "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"]]
        ]
        let first = JSONRPCID.string("caf\u{00E9}")
        let second = JSONRPCID.string("cafe\u{0301}")
        for id in [first, second, second] {
            try broker.accept(.init(id: id, method: "session/request_permission", params: params, paramsJSON: nil, raw: [:]))
        }
        let requests = events.value.compactMap { event -> RuntimeInteraction? in
            if case .interaction(let request) = event { return request }
            return nil
        }
        XCTAssertEqual(requests.count, 2)
        let firstRequest = try XCTUnwrap(requests.first)
        let secondRequest = try XCTUnwrap(requests.last)
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)
        XCTAssertEqual(broker.pendingCount, 2)

        broker.cancel(second)
        broker.cancel(second)
        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertEqual(replies.value.map(\.0), [second])
        XCTAssertEqual((replies.value.first?.1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        XCTAssertThrowsError(try broker.respond(secondRequest, .permissionOption("a")))
        try broker.respond(firstRequest, .permissionOption("a"))
        XCTAssertEqual(replies.value.map(\.0), [second, first])
        XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["optionId"] as? String, "a")
        XCTAssertEqual(broker.pendingCount, 0)
    }

    func testPermissionCancelsWhenCommandOrEditChangesUTF8Bytes() throws {
        let events = LockedBox<[AgentEvent]>([])
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let broker = ACPInteractionBroker(
            instanceID: UUID(),
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )
        let now = Date()
        let original = "caf\u{00E9}"
        let changed = "cafe\u{0301}"
        XCTAssertEqual(original, changed)
        XCTAssertFalse(original.utf8.elementsEqual(changed.utf8))

        let operations: [(kind: String, field: String, initial: Any, updated: Any)] = [
            ("execute", "rawInput", ["command": "printf '\(original)'"], ["command": "printf '\(changed)'"]),
            ("edit", "content",
             [["type": "diff", "path": "/fixture/file", "oldText": "", "newText": original]],
             [["type": "diff", "path": "/fixture/file", "oldText": "", "newText": changed]])
        ]
        for (index, operation) in operations.enumerated() {
            let id = JSONRPCID.int(index)
            let toolID = "\(operation.kind)-\(original)"
            let toolCall: Record = ["toolCallId": toolID, "kind": operation.kind,
                                    operation.field: operation.initial]
            try broker.accept(.init(id: id, method: "session/request_permission", params: [
                "sessionId": original, "toolCall": toolCall,
                "options": [["optionId": "a", "name": "Allow", "kind": "allow_once"]]
            ], paramsJSON: nil, raw: [:]), now: now)
            guard case .interaction(let shown)? = events.value.last else { return XCTFail("Missing request") }
            let update: Record = ["sessionUpdate": "tool_call_update", "toolCallId": toolID,
                                   operation.field: operation.updated]
            broker.receiveToolUpdate(update, sessionID: changed)
            var otherTool = update
            otherTool["toolCallId"] = "\(operation.kind)-\(changed)"
            broker.receiveToolUpdate(otherTool, sessionID: original)
            XCTAssertEqual(broker.pendingCount, 1)
            XCTAssertEqual(replies.value.count, index)

            broker.receiveToolUpdate(update, sessionID: original)
            XCTAssertEqual(broker.pendingCount, 0)
            XCTAssertEqual(replies.value.last?.0, id)
            XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
            XCTAssertThrowsError(try broker.respond(shown, .permissionOption("a"), now: now))
            XCTAssertEqual(replies.value.count, index + 1)
        }
    }

    func testInteractionBrokerRejectsOversizedOrEmptyPayloadsWithoutTruncating() throws {
        let instanceID = UUID()
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let events = LockedBox<[AgentEvent]>([])
        let broker = ACPInteractionBroker(
            instanceID: instanceID,
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )

        // Empty options -> auto-cancelled
        try broker.accept(JSONRPCRequest(id: .int(1), method: "session/request_permission", params: ["toolCall": ["title": "Run"], "options": [] as [Record]], paramsJSON: nil, raw: [:]))
        // Oversized title -> auto-cancelled
        let hugeTitle = String(repeating: "x", count: 5_000)
        try broker.accept(JSONRPCRequest(id: .string("huge"), method: "session/request_permission", params: [
            "toolCall": ["title": hugeTitle],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]))

        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(replies.value.count, 2)
        XCTAssertEqual((replies.value[0].1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        XCTAssertEqual((replies.value[1].1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        XCTAssertEqual(events.value.filter { if case .notice = $0 { return true }; return false }.count, 2)
    }

    func testInteractionBrokerAcceptsLargePayloadsAboveLegacy64KiBCapWithoutTruncating() throws {
        let instanceID = UUID()
        let replies = LockedBox<[(JSONRPCID, Record)]>([])
        let events = LockedBox<[AgentEvent]>([])
        let broker = ACPInteractionBroker(
            instanceID: instanceID,
            sendResponse: { id, payload in replies.withValue { $0.append((id, payload)) } },
            emit: { event in events.withValue { $0.append(event) } }
        )

        let largeOldText = String(repeating: "let oldLine = 1\n", count: 6_000) // ~96 KiB
        let largeNewText = String(repeating: "let newLine = 2\n", count: 6_000) // ~96 KiB (combined > 190 KiB)
        let largeRawInput: Record = [
            "path": "/fixture/LargeFile.swift",
            "payload": String(repeating: "x", count: 300_000) // > 256 KiB, uses compact JSON
        ]

        broker.receiveToolUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "large-edit-1",
            "kind": "edit",
            "title": "Edit LargeFile.swift",
            "locations": [["path": "/fixture/LargeFile.swift"]],
            "content": [["type": "diff", "path": "/fixture/LargeFile.swift", "oldText": largeOldText, "newText": largeNewText]],
            "rawInput": largeRawInput
        ], sessionID: "session-large")

        try broker.accept(JSONRPCRequest(id: .string("req-large-diff"), method: "session/request_permission", params: [
            "sessionId": "session-large",
            "toolCall": ["toolCallId": "large-edit-1"],
            "options": [
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
            ]
        ], paramsJSON: nil, raw: [:]))

        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertTrue(replies.value.isEmpty)
        guard case .interaction(let interaction)? = events.value.last else {
            return XCTFail("Expected large permission request to be accepted instead of auto-cancelled")
        }
        XCTAssertEqual(interaction.permissionContext?.fileDiffs.first?.oldText, largeOldText)
        XCTAssertEqual(interaction.permissionContext?.fileDiffs.first?.newText, largeNewText)
        XCTAssertEqual(interaction.permissionContext?.rawInputJSON?.contains(String(repeating: "x", count: 300_000)), true)

        try broker.respond(interaction, .permissionOption("allow"))
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["optionId"] as? String, "allow")

        let largeCommand = "echo " + String(repeating: "a", count: 150_000)
        try broker.accept(JSONRPCRequest(id: .string("req-large-cmd"), method: "session/request_permission", params: [
            "sessionId": "session-large",
            "toolCall": [
                "toolCallId": "large-cmd-1",
                "kind": "execute",
                "title": "Run large script",
                "rawInput": ["command": largeCommand]
            ],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]))

        XCTAssertEqual(broker.pendingCount, 1)
        guard case .interaction(let cmdInteraction)? = events.value.last else {
            return XCTFail("Expected large command permission request to be accepted")
        }
        XCTAssertEqual(cmdInteraction.toolApproval?.operation, .command(text: largeCommand, timeoutSeconds: nil))
        try broker.respond(cmdInteraction, .permissionOption("allow"))

        // Retain > 4 MiB pre-permission tool_call without silently dropping it.
        let fiveMiBNewText = String(repeating: "0123456789abcdef\n", count: 310_000) // ~5.27 MiB
        broker.receiveToolUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "huge-retained-edit",
            "kind": "edit",
            "title": "Edit HugeFile.swift",
            "content": [["type": "diff", "path": "/fixture/HugeFile.swift", "oldText": "a", "newText": fiveMiBNewText]]
        ], sessionID: "session-large")
        try broker.accept(JSONRPCRequest(id: .string("req-5mib-edit"), method: "session/request_permission", params: [
            "sessionId": "session-large",
            "toolCall": ["toolCallId": "huge-retained-edit"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]))
        guard case .interaction(let retainedInteraction)? = events.value.last else {
            return XCTFail("Expected > 4 MiB retained tool_call permission request to be accepted")
        }
        XCTAssertEqual(retainedInteraction.permissionContext?.fileDiffs.first?.newText.utf8.count, fiveMiBNewText.utf8.count)
        try broker.respond(retainedInteraction, .permissionOption("allow"))

        // A session approval without toolCallId cannot be matched to the operation to review.
        let eventCountBeforeMalformedRequest = events.value.count
        try broker.accept(JSONRPCRequest(id: .string("req-no-tool-id"), method: "session/request_permission", params: [
            "sessionId": "session-large",
            "toolCall": ["kind": "execute", "title": "Execute without ID"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]))
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(events.value.count, eventCountBeforeMalformedRequest)
        XCTAssertEqual(replies.value.last?.0, .string("req-no-tool-id"))
        XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["outcome"] as? String, "cancelled")

        // Payloads > 16 MiB are rejected without truncating.
        let overLimitCommand = String(repeating: "z", count: 16 * 1_024 * 1_024 + 1_024)
        let noticeCountBefore = events.value.filter { if case .notice = $0 { return true }; return false }.count
        try broker.accept(JSONRPCRequest(id: .string("req-over-16mib"), method: "session/request_permission", params: [
            "sessionId": "session-large",
            "toolCall": ["toolCallId": "huge-command", "kind": "execute", "title": "Huge command",
                         "rawInput": ["command": overLimitCommand]],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]
        ], paramsJSON: nil, raw: [:]))
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual((replies.value.last?.1["outcome"] as? Record)?["outcome"] as? String, "cancelled")
        let noticeCountAfter = events.value.filter { if case .notice = $0 { return true }; return false }.count
        XCTAssertEqual(noticeCountAfter, noticeCountBefore + 1)
    }

    // MARK: - Prompt Image Encoding Tests

    func testBuildPromptBlocksEncodesImagesWhenSupportedAndFallsBackOtherwise() throws {
        let dir = try makeTempDir(prefix: "zivvi-acp-img")
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("sample.png")
        let noteURL = dir.appendingPathComponent("readme.txt")
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try pngBytes.write(to: imageURL)
        try Data("hello".utf8).write(to: noteURL)

        let prompt = UserPrompt(text: "Inspect these", files: [imageURL, noteURL])

        let withImageSupport = ACPConnection.buildPromptBlocks(prompt: prompt, supportsImage: true)
        XCTAssertEqual(withImageSupport.count, 2)
        XCTAssertEqual(withImageSupport[0]["type"] as? String, "text")
        XCTAssertTrue((withImageSupport[0]["text"] as? String)?.contains(noteURL.path) == true)
        XCTAssertEqual(withImageSupport[1]["type"] as? String, "image")
        XCTAssertEqual(withImageSupport[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(withImageSupport[1]["data"] as? String, pngBytes.base64EncodedString())

        let withoutImageSupport = ACPConnection.buildPromptBlocks(prompt: prompt, supportsImage: false)
        XCTAssertEqual(withoutImageSupport.count, 1)
        XCTAssertEqual(withoutImageSupport[0]["type"] as? String, "text")
        XCTAssertTrue((withoutImageSupport[0]["text"] as? String)?.contains(imageURL.path) == true)
        XCTAssertTrue((withoutImageSupport[0]["text"] as? String)?.contains(noteURL.path) == true)
    }

    // MARK: - End-to-End ACPRuntime + fake-acp.py Contract Tests

    func testCheckConnectionAndInspectModelsAgainstFakeACP() async throws {
        let dir = try makeTempDir(prefix: "zivvi-acp-check")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = await ACPRuntime.checkConnection(fakeConfig(workspace: dir))
        XCTAssertTrue(ok.isReady)
        XCTAssertEqual(ok.protocolVersion, .compatible(1))
        XCTAssertEqual(ok.agentName, "Fake ACP v1 Agent")
        XCTAssertTrue(ok.capabilitiesSummary.loadSession)
        XCTAssertTrue(ok.capabilitiesSummary.imagePrompt)
        XCTAssertGreaterThan(ok.capabilitiesSummary.modesCount, 0)
        XCTAssertGreaterThan(ok.capabilitiesSummary.modelsCount, 0)
        XCTAssertFalse(ok.cleanupUnconfirmed)

        let unsupported = await ACPRuntime.checkConnection(fakeConfig(workspace: dir, extraArgs: ["--protocol-version", "2"]))
        XCTAssertFalse(unsupported.isReady)
        XCTAssertEqual(unsupported.protocolVersion, .unsupported(2))
        XCTAssertFalse(unsupported.cleanupUnconfirmed)

        let authRequired = await ACPRuntime.checkConnection(fakeConfig(workspace: dir, extraArgs: ["--require-auth"]))
        XCTAssertFalse(authRequired.isReady)
        XCTAssertTrue(authRequired.authRequired)
        XCTAssertFalse(authRequired.cleanupUnconfirmed)

        let missing = await ACPRuntime.checkConnection(ACPConfiguration(
            executable: dir.appendingPathComponent("missing-agent"),
            workspace: dir
        ))
        XCTAssertEqual(missing.dependencyFailure, .executable)

        let inspected = try await ACPRuntime.inspectModels(fakeConfig(workspace: dir), model: nil)
        XCTAssertEqual(inspected.models.map(\.modelID), ["fake/model-alpha", "fake/model-beta"])
        XCTAssertEqual(inspected.thinkingLevels, ["low", "medium", "high"])
    }

    func testOrdinaryPromptConfirmationUsesAgentEvidence() async throws {
        let root = try makeTempDir(prefix: "zivvi-acp-confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let acceptedInput = "Accept this prompt"
        for input in ["reject-length-fixture", "refusal", acceptedInput, "slow"] {
            let runtime = ACPRuntime(configuration: fakeConfig(workspace: root))
            let recorder = ACPEventRecorder(runtime: runtime)
            defer { recorder.cancel() }
            _ = try await runtime.connect()
            let prompt = UserPrompt(text: input)
            let disposition = try await runtime.send(prompt)
            XCTAssertEqual(disposition, .started)
            if input == "slow" {
                let early = await recorder.waitUntil(timeout: 3) { events in
                    events.contains { if case .promptConfirmed(prompt.id) = $0 { return true }; return false }
                }
                XCTAssertTrue(early)
                XCTAssertFalse(recorder.events.contains { if case .settled = $0 { return true }; return false })
                try await runtime.stop()
            }
            let settled = await recorder.waitUntil { events in
                events.contains { if case .settled = $0 { return true }; return false }
            }
            XCTAssertTrue(settled)
            let confirmations = recorder.events.filter { event in
                if case .promptConfirmed(let id) = event { return id == prompt.id }
                return false
            }
            XCTAssertEqual(confirmations.count, input == "reject-length-fixture" ? 0 : 1)
            let rejected = recorder.events.contains { event in
                if case .promptAcceptance(prompt.id, .rejected) = event { return true }
                return false
            }
            XCTAssertEqual(rejected, input == "reject-length-fixture")
            try await runtime.close(force: true)
        }
    }

    func testHandoffPromptAcceptanceIsReportedByAgentResponse() async throws {
        let directory = try makeTempDir(prefix: "zivvi-acp-handoff")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: directory))
        let recorder = ACPEventRecorder(runtime: runtime)
        defer { recorder.cancel() }
        _ = try await runtime.connect()
        let prompt = UserPrompt(text: "Continue the task", handoffContext: "Previously completed the first step")
        let disposition = try await runtime.send(prompt)
        XCTAssertEqual(disposition, .awaitingAcceptance)
        let accepted = await recorder.waitUntil { events in
            events.contains { event in
                if case .promptAcceptance(let id, .accepted) = event { return id == prompt.id }
                return false
            }
        }
        try await runtime.close(force: true)
        XCTAssertTrue(accepted)
    }

    func testHandoffPromptLengthRejectionPreservesReasonWithoutEchoingPayload() async throws {
        let directory = try makeTempDir(prefix: "zivvi-acp-handoff-length")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: directory))
        let recorder = ACPEventRecorder(runtime: runtime)
        defer { recorder.cancel() }
        _ = try await runtime.connect()
        let prompt = UserPrompt(text: "reject-length-fixture", handoffContext: "saved")
        let disposition = try await runtime.send(prompt)
        XCTAssertEqual(disposition, .awaitingAcceptance)
        let expected = try XCTUnwrap(RuntimeFailure.promptLengthRejection("context_length_exceeded"))
        let rejected = await recorder.waitUntil { events in
            let receivedRejection = events.contains { event in
                if case .promptAcceptance(let id, .rejected) = event { return id == prompt.id }
                return false
            }
            return receivedRejection && events.contains { event in
                if case .failure(let failure) = event { return failure == expected && !failure.detail.contains("fixture-secret") }
                return false
            }
        }
        try await runtime.close(force: true)
        XCTAssertTrue(rejected)
    }

    func testHandoffPromptLengthWithAmbiguousRPCErrorKeepsDeliveryUnknown() async throws {
        let directory = try makeTempDir(prefix: "zivvi-acp-handoff-length-unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: directory))
        let recorder = ACPEventRecorder(runtime: runtime)
        defer { recorder.cancel() }
        _ = try await runtime.connect()
        let prompt = UserPrompt(text: "unknown-length-fixture", handoffContext: "saved")
        _ = try await runtime.send(prompt)
        let unknown = await recorder.waitUntil { events in
            let receivedUnknown = events.contains { event in
                if case .promptAcceptance(let id, .unknown) = event { return id == prompt.id }
                return false
            }
            return receivedUnknown && events.contains { event in
                if case .failure(let failure) = event {
                    return failure.kind == .outcomeUnknown && !failure.detail.contains("fixture-secret")
                }
                return false
            }
        }
        try await runtime.close(force: true)
        XCTAssertTrue(unknown)
    }

    func testHandoffPromptTextErrorClassificationPreservesDeliveryAndSanitizesDetails() async throws {
        let directory = try makeTempDir(prefix: "zivvi-acp-handoff-error-text")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lengthFailure = try XCTUnwrap(RuntimeFailure.promptLengthRejection("context_length_exceeded"))
        let cases: [(String, RuntimePromptAcceptance, RuntimeFailureKind)] = [
            ("reject-length-text-fixture", .rejected, .model),
            ("unknown-length-text-fixture", .unknown, .outcomeUnknown),
            ("reject-length-echo-fixture", .rejected, .model),
            ("reject-auth-text-fixture", .rejected, .authentication),
            ("reject-auth-code-fixture", .rejected, .authentication),
            ("reject-auth-echo-fixture", .rejected, .authentication),
            ("unknown-auth-echo-fixture", .unknown, .authentication)
        ]
        for (text, acceptance, kind) in cases {
            let runtime = ACPRuntime(configuration: fakeConfig(workspace: directory))
            let recorder = ACPEventRecorder(runtime: runtime)
            defer { recorder.cancel() }
            _ = try await runtime.connect()
            let prompt = UserPrompt(text: text, handoffContext: "saved")
            let disposition = try await runtime.send(prompt)
            XCTAssertEqual(disposition, .awaitingAcceptance)
            let matched = await recorder.waitUntil { events in
                let receivedAcceptance = events.contains { event in
                    if case .promptAcceptance(let id, let result) = event { return id == prompt.id && result == acceptance }
                    return false
                }
                return receivedAcceptance && events.contains { event in
                    guard case .failure(let failure) = event, failure.kind == kind,
                          !failure.detail.contains("fixture-secret") else { return false }
                    return kind != .model || failure == lengthFailure
                }
            }
            try await runtime.close(force: true)
            XCTAssertTrue(matched, text)
        }
    }

    func testHandoffCleanupRetainsAgentAndClientTerminalSupervisorReports() async throws {
        let directory = try makeTempDir(prefix: "zivvi-acp-handoff-cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = ACPHandoffCleanup(root: directory.appendingPathComponent("cleanup"), id: UUID())
        var config = fakeConfig(workspace: directory, extraArgs: ["--v1-extended"])
        config.handoffCleanup = receipt
        config.clientPermissions = [.terminals]
        let runtime = ACPRuntime(configuration: config)
        let recorder = ACPEventRecorder(runtime: runtime)
        defer { recorder.cancel() }
        _ = try await runtime.connect()
        do {
            _ = try await runtime.send(.init(text: "verify-client-terminal-only"))
        } catch {
            try await runtime.close(force: true)
            throw error
        }
        let settled = await recorder.waitUntil { events in
            events.contains { if case .settled(aborted: false) = $0 { return true }; return false }
        }
        XCTAssertFalse(receipt.isConfirmed)
        try await runtime.close(force: true)
        XCTAssertTrue(settled)
        XCTAssertTrue(receipt.isConfirmed)
        let reports = try FileManager.default.contentsOfDirectory(atPath: receipt.directory.path)
        XCTAssertTrue(reports.contains("status.json"))
        XCTAssertEqual(reports.filter { $0.hasPrefix("zivvi-terminal-") }.count, 1)
    }

    func testAgentCancellationClosesPendingPermissionWithoutMarkingTimeout() async throws {
        let directory = try makeTempDir()
        let receipt = directory.appendingPathComponent("wire.jsonl")
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: directory, extraArgs: ["--receipt-path", receipt.path]))
        let recorder = ACPEventRecorder(runtime: runtime)
        addTeardownBlock {
            recorder.cancel()
            try? await runtime.close(force: true)
            try FileManager.default.removeItem(at: directory)
        }

        _ = try await runtime.connect()
        _ = try await runtime.send(.init(text: "cancel pending approval fixture"))
        let settled = await recorder.waitUntil { events in
            events.contains { if case .settled(aborted: true) = $0 { return true }; return false }
        }
        XCTAssertTrue(settled)
        let events = recorder.events
        let pending = try XCTUnwrap(events.compactMap { event -> RuntimeInteraction? in
            if case .interaction(let interaction) = event { return interaction }
            return nil
        }.first)
        XCTAssertGreaterThan(pending.expiresAt, Date())
        let ended = events.compactMap { event -> InteractionEnd? in
            if case .interactionEnded(let id, let reason) = event, id == pending.id { return reason }
            return nil
        }
        XCTAssertEqual(ended, [.cancelled])

        try await runtime.close(force: false)
        let wire = try String(contentsOf: receipt, encoding: .utf8)
        XCTAssertFalse(wire.contains(#""event": "client response""#))
    }

    func testRuntimeStreamingPermissionCancelAndReplayAgainstFakeACP() async throws {
        let dir = try makeTempDir(prefix: "zivvi-acp-e2e")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Streaming + diff + permission + cancel
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: dir))
        let recorder = ACPEventRecorder(runtime: runtime)
        defer { recorder.cancel() }

        let session = try await runtime.connect()
        XCTAssertTrue(session.capabilities.contains(.sessionResume))
        XCTAssertFalse(session.capabilities.contains(.queuedPrompts))

        let d1 = try await runtime.send(UserPrompt(text: "Please diff this"))
        XCTAssertEqual(d1, .started)
        let settled1 = await recorder.waitUntil(timeout: 10) { events in
            events.contains { if case .settled(aborted: false) = $0 { return true }; return false }
        }
        XCTAssertTrue(settled1)
        XCTAssertTrue(recorder.events.contains {
            if case .tool(let tool) = $0 { return tool.name == "edit" && tool.editArguments?.path == "Sources/Demo.swift" }
            return false
        })

        // Permission approval flow
        let offset2 = recorder.events.count
        _ = try await runtime.send(UserPrompt(text: "Trigger approval id-only"))
        let sawInteraction = await recorder.waitUntil(timeout: 10) { events in
            events.dropFirst(offset2).contains { if case .interaction = $0 { return true }; return false }
        }
        XCTAssertTrue(sawInteraction)
        let interaction = try XCTUnwrap(recorder.events.dropFirst(offset2).compactMap { event -> RuntimeInteraction? in
            if case .interaction(let req) = event { return req }
            return nil
        }.first)
        let fileDiffs = try XCTUnwrap(interaction.permissionContext?.fileDiffs)
        XCTAssertEqual(fileDiffs.map(\.path), [dir.appendingPathComponent("Sources/App.swift").path,
                                               dir.appendingPathComponent("Tests/AppTests.swift").path])
        XCTAssertEqual(fileDiffs[0].oldText, "let enabled = false\n")
        XCTAssertNil(fileDiffs[1].oldText)
        XCTAssertEqual(interaction.permissionContext?.paths, [])
        XCTAssertEqual(interaction.permissionContext?.awaitingToolDetails, false)
        try await runtime.respond(to: interaction, with: .permissionOption("allow_once"))
        let settled2 = await recorder.waitUntil(timeout: 10) { events in
            events.dropFirst(offset2).contains { if case .settled(aborted: false) = $0 { return true }; return false }
        }
        XCTAssertTrue(settled2)

        // Mid-turn cancellation
        let offset3 = recorder.events.count
        _ = try await runtime.send(UserPrompt(text: "cancel-me"))
        let sawTool = await recorder.waitUntil(timeout: 5) { events in
            events.dropFirst(offset3).contains { if case .tool = $0 { return true }; return false }
        }
        XCTAssertTrue(sawTool)
        try await runtime.stop()
        let settled3 = await recorder.waitUntil(timeout: 5) { events in
            events.dropFirst(offset3).contains { if case .settled(aborted: true) = $0 { return true }; return false }
        }
        XCTAssertTrue(settled3)
        try await runtime.close(force: false)

        // 2. session/load replay isolation
        let replayRuntime = ACPRuntime(configuration: fakeConfig(workspace: dir, expectedSessionID: "replay-fixture"))
        let replayRecorder = ACPEventRecorder(runtime: replayRuntime)
        defer { replayRecorder.cancel() }

        let loaded = try await replayRuntime.connect()
        XCTAssertEqual(loaded.id, "replay-fixture")
        let sawReplay = await replayRecorder.waitUntil(timeout: 5) { events in
            events.contains { if case .historyReplayed = $0 { return true }; return false }
        }
        XCTAssertTrue(sawReplay)
        XCTAssertFalse(replayRecorder.events.contains {
            switch $0 {
            case .phase(.running), .runStarted, .settled: return true
            default: return false
            }
        })
        try await replayRuntime.close(force: false)

        // 3. Rejects session/load when agent advertises loadSession == false
        let noResume = ACPRuntime(configuration: fakeConfig(workspace: dir, extraArgs: ["--no-load-session"], expectedSessionID: "replay-fixture"))
        do {
            _ = try await noResume.connect()
            XCTFail("Expected loadSession failure")
        } catch let failure as RuntimeFailure {
            XCTAssertEqual(failure.kind, .setup)
        }
        try? await noResume.close(force: true)
    }

    func testRuntimeConfigurationDualPathAndLegacyFallback() async throws {
        let dir = try makeTempDir(prefix: "zivvi-acp-cfg")
        defer { try? FileManager.default.removeItem(at: dir) }

        let modern = ACPRuntime(configuration: fakeConfig(workspace: dir, extraArgs: ["--config-options-only"]))
        let s1 = try await modern.connect()
        let updated1 = try await modern.applyConfiguration(RuntimeSelection(provider: s1.provider ?? "fake-acp", modelID: "fake/model-beta", thinking: "high"))
        XCTAssertEqual(updated1.modelID, "fake/model-beta")
        XCTAssertEqual(updated1.thinking, "high")
        let mode1 = try await modern.setMode("plan")
        XCTAssertEqual(mode1.modeID, "plan")
        try await modern.close(force: false)

        let legacy = ACPRuntime(configuration: fakeConfig(workspace: dir, extraArgs: ["--legacy-models"]))
        let s2 = try await legacy.connect()
        let updated2 = try await legacy.applyConfiguration(RuntimeSelection(provider: s2.provider ?? "fake-acp", modelID: "fake/model-beta", thinking: nil))
        XCTAssertEqual(updated2.modelID, "fake/model-beta")
        let mode2 = try await legacy.setMode("accept-edits")
        XCTAssertEqual(mode2.modeID, "accept-edits")
        try await legacy.close(force: false)
    }

    @MainActor
    func testIdentifiedACPMessagesKeepImagesAndBoundariesThroughLiveTurnAndLoad() async throws {
        let dir = try makeTempDir()
        let options = ["--identified-messages", "--state-file", dir.appendingPathComponent("agent.json").path]
        let live = SessionController()
        let runtime = ACPRuntime(configuration: fakeConfig(workspace: dir, extraArgs: options))
        addTeardownBlock {
            try? await runtime.close(force: true)
            try FileManager.default.removeItem(at: dir)
        }
        await live.connect(runtime)
        let sessionID = try XCTUnwrap(live.session?.id)
        await live.sendDraft(UserPrompt(text: "Identify my replies"))
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline, live.transcript.last?.images.isEmpty != false || live.phase != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        let liveReplies = live.transcript.filter { $0.kind == .assistant }
        let imageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQjer5DwAD3gIT+2LWGAAAAABJRU5ErkJggg=="))
        XCTAssertNotNil(ImageAttachmentThumbnail.loadThumbnail(from: imageData, maxPixels: 120))
        XCTAssertEqual(live.transcript.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(liveReplies.map(\.text), ["First reply", "Next reply", ""])
        XCTAssertEqual(liveReplies.map { $0.images.map(\.data) }, [[imageData], [], [imageData]])
        XCTAssertTrue(liveReplies.allSatisfy { !$0.streaming })
        XCTAssertTrue(TranscriptDisplayRow.project(live.transcript).contains {
            if case .item(let item) = $0 { return item.kind == .assistant && item.text.isEmpty && !item.images.isEmpty }
            return false
        })
        let disconnected = await live.disconnect()
        XCTAssertTrue(disconnected)

        let reopened = SessionController()
        let restored = ACPRuntime(configuration: fakeConfig(workspace: dir, extraArgs: options, expectedSessionID: sessionID))
        addTeardownBlock { try? await restored.close(force: true) }
        await reopened.connect(restored)
        let replayedReplies = reopened.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(replayedReplies.map(\.text), liveReplies.map(\.text))
        XCTAssertEqual(replayedReplies.map { $0.images.map(\.data) }, liveReplies.map { $0.images.map(\.data) })
        XCTAssertTrue(replayedReplies.allSatisfy { !$0.streaming })
        let closed = await reopened.disconnect()
        XCTAssertTrue(closed)
    }

    func testEmptyConfigOptionsReplaceStateInNotificationsAndResponses() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for source in ["prompt", "set-response", "load-response", "set-after", "load-after"] {
            // The fixture advertises modern configOptions alongside legacy modes and models.
            let isLoad = source.hasPrefix("load-")
            let config = fakeConfig(workspace: dir, extraArgs: ["--empty-config-options", source],
                                    expectedSessionID: isLoad ? "replay-fixture" : nil)
            let runtime = ACPRuntime(configuration: config)
            let recorder = ACPEventRecorder(runtime: runtime)
            addTeardownBlock {
                recorder.cancel()
                try? await runtime.close(force: true)
            }
            let initial = try await runtime.connect()
            if !isLoad {
                XCTAssertFalse(initial.availableModes.isEmpty, source)
                if source == "prompt" {
                    _ = try await runtime.send(UserPrompt(text: "Clear options"))
                    let notified = await recorder.waitUntil(timeout: 5) { events in
                        events.contains { if case .sessionUpdated(let session) = $0 { return session.availableModes.isEmpty }; return false }
                    }
                    XCTAssertTrue(notified)
                } else {
                    _ = try await runtime.setMode("plan")
                }
            }
            // A following notification may still be queued when the RPC returns.
            if source.hasSuffix("-after") {
                let deadline = ContinuousClock.now + .seconds(2)
                while .now < deadline {
                    if try await runtime.currentSession().availableModes.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let current = try await runtime.currentSession()
            let remaining = try await runtime.configurationOptions()
            XCTAssertTrue(current.availableModes.isEmpty, source)
            XCTAssertFalse(current.capabilities.contains(.modeSelection), source)
            XCTAssertNil(current.modelID, source)
            XCTAssertTrue(remaining.models.isEmpty, source)
            XCTAssertTrue(remaining.thinkingLevels.isEmpty, source)
            XCTAssertGreaterThan(current.configurationRevision, 0, source)
            do {
                _ = try await runtime.setMode("default")
                XCTFail("Cleared modern mode choices must not fall back to legacy choices: \(source)")
            } catch let failure as RuntimeFailure {
                XCTAssertEqual(failure.kind, .setup)
            }
            try await runtime.close(force: false)
        }
    }
}
