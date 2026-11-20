import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ComposerApprovalPresentation: Equatable {
    let effective: AgentExecutionPolicy
    let pending: AgentExecutionPolicy?
    let status: String
    let note: String?

    var displayed: AgentExecutionPolicy { pending ?? effective }
    var buttonText: String {
        if pending != nil, pending != effective {
            return String(localized: "\(displayed.approval.titleText)（下次执行）")
        }
        return displayed.approval.titleText
    }

    init(selected: AgentExecutionPolicy, active: AgentExecutionPolicy?, isRunning: Bool, isReadOnlyHistory: Bool) {
        effective = active ?? selected
        if isRunning {
            pending = nil
            status = String(localized: "当前执行已生效")
            note = String(localized: "任务和队列结束后可调整工具审批。")
        } else if active == selected {
            pending = nil
            status = String(localized: "已连接生效")
            note = nil
        } else {
            pending = selected
            status = String(localized: "下次执行生效")
            if let active {
                let mode = String(localized: active.mode.title)
                note = String(localized: "当前连接使用「\(mode) · \(active.approval.titleText)」，下次发送时重连。")
            } else if isReadOnlyHistory {
                note = String(localized: "当前为只读历史视图；配置将在可执行的下次运行时生效。")
            } else {
                note = nil
            }
        }
    }
}

private struct ComposerIssuePills: View {
    let controller: SessionController
    let panelsBlocked: Bool
    let presentToolFailures: ([TranscriptItem]) -> Void
    @State private var dismissedFailureIDs: Set<String> = []
    @State private var isHoveringFailure = false
    @FocusState private var dismissFocused: Bool

    var body: some View {
        let items = controller.transcript.reversed()
        let hasExpiredInteraction = items.contains { $0.expiredInteraction != nil }
        let failures = items.filter { $0.toolSummary?.state == .failed && !dismissedFailureIDs.contains($0.id) }
        if hasExpiredInteraction || !failures.isEmpty {
            HStack(spacing: 6) {
                if hasExpiredInteraction {
                    pillLabel("扩展交互已过期")
                        .flatSurface(.clear, radius: 16)
                        .accessibilityIdentifier("composer-expired-interaction")
                }
                if !failures.isEmpty { failurePill(failures) }
            }
            .padding(.bottom, 8)
        }
    }

    private func pillLabel(_ title: LocalizedStringKey, color: Color = PikachuTheme.warningText) -> some View {
        Text(title)
            .pikachuFont(.callout)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func failurePill(_ failures: [TranscriptItem]) -> some View {
        let showsClose = isHoveringFailure || dismissFocused
        return ZStack(alignment: .trailing) {
            Button { presentToolFailures(failures) } label: {
                pillLabel("工具调用失败", color: PikachuTheme.mutedWarningText)
                    .padding(.trailing, showsClose ? 13 : 0)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 16))
            .accessibilityIdentifier("composer-failed-tool")

            Button {
                dismissedFailureIDs.formUnion(failures.map(\.id))
                isHoveringFailure = false
            } label: {
                Image(systemName: "xmark")
                    .pikachuFont(.caption2)
                    .foregroundStyle(PikachuTheme.tertiaryText)
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 9))
            .focused($dismissFocused)
            .help("关闭工具调用失败提示")
            .accessibilityLabel("关闭工具调用失败提示")
            .accessibilityIdentifier("dismiss-composer-failed-tool")
            .padding(.trailing, 4)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
        }
        .contentShape(.rect)
        .onHover { isHoveringFailure = $0 }
        .disabled(panelsBlocked)
    }
}

struct ComposerView: View {
    @Environment(\.pikachuTypography) private var typography
    @Bindable var controller: SessionController
    let workspace: WorkspaceController
    let executionPolicy: AgentExecutionPolicy
    let activePolicy: AgentExecutionPolicy?
    let isViewedSessionActive: Bool
    let isReadOnlyHistory: Bool
    let modeDisabled: Bool
    let model: ComposerModel?
    let reference: SessionReference?
    let project: ProjectRecord?
    let panelsBlocked: Bool
    let onPickFiles: () -> Void
    let onMode: (AgentMode) -> Void
    let onApproval: (ToolApprovalPolicy) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let presentToolFailures: ([TranscriptItem]) -> Void
    let sendEnabled: Bool
    var focusSignal = 0
    var isStarter = false
    var pastedImagesDirectory: URL = AppSettings.defaultPastedImagesDirectory(stateDirectory: nil)
    @FocusState private var focused: Bool
    @FocusState private var modelFocused: Bool
    @FocusState private var sendModeFocused: Bool
    @State private var panel: Panel?
    @State private var savingModel = false
    @State private var restoreInputFocus = false
    @State private var imagePasteFailed = false

    private enum Panel { case mode, approval, context, model, sendMode, workingDirectory }

    private var showsStopButton: Bool {
        isViewedSessionActive && controller.connection == .connected &&
            (controller.isStopping || (controller.phase != .uncertain &&
                (controller.phase.isActive || !controller.queue.isEmpty)))
    }

    private var canConfigureModel: Bool {
        reference.map { !workspace.isOperating(on: $0.id) } == true && !panelsBlocked
    }

    private func setPanel(_ value: Panel?) {
        if value != panel, value == .model || value == .sendMode {
            restoreInputFocus = focused
        }
        panel = value
        if workspace.usageExpanded != (value == .context) {
            workspace.usageExpanded = value == .context
        }
    }

    private func show(_ value: Panel) {
        guard !panelsBlocked, !savingModel else { return }
        setPanel(value)
    }

    private func panelBinding(_ value: Panel) -> Binding<Bool> {
        Binding(get: { panel == value }, set: { presented in
            if presented {
                show(value)
            } else if panel == value && !(value == .model && savingModel) {
                setPanel(nil)
            }
        })
    }

    private var approvalPresentation: ComposerApprovalPresentation {
        ComposerApprovalPresentation(
            selected: executionPolicy,
            active: isViewedSessionActive && controller.connection == .connected ? activePolicy : nil,
            isRunning: isViewedSessionActive && controller.connection == .connected &&
                (controller.phase.isActive || controller.commandPending || !controller.queue.isEmpty || !controller.interactions.isEmpty),
            isReadOnlyHistory: isReadOnlyHistory
        )
    }

    var body: some View {
        let images = controller.draftFiles.filter(ImageAttachmentThumbnail.isImage)
        let imageSet = Set(images)
        let files = controller.draftFiles.filter { !imageSet.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            if !controller.recoveredDrafts.isEmpty {
                RecoveredDraftsView(controller: controller).padding(.bottom, 10)
            }
            HStack(spacing: 6) {
                if showsStopButton { sendModeMenu.padding(.bottom, 8) }
                ComposerIssuePills(controller: controller, panelsBlocked: panelsBlocked,
                                   presentToolFailures: presentToolFailures)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(images, id: \.self) { file in
                                ImageAttachmentThumbnail(file: file) { removeAttachment(file) }
                            }
                        }
                    }
                    .accessibilityIdentifier("draft-images")
                }
                TextField("⚡️Pika! 告诉我你想实现什么、修复什么，或直接提问…", text: $controller.draft, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: isStarter ? 44 : 0, alignment: .topLeading)
                    .focused($focused).accessibilityIdentifier("prompt-input")
                    .diagnosticDraw("editor:\(controller.draft.utf8.count)")
                    .accessibilityLabel("当前查看会话的任务草稿")
                    .accessibilityHint("按 ↩ 或 ⇧↩ 换行，按 ⌘↩ 发送，按 ⌘V 粘贴图片，按 ⌘L 聚焦输入框。")
                    .background {
                        ComposerInputEvents(isFocused: $focused, canPasteImage: !panelsBlocked, canSend: sendEnabled,
                                            onPaste: addPastedImage, onSend: onSend)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                if imagePasteFailed {
                    Text("无法添加剪贴板图片，请重新复制后再试。")
                        .pikachuFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if !files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(files, id: \.self) { file in
                                HStack(spacing: 4) {
                                    Text(file.lastPathComponent).lineLimit(1).help(file.path)
                                    Button {
                                        removeAttachment(file)
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(FlatControlButtonStyle(inset: false))
                                    .accessibilityLabel("移除 \(file.lastPathComponent)")
                                }
                                .pikachuFont(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(PikachuTheme.mutedSurface, in: .capsule)
                            }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("draft-files")
                }
                if showsStopButton {
                    Button("发送", action: onSend)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .pikachuFont(.caption)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送（⌘↩）")
                        .disabled(!sendEnabled)
                        .accessibilityIdentifier("send-prompt")
                }
                ComposerControlsLayout {
                    HStack(spacing: 4) {
                        attachmentButton
                        modeMenu
                        approvalButton
                        if let reference, let project {
                            ComposerWorkingDirectoryButton(workspace: workspace, reference: reference, project: project,
                                                           isPresented: panelBinding(.workingDirectory), panelsBlocked: panelsBlocked)
                        }
                    }
                    HStack(spacing: 4) {
                        if controller.commandPending { FlatProgressView().controlSize(.small) }
                        UsageView(controller: controller, isPresented: panelBinding(.context))
                        modelButton.frame(maxWidth: 220)
                        if showsStopButton { stopButton }
                        else { sendButton }
                    }
                }
                .pikachuFont(.caption)
                .lineLimit(1)
            }
            .padding(12)
            .padding(.vertical, isStarter ? 5 : 0)
            .flatSurface(radius: 14, border: PikachuTheme.inputBorder(focused: focused))
        }
        .padding(.top, 4).padding(.bottom, 12)
        .onChange(of: controller.connection) { _, state in if state == .connected { focused = true } }
        .onChange(of: focusSignal) { _, _ in focused = true }
        .onChange(of: modeDisabled) { _, disabled in
            if disabled && panel == .mode { setPanel(nil) }
        }
        .onChange(of: panelsBlocked) { _, blocked in
            if blocked { setPanel(nil) }
        }
        .onChange(of: showsStopButton) { _, visible in
            if !visible && panel == .sendMode { setPanel(nil) }
        }
        .onChange(of: workspace.usageExpanded, initial: true) { _, expanded in
            if expanded, panelsBlocked || savingModel {
                workspace.usageExpanded = panel == .context
            } else if expanded {
                show(.context)
            } else if panel == .context {
                setPanel(nil)
            }
        }
        .onChange(of: workspace.configurationRequest) { _, _ in
            if canConfigureModel { show(.model) }
        }
        .onChange(of: panel) { previous, current in
            guard current == nil, !panelsBlocked else { return }
            switch previous {
            case .model:
                if restoreInputFocus { focused = true }
                else { modelFocused = true }
            case .sendMode:
                if restoreInputFocus { focused = true }
                else if showsStopButton { sendModeFocused = true }
            default:
                break
            }
        }
    }

    private var sendModeMenu: some View {
        Button {
            panelBinding(.sendMode).wrappedValue.toggle()
        } label: {
            sendModeTitle(controller.mode, compact: true)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, isOpen: panel == .sendMode, inset: false, cornerRadius: 16))
        .pikachuFont(.callout)
        .lineLimit(1)
        .fixedSize()
        .focused($sendModeFocused)
        .disabled(panelsBlocked || savingModel)
        .accessibilityLabel("发送方式")
        .accessibilityValue(sendModeTitle(controller.mode))
        .accessibilityIdentifier("send-mode")
        .popover(isPresented: panelBinding(.sendMode), arrowEdge: .bottom) {
            FlatMenuPanel(width: 218) {
                ForEach(SendMode.allCases) { mode in
                    let selected = controller.mode == mode
                    Button {
                        guard panel == .sendMode, showsStopButton, !panelsBlocked,
                              workspace.viewed?.controller === controller else { return }
                        controller.mode = mode
                        setPanel(nil)
                    } label: {
                        FlatMenuRow(title: sendModeTitle(mode), selected: selected)
                    }
                    .buttonStyle(FlatControlButtonStyle(isOpen: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .onExitCommand { setPanel(nil) }
        }
    }

    private func sendModeTitle(_ mode: SendMode, compact: Bool = false) -> Text {
        switch (mode, compact) {
        case (.steer, true): Text("中途调整")
        case (.followUp, true): Text("排队执行")
        case (.steer, false): Text("调整当前任务描述")
        case (.followUp, false): Text("当前任务完成后继续")
        }
    }

    private func removeAttachment(_ file: URL) {
        controller.draftFiles.removeAll { $0 == file }
        let referenced = controller.draftFiles
            + controller.recoveredDrafts.flatMap { $0.files ?? [] }
            + controller.transcript.flatMap(\.editableFiles)
            + (reference?.submissions.flatMap { $0.files ?? [] } ?? [])
        ClipboardImage.removeUnusedPastedFile(file, in: pastedImagesDirectory, referenced: referenced)
    }

    private func addPastedImage(_ image: ClipboardImage) {
        do {
            let file = try image.save(in: pastedImagesDirectory)
            controller.draftFiles.append(file)
            imagePasteFailed = false
        } catch {
            imagePasteFailed = true
        }
    }

    private var attachmentButton: some View {
        Button(action: onPickFiles) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(FlatControlButtonStyle())
        .fixedSize()
        .help("添加文件")
        .accessibilityLabel("添加文件")
        .accessibilityIdentifier("add-file")
    }

    private var modeMenu: some View {
        Button {
            panelBinding(.mode).wrappedValue.toggle()
        } label: {
            Text(executionPolicy.mode.title)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .mode))
        .fixedSize()
        .disabled(modeDisabled || panelsBlocked)
        .help(modeDisabled ? "运行或保存期间不可切换执行模式" : "切换执行模式")
        .accessibilityLabel("执行模式")
        .accessibilityValue(Text(executionPolicy.mode.title))
        .accessibilityIdentifier("agent-mode")
        .popover(isPresented: panelBinding(.mode), arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(AgentMode.allCases) { mode in
                    Button {
                        setPanel(nil)
                        onMode(mode)
                    } label: {
                        HStack(spacing: 12) {
                            Text(mode.title)
                            Spacer(minLength: 0)
                            if mode == executionPolicy.mode {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(isOpen: mode == executionPolicy.mode))
                    .accessibilityAddTraits(mode == executionPolicy.mode ? .isSelected : [])
                }
            }
            .pikachuFont(.callout)
            .padding(6)
            .frame(width: 144)
            .flatPanelContent()
        }
    }

    private var approvalButton: some View {
        let info = approvalPresentation
        return Button {
            panelBinding(.approval).wrappedValue.toggle()
        } label: {
            Text(info.buttonText)
                .foregroundStyle(.primary)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .approval))
        .fixedSize()
        .help(Text(info.displayed.approval.detail))
        .accessibilityLabel("工具审批")
        .accessibilityValue("\(info.buttonText)，\(info.status)")
        .accessibilityIdentifier("composer-permissions")
        .disabled(panelsBlocked)
        .popover(isPresented: panelBinding(.approval), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("工具审批", systemImage: "shield")
                        .pikachuFont(.headline)
                    Spacer()
                    Text(info.status)
                        .pikachuFont(.caption)
                        .foregroundStyle(PikachuTheme.secondaryText)
                }
                if info.displayed.mode == .automatic {
                    Text(ToolApprovalPolicy.never.title)
                        .pikachuFont(.callout, weight: .semibold)
                    Text("自主执行使用无需审批。所选扩展可以发起自己的交互。")
                        .pikachuFont(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(info.displayed.mode.availableApprovals) { option in
                        Button {
                            setPanel(nil)
                            onApproval(option)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title).pikachuFont(.callout, weight: .medium)
                                    Text(option.detail).pikachuFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if option == info.displayed.approval {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(FlatControlButtonStyle(isOpen: option == info.displayed.approval))
                        .accessibilityAddTraits(option == info.displayed.approval ? .isSelected : [])
                        .accessibilityIdentifier("tool-approval-\(option.rawValue)")
                        .disabled(modeDisabled)
                    }
                    if info.displayed.mode == .plan {
                        Text("制定计划只开放读取、搜索、查找和列目录。")
                            .pikachuFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = info.note {
                    Text(note)
                        .pikachuFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 324, alignment: .leading)
            .flatPanelContent()
        }
    }

    private var modelButton: some View {
        Button {
            panelBinding(.model).wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                if let model {
                    ProviderLogo(provider: model.provider)
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let thinking = model.thinkingLabel {
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
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .model))
        .focused($modelFocused)
        .help(model?.summary ?? String(localized: "模型与推理强度（⇧⌘M）"))
        .accessibilityLabel("模型与推理强度")
        .accessibilityValue(model?.summary ?? String(localized: "未配置"))
        .accessibilityIdentifier("composer-model")
        .disabled(!canConfigureModel)
        .popover(isPresented: panelBinding(.model), arrowEdge: .bottom) {
            if let reference {
                ModelConfigurationPanel(workspace: workspace, reference: reference, saving: $savingModel) {
                    setPanel(nil)
                }
                .lineLimit(nil)
            }
        }
    }

    private var sendButton: some View {
        let buttonSize = typography.composerActionButtonSize
        return Button(action: onSend) {
            Image(systemName: "arrow.up")
                .pikachuFont(.body, weight: .semibold)
                .foregroundStyle(sendEnabled ? Color.black : Color.secondary)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle()
                        .fill(sendEnabled ? PikachuTheme.lightningYellow : PikachuTheme.mutedSurface)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .help("发送（⌘↩）")
        .accessibilityLabel("发送")
        .disabled(!sendEnabled)
        .accessibilityIdentifier("send-prompt")
    }

    private var stopButton: some View {
        let buttonSize = typography.composerActionButtonSize
        let stopping = controller.isStopping
        let enabled = !stopping && reference.map { workspace.canStop($0.id) } == true
        return Button(action: onStop) {
            Image(systemName: "stop.fill")
                .pikachuFont(.callout, weight: .semibold)
                .foregroundStyle(enabled ? Color.black : Color.secondary)
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(enabled ? PikachuTheme.lightningYellow : PikachuTheme.mutedSurface))
        }
        .buttonStyle(.plain)
        .help(stopping ? Text("正在停止") : Text("停止（⌘.）"))
        .accessibilityLabel(stopping ? Text("正在停止") : Text("停止"))
        .accessibilityIdentifier("stop-run")
        .disabled(!enabled)
    }
}

/// Keeps both control groups mounted so moving the model button to the next row
/// does not replace its focus target or popover anchor.
private struct ComposerControlsLayout: Layout {
    private let spacing: CGFloat = 6

    private func measure(_ subviews: Subviews, width: CGFloat?) -> (leading: CGSize, trailing: CGSize, width: CGFloat, wraps: Bool) {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let idealTrailing = subviews[1].sizeThatFits(.unspecified)
        let idealWidth = leading.width + spacing + idealTrailing.width
        let available = width ?? idealWidth
        let wraps = idealWidth > available
        let trailing = wraps ? subviews[1].sizeThatFits(.init(width: available, height: nil)) : idealTrailing
        return (leading, trailing, available, wraps)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews, width: proposal.width)
        let height = sizes.wraps ? sizes.leading.height + spacing + sizes.trailing.height
                                 : max(sizes.leading.height, sizes.trailing.height)
        return CGSize(width: sizes.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, width: bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: sizes.wraps ? bounds.minY : bounds.midY - sizes.leading.height / 2),
                          proposal: ProposedViewSize(sizes.leading))
        let trailingY = sizes.wraps ? bounds.minY + sizes.leading.height + spacing : bounds.midY - sizes.trailing.height / 2
        subviews[1].place(at: CGPoint(x: bounds.maxX - sizes.trailing.width, y: trailingY),
                          proposal: ProposedViewSize(sizes.trailing))
    }
}

extension AgentMode {
    var title: LocalizedStringResource {
        switch self {
        case .plan: "制定计划"
        case .interactive: "交互执行"
        case .automatic: "自主执行"
        }
    }
}

private extension ToolApprovalPolicy {
    var title: LocalizedStringResource {
        switch self {
        case .everyCall: "每次审批"
        case .mutations: "工具审批"
        case .never: "无需审批"
        }
    }

    var titleText: String { String(localized: title) }

    var detail: LocalizedStringResource {
        switch self {
        case .everyCall: "每次调用工具前都询问，包括读取和搜索。"
        case .mutations: "修改文件或运行命令时询问。"
        case .never: "启用的工具可直接执行。"
        }
    }
}

struct ComposerModel {
    let provider: String
    let name: String
    let thinking: String?
    let pending: Bool
    var thinkingLabel: String? { thinking.map(ReasoningLevelLabel.text(for:)) }

    var summary: String {
        ([provider, name] + (thinkingLabel.map { [$0] } ?? []) + (pending ? [String(localized: "待应用")] : [])).joined(separator: " · ")
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
                        if let files = draft.files { Text(files.map(\.lastPathComponent).joined(separator: String(localized: "、"))).lineLimit(1) }
                    }.pikachuFont(.caption)
                    Spacer()
                    Button("放入输入框") { controller.restoreDraft(draft.id) }.pikachuFont(.caption)
                }.padding(.vertical, 4)
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).pikachuFont(.caption)
        .padding(8).flatSurface(PikachuTheme.mutedSurface, radius: 9)
    }
}
