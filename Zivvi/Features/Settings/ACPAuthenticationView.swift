import SwiftUI
import AgentRuntimeCore

struct ACPAuthenticationView: View {
    let settings: AppSettings
    let agentID: String
    @Environment(\.dismiss) private var dismiss
    @State private var control: (any RuntimeAgentControl)?
    @State private var authentication: RuntimeAgentAuthentication?
    @State private var operation: Task<Void, Never>?
    @State private var interactions: [RuntimeInteraction] = []
    @State private var notice: String?
    @State private var submitting = false
    @State private var connectionAttempt = 0
    @State private var connecting = true

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            Text("ACP Agent 登录").zivviFont(.title3, weight: .semibold)
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                if let request = interactions.first, let elicitation = request.elicitation {
                    ACPElicitationView(request: request, elicitation: elicitation, submitting: submitting, reply: reply)
                        .id(request.id)
                } else if let control, let authentication {
                    ForEach(authentication.methods) { method in
                        Button {
                            run {
                                try await control.authenticate(methodID: method.id)
                                let refreshed = await control.authentication
                                if self.control != nil, refreshed.connectionID != nil {
                                    self.authentication = refreshed
                                }
                            }
                        } label: {
                            LightningLabel(verbatim: method.name,
                                           icon: method.kind == .terminal ? .terminal : .personCropCircle,
                                           size: 13)
                        }
                        .disabled(operation != nil)
                    }
                    if authentication.canLogout {
                        Button("登出") { run { try await control.logout() } }
                            .disabled(operation != nil)
                    }
                    if authentication.methods.isEmpty {
                        Text("此 Agent 没有提供应用内登录方式。请使用 Agent 自带的登录入口。")
                    }
                }
                if connecting {
                    FlatProgressView("正在读取登录方式…")
                } else if authentication == nil, operation == nil {
                    Button("重试连接") { connectionAttempt += 1 }
                }
                if let notice { Text(notice) }
                if operation != nil {
                    HStack {
                        FlatProgressView()
                        Button("取消操作") { operation?.cancel() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        .padding(22)
        .frame(width: 520)
        .task(id: connectionAttempt) {
            connecting = true
            notice = nil
            clearConnection()
            do {
                let opened = try await settings.openACPControl(agentID: agentID)
                let initial = await opened.authentication
                if !Task.isCancelled {
                    authentication = initial.connectionID == nil ? nil : initial
                    control = opened
                    connecting = false
                    for await envelope in opened.events {
                        guard !Task.isCancelled else { break }
                        if envelope.instanceID == authentication?.connectionID { consume(envelope.event) }
                    }
                    if !Task.isCancelled { clearConnection() }
                }
                try await settings.closeACPAuthenticationControl(opened)
            } catch {
                guard !Task.isCancelled else { return }
                connecting = false
                notice = (error as? RuntimeFailure)?.detail ?? error.localizedDescription
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private func clearConnection() {
        control = nil
        authentication = nil
        interactions = []
    }

    private func consume(_ event: AgentEvent) {
        switch event {
        case .batch(let events): events.forEach(consume)
        case .interaction(let request): interactions.append(request)
        case .interactionEnded(let id, _): interactions.removeAll { $0.id == id }
        case .notice(let message): notice = message
        case .failure(let failure): notice = failure.detail
        case .disconnected:
            authentication = nil
            interactions = []
        default: break
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do {
                try await settings.performACPAuthentication(for: agentID, operation: action)
                try Task.checkCancellation()
                await settings.refreshACPAfterExternalAuthentication(agentID)
                notice = String(localized: "认证操作已完成。")
            } catch is CancellationError {
                notice = String(localized: "认证操作已取消。")
            } catch {
                notice = (error as? RuntimeFailure)?.detail ?? error.localizedDescription
            }
            if let control, !(await control.isConnected) {
                authentication = nil
                interactions = []
            }
        }
    }

    private func reply(_ answer: InteractionResponse) {
        guard let request = interactions.first, let control else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do { try await control.respond(to: request, with: answer) }
            catch { notice = (error as? RuntimeFailure)?.detail ?? error.localizedDescription }
        }
    }
}
