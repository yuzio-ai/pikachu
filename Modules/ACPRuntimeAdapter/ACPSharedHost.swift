import Foundation
import AgentRuntimeCore
import ProcessSupervision

/// Owns the one reader of a supervised ACP transport. ACPConnection instances are
/// attached endpoints with independent workspaces, turns, brokers, and terminals.
final class ACPSharedHost: @unchecked Sendable {
    let id = UUID()
    let root: ACPConnection
    private let lock = NSRecursiveLock()
    private let openingNew = NSLock()
    private let shutdownLock = NSLock()
    private let admissionLock = NSLock()
    private let onChange: @Sendable (UUID) -> Void
    private var endpoints: [UUID: ACPConnection] = [:]
    private var sessions: [Data: ACPConnection] = [:]
    private var knownSessionIDs: Set<Data> = []
    private var requests: [JSONRPCID: ACPConnection] = [:]
    private var opening: UUID?
    private var earlyUpdates: [(Data, JSONRPCNotification)] = []
    private var earlyBytes = 0
    private var ended = false
    private var retiring = false
    private var unknownCreation: UUID?
    private var pendingCleanup: [UUID: ACPConnection] = [:]
    private var admitsNewWork = true
    private var incompatible = false

    init(configuration: ACPConfiguration, receipts: URL, terminalAuthentication: Bool,
         onChange: @escaping @Sendable (UUID) -> Void) throws {
        self.onChange = onChange
        var config = configuration
        config.handoffCleanup = .init(root: receipts.appendingPathComponent("connections", isDirectory: true), id: id)
        root = try ACPConnection(configuration: config, instanceID: id, sink: RuntimeEventChannel(),
                                 terminalAuthentication: terminalAuthentication, deferDisconnectEvents: true, startPump: false)
    }

    var supportsSharedSessions: Bool { root.initializeResult.agentCapabilities.sessions.contains("close") }
    var isRunning: Bool { lock.withLock { !ended && root.client.isRunning && !root.client.isTransportEnding } }
    var isIncompatible: Bool { lock.withLock { incompatible } }
    var isEmpty: Bool { lock.withLock { endpoints.isEmpty && pendingCleanup.isEmpty } }
    var endpointIDs: Set<UUID> {
        lock.withLock { Set((Array(endpoints.values) + pendingCleanup.values).filter { !$0.isControl }.map(\.instanceID)) }
    }

    func start() {
        Thread.detachNewThread { [self] in pump() }
    }

    func attach(_ endpoint: ACPConnection) throws {
        try lock.withLock {
            guard !retiring, !ended, !incompatible, root.client.isRunning else { throw unavailable() }
            if let receipt = endpoint.configuration.handoffCleanup {
                try receipt.recordSharedConnection(id)
            }
            endpoints[endpoint.instanceID] = endpoint
        }
    }

    func detach(_ endpoint: ACPConnection) {
        lock.withLock {
            // Responses bypass the inbound queue. Deliver earlier frames before changing the session mapping.
            route(root.client.drainInbound().messages)
            endpoints.removeValue(forKey: endpoint.instanceID)
            pendingCleanup.removeValue(forKey: endpoint.instanceID)
            sessions = sessions.filter { $0.value !== endpoint }
            let ownedRequests = requests.filter { $0.value === endpoint }
            for id in ownedRequests.keys {
                requests.removeValue(forKey: id)
                root.client.cancelPendingRequest(id)
            }
        }
        onChange(id)
    }

    func retire() { revokeControls(retiringHost: true) }

    func revokeControls(retiringHost: Bool = false) {
        let controls = lock.withLock { () -> [ACPConnection] in
            if retiringHost {
                retiring = true
                admissionLock.withLock { admitsNewWork = false }
            }
            let controls = endpoints.values.filter(\.isControl)
            for control in controls { endpoints.removeValue(forKey: control.instanceID) }
            let controlRequests = requests.filter { $0.value.isControl }
            for id in controlRequests.keys {
                requests.removeValue(forKey: id)
                root.client.cancelPendingRequest(id, error: unavailable())
            }
            return controls
        }
        for control in controls { _ = control.sharedConnectionEnded(clean: true, failed: false) }
    }

    // The transport attempts only the first nonblocking write under this lock.
    func admitRequest(_ write: () throws -> Void) throws {
        try admissionLock.withLock {
            guard admitsNewWork else { throw retiredFailure() }
            try write()
        }
    }

    func open<T>(_ endpoint: ACPConnection, isNew: Bool, _ body: () throws -> T) throws -> T {
        if isNew { openingNew.lock() }
        defer { if isNew { openingNew.unlock() } }
        try lock.withLock {
            guard !retiring, !ended, unknownCreation == nil, !incompatible, endpoints[endpoint.instanceID] === endpoint else {
                throw unavailable()
            }
            if isNew { opening = endpoint.instanceID }
        }
        defer {
            if isNew {
                lock.withLock {
                    opening = nil
                    earlyUpdates.removeAll(keepingCapacity: true)
                    earlyBytes = 0
                }
            }
        }
        return try body()
    }

    func markUnknownCreation(_ endpoint: ACPConnection) {
        lock.withLock {
            if opening == endpoint.instanceID { unknownCreation = endpoint.instanceID }
        }
    }

    func hasUnknownCreation(for endpoint: ACPConnection) -> Bool {
        lock.withLock { !ended && unknownCreation == endpoint.instanceID }
    }

    func markIncompatible() {
        lock.withLock { incompatible = true }
        onChange(id)
    }

    func bind(_ endpoint: ACPConnection, sessionID: String, newlyCreated: Bool = false) throws {
        try lock.withLock {
            let key = Data(sessionID.utf8)
            guard !ended, endpoints[endpoint.instanceID] === endpoint else { throw unavailable() }
            if (newlyCreated && knownSessionIDs.contains(key)) || (sessions[key].map { $0 !== endpoint } == true) {
                if newlyCreated { markIncompatible() }
                throw RuntimeFailure(.protocolError, String(localized: "ACP Agent 返回的会话标识已在此连接上使用。", bundle: #bundle))
            }
            sessions[key] = endpoint
            knownSessionIDs.insert(key)
            if opening == endpoint.instanceID {
                endpoint.handleInboundMessages(earlyUpdates.filter { $0.0 == key }.map { .notification($0.1) })
                earlyUpdates.removeAll(keepingCapacity: true)
                earlyBytes = 0
                opening = nil
            }
        }
    }

    func sendLinkedRequest(from endpoint: ACPConnection, method: String, params: Record?) throws -> JSONRPCID {
        var registered: JSONRPCID?
        do {
            return try root.client.sendRequest(method: method, params: params, writeGate: admitRequest) { [self] id in
                try lock.withLock {
                    guard !retiring else { throw retiredFailure() }
                    guard !ended, endpoints[endpoint.instanceID] === endpoint else { throw unavailable() }
                    requests[id] = endpoint
                    registered = id
                }
            }
        } catch {
            if let registered { finishLinkedRequest(registered) }
            throw error
        }
    }

    func finishLinkedRequest(_ id: JSONRPCID) {
        lock.withLock { _ = requests.removeValue(forKey: id) }
    }

    func authorizeForce(matching runtimeIDs: Set<UUID>) -> Bool {
        lock.withLock {
            guard endpointIDs == runtimeIDs, !ended || !pendingCleanup.isEmpty else { return false }
            retiring = true
            admissionLock.withLock { admitsNewWork = false }
            return true
        }
    }

    func withInboundDispatch<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    func drainInbound<T>(then finishReplay: () -> T) -> T {
        withInboundDispatch {
            route(root.client.drainInbound().messages)
            return finishReplay()
        }
    }

    func confirmCleanup() throws {
        try ACPStartupCleanupPending(process: root.client).confirm()
    }

    func shutdown(force: Bool) throws {
        try shutdownLock.withLock {
            retire()
            if force, root.client.isRunning { root.client.crash() }
            do {
                try root.client.close(timeout: force ? 2 : 5)
                try confirmCleanup()
            } catch {
                finish(clean: false, failed: false)
                throw ACPStartupCleanupPending(process: root.client).failure
            }
            guard finish(clean: true, failed: false) else {
                throw RuntimeFailure(.supervision, String(localized: "终端进程清理未确认。", bundle: #bundle))
            }
        }
    }

    private func pump() {
        while true {
            root.client.waitForInboundActivity(timeout: 0.25)
            let observation = lock.withLock { () -> (ended: Bool, failed: Bool)? in
                guard !ended else { return nil }
                let batch = root.client.drainInbound()
                route(batch.messages)
                let didEnd = batch.ended || !root.client.isRunning
                let failed = batch.failure != nil
                if !didEnd, !failed {
                    for endpoint in endpoints.values { endpoint.expirePendingInteractions() }
                }
                return (didEnd, failed)
            }
            guard let observation else { return }
            if observation.ended || observation.failed {
                shutdownLock.withLock {
                    if observation.failed, root.client.isRunning { root.client.crash() }
                    try? root.client.close(timeout: 2)
                    let clean = (try? confirmCleanup()) != nil
                    finish(clean: clean, failed: observation.failed)
                }
                return
            }
        }
    }

    @discardableResult
    private func finish(clean: Bool, failed: Bool) -> Bool {
        let attached = lock.withLock { () -> [ACPConnection]? in
            if ended, pendingCleanup.isEmpty { return nil }
            if !ended {
                ended = true
                admissionLock.withLock { admitsNewWork = false }
                pendingCleanup = endpoints
                endpoints.removeAll()
                sessions.removeAll()
                knownSessionIDs.removeAll()
                requests.removeAll()
                earlyUpdates.removeAll()
            }
            return Array(pendingCleanup.values)
        }
        guard let attached else { return true }
        for endpoint in attached where endpoint.sharedConnectionEnded(clean: clean, failed: failed) {
            lock.withLock { _ = pendingCleanup.removeValue(forKey: endpoint.instanceID) }
        }
        onChange(id)
        return lock.withLock { pendingCleanup.isEmpty }
    }

    private func route(_ messages: [JSONRPCInboundMessage]) {
        for message in messages {
            switch message {
            case .notification(let notification):
                if let id = notification.params["sessionId"] as? String {
                    let key = Data(id.utf8)
                    if let endpoint = sessions[key] {
                        endpoint.handleInboundMessages([message])
                    } else if opening != nil, notification.method == ACPProtocol.Method.sessionUpdate,
                              earlyUpdates.count < 64,
                              let bytes = try? JSONSerialization.data(withJSONObject: notification.params).count,
                              earlyBytes + bytes <= 256 * 1024 {
                        earlyBytes += bytes
                        earlyUpdates.append((key, notification))
                    }
                } else if notification.method == ACPProtocol.Method.cancelRequest ||
                            notification.method == ACPProtocol.Method.elicitationComplete {
                    for endpoint in endpoints.values { endpoint.handleInboundMessages([message]) }
                }
            case .request(let request):
                let endpoint: ACPConnection?
                if let id = request.params["sessionId"] as? String {
                    endpoint = sessions[Data(id.utf8)]
                } else if let id = JSONRPCID(jsonValue: request.params["requestId"]) {
                    endpoint = requests[id] ?? endpoints.values.first { $0.ownsPromptRequest(id) }
                } else {
                    endpoint = nil
                }
                if let endpoint {
                    endpoint.handleInboundMessages([message])
                } else {
                    try? root.client.sendErrorResponse(id: request.id, code: ACPProtocol.ErrorCode.resourceNotFound,
                                                       message: "Unknown session or request")
                }
            }
        }
    }

    private func unavailable() -> RuntimeFailure {
        .init(.connection, String(localized: "共享 ACP 连接暂时无法打开新会话。", bundle: #bundle))
    }

    private func retiredFailure() -> RuntimeFailure {
        .init(.setup, String(localized: "ACP 智能体配置已经更改，请重试。", bundle: #bundle))
    }
}
