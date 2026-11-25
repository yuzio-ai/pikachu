import ACPRuntimeAdapter
import AgentRuntimeCore
import Darwin
import Foundation
import OrchestrationCore
import XCTest
@testable import Pikachu

@MainActor final class ACPSessionTitleTests: XCTestCase {
    private let provider = "@agentclientprotocol/claude-agent-acp"

    func testCatalogueUsesACPSessionWithoutInference() async throws {
        let fixture = try TitleFixture()
        defer { fixture.remove() }
        let catalogue = try await ACPRuntime.titleModels(fixture.config)
        XCTAssertEqual(catalogue?.map(\.modelID), ["agent-default", "chosen"])
        XCTAssertEqual(catalogue?.first?.provider, provider)
        let records = try fixture.records()
        XCTAssertEqual(records.compactMap { $0["method"] as? String }, ["initialize", "session/new"])
        XCTAssertTrue(records.allSatisfy { $0["kind"] as? String == "bridge" })
        let session = try XCTUnwrap(records.last)
        let params = try XCTUnwrap(session["params"] as? [String: Any])
        XCTAssertEqual(params["mcpServers"] as? [String], [])
        let meta = try XCTUnwrap(params["_meta"] as? [String: [String: [String: Any]]])
        let options = try XCTUnwrap(meta["claudeCode"]?["options"])
        XCTAssertEqual(options["persistSession"] as? Bool, false)
        XCTAssertEqual(options["strictMcpConfig"] as? Bool, true)
        XCTAssertEqual(options["settingSources"] as? [String], [])
        XCTAssertEqual(options["disallowedTools"] as? [String], ["*"])
        XCTAssertNotNil((options["extraArgs"] as? [String: NSNull])?["bare"])
        XCTAssertEqual(session["bareEnvironment"] as? String, "1")
        try assertClean(records)
    }

    func testHeadlessTitlePinsAgentDefaultOrChosenModelWithoutSendingAnACPPrompt() async throws {
        let choice = RuntimeModel(provider: provider, modelID: "chosen", name: "Chosen")
        let firstMessage = "/command\n" + String(repeating: "上下文🙂", count: 7_500) + "\nFix @search"
        for model: RuntimeModel? in [nil, choice] {
            let fixture = try TitleFixture()
            defer { fixture.remove() }
            let result = try await ACPRuntime.generateSessionTitle(fixture.config, model: model, rules: "Use Chinese", text: firstMessage)
            guard case .finished(let title) = result else { return XCTFail("Expected a supported title operation") }
            XCTAssertEqual(title, "侧栏 · 修复搜索")
            let records = try fixture.records()
            XCTAssertEqual(records.compactMap { $0["method"] as? String }, ["initialize", "session/new"])
            let launches = records.filter { $0["kind"] as? String == "native" }
            XCTAssertEqual(launches.count, 1)
            let launch = try XCTUnwrap(launches.first)
            let arguments = try XCTUnwrap(launch["arguments"] as? [String])
            let values = ["--model": model?.modelID ?? "agent-default", "--tools": "", "--setting-sources": "",
                          "--max-turns": "1", "--disallowedTools": "*", "--fallback-model": ""]
            for (flag, expected) in values {
                let index = try XCTUnwrap(arguments.firstIndex(of: flag))
                XCTAssertEqual(arguments.dropFirst(index + 1).first, expected)
            }
            XCTAssertTrue(arguments.contains("--strict-mcp-config"))
            XCTAssertTrue(arguments.contains("--no-session-persistence"))
            XCTAssertTrue(arguments.contains("--bare"))
            XCTAssertTrue(arguments.contains("--disable-slash-commands"))
            XCTAssertEqual(launch["autoTitle"] as? String, "1")
            XCTAssertEqual(launch["nonessential"] as? String, "1")
            XCTAssertTrue((launch["instructions"] as? String)?.contains("Use Chinese") == true)
            XCTAssertFalse(arguments.joined().contains("Use Chinese"))
            let settings = try XCTUnwrap(launch["settings"] as? [String: Any])
            XCTAssertEqual(settings["disableAllHooks"] as? Bool, true)
            XCTAssertEqual(settings["autoMemoryEnabled"] as? Bool, false)
            XCTAssertEqual(settings["disableClaudeAiConnectors"] as? Bool, true)
            XCTAssertEqual(settings["fallbackModel"] as? [String], [])
            XCTAssertEqual(launch["fallbackGuards"] as? [String], ["1", "1", "1"])
            let text = try XCTUnwrap(launch["input"] as? String)
            XCTAssertFalse(text.contains("@"))
            XCTAssertFalse(launch["inputPathExists"] as? Bool ?? true)
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(text.utf8)), ["firstMessage": firstMessage])
            try assertClean(records)
        }
    }

    func testUnsupportedLaunchersAndUnavailableModelDoNotReceiveInput() async throws {
        for mode in ["old-bridge", "old-native", "unavailable", "subscription-only"] {
            let fixture = try TitleFixture(mode: mode)
            defer { fixture.remove() }
            let model = RuntimeModel(provider: provider, modelID: "unavailable", name: "Unavailable")
            let result = try await ACPRuntime.generateSessionTitle(fixture.config, model: model, rules: "", text: "private input")
            switch (mode, result) {
            case ("old-bridge", .unsupported), ("old-native", .unsupported), ("subscription-only", .unsupported),
                 ("unavailable", .finished(nil)): break
            default: XCTFail("Expected local fallback for \(mode)")
            }
            let records = try fixture.records()
            XCTAssertFalse(records.contains { $0["kind"] as? String == "native" || $0["method"] as? String == "session/prompt" })
            try assertClean(records)
        }
    }

    func testTimeoutAndUnsuccessfulNativeRunsKeepTheLocalTitle() async throws {
        for mode in ["timeout", "ignored-stdin", "multiple-turns", "multiple-results", "multiple-models", "nonzero-exit"] {
            let fixture = try TitleFixture(mode: mode)
            defer { fixture.remove() }
            let text = String(repeating: "Long title input\n", count: 10_000)
            let result = try await ACPRuntime.generateSessionTitle(fixture.config, model: nil, rules: "", text: text, timeout: 0.3)
            guard case .finished(nil) = result else { return XCTFail("Expected local fallback for \(mode)") }
            let records = try fixture.records()
            XCTAssertEqual(records.filter { $0["kind"] as? String == "native" }.count, 1)
            try assertClean(records)
        }
    }

    func testAutomaticSkipsProbeFailureAndKeepsAChosenAgentsFailureLocal() async throws {
        let failingProbe = try TitleFixture(mode: "probe-failure", runtimeID: "acp:first")
        defer { failingProbe.remove() }
        let second = try TitleFixture(runtimeID: "acp:second")
        defer { second.remove() }
        let choice = RuntimeModel(provider: provider, modelID: "chosen", name: "Chosen")
        let title = await AppSettings.generateTitle(.init(), text: "Fix search",
                                                    configurations: [failingProbe.config, second.config]) { _ in choice }
        XCTAssertEqual(title, "侧栏 · 修复搜索")
        XCTAssertFalse(try failingProbe.records().contains { $0["kind"] as? String == "native" })
        let launched = try XCTUnwrap(second.records().first { $0["kind"] as? String == "native" })
        XCTAssertTrue((launched["arguments"] as? [String])?.contains("chosen") == true)

        let failingInference = try TitleFixture(mode: "nonzero-exit", runtimeID: "acp:failed")
        defer { failingInference.remove() }
        let untouched = try TitleFixture(runtimeID: "acp:unused")
        defer { untouched.remove() }
        let fallback = await AppSettings.generateTitle(.init(), text: "Keep local",
                                                       configurations: [failingInference.config, untouched.config]) { _ in nil }
        XCTAssertNil(fallback)
        XCTAssertEqual(try failingInference.records().filter { $0["kind"] as? String == "native" }.count, 1)
        let missing = SessionTitleModel(runtimeID: failingInference.config.runtimeID,
                                        model: .init(provider: provider, modelID: "removed", name: "Removed"))
        let specified = await AppSettings.generateTitle(.init(mode: .specified, model: missing), text: "Keep local",
                                                        configurations: [untouched.config, failingInference.config]) { _ in nil }
        XCTAssertNil(specified)
        XCTAssertTrue(try untouched.records().isEmpty)
        XCTAssertEqual(try failingInference.records().filter { $0["kind"] as? String == "native" }.count, 1)
        let unsupported = await AppSettings.generateTitle(.init(), text: "Keep local", configurations: []) { _ in nil }
        XCTAssertNil(unsupported)
    }

    private func assertClean(_ records: [[String: Any]]) throws {
        for record in records {
            let cwd = try XCTUnwrap(record["cwd"] as? String)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cwd))
            let pid = try XCTUnwrap(record["pid"] as? Int32)
            let status = kill(pid, 0)
            let signalError = errno
            XCTAssertEqual(status, -1)
            XCTAssertEqual(signalError, ESRCH)
        }
    }
}

private struct TitleFixture {
    let root: URL
    let config: ACPConfiguration

    init(mode: String = "normal", runtimeID: String = "acp:fixture") throws {
        let files = FileManager.default
        root = files.temporaryDirectory.appendingPathComponent("Pikachu-TitleFixture-\(UUID())")
        let modules = root.appendingPathComponent("node_modules")
        let bridge = modules.appendingPathComponent("@agentclientprotocol/claude-agent-acp/dist/index.js")
        let sdk = modules.appendingPathComponent("@anthropic-ai/claude-agent-sdk/package.json")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let native = modules.appendingPathComponent("@anthropic-ai/claude-agent-sdk-darwin-\(architecture)/claude")
        let receipt = root.appendingPathComponent("events.jsonl")
        do {
            for executable in [bridge, native] {
                try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.script.write(to: executable, atomically: true, encoding: .utf8)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            try files.createDirectory(at: sdk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: sdk)
            try Data().write(to: receipt)
        } catch {
            try? files.removeItem(at: root)
            throw error
        }
        var environment = ["PIKACHU_TITLE_FIXTURE_MODE": mode, "PIKACHU_TITLE_FIXTURE_LOG": receipt.path,
                           "CLAUDE_CODE_EXECUTABLE": "", "CLAUDE_MODEL_CONFIG": "",
                           "ANTHROPIC_API_KEY": mode == "subscription-only" ? "" : "synthetic-key",
                           "CLAUDE_CODE_USE_BEDROCK": "", "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": ""]
        if mode == "old-native" { environment["CLAUDE_CODE_EXECUTABLE"] = native.path }
        config = ACPConfiguration(executable: bridge, arguments: [], workspace: root, runtimeID: runtimeID,
                                  environmentOverrides: environment)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func records() throws -> [[String: Any]] {
        let contents = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        return try contents.split(whereSeparator: \.isNewline).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private static let script = """
    #!/usr/bin/python3
    import json, os, sys, time
    mode = os.environ["PIKACHU_TITLE_FIXTURE_MODE"]
    receipt = os.environ["PIKACHU_TITLE_FIXTURE_LOG"]

    def log(record):
        record.update(cwd=os.getcwd(), pid=os.getpid())
        with open(receipt, "a", encoding="utf-8") as output:
            print(json.dumps(record), file=output)

    if "--version" in sys.argv:
        print("2.1.292 (Claude Code)" if mode == "old-native" else "2.1.293 (Claude Code)")
        sys.exit(0)

    if "--print" in sys.argv:
        def flag(name):
            return sys.argv[sys.argv.index(name) + 1]
        log({"kind": "native", "arguments": sys.argv[1:], "input": None if mode == "ignored-stdin" else sys.stdin.read(),
             "inputPathExists": os.path.exists("first-message.json"),
             "autoTitle": os.environ.get("CLAUDE_CODE_DISABLE_TERMINAL_TITLE"),
             "nonessential": os.environ.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"),
             "fallbackGuards": [os.environ.get("CLAUDE_CODE_" + key) for key in
                                ["DISABLE_MODEL_ACCESS_FALLBACK", "DISABLE_REFUSAL_FALLBACK", "NO_MODEL_FALLBACK"]],
             "settings": json.load(open(flag("--settings"), encoding="utf-8")),
             "instructions": open(flag("--system-prompt-file"), encoding="utf-8").read()})
        if mode in ("timeout", "ignored-stdin"):
            time.sleep(20)
        result = {"type": "result", "subtype": "success", "is_error": False,
                  "num_turns": 2 if mode == "multiple-turns" else 1, "result": "侧栏 · 修复搜索",
                  "modelUsage": {flag("--model"): {"outputTokens": 1}}}
        if mode == "multiple-models":
            result["modelUsage"]["unexpected-model"] = {"outputTokens": 1}
        print(json.dumps(result), flush=True)
        if mode == "multiple-results":
            print(json.dumps(result), flush=True)
        sys.exit(1 if mode == "nonzero-exit" else 0)

    for line in sys.stdin:
        command = json.loads(line)
        command["kind"] = "bridge"
        command["bareEnvironment"] = os.environ.get("CLAUDE_CODE_SIMPLE")
        log(command)
        kind = command["method"]
        if kind == "initialize":
            if mode == "probe-failure":
                print(json.dumps({"jsonrpc": "2.0", "id": command["id"],
                                  "error": {"code": -32603, "message": "Probe failed"}}), flush=True)
                continue
            result = {"protocolVersion": 1, "agentInfo": {"name": "@agentclientprotocol/claude-agent-acp",
                      "version": "0.87.0" if mode == "old-bridge" else "0.88.0"}}
        elif kind == "session/new":
            result = {"sessionId": "title", "models": {"currentModelId": "agent-default", "availableModels": [
                       {"modelId": "agent-default", "name": "Agent default"}, {"modelId": "chosen", "name": "Chosen"}]}}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": command["id"], "result": result}), flush=True)
    """
}
