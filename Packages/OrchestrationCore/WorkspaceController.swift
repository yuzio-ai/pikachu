import Foundation
import Observation
import AgentRuntimeCore

@MainActor @Observable public final class SessionPresentation: Identifiable {
    public let id: UUID
    public let controller: SessionController
    public var history: RuntimeHistory?
    public var loading = false
    public var loadError: String?
    public var executionIssue: String?
    @ObservationIgnored var readGeneration = UUID()
    init(id: UUID, clock: any RuntimeClock = SystemRuntimeClock()) {
        self.id = id
        self.controller = SessionController(clock: clock)
    }
}

@MainActor @Observable public final class WorkspaceController {
    public private(set) var state = WorkspaceSnapshot()
    public private(set) var initialized = false
    public private(set) var busy = false
    public private(set) var refreshingHistoryIndex = false
    private var savingProject = false
    public private(set) var activeID: UUID?
    public private(set) var activeMode: AgentMode?
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
    public private(set) var lastCompletedTurnDirectory: String?
    public private(set) var completedTurnSequence = 0
    public func focusInput() { inputFocusRequest += 1 }
    @ObservationIgnored private let store: any WorkspaceStore
    @ObservationIgnored private let reader: any RuntimeHistoryReader
    @ObservationIgnored private let clock: any RuntimeClock
    @ObservationIgnored private let factory: @MainActor (ProjectRecord, SessionReference) -> any AgentRuntime
    @ObservationIgnored private let inspectModels: @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var dirtyDrafts: Set<UUID> = []
    @ObservationIgnored private var activatingID: UUID?
    private var draftIndicators: [UUID: Bool] = [:]
    public var active: SessionController? { activeID.flatMap { presentations[$0]?.controller } }
    public var selected: SessionReference? { state.sessions.first { $0.id == state.selectedSessionID } }
    public var selectedProject: ProjectRecord? { selected.flatMap { item in state.projects.first { $0.id == item.projectID } } }
    public var canManageProjects: Bool { initialized && !busy && !savingProject && !refreshingHistoryIndex && storageError == nil }
    public func hasDraft(_ session: SessionReference) -> Bool {
        (draftIndicators[session.id] ?? (!session.draft.isEmpty || session.draftFiles?.isEmpty == false)) || !session.recovered.isEmpty
    }
    public var requiresStopBeforeSend: Bool {
        guard let active, activeID != state.selectedSessionID else { return false }
        return active.connection == .blocked || active.commandPending || active.phase.isActive || !active.queue.isEmpty
    }
    public init(store: any WorkspaceStore, reader: any RuntimeHistoryReader,
                clock: any RuntimeClock = SystemRuntimeClock(),
                inspectModels: @escaping @MainActor (RuntimeModel?) async throws -> RuntimeConfigurationOptions = { _ in
                    throw RuntimeFailure(.setup, "未配置模型目录。")
                }, factory: @escaping @MainActor (ProjectRecord, SessionReference) -> any AgentRuntime) {
        self.store = store; self.reader = reader; self.clock = clock; self.factory = factory
        self.inspectModels = inspectModels
    }
    public func start() async {
        guard !initialized else { return }
        do {
            state = try await store.load()
            guard state.version == 1, Set(state.projects.map(\.id)).count == state.projects.count,
                  Set(state.sessions.map(\.id)).count == state.sessions.count,
                  state.sessions.allSatisfy({ s in state.projects.contains { $0.id == s.projectID } }) else { throw RuntimeFailure(.setup, "本地索引不一致。") }
            let runtimeKeys = state.sessions.compactMap { s in s.runtimeSessionID.map { s.projectID.uuidString + ":" + s.runtimeID + ":" + $0 } }
            guard Set(runtimeKeys).count == runtimeKeys.count else { throw RuntimeFailure(.setup, "本地会话绑定重复。") }
            for i in state.sessions.indices {
                initializeSidebarMetadata(at: i)
                // Extension commands may be handled without materializing a Pi
                // session file. Keep their journal, but never resume an allocation
                // that has no durable history. Confirmed missing history stays blocked.
                if state.sessions[i].historyConfirmed != true,
                   state.sessions[i].file.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                    state.sessions[i].runtimeSessionID = nil; state.sessions[i].file = nil
                }
                if state.sessions[i].wasExecuting { notice = "上次运行已中断。仅恢复历史和草稿，没有恢复推理或执行队列。" }
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
        } catch { storageError = "本地工作台数据无法读取，已阻止执行；没有重建或覆盖原数据。" }
    }
    @discardableResult public func addProject(_ path: URL) async -> UUID? {
        guard canManageProjects else { return nil }
        let location = path.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location, isDirectory: &directory), directory.boolValue else { error = "项目目录不存在。"; return nil }
        if let existing = state.projects.first(where: { $0.path == location }) {
            if let session = state.sessions.first(where: { $0.projectID == existing.id }) { await select(session.id) }
            return existing.id
        }
        let project = ProjectRecord(path: location); state.projects.append(project)
        savingProject = true
        defer { savingProject = false }
        let session = appendNewSession(to: project.id)
        await select(session)
        if await flush() { await refreshHistoryIndex(projectID: project.id, refreshViewed: false) }
        return project.id
    }
    public func relocateProject(_ projectID: UUID, to path: URL) async {
        guard canManageProjects, let i = state.projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let activeID, state.sessions.first(where: { $0.id == activeID })?.projectID == projectID, active?.connection != .disconnected {
            error = "请先清理并断开该项目的执行会话，再重新定位。"; return
        }
        let location = path.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location, isDirectory: &directory), directory.boolValue,
              !state.projects.contains(where: { $0.id != projectID && $0.path == location }) else { error = "目录不可用或已属于其他项目。"; return }
        let previous = state.projects[i].path
        if !state.projects[i].previousPaths.contains(previous) { state.projects[i].previousPaths.append(previous) }
        state.projects[i].path = location; state.projects[i].name = path.lastPathComponent
        savingProject = true
        defer { savingProject = false }
        if await flush() { await refreshHistoryIndex(projectID: projectID, refreshViewed: false) }
    }
    @discardableResult public func createSession(in projectID: UUID) async -> UUID? {
        guard canManageProjects, state.projects.contains(where: { $0.id == projectID }) else { return nil }
        let id = appendNewSession(to: projectID)
        await select(id); _ = await flush()
        return id
    }
    private func appendNewSession(to projectID: UUID) -> UUID {
        var reference = SessionReference(projectID: projectID)
        reference.agentMode = .interactive
        reference.processingStatus = .open
        reference.sidebarActivity = .init(date: reference.lastViewed)
        state.sessions.append(reference)
        return reference.id
    }
    public func settleBlockReason(for session: SessionReference) -> LocalizedStringResource? {
        if !initialized || storageError != nil { return "请先恢复工作台存储。" }
        if session.id == activeID, let active {
            if !active.interactions.isEmpty { return "请先处理等待中的输入。" }
            if active.connection == .closing || active.connection == .blocked { return "请先确认运行时进程已清理。" }
            if active.phase == .uncertain { return "请先核实执行结果。" }
            if active.phase.isActive || active.connection == .connecting || active.commandPending || !active.queue.isEmpty {
                return "请等待执行和队列结束。"
            }
        }
        if session.submissions.contains(where: \.needsReview) { return "请先核对未确认的发送记录。" }
        if busy || session.submissions.contains(where: { [.pending, .queued, .accepted].contains($0.delivery) }) {
            return "请等待当前操作结束。"
        }
        if hasDraft(session) { return "请先处理会话草稿。" }
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
    public func refreshHistory(_ id: UUID) async {
        guard let reference = state.sessions.first(where: { $0.id == id }) else { return }
        let view = presentation(id)
        guard reference.runtimeID == "pi" else { view.loadError = "该历史的 Runtime 尚未接入，原记录已保留。"; return }
        if activeID == id, view.controller.connection != .disconnected { return }
        guard let file = reference.file else { view.loadError = nil; view.executionIssue = nil; return }
        let generation = UUID(); view.readGeneration = generation; view.loading = true; view.loadError = nil
        defer { if view.readGeneration == generation { view.loading = false } }
        do {
            let history = try await reader.read(file)
            guard view.readGeneration == generation, !(activeID == id && view.controller.connection != .disconnected),
                  let index = state.sessions.firstIndex(where: { $0.id == id && $0.file == file }) else { return }
            guard reference.runtimeSessionID == history.sessionID else { throw RuntimeFailure(.protocolError, "会话标识不匹配。") }
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
            let project = state.projects.first { $0.id == reference.projectID }
            let historyLocation = URL(fileURLWithPath: history.cwd).standardizedFileURL.resolvingSymlinksInPath().path
            view.executionIssue = project?.path == historyLocation ? nil : "历史工作目录与当前位置不同。旧会话可只读查看；请在当前位置新建会话。"
        } catch {
            if view.readGeneration == generation {
                view.loadError = ((error as? RuntimeFailure)?.detail ?? "历史读取失败，未修改源文件。")
                    + (view.history == nil ? "" : " 下方保留上次可读内容，可能已过期。")
            }
        }
    }
    public func discover(_ projectID: UUID) async {
        guard canManageProjects, state.projects.contains(where: { $0.id == projectID }) else { return }
        await refreshHistoryIndex(projectID: projectID, refreshViewed: false)
    }
    public func refreshWorkspaceHistory() async {
        guard canManageProjects, !state.projects.isEmpty else { return }
        await refreshHistoryIndex(projectID: nil, refreshViewed: true)
    }
    private struct HistoryBinding: Hashable {
        let projectID: UUID
        let sessionID: String
    }
    private func refreshHistoryIndex(projectID: UUID?, refreshViewed: Bool) async {
        guard initialized, !refreshingHistoryIndex, storageError == nil else { return }
        refreshingHistoryIndex = true
        defer { refreshingHistoryIndex = false }
        let projects = state.projects
        let scope = Set(projects.lazy.filter { projectID == nil || $0.id == projectID }.map(\.id))
        let locations = projects.filter { scope.contains($0.id) }.flatMap { [$0.path] + $0.previousPaths }
        error = nil
        do {
            let found = try await reader.discoverSummaries(locations: Array(Set(locations)).sorted())
            var issues = found.issues
            var ownersByPath: [String: Set<UUID>] = [:]
            for project in projects {
                for path in [project.path] + project.previousPaths {
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
                        issues.append("部分会话的工作目录对应多个项目，已保留现有绑定。")
                        ambiguous.formUnion(candidates)
                    }
                    continue
                }
                if scope.contains(binding.projectID) { foundByBinding[binding, default: []].append(history) }
            }
            for (binding, group) in foundByBinding where !ambiguous.contains(binding) {
                guard group.count == 1, let history = group.first else { issues.append("同一会话 ID 对应多个文件，请保留唯一来源后刷新。"); continue }
                if let i = indexed[binding] {
                    guard activatingID != state.sessions[i].id,
                          activeID != state.sessions[i].id || active?.connection == .disconnected else { continue }
                    var reference = state.sessions[i]
                    updateHistoryMetadata(history, in: &reference)
                    if state.sessions[i] != reference { state.sessions[i] = reference }
                } else {
                    var reference = SessionReference(projectID: binding.projectID, title: history.title)
                    reference.runtimeSessionID = history.sessionID
                    reference.processingStatus = history.needsAttention ? .open : .settled
                    updateHistoryMetadata(history, in: &reference)
                    if reference.sidebarActivity == nil {
                        reference.sidebarActivity = .init(date: reference.lastViewed, isEstimate: true)
                    }
                    state.sessions.append(reference)
                }
            }
            if !issues.isEmpty {
                var seen = Set<String>()
                notice = issues.filter { seen.insert($0).inserted }.prefix(3).joined(separator: "\n")
            }
            if refreshViewed, let id = state.selectedSessionID { await refreshHistory(id) }
            if await flush(), refreshViewed, issues.isEmpty { notice = "会话列表已刷新。" }
        } catch { self.error = "会话发现失败，现有索引和源历史保持不变。" }
    }
    private func updateHistoryMetadata(_ history: RuntimeHistorySummary, in reference: inout SessionReference) {
        reference.file = history.file
        reference.historyConfirmed = true
        reference.historicalModel = history.model
        if let date = history.activityAt, reference.activity.isEstimate || date > reference.activity.date {
            reference.sidebarActivity = .init(date: date)
        }
    }
    /// Establish a supervised execution connection for the next input.
    @discardableResult public func activate(_ id: UUID, stopCurrent: Bool = false) async -> Bool {
        guard initialized, !busy, storageError == nil, let reference = state.sessions.first(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == reference.projectID }) else { return false }
        error = nil
        if activeID == id, let active, active.connection == .connected,
           activeMode == reference.executionMode || active.phase.isActive || !active.queue.isEmpty {
            if active.phase == .idle, active.queue.isEmpty, let desired = reference.pendingSelection {
                busy = true; defer { busy = false }
                return await applySelection(desired, to: id)
            }
            return true
        }
        if let active {
            guard !active.commandPending || (!active.interactions.isEmpty && stopCurrent) else { error = "请等待当前控制请求结束。"; return false }
            if (active.phase.isActive || !active.queue.isEmpty || active.connection == .blocked) && !stopCurrent {
                error = "当前任务仍占用执行槽位。草稿已保留，请返回任务或明确停止后再执行。"; return false
            }
        }
        busy = true; error = nil; activatingID = id
        defer { busy = false; activatingID = nil }
        if let active {
            if activeID != id {
                await refreshHistory(id)
                guard isExecutable(presentation(id)) else { return false }
            }
            if !active.interactions.isEmpty { await active.stop() }
            // Disconnect retains M1's clear_queue → abort → supervised close policy.
            guard await active.disconnect(force: active.connection == .blocked || active.phase == .uncertain) else { error = "旧执行实例清理未确认，没有启动目标会话。"; return false }
            activeID = nil; activeMode = nil
            guard await flush() else { return false }
        }
        await refreshHistory(id)
        let view = presentation(id)
        guard isExecutable(view),
              let reference = state.sessions.first(where: { $0.id == id }) else { return false }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else { error = "项目目录已移动，请重新定位后执行。"; return false }
        activeID = id; activeMode = reference.executionMode
        await view.controller.connect(
            factory(project, reference),
            history: view.history?.items ?? [],
            turns: view.history?.turns ?? [],
            recordedTurns: reference.recordedTurns ?? [],
            recordedMessages: reference.recordedMessages ?? []
        )
        guard view.controller.connection == .connected else { error = view.controller.failure?.detail ?? "连接失败。"; return false }
        if let expected = reference.runtimeSessionID, view.controller.session?.id != expected {
            error = "执行会话标识与历史绑定不一致，没有发送任务。"
            _ = await view.controller.disconnect(force: true); return false
        }
        if let desired = reference.pendingSelection ?? reference.selection,
           reference.pendingSelection != nil || !matchesSelection(desired, session: view.controller.session) {
            return await applySelection(desired, to: id)
        }
        synchronize(id)
        guard await flush() else { _ = await view.controller.disconnect(); return false }
        return true
    }
    private func isExecutable(_ view: SessionPresentation) -> Bool {
        guard view.loadError == nil, view.executionIssue == nil, view.history?.incompleteTail != true else {
            error = view.loadError ?? view.executionIssue ?? "会话尾部尚未写完，请稍后重新读取。"
            return false
        }
        return true
    }
    public func send(_ id: UUID, stopCurrent: Bool = false, submitted: UserPrompt? = nil) async {
        guard let reference = state.sessions.first(where: { $0.id == id }), !reference.submissions.contains(where: \.needsReview) else {
            error = "该会话有未核实的发送记录。请先核对执行结果，避免重复操作。"; return
        }
        if activeID == id, let active, reference.pendingSelection != nil, active.phase.isActive || !active.queue.isEmpty {
            error = "当前任务及队列完成后才能使用待应用模型，草稿已保留。"
            return
        }
        if reference.historyConfirmed == true, let file = reference.file, !FileManager.default.fileExists(atPath: file.path) {
            error = "历史文件缺失，已阻止继续发送。请恢复原文件或在新会话中执行。"; return
        }
        let editor = presentation(id).controller
        let submitted = submitted ?? editor.draftPrompt
        guard submitted.hasContent else { return }
        guard await activate(id, stopCurrent: stopCurrent), let controller = presentations[id]?.controller else { return }
        await controller.sendDraft(submitted); synchronize(id); _ = await flush()
    }
    public func disconnect(force: Bool = false) async -> Bool {
        guard !busy else { return false }
        guard let active else { return await flush() }
        busy = true; let result = await active.disconnect(force: force); busy = false
        if result { activeID = nil; activeMode = nil }
        let saved = await flush(); return result && saved
    }
    public func stop() async { guard !busy else { return }; await active?.stop(); _ = await flush() }
    public func reviewSubmission(_ submissionID: UUID, in id: UUID) async {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }), let j = state.sessions[i].submissions.firstIndex(where: { $0.id == submissionID }) else { return }
        state.sessions[i].submissions[j].needsReview = false; _ = await flush()
    }
    public func restoreReviewedSubmission(_ submissionID: UUID, in id: UUID) async {
        guard !busy, storageError == nil, let i = state.sessions.firstIndex(where: { $0.id == id }),
              let j = state.sessions[i].submissions.firstIndex(where: {
                  $0.id == submissionID && $0.delivery == .unknown && !$0.needsReview
              }) else { return }
        let submission = state.sessions[i].submissions.remove(at: j)
        presentation(id).controller.mergeIntoDraft(.init(id: submission.id, text: submission.text,
                                                           mode: submission.mode, files: submission.files ?? []))
        _ = await flush()
    }
    public func setAgentMode(_ mode: AgentMode, for id: UUID) async {
        guard !busy, let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        if activeID == id, let active, active.phase.isActive || active.commandPending || !active.queue.isEmpty { return }
        state.sessions[i].agentMode = mode
        _ = await flush()
    }
    public func configurationOptions(for id: UUID, model: RuntimeModel? = nil) async throws -> RuntimeConfigurationOptions {
        guard let reference = state.sessions.first(where: { $0.id == id }) else { throw RuntimeFailure(.setup, "会话已不可用。") }
        if !busy, activeID == id, activeMode == reference.executionMode, let active, active.connection == .connected,
           model == nil || (model?.provider == active.session?.provider && model?.modelID == active.session?.modelID) {
            return try await active.configurationOptions()
        }
        return try await inspectModels(model)
    }
    @discardableResult public func saveSelection(_ selection: RuntimeSelection, name: String? = nil, for id: UUID) async -> Bool {
        guard !busy, let i = state.sessions.firstIndex(where: { $0.id == id }) else { return false }
        busy = true; error = nil; defer { busy = false }
        state.sessions[i].pendingSelection = selection
        state.sessions[i].pendingModelName = name
        guard await flush() else { return false }
        if activeID == id, activeMode == state.sessions[i].executionMode, let active, active.connection == .connected,
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
        guard activeID == id, let active, let i = state.sessions.firstIndex(where: { $0.id == id }) else { return false }
        // Keep the request through startup readback and failed attempts.
        state.sessions[i].pendingSelection = selection
        guard await active.configure(selection) else {
            error = active.failure?.detail ?? "模型配置暂时无法应用，草稿已保留。"
            _ = await flush()
            return false
        }
        state.sessions[i].pendingSelection = nil
        state.sessions[i].pendingModelName = nil
        synchronize(id)
        return await flush()
    }
    public func setPreferences(_ preferences: WorkspacePreferences) { state.preferences = preferences; scheduleSave() }
    @discardableResult public func flush() async -> Bool {
        guard initialized else { return false }
        autosave?.cancel()
        for id in dirtyDrafts {
            guard let controller = presentations[id]?.controller,
                  let index = state.sessions.firstIndex(where: { $0.id == id }) else { continue }
            state.sessions[index].draft = controller.draft
            state.sessions[index].draftFiles = controller.draftFiles.isEmpty ? nil : controller.draftFiles
        }
        dirtyDrafts.removeAll()
        state.revision += 1
        let snapshot = state
        do {
            try await store.save(snapshot)
            if snapshot.revision == state.revision { storageError = nil }
            return true
        } catch {
            if snapshot.revision == state.revision {
                storageError = "本地保存失败，已阻止新任务。会话状态和草稿仍在内存中，请修复存储后重试保存。"
            }
            return false
        }
    }
    private func scheduleSave() {
        guard initialized else { return }
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }; _ = await self.flush()
        }
    }
    private func trimHistoryCache(keeping id: UUID) {
        let candidates = state.sessions.sorted { $0.lastViewed > $1.lastViewed }.map(\.id)
        let keep = Set(candidates.prefix(4)).union([id]).union(activeID.map { [$0] } ?? [])
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
            if before != self.state.sessions.first(where: { $0.id == id })?.recovered {
                Task { _ = await self.flush() }
            } else { self.scheduleSave() }
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
                status: turn.status
            )
            var turns = self.state.sessions[i].recordedTurns ?? []
            if let existing = turns.firstIndex(where: { $0.id == record.id }) { turns[existing] = record }
            else { turns.append(record) }
            self.state.sessions[i].recordedTurns = turns
            let projectID = self.state.sessions[i].projectID
            if let path = self.state.projects.first(where: { $0.id == projectID })?.path {
                self.lastCompletedTurnDirectory = path
                self.completedTurnSequence += 1
            }
            self.scheduleSave()
        }
        view.controller.onUserMessageTimestamp = { [weak self] promptID, timestampMs in
            guard let self, let i = self.state.sessions.firstIndex(where: { $0.id == id }) else { return }
            var messages = self.state.sessions[i].recordedMessages ?? []
            if let promptID, let j = messages.firstIndex(where: { $0.id == promptID }) {
                messages[j].messageTimestampMs = timestampMs
                self.state.sessions[i].recordedMessages = messages
                self.scheduleSave()
            } else if let j = messages.lastIndex(where: { $0.messageTimestampMs == nil }) {
                messages[j].messageTimestampMs = timestampMs
                self.state.sessions[i].recordedMessages = messages
                self.scheduleSave()
            }
        }
        view.controller.prepareSubmission = { [weak self, weak controller = view.controller] prompt in
            guard let self, let controller, let i = self.state.sessions.firstIndex(where: { $0.id == id }), self.storageError == nil else { throw RuntimeFailure(.setup, "工作台不可写。") }
            let submittedAt = self.clock.now()
            self.state.sessions[i].submissions.append(.init(prompt, sentAt: submittedAt))
            self.synchronize(id)
            if controller.matchesDraft(prompt) {
                self.state.sessions[i].draft = ""
                self.state.sessions[i].draftFiles = nil
            }
            guard await self.flush() else {
                self.state.sessions[i].submissions.removeAll { $0.id == prompt.id }
                self.synchronize(id)
                throw RuntimeFailure(.setup, "提交状态未保存。")
            }
        }
        view.controller.resolveSubmission = { [weak self] promptID, delivery in
            guard let self, let i = self.state.sessions.firstIndex(where: { $0.id == id }), let j = self.state.sessions[i].submissions.firstIndex(where: { $0.id == promptID }) else { return }
            self.state.sessions[i].submissions[j].delivery = delivery
            self.state.sessions[i].submissions[j].acknowledged = [.accepted, .queued, .handled].contains(delivery)
            self.state.sessions[i].submissions[j].needsReview = delivery == .unknown
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
        if activeID == id, let runtime = controller.session {
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
            else if let file = first.submission?.files.first { state.sessions[i].title = "查看 " + String(file.lastPathComponent.prefix(45)) }
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
