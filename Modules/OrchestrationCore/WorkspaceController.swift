import Foundation
import Observation
import AgentRuntimeCore

public struct ProjectOperationFeedback: Sendable {
    public let message: String
    public let warning: Bool
}

public struct ProjectDeletionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let sessionCount: Int
    public let draftCount: Int
}

@MainActor @Observable public final class SessionPresentation: Identifiable {
    public let id: UUID
    public let controller: SessionController
    public var loading = false
    public var loadError: String?
    public var executionIssue: String?
    public var executionError: String?
    public private(set) var frozenTranscript: [TranscriptItem] = []
    public private(set) var frozenRows: [TranscriptDisplayRow] = []
    public internal(set) var activeHandoffMarker: TranscriptItem?
    public private(set) var isSubmittingHandoff = false
    @ObservationIgnored var frozenSegmentIDs: [UUID] = []
    @ObservationIgnored var handoffPreviewToken: UUID?
    @ObservationIgnored var readGeneration = UUID()
    init(id: UUID, clock: any RuntimeClock = SystemRuntimeClock()) {
        self.id = id
        self.controller = SessionController(clock: clock)
    }

    func setFrozenTranscript(_ items: [TranscriptItem], rows: [TranscriptDisplayRow], segmentIDs: [UUID]) {
        frozenTranscript = items
        frozenRows = rows
        frozenSegmentIDs = segmentIDs
    }

    func setSubmittingHandoff(_ value: Bool) {
        isSubmittingHandoff = value
    }
}

public struct WorkspaceRuntimeLaunch: Sendable, Equatable {
    public let workingDirectory: String
    public let canonicalDirectory: String
    public let handoffCleanupID: UUID?

    public init(workingDirectory: String, canonicalDirectory: String,
                handoffCleanupID: UUID? = nil) {
        self.workingDirectory = workingDirectory
        self.canonicalDirectory = canonicalDirectory
        self.handoffCleanupID = handoffCleanupID
    }
}

@MainActor @Observable public final class WorkspaceController {
    public private(set) var state = WorkspaceSnapshot()
    public private(set) var initialized = false
    public private(set) var isShuttingDown = false
    private var sessionOperations: Set<UUID> = []
    public private(set) var refreshingHistoryIndex = false
    public private(set) var historyIndexWarning: String?
    private var savingProject = false
    private var savingProjectNames: Set<UUID> = []
    private var deletingProjectID: UUID?
    private var deletingSessionIDs: Set<UUID> = []
    private var activeExecutionIDs: Set<UUID> = []
    private var executionLaunches: [UUID: WorkspaceRuntimeLaunch] = [:]
    public private(set) var viewed: SessionPresentation?
    public private(set) var presentations: [UUID: SessionPresentation] = [:]
    public var error: String?
    public var storageError: String?
    public var notice: String?
    public var inputFocusRequest = 0
    public var usageExpanded = false
    public var configurationRequest = 0
    public var newSessionRequest = 0
    public var openProjectRequest = 0
    public private(set) var completedTurnsByDirectory: [String: Int] = [:]
    @ObservationIgnored public var onLiveTurnFinished: (@MainActor (UUID, TurnRecord) -> Void)?
    @ObservationIgnored public var onLiveApprovalRequested: (@MainActor (UUID, RuntimeInteraction, SessionController) -> Void)?
    @ObservationIgnored public var generateSessionTitle: (@MainActor (SessionTitleSettings, String) async -> String?)?
    @ObservationIgnored private var titleGenerationTasks: [UUID: Task<Void, Never>] = [:]
    public func focusInput() { inputFocusRequest += 1 }
    @ObservationIgnored private let store: any WorkspaceStore
    @ObservationIgnored private let clock: any RuntimeClock
    @ObservationIgnored private let runtimeFactory: @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime
    @ObservationIgnored private let inspectRuntimeModels: @MainActor (String, RuntimeModel?) async throws -> RuntimeConfigurationOptions
    @ObservationIgnored private let verifyHandoffCleanup: @MainActor (UUID) -> Bool
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private let idleRuntimeTimeout: Duration
    @ObservationIgnored private var idleReapers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dirtyDrafts: Set<UUID> = []
    @ObservationIgnored private var defaultModelSaves: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var savingSnapshot = false
    @ObservationIgnored private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let validateWorktree: @MainActor (String, String) async -> Bool
    private var draftIndicators: [UUID: Bool] = [:]
    public var executionIDs: [UUID] { state.sessions.compactMap { activeExecutionIDs.contains($0.id) ? $0.id : nil } }
    public var hasPendingExecutionControls: Bool {
        !sessionOperations.isEmpty || executionIDs.contains { execution(for: $0)?.commandPending == true }
    }
    public func isOperating(on id: UUID) -> Bool {
        isShuttingDown || sessionOperations.contains(id) || deletingSessionIDs.contains(id)
    }
    public func execution(for id: UUID) -> SessionController? {
        activeExecutionIDs.contains(id) ? presentations[id]?.controller : nil
    }
    public func workingDirectory(for id: UUID) -> String? {
        guard let reference = state.sessions.first(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == reference.projectID }) else { return nil }
        return reference.workingDirectory(in: project)
    }
    public var acpAgents: [RuntimeAgentProfile] { state.preferences.acpAgents ?? [] }
    public var defaultRuntimeID: String? { state.preferences.resolvedDefaultRuntimeID }
    public var availableRuntimes: [RuntimeAgentProfile] { acpAgents.filter(\.enabled) }
    public var availableRuntimeIDs: [String] { availableRuntimes.map(\.id) }
    public func agentProfile(for runtimeID: String) -> RuntimeAgentProfile? {
        return acpAgents.first { $0.id == runtimeID }
    }
    public func isRuntimeAvailable(_ runtimeID: String) -> Bool {
        acpAgents.contains(where: { $0.id == runtimeID && $0.enabled })
    }
    public func runtimeDisplayName(for runtimeID: String) -> String {
        if let profile = acpAgents.first(where: { $0.id == runtimeID }) { return profile.name }
        if runtimeID == RuntimeAgentProfile.antigravityRuntimeID { return "Antigravity" }
        return runtimeID
    }
    public var selected: SessionReference? { state.sessions.first { $0.id == state.selectedSessionID } }
    public var selectedProject: ProjectRecord? { selected.flatMap { item in state.projects.first { $0.id == item.projectID } } }
    public var canManageProjects: Bool { initialized && !isShuttingDown && !savingProject && !refreshingHistoryIndex && storageError == nil }
    public func hasDraft(_ session: SessionReference) -> Bool {
        (draftIndicators[session.id] ?? (!session.draft.isEmpty || session.draftFiles?.isEmpty == false)) || !session.recovered.isEmpty
    }
    public convenience init(store: any WorkspaceStore,
                            clock: any RuntimeClock = SystemRuntimeClock(), idleRuntimeTimeout: Duration = .seconds(35 * 60),
                            validateWorktree: @escaping @MainActor (String, String) async -> Bool = { _, _ in true },
                            inspectModels: @escaping @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions = { _ in
                                throw RuntimeFailure(.setup, String(localized: "未配置模型目录。", bundle: #bundle))
                            }, factory: @escaping @MainActor (ProjectRecord, SessionReference) -> any AgentRuntime) {
        self.init(store: store, clock: clock, idleRuntimeTimeout: idleRuntimeTimeout,
                  validateWorktree: validateWorktree, inspectModels: inspectModels) { project, reference, _ in
            factory(project, reference)
        }
    }
    public convenience init(store: any WorkspaceStore,
                            clock: any RuntimeClock = SystemRuntimeClock(), idleRuntimeTimeout: Duration = .seconds(35 * 60),
                            validateWorktree: @escaping @MainActor (String, String) async -> Bool = { _, _ in true },
                            inspectModels: @escaping @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions = { _ in
                                throw RuntimeFailure(.setup, String(localized: "未配置模型目录。", bundle: #bundle))
                            }, runtimeFactory: @escaping @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime) {
        self.init(store: store, clock: clock, idleRuntimeTimeout: idleRuntimeTimeout,
                  validateWorktree: validateWorktree, inspectRuntimeModels: { _, model in try await inspectModels(model) }, runtimeFactory: runtimeFactory)
    }
    public init(store: any WorkspaceStore,
                clock: any RuntimeClock = SystemRuntimeClock(), idleRuntimeTimeout: Duration = .seconds(35 * 60),
                validateWorktree: @escaping @MainActor (String, String) async -> Bool = { _, _ in true },
                verifyHandoffCleanup: @escaping @MainActor (UUID) -> Bool = { _ in false },
                inspectRuntimeModels: @escaping @MainActor (String, RuntimeModel?) async throws -> RuntimeConfigurationOptions,
                runtimeFactory: @escaping @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime) {
        self.store = store; self.clock = clock; self.runtimeFactory = runtimeFactory
        self.inspectRuntimeModels = inspectRuntimeModels; self.validateWorktree = validateWorktree
        self.verifyHandoffCleanup = verifyHandoffCleanup
        self.idleRuntimeTimeout = idleRuntimeTimeout
    }
    public func start() async {
        guard !initialized else { return }
        do {
            let original = try await store.load()
            state = original
            state.sessions.removeAll { $0.runtimeID == "pi" }
            state.runtimeEnvironments?.removeValue(forKey: "pi")
            state.modelPreferencesByRuntime?.removeValue(forKey: "pi")
            if state.preferences.defaultRuntimeID != state.preferences.resolvedDefaultRuntimeID {
                state.preferences.defaultRuntimeID = nil
            }
            guard state.version == 1, Set(state.projects.map(\.id)).count == state.projects.count,
                  Set(state.sessions.map(\.id)).count == state.sessions.count,
                  state.sessions.allSatisfy({ s in state.projects.contains { $0.id == s.projectID } }) else { throw RuntimeFailure(.setup, String(localized: "本地索引不一致。", bundle: #bundle)) }
            let runtimeKeys = state.sessions.flatMap { session in
                let segments = session.frozenSegments ?? []
                let frozen = segments.compactMap { segment in
                    segment.runtimeSessionID.map { session.projectID.uuidString + ":" + segment.runtimeID + ":" + $0 }
                }
                let active = session.runtimeSessionID.map { [session.projectID.uuidString + ":" + session.runtimeID + ":" + $0] } ?? []
                return frozen + active
            }
            guard Set(runtimeKeys).count == runtimeKeys.count else { throw RuntimeFailure(.setup, String(localized: "本地会话绑定重复。", bundle: #bundle)) }
            let frozenIDs = state.sessions.flatMap { ($0.frozenSegments ?? []).map(\.id) }
            guard Set(frozenIDs).count == frozenIDs.count else {
                throw RuntimeFailure(.setup, String(localized: "本地索引不一致。", bundle: #bundle))
            }
            for i in state.sessions.indices {
                initializeSidebarMetadata(at: i)
                state.sessions[i].file = nil
                reconcileHandoffCleanup(at: i)
                if state.sessions[i].automaticTitleSubmissionID != nil
                    || state.sessions[i].submissions.contains(where: { $0.delivery != .rejected })
                    || state.sessions[i].recordedMessages?.isEmpty == false
                    || state.sessions[i].archivedAt != nil {
                    state.sessions[i].awaitsAutomaticTitle = nil
                }
                if state.sessions[i].wasExecuting { notice = String(localized: "上次运行已中断。仅恢复历史和草稿，没有恢复推理或执行队列。", bundle: #bundle) }
                state.sessions[i].wasExecuting = false
                for j in state.sessions[i].submissions.indices {
                    if [.pending, .queued, .accepted].contains(state.sessions[i].submissions[j].delivery) {
                        state.sessions[i].submissions[j].delivery = .unknown
                        state.sessions[i].submissions[j].needsReview = true
                    }
                }
            }
            if !state.sessions.contains(where: { $0.id == state.selectedSessionID }) { state.selectedSessionID = nil }
            state.revision += 1
            do { try await store.save(state) }
            catch { state = original; throw error }
            try? await store.pruneSessionHistory(retaining: Set(frozenIDs))
            storageError = nil
            initialized = true
            if let id = state.selectedSessionID { await select(id) }
        } catch { storageError = String(localized: "本地工作台数据无法读取，已阻止执行；没有重建或覆盖原数据。", bundle: #bundle) }
    }
    @discardableResult public func addProject(_ path: URL, createInitialSession: Bool = true) async -> UUID? {
        if createInitialSession, !(await waitForSessionDefaults(for: { defaultRuntimeID })) { return nil }
        guard canManageProjects else { return nil }
        let location = path.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location, isDirectory: &directory), directory.boolValue else { error = String(localized: "项目目录不存在。", bundle: #bundle); return nil }
        if let existing = state.projects.first(where: { $0.path == location }) {
            if createInitialSession {
                if let session = state.sessions.first(where: { $0.projectID == existing.id && $0.archivedAt == nil }) {
                    await select(session.id)
                } else {
                    _ = await createSession(in: existing.id)
                }
            }
            return existing.id
        }
        let project = ProjectRecord(path: location); state.projects.append(project)
        savingProject = true
        defer { savingProject = false }
        if createInitialSession, let runtimeID = defaultRuntimeID {
            await select(appendNewSession(to: project.id, runtimeID: runtimeID))
        }
        _ = await flush()
        return project.id
    }
    @discardableResult public func relocateProject(_ projectID: UUID, to path: URL) async -> ProjectOperationFeedback? {
        guard canManageProjects, let i = state.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        error = nil
        if state.sessions.contains(where: { $0.projectID == projectID && (activeExecutionIDs.contains($0.id) || sessionOperations.contains($0.id)) }) {
            let message = String(localized: "请先清理并断开该项目的执行会话，再重新定位。", bundle: #bundle)
            error = message
            return .init(message: message, warning: true)
        }
        let location = path.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location, isDirectory: &directory), directory.boolValue,
              !state.projects.contains(where: { $0.id != projectID && $0.path == location }) else {
            let message = String(localized: "目录不可用或已属于其他项目。", bundle: #bundle)
            error = message
            return .init(message: message, warning: true)
        }
        let previous = state.projects[i].path
        if !state.projects[i].previousPaths.contains(previous) { state.projects[i].previousPaths.append(previous) }
        state.projects[i].path = location; state.projects[i].name = path.lastPathComponent
        savingProject = true
        defer { savingProject = false }
        guard await flush() else {
            return storageError.map { .init(message: $0, warning: true) }
        }
        return .init(message: String(localized: "工作目录已更新。", bundle: #bundle), warning: false)
    }

    @discardableResult public func setProjectDisplayName(_ input: String, for id: UUID) async -> Bool {
        guard initialized, !isShuttingDown, deletingProjectID != id,
              !input.contains(where: \.isNewline), state.projects.contains(where: { $0.id == id }),
              savingProjectNames.insert(id).inserted else { return false }
        defer { savingProjectNames.remove(id) }
        let name = input.trimmingCharacters(in: .whitespaces)
        return await saveSnapshot { snapshot in
            guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
            snapshot.projects[index].customDisplayName = name.isEmpty ? nil : name
        }
    }

    public func projectDeletionSummary(for id: UUID) -> ProjectDeletionSummary? {
        guard let project = state.projects.first(where: { $0.id == id }) else { return nil }
        let sessions = state.sessions.filter { $0.projectID == id }
        return .init(id: id, name: project.displayName, path: project.path,
                     sessionCount: sessions.count, draftCount: sessions.count(where: { hasDraft($0) }))
    }

    public func projectDeletionBlockReason(for id: UUID) -> String? {
        if state.sessions.contains(where: { session in
            session.projectID == id && (sessionOperations.contains(session.id) || activeExecutionIDs.contains(session.id) ||
                executionLaunches[session.id] != nil || presentations[session.id].map { $0.controller.connection != .disconnected } == true)
        }) {
            return String(localized: "请先结束该项目的任务并断开会话，再删除项目。", bundle: #bundle)
        }
        if !initialized || isShuttingDown || savingProject || refreshingHistoryIndex ||
            savingProjectNames.contains(id) {
            return String(localized: "项目设置或会话列表正在更新，请稍后再试。", bundle: #bundle)
        }
        return nil
    }

    @discardableResult public func deleteProject(_ confirmed: ProjectDeletionSummary) async -> ProjectOperationFeedback? {
        let id = confirmed.id
        guard projectDeletionSummary(for: id) == confirmed else {
            return .init(message: String(localized: "项目或会话列表已有变化，请重新确认删除。", bundle: #bundle), warning: true)
        }
        if let reason = projectDeletionBlockReason(for: id) { return .init(message: reason, warning: true) }
        let sessionIDs = Set(state.sessions.lazy.filter { $0.projectID == id }.map(\.id))
        let segmentIDs = Set(state.sessions.lazy.filter { sessionIDs.contains($0.id) }.flatMap { ($0.frozenSegments ?? []).map(\.id) })
        savingProject = true
        deletingProjectID = id
        deletingSessionIDs.formUnion(sessionIDs)
        defer {
            deletingSessionIDs.subtract(sessionIDs)
            deletingProjectID = nil
            savingProject = false
        }
        guard await saveSnapshot(applying: { snapshot in
            snapshot.projects.removeAll { $0.id == id }
            snapshot.sessions.removeAll { $0.projectID == id }
            if let selected = snapshot.selectedSessionID, sessionIDs.contains(selected) { snapshot.selectedSessionID = nil }
        }) else {
            return .init(message: storageError ?? String(localized: "无法删除项目。请重试。", bundle: #bundle), warning: true)
        }
        if let viewed, sessionIDs.contains(viewed.id) { clearViewedSession(viewed.id) }
        for sessionID in sessionIDs { removeSessionPresentation(sessionID) }
        try? await store.removeSessionHistory(segmentIDs: segmentIDs)
        return nil
    }
    @discardableResult public func createSession(in projectID: UUID) async -> UUID? {
        guard let runtimeID = defaultRuntimeID else { return nil }
        return await createSession(in: projectID, runtimeID: runtimeID)
    }

    @discardableResult public func createSession(in projectID: UUID, runtimeID: String) async -> UUID? {
        guard await waitForSessionDefaults(for: { runtimeID }), canManageProjects,
              acpAgents.contains(where: { $0.id == runtimeID && $0.enabled }),
              state.projects.contains(where: { $0.id == projectID }) else { return nil }
        let id = appendNewSession(to: projectID, runtimeID: runtimeID)
        await select(id); _ = await flush()
        return id
    }
    @discardableResult
    public func importRemoteSession(_ remote: RuntimeRemoteSession, projectID: UUID, agentID: String,
                                    canRestore: Bool, canDelete: Bool) async -> UUID? {
        guard canManageProjects, RuntimeAgentProfile.isACPRuntimeID(agentID),
              let project = state.projects.first(where: { $0.id == projectID }) else { return nil }
        if let existing = state.sessions.first(where: { $0.containsRuntimeSession(agent: agentID, id: remote.id) }) {
            await select(existing.id)
            return existing.id
        }
        let root = Self.canonicalPath(project.path)
        let directory = Self.canonicalPath(remote.directory)
        if root != directory {
            guard await validateWorktree(project.path, directory) else { return nil }
        }
        var reference = SessionReference(projectID: projectID, runtimeID: agentID,
                                         title: remote.title ?? "历史会话")
        reference.runtimeSessionID = remote.id
        reference.resumableSession = canRestore
        reference.canDeleteRemoteHistory = canDelete
        reference.boundWorkingDirectory = directory
        if directory != root { reference.worktreePath = directory }
        let imported = reference
        guard await saveSnapshot(applying: { snapshot in
            guard snapshot.projects.contains(where: { $0.id == projectID && Self.canonicalPath($0.path) == root }),
                  !snapshot.sessions.contains(where: { $0.containsRuntimeSession(agent: agentID, id: remote.id) })
            else { return }
            snapshot.sessions.append(imported)
        }), state.sessions.contains(where: { $0.id == imported.id }) else { return nil }
        await select(imported.id)
        return imported.id
    }

    public func deleteRemoteHistory(_ id: UUID,
                                    delete: (String, String, String) async throws -> Void) async throws {
        guard let reference = state.sessions.first(where: { $0.id == id }),
              reference.isACPRuntime, reference.remoteHistoryDeleted != true,
              reference.canDeleteRemoteHistory == true, let remoteID = reference.runtimeSessionID,
              let directory = workingDirectory(for: id), !isOperating(on: id),
              sessionArchiveBlockReason(for: reference) == nil else {
            throw RuntimeFailure(.setup, String(localized: "会话当前无法删除远端历史。", bundle: #bundle))
        }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        guard await closeExecution(id) else {
            throw RuntimeFailure(.connection, String(localized: "无法断开 ACP 会话。", bundle: #bundle))
        }
        try await delete(reference.runtimeID, directory, remoteID)
        if let index = state.sessions.firstIndex(where: { $0.id == id }) {
            state.sessions[index].remoteHistoryDeleted = true
            state.sessions[index].awaitsAutomaticTitle = nil
            titleGenerationTasks[id]?.cancel()
            presentations[id]?.executionIssue = Self.acpResumeIssue(for: state.sessions[index])
        }
        guard await flush() else {
            throw RuntimeFailure(.setup, String(localized: "远端历史已删除，但本地状态未能保存。请重试。", bundle: #bundle))
        }
    }

    private func appendNewSession(to projectID: UUID, runtimeID: String) -> UUID {
        let reference = makeNewSession(in: projectID, runtimeID: runtimeID)
        state.sessions.append(reference)
        return reference.id
    }

    public var sessionTitleSettings: SessionTitleSettings { state.sessionTitleSettings ?? .init() }

    @discardableResult public func setSessionTitleSettings(_ draft: SessionTitleSettings) async -> Bool {
        var settings = draft
        if settings.mode == .disabled { settings.rules = sessionTitleSettings.rules }
        guard initialized, !isShuttingDown,
              settings.rules.utf8.count <= SessionTitleSettings.maximumRuleBytes,
              settings.mode != .specified || settings.model != nil else { return false }
        guard settings != sessionTitleSettings else { return true }
        guard await saveSnapshot(applying: { $0.sessionTitleSettings = settings == .init() ? nil : settings }) else { return false }
        for task in titleGenerationTasks.values { task.cancel() }
        return true
    }

    private func waitForSessionDefaults(for targetRuntime: () -> String?) async -> Bool {
        while let runtimeID = targetRuntime(), let save = defaultModelSaves[runtimeID] {
            guard await save.value else { return false }
        }
        return true
    }

    private func makeNewSession(in projectID: UUID, runtimeID: String) -> SessionReference {
        var reference = SessionReference(projectID: projectID, runtimeID: runtimeID)
        reference.awaitsAutomaticTitle = true
        let initialModel = state.modelPreferences(forRuntime: runtimeID).defaultModel
        if let model = initialModel {
            reference.pendingSelection = .init(provider: model.provider, modelID: model.modelID)
            reference.pendingModelName = model.name
        }
        reference.modelSource = .global
        reference.processingStatus = .open
        reference.sidebarActivity = .init(date: reference.lastViewed)
        return reference
    }
    public func settleBlockReason(for session: SessionReference) -> LocalizedStringResource? {
        if !initialized || storageError != nil { return LocalizedStringResource("请先恢复工作台存储。", bundle: .atURL(#bundle.bundleURL)) }
        if let active = execution(for: session.id) {
            if !active.interactions.isEmpty { return LocalizedStringResource("请先处理等待中的输入。", bundle: .atURL(#bundle.bundleURL)) }
            if active.connection == .closing || active.connection == .blocked { return LocalizedStringResource("请先确认运行时进程已清理。", bundle: .atURL(#bundle.bundleURL)) }
            if active.phase == .uncertain { return LocalizedStringResource("请先核实执行结果。", bundle: .atURL(#bundle.bundleURL)) }
            if active.phase.isActive || active.connection == .connecting || active.commandPending || !active.queue.isEmpty {
                return LocalizedStringResource("请等待执行和队列结束。", bundle: .atURL(#bundle.bundleURL))
            }
        }
        if session.submissions.contains(where: \.needsReview) { return LocalizedStringResource("请先核对未确认的发送记录。", bundle: .atURL(#bundle.bundleURL)) }
        if isOperating(on: session.id) || session.submissions.contains(where: { [.pending, .queued, .accepted].contains($0.delivery) }) {
            return LocalizedStringResource("请等待当前操作结束。", bundle: .atURL(#bundle.bundleURL))
        }
        if hasDraft(session) { return LocalizedStringResource("请先处理会话草稿。", bundle: .atURL(#bundle.bundleURL)) }
        return nil
    }
    public func markSessionSettled(_ id: UUID) async {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[i].sidebarStatus == .open, settleBlockReason(for: state.sessions[i]) == nil else { return }
        state.sessions[i].processingStatus = .settled
        state.sessions[i].reminderDueAt = nil
        _ = await flush()
    }
    public func reopenSession(_ id: UUID) async {
        guard initialized, storageError == nil, let i = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[i].sidebarStatus == .settled else { return }
        state.sessions[i].processingStatus = .open
        _ = await flush()
    }
    public func setSessionReminder(_ id: UUID, until: Date?) async {
        guard initialized, storageError == nil, let i = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[i].sidebarStatus == .open else { return }
        state.sessions[i].reminderDueAt = until
        _ = await flush()
    }

    public func sessionArchiveBlockReason(for session: SessionReference) -> LocalizedStringResource? {
        if !initialized || storageError != nil {
            return LocalizedStringResource("请先恢复工作台存储。", bundle: .atURL(#bundle.bundleURL))
        }
        if isOperating(on: session.id) {
            return LocalizedStringResource("请等待当前操作结束。", bundle: .atURL(#bundle.bundleURL))
        }
        if let controller = execution(for: session.id), !canReclaimRuntime(controller, for: session) {
            return LocalizedStringResource("请先结束运行并断开会话，再归档。", bundle: .atURL(#bundle.bundleURL))
        }
        return nil
    }

    @discardableResult public func setSessionArchived(_ id: UUID, archived: Bool) async -> Bool {
        guard initialized, storageError == nil, !isOperating(on: id),
              let reference = state.sessions.first(where: { $0.id == id }),
              (reference.archivedAt != nil) != archived else { return false }
        if archived, sessionArchiveBlockReason(for: reference) != nil { return false }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        if archived, !(await closeExecution(id)) { return false }
        guard !isShuttingDown else { return false }

        let archivedAt: Date? = archived ? clock.now() : nil
        guard await saveSnapshot(applying: { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].archivedAt = archivedAt
            if archived { snapshot.sessions[index].awaitsAutomaticTitle = nil }
            if archived, snapshot.selectedSessionID == id { snapshot.selectedSessionID = nil }
        }) else { return false }
        if archived {
            titleGenerationTasks[id]?.cancel()
            clearViewedSession(id)
        }
        return true
    }

    public func isDeletableDraft(_ session: SessionReference) -> Bool {
        !session.hasBoundRuntime && session.historyConfirmed != true && !session.wasExecuting &&
            session.submissions.isEmpty && session.recordedTurns?.isEmpty != false &&
            session.cachedHistoryItems?.isEmpty != false
    }

    public func canDeleteDraft(_ session: SessionReference) -> Bool {
        initialized && storageError == nil && !isOperating(on: session.id) &&
            isDeletableDraft(session) && execution(for: session.id) == nil && executionLaunches[session.id] == nil
    }

    @discardableResult public func deleteDraft(_ id: UUID, discardContents: Bool = false) async -> Bool {
        guard let reference = state.sessions.first(where: { $0.id == id }), canDeleteDraft(reference),
              discardContents || !hasDraft(reference) else { return false }
        let controller = presentations[id]?.controller
        controller?.isDraftEditingLocked = true
        deletingSessionIDs.insert(id)
        sessionOperations.insert(id)
        defer {
            deletingSessionIDs.remove(id)
            endOperation(id)
        }
        guard await saveSnapshot(applying: { snapshot in
            snapshot.sessions.removeAll { $0.id == id }
            if snapshot.selectedSessionID == id { snapshot.selectedSessionID = nil }
        }) else {
            controller?.isDraftEditingLocked = false
            return false
        }
        clearViewedSession(id)
        removeSessionPresentation(id)
        return true
    }

    private func clearViewedSession(_ id: UUID) {
        guard viewed?.id == id else { return }
        viewed = nil
        usageExpanded = false
    }

    private func removeSessionPresentation(_ id: UUID) {
        titleGenerationTasks[id]?.cancel()
        presentations.removeValue(forKey: id)
        draftIndicators.removeValue(forKey: id)
        idleReapers.removeValue(forKey: id)?.cancel()
        dirtyDrafts.remove(id)
    }

    private func initializeSidebarMetadata(at index: Int) {
        let session = state.sessions[index]
        if session.processingStatus == nil {
            let hasPendingDelivery = session.submissions.contains { $0.needsReview || [.pending, .accepted, .queued, .unknown].contains($0.delivery) }
            let hasHistory = session.resumableSession == true && session.runtimeSessionID != nil
            state.sessions[index].processingStatus = hasHistory && !session.wasExecuting && !hasDraft(session) && !hasPendingDelivery ? .settled : .open
        }
        if session.sidebarActivity == nil {
            state.sessions[index].sidebarActivity = .init(date: session.lastViewed, isEstimate: true)
        }
    }
    public func select(_ id: UUID) async {
        guard initialized, !deletingSessionIDs.contains(id), let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        if state.selectedSessionID != id { usageExpanded = false }
        state.selectedSessionID = id; state.sessions[i].lastViewed = Date()
        if let p = state.projects.firstIndex(where: { $0.id == state.sessions[i].projectID }) { state.projects[p].lastViewed = Date() }
        viewed = presentation(id); scheduleSave()
        scheduleIdleReap(id)
        await refreshHistory(id)
        trimHistoryCache(keeping: id)
    }
    public func openSessionForReview(_ id: UUID) async {
        let completion = state.sessions.first(where: { $0.id == id })?.unreadCompletionTurnID
        await openSessionForReview(id, acknowledging: completion)
    }

    /// A notification may refer to an older turn or to an approval, not to the latest completion.
    public func openSessionForReview(_ id: UUID, acknowledging completion: UUID?) async {
        await select(id)
        // Do not acknowledge a newer completion that arrived during the history read.
        guard let completion, state.selectedSessionID == id, let viewed, !viewed.loading, viewed.loadError == nil,
              let index = state.sessions.firstIndex(where: { $0.id == id && $0.unreadCompletionTurnID == completion }) else { return }
        state.sessions[index].unreadCompletionTurnID = nil
        scheduleSave()
    }
    public func refreshHistory(_ id: UUID) async {
        recheckHandoffCleanup(id)
        guard let reference = state.sessions.first(where: { $0.id == id }) else { return }
        let view = presentation(id)
        await loadFrozenHistory(reference, into: view)
        guard state.sessions.first(where: { $0.id == id })?.segmentID == reference.segmentID else { return }
        if view.controller.connection != .disconnected { return }
        view.loadError = nil
        view.executionIssue = isHandoffCleanupPending(for: id) ? Self.handoffCleanupIssue : Self.acpResumeIssue(for: reference)
        let cached = reference.cachedHistoryItems ?? []
        if !cached.isEmpty {
            let notice = view.executionIssue == nil
                ? String(localized: "当前处于离线状态，展示缓存内容。", bundle: #bundle)
                : nil
            view.controller.showCachedHistory(
                cached,
                recordedTurns: reference.recordedTurns ?? [],
                recordedMessages: reference.recordedMessages ?? [],
                notice: notice
            )
        } else if view.controller.showingCachedHistory {
            view.controller.showCachedHistory([])
        }
    }
    public func refreshWorkspaceHistory() async {
        if let id = state.selectedSessionID { await refreshHistory(id) }
    }
    public nonisolated static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    @discardableResult public func chooseWorkingDirectory(worktree: String?, for id: UUID) async -> Bool {
        guard !isOperating(on: id), storageError == nil,
              let initial = state.sessions.first(where: { $0.id == id && $0.archivedAt == nil }),
              let project = state.projects.first(where: { $0.id == initial.projectID }) else { return false }
        let source = presentation(id)
        source.executionError = nil
        let path = worktree.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let target = path ?? project.path
        sessionOperations.insert(id)
        defer { endOperation(id) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else {
            source.executionError = String(localized: "工作目录不可用：\(target)", bundle: #bundle)
            return false
        }
        if let path, !(await validateWorktree(project.path, path)) {
            source.executionError = String(localized: "工作树不可用：\(path)", bundle: #bundle)
            return false
        }
        guard !isShuttingDown,
              let reference = state.sessions.first(where: { $0.id == id }) else { return false }
        if reference.worktreePath == path,
           URL(fileURLWithPath: reference.workingDirectory(in: project)).standardizedFileURL.path ==
            URL(fileURLWithPath: target).standardizedFileURL.path { return true }
        if reference.hasBoundRuntime {
            guard await waitForSessionDefaults(for: { defaultRuntimeID }),
                  storageError == nil, !isShuttingDown else { return false }
            guard let runtimeID = defaultRuntimeID else {
                source.executionError = String(localized: "请先在「设置 → 智能体」中添加或启用智能体。", bundle: #bundle)
                return false
            }
            var newSession = makeNewSession(in: project.id, runtimeID: runtimeID)
            newSession.worktreePath = path
            newSession.draft = source.controller.draft
            newSession.draftFiles = source.controller.draftFiles
            newSession.mode = source.controller.mode
            guard await saveSnapshot(applying: { $0.sessions.append(newSession) }) else { return false }
            if state.selectedSessionID == id { await select(newSession.id) }
            return true
        }

        if let controller = execution(for: id) {
            guard isIdle(controller), await closeExecution(id) else {
                source.executionError = controller.failure?.detail ?? String(localized: "请等待会话空闲后再更改工作目录。", bundle: #bundle)
                return false
            }
        }
        guard !isShuttingDown else { return false }
        return await saveSnapshot(applying: { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].worktreePath = path
        })
    }

    /// Establish a supervised connection without changing the viewed session.
    @discardableResult public func activate(_ id: UUID) async -> Bool {
        guard initialized, !isOperating(on: id), storageError == nil,
              state.sessions.first(where: { $0.id == id })?.handoff?.delivered != false else { return false }
        sessionOperations.insert(id)
        presentations[id]?.handoffPreviewToken = nil
        defer { endOperation(id) }
        return await openExecution(id)
    }

    private func endOperation(_ id: UUID) {
        if presentations[id]?.controller.connection == .disconnected {
            activeExecutionIDs.remove(id)
            executionLaunches.removeValue(forKey: id)
        }
        sessionOperations.remove(id)
        scheduleIdleReap(id)
    }

    private func scheduleIdleReap(_ id: UUID) {
        idleReapers.removeValue(forKey: id)?.cancel()
        guard !isOperating(on: id), execution(for: id)?.canReclaimIdleRuntime == true else { return }
        idleReapers[id] = Task { [weak self, idleRuntimeTimeout] in
            do { try await Task.sleep(for: idleRuntimeTimeout) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.idleReapers.removeValue(forKey: id)
            guard !self.isOperating(on: id), let controller = self.execution(for: id),
                  let reference = self.state.sessions.first(where: { $0.id == id }),
                  self.canReclaimRuntime(controller, for: reference) else { return }
            // Use the same close path as a manual disconnect. Unknown cleanup keeps the slot blocked.
            _ = await self.disconnect(id)
        }
    }

    private func canReclaimRuntime(_ controller: SessionController, for reference: SessionReference) -> Bool {
        guard controller.canReclaimIdleRuntime, reference.submissions.isEmpty else { return false }
        // Resume only when there is durable history, or nothing to resume yet.
        return !reference.hasNonResumableACPHistory &&
            (controller.transcript.isEmpty || (reference.resumableSession == true && reference.runtimeSessionID != nil))
    }

    private func matchesLaunchConfiguration(_ id: UUID, directory: String) -> Bool {
        executionLaunches[id]?.canonicalDirectory == Self.canonicalPath(directory)
    }

    private func openExecution(_ id: UUID, historyOnly: Bool = false) async -> Bool {
        recheckHandoffCleanup(id)
        guard let reference = state.sessions.first(where: { $0.id == id && $0.archivedAt == nil }),
              let project = state.projects.first(where: { $0.id == reference.projectID }) else { return false }
        let view = presentation(id)
        view.executionError = nil
        guard !isHandoffCleanupPending(for: id) else {
            view.executionIssue = Self.handoffCleanupIssue
            return false
        }
        let directoryPath = reference.workingDirectory(in: project)
        if reference.worktreePath == nil, Self.canonicalPath(directoryPath) != Self.canonicalPath(project.path) {
            view.executionError = String(localized: "历史工作目录与当前位置不同。旧会话可只读查看；请在当前位置新建会话。", bundle: #bundle)
            return false
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &directory), directory.boolValue else {
            view.executionError = String(localized: "工作目录不可用：\(directoryPath)", bundle: #bundle)
            return false
        }
        if let path = reference.worktreePath {
            let registeredPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard URL(fileURLWithPath: directoryPath).standardizedFileURL.path == registeredPath,
                  await validateWorktree(project.path, directoryPath) else {
                view.executionError = String(localized: "工作树不可用：\(path)", bundle: #bundle)
                return false
            }
        }
        guard !isShuttingDown else { return false }

        let active = execution(for: id)
        if let controller = active {
            if matchesLaunchConfiguration(id, directory: directoryPath) || controller.phase.isActive || !controller.queue.isEmpty {
                if isIdle(controller), let desired = reference.pendingSelection { return await applySelection(desired, to: id) }
                return true
            }
        }
        if let issue = Self.acpResumeIssue(for: reference) {
            view.executionIssue = issue
            return false
        }
        if let controller = active {
            guard controller.connection != .blocked, controller.phase != .uncertain, !controller.commandPending,
                  controller.interactions.isEmpty, !controller.replying,
                  await closeExecution(id) else {
                view.executionError = controller.failure?.detail ?? String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle)
                return false
            }
        }

        guard !isShuttingDown else { return false }
        activeExecutionIDs.insert(id)
        await refreshHistory(id)
        guard isExecutable(view),
              let current = state.sessions.first(where: { $0.id == id }),
              let currentProject = state.projects.first(where: { $0.id == current.projectID }) else { return false }

        // Re-verify target directory and worktree ownership after async validation and history loading.
        var verifiedDirectory = current.workingDirectory(in: currentProject)
        var verifiedCanonical = Self.canonicalPath(verifiedDirectory)
        var verifiedDirFlag: ObjCBool = false
        guard verifiedCanonical == Self.canonicalPath(directoryPath),
              FileManager.default.fileExists(atPath: verifiedDirectory, isDirectory: &verifiedDirFlag), verifiedDirFlag.boolValue else {
            view.executionError = String(localized: "工作目录不可用：\(verifiedDirectory)", bundle: #bundle)
            return false
        }
        if current.worktreePath == nil, verifiedCanonical != Self.canonicalPath(currentProject.path) {
            view.executionError = String(localized: "历史工作目录与当前位置不同。旧会话可只读查看；请在当前位置新建会话。", bundle: #bundle)
            return false
        }
        if let path = current.worktreePath {
            guard verifiedCanonical == URL(fileURLWithPath: verifiedDirectory).standardizedFileURL.path,
                  await validateWorktree(currentProject.path, verifiedDirectory) else {
                view.executionError = String(localized: "工作树不可用：\(verifiedDirectory)", bundle: #bundle)
                return false
            }
            guard !isShuttingDown,
                  let recheckedSession = state.sessions.first(where: { $0.id == id }),
                  let recheckedProject = state.projects.first(where: { $0.id == recheckedSession.projectID }) else { return false }
            verifiedDirectory = recheckedSession.workingDirectory(in: recheckedProject)
            verifiedCanonical = Self.canonicalPath(verifiedDirectory)
            var recheckedDirFlag: ObjCBool = false
            guard recheckedSession.worktreePath == path,
                  verifiedCanonical == Self.canonicalPath(directoryPath),
                  verifiedCanonical == URL(fileURLWithPath: verifiedDirectory).standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: verifiedDirectory, isDirectory: &recheckedDirFlag), recheckedDirFlag.boolValue else {
                view.executionError = String(localized: "工作树不可用：\(verifiedDirectory)", bundle: #bundle)
                return false
            }
        }

        let launch = WorkspaceRuntimeLaunch(
            workingDirectory: verifiedDirectory,
            canonicalDirectory: verifiedCanonical,
            handoffCleanupID: current.isACPRuntime && current.handoff?.delivered == false ? UUID() : nil
        )
        executionLaunches[id] = launch
        view.controller.reconnectingACPHistory = current.isACPRuntime && current.runtimeSessionID != nil
        await view.controller.connect(
            runtimeFactory(currentProject, current, launch),
            recordedTurns: current.recordedTurns ?? [],
            recordedMessages: current.recordedMessages ?? [],
            historyOnly: historyOnly
        )
        guard view.controller.connection == .connected else {
            view.executionError = view.controller.failure?.detail ?? String(localized: "连接失败。", bundle: #bundle)
            return false
        }
        if let expected = current.runtimeSessionID, view.controller.session?.id != expected {
            view.executionError = String(localized: "执行会话标识与历史绑定不一致，没有发送任务。", bundle: #bundle)
            _ = await closeExecution(id, force: true)
            return false
        }
        await view.controller.reconcileLoadedSessionHistory()
        if historyOnly { return true }
        if current.isACPRuntime,
           let desiredMode = current.runtimeModeID,
           view.controller.session?.modeID != desiredMode,
           view.controller.supportsModeSelection,
           view.controller.session?.availableModes.isEmpty == true ||
               view.controller.session?.availableModes.contains(where: { $0.id == desiredMode }) == true {
            _ = await view.controller.setRuntimeMode(desiredMode)
        }
        if let desired = current.pendingSelection ?? current.selection,
           current.pendingSelection != nil || !matchesSelection(desired, session: view.controller.session) {
            return await applySelection(desired, to: id)
        }
        synchronize(id)
        guard await flush() else { _ = await closeExecution(id); return false }
        return true
    }

    private func isIdle(_ controller: SessionController) -> Bool {
        controller.connection == .connected && controller.phase == .idle &&
            controller.queueIsKnown && controller.queue.isEmpty && controller.interactions.isEmpty &&
            !controller.commandPending && !controller.replying
    }

    private func isExecutable(_ view: SessionPresentation) -> Bool {
        guard !view.loading, view.loadError == nil, view.executionIssue == nil else {
            view.executionError = view.loadError ?? view.executionIssue
            return false
        }
        return true
    }

    private static func acpResumeIssue(for reference: SessionReference) -> String? {
        if reference.remoteHistoryDeleted == true {
            return String(localized: "Agent 历史已删除。原有记录可只读查看。", bundle: #bundle)
        }
        guard reference.hasNonResumableACPHistory else { return nil }
        return String(localized: "该 ACP 会话无法恢复。请新建会话继续，原有历史可只读查看。", bundle: #bundle)
    }

    private static var handoffCleanupIssue: String {
        String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle)
    }

    public func isHandoffCleanupPending(for id: UUID) -> Bool {
        execution(for: id) == nil &&
            state.sessions.first(where: { $0.id == id })?.requiresHandoffCleanupConfirmation == true
    }

    @discardableResult private func reconcileHandoffCleanup(at index: Int) -> Bool {
        guard let cleanupID = state.sessions[index].handoffCleanupID, verifyHandoffCleanup(cleanupID) else { return false }
        state.sessions[index].handoffCleanupID = nil
        state.sessions[index].releaseUnacceptedACPBinding()
        return true
    }

    private func recheckHandoffCleanup(_ id: UUID) {
        guard isHandoffCleanupPending(for: id),
              let index = state.sessions.firstIndex(where: { $0.id == id }),
              reconcileHandoffCleanup(at: index) else { return }
        presentations[id]?.executionIssue = Self.acpResumeIssue(for: state.sessions[index])
        scheduleSave()
    }

    public func send(_ id: UUID, submitted: UserPrompt? = nil) async {
        guard initialized, !isOperating(on: id), storageError == nil,
              let reference = state.sessions.first(where: { $0.id == id && $0.archivedAt == nil }) else { return }
        let view = presentation(id)
        guard !reference.submissions.contains(where: \.needsReview),
              reference.handoff?.delivered != false || reference.handoff?.firstSubmissionID == nil else {
            view.executionError = String(localized: "该会话有未核实的发送记录。请先核对执行结果，避免重复操作。", bundle: #bundle)
            return
        }
        if let active = execution(for: id), active.connection == .connected, active.phase.isActive, !active.supportsQueuedPrompts {
            return
        }
        if let active = execution(for: id), reference.pendingSelection != nil, active.phase.isActive || !active.queue.isEmpty {
            view.executionError = String(localized: "当前任务及队列完成后才能使用待应用模型，草稿已保留。", bundle: #bundle)
            return
        }
        let submitted = submitted ?? view.controller.draftPrompt
        guard submitted.hasContent else { return }
        sessionOperations.insert(id)
        view.handoffPreviewToken = nil
        let sendingHandoff = reference.handoff?.delivered == false
        if sendingHandoff { view.setSubmittingHandoff(true) }
        defer {
            if sendingHandoff { view.setSubmittingHandoff(false) }
            endOperation(id)
        }
        guard await openExecution(id), !isShuttingDown, let controller = execution(for: id) else {
            if !isShuttingDown, let handoff = reference.handoff, !handoff.delivered,
               let index = state.sessions.firstIndex(where: { $0.id == id && $0.handoff?.id == handoff.id }),
               state.sessions[index].handoff?.firstSubmissionID == nil {
                state.sessions[index].handoff?.lastSubmissionRejected = true
                scheduleSave()
            }
            return
        }
        let context = reference.handoff.flatMap { $0.delivered ? nil : $0.context }
        let message = UserPrompt(id: submitted.id, text: submitted.text, mode: submitted.mode,
                                 files: submitted.files, handoffContext: context)
        await controller.sendDraft(message)
        synchronize(id)
        _ = await flush()
    }

    private func closeExecution(_ id: UUID, force: Bool = false) async -> Bool {
        guard let controller = execution(for: id) else {
            recheckHandoffCleanup(id)
            return !isHandoffCleanupPending(for: id)
        }
        guard await controller.disconnect(force: force) else { return false }
        activeExecutionIDs.remove(id)
        executionLaunches.removeValue(forKey: id)
        return true
    }

    @discardableResult public func disconnect(_ id: UUID, force: Bool = false) async -> Bool {
        guard !sessionOperations.contains(id), !deletingSessionIDs.contains(id) else { return false }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        let closed = await closeExecution(id, force: force)
        let saved = await flush()
        return closed && saved
    }

    public func stop(_ id: UUID) async {
        guard !isShuttingDown, let controller = execution(for: id),
              !sessionOperations.contains(id) || !controller.interactions.isEmpty else { return }
        await controller.stop()
        _ = await flush()
    }

    public func stopViewedSession() async {
        guard let id = state.selectedSessionID else { return }
        await stop(id)
    }

    public func canStop(_ id: UUID) -> Bool {
        guard !isShuttingDown, let controller = execution(for: id) else { return false }
        return controller.canStop && (!sessionOperations.contains(id) || !controller.interactions.isEmpty)
    }

    public func beginShutdown() {
        isShuttingDown = true
        for task in idleReapers.values { task.cancel() }
        for task in titleGenerationTasks.values { task.cancel() }
        idleReapers.removeAll()
    }
    public func cancelShutdown() {
        isShuttingDown = false
        for id in executionIDs { scheduleIdleReap(id) }
    }

    public func disconnectAll(force: Bool = false) async -> Bool {
        if isShuttingDown {
            for task in Array(titleGenerationTasks.values) { await task.value }
        }
        var clean = true
        for id in executionIDs {
            if !(await disconnect(id, force: force)) { clean = false }
        }
        let saved = await flush()
        return clean && saved && sessionOperations.isEmpty && activeExecutionIDs.isEmpty && executionLaunches.isEmpty
    }

    public func reviewSubmission(_ submissionID: UUID, in id: UUID) async {
        guard !isOperating(on: id), let i = state.sessions.firstIndex(where: { $0.id == id }),
              let j = state.sessions[i].submissions.firstIndex(where: { $0.id == submissionID }) else { return }
        state.sessions[i].submissions[j].needsReview = false; _ = await flush()
    }

    public func confirmHandoffDelivery(_ submissionID: UUID, in id: UUID) async {
        guard !isOperating(on: id), storageError == nil,
              let i = state.sessions.firstIndex(where: { $0.id == id }),
              let handoff = state.sessions[i].handoff, !handoff.delivered, handoff.firstSubmissionID == submissionID,
              let submission = state.sessions[i].submissions.first(where: { $0.id == submissionID && $0.delivery == .unknown }),
              presentation(id).controller.canReviewHandoffSubmission(submissionID) else { return }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        guard await saveSnapshot(applying: { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            let targetModel = snapshot.sessions[index].recordedTurns?.first?.model
                ?? SessionTurnModel(self.presentations[id]?.controller.session)
            snapshot.sessions[index].handoff?.delivered = true
            snapshot.sessions[index].handoff?.targetModel = targetModel
            var messages = snapshot.sessions[index].recordedMessages ?? []
            if !messages.contains(where: { $0.id == submissionID }) {
                messages.append(.init(id: submissionID, text: submission.text, files: submission.files,
                                      sentAt: submission.sentAt, handoffContext: handoff.context))
                snapshot.sessions[index].recordedMessages = messages
            }
            snapshot.sessions[index].submissions.removeAll { $0.id == submissionID }
        }) else { return }
        presentations[id]?.controller.finishHandoffSubmissionReview(submissionID, delivery: .accepted)
        if let confirmed = state.sessions.first(where: { $0.id == id })?.handoff {
            presentations[id]?.activeHandoffMarker = Self.handoffMarker(confirmed)
        }
    }
    public func restoreReviewedSubmission(_ submissionID: UUID, in id: UUID) async {
        func reviewedSubmission(in reference: SessionReference) -> Int? {
            reference.submissions.firstIndex { $0.id == submissionID && $0.delivery == .unknown && !$0.needsReview }
        }
        guard !isOperating(on: id), storageError == nil else { return }
        recheckHandoffCleanup(id)
        guard !isHandoffCleanupPending(for: id),
              let reference = state.sessions.first(where: { $0.id == id }), reviewedSubmission(in: reference) != nil else { return }
        let view = presentation(id)
        let isFirstHandoff = reference.handoff?.firstSubmissionID == submissionID
        if isFirstHandoff {
            guard reference.handoff?.delivered == false, view.controller.canReviewHandoffSubmission(submissionID) else { return }
        }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        let needsFreshACP = isFirstHandoff && reference.isACPRuntime && reference.runtimeSessionID != nil && reference.resumableSession != true
        if needsFreshACP {
            let closed = if execution(for: id) != nil {
                await closeExecution(id, force: true)
            } else {
                await view.controller.disconnect(force: true)
            }
            guard closed else {
                view.executionError = view.controller.failure?.detail ?? String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle)
                return
            }
        }
        guard let i = state.sessions.firstIndex(where: { $0.id == id }), let j = reviewedSubmission(in: state.sessions[i]),
              !isFirstHandoff || (state.sessions[i].handoff?.delivered == false && view.controller.canReviewHandoffSubmission(submissionID)) else { return }
        let submission = state.sessions[i].submissions.remove(at: j)
        if isFirstHandoff {
            state.sessions[i].discardUnacceptedHandoffSubmission(submissionID)
            view.controller.finishHandoffSubmissionReview(submissionID, delivery: .rejected)
        }
        if needsFreshACP {
            state.sessions[i].runtimeSessionID = nil
            state.sessions[i].resumableSession = nil
            state.sessions[i].canDeleteRemoteHistory = nil
            state.sessions[i].cachedHistoryItems = nil
            state.sessions[i].recordedTurns = nil
            view.executionIssue = nil
            view.executionError = nil
            view.controller.resetForHandoff(to: state.sessions[i].segmentID)
        }
        view.controller.mergeIntoDraft(.init(id: submission.id, text: submission.text,
                                             mode: submission.mode, files: submission.files ?? []))
        _ = await flush()
    }
    public func canConfigureSession(for id: UUID) -> Bool {
        guard !isOperating(on: id), storageError == nil,
              state.sessions.contains(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
        guard let active = execution(for: id) else { return true }
        return !active.phase.isActive && !active.commandPending && active.queue.isEmpty && active.interactions.isEmpty
    }

    public func handoffBlockReason(for id: UUID) -> String? {
        guard initialized, storageError == nil, !isOperating(on: id),
              presentations[id]?.loading != true,
              let reference = state.sessions.first(where: { $0.id == id && $0.archivedAt == nil }),
              reference.hasBoundRuntime else {
            return String(localized: "当前无法切换智能体。", bundle: #bundle)
        }
        if reference.submissions.contains(where: \.needsReview) ||
            (reference.handoff?.delivered == false && reference.handoff?.firstSubmissionID != nil) {
            return String(localized: "请先核对未确认的消息，再切换智能体。", bundle: #bundle)
        }
        if isHandoffCleanupPending(for: id) { return Self.handoffCleanupIssue }
        if let controller = presentations[id]?.controller,
           controller.connection != .disconnected && !controller.canReclaimIdleRuntime {
            return String(localized: "请等待当前运行、排队消息及审批全部结束后再切换。", bundle: #bundle)
        }
        return nil
    }

    public func prepareHandoff(for id: UUID) async throws -> SessionHandoffPreview {
        recheckHandoffCleanup(id)
        if let reason = handoffBlockReason(for: id) { throw RuntimeFailure(.setup, reason) }
        guard let reference = state.sessions.first(where: { $0.id == id }), let directory = workingDirectory(for: id) else {
            throw RuntimeFailure(.setup, String(localized: "当前无法切换智能体。", bundle: #bundle))
        }
        let view = presentation(id)
        let token = UUID()
        sessionOperations.insert(id)
        defer { endOperation(id) }
        if let pending = reference.handoff, !pending.delivered {
            if let draft = pending.draft {
                let history = try? await store.loadSessionHistory(segmentID: pending.source)
                guard !Task.isCancelled else { throw CancellationError() }
                view.handoffPreviewToken = token
                return SessionHandoffPreview(sourceAgent: pending.sourceAgent, directory: directory,
                                             coverage: history?.coverage ?? .unavailable, draft: draft,
                                             excerpts: history?.handoffExcerpts ?? [], source: reference.segmentID,
                                             history: nil, token: token)
            }
            let snapshot = try await store.loadSessionHistory(segmentID: pending.source)
            let fileHistory = await handoffFileHistory(in: reference, including: nil)
            guard !Task.isCancelled else { throw CancellationError() }
            let preview = snapshot.preview(source: reference.segmentID, agent: pending.sourceAgent, directory: directory,
                                           token: token, retainingHistory: false, fileHistory: fileHistory)
            view.handoffPreviewToken = token
            return preview
        }

        let controller = view.controller
        let reloading = reference.isACPRuntime && controller.connection == .disconnected && reference.resumableSession == true &&
            reference.runtimeSessionID != nil && reference.remoteHistoryDeleted != true && isRuntimeAvailable(reference.runtimeID)
        if reloading { _ = await openExecution(id, historyOnly: true) }
        var snapshot: SessionHistorySnapshot
        do {
            if controller.connection == .disconnected && controller.transcript.isEmpty { await refreshHistory(id) }
            let partial = controller.showingCachedHistory ||
                (controller.reconnectingACPHistory && !controller.receivedHistoryReplay)
            snapshot = .init(transcript: controller.transcript, turnStarts: controller.transcriptTurnStarts,
                             coverage: controller.transcript.isEmpty ? .unavailable : (partial ? .partial : .available))
        }
        if reloading, controller.connection != .disconnected {
            guard controller.connection == .connected, isIdle(controller), await closeExecution(id) else {
                throw RuntimeFailure(.connection, controller.failure?.detail ?? String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle))
            }
        }
        let storedTurns = state.sessions.first(where: { $0.id == id })?.recordedTurns ?? []
        snapshot.fileChangeRecords = snapshot.fileRecords(including: storedTurns)
        let fileHistory = await handoffFileHistory(in: reference, including: snapshot)
        guard !Task.isCancelled else { throw CancellationError() }
        view.handoffPreviewToken = token
        return snapshot.preview(source: reference.segmentID, agent: runtimeDisplayName(for: reference.runtimeID),
                                directory: directory, token: token, retainingHistory: true, fileHistory: fileHistory)
    }

    private func handoffFileHistory(in reference: SessionReference,
                                    including active: SessionHistorySnapshot?) async -> [SessionHandoffFileHistory] {
        var segments: [SessionHandoffFileHistory] = []
        for segment in reference.frozenSegments ?? [] {
            let history = try? await store.loadSessionHistory(segmentID: segment.id)
            segments.append(.init(id: segment.id, coverage: history?.coverage ?? .unavailable,
                                  turns: history?.fileRecords ?? []))
        }
        if let active {
            segments.append(.init(id: reference.segmentID, coverage: active.coverage, turns: active.fileRecords))
        }
        return segments
    }

    @discardableResult public func commitHandoff(_ preview: SessionHandoffPreview, to runtimeID: String,
                                                  selection: RuntimeSelection?, modelName: String?, context: String,
                                                  draft: SessionHandoffDraft? = nil,
                                                  for id: UUID) async throws -> Bool {
        recheckHandoffCleanup(id)
        if let reason = handoffBlockReason(for: id) { throw RuntimeFailure(.setup, reason) }
        let view = presentation(id)
        guard let source = state.sessions.first(where: { $0.id == id }), source.segmentID == preview.source,
              state.selectedSessionID == id, view.handoffPreviewToken == preview.token,
              workingDirectory(for: id) == preview.directory, runtimeID != source.runtimeID, isRuntimeAvailable(runtimeID) else {
            throw RuntimeFailure(.setup, String(localized: "会话或目标已变化，请重新预览交接。", bundle: #bundle))
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: preview.directory, isDirectory: &directory), directory.boolValue else {
            throw RuntimeFailure(.setup, String(localized: "工作目录不可用：\(preview.directory)", bundle: #bundle))
        }

        sessionOperations.insert(id)
        defer { endOperation(id) }
        if let project = state.projects.first(where: { $0.id == source.projectID }) {
            let canonicalDirectory = Self.canonicalPath(preview.directory)
            if let worktree = source.worktreePath {
                guard Self.canonicalPath(worktree) == canonicalDirectory, await validateWorktree(project.path, canonicalDirectory) else {
                    throw RuntimeFailure(.setup, String(localized: "工作树不可用：\(worktree)", bundle: #bundle))
                }
            } else if canonicalDirectory != Self.canonicalPath(project.path) {
                throw RuntimeFailure(.setup, String(localized: "历史工作目录与当前位置不同。旧会话可只读查看；请在当前位置新建会话。", bundle: #bundle))
            }
        }
        var segments = source.frozenSegments ?? []
        let sourceID: UUID
        if let history = preview.history {
            sourceID = source.segmentID
            try await store.saveSessionHistory(history, segmentID: sourceID)
            segments.append(.init(id: sourceID, runtimeID: source.runtimeID, runtimeSessionID: source.runtimeSessionID,
                                  file: source.file, modelName: source.modelName, selection: source.selection,
                                  modeID: source.runtimeModeID, coverage: preview.coverage, incomingHandoff: source.handoff))
        } else if let previous = source.handoff, !previous.delivered {
            sourceID = previous.source
        } else {
            throw RuntimeFailure(.setup, String(localized: "会话或目标已变化，请重新预览交接。", bundle: #bundle))
        }
        guard view.handoffPreviewToken == preview.token,
              view.controller.connection == .disconnected || view.controller.canReclaimIdleRuntime else {
            throw RuntimeFailure(.setup, String(localized: "会话或目标已变化，请重新预览交接。", bundle: #bundle))
        }
        guard await closeExecution(id) else {
            throw RuntimeFailure(.connection, view.controller.failure?.detail ?? String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle))
        }
        guard !isShuttingDown, isRuntimeAvailable(runtimeID), state.selectedSessionID == id,
              workingDirectory(for: id) == preview.directory else {
            throw RuntimeFailure(.setup, String(localized: "会话或目标已变化，请重新预览交接。", bundle: #bundle))
        }

        let target = makeNewSession(in: source.projectID, runtimeID: runtimeID)
        let handoff = SessionHandoff(id: UUID(), source: sourceID, sourceAgent: preview.sourceAgent,
                                     targetAgent: runtimeDisplayName(for: runtimeID), coverage: preview.coverage,
                                     context: draft?.context ?? context, draft: draft, sentTextContext: draft?.textContext)
        // Only replace runtime-owned fields. Drafts and other conversation fields may change while saving.
        guard await saveSnapshot(applying: { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].beginHandoff(handoff, target: target, selection: selection, modelName: modelName,
                                                  directory: preview.directory, frozenSegments: segments)
        }) else { return false }

        view.handoffPreviewToken = nil
        view.readGeneration = UUID()
        view.loading = false
        view.loadError = nil
        view.executionError = nil
        view.executionIssue = nil
        view.activeHandoffMarker = nil
        view.controller.resetForHandoff(to: handoff.id)
        if let updated = state.sessions.first(where: { $0.id == id }) { await loadFrozenHistory(updated, into: view) }
        return true
    }

    public func updateHandoffContext(_ context: String, draft: SessionHandoffDraft? = nil, for id: UUID) async -> Bool {
        guard handoffBlockReason(for: id) == nil,
              let old = state.sessions.first(where: { $0.id == id })?.handoff, !old.delivered,
              old.firstSubmissionID == nil else { return false }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        return await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].handoff?.context = draft?.context ?? context
            snapshot.sessions[index].handoff?.draft = draft
            snapshot.sessions[index].handoff?.sentTextContext = draft?.textContext
        }
    }

    private func loadFrozenHistory(_ reference: SessionReference, into view: SessionPresentation) async {
        let segments = reference.frozenSegments ?? []
        let ids = segments.map(\.id)
        guard ids != view.frozenSegmentIDs else { return }
        let prefixCount = view.frozenSegmentIDs.count
        let canAppend = ids.starts(with: view.frozenSegmentIDs)
        var items = canAppend ? view.frozenTranscript : []
        var rows = canAppend ? view.frozenRows : []
        for segment in segments.dropFirst(canAppend ? prefixCount : 0) {
            let marker = segment.incomingHandoff.flatMap { $0.delivered ? Self.handoffMarker($0) : nil }
            do {
                let history = try await store.loadSessionHistory(segmentID: segment.id)
                let timeline = history.timeline()
                if let marker { items.append(marker) }
                items.append(contentsOf: timeline.items)
                rows.append(contentsOf: TranscriptDisplayRow.placingHandoff(marker, in: timeline.rows))
            } catch {
                if let marker {
                    items.append(marker)
                    rows.append(.item(marker))
                }
                let notice = TranscriptItem(id: "missing-segment:\(segment.id)", kind: .notice,
                                            text: String(localized: "无法读取这一段已保存的会话历史。", bundle: #bundle))
                items.append(notice)
                rows.append(.item(notice))
            }
        }
        guard state.sessions.first(where: { $0.id == reference.id })?.frozenSegments?.map(\.id) == ids else { return }
        view.setFrozenTranscript(items, rows: rows, segmentIDs: ids)
    }

    private static func handoffMarker(_ handoff: SessionHandoff) -> TranscriptItem {
        let row = TranscriptItem(id: "handoff:\(handoff.id)", kind: .notice,
                                 text: "\(handoff.sourceAgent) → \(handoff.targetAgent)")
        row.handoff = handoff
        return row
    }

    public func canSwitchDraftAgent(for reference: SessionReference) -> Bool {
        !reference.hasBoundRuntime && reference.archivedAt == nil && execution(for: reference.id) == nil &&
            availableRuntimeIDs.contains { $0 != reference.runtimeID }
    }

    @discardableResult public func setSessionRuntime(_ runtimeID: String, for id: UUID) async -> Bool {
        guard initialized, !isOperating(on: id), storageError == nil,
              isRuntimeAvailable(runtimeID),
              let reference = state.sessions.first(where: { $0.id == id && $0.archivedAt == nil }),
              !reference.hasBoundRuntime,
              execution(for: id) == nil,
              (presentations[id]?.controller.connection ?? .disconnected) == .disconnected else { return false }
        if reference.runtimeID == runtimeID { return true }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        let saved = await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }),
                  !snapshot.sessions[index].hasBoundRuntime else { return }
            snapshot.sessions[index].runtimeID = runtimeID
            snapshot.sessions[index].selection = nil
            snapshot.sessions[index].modelName = nil
            snapshot.sessions[index].runtimeModeID = nil
            snapshot.sessions[index].resumableSession = nil
            snapshot.sessions[index].cachedHistoryItems = nil
            let initialModel = snapshot.modelPreferences(forRuntime: runtimeID).defaultModel
            if let model = initialModel {
                snapshot.sessions[index].pendingSelection = .init(provider: model.provider, modelID: model.modelID)
                snapshot.sessions[index].pendingModelName = model.name
            } else {
                snapshot.sessions[index].pendingSelection = nil
                snapshot.sessions[index].pendingModelName = nil
            }
            snapshot.sessions[index].modelSource = .global
        }
        if saved, let view = presentations[id] {
            view.loadError = nil
            view.executionIssue = nil
            view.executionError = nil
        }
        return saved
    }
    @discardableResult public func setACPMode(_ modeID: String, for id: UUID) async -> Bool {
        guard initialized, canConfigureSession(for: id),
              let reference = state.sessions.first(where: { $0.id == id }),
              reference.isACPRuntime else { return false }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        if let active = execution(for: id), active.connection == .connected {
            guard isIdle(active) else { return false }
            guard await active.setRuntimeMode(modeID) else {
                presentation(id).executionError = active.failure?.detail ?? String(localized: "模式切换暂时无法应用。", bundle: #bundle)
                return false
            }
            if let index = state.sessions.firstIndex(where: { $0.id == id }) {
                state.sessions[index].runtimeModeID = active.session?.modeID ?? modeID
            }
            synchronize(id)
            return await flush()
        }
        return await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].runtimeModeID = modeID
        }
    }
    public func modelPreferences(forRuntime runtimeID: String) -> WorkspaceModelPreferences {
        state.modelPreferences(forRuntime: runtimeID)
    }
    public func modelCatalogue(for id: UUID) async throws -> [RuntimeModel] {
        if let active = try metadataRuntime(for: id, model: nil) {
            return try await active.modelCatalogue()
        }
        let runtimeID = try sessionRuntimeID(for: id)
        return try await inspectRuntimeModels(runtimeID, nil).models
    }
    private func sessionRuntimeID(for id: UUID) throws -> String {
        guard let session = state.sessions.first(where: { $0.id == id }) else {
            throw RuntimeFailure(.setup, String(localized: "会话已不可用。", bundle: #bundle))
        }
        return session.runtimeID
    }
    public func modelCatalogue(forRuntime runtimeID: String) async throws -> [RuntimeModel] {
        try await inspectRuntimeModels(runtimeID, nil).models
    }

    @discardableResult public func setDefaultModel(_ model: RuntimeModel?, forRuntime runtimeID: String) async -> Bool {
        guard initialized, !isShuttingDown, defaultModelSaves[runtimeID] == nil else { return false }
        let save = Task {
            defer { defaultModelSaves[runtimeID] = nil }
            return await updateModelPreferences(forRuntime: runtimeID) { $0.defaultModel = model }
        }
        defaultModelSaves[runtimeID] = save
        return await save.value
    }

    @discardableResult public func setFavoriteModel(_ model: RuntimeModel, isFavorite: Bool, forRuntime runtimeID: String) async -> Bool {
        await updateModelPreferences(forRuntime: runtimeID) {
            $0.favorites.removeAll { $0.id == model.id }
            if isFavorite { $0.favorites.append(model) }
        }
    }

    @discardableResult public func setModelVisible(_ model: RuntimeModel, isVisible: Bool, forRuntime runtimeID: String) async -> Bool {
        await updateModelPreferences(forRuntime: runtimeID) {
            if isVisible {
                $0.hiddenModelIDs.remove(model.id)
                $0.hiddenModelReferences?.removeValue(forKey: model.id)
                if $0.hiddenModelReferences?.isEmpty == true { $0.hiddenModelReferences = nil }
            } else {
                $0.hiddenModelIDs.insert(model.id)
                if $0.hiddenModelReferences == nil { $0.hiddenModelReferences = [:] }
                $0.hiddenModelReferences?[model.id] = model
            }
        }
    }

    private func updateModelPreferences(forRuntime runtimeID: String, _ change: @escaping (inout WorkspaceModelPreferences) -> Void) async -> Bool {
        guard acpAgents.contains(where: { $0.id == runtimeID }) else { return false }
        return await saveSnapshot(applying: {
            var byRuntime = $0.modelPreferencesByRuntime ?? [:]
            var preferences = byRuntime[runtimeID] ?? WorkspaceModelPreferences()
            change(&preferences)
            byRuntime[runtimeID] = preferences
            $0.modelPreferencesByRuntime = byRuntime
        })
    }

    public func configurationOptions(for id: UUID, model: RuntimeModel? = nil) async throws -> RuntimeConfigurationOptions {
        if let active = try metadataRuntime(for: id, model: model) {
            return try await active.configurationOptions()
        }
        let runtimeID = try sessionRuntimeID(for: id)
        return try await inspectRuntimeModels(runtimeID, model)
    }

    public func configurationOptions(forRuntime runtimeID: String, model: RuntimeModel? = nil) async throws -> RuntimeConfigurationOptions {
        try await inspectRuntimeModels(runtimeID, model)
    }

    public func thinkingLevels(for id: UUID, model: RuntimeModel) async throws -> [String] {
        if let active = try metadataRuntime(for: id, model: model) {
            return try await active.thinkingLevels()
        }
        let runtimeID = try sessionRuntimeID(for: id)
        return try await inspectRuntimeModels(runtimeID, model).thinkingLevels
    }

    private func metadataRuntime(for id: UUID, model: RuntimeModel?) throws -> SessionController? {
        guard state.sessions.contains(where: { $0.id == id }) else { throw RuntimeFailure(.setup, String(localized: "会话已不可用。", bundle: #bundle)) }
        let directoryMatches = workingDirectory(for: id).map { matchesLaunchConfiguration(id, directory: $0) } ?? false
        if !isOperating(on: id), directoryMatches,
           let active = execution(for: id), active.connection == .connected,
           model == nil || (model?.provider == active.session?.provider && model?.modelID == active.session?.modelID) {
            return active
        }
        return nil
    }
    @discardableResult public func saveSelection(_ selection: RuntimeSelection, name: String? = nil, for id: UUID) async -> Bool {
        guard !isOperating(on: id), state.sessions.contains(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
        presentation(id).executionError = nil
        sessionOperations.insert(id)
        defer { endOperation(id) }
        let saved = await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].pendingSelection = selection
            snapshot.sessions[index].pendingModelName = name
            snapshot.sessions[index].modelSource = .session
        }
        guard saved else { return false }
        let directoryMatches = workingDirectory(for: id).map { matchesLaunchConfiguration(id, directory: $0) } ?? false
        if directoryMatches,
           let active = execution(for: id), active.connection == .connected,
           active.phase == .idle, !active.commandPending, active.queue.isEmpty {
            return await applySelection(selection, to: id)
        }
        return true
    }
    private func matchesSelection(_ selection: RuntimeSelection, session: RuntimeSession?) -> Bool {
        session?.provider == selection.provider && session?.modelID == selection.modelID &&
            (selection.thinking == nil || session?.thinking == selection.thinking)
    }
    private func applySelection(_ selection: RuntimeSelection, to id: UUID) async -> Bool {
        guard let active = execution(for: id), let i = state.sessions.firstIndex(where: { $0.id == id }) else { return false }
        // Keep the request through startup readback and failed attempts.
        state.sessions[i].pendingSelection = selection
        guard await active.configure(selection) else {
            presentation(id).executionError = active.failure?.detail ?? String(localized: "模型配置暂时无法应用，草稿已保留。", bundle: #bundle)
            _ = await flush()
            return false
        }
        guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { return false }
        state.sessions[index].pendingSelection = nil
        state.sessions[index].pendingModelName = nil
        synchronize(id)
        return await flush()
    }
    public func renameSession(_ id: UUID, to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShuttingDown, !title.isEmpty,
              state.sessions.contains(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
        let saved = await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { return }
            snapshot.sessions[index].customTitle = title
        }
        if saved { titleGenerationTasks[id]?.cancel() }
        return saved
    }


    public func runtimeEnvironment(for id: String) -> [String: String] {
        state.runtimeEnvironments?[id] ?? [:]
    }

    @discardableResult public func setRuntimeEnvironment(_ values: [String: String], for id: String) async -> Bool {
        guard !isShuttingDown else { return false }
        let saved = await saveSnapshot { snapshot in
            guard snapshot.preferences.acpAgents?.contains(where: { $0.id == id }) == true
            else { return }
            var environments = snapshot.runtimeEnvironments ?? [:]
            environments[id] = values.isEmpty ? nil : values
            snapshot.runtimeEnvironments = environments.isEmpty ? nil : environments
        }
        return saved && runtimeEnvironment(for: id) == values
    }

    @discardableResult public func removeACPAgent(id: String) async -> Bool {
        guard !isShuttingDown, RuntimeAgentProfile.isACPRuntimeID(id) else { return false }
        return await saveSnapshot { snapshot in
            snapshot.preferences.acpAgents?.removeAll { $0.id == id }
            if snapshot.preferences.acpAgents?.isEmpty == true { snapshot.preferences.acpAgents = nil }
            if snapshot.preferences.defaultRuntimeID == id { snapshot.preferences.defaultRuntimeID = nil }
            snapshot.runtimeEnvironments?.removeValue(forKey: id)
            if snapshot.runtimeEnvironments?.isEmpty == true { snapshot.runtimeEnvironments = nil }
        }
    }

    public func setPreferences(_ preferences: WorkspacePreferences) { state.preferences = preferences; scheduleSave() }
    public func setACPAgents(_ agents: [RuntimeAgentProfile]) {
        var seen = Set<String>()
        let normalized = agents.filter { profile in
            RuntimeAgentProfile.isACPRuntimeID(profile.id) && seen.insert(profile.id).inserted
        }
        state.preferences.acpAgents = normalized.isEmpty ? nil : normalized
        if let configured = state.preferences.defaultRuntimeID,
           !normalized.contains(where: { $0.id == configured && $0.enabled }) {
            state.preferences.defaultRuntimeID = nil
        }
        scheduleSave()
    }
    public func setDefaultRuntimeID(_ id: String) {
        if !acpAgents.contains(where: { $0.id == id && $0.enabled }) {
            state.preferences.defaultRuntimeID = nil
        } else {
            state.preferences.defaultRuntimeID = id
        }
        scheduleSave()
    }
    @discardableResult public func flush() async -> Bool {
        await saveSnapshot()
    }

    /// Apply a staged change to the saved snapshot, then publish it to the live state.
    private func saveSnapshot(applying change: ((inout WorkspaceSnapshot) -> Void)? = nil) async -> Bool {
        guard initialized else { return false }
        if savingSnapshot {
            await withCheckedContinuation { snapshotWaiters.append($0) }
        } else {
            savingSnapshot = true
        }
        defer {
            if snapshotWaiters.isEmpty { savingSnapshot = false }
            else { snapshotWaiters.removeFirst().resume() }
        }
        autosave?.cancel()
        autosave = nil
        for id in dirtyDrafts {
            guard let controller = presentations[id]?.controller,
                  let index = state.sessions.firstIndex(where: { $0.id == id }) else { continue }
            state.sessions[index].draft = controller.draft
            state.sessions[index].draftFiles = controller.draftFiles.isEmpty ? nil : controller.draftFiles
        }
        dirtyDrafts.removeAll()
        state.revision += 1
        var snapshot = state
        change?(&snapshot)
        do {
            try await store.save(snapshot)
            // Other sessions can still change while the store is writing.
            change?(&state)
            storageError = nil
            return true
        } catch {
            storageError = String(localized: "本地保存失败，已阻止新任务。会话状态和草稿仍在内存中，请修复存储后重试保存。", bundle: #bundle)
            return false
        }
    }
    private func scheduleSave() {
        guard initialized else { return }
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.autosave = nil
            _ = await self.flush()
        }
    }
    private func trimHistoryCache(keeping id: UUID) {
        let candidates = state.sessions.sorted { $0.lastViewed > $1.lastViewed }.map(\.id)
        let keep = Set(candidates.prefix(4)).union([id]).union(activeExecutionIDs).union(sessionOperations)
        for (key, presentation) in presentations where !keep.contains(key) && presentation.controller.connection == .disconnected && !presentation.controller.commandPending {
            presentation.controller.showHistory([])
            presentation.setFrozenTranscript([], rows: [], segmentIDs: [])
        }
    }
    private func presentation(_ id: UUID) -> SessionPresentation {
        if let value = presentations[id] { return value }
        let view = SessionPresentation(id: id, clock: clock)
        if let reference = state.sessions.first(where: { $0.id == id }) {
            view.controller.timelineSegmentID = reference.activeSegmentID
            if let handoff = reference.handoff, handoff.delivered { view.activeHandoffMarker = Self.handoffMarker(handoff) }
            view.controller.restoreLocalState(draft: reference.draft, mode: reference.mode, recovered: reference.recovered, files: reference.draftFiles ?? [])
        }
        presentations[id] = view
        view.controller.onDraftEdited = { [weak self, weak controller = view.controller] in
            guard let self, let controller, !self.deletingSessionIDs.contains(id),
                  let i = self.state.sessions.firstIndex(where: { $0.id == id }) else { return }
            self.dirtyDrafts.insert(id)
            let hasText = !controller.draft.isEmpty || !controller.draftFiles.isEmpty
            if self.draftIndicators[id] != hasText { self.draftIndicators[id] = hasText }
            if hasText, self.state.sessions[i].sidebarStatus == .settled {
                self.state.sessions[i].processingStatus = .open
            }
            self.scheduleSave()
            self.scheduleIdleReap(id)
        }
        view.controller.onRuntimeActivityChanged = { [weak self] in self?.scheduleIdleReap(id) }
        view.controller.onControlChanged = { [weak self] in
            guard let self else { return }
            let before = self.state.sessions.first { $0.id == id }?.recovered
            self.synchronize(id)
            if self.presentations[id]?.controller.connection == .disconnected, !self.sessionOperations.contains(id) {
                self.activeExecutionIDs.remove(id)
                self.executionLaunches.removeValue(forKey: id)
            }
            self.scheduleIdleReap(id)
            if before != self.state.sessions.first(where: { $0.id == id })?.recovered {
                Task { _ = await self.flush() }
            } else { self.scheduleSave() }
        }
        view.controller.onApprovalRequested = { [weak self, weak controller = view.controller] request in
            guard let controller else { return }
            self?.onLiveApprovalRequested?(id, request, controller)
        }
        view.controller.onTurnFinished = { [weak self] turn in
            guard let self, let i = self.state.sessions.firstIndex(where: { $0.id == id }) else { return }
            self.presentations[id]?.handoffPreviewToken = nil
            var record = RecordedTurnRecord(
                id: turn.id,
                anchorAssistantTimestampMs: turn.anchorAssistantTimestampMs,
                endAssistantTimestampMs: turn.endAssistantTimestampMs,
                anchorToolCallID: turn.anchorToolCallID,
                anchorUserTimestampMs: turn.anchorUserTimestampMs,
                startedAt: turn.startedAt,
                endedAt: turn.endedAt,
                durationSeconds: turn.durationSeconds,
                status: turn.status,
                fileChanges: turn.fileChanges
            )
            record.model = turn.model
            record.modelChange = turn.modelChange
            record.modelSubmissionID = turn.modelSubmissionID
            var turns = self.state.sessions[i].recordedTurns ?? []
            let existing = turns.firstIndex(where: { $0.id == record.id })
            if let existing { turns[existing] = record }
            else {
                turns.append(record)
                if record.status == .completed {
                    self.state.sessions[i].unreadCompletionTurnID = record.id
                }
            }
            self.state.sessions[i].recordedTurns = turns
            if let path = self.workingDirectory(for: id) {
                self.completedTurnsByDirectory[path, default: 0] += 1
            }
            self.synchronize(id)
            self.scheduleSave()
            if existing == nil { self.onLiveTurnFinished?(id, turn) }
        }
        view.controller.onUserMessageTimestamp = { [weak self] promptID, timestampMs in
            guard let self, let promptID, let i = self.state.sessions.firstIndex(where: { $0.id == id }) else { return }
            var messages = self.state.sessions[i].recordedMessages ?? []
            // If acknowledgement is still pending, resolveSubmission reads the timestamp from this input's row.
            guard let j = messages.firstIndex(where: { $0.id == promptID }) else { return }
            messages[j].messageTimestampMs = timestampMs
            self.state.sessions[i].recordedMessages = messages
            self.scheduleSave()
        }
        view.controller.prepareSubmission = { [weak self, weak controller = view.controller] prompt in
            guard let self, let controller, let i = self.state.sessions.firstIndex(where: { $0.id == id }), self.storageError == nil else { throw RuntimeFailure(.setup, String(localized: "工作台不可写。", bundle: #bundle)) }
            let submittedAt = self.clock.now()
            let originalDirectory = self.state.sessions[i].boundWorkingDirectory
            let originalHandoff = self.state.sessions[i].handoff
            let originalCleanupID = self.state.sessions[i].handoffCleanupID
            let originalTitleSubmissionID = self.state.sessions[i].automaticTitleSubmissionID
            let launchCleanupID = self.executionLaunches[id]?.handoffCleanupID
            self.state.sessions[i].boundWorkingDirectory = self.workingDirectory(for: id)
            if self.state.sessions[i].handoff?.delivered == false {
                self.state.sessions[i].handoff?.firstSubmissionID = prompt.id
                self.state.sessions[i].handoff?.lastSubmissionRejected = false
                if let launchCleanupID { self.state.sessions[i].handoffCleanupID = launchCleanupID }
            }
            self.state.sessions[i].submissions.append(.init(prompt, sentAt: submittedAt))
            if self.state.sessions[i].awaitsAutomaticTitle == true && originalTitleSubmissionID == nil {
                self.state.sessions[i].automaticTitleSubmissionID = prompt.id
            }
            self.synchronize(id)
            if controller.matchesDraft(prompt) {
                self.state.sessions[i].draft = ""
                self.state.sessions[i].draftFiles = nil
            }
            guard await self.flush() else {
                if let index = self.state.sessions.firstIndex(where: { $0.id == id }) {
                    self.state.sessions[index].submissions.removeAll { $0.id == prompt.id }
                    self.state.sessions[index].boundWorkingDirectory = originalDirectory
                    self.state.sessions[index].handoff = originalHandoff
                    self.state.sessions[index].automaticTitleSubmissionID = originalTitleSubmissionID
                    if self.state.sessions[index].handoffCleanupID == launchCleanupID {
                        self.state.sessions[index].handoffCleanupID = originalCleanupID
                    }
                    self.synchronize(id)
                }
                throw RuntimeFailure(.setup, String(localized: "提交状态未保存。", bundle: #bundle))
            }
        }
        view.controller.resolveSubmission = { [weak self] promptID, delivery in
            guard let self, let i = self.state.sessions.firstIndex(where: { $0.id == id }), let j = self.state.sessions[i].submissions.firstIndex(where: { $0.id == promptID }) else { return }
            let firstHandoff = self.state.sessions[i].handoff.flatMap { $0.firstSubmissionID == promptID ? $0 : nil }
            if firstHandoff?.delivered == true { return }
            self.state.sessions[i].submissions[j].delivery = delivery
            self.state.sessions[i].submissions[j].acknowledged = [.accepted, .queued, .handled].contains(delivery)
            self.state.sessions[i].submissions[j].needsReview = delivery == .unknown
            if firstHandoff != nil {
                switch delivery {
                case .accepted, .queued, .handled:
                    let targetModel = self.state.sessions[i].recordedTurns?.first?.model
                        ?? SessionTurnModel(self.presentations[id]?.controller.session)
                    self.state.sessions[i].handoff?.delivered = true
                    self.state.sessions[i].handoff?.targetModel = targetModel
                    if let handoff = self.state.sessions[i].handoff { self.presentations[id]?.activeHandoffMarker = Self.handoffMarker(handoff) }
                case .rejected, .recovered:
                    self.state.sessions[i].discardUnacceptedHandoffSubmission(promptID)
                    let reference = self.state.sessions[i]
                    if reference.recordedMessages?.isEmpty != false && (!reference.isACPRuntime || reference.resumableSession == true) {
                        self.state.sessions[i].runtimeSessionID = nil
                    }
                default: break
                }
            }
            if delivery == .rejected, self.state.sessions[i].file == nil, self.state.sessions[i].recordedMessages?.isEmpty != false,
               self.state.sessions[i].handoff == nil, self.state.sessions[i].submissions.allSatisfy({ $0.delivery == .rejected }) {
                self.state.sessions[i].boundWorkingDirectory = nil
            }
            if self.state.sessions[i].submissions[j].acknowledged || delivery == .unknown {
                self.state.sessions[i].processingStatus = .open
                self.state.sessions[i].sidebarActivity = .init()
                let sub = self.state.sessions[i].submissions[j]
                let itemTs = self.presentations[id]?.controller.transcript.first(where: { $0.id == "user:\(promptID)" })?.messageTimestampMs
                var messages = self.state.sessions[i].recordedMessages ?? []
                if !messages.contains(where: { $0.id == promptID }) {
                    messages.append(.init(id: promptID, text: sub.text, files: sub.files, sentAt: sub.sentAt,
                                          messageTimestampMs: itemTs, handoffContext: firstHandoff?.context))
                    self.state.sessions[i].recordedMessages = messages
                }
            }
            self.synchronize(id); _ = await self.flush()
        }
        view.controller.onPromptConfirmed = { [weak self] prompt in
            guard let self, let index = self.state.sessions.firstIndex(where: { $0.id == id }) else { return }
            self.considerSessionTitle(for: index, prompt: prompt)
        }
        return view
    }

    private func considerSessionTitle(for index: Int, prompt: UserPrompt) {
        let session = state.sessions[index]
        guard session.awaitsAutomaticTitle == true,
              session.automaticTitleSubmissionID == prompt.id else { return }
        state.sessions[index].awaitsAutomaticTitle = nil

        let settings = sessionTitleSettings
        let id = session.id
        guard titleGenerationIndex(for: id, settings: settings) != nil,
              !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.mode != .disabled, let generateSessionTitle else {
            scheduleSave()
            return
        }
        titleGenerationTasks[id] = Task { [weak self] in
            defer { self?.titleGenerationTasks[id] = nil }
            guard !Task.isCancelled, await self?.flush() == true,
                  !Task.isCancelled, self?.titleGenerationIndex(for: id, settings: settings) != nil,
                  let result = await generateSessionTitle(settings, prompt.text),
                  !Task.isCancelled, let self, let index = self.titleGenerationIndex(for: id, settings: settings)
            else { return }
            let title = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 48, !title.contains(where: \.isNewline),
                  !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
            self.state.sessions[index].generatedTitle = title
            self.scheduleSave()
        }
    }

    private func titleGenerationIndex(for id: UUID, settings: SessionTitleSettings) -> Int? {
        guard !isShuttingDown, sessionTitleSettings == settings else { return nil }
        return state.sessions.firstIndex {
            $0.id == id && $0.archivedAt == nil && $0.remoteHistoryDeleted != true
                && $0.customTitle == nil && $0.handoff == nil
        }
    }

    private func synchronize(_ id: UUID) {
        guard let view = presentations[id], let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        let controller = view.controller
        dirtyDrafts.remove(id)
        state.sessions[i].draft = controller.draft; state.sessions[i].mode = controller.mode; state.sessions[i].recovered = controller.recoveredDrafts
        state.sessions[i].draftFiles = controller.draftFiles.isEmpty ? nil : controller.draftFiles
        let wasExecuting = state.sessions[i].wasExecuting
        let executing = controller.phase.isActive && controller.connection != .disconnected
        state.sessions[i].wasExecuting = executing
        if wasExecuting && !executing { state.sessions[i].sidebarActivity = .init() }
        if executing || !controller.recoveredDrafts.isEmpty, state.sessions[i].sidebarStatus == .settled {
            state.sessions[i].processingStatus = .open
        }
        if activeExecutionIDs.contains(id), let runtime = controller.session {
            let hasActiveSubmissions = state.sessions[i].submissions.contains { $0.delivery != .rejected }
            let hasTranscript = controller.transcript.contains { $0.kind != .user || $0.delivery != .rejected }
            let hasRecordedHistory = state.sessions[i].recordedMessages?.isEmpty == false
            let hasActivity = hasActiveSubmissions || hasTranscript || hasRecordedHistory
            let expected = state.sessions[i].runtimeSessionID
            if expected == nil || expected == runtime.id {
                if hasActivity || expected != nil {
                    state.sessions[i].runtimeSessionID = runtime.id
                    state.sessions[i].file = nil
                    state.sessions[i].resumableSession = runtime.resumable
                    state.sessions[i].canDeleteRemoteHistory = runtime.capabilities.contains(.sessionDelete)
                } else {
                    state.sessions[i].runtimeSessionID = nil
                    state.sessions[i].file = nil
                    state.sessions[i].resumableSession = nil
                }
            }
            if let modeID = runtime.modeID {
                state.sessions[i].runtimeModeID = modeID
            }
            if !controller.showingCachedHistory && !controller.transcript.isEmpty {
                state.sessions[i].cachedHistoryItems = Self.cachedHistorySnapshot(from: controller.transcript)
            }
            if let provider = runtime.provider, let model = runtime.modelID {
                state.sessions[i].selection = .init(provider: provider, modelID: model, thinking: runtime.thinking)
                state.sessions[i].modelName = runtime.model
            }
        }
        if state.sessions[i].title == "新会话", let first = controller.transcript.first(where: { $0.kind == .user }) {
            let text = first.submission?.text ?? first.text
            let title = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            if let title { state.sessions[i].title = String(title.prefix(48)) }
            else if let file = first.submission?.files.first {
                let filename = String(file.lastPathComponent.prefix(45))
                state.sessions[i].title = "查看 " + filename
                state.sessions[i].attachmentTitleFilename = filename
            }
        }
        let final = controller.connection == .connected && controller.phase == .idle && !controller.commandPending
        for j in state.sessions[i].submissions.indices {
            let submission = state.sessions[i].submissions[j]
            if let row = controller.transcript.first(where: { $0.id == "user:\(submission.id)" }), row.delivery != .pending {
                state.sessions[i].submissions[j].delivery = row.delivery
                if row.delivery == .unknown && submission.delivery != .unknown { state.sessions[i].submissions[j].needsReview = true }
                if row.delivery == .rejected {
                    state.sessions[i].recordedMessages?.removeAll { $0.id == submission.id }
                    if state.sessions[i].awaitsAutomaticTitle == true,
                       state.sessions[i].automaticTitleSubmissionID == submission.id {
                        state.sessions[i].automaticTitleSubmissionID = nil
                    }
                }
            }
        }
        let pendingHandoffID = state.sessions[i].handoff.flatMap { $0.delivered ? nil : $0.firstSubmissionID }
        state.sessions[i].submissions.removeAll { submission in
            if pendingHandoffID == submission.id { return false }
            return [.handled, .rejected, .recovered].contains(submission.delivery) || (final && controller.queue.isEmpty && [.accepted, .queued].contains(submission.delivery) && !submission.needsReview)
        }
        if controller.connection == .disconnected, state.sessions[i].isACPRuntime {
            if let cleanupID = executionLaunches[id]?.handoffCleanupID, state.sessions[i].handoffCleanupID == cleanupID {
                state.sessions[i].handoffCleanupID = nil
            }
            if let closedSessionID = controller.session?.id, closedSessionID == state.sessions[i].runtimeSessionID {
                state.sessions[i].releaseUnacceptedACPBinding()
            }
            view.executionIssue = Self.acpResumeIssue(for: state.sessions[i])
        }
    }

    private static func cachedHistorySnapshot(from transcript: [TranscriptItem]) -> [CachedTranscriptItem] {
        let items = transcript.compactMap { item -> CachedTranscriptItem? in
            if item.kind == .assistant && !item.hasVisibleText { return nil }
            if item.expiredInteraction != nil { return nil }
            if item.kind == .user && item.delivery == .rejected { return nil }
            let kind: HistoryItemKind
            switch item.kind {
            case .user: kind = .user
            case .assistant: kind = .assistant
            case .tool: kind = .tool
            case .notice: kind = .notice
            }
            return CachedTranscriptItem(
                id: item.id,
                kind: kind,
                text: item.kind == .user ? item.editableText : item.text,
                tool: item.tool,
                sentAt: item.sentAt,
                endedAt: (item.kind == .assistant || item.kind == .tool) ? item.turn?.endedAt : nil,
                files: item.kind == .user && !item.attachedFiles.isEmpty ? item.attachedFiles : nil,
                submissionID: item.kind == .user ? item.submissionID : nil
            )
        }
        if items.count > CachedTranscriptItem.maximumItemCount {
            return Array(items.suffix(CachedTranscriptItem.maximumItemCount))
        }
        return items
    }
}
