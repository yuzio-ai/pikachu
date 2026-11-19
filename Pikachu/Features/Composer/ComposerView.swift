import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ComposerPermissionsPresentation: Equatable {
    let buttonText: String
    let effectiveMode: AgentMode
    let pendingNextRunMode: AgentMode?
    let statusBadge: String
    let explanation: String
    let secondaryNote: String?

    init(selectedMode: AgentMode, activeMode: AgentMode?, isViewedSessionActive: Bool,
         isConnected: Bool, isActiveRunOrQueue: Bool, isReadOnlyHistory: Bool) {
        if isViewedSessionActive && isConnected {
            let liveMode = activeMode ?? selectedMode
            if isActiveRunOrQueue {
                self.effectiveMode = liveMode
                self.pendingNextRunMode = nil
                self.buttonText = liveMode.permissionSummary
                self.statusBadge = String(localized: "当前执行已生效")
                self.explanation = liveMode.permissionDetail
                self.secondaryNote = String(localized: "运行中或队列未清空时保持当前已生效权限，结束后可调整。")
            } else if let activeMode, activeMode != selectedMode {
                self.effectiveMode = activeMode
                self.pendingNextRunMode = selectedMode
                self.buttonText = String(localized: "\(selectedMode.permissionSummary)（下次执行）")
                self.statusBadge = String(localized: "下次执行生效")
                self.explanation = selectedMode.permissionDetail
                self.secondaryNote = String(localized: "当前空闲连接仍为「\(activeMode.titleText)」；下次发送将重连并应用新权限。")
            } else {
                self.effectiveMode = selectedMode
                self.pendingNextRunMode = nil
                self.buttonText = selectedMode.permissionSummary
                self.statusBadge = String(localized: "已连接生效")
                self.explanation = selectedMode.permissionDetail
                self.secondaryNote = String(localized: "由当前执行模式「\(selectedMode.titleText)」决定，可在模式菜单调整。")
            }
        } else {
            self.effectiveMode = selectedMode
            self.pendingNextRunMode = selectedMode
            self.buttonText = selectedMode.permissionSummary
            self.statusBadge = String(localized: "下次执行生效")
            self.explanation = selectedMode.permissionDetail
            if isReadOnlyHistory {
                self.secondaryNote = String(localized: "当前为只读历史视图；配置将在可执行的下次运行时生效。")
            } else {
                self.secondaryNote = String(localized: "配置将在下次连接并发送时生效，可在模式菜单调整。")
            }
        }
    }
}

struct ComposerView: View {
    @Bindable var controller: SessionController
    let workspace: WorkspaceController
    let agentMode: AgentMode
    let activeMode: AgentMode?
    let isViewedSessionActive: Bool
    let isReadOnlyHistory: Bool
    let modeDisabled: Bool
    let model: ComposerModel?
    var isModelSheetOpen = false
    let onPickFiles: () -> Void
    let onMode: (AgentMode) -> Void
    let onModel: () -> Void
    let onSend: () -> Void
    let sendEnabled: Bool
    var focusSignal = 0
    @FocusState private var focused: Bool
    @State private var showsPermissions = false
    @State private var showsModePicker = false

    private var permissions: ComposerPermissionsPresentation {
        ComposerPermissionsPresentation(
            selectedMode: agentMode,
            activeMode: activeMode,
            isViewedSessionActive: isViewedSessionActive,
            isConnected: controller.connection == .connected,
            isActiveRunOrQueue: controller.phase.isActive || controller.commandPending || !controller.queue.isEmpty || !controller.interactions.isEmpty,
            isReadOnlyHistory: isReadOnlyHistory
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.recoveredDrafts.isEmpty { RecoveredDraftsView(controller: controller) }
            if !controller.queue.isEmpty {
                Text(controller.queueIsKnown ? "等待交付：补充 \(controller.queue.steering.count) · 后续 \(controller.queue.followUp.count)" : "队列状态待核实")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).glassEffect()
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("输入编码任务…", text: $controller.draft, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focused).accessibilityIdentifier("prompt-input")
                    .diagnosticDraw("editor:\(controller.draft.utf8.count)")
                    .accessibilityLabel("当前查看会话的任务草稿")
                    .accessibilityHint("多行输入。Command Return 发送；Command L 聚焦输入。")
                if !controller.draftFiles.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(controller.draftFiles, id: \.self) { file in
                                HStack(spacing: 4) {
                                    Text(file.lastPathComponent).lineLimit(1).help(file.path)
                                    Button {
                                        controller.draftFiles.removeAll { $0 == file }
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("移除 \(file.lastPathComponent)")
                                }
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .glassEffect(in: .capsule)
                            }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("draft-files")
                }
                if controller.phase.isActive {
                    Picker("发送方式", selection: $controller.mode) {
                        Text("补充当前任务").tag(SendMode.steer)
                        Text("完成后执行").tag(SendMode.followUp)
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                    .fixedSize()
                    .accessibilityIdentifier("send-mode")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        attachmentButton
                        modeMenu
                        permissionsButton
                        modelButton
                            .frame(minWidth: 110, alignment: .leading)
                        Spacer(minLength: 4)
                        UsageView(controller: controller, workspace: workspace)
                        if controller.commandPending { ProgressView().controlSize(.small) }
                        sendButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            attachmentButton
                            modeMenu
                            permissionsButton
                            modelButton
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            UsageView(controller: controller, workspace: workspace, compactNumbers: true)
                            if controller.commandPending { ProgressView().controlSize(.small) }
                            sendButton
                        }
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focused ? Color.accentColor : Color.clear)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
        .onChange(of: controller.connection) { _, state in if state == .connected { focused = true } }
        .onChange(of: focusSignal) { _, _ in focused = true }
        .onChange(of: modeDisabled) { _, disabled in
            if disabled { showsModePicker = false }
        }
    }

    private var attachmentButton: some View {
        Button(action: onPickFiles) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(ComposerControlButtonStyle(isOpen: false))
        .fixedSize()
        .help("添加文件")
        .accessibilityLabel("添加文件")
        .accessibilityIdentifier("add-file")
    }

    private var modeMenu: some View {
        Button {
            showsModePicker.toggle()
        } label: {
            Text(agentMode.title)
        }
        .buttonStyle(ComposerControlButtonStyle(isOpen: showsModePicker))
        .fixedSize()
        .disabled(modeDisabled)
        .help(modeDisabled ? "运行或保存期间不可切换执行模式" : "切换执行模式（影响工具权限）")
        .accessibilityLabel("执行模式")
        .accessibilityValue(Text(agentMode.title))
        .accessibilityIdentifier("agent-mode")
        .popover(isPresented: $showsModePicker, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(AgentMode.allCases) { mode in
                    Button {
                        showsModePicker = false
                        onMode(mode)
                    } label: {
                        HStack(spacing: 12) {
                            Text(mode.title)
                            Spacer(minLength: 0)
                            if mode == agentMode {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(ComposerControlButtonStyle(isOpen: false))
                    .accessibilityAddTraits(mode == agentMode ? .isSelected : [])
                }
            }
            .font(.callout)
            .padding(6)
            .frame(width: 120)
        }
    }

    private var permissionsButton: some View {
        let info = permissions
        return Button {
            showsPermissions.toggle()
        } label: {
            Text(info.buttonText)
                .foregroundStyle(.primary)
        }
        .buttonStyle(ComposerControlButtonStyle(isOpen: showsPermissions))
        .fixedSize()
        .help(info.explanation)
        .accessibilityLabel("权限")
        .accessibilityValue("\(info.buttonText)，\(info.statusBadge)")
        .accessibilityIdentifier("composer-permissions")
        .popover(isPresented: $showsPermissions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("工具权限", systemImage: "shield")
                        .font(.headline)
                    Spacer()
                    Text(info.statusBadge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(info.explanation)
                    .font(.callout)
                if let note = info.secondaryNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 310, alignment: .leading)
        }
    }

    private var modelButton: some View {
        Button(action: onModel) {
            HStack(spacing: 5) {
                if let model {
                    ProviderLogo(provider: model.provider)
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let thinking = model.thinking {
                        Text(thinking)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if model.pending {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                } else {
                    Image(systemName: "cpu")
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    Text("模型…")
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(ComposerControlButtonStyle(isOpen: isModelSheetOpen))
        .help(model?.summary ?? "模型与推理强度")
        .accessibilityLabel("模型与推理强度")
        .accessibilityValue(model?.summary ?? "未配置")
        .accessibilityIdentifier("composer-model")
        .disabled(workspace.busy)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sendEnabled ? Color.black : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(sendEnabled ? PikachuTheme.lightningYellow : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .help("发送（⌘Return）")
        .accessibilityLabel("发送")
        .disabled(!sendEnabled)
        .accessibilityIdentifier("send-prompt")
    }
}

extension AgentMode {
    var title: LocalizedStringResource {
        switch self {
        case .interactive: "交互"
        case .plan: "计划"
        case .automatic: "自动"
        }
    }

    var titleText: String {
        switch self {
        case .interactive: String(localized: "交互")
        case .plan: String(localized: "计划")
        case .automatic: String(localized: "自动")
        }
    }

    var permissionSummary: String {
        switch self {
        case .interactive: String(localized: "需确认")
        case .plan: String(localized: "仅读工具")
        case .automatic: String(localized: "运行时配置")
        }
    }

    var permissionDetail: String {
        switch self {
        case .interactive: String(localized: "内置编辑、写入和命令工具逐项确认。读取和搜索可用。")
        case .plan: String(localized: "仅提供读取及搜索工具。适用范围为工具能力。")
        case .automatic: String(localized: "按当前 Pi 配置和所选扩展运行，工具权限以运行环境为准。")
        }
    }
}

struct ComposerModel {
    let provider: String
    let name: String
    let thinking: String?
    let pending: Bool
    var summary: String {
        ([provider, name] + (thinking.map { [$0] } ?? []) + (pending ? ["待应用"] : [])).joined(separator: " · ")
    }
}

struct ProviderLogo: View {
    let provider: String
    private static let names = [
        "openai": "openai", "openai-codex": "openai",
        "anthropic": "anthropic",
        "google": "googlegemini", "google-vertex": "googlegemini", "google-gemini-cli": "googlegemini",
    ]
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in Set(names.values) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            images[name] = image
        }
        return images
    }()

    var body: some View {
        Group {
            if let name = Self.names[provider.lowercased()], let image = Self.images[name] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "cpu")
            }
        }.frame(width: 13, height: 13).accessibilityHidden(true)
    }
}

struct RecoveredDraftsView: View {
    let controller: SessionController
    var body: some View {
        DisclosureGroup("保留的待发送内容（\(controller.recoveredDrafts.count)）") {
            ForEach(controller.recoveredDrafts) { draft in
                HStack {
                    VStack(alignment: .leading) {
                        if !draft.text.isEmpty { Text(draft.text).lineLimit(2) }
                        if let files = draft.files { Text(files.map(\.lastPathComponent).joined(separator: "、")).lineLimit(1) }
                    }.font(.caption)
                    Spacer()
                    Button("放入输入框") { controller.restoreDraft(draft.id) }.font(.caption)
                }.padding(.vertical, 4)
            }
        }
        .buttonStyle(.glass).font(.caption)
        .padding(8).glassEffect(in: .rect(cornerRadius: 9))
    }
}
