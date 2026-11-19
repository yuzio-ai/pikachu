import SwiftUI
import AppKit
import Observation
import OrchestrationCore
import AgentRuntimeCore

struct TranscriptView: View {
    let items: [TranscriptItem]
    var diagnosticSession = ""
    var historyLoading = false
    var showsEmptyState = true
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    @State private var follow = true
    var body: some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                NativeTranscript(rows: TranscriptDisplayRow.grouped(items), follow: $follow, onEditUserMessage: onEditUserMessage)
                if !follow {
                    Button("回到最新", systemImage: "arrow.down") { follow = true }
                        .buttonStyle(.glass)
                        .font(.caption)
                        .padding(.vertical, 5)
                        .accessibilityIdentifier("transcript-jump-to-latest")
                }
            } else if showsEmptyState && !historyLoading {
                ContentUnavailableView("新会话", systemImage: "bolt.bubble", description: Text("在下方输入编码任务。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .diagnosticDraw("history:\(diagnosticSession):\(historyLoading):\(items.count)")
    }
}

@MainActor struct TurnHeaderSummary {
    let displayText: String
    let tooltipText: String
    let accessibilityText: String

    init(turn: TurnRecord, relativeTo now: Date = Date()) {
        let duration = turn.durationSeconds.map { "执行 \(TranscriptTimestampFormatter.durationText($0))" }
        let endShort = turn.endedAt.map { "结束于 \(TranscriptTimestampFormatter.shortTime($0, relativeTo: now))" }
        let endFull = turn.endedAt.map { TranscriptTimestampFormatter.fullTimeWithZone($0) }

        switch turn.status {
        case .running:
            self.displayText = "执行中"
            self.tooltipText = turn.startedAt.map { "开始于 \(TranscriptTimestampFormatter.fullTimeWithZone($0))" } ?? "正在执行"
            self.accessibilityText = "Pika，执行中"
        case .completed:
            let parts = [duration, endShort].compactMap { $0 }
            self.displayText = parts.isEmpty ? "时间未知" : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { "结束于 \($0)" } ?? "执行完成时间未知"
            let a11yParts = [duration, endFull.map { "结束于 \($0)" }].compactMap { $0 }
            self.accessibilityText = "Pika，" + (a11yParts.isEmpty ? "时间未知" : a11yParts.joined(separator: "，"))
        case .stopped:
            let parts = ["已停止"] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? "已停止 · 时间未知" : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { "已停止 · 结束于 \($0)" } ?? "已停止，结束时间未知"
            let a11yParts = ["已停止"] + [duration, endFull.map { "结束于 \($0)" }].compactMap { $0 }
            self.accessibilityText = "Pika，" + a11yParts.joined(separator: "，")
        case .failed:
            let parts = ["执行失败"] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? "执行失败 · 时间未知" : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { "执行失败 · 结束于 \($0)" } ?? "执行失败，结束时间未知"
            let a11yParts = ["执行失败"] + [duration, endFull.map { "结束于 \($0)" }].compactMap { $0 }
            self.accessibilityText = "Pika，" + a11yParts.joined(separator: "，")
        case .uncertain:
            let parts = ["待核实"] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? "待核实 · 时间未知" : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { "执行状态待核实 · 结束于 \($0)" } ?? "执行状态待核实，时间未知"
            self.accessibilityText = "Pika，" + self.displayText
        }
    }
}

struct TurnHeaderView: View {
    let turn: TurnRecord

    var body: some View {
        let summary = TurnHeaderSummary(turn: turn)
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(PikachuTheme.lightningYellow)
                .accessibilityHidden(true)
            Text("Pika")
                .font(.caption.weight(.semibold))
            Text(summary.displayText)
                .font(.caption)
                .foregroundStyle(turn.status == .uncertain || turn.status == .failed ? Color.orange : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(summary.tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityText)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    var turnHeader: TurnRecord? = nil
    let width: CGFloat
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    let contentChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tool = item.tool {
                if let turnHeader {
                    TurnHeaderView(turn: turnHeader)
                        .padding(.bottom, 6)
                }
                ToolRow(tool: tool, contentChanged: contentChanged)
            } else if item.kind == .user {
                UserMessageRow(item: item, onEdit: onEditUserMessage)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let turnHeader {
                        TurnHeaderView(turn: turnHeader)
                    }
                    if item.text.isEmpty && item.streaming {
                        Text("正在生成…").foregroundStyle(.secondary)
                    } else {
                        MarkdownContent(text: item.text, streaming: item.streaming, width: width)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .onChange(of: item.text) { _, _ in contentChanged() }
        .onChange(of: item.streaming) { _, _ in contentChanged() }
        .onChange(of: item.tool) { _, _ in contentChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(item.id)
    }
}

private struct UserMessageRow: View {
    let item: TranscriptItem
    let onEdit: ((TranscriptItem) -> Void)?
    @State private var isHovering = false
    @State private var copiedFeedback = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @FocusState private var focusedAction: FooterAction?

    private enum FooterAction: Hashable {
        case edit, copy
    }

    private var needsAttentionDelivery: Bool {
        item.delivery != .accepted && item.delivery != .handled
    }

    private var showsFooter: Bool {
        isHovering || focusedAction != nil || copiedFeedback
    }

    private var timeDisplay: String {
        item.sentAt.map { TranscriptTimestampFormatter.shortTime($0) } ?? String(localized: "时间未知")
    }

    private var timeTooltip: String {
        item.sentAt.map { "发送于 \(TranscriptTimestampFormatter.fullTimeWithZone($0))" } ?? String(localized: "发送时间未知")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .trailing, spacing: 5) {
                if needsAttentionDelivery {
                    DeliveryLabel(state: item.delivery)
                }
                if !item.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.attachedFiles.isEmpty {
                    Text(item.attachedFiles.isEmpty ? item.text : item.editableText)
                        .textSelection(.enabled)
                }
                if !item.attachedFiles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.attachedFiles, id: \.self) { file in
                            Label(file.lastPathComponent, systemImage: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: .capsule)
                                .help(file.path)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.accentColor.opacity(0.14)), in: .rect(cornerRadius: 12))

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if copiedFeedback {
                    Text("已复制")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(timeDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(timeTooltip)
                if let onEdit {
                    Button {
                        onEdit(item)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedAction, equals: .edit)
                    .help("编辑")
                    .accessibilityLabel("编辑")
                    .accessibilityIdentifier("edit-\(item.id)")
                }
                Button {
                    copyMessage()
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focused($focusedAction, equals: .copy)
                .help("复制")
                .accessibilityLabel("复制")
                .accessibilityIdentifier("copy-\(item.id)")
            }
            .frame(height: 20)
            .opacity(showsFooter ? 1 : 0)
            .accessibilityElement(children: .contain)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onDisappear { copyFeedbackTask?.cancel() }
        .accessibilityAction(named: Text("编辑")) {
            onEdit?(item)
        }
        .accessibilityAction(named: Text("复制")) {
            copyMessage()
        }
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.editableText.isEmpty && !item.text.isEmpty ? item.text : item.editableText, forType: .string)
        copiedFeedback = true
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: String(localized: "已复制"), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            copiedFeedback = false
        }
    }
}

@MainActor @Observable final class ToolGroupExpansion {
    var expandedIDs: Set<String> = []
}

struct CompletedToolsRow: View {
    let items: [TranscriptItem]
    var turnHeader: TurnRecord? = nil
    let expansion: ToolGroupExpansion
    let contentChanged: () -> Void

    private var expanded: Bool {
        !expansion.expandedIDs.isDisjoint(with: items.lazy.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let turnHeader {
                TurnHeaderView(turn: turnHeader)
            }
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { isExpanded in
                if isExpanded {
                    expansion.expandedIDs.insert(items[0].id)
                } else {
                    expansion.expandedIDs.subtract(items.lazy.map(\.id))
                }
            })) {
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            if let tool = item.tool {
                                ToolRow(tool: tool, contentChanged: contentChanged)
                                    .accessibilityIdentifier(item.id)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Label("\(items.count) 项工具调用", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .rect(cornerRadius: 9))
            .onChange(of: expanded) { _, _ in contentChanged() }
        }
    }
}

struct DeliveryLabel: View {
    let state: DeliveryState
    var label: LocalizedStringResource {
        switch state {
        case .pending: "待确认"
        case .accepted: "已接受"
        case .queued: "排队中"
        case .recovered: "已退回草稿"
        case .handled: "已处理"
        case .rejected: "未发送"
        case .unknown: "发送结果不明"
        }
    }
    var body: some View { Text(label).font(.caption2).foregroundStyle(state == .unknown || state == .rejected ? Color.orange : Color.secondary) }
}

struct ToolRow: View {
    let tool: RuntimeTool
    var contentChanged: () -> Void = {}
    @State private var expanded = false
    private var summary: String {
        String(tool.arguments.prefix(256)).split(whereSeparator: \.isNewline).joined(separator: " ")
    }
    var status: LocalizedStringResource {
        switch tool.state { case .running: "执行中"; case .completed: "已完成"; case .failed: "失败"; case .interrupted: "已中断" }
    }
    private var statusIcon: String {
        switch tool.state {
        case .running: "gearshape.2"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.circle"
        }
    }
    private var statusColor: Color {
        switch tool.state {
        case .failed: .red
        case .interrupted: .orange
        default: .secondary
        }
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !tool.arguments.isEmpty {
                    Text("参数").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(tool.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(7).glassEffect(in: .rect(cornerRadius: 7))
                }
                if !tool.output.isEmpty {
                    Divider()
                    ScrollView(.horizontal) {
                        Text(tool.output).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(7).glassEffect(in: .rect(cornerRadius: 7))
                }
                if tool.truncated { Text("输出过长，仅显示部分内容。").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "terminal").accessibilityHidden(true)
                Text(tool.name).font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1).layoutPriority(1)
                if !summary.isEmpty {
                    Text(summary).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                Label {
                    Text(status)
                } icon: {
                    Image(systemName: statusIcon).accessibilityHidden(true)
                }
                .font(.caption).foregroundStyle(statusColor).fixedSize()
            }.padding(.vertical, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(
            .regular.tint(tool.state == .failed || tool.state == .interrupted ? statusColor.opacity(0.18) : nil),
            in: .rect(cornerRadius: 9)
        )
        .onChange(of: expanded) { _, _ in contentChanged() }
    }
}
