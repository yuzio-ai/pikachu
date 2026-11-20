import SwiftUI
import AppKit
import Observation
import OrchestrationCore
import AgentRuntimeCore

struct TranscriptView: View {
    let items: [TranscriptItem]
    var turnStarts: [TranscriptTurnStart] = []
    var diagnosticSession = ""
    var historyLoading = false
    var isExecuting = false
    var queue = RuntimeQueue()
    var queueIsKnown = true
    var showsEmptyState = true
    var composerClearance: CGFloat = 0
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    @State private var follow = true
    @State private var jump: NativeTranscript.Jump?
    @State private var previewImage: AttachmentImagePreview.Selection?

    var body: some View {
        Group {
            if !items.isEmpty || !turnStarts.isEmpty {
                NativeTranscript(rows: TranscriptDisplayRow.project(items, turnStarts: turnStarts), follow: $follow,
                                 composerClearance: composerClearance, jump: jump, onEditUserMessage: onEditUserMessage,
                                 copyableConversation: copyableConversation,
                                 onPreviewImage: { previewImage = .init(file: $0) },
                                 queueFooter: TranscriptQueueFooter.project(items, queue: queue, isKnown: queueIsKnown))
                    .overlay {
                        TranscriptMessageRail(messages: items.filter { $0.kind == .user },
                                              selectedID: follow ? nil : jump?.messageID) { message in
                            follow = false
                            jump = .init(messageID: message.id)
                        }
                        .padding(.bottom, composerClearance)
                    }
                    .overlay(alignment: .bottom) {
                        if !follow {
                            Button("回到最新", systemImage: "arrow.down") { follow = true }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                                .pikachuFont(.caption)
                                .padding(.bottom, composerClearance + 8)
                                .accessibilityIdentifier("transcript-jump-to-latest")
                        }
                    }
            } else if showsEmptyState && !historyLoading {
                FlatEmptyState("新会话", systemImage: "bolt.bubble", description: Text("在下方输入编码任务。"))
                    .padding(.bottom, composerClearance)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $previewImage) { selection in
            AttachmentImagePreview(file: selection.file)
        }
        .diagnosticDraw("history:\(diagnosticSession):\(historyLoading):\(items.count)")
    }

    private var copyableConversation: [TranscriptItem]? {
        guard !historyLoading, !isExecuting, items.contains(where: CopyConversationButton.isCopyable) else { return nil }
        return items
    }
}

struct TranscriptQueueFooter: Equatable {
    let itemID: String
    let text: String

    @MainActor static func project(_ items: [TranscriptItem], queue: RuntimeQueue, isKnown: Bool) -> Self? {
        guard !queue.isEmpty else { return nil }
        let queued = items.lazy.filter { $0.kind == .user && $0.delivery == .queued }
        guard let item = queued.last(where: { $0.submittedMode == .steer }) ?? queued.last else { return nil }
        let text = isKnown
            ? String(localized: "等待交付：补充 \(queue.steering.count) · 后续 \(queue.followUp.count)")
            : String(localized: "队列状态待核实")
        return Self(itemID: item.id, text: text)
    }
}

struct CopyConversationButton: View {
    let items: [TranscriptItem]
    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            copied = pasteboard.setString(Self.markdown(for: items), forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .pikachuFont(.caption)
                .opacity(isHovering ? 1 : 0)
        }
        .buttonStyle(FlatControlButtonStyle())
        .help("复制整个会话")
        .accessibilityLabel(copied ? "已复制" : "复制整个会话")
        .accessibilityIdentifier("copy-conversation")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch { }
        }
        .onDisappear {
            isHovering = false
            copied = false
        }
    }

    static func markdown(for items: [TranscriptItem]) -> String {
        items.filter(isCopyable).map { item in
            let role = item.kind == .user ? String(localized: "你") : String(localized: "助手")
            var sections = ["## \(role)", item.kind == .user ? item.editableText : item.text]
            if item.kind == .user, !item.editableFiles.isEmpty {
                let names = item.editableFiles.map(\.lastPathComponent).joined(separator: ", ")
                sections.append(String(localized: "附件：\(names)"))
            }
            return sections.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static func isCopyable(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .user: true
        case .assistant: item.hasVisibleText
        case .tool, .notice: false
        }
    }
}

private struct TranscriptMessageRail: View {
    let messages: [TranscriptItem]
    let selectedID: String?
    let onJump: (TranscriptItem) -> Void
    @State private var hoveredMessage: TranscriptItem?

    private let markerHeight: CGFloat = 15

    var body: some View {
        if !messages.isEmpty {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            marker(for: message)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(width: 24, height: min(CGFloat(messages.count) * markerHeight, 225, geometry.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlayPreferenceValue(TranscriptMarkerAnchor.self, alignment: .topLeading) { anchor in
                    if let anchor, let hoveredMessage {
                        let previewWidth = min(290, max(0, geometry.size.width - 44))
                        let anchorY = geometry[anchor].midY
                        preview(for: hoveredMessage)
                            .frame(width: previewWidth, alignment: .leading)
                            .offset(x: 28, y: max(4, min(anchorY - 28, geometry.size.height - 106)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func marker(for message: TranscriptItem) -> some View {
        let hovered = hoveredMessage?.id == message.id
        let isSelected = selectedID == message.id
        let snippet = previewText(for: message)
        return Button {
            onJump(message)
        } label: {
            Capsule()
                .fill(PikachuTheme.secondaryText.opacity(hovered || isSelected ? 0.85 : 0.35))
                .frame(width: hovered || isSelected ? 16 : 9, height: 2.5)
                .frame(width: 24, height: markerHeight, alignment: .leading)
                .padding(.leading, 5)
                .frame(width: 24, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityLabel(snippet)
        .accessibilityHint("跳到这条消息")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("transcript-marker-\(message.id)")
        .onHover { inside in
            if inside { hoveredMessage = message }
            else if hoveredMessage?.id == message.id { hoveredMessage = nil }
        }
        .anchorPreference(key: TranscriptMarkerAnchor.self, value: .bounds) { hovered ? $0 : nil }
    }

    private func preview(for message: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: previewText(for: message))
                .pikachuFont(.callout)
                .lineLimit(3)
            if let sentAt = message.sentAt {
                Text(TranscriptTimestampFormatter.shortTime(sentAt))
                    .pikachuFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .flatSurface(radius: 9)
    }

    private func previewText(for message: TranscriptItem) -> String {
        let text = String(message.editableText.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if let file = message.editableFiles.first { return file.lastPathComponent }
        return String(localized: "用户消息")
    }
}

private struct TranscriptMarkerAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

@MainActor struct TurnHeaderSummary {
    let title: String
    let displayText: String
    let tooltipText: String
    let accessibilityText: String

    init(turn: TurnRecord, relativeTo now: Date = .now, monotonicNow: ContinuousClock.Instant = .now) {
        let duration = turn.durationSeconds.map { String(localized: "执行 \(TranscriptTimestampFormatter.durationText($0))") }
        let endShort = turn.endedAt.map { String(localized: "结束于 \(TranscriptTimestampFormatter.shortTime($0, relativeTo: now))") }
        let endFull = turn.endedAt.map { TranscriptTimestampFormatter.fullTimeWithZone($0) }
        let separator = String(localized: "，", comment: "Separator between transcript status phrases read by VoiceOver")

        switch turn.status {
        case .running:
            self.title = "⚡️Pika Pika！"
            if let elapsed = turn.elapsedTime(at: now, monotonicNow: monotonicNow) {
                let elapsedText = TranscriptTimestampFormatter.durationText(elapsed)
                self.displayText = String(localized: "执行中 ... \(elapsedText)")
                self.accessibilityText = String(localized: "Pika Pika，执行中，已用时 \(elapsedText)")
            } else {
                self.displayText = String(localized: "执行中")
                self.accessibilityText = String(localized: "Pika Pika，执行中")
            }
            self.tooltipText = turn.startedAt.map { String(localized: "开始于 \(TranscriptTimestampFormatter.fullTimeWithZone($0))") } ?? String(localized: "正在执行")
        case .completed:
            self.title = "⚡️Pika-CHUUU!"
            let parts = [duration, endShort].compactMap { $0 }
            self.displayText = parts.isEmpty ? String(localized: "时间未知") : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { String(localized: "结束于 \($0)") } ?? String(localized: "执行完成时间未知")
            let a11yParts = [duration, endFull.map { String(localized: "结束于 \($0)") }].compactMap { $0 }
            self.accessibilityText = String(localized: "Pika-CHUUU! 执行完成，\(a11yParts.isEmpty ? String(localized: "时间未知") : a11yParts.joined(separator: separator))")
        case .stopped:
            self.title = "Pika"
            let parts = [String(localized: "已停止")] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? String(localized: "已停止 · 时间未知") : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { String(localized: "已停止 · 结束于 \($0)") } ?? String(localized: "已停止，结束时间未知")
            let a11yParts = [String(localized: "已停止")] + [duration, endFull.map { String(localized: "结束于 \($0)") }].compactMap { $0 }
            self.accessibilityText = String(localized: "Pika，\(a11yParts.joined(separator: separator))")
        case .failed:
            self.title = "Pika"
            let parts = [String(localized: "执行失败")] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? String(localized: "执行失败 · 时间未知") : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { String(localized: "执行失败 · 结束于 \($0)") } ?? String(localized: "执行失败，结束时间未知")
            let a11yParts = [String(localized: "执行失败")] + [duration, endFull.map { String(localized: "结束于 \($0)") }].compactMap { $0 }
            self.accessibilityText = String(localized: "Pika，\(a11yParts.joined(separator: separator))")
        case .uncertain:
            self.title = "Pika"
            let parts = [String(localized: "待核实")] + [duration, endShort].compactMap { $0 }
            self.displayText = parts.count == 1 ? String(localized: "待核实 · 时间未知") : parts.joined(separator: " · ")
            self.tooltipText = endFull.map { String(localized: "执行状态待核实 · 结束于 \($0)") } ?? String(localized: "执行状态待核实，时间未知")
            self.accessibilityText = String(localized: "Pika，\(self.displayText)")
        }
    }
}

struct TurnHeaderView: View {
    let turn: TurnRecord

    var body: some View {
        if turn.status == .running, let start = turn.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                header(relativeTo: context.date)
            }
        } else {
            header(relativeTo: .now)
        }
    }

    private func header(relativeTo now: Date) -> some View {
        let summary = TurnHeaderSummary(turn: turn, relativeTo: now)
        return HStack(spacing: 6) {
            if turn.status != .running && turn.status != .completed {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(PikachuTheme.lightningYellow)
                    .accessibilityHidden(true)
            }
            Text(verbatim: summary.title)
                .pikachuFont(.caption, weight: .semibold)
            Text(summary.displayText)
                .pikachuFont(.caption)
                .monospacedDigit()
                .foregroundStyle(turn.status == .uncertain || turn.status == .failed ? PikachuTheme.warningText : Color.secondary)
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
    let width: CGFloat
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((URL) -> Void)? = nil
    var queueFooter: String? = nil
    let contentChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let request = item.expiredInteraction {
                ExpiredInteractionRow(request: request, contentChanged: contentChanged)
            } else if item.kind == .user {
                UserMessageRow(item: item, width: width, onEdit: onEditUserMessage,
                               onPreviewImage: onPreviewImage, queueFooter: queueFooter)
                    .padding(.top, 8)
            } else {
                MarkdownContent(text: item.text, streaming: item.streaming, width: width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .onChange(of: item.text) { _, _ in contentChanged() }
        .onChange(of: item.streaming) { _, _ in contentChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(item.id)
    }
}

private struct ExpiredInteractionRow: View {
    let request: RuntimeInteraction
    let contentChanged: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ExpiredInteractionDetails(request: request)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("请求已过期，未提交回复", systemImage: "clock.badge.exclamationmark")
                    .pikachuFont(.callout, weight: .semibold)
                Text(verbatim: request.title)
                    .pikachuFont(.caption)
                    .lineLimit(2)
                InteractionDeadline(expiresAt: request.expiresAt)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(PikachuTheme.mutedSurface, radius: 9)
        .onChange(of: expanded) { _, _ in contentChanged() }
    }
}

private struct UserMessageRow: View {
    let item: TranscriptItem
    let width: CGFloat
    let onEdit: ((TranscriptItem) -> Void)?
    let onPreviewImage: ((URL) -> Void)?
    let queueFooter: String?
    private let bubbleInset: CGFloat = 14
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
        item.sentAt.map { String(localized: "发送于 \(TranscriptTimestampFormatter.fullTimeWithZone($0))") } ?? String(localized: "发送时间未知")
    }

    var body: some View {
        let images = item.attachedFiles.filter(ImageAttachmentThumbnail.isImage)
        let otherFiles = item.attachedFiles.filter { !ImageAttachmentThumbnail.isImage($0) }
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .trailing, spacing: 5) {
                if needsAttentionDelivery {
                    DeliveryLabel(state: item.delivery)
                        .padding(.bottom, item.delivery == .queued ? 2 : 0)
                }
                if !images.isEmpty {
                    imageGrid(images)
                }
                if !item.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.attachedFiles.isEmpty {
                    Text(item.attachedFiles.isEmpty ? item.text : item.editableText)
                        .textSelection(.enabled)
                }
                if !otherFiles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(otherFiles, id: \.self) { file in
                            Label(file.lastPathComponent, systemImage: "paperclip")
                                .pikachuFont(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PikachuTheme.surface, in: .capsule)
                                .help(file.path)
                        }
                    }
                }
            }
            .padding(.horizontal, bubbleInset)
            .padding(.vertical, 9)
            .background(PikachuTheme.messageBubble, in: .rect(cornerRadius: 12))

            if let queueFooter {
                Text(queueFooter)
                    .pikachuFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, bubbleInset)
                    .accessibilityIdentifier("message-queue-footer")
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if copiedFeedback {
                    Text("已复制")
                        .pikachuFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(timeDisplay)
                    .pikachuFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(timeTooltip)
                if let onEdit {
                    Button {
                        onEdit(item)
                    } label: {
                        Image(systemName: "pencil")
                            .pikachuFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false))
                    .focused($focusedAction, equals: .edit)
                    .help("编辑")
                    .accessibilityLabel("编辑")
                    .accessibilityIdentifier("edit-\(item.id)")
                }
                Button {
                    copyMessage()
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .pikachuFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false))
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

    private func imageGrid(_ images: [URL]) -> some View {
        let spacing: CGFloat = 6
        let available = max(1, width - 2 * bubbleInset)
        let size = min(ImageAttachmentThumbnail.defaultSize, available)
        let columns = min(images.count, Int((available + spacing) / (size + spacing)))
        let gridWidth = CGFloat(columns) * (size + spacing) - spacing
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: spacing), count: columns),
                         alignment: .trailing, spacing: spacing) {
            ForEach(images.indices, id: \.self) { index in
                let file = images[index]
                if let onPreviewImage {
                    Button { onPreviewImage(file) } label: {
                        ImageAttachmentThumbnail(file: file, size: size)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预览 \(file.lastPathComponent)")
                    .accessibilityIdentifier("preview-image-\(item.id)-\(index)")
                } else {
                    ImageAttachmentThumbnail(file: file, size: size)
                }
            }
        }
        .frame(width: gridWidth)
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

@MainActor @Observable final class ToolCallExpansion {
    private var groups: Set<String> = []
    private var details: Set<String> = []

    func groupBinding(for items: [TranscriptItem]) -> Binding<Bool> {
        Binding {
            !self.groups.isDisjoint(with: items.lazy.map(\.id))
        } set: { expanded in
            if expanded { self.groups.insert(items[0].id) }
            else { self.groups.subtract(items.lazy.map(\.id)) }
        }
    }

    func detailBinding(for item: TranscriptItem, isSingle: Bool) -> Binding<Bool> {
        Binding {
            self.details.contains(item.id) && (!isSingle || self.groups.contains(item.id))
        } set: { expanded in
            if expanded { self.details.insert(item.id) }
            else { self.details.remove(item.id) }
            if isSingle { self.groupBinding(for: [item]).wrappedValue = expanded }
        }
    }
}

@MainActor struct ToolCallsSummary {
    let total: Int
    let statuses: [Status]

    struct Status: Identifiable {
        let state: ToolState
        let count: Int
        var id: ToolState { state }
        var label: LocalizedStringResource {
            switch state {
            case .running: "\(count) 项执行中"
            case .failed: "\(count) 项失败"
            case .interrupted: "\(count) 项已中断"
            case .completed: "已完成"
            }
        }
    }

    init(items: [TranscriptItem]) {
        total = items.count
        var counts: [ToolState: Int] = [:]
        for item in items {
            if let state = item.toolSummary?.state { counts[state, default: 0] += 1 }
        }
        statuses = [ToolState.failed, .interrupted, .running].compactMap { state in
            counts[state].map { Status(state: state, count: $0) }
        }
    }

    var countLabel: LocalizedStringResource { "\(total) 项工具调用" }

    var description: String {
        ([String(localized: countLabel)] + statuses.map { String(localized: $0.label) }).joined(separator: " · ")
    }
}

struct ToolCallsRow: View {
    let items: [TranscriptItem]
    let expansion: ToolCallExpansion
    let contentChanged: () -> Void

    var body: some View {
        if items.count == 1, let item = items.first {
            ToolRow(item: item, expanded: expansion.detailBinding(for: item, isSingle: true), contentChanged: contentChanged)
        } else {
            let expanded = expansion.groupBinding(for: items)
            let summary = ToolCallsSummary(items: items)
            DisclosureGroup(isExpanded: expanded) {
                if expanded.wrappedValue {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            ToolRow(item: item, expanded: expansion.detailBinding(for: item, isSingle: false),
                                    contentChanged: contentChanged)
                        }
                    }
                    .padding(.leading, 19)
                    .padding(.top, 2)
                }
            } label: {
                HStack(spacing: 8) {
                    Label { Text(summary.countLabel) } icon: {
                        ToolCallIcon()
                    }
                    .pikachuFont(.callout)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    ForEach(summary.statuses) { status in
                        Text(status.label).pikachuFont(.caption).foregroundStyle(status.state.statusColor)
                    }
                }
                .lineLimit(1)
                .padding(.vertical, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.description)
            }
            .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
            .accessibilityIdentifier("tool-group-\(items[0].id)")
            .onChange(of: expanded.wrappedValue) { _, _ in contentChanged() }
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
    var body: some View {
        HStack(spacing: 5) {
            Text(label).pikachuFont(.caption2, weight: state == .queued ? .semibold : .regular)
            if state == .queued {
                DeliveryLoadingDots()
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(state == .unknown || state == .rejected ? PikachuTheme.warningText : Color.secondary)
        .accessibilityIdentifier("message-delivery-status")
    }
}

private struct DeliveryLoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(at: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
                dots(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(at time: TimeInterval?) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle().frame(width: 3, height: 3).opacity(dotOpacity(at: time, index: index))
            }
        }
    }

    private func dotOpacity(at time: TimeInterval?, index: Int) -> Double {
        guard let time else { return 1 }
        let angle = 2 * Double.pi * (time.truncatingRemainder(dividingBy: 1) - Double(index) / 3)
        return 0.62 + 0.38 * cos(angle)
    }
}

extension ToolState {
    var statusLabel: LocalizedStringResource {
        switch self {
        case .running: "执行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
    var statusIcon: String {
        switch self {
        case .running: "gearshape.2"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.circle"
        }
    }
    var statusColor: Color {
        switch self {
        case .running: PikachuTheme.runningText
        case .failed: PikachuTheme.errorText
        case .interrupted: PikachuTheme.warningText
        default: .secondary
        }
    }
}

struct ToolRow: View {
    let item: TranscriptItem
    @Binding var expanded: Bool
    var contentChanged: () -> Void = {}

    private func argumentPreview(_ tool: TranscriptToolSummary) -> String {
        var preview = tool.arguments
        if tool.name == "bash" || tool.name == "pikachu_bash",
           let arguments = try? JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any],
           let command = arguments["command"] as? String {
            preview = command
        }
        return String(preview.prefix(256)).split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var body: some View {
        if let tool = item.toolSummary {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ToolDetails(item: item, contentChanged: contentChanged)
                }
            } label: {
                let summary = argumentPreview(tool)
                HStack(spacing: 7) {
                    ToolCallIcon(tool: tool.name)
                    Text(tool.name).pikachuFont(.callout, weight: .medium, design: .monospaced)
                        .lineLimit(1).layoutPriority(1)
                    if !summary.isEmpty {
                        Text(summary).pikachuFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary).lineLimit(1).accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    Label {
                        Text(tool.state.statusLabel)
                    } icon: {
                        Image(systemName: tool.state.statusIcon).accessibilityHidden(true)
                    }
                    .pikachuFont(.caption).foregroundStyle(tool.state.statusColor).fixedSize()
                }
                .padding(.vertical, 2)
            }
            .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
            .accessibilityIdentifier(item.id)
            .onChange(of: expanded) { _, _ in contentChanged() }
        }
    }
}

struct ToolDetails: View {
    let item: TranscriptItem
    var contentChanged: () -> Void = {}

    var body: some View {
        if let tool = item.tool {
            VStack(alignment: .leading, spacing: 12) {
                if !tool.arguments.isEmpty {
                    Text("参数").pikachuFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(tool.arguments).pikachuFont(.caption, design: .monospaced).textSelection(.enabled)
                    }
                }
                if !tool.output.isEmpty {
                    PikachuDivider()
                    ScrollView(.horizontal) {
                        Text(tool.output).pikachuFont(.callout, design: .monospaced).textSelection(.enabled)
                    }
                }
                if tool.truncated { Text("输出过长，仅显示部分内容。").pikachuFont(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .onChange(of: tool) { _, _ in contentChanged() }
        }
    }
}
