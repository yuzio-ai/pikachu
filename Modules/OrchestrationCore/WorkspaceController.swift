import Foundation
import Observation
import AgentRuntimeCore

public struct ProjectOperationFeedback: Sendable {
    public let message: String
    public let warning: Bool
}

@MainActor @Observable public final class SessionPresentation: Identifiable {
    public let id: UUID
    public let controller: SessionController
    public var history: RuntimeHistory?
    public var loading = false
    public var loadError: String?
    public var executionIssue: String?
    public var executionError: String?
    @ObservationIgnored var readGeneration = UUID()
    init(id: UUID, clock: any RuntimeClock = SystemRuntimeClock()) {
        self.id = id
        self.controller = SessionController(clock: clock)
    }
}

public struct WorkspaceRuntimeLaunch: Sendable, Equatable {
    public let workingDirectory: String
    public let canonicalDirectory: String
    public let approveProjectConfiguration: Bool

    public init(workingDirectory: String, canonicalDirectory: String, approveProjectConfiguration: Bool) {
        self.workingDirectory = workingDirectory
        self.canonicalDirectory = canonicalDirectory
        self.approveProjectConfiguration = approveProjectConfiguration
    }
}

@MainActor @Observable public final class WorkspaceController {
    public private(set) var state = WorkspaceSnapshot()
    public private(set) var initialized = false
    public private(set) var isShuttingDown = false
    private var sessionOperations: Set<UUID> = []
    public private(set) var refreshingHistoryIndex = false
    private var savingProject = false
    private var savingProjectConfigDirectories: Set<String> = []
    private var executionPolicies: [UUID: AgentExecutionPolicy] = [:]
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
    public func focusInput() { inputFocusRequest += 1 }
    @ObservationIgnored private let store: any WorkspaceStore
    @ObservationIgnored private let reader: any RuntimeHistoryReader
    @ObservationIgnored private let clock: any RuntimeClock
    @ObservationIgnored private let runtimeFactory: @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime
    @ObservationIgnored private let inspectModels: @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var dirtyDrafts: Set<UUID> = []
    @ObservationIgnored private var savingSnapshot = false
    @ObservationIgnored private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let validateWorktree: @MainActor (String, String) async -> Bool
    private var draftIndicators: [UUID: Bool] = [:]
    public var executionIDs: [UUID] { state.sessions.compactMap { executionPolicies[$0.id] == nil ? nil : $0.id } }
    public var hasPendingExecutionControls: Bool {
        !sessionOperations.isEmpty || executionIDs.contains { execution(for: $0)?.commandPending == true }
    }
    public func isOperating(on id: UUID) -> Bool { isShuttingDown || sessionOperations.contains(id) }
    public func execution(for id: UUID) -> SessionController? {
        executionPolicies[id] == nil ? nil : presentations[id]?.controller
    }
    public func runningPolicy(for id: UUID) -> AgentExecutionPolicy? { executionPolicies[id] }
    public func workingDirectory(for id: UUID) -> String? {
        guard let reference = state.sessions.first(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == reference.projectID }) else { return nil }
        return reference.workingDirectory(in: project)
    }
    public var selected: SessionReference? { state.sessions.first { $0.id == state.selectedSessionID } }
    public var selectedProject: ProjectRecord? { selected.flatMap { item in state.projects.first { $0.id == item.projectID } } }
    public var canManageProjects: Bool { initialized && !isShuttingDown && !savingProject && !refreshingHistoryIndex && storageError == nil }
    public func hasDraft(_ session: SessionReference) -> Bool {
        (draftIndicators[session.id] ?? (!session.draft.isEmpty || session.draftFiles?.isEmpty == false)) || !session.recovered.isEmpty
    }
    public convenience init(store: any WorkspaceStore, reader: any RuntimeHistoryReader,
                            clock: any RuntimeClock = SystemRuntimeClock(),
                            validateWorktree: @escaping @MainActor (String, String) async -> Bool = { _, _ in true },
                            inspectModels: @escaping @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions = { _ in
                                throw RuntimeFailure(.setup, String(localized: "未配置模型目录。", bundle: #bundle))
                            }, factory: @escaping @MainActor (ProjectRecord, SessionReference) -> any AgentRuntime) {
        self.init(store: store, reader: reader, clock: clock,
                  validateWorktree: validateWorktree, inspectModels: inspectModels) { project, reference, _ in
            factory(project, reference)
        }
    }
    public init(store: any WorkspaceStore, reader: any RuntimeHistoryReader,
                clock: any RuntimeClock = SystemRuntimeClock(),
                validateWorktree: @escaping @MainActor (String, String) async -> Bool = { _, _ in true },
                inspectModels: @escaping @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions = { _ in
                    throw RuntimeFailure(.setup, String(localized: "未配置模型目录。", bundle: #bundle))
                }, runtimeFactory: @escaping @MainActor (ProjectRecord, SessionReference, WorkspaceRuntimeLaunch) -> any AgentRuntime) {
        self.store = store; self.reader = reader; self.clock = clock; self.runtimeFactory = runtimeFactory
        self.inspectModels = inspectModels; self.validateWorktree = validateWorktree
    }
    public func start() async {
        guard !initialized else { return }
        do {
            state = try await store.load()
            guard state.version == 1, Set(state.projects.map(\.id)).count == state.projects.count,
                  Set(state.sessions.map(\.id)).count == state.sessions.count,
                  state.sessions.allSatisfy({ s in state.projects.contains { $0.id == s.projectID } }) else { throw RuntimeFailure(.setup, String(localized: "本地索引不一致。", bundle: #bundle)) }
            let runtimeKeys = state.sessions.compactMap { s in s.runtimeSessionID.map { s.projectID.uuidString + ":" + s.runtimeID + ":" + $0 } }
            guard Set(runtimeKeys).count == runtimeKeys.count else { throw RuntimeFailure(.setup, String(localized: "本地会话绑定重复。", bundle: #bundle)) }
            for i in state.sessions.indices {
                initializeSidebarMetadata(at: i)
                // Extension commands may be handled without materializing a Pi
                // session file. Keep their journal, but never resume an allocation
                // that has no durable history. Confirmed missing history stays blocked.
                if state.sessions[i].historyConfirmed != true,
                   state.sessions[i].file.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                    state.sessions[i].runtimeSessionID = nil; state.sessions[i].file = nil
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
            initialized = true
            if let id = state.selectedSessionID, state.sessions.contains(where: { $0.id == id }) { await select(id) }
            else { state.selectedSessionID = nil }
            _ = await flush()
        } catch { storageError = String(localized: "本地工作台数据无法读取，已阻止执行；没有重建或覆盖原数据。", bundle: #bundle) }
    }
    @discardableResult public func addProject(_ path: URL, createInitialSession: Bool = true) async -> UUID? {
        guard canManageProjects else { return nil }
        let location = path.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location, isDirectory: &directory), directory.boolValue else { error = String(localized: "项目目录不存在。", bundle: #bundle); return nil }
        if let existing = state.projects.first(where: { $0.path == location }) {
            if createInitialSession, let session = state.sessions.first(where: { $0.projectID == existing.id }) {
                await select(session.id)
            }
            return existing.id
        }
        let project = ProjectRecord(path: location); state.projects.append(project)
        savingProject = true
        defer { savingProject = false }
        if createInitialSession { await select(appendNewSession(to: project.id)) }
        if await flush() { await refreshHistoryIndex(projectID: project.id, refreshViewed: false) }
        return project.id
    }
    @discardableResult public func relocateProject(_ projectID: UUID, to path: URL) async -> ProjectOperationFeedback? {
        guard canManageProjects, let i = state.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        error = nil
        if state.sessions.contains(where: { $0.projectID == projectID && (executionPolicies[$0.id] != nil || sessionOperations.contains($0.id)) }) {
            let message = String(localized: "请先清理并断开该项目的执行会话，再重新定位。", bundle: #bundle)
            error = message
            return .init(message: message, warning: true)
        }
        let projectDirectories = Set(
            [Self.canonicalPath(state.projects[i].path)] +
            state.sessions.filter { $0.projectID == projectID }.map { Self.canonicalPath($0.workingDirectory(in: state.projects[i])) }
        )
        if !savingProjectConfigDirectories.isDisjoint(with: projectDirectories) {
            let message = String(localized: "请先等待项目配置设置保存完成，再重新定位。", bundle: #bundle)
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
        if let feedback = await refreshHistoryIndex(projectID: projectID, refreshViewed: false), feedback.warning {
            return feedback
        }
        return .init(message: String(localized: "工作目录已更新。", bundle: #bundle), warning: false)
    }
    @discardableResult public func createSession(in projectID: UUID) async -> UUID? {
        guard canManageProjects, state.projects.contains(where: { $0.id == projectID }) else { return nil }
        let id = appendNewSession(to: projectID)
        await select(id); _ = await flush()
        return id
    }
    private func appendNewSession(to projectID: UUID) -> UUID {
        let reference = makeNewSession(in: projectID)
        state.sessions.append(reference)
        return reference.id
    }

    private func makeNewSession(in projectID: UUID) -> SessionReference {
        var reference = SessionReference(projectID: projectID)
        if let model = state.modelPreferences?.defaultModel {
            reference.pendingSelection = .init(provider: model.provider, modelID: model.modelID)
            reference.pendingModelName = model.name
        }
        reference.agentMode = .interactive
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
    private func initializeSidebarMetadata(at index: Int) {
        let session = state.sessions[index]
        if session.processingStatus == nil {
            let hasPendingDelivery = session.submissions.contains { $0.needsReview || [.pending, .accepted, .queued, .unknown].contains($0.delivery) }
            let hasHistory = session.historyConfirmed == true && session.file.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true
            state.sessions[index].processingStatus = hasHistory && !session.wasExecuting && !hasDraft(session) && !hasPendingDelivery ? .settled : .open
        }
        if session.sidebarActivity == nil {
            state.sessions[index].sidebarActivity = .init(date: session.lastViewed, isEstimate: true)
        }
    }
    public func select(_ id: UUID) async {
        guard initialized, let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        if state.selectedSessionID != id { usageExpanded = false }
        state.selectedSessionID = id; state.sessions[i].lastViewed = Date()
        if let p = state.projects.firstIndex(where: { $0.id == state.sessions[i].projectID }) { state.projects[p].lastViewed = Date() }
        viewed = presentation(id); scheduleSave()
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
        guard let reference = state.sessions.first(where: { $0.id == id }) else { return }
        let view = presentation(id)
        guard reference.runtimeID == "pi" else { view.loadError = String(localized: "此历史会话使用的运行时尚未接入，原记录已保留。", bundle: #bundle); return }
        if view.controller.connection != .disconnected { return }
        guard let file = reference.file else { view.loadError = nil; view.executionIssue = nil; return }
        let generation = UUID(); view.readGeneration = generation; view.loading = true; view.loadError = nil
        defer { if view.readGeneration == generation { view.loading = false } }
        do {
            let history = try await reader.read(file)
            guard view.readGeneration == generation, view.controller.connection == .disconnected,
                  let index = state.sessions.firstIndex(where: { $0.id == id && $0.file == file }) else { return }
            guard reference.runtimeSessionID == history.sessionID else { throw RuntimeFailure(.protocolError, String(localized: "会话标识不匹配。", bundle: #bundle)) }
            view.history = history
            view.controller.showHistory(
                history.items,
                usage: history.usage,
                turns: history.turns,
                recordedTurns: reference.recordedTurns ?? [],
                recordedMessages: reference.recordedMessages ?? []
            )
            var updated = state.sessions[index]
            updateHistoryMetadata(RuntimeHistorySummary(history), in: &updated)
            if updated != state.sessions[index] { state.sessions[index] = updated; scheduleSave() }
            let historyLocation = Self.canonicalPath(history.cwd)
            let actualLocation = workingDirectory(for: id).map(Self.canonicalPath)
            let projectLocation = state.projects.first { $0.id == updated.projectID }.map { Self.canonicalPath($0.path) }
            let projectMoved = updated.worktreePath == nil && actualLocation != projectLocation
            view.executionIssue = !projectMoved && actualLocation == historyLocation ? nil :
                String(localized: "历史工作目录与当前位置不同。旧会话可只读查看；请在当前位置新建会话。", bundle: #bundle)
        } catch {
            if view.readGeneration == generation {
                view.loadError = ((error as? RuntimeFailure)?.detail ?? String(localized: "历史读取失败，未修改源文件。", bundle: #bundle))
                    + (view.history == nil ? "" : String(localized: " 下方保留上次可读内容，可能已过期。", bundle: #bundle))
            }
        }
    }
    @discardableResult public func discover(_ projectID: UUID) async -> ProjectOperationFeedback? {
        guard canManageProjects, state.projects.contains(where: { $0.id == projectID }) else { return nil }
        return await refreshHistoryIndex(projectID: projectID, refreshViewed: false)
    }
    public func refreshWorkspaceHistory() async {
        guard canManageProjects, !state.projects.isEmpty else { return }
        await refreshHistoryIndex(projectID: nil, refreshViewed: true)
    }
    private struct HistoryBinding: Hashable {
        let projectID: UUID
        let sessionID: String
    }
    @discardableResult private func refreshHistoryIndex(projectID: UUID?, refreshViewed: Bool) async -> ProjectOperationFeedback? {
        guard initialized, !refreshingHistoryIndex, storageError == nil else { return nil }
        refreshingHistoryIndex = true
        defer { refreshingHistoryIndex = false }
        let projects = state.projects
        let scope = Set(projects.lazy.filter { projectID == nil || $0.id == projectID }.map(\.id))
        var pathsByProject = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, [$0.path] + $0.previousPaths) })
        for session in state.sessions {
            if let path = session.worktreePath { pathsByProject[session.projectID, default: []].append(path) }
        }
        let locations = scope.flatMap { pathsByProject[$0] ?? [] }
        error = nil
        do {
            let found = try await reader.discoverSummaries(locations: Array(Set(locations)).sorted())
            var issues = found.issues
            var ownersByPath: [String: Set<UUID>] = [:]
            for project in projects {
                for path in pathsByProject[project.id] ?? [] {
                    let location = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                    ownersByPath[location, default: []].insert(project.id)
                }
            }
            var indexed: [HistoryBinding: Int] = [:]
            for (index, session) in state.sessions.enumerated() where session.runtimeID == "pi" {
                if let id = session.runtimeSessionID { indexed[.init(projectID: session.projectID, sessionID: id)] = index }
            }
            var foundByBinding: [HistoryBinding: [RuntimeHistorySummary]] = [:]
            var ambiguous = Set<HistoryBinding>()
            for history in found.sessions {
                let location = URL(fileURLWithPath: history.cwd).standardizedFileURL.resolvingSymlinksInPath().path
                let owners = ownersByPath[location] ?? []
                let candidates = owners.map { HistoryBinding(projectID: $0, sessionID: history.sessionID) }
                let matching = candidates.filter { key in
                    indexed[key].map { state.sessions[$0].file?.standardizedFileURL == history.file.standardizedFileURL } == true
                }
                let binding = candidates.count == 1 ? candidates.first : (matching.count == 1 ? matching.first : nil)
                guard let binding else {
                    if owners.count > 1 {
                        issues.append(String(localized: "部分会话的工作目录对应多个项目，已保留现有绑定。", bundle: #bundle))
                        ambiguous.formUnion(candidates)
                    }
                    continue
                }
                if scope.contains(binding.projectID) { foundByBinding[binding, default: []].append(history) }
            }
            for (binding, group) in foundByBinding where !ambiguous.contains(binding) {
                guard group.count == 1, let history = group.first else { issues.append(String(localized: "同一会话 ID 对应多个文件，请保留唯一来源后刷新。", bundle: #bundle)); continue }
                if let i = indexed[binding] {
                    let id = state.sessions[i].id
                    guard !sessionOperations.contains(id), executionPolicies[id] == nil else { continue }
                    var reference = state.sessions[i]
                    updateHistoryMetadata(history, in: &reference)
                    if state.sessions[i] != reference { state.sessions[i] = reference }
                } else {
                    var reference = SessionReference(projectID: binding.projectID, title: history.title)
                    reference.runtimeSessionID = history.sessionID
                    if let project = projects.first(where: { $0.id == binding.projectID }),
                       !([project.path] + project.previousPaths).map(Self.canonicalPath).contains(Self.canonicalPath(history.cwd)) {
                        reference.worktreePath = Self.canonicalPath(history.cwd)
                    }
                    reference.processingStatus = history.needsAttention ? .open : .settled
                    updateHistoryMetadata(history, in: &reference)
                    if reference.sidebarActivity == nil {
                        reference.sidebarActivity = .init(date: reference.lastViewed, isEstimate: true)
                    }
                    state.sessions.append(reference)
                }
            }
            let warning: String?
            if issues.isEmpty {
                warning = nil
            } else {
                var seen = Set<String>()
                let message = issues.filter { seen.insert($0).inserted }.prefix(3).joined(separator: "\n")
                warning = message
                notice = message
            }
            if refreshViewed, let id = state.selectedSessionID { await refreshHistory(id) }
            guard await flush() else { return storageError.map { .init(message: $0, warning: true) } }
            if let warning { return .init(message: warning, warning: true) }
            let message = String(localized: "会话列表已刷新。", bundle: #bundle)
            if refreshViewed { notice = message }
            return .init(message: message, warning: false)
        } catch {
            let message = String(localized: "会话发现失败，现有索引和源历史保持不变。", bundle: #bundle)
            self.error = message
            return .init(message: message, warning: true)
        }
    }
    private func updateHistoryMetadata(_ history: RuntimeHistorySummary, in reference: inout SessionReference) {
        reference.file = history.file
        reference.historyConfirmed = true
        reference.historicalModel = history.model
        if let date = history.activityAt, reference.activity.isEstimate || date > reference.activity.date {
            reference.sidebarActivity = .init(date: date)
        }
    }
    public nonisolated static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func isProjectPiConfigTrusted(for directory: String) -> Bool {
        let canonical = Self.canonicalPath(directory)
        return state.trustedPiConfigDirectories?.contains(where: { Self.canonicalPath($0) == canonical }) == true
    }

    public func isSavingProjectPiConfig(for directory: String) -> Bool {
        savingProjectConfigDirectories.contains(Self.canonicalPath(directory))
    }

    public func canChangeProjectPiConfig(for directory: String) -> Bool {
        canChangeProjectPiConfig(forCanonicalDirectory: Self.canonicalPath(directory), ignoringSaving: false)
    }

    private func canChangeProjectPiConfig(forCanonicalDirectory canonical: String, ignoringSaving: Bool) -> Bool {
        guard initialized, !isShuttingDown, storageError == nil else { return false }
        if !ignoringSaving, savingProjectConfigDirectories.contains(canonical) { return false }
        for session in state.sessions {
            let touchesDirectory = executionLaunches[session.id]?.canonicalDirectory == canonical ||
                workingDirectory(for: session.id).map(Self.canonicalPath) == canonical
            guard touchesDirectory else { continue }
            if sessionOperations.contains(session.id) { return false }
            if let active = execution(for: session.id), !isIdle(active) { return false }
        }
        return true
    }

    @discardableResult public func setProjectPiConfigTrusted(
        _ trusted: Bool,
        forProject projectID: UUID,
        directory: String
    ) async -> ProjectOperationFeedback? {
        let canonical = Self.canonicalPath(directory)
        guard canChangeProjectPiConfig(forCanonicalDirectory: canonical, ignoringSaving: false),
              state.projects.contains(where: { $0.id == projectID }) else {
            return .init(message: storageError ?? String(localized: "当前无法修改该目录的项目配置设置。", bundle: #bundle), warning: true)
        }
        savingProjectConfigDirectories.insert(canonical)
        defer { savingProjectConfigDirectories.remove(canonical) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue,
              let project = state.projects.first(where: { $0.id == projectID }) else {
            return .init(message: String(localized: "工作目录不可用或不属于当前项目。", bundle: #bundle), warning: true)
        }
        let isRoot = canonical == Self.canonicalPath(project.path)
        if !isRoot, !(await validateWorktree(project.path, canonical)) {
            return .init(message: String(localized: "工作目录不可用或不属于当前项目。", bundle: #bundle), warning: true)
        }
        guard !isShuttingDown, storageError == nil,
              canChangeProjectPiConfig(forCanonicalDirectory: canonical, ignoringSaving: true),
              let verifiedProject = state.projects.first(where: { $0.id == projectID }),
              canonical == Self.canonicalPath(verifiedProject.path) || !isRoot else {
            return .init(message: storageError ?? String(localized: "当前无法修改该目录的项目配置设置。", bundle: #bundle), warning: true)
        }

        let saved = await saveSnapshot { snapshot in
            var directories = Set((snapshot.trustedPiConfigDirectories ?? []).map(Self.canonicalPath))
            if trusted {
                directories.insert(canonical)
            } else {
                directories.remove(canonical)
            }
            snapshot.trustedPiConfigDirectories = directories.isEmpty ? nil : directories
        }
        guard saved else {
            return storageError.map { .init(message: $0, warning: true) }
        }
        return nil
    }

    @discardableResult public func chooseWorkingDirectory(worktree: String?, for id: UUID) async -> Bool {
        guard !isOperating(on: id), storageError == nil,
              let i = state.sessions.firstIndex(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == state.sessions[i].projectID }) else { return false }
        let source = presentation(id)
        source.executionError = nil
        let path = worktree.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let target = path ?? project.path
        if isSavingProjectPiConfig(for: target) || isSavingProjectPiConfig(for: state.sessions[i].workingDirectory(in: project)) {
            source.executionError = String(localized: "正在保存该目录的项目配置设置，请稍后再试。", bundle: #bundle)
            return false
        }
        sessionOperations.insert(id)
        defer { sessionOperations.remove(id) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else {
            source.executionError = String(localized: "工作目录不可用：\(target)", bundle: #bundle)
            return false
        }
        if let path, !(await validateWorktree(project.path, path)) {
            source.executionError = String(localized: "工作树不可用：\(path)", bundle: #bundle)
            return false
        }
        guard !isShuttingDown else { return false }

        let reference = state.sessions[i]
        if reference.worktreePath == path,
           URL(fileURLWithPath: reference.workingDirectory(in: project)).standardizedFileURL.path ==
            URL(fileURLWithPath: target).standardizedFileURL.path { return true }
        if reference.hasBoundWorkingDirectory {
            var newSession = makeNewSession(in: project.id)
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
        guard initialized, !isOperating(on: id), storageError == nil else { return false }
        if let directory = workingDirectory(for: id), isSavingProjectPiConfig(for: directory) {
            presentation(id).executionError = String(localized: "正在保存该目录的项目配置设置，请稍后再试。", bundle: #bundle)
            return false
        }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        return await openExecution(id)
    }

    private func endOperation(_ id: UUID) {
        if presentations[id]?.controller.connection == .disconnected {
            executionPolicies.removeValue(forKey: id)
            executionLaunches.removeValue(forKey: id)
        }
        sessionOperations.remove(id)
    }

    private func matchesLaunchConfiguration(_ id: UUID, directory: String) -> Bool {
        guard let launch = executionLaunches[id] else { return false }
        return launch.canonicalDirectory == Self.canonicalPath(directory) &&
            launch.approveProjectConfiguration == isProjectPiConfigTrusted(for: directory)
    }

    private func openExecution(_ id: UUID) async -> Bool {
        guard let reference = state.sessions.first(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == reference.projectID }) else { return false }
        let view = presentation(id)
        view.executionError = nil
        let directoryPath = reference.workingDirectory(in: project)
        if isSavingProjectPiConfig(for: directoryPath) {
            view.executionError = String(localized: "正在保存该目录的项目配置设置，请稍后再试。", bundle: #bundle)
            return false
        }
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

        if let controller = execution(for: id) {
            let policyAndLaunchMatch = executionPolicies[id] == reference.executionPolicy &&
                matchesLaunchConfiguration(id, directory: directoryPath)
            if policyAndLaunchMatch || controller.phase.isActive || !controller.queue.isEmpty {
                if isIdle(controller), let desired = reference.pendingSelection { return await applySelection(desired, to: id) }
                return true
            }
            guard controller.connection != .blocked, controller.phase != .uncertain, !controller.commandPending,
                  controller.interactions.isEmpty, !controller.replying,
                  await closeExecution(id) else {
                view.executionError = controller.failure?.detail ?? String(localized: "请先确认此会话的运行时已清理。", bundle: #bundle)
                return false
            }
        }

        guard !isShuttingDown else { return false }
        executionPolicies[id] = reference.executionPolicy
        await refreshHistory(id)
        guard isExecutable(view),
              let current = state.sessions.first(where: { $0.id == id }),
              let currentProject = state.projects.first(where: { $0.id == current.projectID }) else { return false }
        if let file = current.file, historyInUse(file, excluding: id) {
            view.executionError = String(localized: "已有执行实例使用此会话历史，草稿已保留。", bundle: #bundle)
            return false
        }

        // Re-verify target directory and worktree ownership after async validation and history loading.
        var verifiedDirectory = current.workingDirectory(in: currentProject)
        var verifiedCanonical = Self.canonicalPath(verifiedDirectory)
        var verifiedDirFlag: ObjCBool = false
        guard !isSavingProjectPiConfig(for: verifiedCanonical),
              verifiedCanonical == Self.canonicalPath(directoryPath),
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
                  !isSavingProjectPiConfig(for: verifiedCanonical),
                  FileManager.default.fileExists(atPath: verifiedDirectory, isDirectory: &recheckedDirFlag), recheckedDirFlag.boolValue else {
                view.executionError = String(localized: "工作树不可用：\(verifiedDirectory)", bundle: #bundle)
                return false
            }
        }

        let launch = WorkspaceRuntimeLaunch(
            workingDirectory: verifiedDirectory,
            canonicalDirectory: verifiedCanonical,
            approveProjectConfiguration: isProjectPiConfigTrusted(for: verifiedDirectory)
        )
        executionLaunches[id] = launch
        await view.controller.connect(
            runtimeFactory(currentProject, current, launch),
            history: view.history?.items ?? [],
            turns: view.history?.turns ?? [],
            recordedTurns: current.recordedTurns ?? [],
            recordedMessages: current.recordedMessages ?? []
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
        if let file = view.controller.session?.file, historyInUse(file, excluding: id) {
            view.executionError = String(localized: "已有执行实例使用此会话历史，草稿已保留。", bundle: #bundle)
            _ = await closeExecution(id, force: true)
            return false
        }
        if let desired = current.pendingSelection ?? current.selection,
           current.pendingSelection != nil || !matchesSelection(desired, session: view.controller.session) {
            return await applySelection(desired, to: id)
        }
        synchronize(id)
        guard await flush() else { _ = await closeExecution(id); return false }
        return true
    }

    private func historyInUse(_ file: URL, excluding id: UUID) -> Bool {
        let path = Self.canonicalPath(file.path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return executionIDs.contains { other in
            guard other != id,
                  let otherFile = execution(for: other)?.session?.file ?? state.sessions.first(where: { $0.id == other })?.file else { return false }
            let otherPath = Self.canonicalPath(otherFile.path)
            if otherPath == path { return true }
            guard let device = attributes?[.systemNumber] as? NSNumber,
                  let inode = attributes?[.systemFileNumber] as? NSNumber,
                  let otherAttributes = try? FileManager.default.attributesOfItem(atPath: otherPath) else { return false }
            return device == otherAttributes[.systemNumber] as? NSNumber &&
                inode == otherAttributes[.systemFileNumber] as? NSNumber
        }
    }

    private func isIdle(_ controller: SessionController) -> Bool {
        controller.connection == .connected && controller.phase == .idle &&
            controller.queueIsKnown && controller.queue.isEmpty && controller.interactions.isEmpty &&
            !controller.commandPending && !controller.replying
    }

    private func isExecutable(_ view: SessionPresentation) -> Bool {
        guard !view.loading, view.loadError == nil, view.executionIssue == nil, view.history?.incompleteTail != true else {
            view.executionError = view.loadError ?? view.executionIssue ?? String(localized: "会话尾部尚未写完，请稍后重新读取。", bundle: #bundle)
            return false
        }
        return true
    }

    public func send(_ id: UUID, submitted: UserPrompt? = nil) async {
        guard initialized, !isOperating(on: id), storageError == nil,
              let reference = state.sessions.first(where: { $0.id == id }) else { return }
        let view = presentation(id)
        if let directory = workingDirectory(for: id), isSavingProjectPiConfig(for: directory) {
            view.executionError = String(localized: "正在保存该目录的项目配置设置，请稍后再试。草稿已保留。", bundle: #bundle)
            return
        }
        guard !reference.submissions.contains(where: \.needsReview) else {
            view.executionError = String(localized: "该会话有未核实的发送记录。请先核对执行结果，避免重复操作。", bundle: #bundle)
            return
        }
        if let active = execution(for: id), reference.pendingSelection != nil, active.phase.isActive || !active.queue.isEmpty {
            view.executionError = String(localized: "当前任务及队列完成后才能使用待应用模型，草稿已保留。", bundle: #bundle)
            return
        }
        if reference.historyConfirmed == true, let file = reference.file, !FileManager.default.fileExists(atPath: file.path) {
            view.executionError = String(localized: "历史文件缺失，已阻止继续发送。请恢复原文件或在新会话中执行。", bundle: #bundle)
            return
        }
        let submitted = submitted ?? view.controller.draftPrompt
        guard submitted.hasContent else { return }
        sessionOperations.insert(id)
        defer { endOperation(id) }
        guard await openExecution(id), !isShuttingDown, let controller = execution(for: id) else { return }
        await controller.sendDraft(submitted)
        synchronize(id)
        _ = await flush()
    }

    private func closeExecution(_ id: UUID, force: Bool = false) async -> Bool {
        guard let controller = execution(for: id) else { return true }
        guard await controller.disconnect(force: force) else { return false }
        executionPolicies.removeValue(forKey: id)
        executionLaunches.removeValue(forKey: id)
        return true
    }

    @discardableResult public func disconnect(_ id: UUID, force: Bool = false) async -> Bool {
        guard !sessionOperations.contains(id) else { return false }
        sessionOperations.insert(id)
        defer { sessionOperations.remove(id) }
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

    public func beginShutdown() { isShuttingDown = true }
    public func cancelShutdown() { isShuttingDown = false }

    public func disconnectAll(force: Bool = false) async -> Bool {
        var clean = true
        for id in executionIDs {
            if !(await disconnect(id, force: force)) { clean = false }
        }
        let saved = await flush()
        return clean && saved && sessionOperations.isEmpty && executionPolicies.isEmpty && executionLaunches.isEmpty
    }

    public func reviewSubmission(_ submissionID: UUID, in id: UUID) async {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }), let j = state.sessions[i].submissions.firstIndex(where: { $0.id == submissionID }) else { return }
        state.sessions[i].submissions[j].needsReview = false; _ = await flush()
    }
    public func restoreReviewedSubmission(_ submissionID: UUID, in id: UUID) async {
        guard !isOperating(on: id), storageError == nil, let i = state.sessions.firstIndex(where: { $0.id == id }),
              let j = state.sessions[i].submissions.firstIndex(where: {
                  $0.id == submissionID && $0.delivery == .unknown && !$0.needsReview
              }) else { return }
        let submission = state.sessions[i].submissions.remove(at: j)
        presentation(id).controller.mergeIntoDraft(.init(id: submission.id, text: submission.text,
                                                           mode: submission.mode, files: submission.files ?? []))
        _ = await flush()
    }
    public func setAgentMode(_ mode: AgentMode, for id: UUID) async {
        guard canChangeExecutionPolicy(for: id), let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        state.sessions[i].agentMode = mode
        _ = await flush()
    }
    public func setToolApproval(_ approval: ToolApprovalPolicy, for id: UUID) async {
        guard canChangeExecutionPolicy(for: id), let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        let mode = state.sessions[i].executionMode
        guard mode != .automatic, mode.availableApprovals.contains(approval) else { return }
        var selections = state.sessions[i].approvalPolicies ?? [:]
        selections[mode] = approval
        state.sessions[i].approvalPolicies = selections
        _ = await flush()
    }
    public func canChangeExecutionPolicy(for id: UUID) -> Bool {
        guard !isOperating(on: id), storageError == nil else { return false }
        guard let active = execution(for: id) else { return true }
        return !active.phase.isActive && !active.commandPending && active.queue.isEmpty && active.interactions.isEmpty
    }
    public func modelCatalogue() async throws -> [RuntimeModel] {
        try await inspectModels(nil).models
    }

    @discardableResult public func setDefaultModel(_ model: RuntimeModel?) async -> Bool {
        await updateModelPreferences { $0.defaultModel = model }
    }

    @discardableResult public func setFavoriteModel(_ model: RuntimeModel, isFavorite: Bool) async -> Bool {
        await updateModelPreferences {
            $0.favorites.removeAll { $0.id == model.id }
            if isFavorite { $0.favorites.append(model) }
        }
    }

    @discardableResult public func setModelVisible(_ model: RuntimeModel, isVisible: Bool) async -> Bool {
        await updateModelPreferences {
            if isVisible { $0.hiddenModelIDs.remove(model.id) }
            else { $0.hiddenModelIDs.insert(model.id) }
        }
    }

    private func updateModelPreferences(_ change: @escaping (inout WorkspaceModelPreferences) -> Void) async -> Bool {
        await saveSnapshot(applying: {
            var preferences = $0.modelPreferences ?? WorkspaceModelPreferences()
            change(&preferences)
            $0.modelPreferences = preferences
        })
    }

    public func configurationOptions(for id: UUID, model: RuntimeModel? = nil) async throws -> RuntimeConfigurationOptions {
        guard let reference = state.sessions.first(where: { $0.id == id }) else { throw RuntimeFailure(.setup, String(localized: "会话已不可用。", bundle: #bundle)) }
        let directoryMatches = workingDirectory(for: id).map { matchesLaunchConfiguration(id, directory: $0) } ?? false
        if !isOperating(on: id), executionPolicies[id] == reference.executionPolicy, directoryMatches,
           let active = execution(for: id), active.connection == .connected,
           model == nil || (model?.provider == active.session?.provider && model?.modelID == active.session?.modelID) {
            return try await active.configurationOptions()
        }
        return try await inspectModels(model)
    }
    @discardableResult public func saveSelection(_ selection: RuntimeSelection, name: String? = nil, for id: UUID) async -> Bool {
        guard !isOperating(on: id), let i = state.sessions.firstIndex(where: { $0.id == id }) else { return false }
        presentation(id).executionError = nil
        sessionOperations.insert(id)
        defer { sessionOperations.remove(id) }
        state.sessions[i].pendingSelection = selection
        state.sessions[i].pendingModelName = name
        guard await flush() else { return false }
        let directoryMatches = workingDirectory(for: id).map { matchesLaunchConfiguration(id, directory: $0) } ?? false
        if executionPolicies[id] == state.sessions[i].executionPolicy, directoryMatches,
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
        state.sessions[i].pendingSelection = nil
        state.sessions[i].pendingModelName = nil
        synchronize(id)
        return await flush()
    }
    public func renameSession(_ id: UUID, to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShuttingDown, !title.isEmpty, state.sessions.contains(where: { $0.id == id }) else { return false }
        return await saveSnapshot { snapshot in
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].customTitle = title
        }
    }

    public func setPreferences(_ preferences: WorkspacePreferences) { state.preferences = preferences; scheduleSave() }
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
        let keep = Set(candidates.prefix(4)).union([id]).union(executionPolicies.keys).union(sessionOperations)
        for (key, presentation) in presentations where !keep.contains(key) && presentation.controller.connection == .disconnected && !presentation.controller.commandPending {
            presentation.history = nil; presentation.controller.showHistory([])
        }
    }
    private func presentation(_ id: UUID) -> SessionPresentation {
        if let value = presentations[id] { return value }
        let view = SessionPresentation(id: id, clock: clock)
        if let reference = state.sessions.first(where: { $0.id == id }) {
            view.controller.restoreLocalState(draft: reference.draft, mode: reference.mode, recovered: reference.recovered, files: reference.draftFiles ?? [])
        }
        presentations[id] = view
        view.controller.onDraftEdited = { [weak self, weak controller = view.controller] in
            guard let self, let controller else { return }
            self.dirtyDrafts.insert(id)
            let hasText = !controller.draft.isEmpty || !controller.draftFiles.isEmpty
            if self.draftIndicators[id] != hasText { self.draftIndicators[id] = hasText }
            if hasText, let i = self.state.sessions.firstIndex(where: { $0.id == id }), self.state.sessions[i].sidebarStatus == .settled {
                self.state.sessions[i].processingStatus = .open
            }
            self.scheduleSave()
        }
        view.controller.onControlChanged = { [weak self] in
            guard let self else { return }
            let before = self.state.sessions.first { $0.id == id }?.recovered
            self.synchronize(id)
            if self.presentations[id]?.controller.connection == .disconnected, !self.sessionOperations.contains(id) {
                self.executionPolicies.removeValue(forKey: id)
                self.executionLaunches.removeValue(forKey: id)
            }
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
            let record = RecordedTurnRecord(
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
            self.state.sessions[i].boundWorkingDirectory = self.workingDirectory(for: id)
            self.state.sessions[i].submissions.append(.init(prompt, sentAt: submittedAt))
            self.synchronize(id)
            if controller.matchesDraft(prompt) {
                self.state.sessions[i].draft = ""
                self.state.sessions[i].draftFiles = nil
            }
            guard await self.flush() else {
                self.state.sessions[i].submissions.removeAll { $0.id == prompt.id }
                self.state.sessions[i].boundWorkingDirectory = originalDirectory
                self.synchronize(id)
                throw RuntimeFailure(.setup, String(localized: "提交状态未保存。", bundle: #bundle))
            }
        }
        view.controller.resolveSubmission = { [weak self] promptID, delivery in
            guard let self, let i = self.state.sessions.firstIndex(where: { $0.id == id }), let j = self.state.sessions[i].submissions.firstIndex(where: { $0.id == promptID }) else { return }
            self.state.sessions[i].submissions[j].delivery = delivery
            self.state.sessions[i].submissions[j].acknowledged = [.accepted, .queued, .handled].contains(delivery)
            self.state.sessions[i].submissions[j].needsReview = delivery == .unknown
            if delivery == .rejected, self.state.sessions[i].file == nil, self.state.sessions[i].recordedMessages?.isEmpty != false,
               self.state.sessions[i].submissions.allSatisfy({ $0.delivery == .rejected }) {
                self.state.sessions[i].boundWorkingDirectory = nil
            }
            if self.state.sessions[i].submissions[j].acknowledged || delivery == .unknown {
                self.state.sessions[i].processingStatus = .open
                self.state.sessions[i].sidebarActivity = .init()
                let sub = self.state.sessions[i].submissions[j]
                let itemTs = self.presentations[id]?.controller.transcript.first(where: { $0.id == "user:\(promptID)" })?.messageTimestampMs
                var messages = self.state.sessions[i].recordedMessages ?? []
                if !messages.contains(where: { $0.id == promptID }) {
                    messages.append(.init(id: promptID, text: sub.text, files: sub.files, sentAt: sub.sentAt, messageTimestampMs: itemTs))
                    self.state.sessions[i].recordedMessages = messages
                }
            }
            self.synchronize(id); _ = await self.flush()
        }
        return view
    }
    private func synchronize(_ id: UUID) {
        guard let controller = presentations[id]?.controller, let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
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
        if executionPolicies[id] != nil, let runtime = controller.session {
            // Pi allocates a filename at connect but does not create a file until
            // the first conversational input. An unopened session stays local.
            let hasFile = runtime.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let expected = state.sessions[i].runtimeSessionID
            if state.sessions[i].historyConfirmed != true || expected == nil || expected == runtime.id {
                if hasFile || !state.sessions[i].submissions.isEmpty {
                    state.sessions[i].runtimeSessionID = runtime.id; state.sessions[i].file = runtime.file
                    if hasFile { state.sessions[i].historyConfirmed = true }
                } else if state.sessions[i].historyConfirmed != true {
                    state.sessions[i].runtimeSessionID = nil; state.sessions[i].file = nil
                }
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
            }
        }
        state.sessions[i].submissions.removeAll { submission in
            [.handled, .rejected, .recovered].contains(submission.delivery) || (final && controller.queue.isEmpty && [.accepted, .queued].contains(submission.delivery) && !submission.needsReview)
        }
    }
}
