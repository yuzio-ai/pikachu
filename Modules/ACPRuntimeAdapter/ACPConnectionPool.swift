import Foundation
import AgentRuntimeCore

public actor ACPConnectionPool {
    private final class Slot {
        let config: ACPConfiguration
        let receipts: URL
        var host: ACPSharedHost?
        var startup: Task<ACPSharedHost, Error>?
        var startupID: UUID?
        var retry: Task<Void, Never>?
        var discarding: Task<Void, Error>?
        var pendingCleanup: ACPStartupCleanupPending?
        var dedicated = false
        var attempts = 0

        init(config: ACPConfiguration, receipts: URL) {
            self.config = config
            self.receipts = receipts
        }
    }

    public nonisolated let statuses: AsyncStream<(String, ACPPoolStatus?)>
    private let updates: AsyncStream<(String, ACPPoolStatus?)>.Continuation
    public nonisolated let retirements: AsyncStream<Set<UUID>>
    private let retirementsContinuation: AsyncStream<Set<UUID>>.Continuation
    private var slots: [String: Slot] = [:]
    private var retired: [UUID: ACPSharedHost] = [:]
    private var retiringSlots: [UUID: Slot] = [:]
    private var sequence = -1
    private var shuttingDown = false

    public init() {
        (statuses, updates) = AsyncStream.makeStream()
        (retirements, retirementsContinuation) = AsyncStream.makeStream()
    }

    public func configure(_ configurations: [ACPConfiguration], receipts: URL, sequence: Int) {
        guard !shuttingDown, sequence > self.sequence else { return }
        self.sequence = sequence
        let desired = Dictionary(uniqueKeysWithValues: configurations.map { ($0.runtimeID, $0) })
        for (id, slot) in slots where desired[id] != slot.config {
            slots.removeValue(forKey: id)
            retire(slot)
            publish(id, nil)
        }
        for (id, config) in desired where slots[id] == nil {
            let slot = Slot(config: config, receipts: receipts)
            slots[id] = slot
            start(slot)
        }
    }

    func connection(for configuration: ACPConfiguration) async throws -> ACPSharedHost? {
        guard !shuttingDown, let slot = slots[configuration.runtimeID] else { throw CancellationError() }
        var requested = configuration
        requested.workspace = slot.config.workspace
        requested.expectedSessionID = nil
        requested.initialModeID = nil
        requested.handoffCleanup = nil
        guard requested == slot.config else {
            throw RuntimeFailure(.connection, String(localized: "ACP 智能体配置已经更改，请重试。", bundle: #bundle))
        }
        if let discarding = slot.discarding {
            try await discarding.value
            guard !shuttingDown, slots[configuration.runtimeID] === slot else { throw CancellationError() }
            return nil
        }
        if slot.dedicated || slot.host?.isIncompatible == true { return nil }
        if let host = slot.host, host.isRunning { return host }
        if let host = slot.host {
            try? await stop(host, force: false)
            try host.confirmCleanup()
            guard slots[configuration.runtimeID] === slot, !shuttingDown else { throw CancellationError() }
            if slot.host === host { hostChanged(host.id) }
        }
        if let retry = slot.retry {
            await retry.value
            try Task.checkCancellation()
            guard slots[configuration.runtimeID] === slot, !shuttingDown else { throw CancellationError() }
            if let host = slot.host, host.isRunning { return host }
        }
        try confirmStartupCleanup(slot)
        start(slot)
        guard let startup = slot.startup, let startupID = slot.startupID else {
            try confirmStartupCleanup(slot)
            throw RuntimeFailure(.connection, String(localized: "ACP Agent 启动失败。", bundle: #bundle))
        }
        return try await finishStartup(startup, id: startupID, for: slot)
    }

    public func retry(_ id: String) {
        guard !shuttingDown, let slot = slots[id], slot.host?.isRunning != true else { return }
        slot.retry?.cancel()
        slot.retry = nil
        slot.attempts = 0
        if let host = slot.host {
            hostChanged(host.id)
        } else {
            start(slot)
        }
    }

    func authenticationRequired(on host: ACPSharedHost?) {
        guard let host else { return }
        updateAuthentication(.needsLogin(host.id), on: host)
    }

    func authenticated(on host: ACPSharedHost?) {
        guard let host else { return }
        updateAuthentication(.ready(host.id), on: host)
    }

    private func updateAuthentication(_ status: ACPPoolStatus, on host: ACPSharedHost?) {
        guard !shuttingDown, let host, host.isRunning else { return }
        let agent = host.root.configuration.runtimeID
        guard slots[agent]?.host === host else { return }
        publish(agent, status)
    }

    func reconnectAfterLogin(_ configuration: ACPConfiguration, replacing host: ACPSharedHost) async throws -> ACPSharedHost? {
        guard let old = slots[configuration.runtimeID], !shuttingDown, old.host === host else { throw CancellationError() }
        let replacement = Slot(config: old.config, receipts: old.receipts)
        slots[configuration.runtimeID] = replacement
        retire(old)
        return try await connection(for: configuration)
    }

    public func refreshAfterExternalAuthentication(_ id: String) {
        guard let old = slots[id], !shuttingDown, !old.dedicated else { return }
        let replacement = Slot(config: old.config, receipts: old.receipts)
        slots[id] = replacement
        retire(old)
        start(replacement)
    }

    public func shutdown(force: Bool = false) async -> Bool {
        shuttingDown = true
        let currentSlots = Array(slots.values) + Array(retiringSlots.values)
        for slot in currentSlots {
            slot.retry?.cancel()
            slot.retry = nil
            if let startup = slot.startup, case .success(let host) = await startup.result {
                if slot.host == nil { slot.host = host }
            }
            if let startup = slot.startup, case .failure(let pending as ACPStartupCleanupPending) = await startup.result {
                slot.pendingCleanup = pending
            }
            slot.startup = nil
            slot.startupID = nil
        }
        var clean = true
        let hosts = Dictionary((currentSlots.compactMap(\.host) + retired.values).map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        for host in hosts.values {
            host.revokeControls()
            if !force, !host.isEmpty, host.isRunning {
                clean = false
                continue
            }
            do { try await stop(host, force: force) }
            catch { clean = false }
        }
        for slot in currentSlots {
            do { try confirmStartupCleanup(slot) }
            catch { clean = false }
        }
        if clean {
            for slot in slots.values { slot.host = nil }
            retired.removeAll()
            retiringSlots.removeAll()
        }
        return clean
    }

    public func resume() {
        shuttingDown = false
        for slot in slots.values where slot.host?.isRunning != true && !slot.dedicated {
            if let host = slot.host { hostChanged(host.id) }
            else { start(slot) }
        }
    }

    private func start(_ slot: Slot) {
        guard !shuttingDown, slot.startup == nil, slot.host == nil, !slot.dedicated else { return }
        do { try confirmStartupCleanup(slot) }
        catch { publish(slot.config.runtimeID, .failed(detail(error))); return }
        let config = slot.config
        let receipts = slot.receipts
        let startupID = UUID()
        let startup = Task.detached { [weak self] in
            try FileManager.default.createDirectory(at: config.workspace, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return try ACPSharedHost(configuration: config, receipts: receipts, terminalAuthentication: true) { [weak self] id in
                Task { await self?.hostChanged(id) }
            }
        }
        slot.startup = startup
        slot.startupID = startupID
        publish(config.runtimeID, slot.attempts == 0 ? .starting : .reconnecting)
        Task { _ = try? await finishStartup(startup, id: startupID, for: slot) }
    }

    private func finishStartup(_ startup: Task<ACPSharedHost, Error>, id: UUID, for slot: Slot) async throws -> ACPSharedHost? {
        let host: ACPSharedHost
        do {
            host = try await startup.value
        } catch {
            if slot.startupID == id {
                slot.startup = nil
                slot.startupID = nil
                if let pending = error as? ACPStartupCleanupPending { slot.pendingCleanup = pending }
                if slots[slot.config.runtimeID] === slot, !shuttingDown {
                    if (error as? RuntimeFailure)?.kind == .authentication {
                        publish(slot.config.runtimeID, .needsLogin(nil))
                    } else {
                        publish(slot.config.runtimeID, .failed(detail(error)))
                        if slot.attempts > 0 { scheduleRetry(slot) }
                    }
                }
            }
            throw error
        }
        guard !shuttingDown, slots[slot.config.runtimeID] === slot else { throw CancellationError() }
        if let discarding = slot.discarding {
            try await discarding.value
            guard !shuttingDown, slots[slot.config.runtimeID] === slot else { throw CancellationError() }
            return nil
        }
        if let existing = slot.host { return slot.dedicated ? nil : existing }
        if slot.dedicated { return nil }
        guard slot.startupID == id else { throw CancellationError() }
        slot.startup = nil
        slot.startupID = nil
        slot.host = host
        if !host.supportsSharedSessions {
            slot.dedicated = true
            let discard = Task.detached { try host.shutdown(force: false) }
            slot.discarding = discard
            defer { slot.discarding = nil }
            do {
                try await discard.value
                if slot.host === host { slot.host = nil }
            } catch {
                slot.dedicated = false
                publish(slot.config.runtimeID, .failed(detail(error)))
                throw error
            }
            guard !shuttingDown, slots[slot.config.runtimeID] === slot else { throw CancellationError() }
            publish(slot.config.runtimeID, .dedicated(.missingSessionClose))
            return nil
        }
        slot.attempts = 0
        host.start()
        publish(slot.config.runtimeID, .ready(host.id))
        return host
    }

    private func hostChanged(_ id: UUID) {
        if shuttingDown { return }
        if let host = retired[id], host.isEmpty {
            Task { try? await disposeRetired(host) }
            return
        }
        guard let slot = slots.values.first(where: { $0.host?.id == id }), let host = slot.host else { return }
        if host.isIncompatible {
            slot.dedicated = true
            publish(slot.config.runtimeID, .dedicated(.incompatible))
            if host.isEmpty {
                slot.host = nil
                retired[id] = host
                Task { try? await disposeRetired(host) }
            }
            return
        }
        guard !slot.dedicated else { return }
        guard !host.isRunning else { return }
        do {
            try host.confirmCleanup()
            if !host.isEmpty { retired[id] = host }
            slot.host = nil
            scheduleRetry(slot)
        } catch {
            publish(slot.config.runtimeID, .failed(detail(error)))
        }
    }

    private func scheduleRetry(_ slot: Slot) {
        guard slot.retry == nil, !shuttingDown, slot.attempts < 5 else { return }
        let delay = 1 << slot.attempts
        slot.attempts += 1
        publish(slot.config.runtimeID, .reconnecting)
        slot.retry = Task {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            slot.retry = nil
            guard slots[slot.config.runtimeID] === slot else { return }
            start(slot)
        }
    }

    private func retire(_ slot: Slot) {
        slot.retry?.cancel()
        if let host = slot.host {
            host.retire()
            retirementsContinuation.yield(host.endpointIDs)
            retired[host.id] = host
            if host.isEmpty { Task { try? await disposeRetired(host) } }
        }
        if let startup = slot.startup {
            let retirement = UUID()
            retiringSlots[retirement] = slot
            Task {
                if case .success(let host) = await startup.result {
                    retired[host.id] = host
                    try? await disposeRetired(host)
                } else if case .failure(let pending as ACPStartupCleanupPending) = await startup.result {
                    slot.pendingCleanup = pending
                    if (try? confirmStartupCleanup(slot)) == nil { return }
                }
                retiringSlots.removeValue(forKey: retirement)
            }
        } else if slot.pendingCleanup != nil {
            retiringSlots[UUID()] = slot
        }
    }

    private func disposeRetired(_ host: ACPSharedHost) async throws {
        try await stop(host, force: false)
        retired.removeValue(forKey: host.id)
    }

    private func stop(_ host: ACPSharedHost, force: Bool) async throws {
        try await Task.detached { try host.shutdown(force: force) }.value
    }

    private func confirmStartupCleanup(_ slot: Slot) throws {
        if let pending = slot.pendingCleanup {
            try pending.confirm()
            slot.pendingCleanup = nil
        }
    }

    private func publish(_ id: String, _ state: ACPPoolStatus?) { updates.yield((id, state)) }

    private func detail(_ error: Error) -> String {
        if let pending = error as? ACPStartupCleanupPending { return pending.failure.detail }
        return (error as? RuntimeFailure)?.detail ?? String(localized: "ACP Agent 启动失败。", bundle: #bundle)
    }
}
