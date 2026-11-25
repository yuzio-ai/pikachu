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
    @Environment(\.pikachuTypography) private var typography
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
        request.isPermissionApproval && (request.toolApproval?.operation.usesAdaptiveSheet ?? true)
    }

    var body: some View {
        Group {
            if usesAdaptiveSheet {
                ApprovalHeightLayout(maximumHeight: availableSize.height > 0
                                     ? max(1, availableSize.height - 2 * ApprovalSheetLayout.inset) : nil) {
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
            } else {
                interactionContent
            }
        }
        .scrollIndicators(.never)
        .interactiveDismissDisabled(submitting)
        .onChange(of: request.toolApproval, initial: true) {
            preferredApprovalWidth = request.toolApproval.flatMap {
                ApprovalSheetLayout.preferredWidth(for: $0, typography: typography, projectDirectory: projectDirectory)
            }
        }
        .task(id: request.id) { await Task.yield(); focused = request.kind == .input || request.kind == .editor }
        .onDisappear {
            if !completed && controller.interactions.contains(where: { $0.id == request.id }) {
                Task { await controller.reply(request, .cancelled) }
            }
        }
    }

    private var interactionContent: some View {
        Group {
            if expired {
                VStack(alignment: .leading, spacing: 12) {
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
                        Button("关闭") { dismiss() }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("interaction-close-expired")
                    }
                    .layoutPriority(1)
                }
                .padding(20)
            } else if let elicitation = request.elicitation {
                VStack(alignment: .leading, spacing: 10) {
                    ACPElicitationView(request: request, elicitation: elicitation, submitting: submitting, reply: submit)
                    if let notice = controller.notice { Text(notice).foregroundStyle(PikachuTheme.secondaryText) }
                    if let error = controller.failure { Text(error.detail).foregroundStyle(PikachuTheme.errorText) }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("请求已过期，未提交回复")
                .pikachuFont(.title2, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Text("会话：\(sessionTitle)").pikachuFont(.caption).foregroundStyle(.secondary)
            InteractionDeadline(expiresAt: request.expiresAt)
            ExpiredInteractionDetails(request: request, projectDirectory: projectDirectory)
        }
    }

    private var approvalSheetWidth: CGFloat {
        guard request.isPermissionApproval else { return 560 }
        guard let toolApproval = request.toolApproval else {
            return ApprovalSheetLayout.width(preferred: 640, available: availableSize.width)
        }
        guard let preferred = preferredApprovalWidth
            ?? ApprovalSheetLayout.preferredWidth(for: toolApproval, typography: typography, projectDirectory: projectDirectory) else { return 740 }
        return ApprovalSheetLayout.width(preferred: preferred, available: availableSize.width)
    }

    private var extensionRequest: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.authenticationMethods.isEmpty ? "扩展请求" : "ACP Agent 登录")
                .pikachuFont(.caption).foregroundStyle(.secondary)
            Text(request.title).pikachuFont(.title2).textSelection(.enabled)
            Text("会话：\(sessionTitle)").pikachuFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            InteractionDeadline(expiresAt: request.expiresAt)
            if !request.message.isEmpty {
                ScrollView {
                    Text(request.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8).flatSurface(PikachuTheme.mutedSurface, radius: 9)
            }
            switch request.kind {
            case .select:
                InteractionChoices(options: request.authenticationMethods.isEmpty ? request.options : request.authenticationMethods.map { method in
                    method.kind == .terminal ? String(localized: "\(method.name)（终端）") : method.name
                }, selection: $selection)
            case .input:
                TextField(request.placeholder.isEmpty ? String(localized: "回复内容") : request.placeholder, text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .padding(8).flatSurface(PikachuTheme.workspace, radius: 9, border: PikachuTheme.inputBorder(focused: focused))
                    .accessibilityIdentifier("interaction-input").accessibilityLabel("扩展单行回复")
            case .editor:
                TextEditor(text: $text).pikachuFont(.body, design: .monospaced).frame(height: 220)
                    .scrollContentBackground(.hidden).focused($focused)
                    .padding(8).flatSurface(PikachuTheme.workspace, radius: 9, border: PikachuTheme.inputBorder(focused: focused))
                    .accessibilityIdentifier("interaction-editor").accessibilityLabel("扩展多行回复")
                Text("按回车键换行，按 ⌘↩ 提交。文本上限 1 MiB。").pikachuFont(.caption).foregroundStyle(.secondary)
            case .confirm: EmptyView()
            }
            if let message = controller.notice { Text(message).pikachuFont(.caption).foregroundStyle(.secondary) }
            if let error = controller.failure { Text(error.detail).pikachuFont(.caption).foregroundStyle(PikachuTheme.errorText) }
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
    static let previewInset: CGFloat = 12

    static func preferredWidth(
        for operation: RuntimeToolApproval.Operation,
        typography: PikachuTypography,
        workingDirectory: String? = nil,
        projectDirectory: String? = nil
    ) -> CGFloat? {
        let regularWidth: CGFloat = 640
        let wideWidth: CGFloat = 700
        let bodyWidth = regularWidth - 2 * inset
        let font = previewFont(typography)

        switch operation {
        case .command(let command, _):
            let textWidth = bodyWidth - 2 * previewInset - IconButtonLabel.side - 6
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            let size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            let needsWideLayout = command.split(whereSeparator: \.isNewline).contains { line in
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
        for approval: RuntimeToolApproval, typography: PikachuTypography, projectDirectory: String?
    ) -> CGFloat? {
        preferredWidth(for: approval.operation, typography: typography,
                       workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory)
    }

    static func commandPreviewHeight(typography: PikachuTypography) -> CGFloat {
        8 * ceil(NSLayoutManager().defaultLineHeight(for: previewFont(typography)))
    }

    private static func previewFont(_ typography: PikachuTypography) -> NSFont {
        .monospacedSystemFont(ofSize: typography.pointSize(for: .body), weight: .regular)
    }
}

struct InteractionDeadline: View {
    let expiresAt: Date

    var body: some View {
        let deadline = expiresAt.formatted(date: .abbreviated, time: .standard)
        Label("回复截止时间：\(deadline)", systemImage: "clock")
            .pikachuFont(.caption)
            .foregroundStyle(PikachuTheme.secondaryText)
            .monospacedDigit()
            .accessibilityIdentifier("interaction-deadline")
    }
}

struct InteractionCountdown: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = remainingDuration(relativeTo: context.date)
                .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
            let digits = Text(verbatim: remaining).fontWeight(.semibold).monospacedDigit()
                .foregroundColor(PikachuTheme.primaryText)
            Label("剩余 \(digits)", systemImage: "clock")
                .pikachuFont(.caption)
                .foregroundStyle(PikachuTheme.secondaryText)
                .accessibilityIdentifier("interaction-countdown")
        }
    }

    func remainingDuration(relativeTo now: Date) -> Duration {
        .seconds(max(0, expiresAt.timeIntervalSince(now).rounded(.up)))
    }
}

struct ExpiredInteractionDetails: View {
    let request: RuntimeInteraction
    var projectDirectory: String? = nil
    var contentChanged: () -> Void = {}
    @State private var permissionDetailsExpanded = false
    @State private var rawInputExpanded = false

    var additionalWorkingDirectory: String? {
        ApprovalPathFormatter.distinctDirectory(request.toolApproval?.workingDirectory,
                                               from: request.permissionContext?.sessionDirectory)
    }

    private var showsRequestTitle: Bool {
        guard !request.title.isEmpty else { return false }
        if case .command(let command, _)? = request.toolApproval?.operation {
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
                != request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return true
    }

    var body: some View {
        let options = request.permissionOptions.isEmpty ? request.options : request.permissionOptions.map(\.name)
        let sessionDirectory = request.permissionContext?.sessionDirectory
        let permissionDetails = PermissionApprovalDetails(request: request, projectDirectory: projectDirectory,
                                                          excludingTitle: request.title,
                                                          excludingWorkingDirectory: request.toolApproval.map { sessionDirectory ?? $0.workingDirectory })
        VStack(alignment: .leading, spacing: 10) {
            if showsRequestTitle {
                Text(verbatim: request.title)
                    .pikachuFont(.callout, weight: .semibold)
                    .textSelection(.enabled)
            }
            if let approval = request.toolApproval {
                if let sessionDirectory, !sessionDirectory.isEmpty {
                    ApprovalPathRow("会话目录", path: sessionDirectory, projectDirectory: projectDirectory,
                                    identifier: "approval-working-directory")
                    if let additionalWorkingDirectory {
                        ApprovalPathRow("工作目录", path: additionalWorkingDirectory, projectDirectory: projectDirectory,
                                        relativeTo: sessionDirectory, identifier: "approval-command-directory")
                    }
                }
                ToolApprovalDetails(approval: approval, projectDirectory: projectDirectory,
                                    showsDirectory: sessionDirectory?.isEmpty != false)
            } else if !request.permissionOptions.isEmpty {
                permissionDetails
            } else if !request.message.isEmpty {
                ApprovalTextScrollView(text: request.message, maxHeight: 180)
            }
            if let rawInput = request.permissionContext?.rawInputJSON {
                ApprovalRawInputDisclosure(json: rawInput, isExpanded: $rawInputExpanded)
                    .onChange(of: rawInputExpanded) { _, _ in contentChanged() }
            }
            if request.toolApproval == nil || !request.permissionOptions.isEmpty, !options.isEmpty {
                ExpiredInteractionOptions(options: options)
            }
            if request.toolApproval != nil, !request.permissionOptions.isEmpty, permissionDetails.hasAdditionalContent {
                DisclosureGroup(isExpanded: $permissionDetailsExpanded) {
                    permissionDetails.padding(.top, 8)
                } label: {
                    Text("审批详情")
                        .pikachuFont(.caption)
                        .foregroundStyle(PikachuTheme.secondaryText)
                }
                .disclosureGroupStyle(FlatDisclosureStyle(showsHoverBackground: false))
                .onChange(of: permissionDetailsExpanded) { _, _ in contentChanged() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .pikachuFont(.callout)
        .foregroundStyle(PikachuTheme.secondaryText)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("工具调用失败")
                        .pikachuFont(.title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if failures.count > 1 {
                        HStack(spacing: 6) {
                            Button {
                                stepFailure(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .pikachuFont(.caption, weight: .semibold)
                            }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                            .disabled(currentFailureIndex <= 0)
                            .help("上一个失败")
                            .accessibilityLabel("上一个失败")
                            .accessibilityIdentifier("tool-failure-prev")

                            Text(verbatim: "\(currentFailureIndex + 1) / \(failures.count)")
                                .pikachuFont(.caption)
                                .foregroundStyle(PikachuTheme.secondaryText)
                                .monospacedDigit()
                                .accessibilityIdentifier("tool-failure-page")

                            Button {
                                stepFailure(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .pikachuFont(.caption, weight: .semibold)
                            }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                            .disabled(currentFailureIndex >= failures.count - 1)
                            .help("下一个失败")
                            .accessibilityLabel("下一个失败")
                            .accessibilityIdentifier("tool-failure-next")
                        }
                    }
                }
                PikachuDivider()
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
                        LazyVStack(alignment: .leading, spacing: 12) {
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
            PikachuDivider()
            HStack {
                Spacer()
                Button("关闭", action: close)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    ToolCallIcon(tool: tool.name)
                    Text(verbatim: tool.name)
                        .pikachuFont(.callout, weight: .semibold, design: .monospaced)
                }
                if tool.output.isEmpty {
                    Text("没有可用的工具输出。").pikachuFont(.caption).foregroundStyle(.secondary)
                }
                ToolDetails(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .flatSurface(PikachuTheme.mutedSurface, radius: 9)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("任务计划")
                        .pikachuFont(.title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(completed)/\(entries.count) 已完成")
                            .pikachuFont(.caption)
                            .foregroundStyle(PikachuTheme.secondaryText)
                    }
                }
                PikachuDivider()
                if entries.isEmpty {
                    Text("当前暂无任务计划。")
                        .pikachuFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: statusIcon(for: entry.status))
                                        .pikachuFont(.callout)
                                        .foregroundStyle(statusColor(for: entry.status))
                                        .frame(width: 16, height: 18)
                                        .accessibilityHidden(true)
                                    Text(verbatim: entry.content)
                                        .pikachuFont(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(statusLabel(for: entry.status))
                                        .pikachuFont(.caption)
                                        .foregroundStyle(statusColor(for: entry.status))
                                        .fixedSize()
                                }
                                .padding(10)
                                .flatSurface(PikachuTheme.mutedSurface, radius: 9)
                            }
                        }
                        .padding(1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(idealHeight: 240, maxHeight: 340)
                }
            }
            .padding(20)
            PikachuDivider()
            HStack {
                Spacer()
                Button("关闭", action: close)
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
        case .completed: PikachuTheme.runningText
        case .inProgress: PikachuTheme.infoText
        case .pending: PikachuTheme.tertiaryText
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
        .onChange(of: request.id) { rawInputExpanded = false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolApprovalHeader(title: request.title, operation: request.toolApproval?.operation,
                               toolName: request.permissionContext?.toolName, toolKind: request.permissionContext?.toolKind,
                               usesLocalToolIdentity: request.permissionOptions.isEmpty, expiresAt: request.expiresAt,
                               adaptive: adaptive)
            ActiveApprovalDetails(approval: request.toolApproval, context: request.permissionContext,
                                  message: request.permissionOptions.isEmpty ? "" : request.message,
                                  projectDirectory: projectDirectory)
            if let rawInput = request.permissionContext?.rawInputJSON {
                ApprovalRawInputDisclosure(json: rawInput, isExpanded: $rawInputExpanded)
            }
            if let notice { Text(verbatim: notice).pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText) }
            if let error { Text(verbatim: error).pikachuFont(.caption).foregroundStyle(PikachuTheme.errorText) }
        }
        .padding(adaptive ? ApprovalSheetLayout.inset : 20)
    }
}

struct ActiveApprovalDetails: View {
    let approval: RuntimeToolApproval?
    let context: RuntimePermissionContext?
    let message: String
    let projectDirectory: String?

    private var sessionDirectory: String? { context?.sessionDirectory ?? approval?.workingDirectory ?? context?.workingDirectory }
    var commandDirectory: String? {
        guard context?.toolKind == "execute" else { return nil }
        return ApprovalPathFormatter.distinctDirectory(context?.workingDirectory, from: sessionDirectory)
    }
    var relatedPaths: [ApprovalPathFormatter.RelatedPath] {
        ApprovalPathFormatter.relatedPaths(context?.paths ?? [], excluding: context?.fileDiffs ?? [],
                                          relativeTo: sessionDirectory)
    }
    private var isCommand: Bool {
        if case .command? = approval?.operation { return true }
        return context?.toolKind == "execute"
    }
    var commandSummaries: [String] {
        let rawSummary = context?.toolSummary
        let standardSummary = context?.summary ?? message
        return [rawSummary, standardSummary == rawSummary ? nil : standardSummary].compactMap { value in
            guard let value, !value.isEmpty, value != context?.toolTitle else { return nil }
            return value
        }
    }

    var body: some View {
        if let sessionDirectory, !sessionDirectory.isEmpty {
            ApprovalPathRow("会话目录", path: sessionDirectory, projectDirectory: projectDirectory,
                            identifier: "approval-working-directory")
        } else {
            LabeledContent("会话目录") { Text("未知") }
                .pikachuFont(.caption)
        }
        let diffs = context?.fileDiffs ?? []
        let relatedPaths = self.relatedPaths
        if !relatedPaths.isEmpty {
            ApprovalPathRows(paths: relatedPaths, projectDirectory: projectDirectory)
        }
        if let commandDirectory {
            ApprovalPathRow("工作目录", path: commandDirectory, projectDirectory: projectDirectory,
                            relativeTo: sessionDirectory, identifier: "approval-command-directory")
        }
        if context?.awaitingToolDetails == true {
            Text("等待操作详情")
                .pikachuFont(.callout)
                .foregroundStyle(PikachuTheme.secondaryText)
        }
        if isCommand {
            ForEach(commandSummaries, id: \.self) { summary in
                Text(verbatim: summary).pikachuFont(.callout).textSelection(.enabled)
            }
        } else if let summary = context?.toolSummary, !summary.isEmpty, summary != context?.toolTitle {
            Text(verbatim: summary).pikachuFont(.callout).textSelection(.enabled)
        }
        if let approval {
            switch approval.operation {
            case .command(let command, let timeout):
                CommandApprovalPreview(command: command)
                if let timeout {
                    LabeledContent("执行超时") { Text("\(timeout.formatted()) 秒") }
                        .pikachuFont(.caption)
                }
            case .edit(let path, let replacements):
                ApprovalFileChanges(diffs: replacements.map { .init(path: path, oldText: $0.oldText, newText: $0.newText) },
                                    projectDirectory: projectDirectory, relativeTo: sessionDirectory)
            case .write, .inspect:
                ToolApprovalDetails(approval: approval, projectDirectory: projectDirectory, showsDirectory: false)
            }
        }
        let summary = context?.summary ?? message
        if !isCommand, !summary.isEmpty, summary != context?.toolSummary {
            ApprovalTextPreview(text: summary, identifier: "permission-summary")
        }
        if !diffs.isEmpty {
            ApprovalFileChanges(diffs: diffs, projectDirectory: projectDirectory, relativeTo: sessionDirectory)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                (title.isEmpty ? Text(fallbackTitle) : Text(verbatim: title))
                    .pikachuFont(.title2, weight: .semibold)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if adaptive {
                    Spacer(minLength: 0)
                    InteractionCountdown(expiresAt: expiresAt)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            subtitle
                .pikachuFont(.caption)
                .foregroundStyle(PikachuTheme.secondaryText)
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

private struct ToolApprovalFooter: View {
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
                Rectangle().fill(PikachuTheme.subtleDivider)
                    .frame(height: 1)
                    .padding(.horizontal, ApprovalSheetLayout.inset)
                    .accessibilityHidden(true)
            } else {
                PikachuDivider()
            }
            VStack(spacing: 10) {
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
                                                outlineColor: adaptive ? PikachuTheme.selectionBorder.opacity(0.7) : nil))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(reject.map { "permission-option-\($0.id)" } ?? "interaction-no")
            Button {
                reply(allow.map { .permissionOption($0.id) } ?? .confirmed(true))
            } label: {
                confirmationLabel(allow, fallback: adaptive ? "允许" : "运行", standardNames: ["allow", "allow once"])
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
        PermissionOptionFlowLayout(spacing: 8) {
            ForEach(options) { option in
                Button { reply(.permissionOption(option.id)) } label: { Text(verbatim: option.name) }
                    .buttonStyle(FlatControlButtonStyle(treatment: option.kind == .allowOnce ? .prominent : .outlined))
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
    @State private var editExpanded = false

    var body: some View {
        switch approval.operation {
        case .command(let command, let timeout):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, timeout: timeout)
            CommandApprovalPreview(command: command)
        case .write(let path, let content):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, projectDirectory: projectDirectory, showsDirectory: showsDirectory, path: path)
            Text("写入内容").pikachuFont(.callout, weight: .semibold)
            ApprovalTextPreview(text: content, copyLabel: "复制写入内容", identifier: "file-approval")
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
                    .padding(10)
                    .flatSurface(PikachuTheme.mutedSurface, radius: 9)
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
                .pikachuFont(compact ? .caption : .callout)
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
                             relativeTo directory: String? = nil) -> [RelatedPath] {
        var seen = Set(diffs.map { Data($0.path.utf8) })
        return paths.compactMap { path in
            let id = Data(path.utf8)
            guard seen.insert(id).inserted else { return nil }
            return RelatedPath(id: id, path: absolutePath(path, relativeTo: directory))
        }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    static func distinctDirectory(_ directory: String?, from displayedDirectory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        if let displayedDirectory, directory.utf8.elementsEqual(displayedDirectory.utf8) { return nil }
        return directory
    }

    static func diffGroups(_ diffs: [RuntimePermissionContext.FileDiff]) -> [DiffGroup] {
        let groups = Dictionary(grouping: diffs) { Data($0.path.utf8) }
        return groups.compactMap { id, changes in
            changes.first.map { DiffGroup(id: id, path: $0.path, changes: changes) }
        }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    static func absolutePath(_ path: String, relativeTo directory: String?) -> String {
        guard !path.hasPrefix("/"), let directory, directory.hasPrefix("/") else { return path }
        return directory.hasSuffix("/") ? directory + path : directory + "/" + path
    }

    static func displayPath(_ path: String, projectDirectory: String?) -> String {
        guard let projectDirectory, projectDirectory.hasPrefix("/"), path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return path }
        // A file URL can normalize Unicode on macOS before the prefix comparison.
        let root = (projectDirectory as NSString).standardizingPath
        let rootName = (root as NSString).lastPathComponent
        guard !rootName.isEmpty, root != "/" else { return path }
        let prefix = root + "/"
        if path.utf8.elementsEqual(root.utf8) || path.utf8.elementsEqual(prefix.utf8) { return rootName }
        guard path.utf8.starts(with: prefix.utf8) else { return path }
        return rootName + "/" + String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
}

private struct ApprovalInlineCode: View {
    let value: String

    var body: some View {
        Text(verbatim: value)
            .pikachuFont(.caption, weight: .semibold, design: .monospaced)
            .foregroundStyle(PikachuTheme.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(PikachuTheme.selected, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ApprovalPathRow: View {
    let label: LocalizedStringKey
    let path: String
    let projectDirectory: String?
    let relativeTo: String?
    let identifier: String

    init(_ label: LocalizedStringKey, path: String, projectDirectory: String?, relativeTo: String? = nil, identifier: String) {
        self.label = label
        self.path = path
        self.projectDirectory = projectDirectory
        self.relativeTo = relativeTo
        self.identifier = identifier
    }

    var body: some View {
        let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: relativeTo)
        let displayed = ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory)
        ApprovalCopyArea(text: absolute, title: "复制路径", identifier: "\(identifier)-copy", alignment: .center) {
            HStack(alignment: .center, spacing: 12) {
                Text(label).foregroundStyle(PikachuTheme.secondaryText).fixedSize()
                ScrollView(.horizontal) {
                    ApprovalInlineCode(value: singleLineApprovalPath(displayed))
                        .fixedSize()
                        .textSelection(.enabled)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .help(absolute)
                .accessibilityIdentifier(identifier)
            }
            .pikachuFont(.caption)
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

    var body: some View {
        ForEach(ApprovalPathFormatter.diffGroups(diffs)) { group in
            ApprovalPathRow("目标文件", path: group.path, projectDirectory: projectDirectory,
                            relativeTo: relativeTo, identifier: "approval-file-path")
            VStack(spacing: 0) {
                let changes = group.changes
                ForEach(changes.indices, id: \.self) { index in
                    if index > 0 { PikachuDivider() }
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
                RoundedRectangle(cornerRadius: 8).strokeBorder(PikachuTheme.border)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("edit-approval-preview")
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
        let color = isAddition ? PikachuTheme.runningText : PikachuTheme.errorText
        let mark = isAddition ? "+ " : "− "
        let rendered = markedText(mark, color: color)
        ApprovalTextScrollView(text: String(rendered.characters), maxHeight: 184, highlightedText: rendered)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.08))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isAddition ? Text("新增内容") : Text("移除内容"))
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
            annotation.swiftUI.foregroundColor = PikachuTheme.secondaryText
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
            preview.padding(.top, 6)
        } label: {
            if showsChangeCount {
                HStack(spacing: 8) {
                    Text("查看修改 · \(replacements.count) 处",
                         comment: "Disclosure label followed by the number of edits in this approval.")
                        .pikachuFont(.callout, weight: .semibold)
                    FlatDisclosureChevron(expanded: isExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PikachuTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("修改内容").pikachuFont(.callout, weight: .semibold)
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(replacements.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    if index > 0 { PikachuDivider() }
                    if replacements.count > 1 {
                        Text("第 \(index + 1) 处修改").pikachuFont(.callout, weight: .semibold)
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
        let tint = isReplacement ? PikachuTheme.runningText : PikachuTheme.errorText
        VStack(alignment: .leading, spacing: 4) {
            Label(isReplacement ? "修改后" : "修改前", systemImage: isReplacement ? "plus" : "minus")
                .pikachuFont(.caption, weight: .semibold)
                .foregroundStyle(tint)
            ApprovalVerbatimText(text: text).textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .flatSurface(tint.opacity(0.07), radius: 8, border: tint.opacity(0.25))
    }
}

struct CommandApprovalPreview: View {
    let command: String
    @Environment(\.pikachuTypography) private var typography

    var body: some View {
        ApprovalCopyArea(text: command, title: "复制命令", identifier: "command-approval-copy") {
            ApprovalTextScrollView(text: command, maxHeight: ApprovalSheetLayout.commandPreviewHeight(typography: typography))
                .accessibilityIdentifier("command-approval-preview")
        }
        .padding(ApprovalSheetLayout.previewInset)
        .flatSurface(PikachuTheme.mutedSurface, radius: 9)
    }
}

private struct ApprovalRawInputDisclosure: View {
    let json: String
    @Binding var isExpanded: Bool
    @State private var hovered = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ApprovalJSONPreview(json: json)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Text("原始参数")
                FlatDisclosureChevron(expanded: isExpanded)
            }
            .padding(.trailing, IconButtonLabel.side + 6)
            .frame(minHeight: IconButtonLabel.side, alignment: .leading)
        }
        .pikachuFont(.caption)
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil, showsHoverBackground: false))
        .overlay(alignment: .topTrailing) {
            ApprovalHoverCopy(text: json, title: "复制原始参数", identifier: "approval-raw-input-copy", hovered: hovered)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityIdentifier("approval-raw-input")
    }
}

private struct ApprovalCopyArea<Content: View>: View {
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

private struct ApprovalHoverCopy: View {
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
            Image(systemName: "doc.on.doc")
                .pikachuFont(.caption)
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

private struct ApprovalJSONPreview: View {
    let json: String
    // Capture keys before strings, then literals and numbers. Preserve the source between matches.
    private static let tokens = try? NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*")(?=\s*:)|("(?:\\.|[^"\\])*")|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
    )

    var body: some View {
        ApprovalTextScrollView(text: json, maxHeight: 196, highlightedText: highlightedJSON)
            .accessibilityIdentifier("approval-raw-input-preview")
            .padding(10)
            .flatSurface(PikachuTheme.mutedSurface, radius: 9)
    }

    private var highlightedJSON: AttributedString {
        guard let tokens = Self.tokens else { return AttributedString(json) }
        var result = AttributedString()
        var cursor = json.startIndex
        for match in tokens.matches(in: json, range: NSRange(json.startIndex..., in: json)) {
            guard let range = Range(match.range, in: json) else { continue }
            result += AttributedString(json[cursor..<range.lowerBound])
            var token = AttributedString(json[range])
            if match.range(at: 1).location != NSNotFound {
                token.swiftUI.foregroundColor = PikachuTheme.infoText
            } else if match.range(at: 2).location != NSNotFound {
                token.swiftUI.foregroundColor = PikachuTheme.runningText
            } else {
                token.swiftUI.foregroundColor = PikachuTheme.draftText
            }
            result += token
            cursor = range.upperBound
        }
        result += AttributedString(json[cursor...])
        return result
    }
}

struct ApprovalTextPreview: View {
    let text: String
    var copyLabel: LocalizedStringKey? = nil
    let identifier: String
    var pasteboard: NSPasteboard? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let copyLabel {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ApprovalCopyButton(text: text, title: copyLabel, identifier: "\(identifier)-copy", pasteboard: pasteboard)
                }
            }
            ApprovalTextScrollView(text: text, maxHeight: 196)
                .accessibilityIdentifier("\(identifier)-preview")
        }
        .padding(10)
        .flatSurface(PikachuTheme.mutedSurface, radius: 9)
    }
}

private struct ApprovalCopyButton: View {
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
            Label(title, systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
                .pikachuFont(.caption)
        }
        .buttonStyle(FlatControlButtonStyle())
        .help(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct ApprovalTextScrollView: View {
    let text: String
    let maxHeight: CGFloat
    var highlightedText: AttributedString? = nil

    var body: some View {
        // Measure the wrapped text so short previews hug their contents.
        ApprovalVerbatimText(text: text, highlightedText: highlightedText)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: maxHeight)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                ScrollView {
                    ApprovalVerbatimText(text: text, highlightedText: highlightedText).textSelection(.enabled)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
    }
}

private struct ApprovalVerbatimText: View {
    let text: String
    var highlightedText: AttributedString? = nil

    var body: some View {
        Group {
            if text.isEmpty {
                Text("（空）").foregroundStyle(PikachuTheme.secondaryText)
            } else if let highlightedText {
                Text(highlightedText)
            } else {
                Text(verbatim: text)
            }
        }
        .pikachuFont(.body, design: .monospaced)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                    Image(systemName: "checkmark")
                                        .pikachuFont(.caption, weight: .semibold)
                                        .accessibilityHidden(true)
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
            .flatSurface(PikachuTheme.workspace, radius: 9)
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

    private var contextDetails: PermissionContextDetails? {
        request.permissionContext.map { context in
            PermissionContextDetails(context: context, projectDirectory: projectDirectory,
                                     excludingTitle: excludingTitle, excludingWorkingDirectory: excludingWorkingDirectory)
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
                .pikachuFont(.callout, weight: .semibold)
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
        ApprovalPathFormatter.relatedPaths(context.paths, excluding: context.fileDiffs, relativeTo: pathBase)
    }

    var hasContent: Bool {
        showsTitle || displayedWorkingDirectory != nil || !context.paths.isEmpty
            || context.summary?.isEmpty == false || !context.fileDiffs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                HStack(spacing: 6) {
                    ToolCallIcon(tool: context.toolKind ?? context.toolTitle)
                    Text(verbatim: context.toolTitle)
                        .pikachuFont(.callout, weight: .semibold)
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
                                    relativeTo: pathBase)
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
