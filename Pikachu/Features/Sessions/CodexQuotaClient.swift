import Foundation
import ProcessSupervision

/// Reads only the local Codex account's subscription windows. Codex owns its OAuth credentials.
enum CodexQuotaClient {
    enum Failure: Error { case notInstalled, notSignedIn, invalidResponse }

    private struct Snapshot: Decodable {
        struct Window: Decodable {
            let usedPercent: Int
            let windowDurationMins: Int?
            let resetsAt: Int64?
        }
        let limitId: String?
        let primary: Window?
        let secondary: Window?
    }

    private struct Limits: Decodable {
        let rateLimits: Snapshot?
        let rateLimitsByLimitId: [String: Snapshot]?
    }

    static func windows(from data: Data, observedAt: Date) throws -> [AccountQuotaWindow] {
        let limits = try JSONDecoder().decode(Limits.self, from: data)
        let snapshot = limits.rateLimitsByLimitId?["codex"] ??
            limits.rateLimits.flatMap { $0.limitId == nil || $0.limitId == "codex" ? $0 : nil }
        return [("primary", snapshot?.primary), ("secondary", snapshot?.secondary)].compactMap { id, window in
            guard let window, (0...100).contains(window.usedPercent) else { return nil }
            let period = window.windowDurationMins.flatMap { minutes -> String? in
                guard (1...525_600).contains(minutes) else { return nil }
                return Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
            } ?? String(localized: "周期未知")
            return .init(id: id, provider: "Codex", account: String(localized: "本机 Codex 账号"), period: period,
                         remaining: 100 - window.usedPercent, limit: 100,
                         resetAt: window.resetsAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil },
                         observedAt: observedAt, expiresAt: observedAt.addingTimeInterval(300))
        }
    }

    static func fetch(searchPaths: [String] = []) async throws -> [AccountQuotaWindow] {
        try await Task.detached(priority: .utility) { try query(searchPaths: searchPaths) }.value
    }

    private static func query(searchPaths: [String]) throws -> [AccountQuotaWindow] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin", "/usr/local/bin",
                     home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".npm-global/bin").path,
                     home.appendingPathComponent(".bun/bin").path]
            + searchPaths
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let executable = paths.filter({ $0.hasPrefix("/") }).map({ $0 + "/codex" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw Failure.notInstalled }
        let process = try RPCProcess(executable: executable, arguments: ["app-server", "--listen", "stdio://"],
                                     cwd: home, environment: environment, streaming: true)
        defer { try? process.close(timeout: 0.5) }

        func request(_ id: Int, _ method: String, params: Record? = nil) throws -> Record {
            var record: Record = ["id": id, "method": method]
            if let params { record["params"] = params }
            try process.send(record)
            let response = try process.wait(timeout: 8) { $0["id"] as? Int == id }
            guard let result = response["result"] as? Record else { throw Failure.invalidResponse }
            return result
        }

        _ = try request(1, "initialize", params: ["clientInfo": ["name": "pikachu", "version": "0.1.0"]])
        try process.send(["method": "initialized"])
        let account = try request(2, "account/read", params: ["refreshToken": false])
        guard (account["account"] as? Record)?["type"] as? String == "chatgpt" else { throw Failure.notSignedIn }
        let result = try request(3, "account/rateLimits/read")
        return try windows(from: JSONSerialization.data(withJSONObject: result), observedAt: .now)
    }
}
