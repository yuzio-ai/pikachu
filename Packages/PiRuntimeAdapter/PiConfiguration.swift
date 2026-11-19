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
    public var extensionFixture: URL?
    public var resumeFile: URL?
    public var expectedSessionID: String?
    public var nativeDialogs: Bool
    public var extensionPaths: [URL]
    public var agentMode: AgentMode
    public init(executable: URL, nodeDirectory: URL, workspace: URL, agentDirectory: URL,
                sessionDirectory: URL, proxy: String = "", extensionFixture: URL? = nil, resumeFile: URL? = nil, expectedSessionID: String? = nil, nativeDialogs: Bool = false, extensionPaths: [URL] = [], agentMode: AgentMode = .automatic) {
        self.executable = executable; self.nodeDirectory = nodeDirectory; self.workspace = workspace
        self.agentDirectory = agentDirectory; self.sessionDirectory = sessionDirectory
        self.proxy = proxy; self.extensionFixture = extensionFixture
        self.resumeFile = resumeFile; self.expectedSessionID = expectedSessionID
        self.nativeDialogs = nativeDialogs; self.extensionPaths = extensionPaths
        self.agentMode = agentMode
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
