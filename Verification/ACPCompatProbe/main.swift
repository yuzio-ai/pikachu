import Foundation
import Darwin
import AgentRuntimeCore
import ACPRuntimeAdapter
import ProcessSupervision

signal(SIGPIPE, SIG_IGN)

let fm = FileManager.default
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let args = CommandLine.arguments

@MainActor
func option(_ name: String, _ fallback: String? = nil) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return fallback }
    return args[index + 1]
}

@MainActor
func repeatedOption(_ name: String) -> [String] {
    var values: [String] = []
    var index = 0
    while index < args.count {
        if args[index] == name, index + 1 < args.count {
            values.append(args[index + 1])
            index += 2
        } else {
            index += 1
        }
    }
    return values
}

let suite = option("--suite", "fake") ?? "fake"
try require(["fake", "local", "real"].contains(suite), "Unknown --suite '\(suite)'. Expected fake, local, or real.")

let explicitCommand = option("--command")
let explicitArgs = repeatedOption("--arg")
let defaultAntigravity = ACPConfiguration.detectedAntigravityPath() ?? "/opt/homebrew/bin/agy"
let targetCommand = explicitCommand ?? defaultAntigravity
let targetArgs: [String] = {
    if !explicitArgs.isEmpty { return explicitArgs }
    if explicitCommand == nil || URL(fileURLWithPath: targetCommand).lastPathComponent == "agy" {
        return ["acp"]
    }
    return []
}()

let proxy = option("--proxy", "") ?? ""
let supervised = !args.contains("--unsupervised")
let allowRealPermissions = args.contains("--allow-permissions")
let customPrompt = option("--prompt")
let fakeFixtureURL = projectRoot.appendingPathComponent("Verification/Fixtures/fake-acp.py")

let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + suite
let defaultOutput = projectRoot.appendingPathComponent(".verification-runs/acp-compat-probe/\(runID)")
let output = URL(fileURLWithPath: option("--output", defaultOutput.path) ?? defaultOutput.path)
try fm.createDirectory(at: output, withIntermediateDirectories: true)

let tempWork = fm.temporaryDirectory.appendingPathComponent("Zivvi-acp-compat-probe-\(UUID().uuidString)")
try fm.createDirectory(at: tempWork, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: tempWork) }

let baseCWD: URL = {
    if let explicitCWD = option("--cwd") {
        return URL(fileURLWithPath: explicitCWD, isDirectory: true)
    }
    return tempWork
}()

var results: [Record] = []

@MainActor
func save(_ value: Any, _ name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
}

@MainActor
func runCase(_ id: String, _ body: @MainActor () async throws -> Record) async {
    let started = Date()
    do {
        let evidence = try await body()
        results.append(["case": id, "status": "pass", "seconds": Date().timeIntervalSince(started), "evidence": evidence])
        print("PASS \(id)")
    } catch {
        results.append(["case": id, "status": "fail", "seconds": Date().timeIntervalSince(started), "error": String(describing: error)])
        print("FAIL \(id): \(error)")
    }
    try? save(results, "results.json")
}

/// Collects `AgentEvent`s from an `ACPRuntime` stream on a background task.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [AgentEvent] = []
    private var task: Task<Void, Never>?

    convenience init(runtime: ACPRuntime) { self.init(stream: runtime.events) }

    init(stream: AsyncStream<RuntimeEnvelope>) {
        task = Task.detached { [weak self] in
            for await envelope in stream {
                self?.record(envelope.event)
            }
        }
    }

    private func record(_ event: AgentEvent) {
        lock.withLock {
            if case .batch(let items) = event {
                collected.append(contentsOf: items)
            } else {
                collected.append(event)
            }
        }
    }

    var events: [AgentEvent] {
        lock.withLock { collected }
    }

    func waitUntil(timeout: Double = 10, _ predicate: @Sendable ([AgentEvent]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw ProbeError.failure("Timed out waiting for expected ACP event")
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

@MainActor
func makeSubdir(_ name: String) throws -> URL {
    let dir = tempWork.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
}

@MainActor
func fakeConfiguration(
    workspace: URL,
    extraArgs: [String] = [],
    expectedSessionID: String? = nil,
    cancelTimeout: TimeInterval = 5
) -> ACPConfiguration {
    ACPConfiguration(
        executable: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: ["-u", fakeFixtureURL.path] + extraArgs,
        workspace: workspace,
        runtimeID: "acp:fake",
        expectedSessionID: expectedSessionID,
        environmentOverrides: [:],
        proxy: proxy,
        cancelTimeoutSeconds: cancelTimeout
    )
}

@MainActor
func sanitizeKeys(_ record: Record?) -> [String] {
    guard let record else { return [] }
    return record.keys.sorted()
}

// MARK: - Fake Suite (Zero External Dependencies)

if suite == "fake" {
    try require(fm.isReadableFile(atPath: fakeFixtureURL.path), "Missing fake-acp.py fixture at \(fakeFixtureURL.path)")

    await runCase("acp-compat/fake/check-connection") {
        let cwd = try makeSubdir("fake-check")
        let healthy = await ACPRuntime.checkConnection(fakeConfiguration(workspace: cwd))
        try require(healthy.isReady, "Healthy fake ACP check should be ready")
        try require(healthy.protocolVersion == .compatible(1), "Expected protocolVersion 1")
        try require(healthy.capabilitiesSummary.loadSession, "Expected loadSession true")
        try require(healthy.capabilitiesSummary.imagePrompt, "Expected imagePrompt true")
        try require(healthy.capabilitiesSummary.modesCount > 0 && healthy.capabilitiesSummary.modelsCount > 0, "Expected modes and models")
        try require(!healthy.cleanupUnconfirmed, "Healthy check cleanup must be confirmed")

        let mismatch = await ACPRuntime.checkConnection(fakeConfiguration(workspace: cwd, extraArgs: ["--protocol-version", "2"]))
        try require(mismatch.protocolVersion == .unsupported(2), "Expected unsupported(2)")
        try require(!mismatch.isReady && !mismatch.cleanupUnconfirmed, "Mismatch must not be ready and must clean up")

        let authReq = await ACPRuntime.checkConnection(fakeConfiguration(workspace: cwd, extraArgs: ["--require-auth"]))
        try require(authReq.authRequired && !authReq.isReady && !authReq.cleanupUnconfirmed, "Auth required check failed")

        let options = try await ACPRuntime.inspectModels(fakeConfiguration(workspace: cwd), model: nil)
        try require(!options.models.isEmpty && !options.thinkingLevels.isEmpty, "inspectModels returned empty metadata")

        return [
            "agentName": healthy.agentName ?? NSNull(),
            "agentVersion": healthy.agentVersion ?? NSNull(),
            "modesCount": healthy.capabilitiesSummary.modesCount,
            "modelsCount": healthy.capabilitiesSummary.modelsCount,
            "mismatchRejected": true,
            "authDetected": true,
            "inspectedModels": options.models.map(\.modelID),
            "inspectedThinkingLevels": options.thinkingLevels
        ]
    }

    await runCase("acp-compat/fake/extended-auth-elicitation-cancel") {
        let cwd = try makeSubdir("extended-auth").resolvingSymlinksInPath()
        let receipts = cwd.appendingPathComponent("receipts")
        var config = fakeConfiguration(workspace: cwd, extraArgs: ["--v1-extended", "--require-auth"])
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipts.path]
        let control = try await ACPAgentConnection.open(config)
        let collector = EventCollector(stream: control.events)
        defer { collector.stop() }
        do {
            let form = Task { try await control.authenticate(methodID: "verify-form") }
            try await collector.waitUntil { events in events.contains {
                if case .interaction(let request) = $0, case .form? = request.elicitation { return true }; return false
            } }
            guard let formRequest = collector.events.compactMap({ event -> RuntimeInteraction? in
                if case .interaction(let request) = event { return request }
                return nil
            }).first else { throw ProbeError.failure("No form request") }
            do {
                try await control.respond(to: formRequest, with: .value("{}"))
                throw ProbeError.failure("Missing required fields were accepted")
            } catch let failure as RuntimeFailure {
                try require(failure.kind == .unsupportedInteraction, "Wrong form validation error")
            }
            try await control.respond(to: formRequest, with: .value(#"{"confirm":true}"#))
            try await form.value
            _ = try await control.list(cursor: nil)
            try await control.logout()
            do {
                _ = try await control.list(cursor: nil)
                throw ProbeError.failure("Logout did not clear authentication")
            } catch let failure as RuntimeFailure {
                try require(failure.kind == .authentication, "Expected auth requirement after logout")
            }
            let url = Task { try await control.authenticate(methodID: "verify-url") }
            try await collector.waitUntil { events in events.contains {
                if case .interaction(let request) = $0, case .url? = request.elicitation { return true }; return false
            } }
            guard let urlRequest = collector.events.compactMap({ event -> RuntimeInteraction? in
                if case .interaction(let request) = event, case .url? = request.elicitation { return request }
                return nil
            }).first else { throw ProbeError.failure("No URL request") }
            try await control.respond(to: urlRequest, with: .confirmed(true))
            try await url.value
            try await collector.waitUntil { events in events.contains {
                if case .notice = $0 { return true }; return false
            } }
            let completionCount = collector.events.filter { if case .notice = $0 { return true }; return false }.count
            try require(completionCount == 1, "Duplicate or unknown URL completion was applied")

            let held = Task { try await control.authenticate(methodID: "verify-cancel") }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, (try? String(contentsOf: receipts, encoding: .utf8).contains("authenticate/hold")) != true {
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await control.list(cursor: nil)
            held.cancel()
            do {
                try await held.value
                throw ProbeError.failure("Cancelled request succeeded")
            } catch is CancellationError {}
            _ = try await control.list(cursor: nil)
            try await control.close()
            let trace = try String(contentsOf: receipts, encoding: .utf8)
            try require(trace.contains("$/cancel_request"),
                        "Agent did not receive the per-request cancel notification")
            return ["formValidated": true, "urlCompletionCount": completionCount, "logout": true, "cancel": true]
        } catch {
            try? await control.close()
            throw error
        }
    }

    await runCase("acp-compat/fake/extended-auth-retries-session-open") {
        let cwd = try makeSubdir("extended-auth-retry")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd, extraArgs: ["--require-auth"]))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }
        let connection = Task { try await runtime.connect() }
        do {
            try await collector.waitUntil { $0.contains { if case .interaction = $0 { return true }; return false } }
            guard let interaction = collector.events.compactMap({ event -> RuntimeInteraction? in
                if case .interaction(let request) = event { return request }; return nil
            }).first else { throw ProbeError.failure("Session open did not ask for sign-in") }
            guard let method = interaction.authenticationMethods.first(where: { $0.id == "oauth-browser" }) else {
                throw ProbeError.failure("Missing browser sign-in method")
            }
            try await runtime.respond(to: interaction, with: .value(method.id))
            let session = try await connection.value
            try require(!session.id.isEmpty, "Original session open was not retried")
            try await runtime.close(force: false)
            return ["resumedOriginalOperation": true]
        } catch {
            connection.cancel()
            try? await runtime.close(force: true)
            throw error
        }
    }

    await runCase("acp-compat/fake/extended-session-management") {
        let cwd = try makeSubdir("extended-sessions").resolvingSymlinksInPath()
        let receipts = cwd.appendingPathComponent("receipts")
        let state = cwd.appendingPathComponent("agent-state")
        let extra = ["--v1-extended", "--no-load-session", "--state-file", state.path]
        var config = fakeConfiguration(workspace: cwd, extraArgs: extra)
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipts.path]
        let first = ACPRuntime(configuration: config)
        let collector = EventCollector(runtime: first)
        defer { collector.stop() }
        let original = try await first.connect()
        try await first.close(force: false)
        let second = ACPRuntime(configuration: config)
        let collector2 = EventCollector(runtime: second)
        defer { collector2.stop() }
        _ = try await second.connect()
        try await second.close(force: false)
        let control = try await ACPAgentConnection.open(config)
        let page = try await control.list(cursor: nil)
        try require(page.canRestore && page.canDelete && page.sessions.map(\.id) == [original.id],
                    "Unexpected session list or capabilities")
        guard let cursor = page.nextCursor else { throw ProbeError.failure("Missing pagination cursor") }
        let next = try await control.list(cursor: cursor)
        try require(next.sessions.count == 1 && next.nextCursor == nil, "Failed to page session results")
        config.expectedSessionID = original.id
        let resumed = ACPRuntime(configuration: config)
        let collector3 = EventCollector(runtime: resumed)
        defer { collector3.stop() }
        let snapshot = try await resumed.connect()
        try require(snapshot.id == original.id && snapshot.resumable && !snapshot.replaysHistory, "Resume-only session was not restored")
        try await resumed.close(force: false)
        try await control.delete(sessionID: original.id)
        try await control.delete(sessionID: original.id)
        let remaining = try await control.list(cursor: nil)
        try require(!remaining.sessions.contains(where: { $0.id == original.id }), "Deleted session remained in list")
        try await control.close()
        let trace = try String(contentsOf: receipts, encoding: .utf8)
        try require(trace.contains("session/resume") && trace.contains("session/close"), "Resume or close not sent")
        return ["paginated": true, "resumedWithoutReplay": true, "closed": true, "deleted": true]
    }

    await runCase("acp-compat/fake/extended-client-services") {
        let cwd = try makeSubdir("extended-client-services").resolvingSymlinksInPath()
        let outside = try makeSubdir("extended-outside")
        try "outside".write(to: outside.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: cwd.appendingPathComponent("escape"), withDestinationURL: outside)
        var config = fakeConfiguration(workspace: cwd, extraArgs: ["--v1-extended"])
        config.clientPermissions = [.readFiles, .writeFiles, .terminals]
        var profile = RuntimeAgentProfile(id: config.runtimeID, name: "Fixture", executablePath: config.executable.path,
                                          clientPermissions: config.clientPermissions)
        let permissionStore = ACPClientPermissionStore()
        permissionStore.update([profile])
        config.permissionStore = permissionStore
        let configFile = cwd.appendingPathComponent("AGENTS.md")
        try "# Previous rules".write(to: configFile, atomically: true, encoding: .utf8)
        let receipts = cwd.appendingPathComponent("client-receipts")
        config.environmentOverrides = ["FAKE_ACP_RECEIPT": receipts.path]
        let runtime = ACPRuntime(configuration: config)
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }
        _ = try await runtime.connect()
        _ = try await runtime.send(.init(text: "verify-client-services"))
        do {
            try await collector.waitUntil {
                $0.contains { if case .interaction = $0 { return true }; return false }
            }
            guard let approval = collector.events.compactMap({ event -> RuntimeInteraction? in
                if case .interaction(let request) = event { return request }; return nil
            }).first else { throw ProbeError.failure("Missing configuration-write approval") }
            let change = approval.permissionContext?.fileDiffs.first
            guard let change else { throw ProbeError.failure("Missing configuration-write diff") }
            guard let target = realpath(change.path, nil), let expected = realpath(configFile.path, nil) else {
                throw ProbeError.failure("Configuration-write diff refers to a missing file")
            }
            defer { free(target); free(expected) }
            try require(strcmp(target, expected) == 0 && change.oldText == "# Previous rules" && change.newText == "# Fixture rules",
                        "Configuration-write diff does not match the replacement")
            try await runtime.respond(to: approval, with: .permissionOption("write"))
            try await collector.waitUntil {
                $0.contains {
                    if case .assistantCompleted(_, let text) = $0 { return text == "client services verified" }
                    return false
                }
            }
            try await collector.waitUntil {
                $0.contains { if case .settled(false) = $0 { return true }; return false }
            }
            let pidFile = cwd.appendingPathComponent("terminal.pid")
            let deadline = Date().addingTimeInterval(3)
            while !fm.fileExists(atPath: pidFile.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            guard let pid = Int32(pidText), let terminal = ProcessIdentity.read(pid) else {
                throw ProbeError.failure("Could not identify active fixture terminal")
            }
            profile.clientPermissions = [.readFiles]
            permissionStore.update([profile])
            _ = try await runtime.send(.init(text: "verify-client-read-only"))
            try await collector.waitUntil { events in
                events.filter {
                    if case .assistantCompleted(_, let response) = $0 { return response == "client services verified" }
                    return false
                }.count == 2
            }
            try await runtime.close(force: false)
            try require(ProcessIdentity.read(pid).map { $0.sameProcess(as: terminal) } != true,
                        "Session close left a terminal process running")
        } catch {
            if let data = try? Data(contentsOf: receipts) {
                try? data.write(to: output.appendingPathComponent("client-receipts.jsonl"))
            }
            try? await runtime.close(force: true)
            throw error
        }
        return ["fileRange": true, "blockedSymlink": true, "fileApproval": true, "terminalLifecycle": true,
                "permissionRevocation": true, "sessionTerminalCleanup": true]
    }

    await runCase("acp-compat/fake/extended-terminal-disconnect-cleanup") {
        let cwd = try makeSubdir("extended-terminal-disconnect").resolvingSymlinksInPath()
        var configuration = fakeConfiguration(workspace: cwd, extraArgs: ["--v1-extended"])
        configuration.clientPermissions = [.terminals]
        let runtime = ACPRuntime(configuration: configuration)
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }
        do {
            _ = try await runtime.connect()
            _ = try await runtime.send(.init(text: "verify-client-terminal-only"))
            try await collector.waitUntil { $0.contains { if case .settled(false) = $0 { return true }; return false } }
            let pidFile = cwd.appendingPathComponent("terminal.pid")
            let deadline = Date().addingTimeInterval(3)
            while !fm.fileExists(atPath: pidFile.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            guard let pid = Int32(pidText), let terminal = ProcessIdentity.read(pid) else {
                throw ProbeError.failure("Fixture terminal was not running")
            }
            await runtime.terminateRuntimeForVerification()
            try await collector.waitUntil {
                $0.contains { if case .disconnected(cleanupConfirmed: true) = $0 { return true }; return false }
            }
            try require(ProcessIdentity.read(pid).map { $0.sameProcess(as: terminal) } != true,
                        "Agent disconnect left a client terminal running")
            try await runtime.close(force: true)
            return ["terminalCleanedOnDisconnect": true]
        } catch {
            try? await runtime.close(force: true)
            throw error
        }
    }

    await runCase("acp-compat/fake/streaming-diff-plan-usage") {
        let cwd = try makeSubdir("fake-stream")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        let session = try await runtime.connect()
        try require(!session.id.isEmpty, "Missing sessionId")
        try require(!session.capabilities.contains(.queuedPrompts), "Standard ACP v1 must not claim queuedPrompts")

        let disposition = try await runtime.send(UserPrompt(text: "Please show diff and plan"))
        try require(disposition == .started, "session/prompt must return .started immediately")

        try await collector.waitUntil(timeout: 10) { events in
            events.contains { if case .settled = $0 { return true }; return false }
        }

        let captured = collector.events
        let hasAssistantText = captured.contains {
            if case .assistantCompleted(_, let text) = $0 { return text.contains("Synthetic ACP reply") }
            return false
        }
        let hasNativeDiff = captured.contains {
            if case .tool(let tool) = $0 { return tool.name == "edit" && tool.editArguments?.path == "Sources/Demo.swift" }
            return false
        }
        let hasPlan = captured.contains {
            if case .plan(let entries) = $0 { return !entries.isEmpty }
            return false
        }
        let usage = try await runtime.usage()
        try require(hasAssistantText && hasNativeDiff && hasPlan, "Missing expected stream/diff/plan events")
        try require(usage.context?.tokens == 1200 && usage.tokens.total == 1200, "Usage mapping mismatch")

        try await runtime.close(force: false)
        return [
            "sessionID": session.id,
            "hasAssistantText": hasAssistantText,
            "hasNativeDiff": hasNativeDiff,
            "hasPlan": hasPlan,
            "contextTokens": usage.context?.tokens ?? NSNull(),
            "estimatedCostUSD": usage.estimatedCostUSD ?? NSNull()
        ]
    }

    await runCase("acp-compat/fake/permission-int-and-string-ids") {
        let cwd = try makeSubdir("fake-perm")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        _ = try await runtime.connect()

        // 1. Integer ID permission -> allow_once
        _ = try await runtime.send(UserPrompt(text: "Trigger approval flow"))
        try await collector.waitUntil(timeout: 10) { events in
            events.contains { if case .interaction = $0 { return true }; return false }
        }
        let firstInteraction = collector.events.compactMap { event -> RuntimeInteraction? in
            if case .interaction(let req) = event { return req }
            return nil
        }.first
        guard let firstInteraction else { throw ProbeError.failure("Missing first permission interaction") }
        try require(firstInteraction.permissionOptions.count == 4, "Expected 4 permission options")
        try await runtime.respond(to: firstInteraction, with: .permissionOption("allow_once"))

        try await collector.waitUntil(timeout: 10) { events in
            events.contains { if case .settled(false) = $0 { return true }; return false }
        }

        // 2. String ID permission -> reject_once
        let beforeCount = collector.events.count
        _ = try await runtime.send(UserPrompt(text: "Trigger permission-string flow"))
        try await collector.waitUntil(timeout: 10) { events in
            events.dropFirst(beforeCount).contains { if case .interaction = $0 { return true }; return false }
        }
        let secondInteraction = collector.events.dropFirst(beforeCount).compactMap { event -> RuntimeInteraction? in
            if case .interaction(let req) = event { return req }
            return nil
        }.first
        guard let secondInteraction else { throw ProbeError.failure("Missing second permission interaction") }
        try await runtime.respond(to: secondInteraction, with: .permissionOption("reject_once"))

        try await collector.waitUntil(timeout: 10) { events in
            events.dropFirst(beforeCount).contains { if case .settled(false) = $0 { return true }; return false }
        }

        try await runtime.close(force: false)
        return ["intPermissionApproved": true, "stringPermissionRejected": true]
    }

    await runCase("acp-compat/fake/cancel-mid-turn") {
        let cwd = try makeSubdir("fake-cancel")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        _ = try await runtime.connect()
        _ = try await runtime.send(UserPrompt(text: "cancel-me slowly"))
        try await collector.waitUntil(timeout: 5) { events in
            events.contains { if case .tool = $0 { return true }; return false }
        }
        try await runtime.stop()
        try await collector.waitUntil(timeout: 5) { events in
            events.contains { if case .settled(true) = $0 { return true }; return false }
        }
        try await runtime.close(force: false)
        return ["cancelledMidTurn": true]
    }

    await runCase("acp-compat/fake/session-load-replay-isolation") {
        let cwd = try makeSubdir("fake-replay")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd, expectedSessionID: "replay-fixture"))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        let session = try await runtime.connect()
        try require(session.id == "replay-fixture", "Loaded session ID mismatch")
        try await collector.waitUntil(timeout: 5) { events in
            events.contains { if case .historyReplayed = $0 { return true }; return false }
        }

        let captured = collector.events
        let replayedCount = captured.compactMap { event -> Int? in
            if case .historyReplayed(let items) = event { return items.count }
            return nil
        }.first ?? 0
        let leakedLiveTurn = captured.contains { event in
            switch event {
            case .phase(.running), .runStarted, .settled: return true
            default: return false
            }
        }
        try require(replayedCount == 3, "Expected 3 replayed items (user, tool, assistant), got \(replayedCount)")
        try require(!leakedLiveTurn, "session/load replay must not emit live turn lifecycle events")
        try await runtime.close(force: false)

        // Verify --no-load-session rejects resume rather than creating a new session silently.
        let noResumeRuntime = ACPRuntime(configuration: fakeConfiguration(
            workspace: cwd,
            extraArgs: ["--no-load-session"],
            expectedSessionID: "replay-fixture"
        ))
        var rejected = false
        do {
            _ = try await noResumeRuntime.connect()
        } catch let failure as RuntimeFailure where failure.kind == .setup {
            rejected = true
        }
        try? await noResumeRuntime.close(force: true)
        try require(rejected, "Agent without loadSession must reject expectedSessionID")

        return ["replayedItems": replayedCount, "liveTurnLeaked": false, "unsupportedLoadRejected": rejected]
    }

    await runCase("acp-compat/fake/config-and-legacy-fallback") {
        let cwd = try makeSubdir("fake-config")
        // 1. configOptions path
        let modern = ACPRuntime(configuration: fakeConfiguration(workspace: cwd, extraArgs: ["--config-options-only"]))
        let s1 = try await modern.connect()
        let updated1 = try await modern.applyConfiguration(RuntimeSelection(provider: s1.provider ?? "fake-acp", modelID: "fake/model-beta", thinking: "high"))
        let modeUpdated1 = try await modern.setMode("plan")
        try require(updated1.modelID == "fake/model-beta" && updated1.thinking == "high", "configOptions update mismatch")
        try require(modeUpdated1.modeID == "plan", "configOptions mode update mismatch")
        try await modern.close(force: false)

        // 2. legacy models/modes path
        let legacy = ACPRuntime(configuration: fakeConfiguration(workspace: cwd, extraArgs: ["--legacy-models"]))
        let s2 = try await legacy.connect()
        let updated2 = try await legacy.applyConfiguration(RuntimeSelection(provider: s2.provider ?? "fake-acp", modelID: "fake/model-beta", thinking: nil))
        let modeUpdated2 = try await legacy.setMode("accept-edits")
        try require(updated2.modelID == "fake/model-beta" && modeUpdated2.modeID == "accept-edits", "legacy set_model/set_mode mismatch")
        try await legacy.close(force: false)

        return ["configOptionsVerified": true, "legacyFallbackVerified": true]
    }

    await runCase("acp-compat/fake/supervision-crash-cleanup") {
        let cwd = try makeSubdir("fake-crash")
        let runtime = ACPRuntime(configuration: fakeConfiguration(workspace: cwd))
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        _ = try await runtime.connect()
        _ = try await runtime.send(UserPrompt(text: "crash-worker"))

        try await collector.waitUntil(timeout: 8) { events in
            events.contains { if case .disconnected = $0 { return true }; return false }
        }
        let heartbeatURL = cwd.appendingPathComponent("heartbeat")
        if fm.fileExists(atPath: heartbeatURL.path) {
            let before = try Data(contentsOf: heartbeatURL).count
            try await Task.sleep(for: .milliseconds(250))
            let after = try Data(contentsOf: heartbeatURL).count
            try require(before == after, "Detached worker continued writing heartbeat after supervised crash")
        }
        try await runtime.close(force: true)
        return ["detachedWorkerCleaned": true]
    }
}

// MARK: - Local Suite (Zero-Inference Probe Against Real ACP Binary e.g. `agy acp`)

if suite == "local" {
    await runCase("acp-compat/local/initialize-and-session-new") {
        let cwd = option("--cwd") != nil ? baseCWD : try makeSubdir("local-probe")
        let config = ACPConfiguration(
            executable: URL(fileURLWithPath: targetCommand),
            arguments: targetArgs,
            workspace: cwd,
            runtimeID: RuntimeAgentProfile.antigravityRuntimeID,
            proxy: proxy
        )
        let environment = try config.launchEnvironment(inheriting: ProcessInfo.processInfo.environment)

        let transport = try JSONRPCProcess(
            executable: config.executable.path,
            arguments: config.arguments,
            cwd: cwd,
            environment: environment,
            supervised: supervised,
            supervisionRoot: tempWork
        )

        var observed: Record = [
            "command": config.executable.path,
            "arguments": config.arguments,
            "supervised": supervised
        ]

        let initParams: Record = [
            "protocolVersion": ACPProtocol.supportedVersion,
            "clientInfo": ["name": "zivvi-probe", "version": "1.0"] as Record,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false] as Record,
                "terminal": false
            ] as Record
        ]
        let initResp = try transport.request(
            method: ACPProtocol.Method.initialize,
            params: initParams,
            timeout: 15
        )
        try require(!initResp.isError, "initialize returned JSON-RPC error: \(initResp.error?.description ?? "unknown")")
        guard let initRecord = initResp.resultRecord else {
            throw ProbeError.failure("initialize returned non-object result")
        }
        guard let parsedInit = ACPInitializeResult.parse(initRecord) else {
            throw ProbeError.failure("Could not parse initialize result")
        }
        try require(parsedInit.protocolVersion == 1, "Expected protocolVersion == 1, got \(parsedInit.protocolVersion)")

        let agentInfoSummary: Record = [
            "name": parsedInit.agentInfo?.name ?? NSNull(),
            "title": parsedInit.agentInfo?.title ?? NSNull(),
            "version": parsedInit.agentInfo?.version ?? NSNull()
        ]
        let capabilitiesSummary: Record = [
            "loadSession": parsedInit.agentCapabilities.loadSession,
            "imagePrompt": parsedInit.agentCapabilities.promptCapabilities.image,
            "audioPrompt": parsedInit.agentCapabilities.promptCapabilities.audio,
            "embeddedContext": parsedInit.agentCapabilities.promptCapabilities.embeddedContext,
            "mcpHTTP": parsedInit.agentCapabilities.mcpCapabilities.http,
            "mcpSSE": parsedInit.agentCapabilities.mcpCapabilities.sse
        ]
        let authMethodsSummary: [Record] = parsedInit.authMethods.map { method in
            ["id": method.id, "name": method.name]
        }
        let initializeSummary: Record = [
            "protocolVersion": parsedInit.protocolVersion,
            "topLevelKeys": sanitizeKeys(initRecord),
            "agentInfo": agentInfoSummary,
            "agentCapabilities": capabilitiesSummary,
            "authMethods": authMethodsSummary
        ]
        observed["initialize"] = initializeSummary

        let sessionResp = try transport.request(
            method: ACPProtocol.Method.sessionNew,
            params: ["cwd": cwd.path, "mcpServers": [] as [Any]],
            timeout: 20
        )

        if let rpcError = sessionResp.error {
            let errorSummary: Record = [
                "errorCode": rpcError.code,
                "authRequired": ACPJSONRPCError(rpcError: rpcError).isAuthRequired
            ]
            observed["sessionNew"] = errorSummary
        } else if let sessionRecord = sessionResp.resultRecord {
            let meta = ACPSessionMetadata.parse(sessionRecord)
            let defaultProvider = parsedInit.agentInfo?.name ?? "acp"
            let modesList: [Record] = meta.availableModesList().map { mode in
                ["id": mode.id, "name": mode.name]
            }
            let modelsList: [Record] = meta.availableRuntimeModels(defaultProvider: defaultProvider).map { model in
                ["id": model.modelID, "name": model.name]
            }
            let configOptionsList: [Record] = meta.configOptions.map { option in
                [
                    "id": option.id,
                    "category": option.category ?? NSNull(),
                    "currentValue": option.currentValue,
                    "optionCount": option.options.count
                ]
            }
            let sessionSummary: Record = [
                "topLevelKeys": sanitizeKeys(sessionRecord),
                "hasSessionId": (sessionRecord["sessionId"] as? String)?.isEmpty == false,
                "currentModeId": meta.currentModeID() ?? NSNull(),
                "modes": modesList,
                "currentModelId": meta.currentModelID() ?? NSNull(),
                "models": modelsList,
                "configOptions": configOptionsList
            ]
            observed["sessionNew"] = sessionSummary
        }

        try transport.close(timeout: 5)
        let supervisionState = transport.supervisionStatus["state"] as? String ?? (supervised ? "unknown" : "unsupervised")
        observed["supervisionState"] = supervisionState
        if supervised {
            try require(supervisionState == "clean", "Expected clean supervised shutdown, got \(supervisionState)")
        }

        try save(observed, "local-probe-observed.json")
        return observed
    }

    await runCase("acp-compat/local/runtime-self-check") {
        let cwd = option("--cwd") != nil ? baseCWD : try makeSubdir("local-self-check")
        let config = ACPConfiguration(
            executable: URL(fileURLWithPath: targetCommand),
            arguments: targetArgs,
            workspace: cwd,
            runtimeID: RuntimeAgentProfile.antigravityRuntimeID,
            proxy: proxy
        )
        let check = await ACPRuntime.checkConnection(config)
        try require(check.dependencyFailure == nil, "Dependency failure: \(String(describing: check.dependencyFailure))")
        try require(check.protocolVersion == .compatible(1), "Expected protocolVersion compatible(1), got \(check.protocolVersion)")
        try require(!check.cleanupUnconfirmed, "Supervised cleanup was not confirmed")

        var inspectedModels: [String] = []
        var inspectedThinking: [String] = []
        if check.isReady {
            let options = try await ACPRuntime.inspectModels(config, model: nil)
            inspectedModels = options.models.map(\.modelID)
            inspectedThinking = options.thinkingLevels
        }

        return [
            "isReady": check.isReady,
            "agentName": check.agentName ?? NSNull(),
            "agentVersion": check.agentVersion ?? NSNull(),
            "authRequired": check.authRequired,
            "loadSession": check.capabilitiesSummary.loadSession,
            "imagePrompt": check.capabilitiesSummary.imagePrompt,
            "modesCount": check.capabilitiesSummary.modesCount,
            "modelsCount": check.capabilitiesSummary.modelsCount,
            "inspectedModels": inspectedModels,
            "inspectedThinkingLevels": inspectedThinking,
            "cleanupUnconfirmed": check.cleanupUnconfirmed
        ]
    }
}

// MARK: - Real Suite (Explicit Authorization, Model Inference)

if suite == "real" {
    await runCase("acp-compat/real/connect-prompt-and-resume") {
        let cwd = option("--cwd") != nil ? baseCWD : try makeSubdir("real-turn")
        let config = ACPConfiguration(
            executable: URL(fileURLWithPath: targetCommand),
            arguments: targetArgs,
            workspace: cwd,
            runtimeID: RuntimeAgentProfile.antigravityRuntimeID,
            proxy: proxy
        )
        let runtime = ACPRuntime(configuration: config)
        let collector = EventCollector(runtime: runtime)
        defer { collector.stop() }

        let session = try await runtime.connect()
        let promptText = customPrompt ?? "Reply with exactly the single word: PONG. Do not call any tools."
        let disposition = try await runtime.send(UserPrompt(text: promptText))
        try require(disposition == .started, "Expected .started disposition")

        // Handle any unexpected permission prompts safely while waiting for settlement.
        let deadline = Date().addingTimeInterval(120)
        var handledInteractions = Set<String>()
        var settled = false
        while Date() < deadline && !settled {
            for event in collector.events {
                switch event {
                case .interaction(let req) where handledInteractions.insert(req.id).inserted:
                    if allowRealPermissions, let allow = req.permissionOptions.first(where: \.isAllow) {
                        try? await runtime.respond(to: req, with: .permissionOption(allow.id))
                    } else {
                        try? await runtime.respond(to: req, with: .cancelled)
                    }
                case .settled:
                    settled = true
                default:
                    break
                }
            }
            if !settled {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try require(settled, "Real ACP prompt turn did not settle within 120s")

        let replyChars = collector.events.reduce(into: 0) { count, event in
            if case .assistantCompleted(_, let text) = event { count += text.count }
        }
        try await runtime.close(force: false)

        var resumed = false
        if session.resumable {
            var resumeConfig = config
            resumeConfig.expectedSessionID = session.id
            let resumedRuntime = ACPRuntime(configuration: resumeConfig)
            let resumeCollector = EventCollector(runtime: resumedRuntime)
            defer { resumeCollector.stop() }
            let loaded = try await resumedRuntime.connect()
            resumed = (loaded.id == session.id)
            try await resumedRuntime.close(force: false)
        }

        return [
            "sessionID": session.id,
            "model": session.model,
            "modeID": session.modeID ?? NSNull(),
            "replyChars": replyChars,
            "resumable": session.resumable,
            "resumedCleanly": resumed
        ]
    }
}

try save([
    "runID": runID,
    "suite": suite,
    "command": suite == "fake" ? fakeFixtureURL.path : targetCommand,
    "arguments": suite == "fake" ? [] : targetArgs,
    "results": results
], "run.json")

print("Evidence: \(output.path)")
let hasFailure = results.contains { $0["status"] as? String == "fail" }
try? fm.removeItem(at: tempWork)
exit(hasFailure ? 1 : 0)
