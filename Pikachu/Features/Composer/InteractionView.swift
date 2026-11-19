import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

enum WorkbenchModal: Identifiable {
    case configuration(SessionReference)
    case interaction(RuntimeInteraction, SessionController, String)
    case runtimeSettings
    var id: String {
        switch self {
        case .configuration(let reference): "configuration:\(reference.id)"
        case .interaction(let request, _, _): request.id
        case .runtimeSettings: "runtime-settings"
        }
    }
}

struct PendingInteractionBar: View {
    let workspace: WorkspaceController
    let present: () -> Void
    var body: some View {
        if let active = workspace.active, !active.interactions.isEmpty {
            HStack {
                Image(systemName: "questionmark.bubble")
                Text("执行会话有 \(active.interactions.count) 个扩展请求等待回复。").font(.callout)
                Spacer()
                Button("处理交互", action: present)
                    .buttonStyle(.glass).keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .padding(10)
            .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.bottom, 6)
            .accessibilityIdentifier("pending-interaction")
        }
    }
}

struct InteractionView: View {
    let request: RuntimeInteraction
    let controller: SessionController
    let sessionTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var selection: Int?
    @State private var completed = false
    @State private var submitting = false
    @FocusState private var focused: Bool
    private let options: [Choice]
    private struct Choice: Identifiable { let id: Int; let text: String }
    init(request: RuntimeInteraction, controller: SessionController, sessionTitle: String) {
        self.request = request; self.controller = controller; self.sessionTitle = sessionTitle
        _text = State(initialValue: request.prefill)
        options = request.options.enumerated().map { Choice(id: $0.offset, text: $0.element) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扩展请求").font(.caption).foregroundStyle(.secondary)
            Text(request.title).font(.title2).textSelection(.enabled)
            Text("会话：\(sessionTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !request.message.isEmpty {
                ScrollView {
                    Text(request.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8).glassEffect(in: .rect(cornerRadius: 9))
            }
            switch request.kind {
            case .select:
                List(options, selection: $selection) { option in Text(option.text).tag(option.id) }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 260)
                    .padding(2).glassEffect(in: .rect(cornerRadius: 9))
                    .accessibilityLabel("扩展提供的选项")
            case .input:
                TextField(request.placeholder.isEmpty ? "回复内容" : request.placeholder, text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .padding(8).glassEffect(in: .rect(cornerRadius: 9))
                    .accessibilityIdentifier("interaction-input").accessibilityLabel("扩展单行回复")
            case .editor:
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 220)
                    .scrollContentBackground(.hidden).focused($focused)
                    .padding(8).glassEffect(in: .rect(cornerRadius: 9))
                    .accessibilityIdentifier("interaction-editor").accessibilityLabel("扩展多行回复")
                Text("Return 换行，Command Return 提交。文本上限 1 MiB。").font(.caption).foregroundStyle(.secondary)
            case .confirm: EmptyView()
            }
            if let message = controller.notice { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = controller.failure { Text(error.detail).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消", role: .cancel) { submit(.cancelled) }.keyboardShortcut(.cancelAction)
                Button("停止任务") { Task { await controller.stop() } }
                    .keyboardShortcut(".", modifiers: .command).disabled(!controller.canStop)
                Spacer()
                if submitting { ProgressView().controlSize(.small) }
                if request.kind == .confirm {
                    Button("否") { submit(.confirmed(false)) }.accessibilityIdentifier("interaction-no")
                    Button("是") { submit(.confirmed(true)) }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("interaction-yes")
                } else {
                    Button("提交") {
                        if request.kind == .select, let selection { submit(.value(options[selection].text)) }
                        else { submit(.value(text)) }
                    }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: request.kind == .editor ? .command : [])
                        .disabled(request.kind == .select && selection == nil).accessibilityIdentifier("interaction-submit")
                }
            }.buttonStyle(.glass).disabled(submitting)
        }.padding(24).frame(width: 560)
        .interactiveDismissDisabled(submitting)
        .task(id: request.id) { await Task.yield(); focused = request.kind == .input || request.kind == .editor }
        .onDisappear { if !completed { Task { await controller.reply(request, .cancelled) } } }
    }
    private func submit(_ response: InteractionResponse) {
        submitting = true
        Task {
            let accepted = await controller.reply(request, response)
            submitting = false
            if accepted { completed = true; dismiss() }
        }
    }
}
