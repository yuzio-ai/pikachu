import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ACPHistoryImportView: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let projectID: UUID
    let directory: String
    let imported: () -> Void

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

    private var agents: [RuntimeAgentProfile] { settings.acpAgents.filter(\.enabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从 Agent 导入会话").pikachuFont(.title3, weight: .semibold)
            Text(verbatim: directory).pikachuFont(.caption).textSelection(.enabled)
            Picker("Agent", selection: $agentID) {
                Text("请选择").tag(nil as String?)
                ForEach(agents) { agent in Text(agent.name).tag(Optional(agent.id)) }
            }
            .disabled(nextPage != nil)
            if let request = interactions.first, let elicitation = request.elicitation {
                ACPElicitationView(request: request, elicitation: elicitation, submitting: replying, reply: reply)
                    .id(request.id)
            } else if needsLogin, let control, let authentication {
                ForEach(authentication.methods) { method in
                    Button(method.name) {
                        guard let agentID else { return }
                        nextPage = Task {
                            authenticating = true
                            defer { authenticating = false; nextPage = nil }
                            do {
                                try await settings.performACPAuthentication(for: agentID) {
                                    try await control.authenticate(methodID: method.id)
                                }
                                await load(control, cursor: blockedCursor)
                            } catch { errorMessage(error) }
                        }
                    }
                    .disabled(authenticating || loading)
                }
            }
            if let error { Text(error).foregroundStyle(PikachuTheme.errorText) }
            if loading { FlatProgressView() }
            if !sessions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sessions) { session in
                            Button {
                                guard let agentID, let page else { return }
                                Task {
                                    if await workspace.importRemoteSession(session, projectID: projectID, agentID: agentID,
                                                                          canRestore: page.canRestore,
                                                                          canDelete: page.canDelete) != nil {
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
                        nextPage = Task {
                            defer { nextPage = nil }
                            await load(control, cursor: cursor)
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
        .task(id: agentID) {
            guard let agentID else { return }
            sessions = []
            page = nil
            control = nil
            authentication = nil
            interactions = []
            needsLogin = false
            error = nil
            loading = true
            do {
                let opened = try await settings.openACPControl(agentID: agentID, directory: URL(fileURLWithPath: directory))
                guard !Task.isCancelled else { try await opened.close(); return }
                authentication = await opened.authentication
                control = opened
                let events = Task {
                    for await envelope in opened.events {
                        guard !Task.isCancelled else { return }
                        consume(envelope.event)
                    }
                }
                await withTaskCancellationHandler {
                    await load(opened, cursor: nil)
                    await events.value
                } onCancel: {
                    events.cancel()
                }
                try await opened.close()
            } catch {
                if !Task.isCancelled {
                    loading = false
                    errorMessage(error)
                }
            }
        }
        .onDisappear { nextPage?.cancel() }
    }

    private func load(_ connection: any RuntimeAgentControl, cursor: String?) async {
        loading = true
        needsLogin = false
        error = nil
        do {
            let result = try await connection.list(cursor: cursor)
            guard !Task.isCancelled else { return }
            var seen = Set(sessions.map(\.id))
            sessions.append(contentsOf: result.sessions.filter { seen.insert($0.id).inserted })
            page = result
        } catch {
            if !Task.isCancelled {
                needsLogin = (error as? RuntimeFailure)?.kind == .authentication
                blockedCursor = cursor
                errorMessage(error)
            }
        }
        if !Task.isCancelled { loading = false }
    }

    private func consume(_ event: AgentEvent) {
        switch event {
        case .batch(let events): events.forEach(consume)
        case .interaction(let request): interactions.append(request)
        case .interactionEnded(let id, _): interactions.removeAll { $0.id == id }
        case .failure(let failure): errorMessage(failure)
        default: break
        }
    }

    private func reply(_ answer: InteractionResponse) {
        guard let request = interactions.first, let control else { return }
        replying = true
        Task {
            defer { replying = false }
            do { try await control.respond(to: request, with: answer) }
            catch { errorMessage(error) }
        }
    }

    private func errorMessage(_ failure: Error) {
        error = (failure as? RuntimeFailure)?.detail ?? failure.localizedDescription
    }
}
