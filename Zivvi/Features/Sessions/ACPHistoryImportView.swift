import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ACPHistoryImportView: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let projectID: UUID
    let directory: String
    let imported: () -> Void
    let openAgentSettings: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var agentID: String?
    @State private var authentication: RuntimeAgentAuthentication?
    @State private var control: (any RuntimeAgentControl)?
    @State private var page: RuntimeRemoteSessionPage?
    @State private var sessions: [RuntimeRemoteSession] = []
    @State private var error: String?
    @State private var loading = false
    @State private var authenticating = false
    @State private var needsLogin = false
    @State private var blockedCursor: String?
    @State private var interactions: [RuntimeInteraction] = []
    @State private var replying = false
    @State private var nextPage: Task<Void, Never>?
    @State private var replyTask: Task<Void, Never>?
    @State private var activeQuery: ActiveQuery?
    @State private var loadGeneration = 0
    @State private var connectedHostID: UUID?
    @State private var disconnectedHostID: UUID?

    private struct Query: Equatable {
        let agent: String?
        let generation: Int
    }

    private struct ActiveQuery: Equatable {
        let query: Query
        let id = UUID()
    }

    enum HistoryRecovery: Equatable {
        case waiting, reload, loginInSettings, failed(String)
    }

    private var agents: [RuntimeAgentProfile] { settings.acpAgents.filter(\.enabled) }
    private var connectionStatus: ACPPoolStatus? { agentID.flatMap { settings.acpPoolStatuses[$0] } }
    private var query: Query { .init(agent: agentID, generation: loadGeneration) }
    private var historyRecovery: HistoryRecovery { Self.recovery(after: disconnectedHostID, status: connectionStatus) }
    private var offersSettingsLogin: Bool {
        historyRecovery == .loginInSettings || (needsLogin && authentication?.methods.isEmpty != false)
    }
    private var visibleError: String? {
        switch historyRecovery {
        case .failed(let detail): return detail
        case .loginInSettings: return String(localized: "请先在智能体设置中登录，再重新读取历史。")
        default: return error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                Text("从 Agent 导入会话").zivviFont(.title3, weight: .semibold)
                Text(verbatim: directory).zivviFont(.caption).textSelection(.enabled)
            }
            Picker("Agent", selection: $agentID) {
                Text("请选择").tag(nil as String?)
                ForEach(agents) { agent in Text(agent.name).tag(Optional(agent.id)) }
            }
            if let request = interactions.first, let elicitation = request.elicitation {
                ACPElicitationView(request: request, elicitation: elicitation, submitting: replying, reply: reply)
                    .id(request.id)
            } else if needsLogin, let control, let authentication, !authentication.methods.isEmpty {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                    ForEach(authentication.methods) { method in
                        Button(method.name) {
                            guard let agentID, let activeQuery, isCurrent(activeQuery), nextPage == nil else { return }
                            let cursor = blockedCursor
                            let previousConnection = authentication.connectionID
                            authenticating = true
                            nextPage = Task {
                                defer { finishPageAction(activeQuery) }
                                do {
                                    try await settings.performACPAuthentication(for: agentID) {
                                        try await control.authenticate(methodID: method.id)
                                    }
                                    let updated = await control.authentication
                                    let hostID = await control.sharedConnectionID
                                    guard isCurrent(activeQuery) else { return }
                                    self.authentication = updated
                                    connectedHostID = hostID
                                    let resume = updated.connectionID == previousConnection
                                    if !resume {
                                        page = nil
                                        sessions = []
                                        blockedCursor = nil
                                    }
                                    await load(control, cursor: resume ? cursor : nil, for: activeQuery)
                                } catch where isCurrent(activeQuery) { errorMessage(error) }
                                  catch {}
                            }
                        }
                        .disabled(authenticating || loading)
                    }
                }
            }
            if let visibleError {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                    Text(visibleError).foregroundStyle(ZivviTheme.errorText)
                    if !loading, !needsLogin || offersSettingsLogin { Button("重新读取") { loadGeneration += 1 } }
                    if !loading, offersSettingsLogin, let agentID {
                        Button("在设置中登录") { openAgentSettings(agentID) }
                    }
                }
            }
            if loading { FlatProgressView() }
            if !sessions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sessions) { session in
                            Button {
                                guard let agentID, let page, let activeQuery, isCurrent(activeQuery) else { return }
                                Task {
                                    let importedID = await workspace.importRemoteSession(session, projectID: projectID, agentID: agentID,
                                                                                       canRestore: page.canRestore,
                                                                                       canDelete: page.canDelete)
                                    guard isCurrent(activeQuery) else { return }
                                    if importedID != nil {
                                        imported()
                                        dismiss()
                                    } else {
                                        error = String(localized: "无法导入会话，请重试。")
                                    }
                                }
                            } label: {
                                FlatMenuRow(title: Text(verbatim: session.title ?? session.id))
                            }
                        }
                    }
                }
                .frame(maxHeight: 330)
            } else if page != nil && !loading {
                Text("此工作目录没有可导入的会话。")
            }
            HStack {
                if let cursor = page?.nextCursor, let control {
                    Button("加载更多") {
                        guard let activeQuery, isCurrent(activeQuery), nextPage == nil else { return }
                        nextPage = Task {
                            defer { finishPageAction(activeQuery) }
                            await load(control, cursor: cursor, for: activeQuery)
                        }
                    }
                    .disabled(loading)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        .padding(22)
        .frame(width: 560)
        .onAppear { agentID = agents.first?.id }
        .onChange(of: agents.map(\.id)) { _, enabled in
            if let agentID, !enabled.contains(agentID) { self.agentID = nil }
        }
        .onChange(of: agentID) { _, _ in disconnectedHostID = nil }
        .onChange(of: connectionStatus) { _, _ in restartHistoryIfReady() }
        .task(id: query) { [query] in await readHistory(query) }
        .onDisappear { resetQuery() }
    }

    private func readHistory(_ query: Query) async {
        guard !Task.isCancelled, query == self.query else { return }
        resetQuery()
        error = nil
        guard let agentID = query.agent else { return }
        let active = ActiveQuery(query: query)
        activeQuery = active
        loading = true
        do {
            let opened = try await settings.openACPControl(agentID: agentID, directory: URL(fileURLWithPath: directory))
            let methods = await opened.authentication
            let hostID = await opened.sharedConnectionID
            if isCurrent(active) {
                connectedHostID = hostID
                disconnectedHostID = nil
                authentication = methods
                control = opened
                let events = Task {
                    for await envelope in opened.events {
                        guard isCurrent(active) else { return }
                        consume(envelope.event)
                        guard isCurrent(active) else { return }
                    }
                }
                await withTaskCancellationHandler {
                    await load(opened, cursor: nil, for: active)
                    await events.value
                } onCancel: { events.cancel() }
            }
            try await settings.closeACPHistoryControl(opened)
            if isCurrent(active) {
                resetQuery()
                error = String(localized: "尚未连接运行时。")
            }
        } catch where isCurrent(active) {
            loading = false
            errorMessage(error)
            restartHistoryIfReady()
        } catch {}
    }

    private func isCurrent(_ active: ActiveQuery) -> Bool {
        !Task.isCancelled && activeQuery == active && active.query == query
    }

    private func resetQuery() {
        activeQuery = nil
        nextPage?.cancel()
        nextPage = nil
        replyTask?.cancel()
        replyTask = nil
        control = nil
        connectedHostID = nil
        authentication = nil
        page = nil
        sessions = []
        blockedCursor = nil
        interactions = []
        needsLogin = false
        loading = false
        authenticating = false
        replying = false
    }

    private func finishPageAction(_ active: ActiveQuery) {
        guard isCurrent(active) else { return }
        authenticating = false
        nextPage = nil
    }

    private func load(_ connection: any RuntimeAgentControl, cursor: String?, for active: ActiveQuery) async {
        guard isCurrent(active) else { return }
        loading = true
        needsLogin = false
        error = nil
        do {
            let result = try await connection.list(cursor: cursor)
            guard isCurrent(active) else { return }
            var seen = Set(sessions.map(\.id))
            sessions.append(contentsOf: result.sessions.filter { seen.insert($0.id).inserted })
            page = result
        } catch where isCurrent(active) {
            needsLogin = (error as? RuntimeFailure)?.kind == .authentication
            blockedCursor = cursor
            errorMessage(error)
        } catch { return }
        if isCurrent(active) { loading = false }
    }

    static func recovery(after previous: UUID?, status: ACPPoolStatus?) -> HistoryRecovery {
        switch status {
        case .ready(let host), .needsLogin(let host?):
            return previous.map { $0 != host } == true ? .reload : .waiting
        case .dedicated:
            return previous != nil ? .reload : .waiting
        case .needsLogin(nil):
            return .loginInSettings
        case .failed(let detail) where previous != nil:
            return .failed(detail)
        default:
            return .waiting
        }
    }

    private func restartHistoryIfReady() {
        guard !loading, historyRecovery == .reload else { return }
        disconnectedHostID = nil
        loadGeneration += 1
    }

    private func consume(_ event: AgentEvent) {
        switch event {
        case .batch(let events):
            for event in events {
                guard activeQuery != nil else { return }
                consume(event)
            }
        case .interaction(let request): interactions.append(request)
        case .interactionEnded(let id, _): interactions.removeAll { $0.id == id }
        case .failure(let failure): errorMessage(failure)
        case .disconnected:
            disconnectedHostID = connectedHostID
            resetQuery()
            restartHistoryIfReady()
        default: break
        }
    }

    private func reply(_ answer: InteractionResponse) {
        guard let request = interactions.first, let control, let activeQuery, isCurrent(activeQuery), replyTask == nil else { return }
        replying = true
        replyTask = Task {
            defer {
                if isCurrent(activeQuery) {
                    replying = false
                    replyTask = nil
                }
            }
            do { try await control.respond(to: request, with: answer) }
            catch where isCurrent(activeQuery) { errorMessage(error) }
            catch {}
        }
    }

    private func errorMessage(_ failure: Error) {
        error = (failure as? RuntimeFailure)?.detail ?? failure.localizedDescription
    }
}
