import Foundation
import SystemConfiguration
import AgentRuntimeCore

public final class ACPClientPermissionStore: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var values: [String: RuntimeACPClientPermissions] = [:]

    public init() {}

    public func update(_ agents: [RuntimeAgentProfile]) {
        lock.withLock {
            values = Dictionary(agents.filter(\.enabled).map { ($0.id, $0.clientPermissions) }, uniquingKeysWith: { _, latest in latest })
        }
    }

    func permissions(for id: String) -> RuntimeACPClientPermissions { lock.withLock { values[id] ?? [] } }

    public static func == (lhs: ACPClientPermissionStore, rhs: ACPClientPermissionStore) -> Bool { lhs === rhs }
}

public struct ACPConfiguration: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workspace: URL
    public var runtimeID: String
    public var expectedSessionID: String?
    /// A missing value means the saved environment configuration could not be loaded.
    public var environmentOverrides: [String: String]?
    public var proxy: String
    public var launchProxyOverride: String?
    public var toolSearchPaths: [String]
    public var initialModeID: String?
    public var cancelTimeoutSeconds: TimeInterval
    public var clientPermissions: RuntimeACPClientPermissions = []
    public var permissionStore: ACPClientPermissionStore?
    public var handoffCleanup: ACPHandoffCleanup?

    var effectiveClientPermissions: RuntimeACPClientPermissions {
        clientPermissions.intersection(permissionStore?.permissions(for: runtimeID) ?? clientPermissions)
    }

    public init(executable: URL,
                arguments: [String] = [],
                workspace: URL,
                runtimeID: String = "acp:antigravity",
                expectedSessionID: String? = nil,
                environmentOverrides: [String: String]? = [:],
                proxy: String = "",
                launchProxyOverride: String? = nil,
                toolSearchPaths: [String] = [],
                initialModeID: String? = nil,
                cancelTimeoutSeconds: TimeInterval = 5) {
        self.executable = executable
        self.arguments = arguments
        self.workspace = workspace
        self.runtimeID = runtimeID
        self.expectedSessionID = expectedSessionID
        self.environmentOverrides = environmentOverrides
        self.proxy = proxy
        self.launchProxyOverride = launchProxyOverride
        self.toolSearchPaths = toolSearchPaths
        self.initialModeID = initialModeID
        self.cancelTimeoutSeconds = cancelTimeoutSeconds
    }

    private static let proxyAliases: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
    private static let managedKeys: Set<String> = ["PATH"]

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

    public func launchEnvironment(inheriting inherited: [String: String]) throws -> [String: String] {
        guard let environmentOverrides else {
            throw RuntimeFailure(.setup, String(localized: "无法读取 ACP 环境变量。请在设置中重试。", bundle: #bundle))
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
                throw RuntimeFailure(.setup, String(localized: "ACP 环境变量无效。", bundle: #bundle))
            }
            if launchProxyOverride == nil || !launchProxyKeys.contains(key) { assign(key, value) }
        }
        if let launchProxyOverride { try setProxy(launchProxyOverride) }
        guard toolSearchPaths.allSatisfy(Self.isValidToolSearchPath) else {
            throw RuntimeFailure(.setup, String(localized: "ACP 工具搜索目录无效。", bundle: #bundle))
        }
        let inheritedPaths = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        let basePaths = inheritedPaths.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : inheritedPaths
        let executableDirectory = executable.deletingLastPathComponent().path
        let candidatePaths = (executableDirectory.hasPrefix("/") ? [executableDirectory] : []) + toolSearchPaths + basePaths
        var seenPaths = Set<String>()
        result["PATH"] = candidatePaths
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            .joined(separator: ":")
        return result
    }

    /// Detects an installed Antigravity CLI (`agy`) binary across standard user/Homebrew locations and PATH.
    public static func detectedAntigravityPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fm = FileManager.default
        let standardDirectories = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent("bin").path,
        ]
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        for directory in standardDirectories + pathDirectories {
            guard seen.insert(directory).inserted else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("agy").path
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func detectedProxy(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var proxy = environment["HTTPS_PROXY"] ?? environment["https_proxy"] ?? ""
        if proxy.isEmpty, let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any],
           settings[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1,
           let host = settings[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = settings[kSCPropNetProxiesHTTPSPort as String] as? Int {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = port
            proxy = components.string ?? ""
        }
        return proxy
    }
}

/// The ACP supervisor and each client-side terminal report into this launch's directory.
public struct ACPHandoffCleanup: Sendable, Equatable {
    public let directory: URL

    public init(root: URL, id: UUID) {
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public var isConfirmed: Bool { Self.isConfirmed(in: directory) }

    private static let sharedConnectionFile = "shared-connection.json"
    private static let sharedSessionClosedFile = "shared-session-closed"

    func recordSharedConnection(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try JSONEncoder().encode(id).write(to: directory.appendingPathComponent(Self.sharedConnectionFile), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func recordSharedSessionClose() throws {
        try Data().write(to: directory.appendingPathComponent(Self.sharedSessionClosedFile), options: .atomic)
    }

    private static func isConfirmed(in directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return false }
        let sharedFile = directory.appendingPathComponent(sharedConnectionFile)
        let ignored: Set<String>
        if let data = try? Data(contentsOf: sharedFile), let id = try? JSONDecoder().decode(UUID.self, from: data) {
            let connection = directory.deletingLastPathComponent().appendingPathComponent("connections", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
            let closed = directory.appendingPathComponent(sharedSessionClosedFile)
            guard FileManager.default.fileExists(atPath: closed.path) || hasCleanReport(in: connection) else { return false }
            ignored = [sharedConnectionFile, sharedSessionClosedFile]
        } else {
            guard hasCleanReport(in: directory) else { return false }
            ignored = ["status.json"]
        }
        // Terminal supervisors are siblings of the ACP supervisor. Its clean report
        // does not cover them, including terminals whose launch never acknowledged.
        return entries.filter { !ignored.contains($0.lastPathComponent) }.allSatisfy { entry in
            let name = entry.lastPathComponent
            return (name.hasPrefix("zivvi-terminal-") || name.hasPrefix("pikachu-terminal-")) && hasCleanReport(in: entry)
        }
    }

    private static func hasCleanReport(in directory: URL) -> Bool {
        struct Report: Decodable {
            let supervisionID: String
            let state: String
            let remaining: Int
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
              let report = try? JSONDecoder().decode(Report.self, from: data) else { return false }
        return report.supervisionID == directory.lastPathComponent && report.state == "clean" && report.remaining == 0
    }

    public static func pruneConfirmed(in root: URL, retaining ids: Set<UUID>) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent), !ids.contains(id), isConfirmed(in: entry) else { continue }
            try? manager.removeItem(at: entry)
        }
        guard let remaining = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let sharedIDs = Set(remaining.compactMap { directory -> UUID? in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(sharedConnectionFile)) else { return nil }
            return try? JSONDecoder().decode(UUID.self, from: data)
        })
        let connections = root.appendingPathComponent("connections", isDirectory: true)
        let reports = (try? manager.contentsOfDirectory(at: connections, includingPropertiesForKeys: nil)) ?? []
        for report in reports {
            guard let id = UUID(uuidString: report.lastPathComponent), !sharedIDs.contains(id), hasCleanReport(in: report) else { continue }
            try? manager.removeItem(at: report)
        }
    }
}
