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
    @FocusState private var failureFocus: FailureFocus?

    private enum FailureFocus: Hashable {
        case details, dismiss
    }

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
        let showsClose = !panelsBlocked && (isHoveringFailure || failureFocus != nil)
        return ZStack(alignment: .trailing) {
            Button { presentToolFailures(failures) } label: {
                pillLabel("工具调用失败", color: PikachuTheme.mutedWarningText)
                    .padding(.trailing, 13)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 16))
            .focused($failureFocus, equals: .details)
            .accessibilityIdentifier("composer-failed-tool")
            .accessibilityActions {
                if !panelsBlocked {
                    Button("关闭工具调用失败提示") { dismiss(failures) }
                }
            }

            Button { dismiss(failures) } label: {
                Image(systemName: "xmark")
                    .pikachuFont(.caption)
                    .foregroundStyle(PikachuTheme.tertiaryText)
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 9))
            .focused($failureFocus, equals: .dismiss)
            .help("关闭工具调用失败提示")
            .accessibilityLabel("关闭工具调用失败提示")
            .accessibilityIdentifier("dismiss-composer-failed-tool")
            .padding(.trailing, 4)
            .revealedAction(showsClose)
        }
        .contentShape(.rect)
        .onHover { isHoveringFailure = $0 }
        .onDisappear { isHoveringFailure = false }
        .disabled(panelsBlocked)
    }

    private func dismiss(_ failures: [TranscriptItem]) {
        guard !panelsBlocked else { return }
        dismissedFailureIDs.formUnion(failures.map(\.id))
        isHoveringFailure = false
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
    let sessionConfigurationDisabled: Bool
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
    @State private var previewImage: AttachmentImagePreview.Selection?

    private enum Panel {
        case mode, approval, context, model, sendMode, workingDirectory

        var configuresSession: Bool {
            switch self {
            case .mode, .approval, .model, .workingDirectory: true
            case .context, .sendMode: false
            }
        }
    }

    private var showsStopButton: Bool {
        isViewedSessionActive && controller.connection == .connected &&
            (controller.isStopping || (controller.phase != .uncertain &&
                (controller.phase.isActive || !controller.queue.isEmpty)))
    }

    private var canConfigureModel: Bool {
        reference != nil && !sessionConfigurationDisabled && !panelsBlocked
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
        guard !panelsBlocked, !savingModel,
              !value.configuresSession || !sessionConfigurationDisabled else { return }
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

    private var composerContent: some View {
        let images = controller.draftFiles.filter(ImageAttachmentThumbnail.isImage)
        let imageSet = Set(images)
        let files = controller.draftFiles.filter { !imageSet.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            if !controller.recoveredDrafts.isEmpty {
                RecoveredDraftsView(controller: controller).padding(.bottom, 10)
            }
            ComposerIssuePills(controller: controller, panelsBlocked: panelsBlocked,
                               presentToolFailures: presentToolFailures)
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(images, id: \.self) { file in
                                ImageAttachmentThumbnail(file: file, onPreview: {
                                    previewImage = .init(file: file)
                                }, remove: { removeAttachment(file) })
                            }
                        }
                    }
                    .accessibilityIdentifier("draft-images")
                }
                editorRow
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
                ComposerControlsLayout {
                    HStack(spacing: 4) {
                        attachmentButton
                        modeMenu
                        approvalButton
                        if let reference, let project {
                            ComposerWorkingDirectoryButton(workspace: workspace, reference: reference, project: project,
                                                           isPresented: panelBinding(.workingDirectory),
                                                           disabled: sessionConfigurationDisabled || panelsBlocked)
                        }
                    }
                    HStack(spacing: 4) {
                        if controller.commandPending {
                            InfinityLoadingIcon()
                                .foregroundStyle(.secondary)
                                .accessibilityRepresentation { ProgressView() }
                        }
                        UsageView(controller: controller, isPresented: panelBinding(.context))
                        modelButton.frame(maxWidth: 220)
                        if showsStopButton { stopButton }
                        else { sendButton }
                    }
                }
                .pikachuFont(.caption)
                .lineLimit(1)
                .padding(.top, 5) // 13 pt after the editor or attachment row, including the stack spacing.
            }
            .padding(12)
            .padding(.vertical, isStarter ? 5 : 0)
            .flatSurface(radius: 14, border: PikachuTheme.inputBorder(focused: focused))
        }
        .padding(.top, 4).padding(.bottom, 12)
    }

    var body: some View {
        composerContent
        .sheet(item: $previewImage) { selection in
            AttachmentImagePreview(file: selection.file)
        }
        .onChange(of: controller.connection) { _, state in if state == .connected { focused = true } }
        .onChange(of: focusSignal) { _, _ in focused = true }
        .onChange(of: sessionConfigurationDisabled) { _, disabled in
            if disabled, panel?.configuresSession == true, !savingModel { setPanel(nil) }
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
                if restoreInputFocus || !canConfigureModel { focused = true }
                else { modelFocused = true }
            case .sendMode:
                if restoreInputFocus { focused = true }
                else if showsStopButton { sendModeFocused = true }
            default:
                break
            }
        }
    }

    private var editorRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsStopButton { sendModeMenu }
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
        }
    }

    private var sendModeMenu: some View {
        Button {
            panelBinding(.sendMode).wrappedValue.toggle()
        } label: {
            sendModeTitle(controller.mode, compact: true)
                .pikachuFont(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, isOpen: panel == .sendMode,
                                            inset: false, cornerRadius: 16))
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
            IconButtonLabel(systemName: "paperclip")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
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
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .mode, height: typography.composerActionButtonSize))
        .fixedSize()
        .disabled(sessionConfigurationDisabled || panelsBlocked)
        .help(sessionConfigurationDisabled ? "运行或保存期间不可切换执行模式" : "切换执行模式")
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
                                    .pikachuFont(.caption, weight: .semibold)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(isOpen: mode == executionPolicy.mode))
                    .accessibilityAddTraits(mode == executionPolicy.mode ? .isSelected : [])
                }
            }
            .anchoredPopoverCard(width: 144, inset: AnchoredCardStyle.compactInset)
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
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .approval, height: typography.composerActionButtonSize))
        .fixedSize()
        .help(Text(info.displayed.approval.detail))
        .accessibilityLabel("工具审批")
        .accessibilityValue("\(info.buttonText)，\(info.status)")
        .accessibilityIdentifier("composer-permissions")
        .disabled(sessionConfigurationDisabled || panelsBlocked)
        .popover(isPresented: panelBinding(.approval), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
                HStack {
                    Label {
                        Text("工具审批").anchoredCardTitle()
                    } icon: {
                        Image(systemName: "shield").pikachuFont(.caption)
                    }
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
                                    Image(systemName: "checkmark")
                                        .pikachuFont(.caption, weight: .semibold)
                                        .accessibilityHidden(true)
                                }
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(FlatControlButtonStyle(isOpen: option == info.displayed.approval))
                        .accessibilityAddTraits(option == info.displayed.approval ? .isSelected : [])
                        .accessibilityIdentifier("tool-approval-\(option.rawValue)")
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
            .anchoredPopoverCard(width: 324)
        }
    }

    private var modelButton: some View {
        Button {
            panelBinding(.model).wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                if let model {
                    ProviderLogo(provider: model.provider)
                        .fixedSize()
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 32)
                    if let thinking = model.thinkingLabel {
                        Text(thinking)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if model.pending {
                        Image(systemName: "clock")
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                } else {
                    ProviderLogo(provider: "")
                    Text("模型…")
                        .fixedSize()
                }
            }
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .model, height: typography.composerActionButtonSize))
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
        Button(action: onSend) {
            primaryActionLabel(
                symbol: "arrow.up",
                tint: sendEnabled ? .black : .secondary,
                fill: sendEnabled ? PikachuTheme.lightningYellow : PikachuTheme.mutedSurface
            )
        }
        .buttonStyle(OverlayFeedbackButtonStyle(shape: Circle()))
        .keyboardShortcut(.return, modifiers: .command)
        .help("发送（⌘↩）")
        .accessibilityLabel("发送")
        .disabled(!sendEnabled)
        .accessibilityIdentifier("send-prompt")
    }

    private var stopButton: some View {
        let stopping = controller.isStopping
        let enabled = !stopping && reference.map { workspace.canStop($0.id) } == true
        return Button(action: onStop) {
            primaryActionLabel(
                symbol: "stop.fill", tint: enabled ? .primary : .secondary,
                fill: PikachuTheme.mutedSurface, border: PikachuTheme.border
            )
        }
        .buttonStyle(OverlayFeedbackButtonStyle(shape: Circle()))
        .help(stopping ? Text("正在停止") : Text("停止（⌘.）"))
        .accessibilityLabel(stopping ? Text("正在停止") : Text("停止"))
        .accessibilityIdentifier("stop-run")
        .disabled(!enabled)
    }

    private func primaryActionLabel(symbol: String, tint: Color, fill: Color, border: Color? = nil) -> some View {
        let targetSize = typography.composerActionButtonSize
        let circleSize = targetSize - 4
        return Image(systemName: symbol)
            .pikachuFont(.callout, weight: .semibold)
            .foregroundStyle(tint)
            .frame(width: circleSize, height: circleSize)
            .background(fill, in: .circle)
            .overlay {
                if let border { Circle().strokeBorder(border, lineWidth: 1) }
            }
            .frame(width: targetSize, height: targetSize)
            .contentShape(Rectangle())
    }
}

/// Reflows the trailing group without replacing any focus targets or popover anchors.
struct ComposerControlsLayout: Layout {
    private let groupGap: CGFloat = 16
    private let rowGap: CGFloat = 6

    private func measure(_ subviews: Subviews, width: CGFloat?) -> (leading: CGSize, trailing: CGSize, width: CGFloat, wraps: Bool) {
        let idealLeading = subviews[0].sizeThatFits(.unspecified)
        let idealTrailing = subviews[1].sizeThatFits(.unspecified)
        let idealWidth = idealLeading.width + groupGap + idealTrailing.width
        let available = width ?? idealWidth
        guard available < idealWidth else { return (idealLeading, idealTrailing, available, false) }

        func fit(_ group: LayoutSubview, width: CGFloat) -> CGSize {
            group.sizeThatFits(.init(width: width, height: nil))
        }
        let minLeading = fit(subviews[0], width: 0).width
        let minTrailing = fit(subviews[1], width: 0).width
        if minLeading + groupGap + minTrailing <= available {
            // Shorten the model label before squeezing the working-directory label.
            let leading = fit(subviews[0], width: min(idealLeading.width, available - groupGap - minTrailing))
            let trailing = fit(subviews[1], width: available - groupGap - leading.width)
            if leading.width + groupGap + trailing.width <= available {
                return (leading, trailing, available, false)
            }
        }

        let rowWidth = max(available, minLeading, minTrailing)
        return (fit(subviews[0], width: rowWidth), fit(subviews[1], width: rowWidth), rowWidth, true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews, width: proposal.width)
        let height = sizes.wraps ? sizes.leading.height + rowGap + sizes.trailing.height
                                 : max(sizes.leading.height, sizes.trailing.height)
        return CGSize(width: sizes.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, width: bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: sizes.wraps ? bounds.minY : bounds.midY - sizes.leading.height / 2),
                          proposal: ProposedViewSize(sizes.leading))
        let trailingY = sizes.wraps ? bounds.minY + sizes.leading.height + rowGap : bounds.midY - sizes.trailing.height / 2
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
    private static let frameSide: CGFloat = 13
    private static let defaultSide: CGFloat = 12

    /// Visible marks sit in one optical band next to 13 pt text, so wide or
    /// thin-stroked marks may fill the whole frame instead of the default 12 pt.
    private struct Mark {
        let asset: String
        let side: CGFloat
    }
    private static let marks: [String: Mark] = [
        "openai": .init(asset: "openai", side: defaultSide), "openai-codex": .init(asset: "openai", side: defaultSide),
        "anthropic": .init(asset: "anthropic", side: defaultSide),
        // The whale reads smaller than square marks; it needs the full frame.
        "deepseek": .init(asset: "deepseek", side: frameSide),
        "google": .init(asset: "googlegemini", side: frameSide), "google-vertex": .init(asset: "googlegemini", side: frameSide),
        "google-gemini-cli": .init(asset: "googlegemini", side: frameSide),
    ]
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in Set(marks.values.map(\.asset)) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            images[name] = image
        }
        return images
    }()

    /// Maps a Pi provider identifier to the bundled mark, or nil when the provider
    /// has no asset and the generic chip icon applies.
    static func assetName(for provider: String) -> String? {
        marks[provider.lowercased()]?.asset
    }

    /// The calibrated draw size inside the 13 pt frame.
    static func drawSide(for provider: String) -> CGFloat {
        marks[provider.lowercased()]?.side ?? defaultSide
    }

    var body: some View {
        Group {
            if let mark = Self.marks[provider.lowercased()], let image = Self.images[mark.asset] {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: mark.side, height: mark.side)
            } else {
                Image(systemName: "cpu")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.defaultSide, height: Self.defaultSide)
            }
        }
        .frame(width: Self.frameSide, height: Self.frameSide)
        .accessibilityHidden(true)
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
