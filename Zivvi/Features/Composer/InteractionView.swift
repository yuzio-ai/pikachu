import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

enum WorkbenchModal: Identifiable {
    case interaction(RuntimeInteraction, SessionController, String, projectDirectory: String?)
    case toolFailures([TranscriptItem])
    case taskPlan(SessionController)
    case settings(SettingsSection)
    case chooseSessionProject
    case importACPHistory(UUID, String)
    case confirmation(ConfirmationRequest)
    var id: String {
        switch self {
        case .interaction(let request, _, _, _): request.id
        case .toolFailures: "tool-failures"
        case .taskPlan: "task-plan"
        case .settings: "settings"
        case .chooseSessionProject: "choose-session-project"
        case .importACPHistory: "import-acp-history"
        case .confirmation(let request): request.id.uuidString
        }
    }
}

struct InteractionView: View {
    private let initialRequest: RuntimeInteraction
    private var request: RuntimeInteraction {
        controller.interactions.first { $0.id == initialRequest.id }
            ?? controller.expiredInteraction(for: initialRequest)
            ?? initialRequest
    }
    let controller: SessionController
    let sessionTitle: String
    let availableSize: CGSize
    let projectDirectory: String?
    @Environment(\.zivviTypography) private var typography
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var selection: Int?
    @State private var completed = false
    @State private var submitting = false
    @State private var preferredApprovalWidth: CGFloat?
    @State private var fittedApprovalHeight: CGFloat?
    @FocusState private var focused: Bool
    init(
        request: RuntimeInteraction,
        controller: SessionController,
        sessionTitle: String,
        availableSize: CGSize = .zero,
        projectDirectory: String? = nil
    ) {
        self.initialRequest = request; self.controller = controller; self.sessionTitle = sessionTitle
        self.availableSize = availableSize
        self.projectDirectory = projectDirectory
        _text = State(initialValue: request.prefill)
    }
    private var expired: Bool { controller.didExpire(request) }
    private var usesAdaptiveSheet: Bool {
        request.isPermissionApproval && (request.usesUnifiedApprovalSheet || (request.toolApproval?.operation.usesAdaptiveSheet ?? true))
    }
    var body: some View {
        Group {
            if usesAdaptiveSheet {
                adaptiveInteractionContent
            } else {
                interactionContent
            }
        }
        .scrollIndicators(.never)
        .interactiveDismissDisabled(submitting)
        .onChange(of: request.toolApproval, initial: true) {
            preferredApprovalWidth = ApprovalSheetLayout.preferredWidth(
                for: request, typography: typography, projectDirectory: projectDirectory
            )
        }
        .onChange(of: request.permissionContext) {
            preferredApprovalWidth = ApprovalSheetLayout.preferredWidth(
                for: request, typography: typography, projectDirectory: projectDirectory
            )
        }
        .onChange(of: typography) {
            preferredApprovalWidth = ApprovalSheetLayout.preferredWidth(
                for: request, typography: typography, projectDirectory: projectDirectory
            )
        }
        .task(id: request.id) { await Task.yield(); focused = request.kind == .input || request.kind == .editor }
        .onDisappear {
            if !completed && controller.interactions.contains(where: { $0.id == request.id }) {
                Task { await controller.reply(request, .cancelled) }
            }
        }
    }

    private var adaptiveInteractionContent: some View {
        let maximumHeight: CGFloat? = availableSize.height > 0
            ? max(1, min(floor(availableSize.height * 0.8), availableSize.height - 2 * ApprovalSheetLayout.inset))
            : nil
        return ApprovalHeightLayout(maximumHeight: maximumHeight) {
            interactionContent
        }
        .onGeometryChange(for: CGFloat.self, of: { ceil($0.size.height) }) { height in
            fittedApprovalHeight = height
        }
        .frame(height: fittedApprovalHeight)
        .background {
            ApprovalSheetWindowHeight(height: fittedApprovalHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .presentationSizing(.fitted)
    }

    private var interactionContent: some View {
        Group {
            if request.usesUnifiedApprovalSheet, let category = request.approvalCategory {
                UnifiedApprovalSheet(
                    request: request,
                    category: category,
                    projectDirectory: projectDirectory,
                    expired: expired,
                    notice: controller.noticeExcludingExpiredInteraction,
                    error: controller.failure?.detail,
                    submitting: submitting,
                    reply: submit,
                    closeExpired: { dismiss() }
                )
            } else if expired {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
                    if usesAdaptiveSheet {
                        ViewThatFits(in: .vertical) {
                            expiredDetails.fixedSize(horizontal: false, vertical: true)
                            ScrollView { expiredDetails }
                                .scrollBounceBehavior(.basedOnSize)
                        }
                    } else {
                        expiredDetails
                    }
                    HStack {
                        Spacer()
                        Button(String(localized: "dialog.close", defaultValue: "关闭")) { dismiss() }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("interaction-close-expired")
                    }
                    .layoutPriority(1)
                }
                .padding(20)
            } else if let elicitation = request.elicitation {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
                    ACPElicitationView(request: request, elicitation: elicitation, submitting: submitting, reply: submit)
                    interactionFeedback(noticeColor: ZivviTheme.secondaryText)
                }.padding(20)
            } else if request.isPermissionApproval {
                ToolApprovalSheet(request: request, projectDirectory: projectDirectory, adaptive: usesAdaptiveSheet,
                                  notice: usesAdaptiveSheet ? controller.noticeExcludingExpiredInteraction : controller.notice,
                                  error: controller.failure?.detail,
                                  submitting: submitting, reply: submit)
            } else {
                extensionRequest
            }
        }
        .frame(width: approvalSheetWidth)
    }

    private var expiredDetails: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                Text("请求已过期，未提交回复")
                    .zivviFont(.title2, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text("会话：\(sessionTitle)").zivviFont(.caption).foregroundStyle(.secondary)
                InteractionDeadline(expiresAt: request.expiresAt)
            }
            ExpiredInteractionDetails(request: request, projectDirectory: projectDirectory)
        }
    }

    private var approvalSheetWidth: CGFloat {
        guard request.isPermissionApproval else { return 560 }
        guard let preferred = preferredApprovalWidth
            ?? ApprovalSheetLayout.preferredWidth(for: request, typography: typography, projectDirectory: projectDirectory) else { return 740 }
        return ApprovalSheetLayout.width(preferred: preferred, available: availableSize.width)
    }

    private var extensionRequest: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    Text(request.authenticationMethods.isEmpty ? "扩展请求" : "ACP Agent 登录")
                        .zivviFont(.caption).foregroundStyle(.secondary)
                    Text(request.title).zivviFont(.title2).textSelection(.enabled)
                }
                Text("会话：\(sessionTitle)").zivviFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                InteractionDeadline(expiresAt: request.expiresAt)
                if !request.message.isEmpty {
                    ScrollView {
                        Text(request.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(ZivviSpacing.contentInset).flatSurface(ZivviTheme.mutedSurface, radius: 9)
                }
            }
            switch request.kind {
            case .select:
                InteractionChoices(options: request.authenticationMethods.isEmpty ? request.options : request.authenticationMethods.map { method in
                    method.kind == .terminal ? String(localized: "\(method.name)（终端）") : method.name
                }, selection: $selection)
            case .input:
                TextField(request.placeholder.isEmpty ? String(localized: "回复内容") : request.placeholder, text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .padding(8).flatSurface(ZivviTheme.workspace, radius: 9, border: ZivviTheme.inputBorder(focused: focused))
                    .accessibilityIdentifier("interaction-input").accessibilityLabel("扩展单行回复")
            case .editor:
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    TextEditor(text: $text).zivviFont(.body, design: .monospaced).frame(height: 220)
                        .scrollContentBackground(.hidden).focused($focused)
                        .padding(8).flatSurface(ZivviTheme.workspace, radius: 9, border: ZivviTheme.inputBorder(focused: focused))
                        .accessibilityIdentifier("interaction-editor").accessibilityLabel("扩展多行回复")
                    Text("按回车键换行，按 ⌘↩ 提交。文本上限 1 MiB。").zivviFont(.caption).foregroundStyle(.secondary)
                }
            case .confirm: EmptyView()
            }
            interactionFeedback(noticeColor: .secondary).zivviFont(.caption)
            HStack {
                Button("取消", role: .cancel) { submit(.cancelled) }.keyboardShortcut(.cancelAction)
                Button("停止任务") { Task { await controller.stop() } }
                    .disabled(!controller.canStop)
                Spacer()
                if submitting { FlatProgressView().controlSize(.small) }
                if request.kind == .confirm {
                    Button("否") { submit(.confirmed(false)) }.accessibilityIdentifier("interaction-no")
                    Button("是") { submit(.confirmed(true)) }
                        .buttonStyle(FlatControlButtonStyle(treatment: .prominent)).accessibilityIdentifier("interaction-yes")
                } else {
                    Button("提交") {
                        if request.kind == .select, let selection {
                            let choice = request.authenticationMethods.isEmpty
                                ? request.options[selection] : request.authenticationMethods[selection].id
                            submit(.value(choice))
                        } else { submit(.value(text)) }
                    }.buttonStyle(FlatControlButtonStyle(treatment: .prominent)).keyboardShortcut(.return, modifiers: request.kind == .editor ? .command : [])
                        .disabled(request.kind == .select && selection == nil).accessibilityIdentifier("interaction-submit")
                }
            }.buttonStyle(FlatControlButtonStyle(treatment: .outlined)).disabled(submitting)
        }.padding(24)
    }

    @ViewBuilder private func interactionFeedback(noticeColor: Color) -> some View {
        let notice = controller.notice
        let error = controller.failure?.detail
        if notice != nil || error != nil {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                if let notice { Text(notice).foregroundStyle(noticeColor) }
                if let error { Text(error).foregroundStyle(ZivviTheme.errorText) }
            }
        }
    }

    private func submit(_ response: InteractionResponse) {
        guard !expired, !submitting else { return }
        submitting = true
        let submittedRequest = request
        Task {
            let accepted = await controller.reply(submittedRequest, response)
            submitting = false
            if accepted { completed = true; dismiss() }
        }
    }

}

private extension RuntimeToolApproval.Operation {
    var usesAdaptiveSheet: Bool {
        switch self {
        case .command, .edit: true
        case .write, .inspect: false
        }
    }
}

@MainActor
enum ApprovalSheetLayout {
    static let inset: CGFloat = 24

    static func preferredWidth(
        for operation: RuntimeToolApproval.Operation,
        typography: ZivviTypography,
        workingDirectory: String? = nil,
        projectDirectory: String? = nil
    ) -> CGFloat? {
        let regularWidth: CGFloat = 640
        let wideWidth: CGFloat = 700
        let bodyWidth = regularWidth - 2 * inset
        let font = previewFont(typography)

        switch operation {
        case .command(let command, _):
            if command.utf8.count > 16_384 {
                return wideWidth
            }
            let textWidth = bodyWidth - 2 * ZivviSpacing.contentInset
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            let size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            let needsWideLayout = command.split(whereSeparator: \.isNewline).contains { line in
                if line.count > 160 { return true }
                let bounds = String(line).boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: attributes)
                return bounds.height > 2 * lineHeight + 1
            }
            return needsWideLayout ? wideWidth : regularWidth
        case .edit(let path, _):
            let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: workingDirectory)
            let displayed = ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory)
            let pathWidth = singleLineApprovalPath(displayed).size(withAttributes: [.font: font]).width
            return pathWidth > bodyWidth ? wideWidth : regularWidth
        case .write, .inspect:
            return nil
        }
    }

    static func width(preferred: CGFloat, available: CGFloat) -> CGFloat {
        available > 0 ? min(preferred, max(1, available - 2 * inset)) : preferred
    }

    static func preferredWidth(
        for interaction: RuntimeInteraction, typography: ZivviTypography, projectDirectory: String?
    ) -> CGFloat? {
        if let toolApproval = interaction.toolApproval {
            return preferredWidth(for: toolApproval, typography: typography, projectDirectory: projectDirectory)
        }
        guard interaction.isPermissionApproval else { return nil }
        let regularWidth: CGFloat = 640
        let wideWidth: CGFloat = 700
        let bodyWidth = regularWidth - 2 * inset
        let font = previewFont(typography)
        if interaction.approvalCategory == .edit, let context = interaction.permissionContext {
            let baseDir = context.sessionDirectory ?? context.workingDirectory
            let hasWidePath = context.fileDiffs.contains { diff in
                let absolute = ApprovalPathFormatter.absolutePath(diff.path, relativeTo: baseDir)
                let displayed = ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory)
                return singleLineApprovalPath(displayed).size(withAttributes: [.font: font]).width > bodyWidth
            }
            if hasWidePath { return wideWidth }
        }
        return regularWidth
    }

    static func preferredWidth(
        for approval: RuntimeToolApproval, typography: ZivviTypography, projectDirectory: String?
    ) -> CGFloat? {
        preferredWidth(for: approval.operation, typography: typography,
                       workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory)
    }

    static func commandPreviewHeight(typography: ZivviTypography) -> CGFloat {
        8 * previewLineHeight(typography: typography)
    }

    static func previewLineHeight(typography: ZivviTypography) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: previewFont(typography)))
    }

    private static func previewFont(_ typography: ZivviTypography) -> NSFont {
        .monospacedSystemFont(ofSize: typography.pointSize(for: .callout), weight: .regular)
    }
}

struct InteractionDeadline: View {
    let expiresAt: Date

    var body: some View {
        let deadline = expiresAt.formatted(date: .abbreviated, time: .standard)
        LightningLabel("回复截止时间：\(deadline)", icon: .clock, size: 13)
            .zivviFont(.caption)
            .foregroundStyle(ZivviTheme.secondaryText)
            .monospacedDigit()
            .accessibilityIdentifier("interaction-deadline")
    }
}

struct InteractionCountdown: View {
    let expiresAt: Date
    var warningThreshold: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = remainingSeconds(relativeTo: context.date)
            let remaining = Duration.seconds(seconds)
                .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
            let isWarning = seconds <= warningThreshold
            Label {
                Text(verbatim: remaining)
                    .monospacedDigit()
            } icon: {
                LightningIconView(.clock, size: 13)
            }
            .zivviFont(.caption)
            .foregroundStyle(isWarning ? ZivviTheme.warningText : ZivviTheme.secondaryText)
            .accessibilityIdentifier("interaction-countdown")
            .accessibilityLabel(String(localized: "approval.countdown.remaining", defaultValue: "剩余时间 \(remaining)"))
        }
    }

    func remainingDuration(relativeTo now: Date) -> Duration {
        .seconds(remainingSeconds(relativeTo: now))
    }

    private func remainingSeconds(relativeTo now: Date) -> Double {
        max(0, expiresAt.timeIntervalSince(now).rounded(.up))
    }
}

extension RuntimeInteraction {
    var isExpiredFileEditApproval: Bool {
        if let operation = toolApproval?.operation {
            if case .edit = operation { return true }
            return false
        }
        guard let permissionContext else { return false }
        if let kind = permissionContext.toolKind, !kind.isEmpty { return kind == "edit" }
        return !permissionContext.fileDiffs.isEmpty
    }
}

struct ExpiredInteractionDetails: View {
    let request: RuntimeInteraction
    var projectDirectory: String? = nil
    var contentChanged: () -> Void = {}
    @State private var technicalDetailsExpanded = false
    @State private var wrapsPreviewLines = true
    @State private var wrapsRawInputLines = true

    private var sessionDirectory: String? {
        let path = request.permissionContext?.sessionDirectory
            ?? request.permissionContext?.workingDirectory ?? request.toolApproval?.workingDirectory
        return path.flatMap { $0.isEmpty ? nil : $0 }
    }

    var additionalWorkingDirectory: String? {
        ApprovalPathFormatter.distinctDirectory(request.toolApproval?.workingDirectory ?? request.permissionContext?.workingDirectory,
                                               from: sessionDirectory)
    }

    private var commandTimeout: Double? {
        guard case .command(_, let timeout)? = request.toolApproval?.operation else { return nil }
        return timeout
    }

    private var options: [String] {
        request.permissionOptions.isEmpty ? request.options : request.permissionOptions.map(\.name)
    }

    var showsRequestTitle: Bool {
        guard !request.title.isEmpty else { return false }
        switch request.toolApproval?.operation {
        case .command?, .edit?, .write?: return false
        default: return !request.isExpiredFileEditApproval || request.permissionContext?.fileDiffs.isEmpty != false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if request.isPermissionApproval {
                approvalContent
                if sessionDirectory != nil || additionalWorkingDirectory != nil || commandTimeout != nil ||
                    request.permissionContext?.rawInputJSON != nil || !options.isEmpty {
                    technicalDetails
                }
            } else {
                if !request.title.isEmpty { requestTitle }
                if !request.message.isEmpty {
                    ApprovalTextScrollView(text: request.message, maxHeight: 180)
                }
                if !options.isEmpty { ExpiredInteractionOptions(options: options) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: wrapsPreviewLines) { contentChanged() }
        .onChange(of: wrapsRawInputLines) { contentChanged() }
    }

    private var requestTitle: some View {
        Text(verbatim: request.title)
            .zivviFont(.callout, weight: .semibold)
            .textSelection(.enabled)
    }

    @ViewBuilder private var approvalContent: some View {
        let details = PermissionApprovalDetails(request: request, projectDirectory: projectDirectory,
                                                 excludingTitle: request.title,
                                                 excludingWorkingDirectory: sessionDirectory, compactFilePaths: true)
        if showsRequestTitle { requestTitle }
        if let approval = request.toolApproval {
            switch approval.operation {
            case .command(let command, _):
                CommandApprovalPreview(command: command, wrapsLines: $wrapsPreviewLines)
            case .edit(let path, let replacements):
                if request.permissionContext?.fileDiffs.isEmpty != false {
                    if replacements.isEmpty {
                        ApprovalPathRow(nil, path: path, projectDirectory: projectDirectory,
                                        relativeTo: sessionDirectory, identifier: "approval-file-path")
                    } else {
                        ApprovalFileChanges(diffs: replacements.map {
                            .init(path: path, oldText: $0.oldText, newText: $0.newText)
                        }, projectDirectory: projectDirectory, relativeTo: sessionDirectory, compactPaths: true)
                    }
                }
            default:
                ToolApprovalDetails(approval: approval, projectDirectory: projectDirectory,
                                    showsDirectory: false, wrapsPreviewLines: $wrapsPreviewLines)
            }
        }
        if details.hasAdditionalContent {
            details
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $technicalDetailsExpanded) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                if let sessionDirectory {
                    ApprovalPathRow("会话目录", path: sessionDirectory, projectDirectory: projectDirectory,
                                    identifier: "approval-working-directory")
                }
                if let additionalWorkingDirectory {
                    ApprovalPathRow("工作目录", path: additionalWorkingDirectory, projectDirectory: projectDirectory,
                                    relativeTo: sessionDirectory, identifier: "approval-command-directory")
                }
                if let commandTimeout {
                    LabeledContent("执行超时") { Text("\(commandTimeout.formatted()) 秒") }
                        .zivviFont(.caption)
                }
                if let rawInput = request.permissionContext?.rawInputJSON {
                    ApprovalJSONPreview(json: rawInput, wrapsLines: $wrapsRawInputLines)
                }
                if !options.isEmpty { ExpiredInteractionOptions(options: options) }
            }
            .padding(.top, ZivviSpacing.dialogItemGap)
        } label: {
            Text("技术详情")
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.secondaryText)
        }
        .disclosureGroupStyle(FlatDisclosureStyle(showsHoverBackground: false))
        .onChange(of: technicalDetailsExpanded) { _, _ in contentChanged() }
    }
}

private struct ExpiredInteractionOptions: View {
    let options: [String]

    var body: some View {
        let names = Text(verbatim: options.joined(separator: " · "))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 12) {
            Text("选项").fixedSize()
            ViewThatFits(in: .vertical) {
                names
                ScrollView { names.frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 100, alignment: .topLeading)
        }
        .zivviFont(.callout)
        .foregroundStyle(ZivviTheme.secondaryText)
    }
}

struct ToolFailureDetailsSheet: View {
    let failures: [TranscriptItem]
    let close: () -> Void
    @State private var selectedFailureID: String?

    private let contentWidth: CGFloat = 700

    private var currentFailureIndex: Int {
        guard let selectedFailureID else { return 0 }
        return failures.firstIndex(where: { $0.id == selectedFailureID }) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("工具调用失败")
                        .zivviFont(.title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if failures.count > 1 {
                        HStack(spacing: 6) {
                            Button {
                                stepFailure(by: -1)
                            } label: {
                                LightningIconView(.chevronLeft, size: 12)
                            }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                            .disabled(currentFailureIndex <= 0)
                            .help("上一个失败")
                            .accessibilityLabel("上一个失败")
                            .accessibilityIdentifier("tool-failure-prev")

                            Text(verbatim: "\(currentFailureIndex + 1) / \(failures.count)")
                                .zivviFont(.caption)
                                .foregroundStyle(ZivviTheme.secondaryText)
                                .monospacedDigit()
                                .accessibilityIdentifier("tool-failure-page")

                            Button {
                                stepFailure(by: 1)
                            } label: {
                                LightningIconView(.chevronRight, size: 12)
                            }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                            .disabled(currentFailureIndex >= failures.count - 1)
                            .help("下一个失败")
                            .accessibilityLabel("下一个失败")
                            .accessibilityIdentifier("tool-failure-next")
                        }
                    }
                }
                ZivviDivider().padding(.vertical, ZivviSpacing.dialogItemGap)
                if failures.count > 1 {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(failures) { item in
                                ScrollView {
                                    failureCard(item)
                                        .padding(1)
                                }
                                .scrollIndicators(.never)
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(width: contentWidth)
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selectedFailureID)
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: contentWidth)
                    .frame(idealHeight: 240, maxHeight: 340)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
                            ForEach(failures) { item in
                                failureCard(item)
                            }
                        }
                        .padding(1)
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(idealHeight: 240, maxHeight: 340)
                }
            }
            .padding(20)
            ZivviDivider()
            HStack {
                Spacer()
                Button(String(localized: "dialog.close", defaultValue: "关闭"), action: close)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 740)
        .onAppear { syncSelection() }
        .onChange(of: failures.map(\.id)) { _, _ in syncSelection() }
        .accessibilityIdentifier("composer-failed-tool-details")
    }

    @ViewBuilder
    private func failureCard(_ item: TranscriptItem) -> some View {
        if let tool = item.tool {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                HStack(spacing: 7) {
                    ToolCallIcon(glyph: ToolCallKind(name: tool.name).glyph)
                    Text(verbatim: tool.name)
                        .zivviFont(.callout, weight: .semibold, design: .monospaced)
                }
                if tool.output.isEmpty {
                    Text("没有可用的工具输出。").zivviFont(.caption).foregroundStyle(.secondary)
                }
                ToolDetails(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ZivviSpacing.contentInset)
            .flatSurface(ZivviTheme.mutedSurface, radius: 9)
        }
    }

    private func syncSelection() {
        if let selectedFailureID, failures.contains(where: { $0.id == selectedFailureID }) { return }
        selectedFailureID = failures.first?.id
    }

    private func stepFailure(by delta: Int) {
        guard failures.count > 1 else { return }
        let current = currentFailureIndex
        let next = min(max(0, current + delta), failures.count - 1)
        guard next != current else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFailureID = failures[next].id
        }
    }
}

struct TaskPlanDetailsSheet: View {
    let controller: SessionController
    let close: () -> Void

    var body: some View {
        let entries = controller.plan
        let completed = entries.count { $0.status == .completed }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("任务计划")
                        .zivviFont(.title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(completed)/\(entries.count) 已完成")
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.secondaryText)
                    }
                }
                ZivviDivider().padding(.vertical, ZivviSpacing.dialogItemGap)
                if entries.isEmpty {
                    Text("当前暂无任务计划。")
                        .zivviFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, ZivviSpacing.contentInset)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 10) {
                                    LightningIconView(systemName: statusIcon(for: entry.status), size: 15)
                                        .foregroundStyle(statusColor(for: entry.status))
                                        .frame(width: 16, height: 18)
                                        .accessibilityHidden(true)
                                    Text(verbatim: entry.content)
                                        .zivviFont(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(statusLabel(for: entry.status))
                                        .zivviFont(.caption)
                                        .foregroundStyle(statusColor(for: entry.status))
                                        .fixedSize()
                                }
                                .padding(ZivviSpacing.contentInset)
                                .flatSurface(ZivviTheme.mutedSurface, radius: 9)
                            }
                        }
                        .padding(1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(idealHeight: 240, maxHeight: 340)
                }
            }
            .padding(20)
            ZivviDivider()
            HStack {
                Spacer()
                Button(String(localized: "dialog.close", defaultValue: "关闭"), action: close)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 740)
        .accessibilityIdentifier("composer-task-plan-details")
    }

    private func statusIcon(for status: RuntimePlanEntry.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "play.circle.fill"
        case .pending: "circle"
        }
    }

    private func statusLabel(for status: RuntimePlanEntry.Status) -> LocalizedStringResource {
        switch status {
        case .completed: "已完成"
        case .inProgress: "进行中"
        case .pending: "待处理"
        }
    }

    private func statusColor(for status: RuntimePlanEntry.Status) -> Color {
        switch status {
        case .completed: ZivviTheme.runningText
        case .inProgress: ZivviTheme.infoText
        case .pending: ZivviTheme.tertiaryText
        }
    }
}

private struct ToolApprovalSheet: View {
    let request: RuntimeInteraction
    let projectDirectory: String?
    let adaptive: Bool
    let notice: String?
    let error: String?
    let submitting: Bool
    let reply: (InteractionResponse) -> Void

    @State private var rawInputExpanded = false
    @State private var wrapsPreviewLines = true
    @State private var wrapsRawInputLines = true

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
            ToolApprovalFooter(adaptive: adaptive, options: request.permissionOptions,
                               submitting: submitting, awaitingToolDetails: request.permissionContext?.awaitingToolDetails == true,
                               reply: reply)
                .layoutPriority(1)
        }
        .onChange(of: request.id) {
            rawInputExpanded = false
            wrapsPreviewLines = true
            wrapsRawInputLines = true
        }
    }

    private var content: some View {
        let details = ActiveApprovalDetails(approval: request.toolApproval, context: request.permissionContext,
                                            message: request.permissionOptions.isEmpty ? "" : request.message,
                                            projectDirectory: projectDirectory,
                                            showsSessionDirectory: request.permissionOptions.isEmpty,
                                            wrapsPreviewLines: $wrapsPreviewLines)
        return VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            ToolApprovalHeader(title: request.title, operation: request.toolApproval?.operation,
                               toolName: request.permissionContext?.toolName, toolKind: request.permissionContext?.toolKind,
                               usesLocalToolIdentity: request.permissionOptions.isEmpty, expiresAt: request.expiresAt,
                               adaptive: adaptive,
                               summaries: details.headerSummaries(excluding: request.title, fallback: request.message))
            details
            if let rawInput = request.permissionContext?.rawInputJSON {
                ApprovalRawInputDisclosure(json: rawInput, isExpanded: $rawInputExpanded, wrapsLines: $wrapsRawInputLines)
            }
            if let notice { Text(verbatim: notice).zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText) }
            if let error { Text(verbatim: error).zivviFont(.caption).foregroundStyle(ZivviTheme.errorText) }
        }
        .padding(adaptive ? ApprovalSheetLayout.inset : 20)
    }
}

struct ActiveApprovalDetails: View {
    let approval: RuntimeToolApproval?
    let context: RuntimePermissionContext?
    let message: String
    let projectDirectory: String?
    var showsSessionDirectory = true
    @Binding var wrapsPreviewLines: Bool

    private var sessionDirectory: String? { context?.sessionDirectory ?? approval?.workingDirectory ?? context?.workingDirectory }
    var commandDirectory: String? {
        guard context?.toolKind == "execute" else { return nil }
        return ApprovalPathFormatter.distinctDirectory(context?.workingDirectory, from: sessionDirectory)
    }
    var relatedPaths: [ApprovalPathFormatter.RelatedPath] {
        ApprovalPathFormatter.relatedPaths(context?.paths ?? [], excluding: context?.fileDiffs ?? [],
                                          relativeTo: sessionDirectory)
    }
    private var standardSummaryBelongsInHeader: Bool {
        switch approval?.operation {
        case .command?, .edit?: return true
        default: break
        }
        switch context?.toolKind {
        case "execute", "edit": return true
        case nil: return context?.fileDiffs.isEmpty == false
        default: return false
        }
    }

    func headerSummaries(excluding title: String, fallback: String) -> [String] {
        let standardSummary = [context?.summary, fallback].compactMap(\.self).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var seen = Set([title, context?.toolTitle ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return [context?.toolSummary, standardSummaryBelongsInHeader ? standardSummary : nil].compactMap { value in
            guard let value else { return nil }
            let comparison = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comparison.isEmpty, seen.insert(comparison).inserted else { return nil }
            return value
        }
    }

    var body: some View {
        let diffs = context?.fileDiffs ?? []
        let summary = context?.summary ?? message
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            metadata
            if let approval {
                switch approval.operation {
                case .command(let command, let timeout):
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                        CommandApprovalPreview(command: command, wrapsLines: $wrapsPreviewLines)
                        if let timeout {
                            LabeledContent("执行超时") { Text("\(timeout.formatted()) 秒") }
                                .zivviFont(.caption)
                        }
                    }
                case .edit(let path, let replacements):
                    ApprovalFileChanges(diffs: replacements.map { .init(path: path, oldText: $0.oldText, newText: $0.newText) },
                                        projectDirectory: projectDirectory, relativeTo: sessionDirectory)
                case .write, .inspect:
                    ToolApprovalDetails(approval: approval, projectDirectory: projectDirectory, showsDirectory: false,
                                        wrapsPreviewLines: $wrapsPreviewLines)
                }
            }
            if !standardSummaryBelongsInHeader, !summary.isEmpty, summary != context?.toolSummary {
                ApprovalTextPreview(text: summary, identifier: "permission-summary")
            }
            if !diffs.isEmpty {
                ApprovalFileChanges(diffs: diffs, projectDirectory: projectDirectory, relativeTo: sessionDirectory)
            }
        }
    }

    private var metadata: some View {
        let relatedPaths = self.relatedPaths
        return VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if showsSessionDirectory {
                if let sessionDirectory, !sessionDirectory.isEmpty {
                    ApprovalPathRow("会话目录", path: sessionDirectory, projectDirectory: projectDirectory,
                                    identifier: "approval-working-directory")
                } else {
                    LabeledContent("会话目录") { Text("未知") }
                        .zivviFont(.caption)
                }
            }
            if !relatedPaths.isEmpty {
                ApprovalPathRows(paths: relatedPaths, projectDirectory: projectDirectory)
            }
            if let commandDirectory {
                ApprovalPathRow("工作目录", path: commandDirectory, projectDirectory: projectDirectory,
                                relativeTo: sessionDirectory, identifier: "approval-command-directory")
            }
            if context?.awaitingToolDetails == true {
                Text("等待操作详情")
                    .zivviFont(.callout)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
        }
    }
}

private struct ApprovalHeightLayout: Layout {
    let maximumHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Measure the ideal height independently of the sheet's current height so it can grow after a disclosure opens.
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maximumHeight ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ApprovalSheetWindowHeight: NSViewRepresentable {
    let height: CGFloat?

    func makeNSView(context: Context) -> SheetAnchor {
        SheetAnchor()
    }

    func updateNSView(_ view: SheetAnchor, context: Context) {
        view.preferredHeight = height
    }

    final class SheetAnchor: NSView {
        var preferredHeight: CGFloat? {
            didSet {
                if preferredHeight != oldValue { resizeSheet() }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizeSheet()
        }

        private func resizeSheet() {
            // An attached SwiftUI sheet can retain its initial height even when its content is fitted.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.sheetParent != nil, let preferredHeight else { return }
                let current = window.frame
                let content = window.contentRect(forFrameRect: current)
                guard abs(content.height - preferredHeight) >= 1 else { return }
                let fitted = window.frameRect(forContentRect: CGRect(origin: content.origin,
                                                                      size: CGSize(width: content.width, height: preferredHeight)))
                window.setFrame(CGRect(x: current.minX, y: current.maxY - fitted.height,
                                       width: current.width, height: fitted.height), display: true)
            }
        }
    }
}

private struct ToolApprovalHeader: View {
    let title: String
    let operation: RuntimeToolApproval.Operation?
    let toolName: String?
    let toolKind: String?
    let usesLocalToolIdentity: Bool
    let expiresAt: Date
    let adaptive: Bool
    let summaries: [String]

    private var fallbackTitle: LocalizedStringKey {
        switch operation {
        case .command?: "允许运行此命令？"
        case .write?: "允许写入文件？"
        case .edit?: "允许编辑文件？"
        case .inspect(let inspection, _)?: inspection.approvalTitle
        case nil: "工具调用权限审批"
        }
    }

    var body: some View {
        let displayTitle = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let usesFallbackTitle = displayTitle.trimmingCharacters(in: .whitespaces).isEmpty
        let fullTitle = usesFallbackTitle ? Text(fallbackTitle) : Text(verbatim: title)
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack(spacing: 12) {
                (usesFallbackTitle ? fullTitle : Text(verbatim: displayTitle))
                    .zivviFont(.title2, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(fullTitle)
                    .accessibilityLabel(fullTitle)
                    .accessibilityAddTraits(.isHeader)
                if adaptive {
                    InteractionCountdown(expiresAt: expiresAt)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }
            ForEach(summaries, id: \.self) { summary in
                Text(verbatim: summary)
                    .zivviFont(.body, weight: .medium)
                    .foregroundStyle(ZivviTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            subtitle
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.secondaryText)
            if !adaptive { InteractionDeadline(expiresAt: expiresAt) }
        }
    }

    private var subtitle: some View {
        let name = toolName.flatMap { $0.isEmpty ? nil : $0 } ?? localTool?.name
        let kind = toolKind.flatMap { $0.isEmpty ? nil : $0 } ?? localTool?.kind
        return PermissionOptionFlowLayout(spacing: 5, alignsLeading: true) {
            if let name {
                Text("授权使用")
                ApprovalInlineCode(value: name)
            }
            if let kind {
                if name == nil { Text("授权执行") } else { Text("执行") }
                ApprovalInlineCode(value: kind)
                Text("操作？")
            } else if name != nil {
                Text("？")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var localTool: (name: String, kind: String)? {
        guard usesLocalToolIdentity else { return nil }
        return switch operation {
        case .command?: ("bash", "execute")
        case .write?: ("write", "edit")
        case .edit?: ("edit", "edit")
        case .inspect(let inspection, _)?:
            (inspection.rawValue, inspection == .read || inspection == .ls ? "read" : "search")
        case nil: nil
        }
    }
}

struct ToolApprovalFooter: View {
    let adaptive: Bool
    let options: [RuntimePermissionOption]
    let submitting: Bool
    let awaitingToolDetails: Bool
    let reply: (InteractionResponse) -> Void

    private var binaryOptions: (reject: RuntimePermissionOption, allow: RuntimePermissionOption)? {
        guard options.count == 2,
              let reject = options.first(where: { $0.kind == .rejectOnce }),
              let allow = options.first(where: { $0.kind == .allowOnce }) else { return nil }
        return (reject, allow)
    }

    var body: some View {
        VStack(spacing: 0) {
            if adaptive {
                ZivviDivider(color: ZivviTheme.subtleDivider)
                    .padding(.horizontal, ApprovalSheetLayout.inset)
                    .accessibilityHidden(true)
            } else {
                ZivviDivider()
            }
            VStack(spacing: ZivviSpacing.dialogItemGap) {
                if options.isEmpty {
                    confirmationButtons(reject: nil, allow: nil)
                } else if let binaryOptions {
                    confirmationButtons(reject: binaryOptions.reject, allow: binaryOptions.allow)
                } else {
                    ViewThatFits(in: .vertical) {
                        permissionChoices.fixedSize(horizontal: false, vertical: true)
                        ScrollView { permissionChoices }.scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxHeight: 160)
                    if submitting {
                        HStack {
                            Spacer()
                            FlatProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .disabled(submitting)
            .padding(.horizontal, adaptive ? ApprovalSheetLayout.inset : 20)
            .padding(.vertical, 12)
        }
    }

    private func confirmationButtons(reject: RuntimePermissionOption?, allow: RuntimePermissionOption?) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if submitting { FlatProgressView().controlSize(.small) }
            Button(role: .cancel) {
                reply(reject.map { .permissionOption($0.id) } ?? .confirmed(false))
            } label: {
                confirmationLabel(reject, fallback: "拒绝", standardNames: ["deny", "deny once", "reject", "reject once"])
                    .frame(minWidth: adaptive ? 56 : nil)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined,
                                                outlineColor: adaptive ? ZivviTheme.selectionBorder.opacity(0.7) : nil))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(reject.map { "permission-option-\($0.id)" } ?? "interaction-no")
            Button {
                reply(allow.map { .permissionOption($0.id) } ?? .confirmed(true))
            } label: {
                confirmationLabel(allow, fallback: adaptive ? "允许本次" : "运行", standardNames: ["allow", "allow once"])
                    .frame(minWidth: adaptive ? 56 : nil)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
            .accessibilityIdentifier(allow.map { "permission-option-\($0.id)" } ?? "interaction-yes")
            .disabled(awaitingToolDetails)
        }
    }

    private func confirmationLabel(_ option: RuntimePermissionOption?, fallback: LocalizedStringKey,
                                   standardNames: Set<String>) -> Text {
        if let option, !standardNames.contains(option.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return Text(verbatim: option.name)
        }
        return Text(fallback)
    }

    private var permissionChoices: some View {
        let cancelOptionID = options.first(where: \.isReject)?.id
        return PermissionOptionFlowLayout(spacing: 8) {
            ForEach(options) { option in
                Button { reply(.permissionOption(option.id)) } label: { Text(verbatim: option.name) }
                    .buttonStyle(FlatControlButtonStyle(treatment: option.kind == .allowOnce ? .prominent : .outlined))
                    .keyboardShortcut(option.id == cancelOptionID ? .cancelAction : nil)
                    .accessibilityIdentifier("permission-option-\(option.id)")
                    .disabled(awaitingToolDetails && !option.isReject)
            }
        }
    }
}

private struct ToolApprovalDetails: View {
    let approval: RuntimeToolApproval
    var projectDirectory: String? = nil
    var showsDirectory = true
    @Binding var wrapsPreviewLines: Bool
    @State private var editExpanded = false

    var body: some View {
        switch approval.operation {
        case .command(let command, let timeout):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, timeout: timeout)
            CommandApprovalPreview(command: command, wrapsLines: $wrapsPreviewLines)
        case .write(let path, let content):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, path: path)
            ApprovalCodePreview(text: content, title: "写入内容", icon: "doc.text",
                                copyLabel: "复制写入内容", identifier: "file-approval", wrapsLines: $wrapsPreviewLines)
        case .edit(let path, let replacements):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, path: path)
            EditApprovalPreview(replacements: replacements, isExpanded: $editExpanded)
        case .inspect(_, let arguments):
            let path = arguments.first { $0.name == "path" }?.value
            let otherArguments = arguments.filter { $0.name != "path" }
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, path: path)
            if !otherArguments.isEmpty {
                ApprovalTextScrollView(text: otherArguments.map { "\($0.name) = \($0.value)" }.joined(separator: "\n"),
                                       maxHeight: 196)
                    .padding(ZivviSpacing.contentInset)
                    .flatSurface(ZivviTheme.mutedSurface, radius: 9)
            }
        }
    }
}

private extension RuntimeToolApproval.Inspection {
    var approvalTitle: LocalizedStringKey {
        switch self {
        case .read: "允许读取文件？"
        case .grep: "允许搜索文件内容？"
        case .find: "允许查找文件？"
        case .ls: "允许列出目录？"
        }
    }
}

private struct ToolApprovalMetadata: View {
    let workingDirectory: String
    var projectDirectory: String? = nil
    var showsDirectory = true
    var path: String? = nil
    var timeout: Double? = nil
    var compact = false

    var body: some View {
        if showsDirectory, !workingDirectory.isEmpty {
            ApprovalPathRow("会话目录", path: workingDirectory, projectDirectory: projectDirectory,
                            identifier: "approval-working-directory")
        }
        if let path {
            ApprovalPathRow("目标文件", path: path, projectDirectory: projectDirectory, relativeTo: workingDirectory,
                            identifier: "approval-file-path")
        }
        if let timeout {
            LabeledContent("执行超时") { Text("\(timeout.formatted()) 秒") }
                .zivviFont(compact ? .caption : .callout)
        }
    }
}

private func singleLineApprovalPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
}

enum ApprovalPathFormatter {
    struct RelatedPath: Identifiable {
        let id: Data
        let path: String
    }

    struct DiffGroup: Identifiable {
        let id: Data
        let path: String
        let changes: [RuntimePermissionContext.FileDiff]
    }

    static func relatedPaths(_ paths: [String], excluding diffs: [RuntimePermissionContext.FileDiff],
                             relativeTo directory: String? = nil,
                             deduplicateResolvedPaths: Bool = false) -> [RelatedPath] {
        var seen = Set(diffs.map { diff in
            let path = deduplicateResolvedPaths ? absolutePath(diff.path, relativeTo: directory) : diff.path
            return Data(path.utf8)
        })
        return paths.compactMap { path in
            let resolved = absolutePath(path, relativeTo: directory)
            let id = Data((deduplicateResolvedPaths ? resolved : path).utf8)
            guard seen.insert(id).inserted else { return nil }
            return RelatedPath(id: id, path: resolved)
        }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    static func distinctDirectory(_ directory: String?, from displayedDirectory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        if let displayedDirectory, directory.utf8.elementsEqual(displayedDirectory.utf8) { return nil }
        return directory
    }

    static func diffGroups(_ diffs: [RuntimePermissionContext.FileDiff], relativeTo directory: String? = nil,
                           deduplicateResolvedPaths: Bool = false) -> [DiffGroup] {
        let groups = Dictionary(grouping: diffs) { diff in
            let path = deduplicateResolvedPaths ? absolutePath(diff.path, relativeTo: directory) : diff.path
            return Data(path.utf8)
        }
        return groups.compactMap { id, changes in
            changes.first.map { DiffGroup(id: id, path: $0.path, changes: changes) }
        }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    static func absolutePath(_ path: String, relativeTo directory: String?) -> String {
        guard !path.hasPrefix("/"), let directory, directory.hasPrefix("/") else { return path }
        return directory.hasSuffix("/") ? directory + path : directory + "/" + path
    }

    static func displayPath(_ path: String, projectDirectory: String?, includesProjectName: Bool = true) -> String {
        guard let projectDirectory, projectDirectory.hasPrefix("/"), path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return path }
        // A file URL can normalize Unicode on macOS before the prefix comparison.
        let root = (projectDirectory as NSString).standardizingPath
        let rootName = (root as NSString).lastPathComponent
        guard !rootName.isEmpty, root != "/" else { return path }
        let prefix = root + "/"
        if path.utf8.elementsEqual(root.utf8) || path.utf8.elementsEqual(prefix.utf8) { return rootName }
        guard path.utf8.starts(with: prefix.utf8) else { return path }
        let relative = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return includesProjectName ? rootName + "/" + relative : relative
    }
}

private struct ApprovalInlineCode: View {
    let value: String

    var body: some View {
        Text(verbatim: value)
            .zivviFont(.caption, weight: .semibold, design: .monospaced)
            .foregroundStyle(ZivviTheme.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(ZivviTheme.selected, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ApprovalPathRow: View {
    let label: LocalizedStringKey?
    let path: String
    let projectDirectory: String?
    let relativeTo: String?
    let identifier: String

    init(_ label: LocalizedStringKey?, path: String, projectDirectory: String?, relativeTo: String? = nil, identifier: String) {
        self.label = label
        self.path = path
        self.projectDirectory = projectDirectory
        self.relativeTo = relativeTo
        self.identifier = identifier
    }

    var body: some View {
        let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: relativeTo)
        let displayed = singleLineApprovalPath(ApprovalPathFormatter.displayPath(
            absolute, projectDirectory: projectDirectory, includesProjectName: label != nil))
        ApprovalCopyArea(text: absolute, title: "复制路径", identifier: "\(identifier)-copy", alignment: .center) {
            HStack(alignment: .center, spacing: 12) {
                if let label {
                    Text(label).foregroundStyle(ZivviTheme.secondaryText).fixedSize()
                }
                ScrollView(.horizontal) {
                    Group {
                        if label != nil {
                            ApprovalInlineCode(value: displayed)
                        } else {
                            Text(verbatim: displayed)
                                .zivviFont(.caption, design: .monospaced)
                                .foregroundStyle(ZivviTheme.secondaryText)
                        }
                    }
                    .fixedSize()
                    .textSelection(.enabled)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .help(absolute)
                .accessibilityIdentifier(identifier)
            }
            .zivviFont(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ApprovalPathRows: View {
    let paths: [ApprovalPathFormatter.RelatedPath]
    let projectDirectory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(paths) { item in
                ApprovalPathRow("涉及文件", path: item.path, projectDirectory: projectDirectory,
                                identifier: "approval-affected-file")
            }
        }
    }
}

private struct ApprovalFileChanges: View {
    let diffs: [RuntimePermissionContext.FileDiff]
    let projectDirectory: String?
    let relativeTo: String?
    var compactPaths = false

    var body: some View {
        ForEach(ApprovalPathFormatter.diffGroups(diffs, relativeTo: relativeTo,
                                                 deduplicateResolvedPaths: compactPaths)) { group in
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                ApprovalPathRow(compactPaths ? nil : "目标文件", path: group.path, projectDirectory: projectDirectory,
                                relativeTo: relativeTo, identifier: "approval-file-path")
                VStack(spacing: 0) {
                    let changes = group.changes
                    ForEach(changes.indices, id: \.self) { index in
                        if index > 0 { ZivviDivider() }
                        let change = changes[index]
                        let endings = ApprovalDiffLines.changedEndings(for: change)
                        if let oldText = change.oldText {
                            ApprovalDiffLines(text: oldText, isAddition: false, ending: endings.old)
                        }
                        ApprovalDiffLines(text: change.newText, isAddition: true, ending: endings.new)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(ZivviTheme.border)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("edit-approval-preview")
            }
        }
    }
}

struct ApprovalDiffLines: View {
    let text: String
    let isAddition: Bool
    let ending: ToolEditDiff.Ending?

    static func changedEndings(for change: RuntimePermissionContext.FileDiff)
        -> (old: ToolEditDiff.Ending?, new: ToolEditDiff.Ending?) {
        guard let oldText = change.oldText else { return (nil, nil) }
        let old = oldText.last.flatMap { ToolEditDiff.Ending(rawValue: String($0)) } ?? .none
        let new = change.newText.last.flatMap { ToolEditDiff.Ending(rawValue: String($0)) } ?? .none
        return old == new ? (nil, nil) : (old, new)
    }

    var body: some View {
        let color = isAddition ? ZivviTheme.diffAddition : ZivviTheme.diffDeletion
        let mark = isAddition ? "+ " : "− "
        if text.utf8.count > 65_536 {
            let plain = plainMarkedText(mark)
            ApprovalTextScrollView(text: plain, maxHeight: 184)
                .foregroundStyle(color)
                .padding(.horizontal, ZivviSpacing.contentInset)
                .padding(.vertical, 6)
                .background(color.opacity(0.08))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isAddition ? Text("新增内容") : Text("移除内容"))
        } else {
            let rendered = markedText(mark, color: color)
            ApprovalTextScrollView(text: String(rendered.characters), maxHeight: 184, highlightedText: rendered)
                .foregroundStyle(color)
                .padding(.horizontal, ZivviSpacing.contentInset)
                .padding(.vertical, 6)
                .background(color.opacity(0.08))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isAddition ? Text("新增内容") : Text("移除内容"))
        }
    }

    private func plainMarkedText(_ mark: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        var result = lines.map { mark + $0 }.joined(separator: "\n")
        if let ending {
            result += " [\(ending.label)]"
        }
        return result
    }

    func markedText(_ mark: String, color: Color) -> AttributedString {
        var prefix = AttributedString(mark)
        prefix.swiftUI.foregroundColor = color
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += prefix
            result += AttributedString(line)
        }
        if let ending {
            var annotation = AttributedString(" [\(ending.label)]")
            annotation.swiftUI.foregroundColor = ZivviTheme.secondaryText
            result += annotation
        }
        return result
    }
}

struct EditApprovalPreview: View {
    let replacements: [RuntimeToolApproval.Replacement]
    @Binding var isExpanded: Bool
    var showsChangeCount = false
    private let heightLimit: CGFloat = 244

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            preview.padding(.top, ZivviSpacing.dialogItemGap)
        } label: {
            if showsChangeCount {
                HStack(spacing: 8) {
                    Text("查看修改 · \(replacements.count) 处",
                         comment: "Disclosure label followed by the number of edits in this approval.")
                        .zivviFont(.callout, weight: .semibold)
                    FlatDisclosureChevron(expanded: isExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZivviTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("修改内容").zivviFont(.callout, weight: .semibold)
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: showsChangeCount ? nil : .leading))
        .accessibilityIdentifier("edit-approval-preview")
    }

    private var preview: some View {
        ViewThatFits(in: .vertical) {
            changes.fixedSize(horizontal: false, vertical: true)
            ScrollView { changes }
                .frame(height: heightLimit)
        }
        .frame(maxHeight: heightLimit)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            ForEach(replacements.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                    if index > 0 { ZivviDivider() }
                    if replacements.count > 1 {
                        Text("第 \(index + 1) 处修改").zivviFont(.callout, weight: .semibold)
                    }
                    EditApprovalText(text: replacements[index].oldText, isReplacement: false)
                    EditApprovalText(text: replacements[index].newText, isReplacement: true)
                }
            }
        }
    }
}

private struct EditApprovalText: View {
    let text: String
    let isReplacement: Bool

    var body: some View {
        let tint = isReplacement ? ZivviTheme.diffAddition : ZivviTheme.diffDeletion
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
            LightningLabel(isReplacement ? "修改后" : "修改前", icon: isReplacement ? .plus : .minus, size: 12)
                .zivviFont(.caption, weight: .semibold)
                .foregroundStyle(tint)
            Group {
                if text.isEmpty {
                    Text("（空）").foregroundStyle(ZivviTheme.secondaryText)
                } else {
                    Text(verbatim: text)
                }
            }
            .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .flatSurface(tint.opacity(0.07), radius: 8, border: tint.opacity(0.25))
    }
}

struct CommandApprovalPreview: View {
    let command: String
    @Binding var wrapsLines: Bool
    @Environment(\.zivviTypography) private var typography

    var body: some View {
        ApprovalCodePreview(text: command, title: "Shell", icon: "terminal",
                            copyLabel: "复制命令", identifier: "command-approval", wrapsLines: $wrapsLines,
                            maxHeight: ApprovalSheetLayout.commandPreviewHeight(typography: typography))
    }
}

private struct ApprovalRawInputDisclosure: View {
    let json: String
    @Binding var isExpanded: Bool
    @Binding var wrapsLines: Bool
    @State private var hovered = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ApprovalJSONPreview(json: json, wrapsLines: $wrapsLines)
                .padding(.top, ZivviSpacing.dialogItemGap)
        } label: {
            HStack(spacing: 7) {
                Text("原始参数")
                FlatDisclosureChevron(expanded: isExpanded)
            }
            .padding(.trailing, IconButtonLabel.side + 6)
            .frame(minHeight: IconButtonLabel.side, alignment: .leading)
        }
        .zivviFont(.caption)
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil, showsHoverBackground: false,
                                                  showsPressedBackground: false))
        .overlay(alignment: .topTrailing) {
            if !isExpanded {
                ApprovalHoverCopy(text: json, title: "复制原始参数", identifier: "approval-raw-input-copy", hovered: hovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityIdentifier("approval-raw-input")
    }
}

struct ApprovalCopyArea<Content: View>: View {
    let text: String
    let title: LocalizedStringKey
    let identifier: String
    var alignment: VerticalAlignment = .top
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        HStack(alignment: alignment, spacing: 6) {
            content
            ApprovalHoverCopy(text: text, title: title, identifier: identifier, hovered: hovered)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

struct ApprovalHoverCopy: View {
    let text: String
    let title: LocalizedStringKey
    let identifier: String
    let hovered: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            LightningIconView(.docOnDoc, size: 13)
                .frame(width: IconButtonLabel.side)
        }
        .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: focused, inset: false, height: IconButtonLabel.side))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .help(title)
        .focused($focused)
        .revealedAction(hovered || focused)
    }
}

struct ApprovalJSONPreview: View {
    let json: String
    @Binding var wrapsLines: Bool
    @State private var cache = JSONHighlightCache()
    private static let highlightByteLimit = 65_536
    // Capture keys before strings, then literals and numbers. Preserve the source between matches.
    private static let tokens = try? NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*")(?=\s*:)|("(?:\\.|[^"\\])*")|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
    )

    @MainActor private final class JSONHighlightCache {
        private var cachedJSON: String?
        private var cachedHighlighted: AttributedString?

        func highlighted(for json: String) -> AttributedString? {
            guard json.utf8.count <= ApprovalJSONPreview.highlightByteLimit else { return nil }
            if cachedJSON == json, let cachedHighlighted {
                return cachedHighlighted
            }
            let built = ApprovalJSONPreview.buildHighlightedJSON(json)
            cachedJSON = json
            cachedHighlighted = built
            return built
        }
    }

    var body: some View {
        ApprovalCodePreview(text: json, title: "JSON", icon: "chevron.left.forwardslash.chevron.right",
                            copyLabel: "复制原始参数", identifier: "approval-raw-input", wrapsLines: $wrapsLines,
                            highlightedText: cache.highlighted(for: json))
    }

    private static func buildHighlightedJSON(_ json: String) -> AttributedString {
        guard let tokens else { return AttributedString(json) }
        var result = AttributedString()
        var cursor = json.startIndex
        for match in tokens.matches(in: json, range: NSRange(json.startIndex..., in: json)) {
            guard let range = Range(match.range, in: json) else { continue }
            result.append(AttributedString(json[cursor..<range.lowerBound]))
            var token = AttributedString(json[range])
            if match.range(at: 1).location != NSNotFound {
                token.swiftUI.foregroundColor = ZivviTheme.infoText
            } else if match.range(at: 2).location != NSNotFound {
                token.swiftUI.foregroundColor = ZivviTheme.runningText
            } else {
                token.swiftUI.foregroundColor = ZivviTheme.draftText
            }
            result.append(token)
            cursor = range.upperBound
        }
        result.append(AttributedString(json[cursor...]))
        return result
    }
}

struct ApprovalTextPreview: View {
    let text: String
    let identifier: String

    var body: some View {
        ApprovalTextScrollView(text: text, maxHeight: 196)
            .accessibilityIdentifier("\(identifier)-preview")
            .padding(ZivviSpacing.contentInset)
            .flatSurface(ZivviTheme.mutedSurface, radius: 9)
    }
}

struct ApprovalCodePreview: View {
    let text: String
    let title: LocalizedStringKey
    let icon: String
    let copyLabel: LocalizedStringKey
    let identifier: String
    @Binding var wrapsLines: Bool
    var maxHeight: CGFloat = 196
    var highlightedText: AttributedString? = nil
    var pasteboard: NSPasteboard? = nil

    private var byteSizeSummary: String? {
        let bytes = text.utf8.count
        guard bytes > 16_384 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack(spacing: 4) {
                LightningLabel(title, systemImage: icon, size: 13)
                    .zivviFont(.caption, weight: .semibold)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                    .lineLimit(1)
                if let byteSizeSummary {
                    Text(verbatim: "· \(byteSizeSummary)")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    wrapsLines.toggle()
                } label: {
                    IconButtonLabel(systemName: "arrow.turn.down.left")
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: wrapsLines, inset: false))
                .help("自动换行")
                .accessibilityLabel("自动换行")
                .accessibilityValue(wrapsLines ? Text("已开启") : Text("已关闭"))
                .accessibilityAddTraits(wrapsLines ? .isSelected : [])
                .accessibilityIdentifier("\(identifier)-wrap-lines")
                ApprovalCopyButton(text: text, title: copyLabel, identifier: "\(identifier)-copy", pasteboard: pasteboard)
            }
            .padding(.horizontal, ZivviSpacing.contentInset)
            .padding(.top, ZivviSpacing.contentInset)
            ApprovalTextScrollView(text: text, maxHeight: maxHeight, highlightedText: highlightedText, wrapsLines: wrapsLines)
                .accessibilityIdentifier("\(identifier)-preview")
                .padding(.horizontal, ZivviSpacing.contentInset)
                .padding(.bottom, ZivviSpacing.contentInset)
        }
        .approvalContentSurface(cornerRadius: 8)
    }
}

struct ApprovalCopyButton: View {
    let text: String
    let title: LocalizedStringKey
    let identifier: String
    var pasteboard: NSPasteboard? = nil

    var body: some View {
        Button {
            let board = pasteboard ?? .general
            board.clearContents()
            board.setString(text, forType: .string)
        } label: {
            IconButtonLabel(systemName: "doc.on.doc")
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct InteractionChoices: View {
    let options: [String]
    @Binding var selection: Int?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        let selected = selection == index
                        Button {
                            selection = index
                            focused = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: options[index])
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if selected {
                                    LightningIconView(.checkmark, size: 13)
                                }
                            }
                            .frame(minHeight: 20)
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: selected))
                        .focusable(false)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .flatSurface(ZivviTheme.workspace, radius: 9)
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                let next: Int
                switch direction {
                case .up: next = selection.map { $0 - 1 } ?? (options.count - 1)
                case .down: next = selection.map { $0 + 1 } ?? 0
                default: return
                }
                guard options.indices.contains(next) else { return }
                selection = next
                scroll.scrollTo(next)
            }
            .onKeyPress(.space) {
                guard selection == nil, let first = options.indices.first else { return .ignored }
                selection = first
                scroll.scrollTo(first)
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("扩展提供的选项")
        }
    }
}

private struct PermissionApprovalDetails: View {
    let request: RuntimeInteraction
    var projectDirectory: String? = nil
    var excludingTitle: String? = nil
    var excludingWorkingDirectory: String? = nil
    var compactFilePaths = false

    private var contextDetails: PermissionContextDetails? {
        request.permissionContext.map { context in
            PermissionContextDetails(context: context, projectDirectory: projectDirectory,
                                     excludingTitle: excludingTitle, excludingWorkingDirectory: excludingWorkingDirectory,
                                     compactFilePaths: compactFilePaths)
        }
    }

    private var showsMessage: Bool {
        !request.message.isEmpty && request.permissionContext?.summary != request.message
    }

    var hasAdditionalContent: Bool {
        contextDetails?.hasContent == true || showsMessage
    }

    var body: some View {
        if let contextDetails {
            contextDetails
        } else if request.toolApproval == nil, !request.title.isEmpty, request.title != excludingTitle {
            Text(verbatim: request.title)
                .zivviFont(.callout, weight: .semibold)
                .textSelection(.enabled)
        }
        if showsMessage {
            ApprovalTextPreview(text: request.message, identifier: "permission-message")
        }
    }
}

struct PermissionContextDetails: View {
    let context: RuntimePermissionContext
    let projectDirectory: String?
    var excludingTitle: String? = nil
    var excludingWorkingDirectory: String? = nil
    var compactFilePaths = false
    private var showsTitle: Bool {
        !context.toolTitle.isEmpty && context.toolTitle != excludingTitle
    }

    private var pathBase: String? {
        context.sessionDirectory ?? context.workingDirectory
    }

    var displayedWorkingDirectory: String? {
        ApprovalPathFormatter.distinctDirectory(pathBase, from: excludingWorkingDirectory)
    }

    var relatedPaths: [ApprovalPathFormatter.RelatedPath] {
        ApprovalPathFormatter.relatedPaths(context.paths, excluding: context.fileDiffs, relativeTo: pathBase,
                                          deduplicateResolvedPaths: compactFilePaths)
    }

    var hasContent: Bool {
        showsTitle || displayedWorkingDirectory != nil || !context.paths.isEmpty
            || context.summary?.isEmpty == false || !context.fileDiffs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if showsTitle {
                HStack(spacing: 6) {
                    ToolCallIcon(glyph: ToolCallKind(name: context.toolKind ?? context.toolTitle).glyph)
                    Text(verbatim: context.toolTitle)
                        .zivviFont(.callout, weight: .semibold)
                        .textSelection(.enabled)
                }
            }
            if let displayedWorkingDirectory {
                ApprovalPathRow("会话目录", path: displayedWorkingDirectory, projectDirectory: projectDirectory,
                                identifier: "approval-working-directory")
            }
            let relatedPaths = self.relatedPaths
            if !relatedPaths.isEmpty {
                ApprovalPathRows(paths: relatedPaths, projectDirectory: projectDirectory)
            }
            if let summary = context.summary, !summary.isEmpty {
                ApprovalTextPreview(text: summary, identifier: "permission-summary")
            }
            if !context.fileDiffs.isEmpty {
                ApprovalFileChanges(diffs: context.fileDiffs, projectDirectory: projectDirectory,
                                    relativeTo: pathBase, compactPaths: compactFilePaths)
            }
        }
    }
}

private struct PermissionOptionFlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignsLeading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { partial, row in
            partial + (partial > 0 ? spacing : 0) + row.height
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = alignsLeading ? bounds.minX : bounds.maxX - row.width
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(subview: LayoutSubview, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = ideal.width <= maxWidth ? ideal : subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append((subview, size))
            current.width = current.items.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
