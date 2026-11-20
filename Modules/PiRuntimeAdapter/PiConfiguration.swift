import Foundation
import SystemConfiguration
import AgentRuntimeCore

public struct PiConfiguration: Sendable {
    public var executable: URL
    public var nodeDirectory: URL
    public var workspace: URL
    public var agentDirectory: URL
    public var sessionDirectory: URL
    public var proxy: String
    /// A missing value means the saved configuration could not be loaded.
    public var environmentOverrides: [String: String]?
    public var launchProxyOverride: String?
    public var extensionFixture: URL?
    public var resumeFile: URL?
    public var expectedSessionID: String?
    public var nativeDialogs: Bool
    public var extensionPaths: [URL]
    public var agentMode: AgentMode
    public var toolApproval: ToolApprovalPolicy?
    var executionPolicy: AgentExecutionPolicy { .init(mode: agentMode, approval: toolApproval) }
    public var toolSearchPaths: [String]
    public var approveProjectConfiguration: Bool
    public init(executable: URL, nodeDirectory: URL, workspace: URL, agentDirectory: URL,
                sessionDirectory: URL, proxy: String = "", environmentOverrides: [String: String]? = [:],
                launchProxyOverride: String? = nil, extensionFixture: URL? = nil, resumeFile: URL? = nil,
                expectedSessionID: String? = nil, nativeDialogs: Bool = false, extensionPaths: [URL] = [],
                agentMode: AgentMode = .automatic, toolApproval: ToolApprovalPolicy? = nil,
                toolSearchPaths: [String] = [], approveProjectConfiguration: Bool = false) {
        self.executable = executable; self.nodeDirectory = nodeDirectory; self.workspace = workspace
        self.agentDirectory = agentDirectory; self.sessionDirectory = sessionDirectory
        self.proxy = proxy; self.extensionFixture = extensionFixture
        self.environmentOverrides = environmentOverrides
        self.launchProxyOverride = launchProxyOverride
        self.resumeFile = resumeFile; self.expectedSessionID = expectedSessionID
        self.nativeDialogs = nativeDialogs; self.extensionPaths = extensionPaths
        self.agentMode = agentMode; self.toolApproval = toolApproval; self.toolSearchPaths = toolSearchPaths
        self.approveProjectConfiguration = approveProjectConfiguration
    }

    private static let proxyAliases: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
    private static let managedKeys: Set<String> = ["PATH", "PI_CODING_AGENT_DIR"]

    public static func environmentKey(_ name: String) -> String? {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == name.startIndex..<name.endIndex,
              !managedKeys.contains(name) else { return nil }
        let upper = name.uppercased()
        return proxyAliases.contains(upper) && name == name.lowercased() ? upper : name
    }

    public static func isValidToolSearchPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(":") && !path.utf8.contains(0)
    }

    public static func proxyEnvironment(_ address: String) -> [String: String] {
        ["HTTP_PROXY": address, "HTTPS_PROXY": address, "NODE_USE_ENV_PROXY": "1"]
    }

    func launchEnvironment(inheriting inherited: [String: String]) throws -> [String: String] {
        guard let environmentOverrides else {
            throw RuntimeFailure(.setup, String(localized: "无法读取 Pi 环境变量。请在设置中重试。", bundle: #bundle))
        }
        var result = inherited
        func assign(_ name: String, _ value: String) {
            if Self.proxyAliases.contains(name) { result.removeValue(forKey: name.lowercased()) }
            result[name] = value
        }
        func setProxy(_ address: String) throws {
            guard !address.isEmpty else { return }
            guard let url = URL(string: address), ["http", "https", "socks5"].contains(url.scheme ?? ""), url.host != nil else {
                throw RuntimeFailure(.setup, String(localized: "代理地址无效。", bundle: #bundle))
            }
            for (name, value) in Self.proxyEnvironment(address) { assign(name, value) }
        }

        if launchProxyOverride == nil { try setProxy(proxy) }
        var seen = Set<String>()
        let launchProxyKeys = Self.proxyEnvironment("").keys
        for (name, value) in environmentOverrides {
            guard let key = Self.environmentKey(name), seen.insert(key).inserted, !value.utf8.contains(0) else {
                throw RuntimeFailure(.setup, String(localized: "Pi 环境变量无效。", bundle: #bundle))
            }
            if launchProxyOverride == nil || !launchProxyKeys.contains(key) { assign(key, value) }
        }
        if let launchProxyOverride { try setProxy(launchProxyOverride) }
        guard toolSearchPaths.allSatisfy(Self.isValidToolSearchPath) else {
            throw RuntimeFailure(.setup, String(localized: "Pi 工具搜索目录无效。", bundle: #bundle))
        }
        let inheritedPaths = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        let basePaths = inheritedPaths.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : inheritedPaths
        var seenPaths = Set<String>()
        result["PATH"] = ([nodeDirectory.path] + toolSearchPaths + basePaths)
            .filter { seenPaths.insert($0).inserted }.joined(separator: ":")
        result["PI_CODING_AGENT_DIR"] = agentDirectory.path
        return result
    }

    public static func detectedPaths() -> (pi: String, node: String, agent: String, proxy: String) {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let piCandidates = [home.appendingPathComponent("bin/pi").path, "/opt/homebrew/bin/pi", "/usr/local/bin/pi"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        let nodeCandidates = [home.appendingPathComponent(".local/share/pi-node/current/bin").path] + versions.map { $0.appendingPathComponent("bin").path } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let env = ProcessInfo.processInfo.environment
        var proxy = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? ""
        if proxy.isEmpty, let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any],
           settings[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1,
           let host = settings[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = settings[kSCPropNetProxiesHTTPSPort as String] as? Int {
            var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port
            proxy = components.string ?? ""
        }
        return (piCandidates.first { fm.isExecutableFile(atPath: $0) } ?? piCandidates[0],
                nodeCandidates.first { fm.isExecutableFile(atPath: $0 + "/node") } ?? "/usr/bin",
                home.appendingPathComponent(".pi/agent").path, proxy)
    }
}
