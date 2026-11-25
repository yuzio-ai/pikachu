import Foundation
import AgentRuntimeCore
import ProcessSupervision

final class ACPClientServices: @unchecked Sendable {
    private let client: JSONRPCProcess
    private let configuration: ACPConfiguration
    private let files: ACPProjectFiles
    let advertisedPermissions: RuntimeACPClientPermissions
    private let lock = NSLock()
    private var terminals: [String: ACPClientTerminal] = [:]
    private var writes: [JSONRPCID: (path: String, content: String)] = [:]
    private var waiting: [JSONRPCID: UUID] = [:]
    private var closed = false

    init(client: JSONRPCProcess, configuration: ACPConfiguration) {
        self.client = client
        self.configuration = configuration
        advertisedPermissions = configuration.effectiveClientPermissions
        files = ACPProjectFiles(workspace: configuration.workspace)
    }

    private func allows(_ permission: RuntimeACPClientPermissions) -> Bool {
        advertisedPermissions.contains(permission) && configuration.effectiveClientPermissions.contains(permission)
    }

    func handle(_ request: JSONRPCRequest, sessionID: String?, broker: ACPInteractionBroker) {
        let permission: RuntimeACPClientPermissions
        switch request.method {
        case "fs/read_text_file": permission = .readFiles
        case "fs/write_text_file": permission = .writeFiles
        case "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
            permission = .terminals
        default:
            error(request.id, code: -32601, message: "Unknown client method")
            return
        }
        guard allows(permission) else {
            error(request.id, code: -32601, message: "Client capability not enabled")
            return
        }
        guard let sessionID, request.params["sessionId"] as? String == sessionID else {
            error(request.id, code: -32002, message: "Unknown session")
            return
        }
        guard lock.withLock({ !closed && waiting[request.id] == nil && writes[request.id] == nil }) else { return }
        do {
            switch request.method {
            case "fs/read_text_file":
                let line = try Self.integer(request.params, "line", minimum: 1)
                let limit = try Self.integer(request.params, "limit", minimum: 0)
                let content = try files.read(try Self.string(request.params, "path"), line: line, limit: limit)
                try client.sendResponse(id: request.id, result: ["content": content])
            case "fs/write_text_file":
                try write(request, broker: broker)
            default:
                try terminalRequest(request)
            }
        } catch {
            respondToError(request.id, error: error)
        }
    }

    func respondToApproval(_ id: JSONRPCID, payload: Record) throws {
        let write = lock.withLock { writes.removeValue(forKey: id) }
        guard let write else {
            try client.sendResponse(id: id, result: payload)
            return
        }
        let outcome = payload["outcome"] as? Record
        if outcome?["outcome"] as? String == "cancelled" {
            error(id, code: -32800, message: "Request cancelled")
        } else if outcome?["optionId"] as? String == "write", allows(.writeFiles),
                  lock.withLock({ !closed }) {
            do {
                try files.write(write.path, content: write.content, confirmed: true)
                try client.sendResponse(id: id, result: [:] as Record)
            } catch { respondToError(id, error: error) }
        } else {
            error(id, code: -32001, message: "File write denied")
        }
    }

    func cancel(_ id: JSONRPCID) {
        guard lock.withLock({ waiting.removeValue(forKey: id) != nil }) else { return }
        error(id, code: -32800, message: "Request cancelled")
    }

    func close() -> Bool {
        let active = lock.withLock {
            closed = true
            waiting.removeAll()
            return Array(terminals.values)
        }
        for terminal in active { terminal.terminate() }
        let deadline = Date().addingTimeInterval(5)
        for terminal in active { _ = try? terminal.wait { Date() >= deadline } }
        return active.allSatisfy(\.didConfirmCleanup)
    }

    private func write(_ request: JSONRPCRequest, broker: ACPInteractionBroker) throws {
        let path = try Self.string(request.params, "path")
        guard let content = request.params["content"] as? String, content.utf8.count <= ACPProjectFiles.maximumBytes else {
            throw Failure.invalidParameters
        }
        do {
            try files.write(path, content: content, confirmed: false)
        } catch ACPProjectFiles.Failure.confirmationRequired {
            let previousText = try files.previousTextForWrite(path)
            guard (previousText?.utf8.count ?? 0) + content.utf8.count <= ACPInteractionBroker.maximumMessageBytes else {
                throw Failure.approvalTooLarge
            }
            var diff: Record = ["type": "diff", "path": path, "newText": content]
            diff["oldText"] = previousText
            lock.withLock { writes[request.id] = (path, content) }
            let approval = JSONRPCRequest(id: request.id, method: ACPProtocol.Method.sessionRequestPermission, params: [
                "toolCall": [
                    "title": String(localized: "批准写入项目配置文件", bundle: #bundle),
                    "kind": "edit", "locations": [["path": path]],
                    "content": [diff]
                ] as Record,
                "options": [
                    ["optionId": "write", "kind": "allow_once", "name": String(localized: "允许写入", bundle: #bundle)],
                    ["optionId": "deny", "kind": "reject_once", "name": String(localized: "拒绝", bundle: #bundle)]
                ]
            ], paramsJSON: nil, raw: [:])
            do { try broker.accept(approval, workingDirectory: configuration.workspace.path) }
            catch {
                _ = lock.withLock { writes.removeValue(forKey: request.id) }
                throw error
            }
            return
        }
        try client.sendResponse(id: request.id, result: [:] as Record)
    }

    private func terminalRequest(_ request: JSONRPCRequest) throws {
        if request.method == "terminal/create" {
            try createTerminal(request)
            return
        }
        let id = try Self.string(request.params, "terminalId")
        guard let terminal = lock.withLock({ terminals[id] }) else { throw Failure.unknownTerminal }
        switch request.method {
        case "terminal/output":
            try client.sendResponse(id: request.id, result: terminal.snapshot())
        case "terminal/wait_for_exit":
            respondAfterExit(request.id, terminal: terminal, includeExit: true)
        case "terminal/kill":
            terminal.terminate()
            respondAfterExit(request.id, terminal: terminal, includeExit: false)
        case "terminal/release":
            terminal.terminate()
            // Keep ownership until the child and its descendants have exited.
            respondAfterExit(request.id, terminal: terminal, includeExit: false, releasedID: id)
        default:
            throw Failure.invalidParameters
        }
    }

    private func createTerminal(_ request: JSONRPCRequest) throws {
        let command = try Self.string(request.params, "command")
        let args = request.params["args"] as? [String] ?? []
        guard args.allSatisfy({ !$0.utf8.contains(0) }) else { throw Failure.invalidParameters }
        let cwd = try files.workingDirectory(request.params["cwd"] as? String)
        let limit = try Self.integer(request.params, "outputByteLimit", minimum: 0) ?? ACPClientTerminal.maximumOutputBytes
        var env = try configuration.launchEnvironment(inheriting: ProcessInfo.processInfo.environment)
        for entry in request.params["env"] as? [Record] ?? [] {
            let name = try Self.string(entry, "name")
            guard !name.contains("="), !name.hasPrefix("PIKACHU_"),
                  let value = entry["value"] as? String, !value.utf8.contains(0) else { throw Failure.invalidParameters }
            env[name] = value
        }
        let id = UUID().uuidString
        try lock.withLock {
            guard !closed, terminals.count < 16,
                  allows(.terminals) else { throw Failure.unavailable }
            terminals[id] = try ACPClientTerminal(command: command, args: args, cwd: cwd, environment: env,
                                                  limit: limit, supervisionRoot: configuration.handoffCleanup?.directory)
        }
        try client.sendResponse(id: request.id, result: ["terminalId": id])
    }

    private func respondAfterExit(_ id: JSONRPCID, terminal: ACPClientTerminal, includeExit: Bool, releasedID: String? = nil) {
        let ticket = UUID()
        let started = lock.withLock {
            guard !closed, waiting.count < 32 else { return false }
            waiting[id] = ticket
            return true
        }
        guard started else {
            error(id, code: -32603, message: "Too many terminal requests")
            return
        }
        Thread.detachNewThread { [self] in
            let result = try? terminal.wait {
                lock.withLock { closed || (releasedID == nil && waiting[id] != ticket) }
            }
            let claimed = lock.withLock {
                if let releasedID, terminal.didConfirmCleanup { terminals.removeValue(forKey: releasedID) }
                guard waiting[id] == ticket else { return false }
                waiting.removeValue(forKey: id)
                return true
            }
            if claimed, let result {
                if terminal.didConfirmCleanup {
                    try? client.sendResponse(id: id, result: includeExit ? result : [:])
                } else {
                    error(id, code: -32603, message: "Terminal cleanup unconfirmed")
                }
            }
        }
    }

    private static func string(_ params: Record, _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty, !value.utf8.contains(0) else {
            throw Failure.invalidParameters
        }
        return value
    }

    private static func integer(_ params: Record, _ key: String, minimum: Int) throws -> Int? {
        guard let raw = params[key], !(raw is NSNull) else { return nil }
        guard case .int(let value) = JSONRPCID(jsonValue: raw), value >= minimum else { throw Failure.invalidParameters }
        return value
    }

    private func respondToError(_ id: JSONRPCID, error failure: Error) {
        switch failure {
        case Failure.invalidParameters:
            error(id, code: -32602, message: "Invalid client method parameters")
        case Failure.unknownTerminal:
            error(id, code: -32002, message: "Unknown terminal")
        case ACPProjectFiles.Failure.outsideWorkspace:
            error(id, code: -32001, message: "Path is outside the session workspace or crosses a symbolic link")
        case Failure.approvalTooLarge:
            error(id, code: -32001, message: "File write is too large to display for approval")
        case let detail as ProbeError:
            error(id, code: -32603, message: detail.description)
        default:
            error(id, code: -32603, message: "Client operation failed")
        }
    }

    private func error(_ id: JSONRPCID, code: Int, message: String) {
        try? client.sendErrorResponse(id: id, code: code, message: message)
    }

    private enum Failure: Error {
        case invalidParameters, unknownTerminal, unavailable, approvalTooLarge
    }
}
