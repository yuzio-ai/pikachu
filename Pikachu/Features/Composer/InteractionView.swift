import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

enum WorkbenchModal: Identifiable {
    case interaction(RuntimeInteraction, SessionController, String)
    case toolFailures([TranscriptItem])
    case settings(SettingsSection)
    case chooseSessionProject
    case confirmation(ConfirmationRequest)
    var id: String {
        switch self {
        case .interaction(let request, _, _): request.id
        case .toolFailures: "tool-failures"
        case .settings: "settings"
        case .chooseSessionProject: "choose-session-project"
        case .confirmation(let request): request.id.uuidString
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
    init(request: RuntimeInteraction, controller: SessionController, sessionTitle: String) {
        self.request = request; self.controller = controller; self.sessionTitle = sessionTitle
        _text = State(initialValue: request.prefill)
    }
    private var expired: Bool { controller.didExpire(request) }
    private var toolApproval: RuntimeToolApproval? { request.kind == .confirm ? request.toolApproval : nil }

    var body: some View {
        Group {
            if expired {
                VStack(alignment: .leading, spacing: 12) {
                    Text("请求已过期，未提交回复")
                        .pikachuFont(.title2, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("会话：\(sessionTitle)").pikachuFont(.caption).foregroundStyle(.secondary)
                    InteractionDeadline(expiresAt: request.expiresAt)
                    ExpiredInteractionDetails(request: request)
                    HStack {
                        Spacer()
                        Button("关闭") { dismiss() }
                            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(20)
            } else if let approval = toolApproval {
                ToolApprovalSheet(approval: approval, sessionTitle: sessionTitle, expiresAt: request.expiresAt,
                                  notice: controller.notice, error: controller.failure?.detail,
                                  submitting: submitting, reply: submit)
            } else {
                extensionRequest
            }
        }
        .frame(width: approvalSheetWidth)
        .interactiveDismissDisabled(submitting)
        .task(id: request.id) { await Task.yield(); focused = request.kind == .input || request.kind == .editor }
        .onDisappear {
            if !completed && controller.interactions.contains(where: { $0.id == request.id }) {
                Task { await controller.reply(request, .cancelled) }
            }
        }
    }

    private var approvalSheetWidth: CGFloat {
        guard let toolApproval else { return 560 }
        if case .edit = toolApproval.operation { return 620 }
        return 740
    }

    private var extensionRequest: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扩展请求").pikachuFont(.caption).foregroundStyle(.secondary)
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
                InteractionChoices(options: request.options, selection: $selection)
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
                        if request.kind == .select, let selection { submit(.value(request.options[selection])) }
                        else { submit(.value(text)) }
                    }.buttonStyle(FlatControlButtonStyle(treatment: .prominent)).keyboardShortcut(.return, modifiers: request.kind == .editor ? .command : [])
                        .disabled(request.kind == .select && selection == nil).accessibilityIdentifier("interaction-submit")
                }
            }.buttonStyle(FlatControlButtonStyle(treatment: .outlined)).disabled(submitting)
        }.padding(24)
    }
    private func submit(_ response: InteractionResponse) {
        guard !expired, !submitting else { return }
        submitting = true
        Task {
            let accepted = await controller.reply(request, response)
            submitting = false
            if accepted { completed = true; dismiss() }
        }
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
            Label("剩余：\(remaining)", systemImage: "clock")
                .pikachuFont(.caption)
                .foregroundStyle(PikachuTheme.secondaryText)
                .monospacedDigit()
                .accessibilityIdentifier("interaction-countdown")
        }
    }

    func remainingDuration(relativeTo now: Date) -> Duration {
        .seconds(max(0, expiresAt.timeIntervalSince(now).rounded(.up)))
    }
}

struct ExpiredInteractionDetails: View {
    let request: RuntimeInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: request.title).pikachuFont(.callout, weight: .semibold).textSelection(.enabled)
            if let approval = request.toolApproval {
                ToolApprovalDetails(approval: approval)
            } else {
                if !request.message.isEmpty {
                    ApprovalTextScrollView(text: request.message, maxHeight: 180)
                }
                if !request.options.isEmpty {
                    Text("选项").pikachuFont(.caption).foregroundStyle(.secondary)
                    ApprovalTextScrollView(text: request.options.joined(separator: "\n"), maxHeight: 160)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolFailureDetailsSheet: View {
    let failures: [TranscriptItem]
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("工具调用失败")
                    .pikachuFont(.title2, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                PikachuDivider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(failures) { item in
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
                                .padding(10)
                                .flatSurface(PikachuTheme.mutedSurface, radius: 9)
                            }
                        }
                    }
                    .padding(1)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(idealHeight: 240, maxHeight: 340)
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
        .accessibilityIdentifier("composer-failed-tool-details")
    }
}

private struct ToolApprovalSheet: View {
    let approval: RuntimeToolApproval
    let sessionTitle: String
    let expiresAt: Date
    let notice: String?
    let error: String?
    let submitting: Bool
    let reply: (InteractionResponse) -> Void

    private var usesCountdownHeader: Bool {
        switch approval.operation {
        case .command, .edit: true
        case .write, .inspect: false
        }
    }

    private var title: LocalizedStringKey {
        switch approval.operation {
        case .command: "允许运行此命令？"
        case .write: "允许写入文件？"
        case .edit: "允许编辑文件？"
        case .inspect(let inspection, _): inspection.approvalTitle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(title)
                            .pikachuFont(.title2, weight: .semibold)
                            .accessibilityAddTraits(.isHeader)
                        if usesCountdownHeader {
                            Spacer(minLength: 0)
                            InteractionCountdown(expiresAt: expiresAt)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if !usesCountdownHeader {
                        Text("会话：\(sessionTitle)")
                            .pikachuFont(.caption)
                            .foregroundStyle(PikachuTheme.secondaryText)
                            .lineLimit(2)
                            .help(sessionTitle)
                        InteractionDeadline(expiresAt: expiresAt)
                    }
                }
                PikachuDivider()
                ToolApprovalDetails(approval: approval)
                if let notice { Text(verbatim: notice).pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText) }
                if let error { Text(verbatim: error).pikachuFont(.caption).foregroundStyle(PikachuTheme.errorText) }
            }
            .padding(20)
            PikachuDivider()
            HStack(spacing: 8) {
                Spacer()
                if submitting { FlatProgressView().controlSize(.small) }
                Button("拒绝", role: .cancel) { reply(.confirmed(false)) }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("interaction-no")
                Button("运行") { reply(.confirmed(true)) }
                    .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                    .accessibilityIdentifier("interaction-yes")
            }
            .disabled(submitting)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

private struct ToolApprovalDetails: View {
    let approval: RuntimeToolApproval
    @State private var editExpanded = false

    var body: some View {
        switch approval.operation {
        case .command(let command, let timeout):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, timeout: timeout)
            ApprovalTextPreview(text: command, copyLabel: "复制命令", identifier: "command-approval")
        case .write(let path, let content):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, path: path)
            Text("写入内容").pikachuFont(.callout, weight: .semibold)
            ApprovalTextPreview(text: content, copyLabel: "复制写入内容", identifier: "file-approval")
        case .edit(let path, let replacements):
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, path: path)
            EditApprovalPreview(replacements: replacements, isExpanded: $editExpanded)
        case .inspect(_, let arguments):
            let path = arguments.first { $0.name == "path" }?.value
            let otherArguments = arguments.filter { $0.name != "path" }
            ToolApprovalMetadata(workingDirectory: approval.workingDirectory, path: path)
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
    var path: String? = nil
    var timeout: Double? = nil

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow(alignment: .center) {
                Text("工作目录").foregroundStyle(PikachuTheme.secondaryText).fixedSize()
                pathValue(workingDirectory).accessibilityIdentifier("approval-working-directory")
            }
            if let path {
                GridRow(alignment: .center) {
                    Text("文件路径").foregroundStyle(PikachuTheme.secondaryText).fixedSize()
                    pathValue(path).accessibilityIdentifier("approval-file-path")
                }
            }
            if let timeout {
                GridRow {
                    Text("执行超时").foregroundStyle(PikachuTheme.secondaryText)
                    Text("\(timeout.formatted()) 秒")
                }
            }
        }
        .pikachuFont(.callout)
    }

    private func pathValue(_ value: String) -> some View {
        let singleLine = value.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return ScrollView(.horizontal) {
            Text(verbatim: singleLine)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .help(value)
    }
}

struct EditApprovalPreview: View {
    let replacements: [RuntimeToolApproval.Replacement]
    @Binding var isExpanded: Bool
    private let heightLimit: CGFloat = 244

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            preview.padding(.top, 6)
        } label: {
            Text("修改内容").pikachuFont(.callout, weight: .semibold)
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
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

private struct ApprovalTextPreview: View {
    let text: String
    let copyLabel: LocalizedStringKey
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ApprovalTextScrollView(text: text, maxHeight: 196)
                .accessibilityIdentifier("\(identifier)-preview")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label(copyLabel, systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .pikachuFont(.callout)
            }
            .buttonStyle(FlatControlButtonStyle())
            .help(copyLabel)
            .accessibilityIdentifier("\(identifier)-copy")
        }
        .padding(10)
        .flatSurface(PikachuTheme.mutedSurface, radius: 9)
    }
}

private struct ApprovalTextScrollView: View {
    let text: String
    let maxHeight: CGFloat

    var body: some View {
        // Measure the wrapped text so short previews hug their contents.
        ApprovalVerbatimText(text: text)
            .frame(maxHeight: maxHeight)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                ScrollView {
                    ApprovalVerbatimText(text: text).textSelection(.enabled)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
    }
}

private struct ApprovalVerbatimText: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                Text("（空）").foregroundStyle(PikachuTheme.secondaryText)
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
                        .buttonStyle(FlatControlButtonStyle(treatment: selected ? .prominent : .quiet))
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
