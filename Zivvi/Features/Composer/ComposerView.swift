import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ComposerView: View {
    @Environment(\.zivviTypography) private var typography
    @Bindable var controller: SessionController
    let workspace: WorkspaceController
    let isViewedSessionActive: Bool
    let sessionConfigurationDisabled: Bool
    let model: ComposerModel?
    let reference: SessionReference?
    let project: ProjectRecord?
    let panelsBlocked: Bool
    let onPickFiles: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let sendEnabled: Bool
    var focusSignal = 0
    var onInputFocused: (() -> Void)? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil
    var isStarter = false
    var maxEditorHeight: CGFloat = 180
    var sendShortcut: ComposerSendShortcut = .commandReturn
    var pastedImagesDirectory: URL = AppSettings.defaultPastedImagesDirectory(stateDirectory: nil)
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var isSubmittingHandoff = false
    @FocusState private var focused: Bool
    @FocusState private var modelFocused: Bool
    @FocusState private var sendModeFocused: Bool
    @State private var panel: Panel?
    @State private var composerWidth: CGFloat = 0
    @State private var savingModel = false
    @State private var opensHandoffEditor = false
    @State private var restoreInputFocus = false
    @State private var attachmentPasteError: String?

    private enum Panel {
        case mode, context, model, sendMode, workingDirectory

        var configuresSession: Bool {
            switch self {
            case .mode, .model, .workingDirectory: true
            case .context, .sendMode: false
            }
        }
    }

    private var showsStopButton: Bool {
        isViewedSessionActive && controller.connection == .connected &&
            (controller.isStopping || (controller.phase != .uncertain &&
                (controller.phase.isActive || !controller.queue.isEmpty)))
    }

    private var showsSendModeMenu: Bool {
        showsStopButton && controller.supportsQueuedPrompts
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

    private var composerContent: some View {
        let attachments = controller.draftFiles.filter {
            ImageAttachmentThumbnail.isImage($0) || VideoAttachmentThumbnail.isVideo($0)
        }
        let attachmentSet = Set(attachments)
        let files = controller.draftFiles.filter { !attachmentSet.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            if !controller.recoveredDrafts.isEmpty {
                RecoveredDraftsView(controller: controller).padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(attachments, id: \.self) { file in
                                attachmentThumbnail(file)
                            }
                        }
                    }
                    .accessibilityIdentifier("draft-attachments")
                }
                editorRow
                if let attachmentPasteError {
                    Text(attachmentPasteError)
                        .zivviFont(.caption)
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
                                    } label: { LightningIconView(.xmark, size: 11) }
                                    .buttonStyle(FlatControlButtonStyle(inset: false))
                                    .accessibilityLabel("移除 \(file.lastPathComponent)")
                                }
                                .zivviFont(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(ZivviTheme.mutedSurface, in: .capsule)
                            }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("draft-files")
                }
                ComposerControlsLayout {
                    HStack(spacing: 4) {
                        attachmentButton
                        if controller.session?.availableModes.isEmpty == false {
                            acpModeMenu
                        }
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
                .zivviFont(.caption)
                .lineLimit(1)
                .padding(.top, 5) // 13 pt after the editor or attachment row, including the stack spacing.
            }
            .padding(ZivviSpacing.contentInset)
            .flatSurface(radius: 14, border: ZivviTheme.inputBorder(focused: focused))
        }
        .padding(.top, 4).padding(.bottom, 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reference, let handoff = reference.handoff, !handoff.delivered {
                let first = reference.submissions.first { $0.id == handoff.firstSubmissionID }
                if first?.delivery != .unknown {
                    ComposerHandoffStatus(handoff: handoff, isSending: isSubmittingHandoff || first?.delivery == .pending,
                                          canEdit: canConfigureModel && workspace.handoffBlockReason(for: reference.id) == nil,
                                          editHandoff: {
                                              opensHandoffEditor = true
                                              show(.model)
                                          }, editDraft: {
                                              if let id = handoff.lastRejectedSubmissionID { controller.restoreDraft(id) }
                                              focused = true
                                          })
                    .padding(.bottom, 2)
                }
            }
            composerContent
        }
        .disabled(controller.isDraftEditingLocked)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { composerWidth = $0 }
        .onChange(of: controller.connection) { _, state in if state == .connected { focused = true } }
        .onChange(of: focusSignal) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            onFocusChanged?(isFocused)
            if isFocused { onInputFocused?() }
        }
        .onChange(of: sessionConfigurationDisabled) { _, disabled in
            if disabled, panel?.configuresSession == true, !savingModel { setPanel(nil) }
        }
        .onChange(of: panelsBlocked) { _, blocked in
            if blocked { setPanel(nil) }
        }
        .onChange(of: showsSendModeMenu) { _, visible in
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
            if canConfigureModel {
                opensHandoffEditor = false
                show(.model)
            }
        }
        .onChange(of: panel) { previous, current in
            if previous == .model && current != .model { opensHandoffEditor = false }
            guard current == nil, !panelsBlocked else { return }
            switch previous {
            case .model:
                if restoreInputFocus || !canConfigureModel { focused = true }
                else { modelFocused = true }
            case .sendMode:
                if restoreInputFocus { focused = true }
                else if showsSendModeMenu { sendModeFocused = true }
            default:
                break
            }
        }
    }

    private var editorRow: some View {
        let maxLines = max(3, min(10, Int(floor(maxEditorHeight / 20))))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsSendModeMenu { sendModeMenu }
            TextField("消息输入框", text: $controller.draft, prompt: Text(verbatim: ""), axis: .vertical)
                .lineLimit(1...maxLines).textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: isStarter ? 44 : 22, alignment: .topLeading)
                .focused($focused).accessibilityIdentifier("prompt-input")
                .diagnosticDraw("editor:\(controller.draft.utf8.count)")
                .accessibilityLabel("消息输入框")
                .accessibilityHint("\(Text(sendShortcut.keyHint)) 按 ⌘V 粘贴图片或视频，按 ⌘L 聚焦输入框。")
                .background {
                    ComposerInputEvents(isFocused: $focused,
                                        canPasteAttachment: !panelsBlocked && !controller.isDraftEditingLocked,
                                        canSend: sendEnabled,
                                        shortcut: sendShortcut,
                                        onPaste: addPastedAttachment, onSend: onSend)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    if controller.draft.isEmpty {
                        messagePrompt
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private var messagePrompt: some View {
        HStack(alignment: .center, spacing: 6) {
            LightningBrandIconView(.agent, size: typography.pointSize(for: .callout) + 2)
            Text("告诉我你想实现什么…",
                 comment: "Empty message editor prompt.")
                .foregroundStyle(ZivviTheme.secondaryText)
                .lineLimit(2)
        }
        // Keep the editor's origin and the insertion point stable as the prompt disappears.
        .padding(.leading, ZivviSpacing.dialogLabelGap)
        .padding(.top, 2)
    }

    private var sendModeMenu: some View {
        Button {
            panelBinding(.sendMode).wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                LightningBrandIconView(controller.mode == .steer ? .steer : .queue, size: 12)
                sendModeTitle(controller.mode, compact: true)
            }
            .zivviFont(.caption)
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
                        guard panel == .sendMode, showsSendModeMenu, !panelsBlocked,
                              workspace.viewed?.controller === controller else { return }
                        controller.mode = mode
                        setPanel(nil)
                    } label: {
                        FlatMenuRow(title: sendModeTitle(mode), selected: selected)
                    }
                    .buttonStyle(FlatControlButtonStyle(isSelected: selected))
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
        guard !controller.isDraftEditingLocked else { return }
        controller.draftFiles.removeAll { $0 == file }
        let referenced = controller.draftFiles
            + controller.recoveredDrafts.flatMap { $0.files ?? [] }
            + controller.transcript.flatMap(\.editableFiles)
            + (reference?.submissions.flatMap { $0.files ?? [] } ?? [])
        ClipboardImage.removeUnusedPastedFile(file, in: pastedImagesDirectory, referenced: referenced)
    }

    @ViewBuilder private func attachmentThumbnail(_ file: URL) -> some View {
        if VideoAttachmentThumbnail.isVideo(file) {
            VideoAttachmentThumbnail(file: file, onOpen: { NSWorkspace.shared.open(file) },
                                     remove: { removeAttachment(file) })
        } else {
            ImageAttachmentThumbnail(file: file, onPreview: onPreviewImage.map { preview in { preview(.file(file)) } },
                                     remove: { removeAttachment(file) })
        }
    }

    private func addPastedAttachment(_ result: PastedAttachment.Result) {
        guard !controller.isDraftEditingLocked else { return }
        switch result {
        case .attachment(.image(let image)):
            do {
                let file = try image.save(in: pastedImagesDirectory)
                controller.draftFiles.append(file)
                attachmentPasteError = nil
            } catch {
                attachmentPasteError = String(localized: "无法添加剪贴板图片，请重新复制后再试。")
            }
        case .attachment(.video(let url)):
            // A pasted video stays where it is so a large clip is never duplicated on disk.
            let file = url.standardizedFileURL
            if !controller.draftFiles.contains(file) { controller.draftFiles.append(file) }
            attachmentPasteError = nil
        case .unavailableVideo:
            attachmentPasteError = String(localized: "无法添加剪贴板中的视频，请先从 Finder 复制视频文件。")
        case .none:
            break
        }
    }

    private var attachmentButton: some View {
        let targetSize = typography.composerActionButtonSize
        return Button(action: onPickFiles) {
            LightningIconView(.paperclip, size: typography.pointSize(for: .caption) + 3)
                .frame(width: targetSize, height: targetSize)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .fixedSize()
        .help("添加文件")
        .accessibilityLabel("添加文件")
        .accessibilityIdentifier("add-file")
    }

    private var acpModeMenu: some View {
        let availableModes = controller.session?.availableModes ?? []
        let activeModeID = controller.session?.modeID ?? reference?.runtimeModeID
        let selectedMode = activeModeID.flatMap { id in availableModes.first { $0.id == id } }
        let modeTitle = selectedMode?.name ?? activeModeID ?? String(localized: "Agent 模式")
        return Button {
            panelBinding(.mode).wrappedValue.toggle()
        } label: {
            Text(verbatim: modeTitle)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .mode, height: typography.composerActionButtonSize))
        .fixedSize()
        .disabled(sessionConfigurationDisabled || panelsBlocked)
        .help(sessionConfigurationDisabled ? "运行或保存期间不可切换执行模式" : "切换 ACP 执行模式")
        .accessibilityLabel("ACP 执行模式")
        .accessibilityValue(modeTitle)
        .accessibilityIdentifier("acp-agent-mode")
        .popover(isPresented: panelBinding(.mode), arrowEdge: .bottom) {
            let maxWidth = max(280, min(460, composerWidth > 0 ? composerWidth - 2 * AnchoredCardStyle.inset : 460))
            ACPModePopoverContent(availableModes: availableModes, activeModeID: activeModeID, maxWidth: maxWidth) { optionID in
                setPanel(nil)
                if let id = reference?.id {
                    Task { await workspace.setACPMode(optionID, for: id) }
                }
            }
        }
    }

    private var modelButton: some View {
        Button {
            panelBinding(.model).wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                if let model {
                    ProviderLogo(provider: model.provider, model: model.name)
                        .fixedSize()
                    Text(verbatim: model.shortDisplayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 48)
                    if let thinking = model.thinkingLabel {
                        Text(thinking)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if model.pending {
                        LightningIconView(.clock, size: 12)
                            .fixedSize()
                    }
                } else if let reference, reference.isACPRuntime {
                    CodingAgentIcon(runtimeID: reference.runtimeID, agents: workspace.acpAgents, side: 13)
                        .fixedSize()
                    Text(verbatim: workspace.runtimeDisplayName(for: reference.runtimeID))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· 模型…")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    ProviderLogo(provider: "")
                    Text("模型…")
                        .fixedSize()
                }
            }
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: panel == .model, height: typography.composerActionButtonSize))
        .focused($modelFocused)
        .help(sessionConfigurationDisabled ? String(localized: "请等待当前运行、排队消息及审批全部结束后再切换。") :
                model?.summary ?? String(localized: "智能体与模型（⇧⌘M）"))
        .accessibilityLabel("智能体与模型")
        .accessibilityValue(model?.summary ?? String(localized: "未配置"))
        .accessibilityHint(reference?.modelSource.map { Text($0.detail) } ?? Text(""))
        .accessibilityIdentifier("composer-model")
        .disabled(!canConfigureModel)
        .popover(isPresented: panelBinding(.model), attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            if let reference {
                let maximumWidth = 34 * typography.pointSize(for: .callout)
                let availableWidth = composerWidth - 2 * AnchoredCardStyle.inset
                let width = availableWidth > 0 ? min(maximumWidth, availableWidth) : maximumWidth
                ModelConfigurationPanel(workspace: workspace, reference: reference, saving: $savingModel, width: width,
                                        opensHandoff: opensHandoffEditor) {
                    setPanel(nil)
                }
                .id(reference.id)
                .lineLimit(nil)
            }
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            primaryActionLabel(
                tint: sendEnabled ? ZivviTheme.brandBadgeText : ZivviTheme.iconYellow,
                fill: sendEnabled ? ZivviTheme.lightningYellow : ZivviTheme.mutedSurface
            ) {
                LightningBrandIconView(.send, size: typography.pointSize(for: .callout) + 2,
                                       tint: sendEnabled ? ZivviTheme.brandBadgeText : ZivviTheme.iconYellow)
            }
        }
        .buttonStyle(OverlayFeedbackButtonStyle(shape: Circle()))
        .help(Text(sendShortcut.sendHelp))
        .accessibilityLabel("发送")
        .accessibilityHint(Text(sendShortcut.keyHint))
        .disabled(!sendEnabled)
        .accessibilityIdentifier("send-prompt")
    }

    private var stopButton: some View {
        let stopping = controller.isStopping
        let enabled = !stopping && reference.map { workspace.canStop($0.id) } == true
        return Button(action: onStop) {
            primaryActionLabel(
                tint: ZivviTheme.iconYellow,
                fill: ZivviTheme.mutedSurface, border: ZivviTheme.border
            ) {
                LightningBrandIconView(.stop, size: typography.pointSize(for: .callout) + 1)
            }
        }
        .buttonStyle(OverlayFeedbackButtonStyle(shape: Circle()))
        .help(stopping ? Text("正在停止") : Text("停止（⌘.）"))
        .accessibilityLabel(stopping ? Text("正在停止") : Text("停止"))
        .accessibilityIdentifier("stop-run")
        .disabled(!enabled)
    }

    private func primaryActionLabel<Icon: View>(tint: Color, fill: Color, border: Color? = nil,
                                               @ViewBuilder icon: () -> Icon) -> some View {
        let targetSize = typography.composerActionButtonSize
        let circleSize = targetSize - 4
        return icon()
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

private struct ComposerHandoffStatus: View {
    let handoff: SessionHandoff
    let isSending: Bool
    let canEdit: Bool
    let editHandoff: () -> Void
    let editDraft: () -> Void

    var body: some View {
        if isSending {
            SessionTransitionRow(title: String(localized: "正在向 \(handoff.targetAgent) 发送"))
                .accessibilityIdentifier("composer-handoff-sending")
        } else if handoff.lastSubmissionRejected == true {
            SessionTransitionRow(title: String(localized: "交接未送达"), detail: String(localized: "编辑草稿"),
                                 color: ZivviTheme.errorText, action: editDraft)
                .accessibilityIdentifier("composer-handoff-rejected")
        } else {
            SessionTransitionRow(title: String(localized: "下一条由 \(handoff.targetAgent) 执行"),
                                 detail: canEdit ? String(localized: "查看交接") : nil, action: canEdit ? editHandoff : nil)
                .accessibilityIdentifier("composer-handoff-ready")
        }
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

extension SessionSettingSource {
    var detail: LocalizedStringResource {
        switch self {
        case .project: "来自项目设置"
        case .global: "来自全局设置"
        case .session: "会话设置"
        }
    }
}

struct ComposerModel {
    let provider: String
    let name: String
    let thinking: String?
    let pending: Bool
    var thinkingLabel: String? { thinking.map(ReasoningLevelLabel.text(for:)) }

    /// Produces a clean, recognizable short label for narrow widths instead of unreadable middle-truncation.
    var shortDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 22 else { return trimmed }
        if let lastSegment = trimmed.split(separator: "/").last, lastSegment.count >= 4 {
            return String(lastSegment)
        }
        return trimmed
    }

    var summary: String {
        ([provider, name] + (thinkingLabel.map { [$0] } ?? []) + (pending ? [String(localized: "待应用")] : [])).joined(separator: " · ")
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
                    }.zivviFont(.caption)
                    Spacer()
                    Button("放入输入框") { controller.restoreDraft(draft.id) }.zivviFont(.caption)
                }.padding(.vertical, 4)
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined)).zivviFont(.caption)
        .padding(8).flatSurface(ZivviTheme.mutedSurface, radius: 9)
    }
}

struct ACPModePopoverContent: View {
    let availableModes: [RuntimeModeOption]
    let activeModeID: String?
    let maxWidth: CGFloat
    let select: (String) -> Void

    var body: some View {
        Group {
            if availableModes.isEmpty {
                Text("连接该 ACP Agent 后将显示其支持的原生执行模式。")
                    .zivviFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: ZivviSpacing.menuItemGap) {
                    ForEach(availableModes) { option in
                        let selected = option.id == activeModeID
                        Button { select(option.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: option.name).zivviFont(.callout, weight: .medium)
                                    if let description = option.description, !description.isEmpty {
                                        Text(verbatim: description)
                                            .zivviFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 4)
                                if selected {
                                    LightningIconView(.checkmark, size: 13)
                                }
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: selected))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("acp-mode-\(option.id)")
                    }
                }
            }
        }
        .lineLimit(nil)
        .anchoredAdaptivePopoverCard(minWidth: 200, maxWidth: maxWidth,
                                     inset: AnchoredCardStyle.compactInset,
                                     background: ZivviTheme.surface)
    }
}
