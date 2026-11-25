import AppKit
import Foundation
import XCTest
import AgentRuntimeCore
@testable import Pikachu

@MainActor final class ACPAgentRegistryTests: XCTestCase {
    private let manifest = Data(#"""
    {"version":"1.0.0","agents":[
      {"id":"antigravity-acp","name":"Google Antigravity","description":"Google Agent",
       "distribution":{"binary":{"darwin-aarch64":{"cmd":"./agy_acp_server.par"}}}},
      {"id":"antigravity-acp","name":"Duplicate","description":"",
       "distribution":{}},
      {"id":"codex-acp","name":"Codex","description":"OpenAI Agent",
       "distribution":{"npx":{"package":"@agentclientprotocol/codex-acp@2.10.0","args":["--stdio",""]}}},
      {"id":"fixture","name":"Fixture Agent","description":"",
       "distribution":{"binary":{
        "darwin-aarch64":{"cmd":"./archive/bin/pikachu-test-arm-agent","args":["--arm"]},
        "darwin-x86_64":{"cmd":"./pikachu-test-intel-agent","args":["--intel"]}
       }}},
      {"id":"minion-code","name":"Minion Code","description":"",
       "distribution":{"npx":{"package":"unverified-minion@0.1.0","args":["--npm"]},
                       "uvx":{"package":"minion-code@0.1.44","args":["acp"]}}},
      {"id":"unknown","name":"Unknown Package","description":"",
       "distribution":{"npx":{"package":"unverified-agent@1.0.0","args":["--acp"]}}},
      {"id":"kimi","name":"Kimi CLI (Legacy)","description":"",
       "distribution":{"binary":{"darwin-aarch64":{"cmd":"./kimi","args":["acp"]}}}},
      {"id":"kimi-code","name":"Kimi Code","description":"",
       "distribution":{"npx":{"package":"@moonshot-ai/kimi-code@2.7.3","args":["acp"]}}}
    ]}
    """#.utf8)

    func testSearchUsesRegistryNameAndIDAndDeduplicatesAntigravity() throws {
        let registry = try ACPAgentRegistry(data: manifest)
        XCTAssertEqual(registry.matching("  ANTIGRAVITY ").map(\.name), ["Google Antigravity"])
        XCTAssertEqual(registry.matching("codex-acp").map(\.name), ["Codex"])
        XCTAssertEqual(registry.matching("fixture agent").map(\.id), ["fixture"])
        XCTAssertTrue(registry.matching("missing-agent").isEmpty)
        XCTAssertEqual(registry.matching("").count, 7)
    }

    func testBundledRegistryLogosDecodeAndRender() throws {
        struct Entry: Decodable { let id: String }
        let index = try XCTUnwrap(Bundle.main.url(forResource: "Index", withExtension: "json", subdirectory: "ACPAgentLogos"))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))
        XCTAssertEqual(Set(entries.map(\.id)).count, 46)
        for entry in entries {
            let image = try XCTUnwrap(ACPRegistryLogos.image(for: entry.id), entry.id)
            XCTAssertTrue(image.isTemplate, entry.id)
            let tiff = try XCTUnwrap(image.tiffRepresentation, entry.id)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), entry.id)
            let hasVisiblePixels = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
            }
            XCTAssertTrue(hasVisiblePixels, entry.id)
        }
    }

    func testRegistryLogoFollowsSavedProfileWhenRenamedAndRecognizesOlderProfiles() throws {
        let agent = try XCTUnwrap(ACPAgentRegistry(data: manifest).matching("codex").first)
        var draft = ACPAgentDraft(agent: agent, defaults: agent.launchDefaults())
        draft.name = "My OpenAI Agent"
        let profile = try XCTUnwrap(draft.profile(existingAgents: []))
        let saved = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(RuntimeAgentProfile.self, from: saved)
        XCTAssertEqual(restored.registryID, "codex-acp")
        XCTAssertEqual(ACPRegistryLogos.registryID(for: restored), "codex-acp")

        let old = Data(#"{"id":"acp:legacy-codex","name":" Codex ","executablePath":"codex-acp"}"#.utf8)
        let legacy = try JSONDecoder().decode(RuntimeAgentProfile.self, from: old)
        XCTAssertNil(legacy.registryID)
        XCTAssertEqual(ACPRegistryLogos.registryID(for: legacy), "codex-acp")
        XCTAssertEqual(ACPRegistryLogos.registryID(for: .antigravityPreset()), "antigravity-acp")
        XCTAssertNil(ACPRegistryLogos.registryID(for: .customACP(name: "Local Agent", executablePath: "local-acp")))
        XCTAssertNil(ACPRegistryLogos.image(for: "unknown-registry-agent"))
    }

    func testRegistryFailureCanBeRetriedAndManualEntryIsIndependent() async throws {
        let fixture = manifest
        do {
            _ = try await ACPAgentRegistry.load { request in
                XCTAssertEqual(request.url, ACPAgentRegistry.endpoint)
                return (fixture, Self.response(status: 503))
            }
            XCTFail("Expected registry load to fail")
        } catch let failure as URLError {
            XCTAssertEqual(failure.code, .badServerResponse)
        }

        var manual = ACPAgentDraft()
        manual.name = "Manual Agent"
        manual.executable = "manual-acp"
        manual.arguments = "--stdio"
        XCTAssertEqual(manual.profile(existingAgents: [])?.arguments, ["--stdio"])

        let registry = try await ACPAgentRegistry.load { _ in
            (fixture, Self.response(status: 200))
        }
        XCTAssertEqual(registry.matching("fixture").map(\.id), ["fixture"])
    }

    func testPlatformAndPackageDefaultsAreDirectCommands() throws {
        let registry = try ACPAgentRegistry(data: manifest)
        let fixture = try XCTUnwrap(registry.matching("fixture").first)
        XCTAssertEqual(fixture.launchDefaults(target: "darwin-aarch64"),
                       .init(executable: "pikachu-test-arm-agent", arguments: ["--arm"]))
        XCTAssertEqual(fixture.launchDefaults(target: "darwin-x86_64"),
                       .init(executable: "pikachu-test-intel-agent", arguments: ["--intel"]))

        let codex = try XCTUnwrap(registry.matching("codex").first).launchDefaults()
        XCTAssertEqual((codex.executable as NSString).lastPathComponent, "codex-acp")
        XCTAssertEqual(codex.arguments, ["--stdio", ""])
        let minion = try XCTUnwrap(registry.matching("minion").first).launchDefaults()
        XCTAssertEqual((minion.executable as NSString).lastPathComponent, "mcode")
        XCTAssertEqual(minion.arguments, ["acp"])
        let unknown = try XCTUnwrap(registry.matching("unknown").first).launchDefaults()
        XCTAssertEqual(unknown, .init(executable: "", arguments: ["--acp"]))
    }

    func testAntigravityReusesLocalCLIAndExistingPresetIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agy = try makeFile(".local/bin/agy", under: root, mode: 0o755)
        let registry = try ACPAgentRegistry(data: manifest)
        let antigravity = try XCTUnwrap(registry.matching("antigravity").first)
        let lookup = ACPExecutableLookup(environment: [:], homeDirectory: root)
        let defaults = antigravity.launchDefaults(target: "darwin-aarch64", lookup: lookup)
        XCTAssertEqual(defaults, .init(executable: agy.path, arguments: ["acp"]))

        let draft = ACPAgentDraft(agent: antigravity, defaults: defaults)
        let original = try XCTUnwrap(draft.profile(existingAgents: []))
        XCTAssertEqual(original.id, RuntimeAgentProfile.antigravityRuntimeID)
        let additional = try XCTUnwrap(draft.profile(existingAgents: [original]))
        XCTAssertNotEqual(additional.id, original.id)
        XCTAssertTrue(additional.isAntigravityPreset)
    }

    func testEditableDefaultsCanBeSavedBeforeCheckingAndRecheckedAfterChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try makeFile("tools/pikachu-test-arm-agent", under: root, mode: 0o755)
        let nonExecutable = try makeFile("tools/pikachu-test-disabled", under: root, mode: 0o644)
        let tools = command.deletingLastPathComponent()
        let registry = try ACPAgentRegistry(data: manifest)
        let agent = try XCTUnwrap(registry.matching("fixture").first)
        let lookup = ACPExecutableLookup(environment: [:], homeDirectory: root)
        var draft = ACPAgentDraft(agent: agent, defaults: agent.launchDefaults(target: "darwin-aarch64", lookup: lookup))
        XCTAssertEqual(draft.name, "Fixture Agent")
        XCTAssertTrue(draft.canSubmit)
        XCTAssertNil(draft.checkInput.installedPath(using: lookup))

        draft.toolSearchPaths = [tools.path]
        let firstCheck = draft.checkInput
        XCTAssertEqual(firstCheck.installedPath(using: lookup), command.path)
        XCTAssertEqual(lookup.launchURL(for: draft.executable, toolDirectories: draft.toolSearchPaths), command)

        let arguments = ["--stdio", "", "two words", "it's", #"a\b"#, #"a"b"#]
        draft.arguments = ACPArgumentsParser.format(arguments)
        XCTAssertNotEqual(draft.checkInput, firstCheck)
        XCTAssertEqual(draft.profile(existingAgents: [])?.arguments, arguments)
        XCTAssertEqual(draft.checkInput.installedPath(using: lookup), command.path)

        draft.executable = nonExecutable.path
        XCTAssertNil(draft.checkInput.installedPath(using: lookup))
        draft.executable = tools.path
        XCTAssertNil(draft.checkInput.installedPath(using: lookup))
        draft.executable = "~/tools/pikachu-test-arm-agent"
        XCTAssertEqual(draft.checkInput.installedPath(using: lookup), command.path)
        draft.executable = "/usr/local/bin/npx"
        XCTAssertFalse(draft.canSubmit)
    }

    func testKimiCodeAndLegacyUseDifferentLocalExecutables() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try makeFile("legacy/bin/kimi", under: root, mode: 0o755)
        let installed = try makeFile("npm/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs", under: root, mode: 0o755)
        let package = installed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
        try Data(#"{"name":"@moonshot-ai/kimi-code"}"#.utf8).write(to: package)
        let npmBin = root.appendingPathComponent("npm/bin")
        try FileManager.default.createDirectory(at: npmBin, withIntermediateDirectories: true)
        let npmCommand = npmBin.appendingPathComponent("kimi")
        try FileManager.default.createSymbolicLink(at: npmCommand, withDestinationURL: installed)

        let registry = try ACPAgentRegistry(data: manifest)
        let legacyEntry = try XCTUnwrap(registry.matching("").first { $0.id == "kimi" })
        let codeEntry = try XCTUnwrap(registry.matching("kimi-code").first)
        let lookup = ACPExecutableLookup(environment: [:], homeDirectory: root)
        let directories = [legacy.deletingLastPathComponent().path, npmBin.path]
        XCTAssertEqual(legacyEntry.launchDefaults(target: "darwin-aarch64", lookup: lookup,
                                                 toolDirectories: directories).executable, legacy.path)
        XCTAssertEqual(legacyEntry.launchDefaults(target: "darwin-x86_64", lookup: lookup,
                                                 toolDirectories: directories).executable, "")
        XCTAssertEqual(codeEntry.launchDefaults(lookup: lookup, toolDirectories: directories).executable, npmCommand.path)
    }

    private nonisolated static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: ACPAgentRegistry.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeFile(_ path: String, under directory: URL, mode: Int) throws -> URL {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
}
