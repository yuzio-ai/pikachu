import Foundation
import ACPRuntimeAdapter

struct ACPAgentRegistry: Sendable {
    static let endpoint = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    let agents: [ACPRegistryAgent]

    private struct Manifest: Decodable {
        let agents: [ACPRegistryAgent]
    }

    static func load(using fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) async throws -> Self {
        let (data, response) = try await fetch(URLRequest(url: endpoint, timeoutInterval: 10))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self(data: data)
    }

    init(data: Data) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        var ids = Set<String>()
        agents = manifest.agents.filter { ids.insert($0.id).inserted }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func matching(_ query: String) -> [ACPRegistryAgent] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return agents }
        return agents.filter { $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
    }
}

struct ACPRegistryAgent: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    private let distribution: Distribution

    var isAntigravity: Bool { id == "antigravity-acp" }

    private struct Distribution: Decodable, Sendable {
        struct Binary: Decodable, Sendable {
            let cmd: String
            let args: [String]?
        }

        struct Package: Decodable, Sendable {
            let package: String
            let args: [String]?

            var name: String {
                let start = package.hasPrefix("@") ? package.index(after: package.startIndex) : package.startIndex
                let end = package[start...].firstIndex { $0 == "@" || $0 == "=" } ?? package.endIndex
                return String(package[..<end])
            }
        }

        let binary: [String: Binary]?
        let npx: Package?
        let uvx: Package?
    }

    struct LaunchDefaults: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    static let macOSTarget: String = {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }()

    func launchDefaults(
        target: String = Self.macOSTarget,
        lookup: ACPExecutableLookup = ACPExecutableLookup(),
        toolDirectories: [String] = []
    ) -> LaunchDefaults {
        if isAntigravity {
            let installed = lookup.installed("agy", toolDirectories: toolDirectories)
            return LaunchDefaults(executable: installed?.path ?? "agy", arguments: ["acp"])
        }

        let binary = distribution.binary?[target]
        let binaryCommand = binary.map { ($0.cmd as NSString).lastPathComponent }
        let packages = [distribution.npx, distribution.uvx].compactMap { $0 }
        var binaryCommands = [binaryCommand].compactMap { $0 }
        if id == "poolside", binary != nil { binaryCommands.insert("pool", at: 0) }
        let candidates = binaryCommands.filter(Self.isDirectCommand).map {
            LaunchDefaults(executable: $0, arguments: binary?.args ?? [])
        } + packages.flatMap { package in
            (Self.packageExecutables[package.name] ?? []).map {
                LaunchDefaults(executable: $0, arguments: package.args ?? [])
            }
        }

        for candidate in candidates {
            if let installed = lookup.installed(candidate.executable, toolDirectories: toolDirectories, matching: {
                acceptsExecutable($0, for: candidate.executable)
            }) {
                return LaunchDefaults(executable: installed.path, arguments: candidate.arguments)
            }
        }

        // Both Kimi packages publish a `kimi` command. Leave the field blank
        // when its owner cannot be established from the installed executable.
        if id != "kimi", id != "kimi-code", let fallback = candidates.first { return fallback }
        return LaunchDefaults(executable: "", arguments: candidates.first?.arguments ?? packages.first?.args ?? binary?.args ?? [])
    }

    private func acceptsExecutable(_ file: URL, for command: String) -> Bool {
        guard command == "kimi" else { return true }
        switch id {
        case "kimi", "kimi-code":
            let isKimiCode = ACPExecutableLookup.npmPackageName(owning: file) == "@moonshot-ai/kimi-code"
            return id == "kimi-code" ? isKimiCode : !isKimiCode
        default:
            return true
        }
    }

    private static func isDirectCommand(_ command: String) -> Bool {
        !command.isEmpty && ![".", "..", "/"].contains(command) && !ACPExecutableLookup.isPackageLauncher(command)
    }

    // Registry package specs name distributions, not their console scripts.
    // npm entries below come from the published package `bin` manifests.
    private static let packageExecutables: [String: [String]] = [
        "@agentclientprotocol/claude-agent-acp": ["claude-agent-acp"],
        "@agentclientprotocol/codex-acp": ["codex-acp"],
        "@augmentcode/auggie": ["auggie"],
        "@compass-ai/nova": ["nova", "compass"],
        "@github/copilot": ["copilot"],
        "@google/gemini-cli": ["gemini"],
        "@ibm/bob": ["bob"],
        "@kilocode/cli": ["kilo", "kilocode"],
        "@minimax-ai/code-acp": ["code-acp"],
        "@moonshot-ai/kimi-code": ["kimi"],
        "@qoder-ai/qodercli": ["qodercli"],
        "@qwen-code/qwen-code": ["qwen"],
        "@smbcloud/sigit": ["sigit"],
        "@tencent-ai/codebuddy-code": ["codebuddy-code", "codebuddy", "cbc"],
        "@xai-official/grok": ["grok"],
        "agoragentic-mcp": ["agoragentic-mcp"],
        "cline": ["cline"],
        "deepagents-acp": ["deepagents-acp"],
        "dimcode": ["dimcode", "dim"],
        "dirac-cli": ["dirac"],
        "droid": ["droid"],
        "fast-agent-acp": ["fast-agent-acp"],
        "glm-acp-agent": ["glm-acp-agent"],
        "minion-code": ["mcode"],
        "pi-acp": ["pi-acp"],
    ]
}

struct ACPExecutableLookup: Sendable {
    var environment = ProcessInfo.processInfo.environment
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    static func isPackageLauncher(_ input: String) -> Bool {
        ["npx", "npm", "uvx", "uv"].contains((input as NSString).lastPathComponent)
    }

    func installed(
        _ input: String,
        toolDirectories: [String] = [],
        matching accepts: (URL) -> Bool = { _ in true }
    ) -> URL? {
        let executable = expanded(input)
        guard !executable.isEmpty else { return nil }
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            return Self.isExecutable(url) && accepts(url) ? url : nil
        }

        if executable == "agy",
           let detected = ACPConfiguration.detectedAntigravityPath(environment: environment, homeDirectory: homeDirectory) {
            let url = URL(fileURLWithPath: detected)
            if accepts(url) { return url }
        }
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = toolDirectories + [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ] + inherited + [homeDirectory.appendingPathComponent("bin").path]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
            if Self.isExecutable(candidate), accepts(candidate) { return candidate }
        }
        return nil
    }

    func launchURL(for input: String, toolDirectories: [String]) -> URL {
        installed(input, toolDirectories: toolDirectories) ?? URL(fileURLWithPath: expanded(input))
    }

    private func expanded(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~/") { return homeDirectory.path + String(trimmed.dropFirst()) }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fm.isExecutableFile(atPath: url.path)
    }

    static func npmPackageName(owning executable: URL) -> String? {
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        guard directory.pathComponents.contains("node_modules") else { return nil }
        while directory.lastPathComponent != "node_modules" {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
               let package = try? JSONDecoder().decode(NPMPackage.self, from: data) {
                return package.name
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private struct NPMPackage: Decodable {
        let name: String
    }
}
