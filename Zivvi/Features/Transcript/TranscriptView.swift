import SwiftUI
import AppKit
import Observation
import OrchestrationCore
import AgentRuntimeCore

/// Lives with the workbench window. Session teardown releases the renderer and its view callbacks.
@MainActor final class WindowTranscriptPositions {
    private var sessions: [UUID: TranscriptScrollState] = [:]

    func state(for id: UUID) -> TranscriptScrollState {
        if let state = sessions[id] { return state }
        let state = TranscriptScrollState()
        sessions[id] = state
        return state
    }
}

struct TranscriptReadingID: Hashable, ExpressibleByStringLiteral {
    let messageID: String
    let occurrence: Int

    init(_ messageID: String, occurrence: Int = 0) {
        self.messageID = messageID
        self.occurrence = occurrence
    }

    init(stringLiteral value: String) { self.init(value) }
}

struct TranscriptReadingAnchor: Equatable {
    let id: TranscriptReadingID
    let offset: CGFloat
    let next: TranscriptReadingID?
    let previous: TranscriptReadingID?

    @MainActor func resolve(in rows: [TranscriptDisplayRow]) -> Int? {
        resolve(in: rows, id: \.id, contains: { $0.contains($1) })
    }

    @MainActor func resolve(inEntries rows: [NativeTranscriptRow]) -> Int? {
        resolve(in: rows, id: \.id, contains: { $0.contains($1) })
    }

    @MainActor private func resolve<Row>(
        in rows: [Row],
        id rowID: (Row) -> String,
        contains: (Row, String) -> Bool
    ) -> Int? {
        for candidate in [id, next, previous].compactMap({ $0 }) {
            var occurrence = 0
            for index in rows.indices where rowID(rows[index]) == candidate.messageID {
                if occurrence == candidate.occurrence { return index }
                occurrence += 1
            }
            if occurrence == 0, let index = rows.firstIndex(where: { contains($0, candidate.messageID) }) {
                return index
            }
        }
        return nil
    }
}

@MainActor @Observable final class TranscriptScrollState {
    @ObservationIgnored var readingAnchor: TranscriptReadingAnchor?
    var follow = true
    var scrolledToTop = false
    var jump: NativeTranscript.Jump?
    let approvalExpansion = ApprovalRecordExpansion()
    @ObservationIgnored weak var coordinator: NativeTranscript.Coordinator?
    /// Installed by `SwiftUITranscript`; the legacy engine uses `coordinator`.
    @ObservationIgnored var scrollToLatest: (() -> Void)?
    @ObservationIgnored var activeMountOwner: ObjectIdentifier?

    func requestFollow() {
        readingAnchor = nil
        follow = true
        jump = nil
        if let coordinator {
            coordinator.setFollowFromUser(true)
        } else {
            scrollToLatest?()
        }
    }

    func requestJump(to messageID: String) {
        follow = false
        if let coordinator {
            coordinator.jumpTo(messageID: messageID)
        } else {
            jump = NativeTranscript.Jump(messageID: messageID)
        }
    }

    func revealApprovalRecord(_ id: String) {
        approvalExpansion.setExpanded(true, for: id)
        requestJump(to: id)
    }
}

@MainActor @Observable final class ApprovalRecordExpansion {
    private var expandedIDs: Set<String> = []

    func setExpanded(_ expanded: Bool, for id: String) {
        if expanded { expandedIDs.insert(id) } else { expandedIDs.remove(id) }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.expandedIDs.contains(id) }, set: { self.setExpanded($0, for: id) })
    }
}

struct TranscriptView: View {
    let items: [TranscriptItem]
    var frozenItems: [TranscriptItem] = []
    var frozenRows: [TranscriptDisplayRow] = []
    var activeHandoff: TranscriptItem? = nil
    var turnStarts: [TranscriptTurnStart] = []
    var diagnosticSession = ""
    var historyLoading = false
    var showsThinking = false
    var queue = RuntimeQueue()
    var queueIsKnown = true
    var showsEmptyState = true
    var showingCachedHistory = false
    var composerClearance: CGFloat = 0
    var workspaceDirectory: URL? = nil
    var approvalProjectDirectory: String? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var onSyncFullHistory: (() -> Void)? = nil
    var onSwitchModel: (() -> Void)? = nil
    var onOpenConnectionSettings: (() -> Void)? = nil
    var onSafeRetry: (() -> Void)? = nil
    var includesToolResultItem: ToolResultSource.Validator? = nil
    var scrollState: TranscriptScrollState? = nil
    @State private var fallbackScrollState = TranscriptScrollState()
    @State private var toolOutput: ToolOutputSelection?
    private var activeScrollState: TranscriptScrollState { scrollState ?? fallbackScrollState }

    var body: some View {
        Group {
            if !items.isEmpty || !turnStarts.isEmpty || !frozenRows.isEmpty || activeHandoff != nil {
                TranscriptBodyContent(
                    historyLoading: historyLoading,
                    items: items,
                    frozenItems: frozenItems,
                    frozenRows: frozenRows,
                    activeHandoff: activeHandoff,
                    turnStarts: turnStarts,
                    diagnosticSession: diagnosticSession,
                    showsThinking: showsThinking,
                    queue: queue,
                    queueIsKnown: queueIsKnown,
                    showingCachedHistory: showingCachedHistory,
                    composerClearance: composerClearance,
                    workspaceDirectory: workspaceDirectory,
                    approvalProjectDirectory: approvalProjectDirectory,
                    scrollState: activeScrollState,
                    onOpenFile: onOpenFile,
                    onOpenToolDiff: onOpenToolDiff,
                    onOpenHandoffFile: onOpenHandoffFile,
                    onEditUserMessage: onEditUserMessage,
                    onPreviewImage: onPreviewImage,
                    onShowToolOutput: { selection in
                        var current = selection
                        current.source.includesItem = includesToolResultItem
                        if current.source.current != nil { toolOutput = current }
                    },
                    onSyncFullHistory: onSyncFullHistory,
                    onSwitchModel: onSwitchModel,
                    onOpenConnectionSettings: onOpenConnectionSettings,
                    onSafeRetry: onSafeRetry
                )
            } else if showsEmptyState && !historyLoading {
                FlatEmptyState("新会话", systemImage: "bubble.left", description: Text("在下方输入编码任务。"))
                    .padding(.bottom, composerClearance)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $toolOutput) { selection in
            ToolOutputPanel(selection: selection)
        }
        .onChange(of: diagnosticSession) { _, _ in toolOutput = nil }
        .diagnosticDraw("history:\(diagnosticSession):\(historyLoading):\(items.count)")
    }
}

private struct TranscriptBodyContent: View {
    let historyLoading: Bool
    let items: [TranscriptItem]
    let frozenItems: [TranscriptItem]
    let frozenRows: [TranscriptDisplayRow]
    let activeHandoff: TranscriptItem?
    let turnStarts: [TranscriptTurnStart]
    let diagnosticSession: String
    let showsThinking: Bool
    let queue: RuntimeQueue
    let queueIsKnown: Bool
    let showingCachedHistory: Bool
    let composerClearance: CGFloat
    let workspaceDirectory: URL?
    let approvalProjectDirectory: String?
    let scrollState: TranscriptScrollState
    let onOpenFile: ((URL) -> Void)?
    let onOpenToolDiff: ((TranscriptItem) -> Void)?
    let onOpenHandoffFile: HandoffFileOpener?
    let onEditUserMessage: ((TranscriptItem) -> Void)?
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let onShowToolOutput: (ToolOutputSelection) -> Void
    let onSyncFullHistory: (() -> Void)?
    let onSwitchModel: (() -> Void)?
    let onOpenConnectionSettings: (() -> Void)?
    let onSafeRetry: (() -> Void)?

    var body: some View {
        TranscriptProjectionHost(
            historyLoading: historyLoading,
            items: items,
            frozenRows: frozenRows,
            activeHandoff: activeHandoff,
            turnStarts: turnStarts,
            showsThinking: showsThinking,
            queue: queue,
            queueIsKnown: queueIsKnown,
            showingCachedHistory: showingCachedHistory,
            composerClearance: composerClearance,
            workspaceDirectory: workspaceDirectory,
            approvalProjectDirectory: approvalProjectDirectory,
            scrollState: scrollState,
            onOpenFile: onOpenFile,
            onOpenToolDiff: onOpenToolDiff,
            onOpenHandoffFile: onOpenHandoffFile,
            onEditUserMessage: onEditUserMessage,
            onPreviewImage: onPreviewImage,
            onShowToolOutput: onShowToolOutput,
            onSwitchModel: onSwitchModel,
            onOpenConnectionSettings: onOpenConnectionSettings,
            onSafeRetry: onSafeRetry
        )
        .overlay {
            TranscriptMessageRailOverlay(
                messages: (frozenItems + items).filter { $0.kind == .user },
                scrollState: scrollState
            )
            .id(diagnosticSession)
            .padding(.bottom, composerClearance)
        }
        .overlay(alignment: .top) {
            TranscriptCachedTopOverlay(
                showingCachedHistory: showingCachedHistory,
                scrollState: scrollState,
                onSyncFullHistory: onSyncFullHistory
            )
        }
        .overlay(alignment: .bottom) {
            TranscriptJumpToLatestOverlay(
                composerClearance: composerClearance,
                scrollState: scrollState
            )
        }
    }
}

private struct TranscriptProjectionHost: View {
    @Environment(\.zivviTypography) private var typography
    let historyLoading: Bool
    let items: [TranscriptItem]
    let frozenRows: [TranscriptDisplayRow]
    let activeHandoff: TranscriptItem?
    let turnStarts: [TranscriptTurnStart]
    let showsThinking: Bool
    let queue: RuntimeQueue
    let queueIsKnown: Bool
    let showingCachedHistory: Bool
    let composerClearance: CGFloat
    let workspaceDirectory: URL?
    let approvalProjectDirectory: String?
    let scrollState: TranscriptScrollState
    let onOpenFile: ((URL) -> Void)?
    let onOpenToolDiff: ((TranscriptItem) -> Void)?
    let onOpenHandoffFile: HandoffFileOpener?
    let onEditUserMessage: ((TranscriptItem) -> Void)?
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let onShowToolOutput: (ToolOutputSelection) -> Void
    let onSwitchModel: (() -> Void)?
    let onOpenConnectionSettings: (() -> Void)?
    let onSafeRetry: (() -> Void)?

    var body: some View {
        let activeRows = TranscriptDisplayRow.project(items, turnStarts: turnStarts, showsThinking: showsThinking)
        let rows = frozenRows + TranscriptDisplayRow.placingHandoff(activeHandoff, in: activeRows)
        if Self.usesLegacyEngine {
            NativeTranscript(
                rows: rows,
                follow: .constant(true),
                extraTopClearance: showingCachedHistory ? 36 : 0,
                composerClearance: composerClearance,
                workspaceDirectory: workspaceDirectory,
                approvalProjectDirectory: approvalProjectDirectory,
                onOpenFile: onOpenFile,
                onOpenHandoffFile: onOpenHandoffFile,
                onEditUserMessage: onEditUserMessage,
                onPreviewImage: onPreviewImage,
                onShowToolOutput: onShowToolOutput,
                replyFooters: TranscriptReplyFooter.project(rows),
                queueFooter: TranscriptQueueFooter.project(items, queue: queue, isKnown: queueIsKnown),
                scrollState: scrollState, historyLoading: historyLoading
            )
        } else {
            SwiftUITranscript(
                entries: NativeTranscriptRow.project(rows, footers: TranscriptReplyFooter.project(rows),
                                                     typography: typography),
                scrollState: scrollState, historyLoading: historyLoading,
                extraTopClearance: showingCachedHistory ? 36 : 0,
                composerClearance: composerClearance,
                workspaceDirectory: workspaceDirectory,
                approvalProjectDirectory: approvalProjectDirectory,
                onOpenFile: onOpenFile,
                onOpenToolDiff: onOpenToolDiff,
                onOpenHandoffFile: onOpenHandoffFile,
                onEditUserMessage: onEditUserMessage,
                onPreviewImage: onPreviewImage,
                onShowToolOutput: onShowToolOutput,
                onSwitchModel: onSwitchModel,
                onOpenConnectionSettings: onOpenConnectionSettings,
                onSafeRetry: onSafeRetry,
                queueFooter: TranscriptQueueFooter.project(items, queue: queue, isKnown: queueIsKnown)
            )
        }
    }

    /// `defaults write <bundle id> TranscriptLegacyEngine -bool YES` switches back to the
    /// AppKit table engine for A/B comparison until it is retired.
    static var usesLegacyEngine: Bool { UserDefaults.standard.bool(forKey: "TranscriptLegacyEngine") }
}

private struct TranscriptMessageRailOverlay: View {
    let messages: [TranscriptItem]
    let scrollState: TranscriptScrollState

    var body: some View {
        TranscriptMessageRail(
            messages: messages,
            selectedID: scrollState.follow ? nil : scrollState.jump?.messageID
        ) { message in
            scrollState.requestJump(to: message.timelineID)
        }
    }
}

private struct TranscriptCachedTopOverlay: View {
    let showingCachedHistory: Bool
    let scrollState: TranscriptScrollState
    let onSyncFullHistory: (() -> Void)?

    var body: some View {
        if showingCachedHistory && scrollState.scrolledToTop {
            HStack(spacing: 8) {
                LightningLabel(icon: .infoCircle, size: 13) {
                    Text("已到离线缓存顶部 · 仅展示近期记录")
                }
                .foregroundStyle(ZivviTheme.secondaryText)
                if let onSyncFullHistory {
                    Button("同步完整历史", action: onSyncFullHistory)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 12))
                        .zivviFont(.caption)
                        .accessibilityIdentifier("transcript-sync-full-history")
                }
            }
            .zivviFont(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .flatSurface(ZivviTheme.surface, radius: 16)
            .padding(.top, 10)
            .accessibilityIdentifier("transcript-cached-history-top-hint")
        }
    }
}

private struct TranscriptJumpToLatestOverlay: View {
    let composerClearance: CGFloat
    let scrollState: TranscriptScrollState

    var body: some View {
        if !scrollState.follow {
            Button {
                scrollState.requestFollow()
            } label: {
                LightningLabel(icon: .arrowDown, size: 13) { Text("回到最新") }
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
            .zivviFont(.caption)
            .padding(.bottom, composerClearance + 8)
            .accessibilityIdentifier("transcript-jump-to-latest")
        }
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
        return Self(itemID: item.timelineID, text: text)
    }
}

@MainActor struct TranscriptReplyFooter {
    let items: [TranscriptItem]
    let endedAt: Date?

    var markdown: String { items.lazy.filter(\.hasVisibleText).map(\.text).joined(separator: "\n\n") }

    func hasSameItems(as other: Self) -> Bool {
        endedAt == other.endedAt && items.count == other.items.count &&
            zip(items, other.items).allSatisfy { $0 === $1 }
    }

    static func project(_ rows: [TranscriptDisplayRow]) -> [String: Self] {
        var replies: [ObjectIdentifier: [TranscriptItem]] = [:]
        var changeRows: [ObjectIdentifier: String] = [:]
        for row in rows {
            switch row {
            case .item(let item) where item.kind == .assistant:
                guard let turn = item.turn, turn.status != .running else { continue }
                replies[ObjectIdentifier(turn), default: []].append(item)
            case .turnChanges(let turn):
                changeRows[ObjectIdentifier(turn)] = row.id
            default:
                break
            }
        }
        var footers: [String: Self] = [:]
        for (turnID, items) in replies {
            guard let last = items.last else { continue }
            footers[changeRows[turnID] ?? last.timelineID] = Self(items: items, endedAt: last.turn?.endedAt)
        }
        return footers
    }
}

// The final reply and its file changes live in separate hosting cells.
@MainActor @Observable final class TranscriptReplyHover {
    private(set) var rowID: String?

    func setHovered(_ hovering: Bool, rowID: String) {
        if hovering { self.rowID = rowID }
        else if self.rowID == rowID { self.rowID = nil }
    }
}

struct AssistantReplyActions: View {
    let reply: TranscriptReplyFooter
    let rowID: String
    let hover: TranscriptReplyHover
    @State private var copied = false
    @FocusState private var isFocused: Bool

    private var isHovering: Bool {
        guard let hoveredRow = hover.rowID else { return false }
        return hoveredRow == rowID || hoveredRow == reply.items.last?.timelineID
    }

    private var timeDisplay: String {
        reply.endedAt.map { TranscriptTimestampFormatter.shortTime($0) } ?? String(localized: "时间未知")
    }

    private var timeTooltip: String {
        reply.endedAt.map { TranscriptTimestampFormatter.fullTimeWithZone($0) } ?? String(localized: "结束时间未知")
    }

    var body: some View {
        HStack(spacing: 4) {
            if reply.items.contains(where: \.hasVisibleText) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copied = pasteboard.setString(reply.markdown, forType: .string)
                } label: {
                    LightningIconView(copied ? .checkmark : .docOnDoc, size: 13)
                }
                .buttonStyle(FlatControlButtonStyle())
                .focused($isFocused)
                .help("复制助手回复")
                .accessibilityLabel(copied ? "已复制" : "复制助手回复")
                .accessibilityValue(timeTooltip)
                .accessibilityIdentifier("copy-assistant-reply")
            }

            Text(timeDisplay)
                .zivviFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(ZivviTheme.secondaryText)
                .help(timeTooltip)
                .accessibilityHidden(true)
        }
        .revealedAction(isHovering || isFocused || copied)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch { }
        }
        .onDisappear { copied = false }
    }
}

struct TranscriptMarkerHover {
    struct Request: Equatable {
        let markerID: String
        // Re-entering the same marker must start a new delay, not complete its old request.
        private let interactionID = UUID()
    }

    private(set) var hoveredID: String?
    private(set) var request: Request?
    private(set) var isPresented = false
    private var isScrolling = false

    mutating func movePointer(to markerID: String?) {
        guard hoveredID != markerID else { return }
        hoveredID = markerID
        restartPreview()
    }

    mutating func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        restartPreview()
    }

    mutating func updateScrollPosition(markerID: String?) {
        hoveredID = markerID
        // A mouse wheel may change the offset without a scroll phase transition.
        restartPreview()
    }

    mutating func dismissPreview() {
        request = nil
        isPresented = false
    }

    private mutating func restartPreview() {
        dismissPreview()
        if !isScrolling, let hoveredID { request = Request(markerID: hoveredID) }
    }

    mutating func present(_ completed: Request) {
        guard request == completed else { return }
        isPresented = true
    }
}

private struct TranscriptMessageRail: View {
    let messages: [TranscriptItem]
    let selectedID: String?
    let onJump: (TranscriptItem) -> Void
    @Environment(\.appearsActive) private var appearsActive
    @State private var hover = TranscriptMarkerHover()
    @State private var pointerY: CGFloat?
    @State private var scrollOffset: CGFloat = 0

    private let markerHeight: CGFloat = 15

    var body: some View {
        let request = hover.request
        let pointedMarker = markerID(at: pointerY, offset: scrollOffset)
        if !messages.isEmpty {
            GeometryReader { geometry in
                let railHeight = min(CGFloat(messages.count) * markerHeight, 225, geometry.size.height)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            marker(for: message)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                .onScrollPhaseChange { _, phase in
                    hover.setScrolling(phase.isScrolling)
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    scrollOffset = offset
                    hover.updateScrollPosition(markerID: markerID(at: pointerY, offset: offset))
                }
                .frame(width: 24, height: railHeight)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointerY = (0..<24).contains(point.x) && (0..<railHeight).contains(point.y) ? point.y : nil
                    case .ended:
                        pointerY = nil
                    }
                }
                .onChange(of: railHeight) { _, height in
                    if let pointerY, pointerY >= height { self.pointerY = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlayPreferenceValue(TranscriptMarkerAnchor.self, alignment: .topLeading) { anchor in
                    if let anchor, hover.isPresented, let request, request.markerID == pointedMarker,
                       let hoveredMessage = messages.first(where: { $0.timelineID == request.markerID }) {
                        let previewWidth = min(290, max(0, geometry.size.width - 44))
                        let anchorY = geometry[anchor].midY
                        preview(for: hoveredMessage)
                            .frame(width: previewWidth, alignment: .leading)
                            .offset(x: 28, y: max(4, min(anchorY - 28, geometry.size.height - 106)))
                    }
                }
            }
            .onChange(of: pointedMarker, initial: true) { _, markerID in
                hover.movePointer(to: markerID)
            }
            .onDisappear {
                pointerY = nil
                scrollOffset = 0
                hover = TranscriptMarkerHover()
            }
            .task(id: request) {
                guard let request else { return }
                do {
                    try await Task.sleep(for: AnchoredCardStyle.hoverDelay)
                    guard !Task.isCancelled else { return }
                    hover.present(request)
                } catch { }
            }
        }
    }

    private func markerID(at y: CGFloat?, offset: CGFloat) -> String? {
        guard appearsActive, let y else { return nil }
        // The rail has no row spacing; view coordinates plus the scroll offset identify the row.
        let contentY = y + offset
        guard contentY >= 0, contentY < CGFloat(messages.count) * markerHeight else { return nil }
        return messages[Int(contentY / markerHeight)].timelineID
    }

    private func marker(for message: TranscriptItem) -> some View {
        let hovered = hover.hoveredID == message.timelineID
        let isSelected = selectedID == message.timelineID
        let snippet = previewText(for: message)
        let length: CGFloat = isSelected ? 16 : (hovered ? 12 : 9)
        let opacity = isSelected ? 0.95 : (hovered ? 0.65 : 0.35)
        return Button {
            hover.dismissPreview()
            onJump(message)
        } label: {
            Capsule()
                .fill(ZivviTheme.secondaryText.opacity(opacity))
                .frame(width: length, height: 2.5)
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
        .accessibilityIdentifier("transcript-marker-\(message.timelineID)")
        .anchorPreference(key: TranscriptMarkerAnchor.self, value: .bounds) { hovered ? $0 : nil }
    }

    private func preview(for message: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            Text(verbatim: previewText(for: message))
                .anchoredCardTitle()
                .lineLimit(3)
            if let sentAt = message.sentAt {
                Text(TranscriptTimestampFormatter.shortTime(sentAt))
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .anchoredPreviewCard()
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
    let brandState: BrandPresentationState
    let title: String
    let displayText: String
    let elapsedText: String?
    let tooltipText: String
    let accessibilityLabel: String
    let accessibilityValue: String?

    var accessibilityText: String {
        guard let accessibilityValue else { return accessibilityLabel }
        return "\(accessibilityLabel). \(accessibilityValue)"
    }

    init(turn: TurnRecord, relativeTo now: Date = .now, monotonicNow: ContinuousClock.Instant = .now,
         locale: Locale = TranscriptTimestampFormatter.displayLocale) {
        if turn.isHistoricalOutcomeMissing {
            brandState = .historicalOutcomeMissing
            title = ""
            displayText = String(localized: LocalizedStringResource("历史结果未记录", locale: locale))
            tooltipText = displayText
            accessibilityLabel = displayText
            accessibilityValue = nil
            elapsedText = nil
            return
        }
        let duration = turn.durationSeconds.map { TranscriptTimestampFormatter.durationText($0, locale: locale) }
        let elapsedSeconds = turn.status == .running
            ? turn.elapsedTime(at: now, monotonicNow: monotonicNow)
            : nil
        elapsedText = elapsedSeconds.map {
            TranscriptTimestampFormatter.durationText($0, locale: locale)
        }
        accessibilityValue = (turn.status == .running ? elapsedText : duration).map {
            String(localized: LocalizedStringResource("用时 \($0)", locale: locale,
                                                       comment: "Accessible elapsed or final duration of an agent turn."))
        }

        switch turn.status {
        case .running:
            switch turn.liveStage {
            case .running:
                if let elapsedSeconds, elapsedSeconds < 0.8 {
                    brandState = .starting
                    title = BrandCopy.agentStarted
                } else {
                    brandState = .running
                    title = BrandCopy.agentRunning
                }
                displayText = String(localized: LocalizedStringResource("执行中", locale: locale))
                accessibilityLabel = String(localized: LocalizedStringResource("智能体正在执行", locale: locale))
            case .thinking:
                brandState = .running
                title = BrandCopy.agentRunning
                displayText = String(localized: LocalizedStringResource("思考中", locale: locale))
                accessibilityLabel = String(localized: LocalizedStringResource("智能体正在思考", locale: locale))
            case .streaming:
                brandState = .running
                title = BrandCopy.agentRunning
                displayText = String(localized: LocalizedStringResource("正在输出", locale: locale))
                accessibilityLabel = String(localized: LocalizedStringResource("智能体正在输出", locale: locale))
            case .waitingApproval:
                brandState = .awaitingApproval
                title = ""
                displayText = String(localized: LocalizedStringResource("等待审批", locale: locale))
                accessibilityLabel = String(localized: LocalizedStringResource("智能体正在等待审批", locale: locale))
            }
            tooltipText = turn.startedAt.map {
                let time = TranscriptTimestampFormatter.fullTimeWithZone($0)
                return String(localized: LocalizedStringResource("开始于 \(time)", locale: locale))
            } ?? displayText
        case .completed:
            brandState = .completed
            title = BrandCopy.completed
            displayText = duration.map { String(localized: LocalizedStringResource("执行 \($0)", locale: locale)) }
                ?? String(localized: LocalizedStringResource("执行完成", locale: locale))
            accessibilityLabel = String(localized: LocalizedStringResource("智能体执行完成", locale: locale))
            tooltipText = displayText
        case .stopped:
            brandState = .stopped
            title = ""
            if turn.interruptedByApprovalTimeout {
                let reason = String(localized: LocalizedStringResource("因审批超时中断", locale: locale))
                displayText = duration.map {
                    String(localized: LocalizedStringResource("因审批超时中断 · 执行 \($0)", locale: locale))
                } ?? reason
                accessibilityLabel = reason
            } else {
                displayText = duration.map { String(localized: LocalizedStringResource("已停止 · 执行 \($0)", locale: locale)) }
                    ?? String(localized: LocalizedStringResource("已停止", locale: locale))
                accessibilityLabel = String(localized: LocalizedStringResource("智能体已停止", locale: locale))
            }
            tooltipText = displayText
        case .failed:
            brandState = .failed
            title = BrandCopy.failed
            displayText = duration.map { String(localized: LocalizedStringResource("执行失败 · 执行 \($0)", locale: locale)) }
                ?? String(localized: LocalizedStringResource("执行失败", locale: locale))
            accessibilityLabel = String(localized: LocalizedStringResource("智能体执行失败", locale: locale))
            tooltipText = displayText
        case .uncertain:
            brandState = .uncertain
            title = ""
            displayText = duration.map { String(localized: LocalizedStringResource("待核实 · 执行 \($0)", locale: locale)) }
                ?? String(localized: LocalizedStringResource("待核实", locale: locale))
            accessibilityLabel = String(localized: LocalizedStringResource("智能体执行状态待核实", locale: locale))
            tooltipText = displayText
        }
    }
}

struct TurnHeaderView: View {
    let turn: TurnRecord
    var locale = TranscriptTimestampFormatter.displayLocale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.zivviTypography) private var typography

    private var statusColor: Color {
        if turn.isHistoricalOutcomeMissing { return ZivviTheme.secondaryText }
        return switch turn.status {
        case .failed: ZivviTheme.errorText
        case .uncertain: ZivviTheme.warningText
        default: ZivviTheme.secondaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if turn.status == .running, let start = turn.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    header(relativeTo: context.date)
                }
            } else {
                header(relativeTo: .now)
            }
            Rectangle()
                .fill(ZivviTheme.border)
                .frame(height: 1 / displayScale)
                .accessibilityHidden(true)
        }
    }

    private func header(relativeTo now: Date) -> some View {
        let summary = TurnHeaderSummary(turn: turn, relativeTo: now, locale: locale)
        let glyphSize = typography.pointSize(for: .caption) + 4
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .center, spacing: 5) {
                BrandStateIconView(
                    state: summary.brandState,
                    turnID: turn.id,
                    size: glyphSize,
                    isMuted: turn.isHistoricalOutcomeMissing
                )
                if !summary.title.isEmpty {
                    Text(verbatim: summary.title)
                        .zivviFont(.caption, weight: .semibold)
                        .foregroundStyle(ZivviTheme.primaryText)
                }
            }
            .fixedSize()
            HStack(spacing: 3) {
                Text(verbatim: summary.displayText)
                if summary.brandState.isActivelyFlowing {
                    TurnLoadingDots()
                }
                if turn.status == .running, let elapsed = summary.elapsedText {
                    Text(verbatim: elapsed)
                }
            }
            .zivviFont(.caption)
            .monospacedDigit()
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(summary.tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary.accessibilityLabel))
        .accessibilityValue(Text(verbatim: summary.accessibilityValue ?? ""))
    }
}

private struct TurnLoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Jannchie Icons `loading-dots`: three dots bounce in succession.
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let period = 1.2
            let phase = reduceMotion ? 0.15 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            Canvas { context, size in
                let scale = size.width / 24
                for index in 0..<3 {
                    let lift = pow(max(0, sin(2 * .pi * (phase - Double(index) / 6))), 2)
                    let x = CGFloat(6 + index * 6) * scale
                    let y = size.height / 2 - lift * 4 * scale
                    let radius = 1.5 * scale
                    let dot = CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
                    context.fill(Path(ellipseIn: dot), with: .foreground)
                }
            }
        }
        .frame(width: 18, height: 12)
        .accessibilityHidden(true)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let width: CGFloat
    var workspaceDirectory: URL? = nil
    var approvalProjectDirectory: String? = nil
    var markdownStore: TranscriptMarkdownStore? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var queueFooter: String? = nil
    var handoffExpansion = HandoffRowExpansion()
    var approvalExpansion = ApprovalRecordExpansion()
    let contentChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let handoff = item.handoff {
                HandoffTranscriptRow(title: item.text, handoff: handoff,
                                     expanded: handoffExpansion.binding(for: handoff.id),
                                     filesExpanded: handoffExpansion.filesBinding(for: handoff.id),
                                     workspaceDirectory: workspaceDirectory,
                                     openFile: onOpenHandoffFile, contentChanged: contentChanged)
            } else if let request = item.expiredInteraction {
                ExpiredInteractionRow(request: request, projectDirectory: approvalProjectDirectory,
                                      expanded: approvalExpansion.binding(for: item.timelineID), contentChanged: contentChanged)
            } else if item.kind == .user {
                UserMessageRow(item: item, width: width, onEdit: onEditUserMessage,
                               onPreviewImage: onPreviewImage, queueFooter: queueFooter, contentChanged: contentChanged)
            } else {
                if item.kind != .assistant || item.hasVisibleText || item.images.isEmpty {
                    MarkdownContent(text: item.text, streaming: item.streaming, width: width, profile: .conversation,
                                    workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile,
                                    markdownStore: markdownStore, contentChanged: contentChanged)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                if !item.images.isEmpty {
                    TranscriptMessageImages(images: item.images, width: width, thumbnailSize: 120,
                                            onPreviewImage: onPreviewImage, contentChanged: contentChanged)
                        .padding(.vertical, 2)
                }
            }
        }
        .onChange(of: item.text) { _, _ in contentChanged() }
        .onChange(of: item.images.count) { _, _ in contentChanged() }
        .onChange(of: item.streaming) { _, _ in contentChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(item.timelineID)
    }
}

private struct TranscriptMessageImages: View {
    let images: [TranscriptImage]
    let width: CGFloat
    let thumbnailSize: CGFloat
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let contentChanged: () -> Void

    var body: some View {
        let spacing: CGFloat = 8
        let available = max(1, width)
        let size = min(thumbnailSize, available)
        let count = max(1, min(images.count, Int((available + spacing) / (size + spacing))))
        let columns = Array(repeating: GridItem(.fixed(size), spacing: spacing, alignment: .topLeading), count: count)
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(images) { image in
                TranscriptImageThumbnail(data: image.data, name: String(localized: "图片"),
                                         identifier: "message-image-\(image.id)", size: size,
                                         onPreviewImage: onPreviewImage, contentChanged: contentChanged)
                    .frame(width: size, height: size, alignment: .topLeading)
            }
        }
        .frame(width: size * CGFloat(count) + spacing * CGFloat(count - 1), alignment: .leading)
    }
}

@MainActor @Observable final class HandoffRowExpansion {
    private var expandedIDs: Set<UUID> = []
    private var expandedFileIDs: Set<UUID> = []

    func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.expandedIDs.contains(id) }, set: { expanded in
            if expanded {
                self.expandedIDs.insert(id)
            } else {
                self.expandedIDs.remove(id)
                self.expandedFileIDs.remove(id)
            }
        })
    }

    func filesBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.expandedFileIDs.contains(id) }, set: { expanded in
            if expanded { self.expandedFileIDs.insert(id) }
            else { self.expandedFileIDs.remove(id) }
        })
    }
}

struct SessionTransitionRow: View {
    let title: String
    var detail: String? = nil
    var color = ZivviTheme.secondaryText
    var titleWeight: Font.Weight? = nil
    var expanded: Bool? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZivviDivider().frame(minWidth: 8)
            if let action {
                Button(action: action) { label }
                    .buttonStyle(FlatControlButtonStyle(inset: false))
                    .accessibilityValue(expanded.map { $0 ? Text("已展开") : Text("已折叠") } ?? Text(""))
            } else {
                label
            }
            ZivviDivider().frame(minWidth: 8)
        }
        .padding(.vertical, 4)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(verbatim: title).zivviFont(.callout, weight: titleWeight).foregroundStyle(color)
            if let detail {
                Text(verbatim: "· \(detail)").zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
            }
            if action != nil { FlatDisclosureChevron(expanded == true ? .up : .forward) }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .padding(.vertical, 3)
    }
}

typealias HandoffFileOpener = @MainActor (ProjectFilePath, URL) async -> WorkbenchTabsModel.LinkedFileOpenOutcome

enum HandoffFileEntry: Identifiable {
    case change(SessionHandoffFile)
    case reference(String)

    var path: String {
        switch self {
        case .change(let file): file.path
        case .reference(let path): path
        }
    }

    var change: SessionHandoffFile? {
        if case .change(let file) = self { return file }
        return nil
    }

    var id: String { path }
}

private struct HandoffTranscriptRow: View {
    let title: String
    let handoff: SessionHandoff
    @Binding var expanded: Bool
    @Binding var filesExpanded: Bool
    let workspaceDirectory: URL?
    let openFile: HandoffFileOpener?
    let contentChanged: () -> Void

    private var hasDetails: Bool {
        !handoff.context.isEmpty || handoff.targetModel != nil ||
            handoff.coverage != .available || handoff.draft?.hasIncompleteFileHistory == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SessionTransitionRow(title: title,
                                 detail: handoff.context.isEmpty ? String(localized: "未携带历史") : String(localized: "已交接上下文"),
                                 titleWeight: .semibold,
                                 expanded: hasDetails ? expanded : nil,
                                 action: hasDetails ? { expanded.toggle() } : nil)
            if expanded && hasDetails {
                HandoffTranscriptDetails(handoff: handoff, filesExpanded: $filesExpanded,
                                         workspaceDirectory: workspaceDirectory, openFile: openFile,
                                         contentChanged: contentChanged)
            }
        }
        .onChange(of: expanded) { _, _ in contentChanged() }
    }
}

private struct HandoffTranscriptDetails: View {
    let handoff: SessionHandoff
    @Binding var filesExpanded: Bool
    let workspaceDirectory: URL?
    let openFile: HandoffFileOpener?
    let contentChanged: () -> Void

    var body: some View {
        let draft = handoff.draft
        let legacy = draft == nil && !handoff.context.isEmpty ? LegacyHandoffSummary(context: handoff.context) : nil
        let files = draft?.selectedFiles.map(HandoffFileEntry.change)
            ?? legacy?.relatedPaths.map(HandoffFileEntry.reference) ?? []
        let request = draft.map { $0.omitsHistory ? "" : $0.userRequest } ?? legacy?.request ?? ""
        let hasRequest = !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 14) {
            if let model = handoff.targetModel { Text("目标模型 · \(model.name)").foregroundStyle(.secondary) }
            if handoff.coverage == .partial { Text("原会话仅有部分历史可用。") }
            if handoff.coverage == .unavailable { Text("原会话没有可读取的历史。") }
            if handoff.draft?.hasIncompleteFileHistory == true {
                Text("部分回合缺少文件改动记录。").foregroundStyle(ZivviTheme.warningText)
            }
            if hasRequest {
                HandoffDetailExcerpt(title: "上次请求", text: request, showsBubble: true)
            } else if let draft, !draft.omitsHistory,
                      !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HandoffDetailExcerpt(title: "其他交接内容", text: draft.notes)
            } else if let reply = legacy?.reply {
                HandoffDetailExcerpt(title: "最近的智能体回复", text: reply)
            } else if let excerpt = legacy?.excerpt {
                Text(verbatim: excerpt).zivviFont(.callout).lineLimit(3)
            }
            if !files.isEmpty {
                HandoffSentFiles(files: files, hasChanges: draft != nil, workspaceDirectory: workspaceDirectory,
                                 openFile: openFile, contentChanged: contentChanged, expanded: $filesExpanded)
            }
        }
        .zivviFont(.caption)
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .background(alignment: .leading) { ZivviDivider(axis: .vertical) }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

struct LegacyHandoffSummary {
    private static let requestHeadings = ["最近的用户请求", "Latest user request"]
    private static let replyHeadings = ["最近的智能体回复", "Latest agent response"]
    private static let fileHeadings = ["相关文件", "Related files"]

    let request: String?
    let reply: String?
    let excerpt: String?
    let relatedPaths: [String]

    init(context: String) {
        let normalized = context.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        var paragraphs = normalized.components(separatedBy: "\n\n")
        var paths: [String] = []
        // The old generator wrote its newline-separated paths as the final section.
        if let last = paragraphs.last, let fileText = Self.sectionBody(last, headings: Self.fileHeadings) {
            let lines = fileText.components(separatedBy: "\n")
            if lines.allSatisfy(Self.looksLikePath) {
                var seen = Set<String>()
                paths = lines.filter { seen.insert($0).inserted }
                paragraphs.removeLast()
            }
        }
        relatedPaths = paths
        let text = paragraphs.joined(separator: "\n\n")
        if let userRequest = Self.sectionBody(text, headings: Self.requestHeadings) {
            let replyStart = Self.replyHeadings.compactMap { userRequest.range(of: "\n\n\($0)\n") }
                .min { $0.lowerBound < $1.lowerBound }
            request = replyStart.map { String(userRequest[..<$0.lowerBound]) } ?? userRequest
            reply = replyStart.map { String(userRequest[$0.upperBound...]) }
            excerpt = nil
        } else if let agentReply = Self.sectionBody(text, headings: Self.replyHeadings) {
            request = nil
            reply = agentReply
            excerpt = nil
        } else {
            request = nil
            reply = nil
            excerpt = text.isEmpty ? nil : text
        }
    }

    private static func sectionBody(_ text: String, headings: [String]) -> String? {
        for heading in headings {
            let prefix = heading + "\n"
            if text.hasPrefix(prefix) { return String(text.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static func looksLikePath(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("- "), !value.contains("://") else { return false }
        return value.contains("/") || !(value as NSString).pathExtension.isEmpty ||
            !value.contains(where: \.isWhitespace)
    }
}

private struct HandoffSentFiles: View {
    let files: [HandoffFileEntry]
    let hasChanges: Bool
    let workspaceDirectory: URL?
    let openFile: HandoffFileOpener?
    let contentChanged: () -> Void
    @Binding var expanded: Bool
    @State private var openTask: Task<Void, Never>?
    @State private var status: OpenStatus?

    private enum OpenStatus: Equatable {
        case opening(String)
        case unavailable(String, ProjectFileIssue)
    }

    var body: some View {
        let previewCount = 3
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if hasChanges {
                    Text("文件改动").zivviFont(.headline)
                    Text("随交接发送了 \(files.count) 个").foregroundStyle(ZivviTheme.secondaryText)
                } else {
                    Text("相关文件").zivviFont(.headline)
                    Text("\(files.count) 个").foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            ForEach(files.prefix(previewCount)) { file in
                fileRow(file)
            }
            if files.count > previewCount {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        expanded ? Text("全部收起") : Text("查看全部 \(files.count) 个")
                        FlatDisclosureChevron(expanded ? .up : .down)
                    }
                    .foregroundStyle(ZivviTheme.secondaryText)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, height: 22))
                .accessibilityValue(expanded ? Text("已展开") : Text("已折叠"))
                .accessibilityIdentifier("handoff-show-related-files")

                if expanded {
                    ForEach(files.dropFirst(previewCount)) { file in
                        fileRow(file)
                    }
                }
            }
        }
        .onChange(of: expanded) { _, _ in contentChanged() }
        .onChange(of: status) { _, _ in contentChanged() }
        .onChange(of: workspaceDirectory) { _, _ in cancelOpen() }
        .onDisappear { cancelOpen() }
    }

    private func fileRow(_ file: HandoffFileEntry) -> some View {
        let action: (() -> Void)?
        let issue: String?
        if file.change?.kind == .deleted {
            action = nil
            issue = String(localized: "已删除")
        } else if let directory = workspaceDirectory, let openFile {
            do {
                let path = try ProjectFilePath.handoffReference(file.path, recordedBase: file.change?.pathBase, in: directory)
                action = { open(path, in: directory, name: file.path, using: openFile) }
                if case .unavailable(let failedPath, let failure) = status, failedPath == file.path {
                    issue = failure.message
                }
                else { issue = nil }
            } catch {
                action = nil
                let failure = error as? ProjectFileIssue
                issue = failure == .handoffPathUnknown ? nil : failure?.message
            }
        } else {
            action = nil
            issue = ProjectFileIssue.rootUnavailable.message
        }
        return HandoffFileLink(file: file, issue: issue, opening: status == .opening(file.path), action: action)
    }

    private func open(_ path: ProjectFilePath, in directory: URL, name: String,
                      using openFile: @escaping HandoffFileOpener) {
        openTask?.cancel()
        status = .opening(name)
        openTask = Task {
            let outcome = await openFile(path, directory)
            guard !Task.isCancelled else { return }
            openTask = nil
            switch outcome {
            case .unavailable(let issue):
                status = .unavailable(name, issue)
            case .opened, .cancelled:
                status = nil
            }
        }
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
        status = nil
    }
}

private struct HandoffFileLink: View {
    let file: HandoffFileEntry
    let issue: String?
    let opening: Bool
    let action: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        let filename = file.path.split(separator: "/").last.map(String.init) ?? file.path
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let action {
                    Button(action: action) {
                        Text(verbatim: filename)
                            .underline()
                            .foregroundStyle(issue == nil ? MarkdownColors.link : ZivviTheme.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: focused, inset: false,
                                                        cornerRadius: 3, height: 22, showsHoverBackground: false))
                    .focused($focused)
                    .disabled(opening)
                    .accessibilityLabel(Text(verbatim: file.path))
                    .accessibilityHint("在右侧预览")
                    .accessibilityIdentifier("handoff-file-link:\(file.path)")
                } else {
                    Text(verbatim: filename)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: file.path))
                }
                if opening {
                    FlatProgressView().controlSize(.small)
                        .accessibilityLabel("正在打开文件")
                }
                Spacer(minLength: 8)
                if let change = file.change {
                    if let added = change.added, added > 0 { Text("+\(added)").fixedSize() }
                    if let deleted = change.deleted, deleted > 0 { Text("−\(deleted)").fixedSize() }
                    if change.added == nil || change.deleted == nil { Text("统计不全").fixedSize() }
                }
            }
            .foregroundStyle(ZivviTheme.secondaryText)
            if let issue {
                Text(verbatim: issue).zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
            }
        }
        .zivviFont(.callout)
        .help(file.path)
        .contextMenu {
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
}

private struct HandoffDetailExcerpt: View {
    let title: LocalizedStringKey
    let text: String
    var showsBubble = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).zivviFont(.headline)
            if showsBubble {
                Text(verbatim: text)
                    .zivviFont(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(UserMessageSurface())
                    .accessibilityIdentifier("handoff-previous-request")
            } else {
                Text(verbatim: text).zivviFont(.callout).lineLimit(3)
            }
        }
    }
}

private struct ExpiredInteractionRow: View {
    let request: RuntimeInteraction
    let projectDirectory: String?
    @Binding var expanded: Bool
    let contentChanged: () -> Void

    private var approvalSummary: Text? {
        if case .command(let command, _)? = request.toolApproval?.operation {
            return Text(verbatim: command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command)
        }
        if case .edit(let path, _)? = request.toolApproval?.operation {
            let name = (path as NSString).lastPathComponent
            return Text("编辑 \(name)", comment: "Expired approval for editing one file. The argument is the filename.")
        }
        if case .write(let path, _)? = request.toolApproval?.operation {
            let name = (path as NSString).lastPathComponent
            return Text("写入 \(name)", comment: "Expired approval for writing one file. The argument is the filename.")
        }
        if let context = request.permissionContext, request.isExpiredFileEditApproval {
            let directory = context.sessionDirectory ?? context.workingDirectory
            let edits = ApprovalPathFormatter.diffGroups(context.fileDiffs, relativeTo: directory,
                                                         deduplicateResolvedPaths: true)
            let paths = edits.isEmpty ? ApprovalPathFormatter.relatedPaths(
                context.paths, excluding: [], relativeTo: directory,
                deduplicateResolvedPaths: true).map(\.path) : edits.map(\.path)
            if paths.count > 1 { return Text("编辑 \(paths.count) 个文件") }
            if let path = paths.first {
                return Text("编辑 \((path as NSString).lastPathComponent)")
            }
        }
        return request.title.isEmpty ? nil : Text(verbatim: request.title)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ZivviDivider()
                if !request.isPermissionApproval { InteractionDeadline(expiresAt: request.expiresAt) }
                ExpiredInteractionDetails(request: request, projectDirectory: projectDirectory, contentChanged: contentChanged)
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    LightningIconView(.clockBadgeExclamationmark, size: 14)
                    (request.isPermissionApproval ? Text("审批已超时") : Text("请求已过期，未提交回复"))
                        .zivviFont(.callout, weight: .semibold)
                        .layoutPriority(1)
                    if request.isPermissionApproval {
                        Spacer(minLength: 8)
                        ApprovalRecordDeadline(expiresAt: request.expiresAt)
                    } else {
                        Spacer(minLength: 0)
                    }
                    FlatDisclosureChevron(expanded: expanded)
                }
                if !expanded, let summary = approvalSummary {
                    summary
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(ZivviTheme.mutedSurface, radius: 9)
        .onChange(of: expanded) { _, _ in contentChanged() }
    }
}

private struct ApprovalRecordDeadline: View {
    let expiresAt: Date
    @State private var referenceDate = Date()

    var body: some View {
        let deadline = TranscriptTimestampFormatter.approvalDeadline(expiresAt, relativeTo: referenceDate)
        let center = NotificationCenter.default
        let dateChanges = center.publisher(for: .NSCalendarDayChanged)
            .merge(with: center.publisher(for: .NSSystemTimeZoneDidChange),
                   center.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)
        Text("截止时间：\(deadline)")
            .zivviFont(.caption)
            .foregroundStyle(ZivviTheme.secondaryText)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .onAppear { referenceDate = .now }
            .onReceive(dateChanges) { _ in referenceDate = .now }
    }
}

extension DeliveryState {
    var showsBrandMessageMarker: Bool { self == .accepted || self == .handled }
}

private struct BoundedWidthLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let cappedMax = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        let cappedMin = min(minWidth, cappedMax)
        let size = child.sizeThatFits(ProposedViewSize(width: cappedMax, height: proposal.height))
        return CGSize(width: min(cappedMax, max(cappedMin, size.width)), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct UserMessageRow: View {
    let item: TranscriptItem
    let width: CGFloat
    let onEdit: ((TranscriptItem) -> Void)?
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let queueFooter: String?
    let contentChanged: () -> Void
    @Environment(\.zivviTypography) private var typography
    @State private var isHovering = false
    @State private var copiedFeedback = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var matchedImages: (request: ImageMatchRequest, files: Set<URL>)?
    @FocusState private var focusedAction: FooterAction?

    private enum FooterAction: Hashable {
        case edit, copy
    }

    private struct ImageMatchRequest: Equatable {
        let files: [URL]
        let imageIDs: [UUID]
    }

    private var needsAttentionDelivery: Bool {
        !item.delivery.showsBrandMessageMarker
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
        let mediaFiles = item.attachedFiles.filter {
            ImageAttachmentThumbnail.isImage($0) || VideoAttachmentThumbnail.isVideo($0)
        }
        let imageMatch = ImageMatchRequest(files: mediaFiles.filter { RuntimeACPInlineImage.mimeType(for: $0) != nil },
                                           imageIDs: item.images.map(\.id))
        let duplicates = matchedImages?.request == imageMatch ? matchedImages?.files ?? [] : []
        let attachments = mediaFiles.filter { !duplicates.contains($0) }
        let otherFiles = item.attachedFiles.filter { !mediaFiles.contains($0) }
        let showsText = (item.attachedFiles.isEmpty && item.images.isEmpty)
            || !item.editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsMarker = item.delivery.showsBrandMessageMarker
        let minBubbleWidth = min(width, UserMessageBrandBadge.minimumBubbleWidth(for: typography))
        let maxBubbleWidth = max(minBubbleWidth, width)
        let horizontalInset = showsMarker ? min(UserMessageSurface.horizontalInset, max(0, floor((width - 1) / 2))) : 0
        let horizontalPadding = 2 * horizontalInset
        let showsFloatingBadge = showsMarker && maxBubbleWidth >= UserMessageBrandBadge.minimumBubbleWidth(for: typography)
        let minInnerWidth = showsFloatingBadge ? max(0, minBubbleWidth - horizontalPadding) : 0
        let maxInnerWidth = max(1, maxBubbleWidth - horizontalPadding)
        let topOverhang = showsFloatingBadge ? UserMessageBrandBadge.topOverhang(for: typography) : 0
        return VStack(alignment: .leading, spacing: 4) {
            BoundedWidthLayout(minWidth: minInnerWidth, maxWidth: maxInnerWidth) {
                VStack(alignment: .leading, spacing: 8) {
                    if !attachments.isEmpty {
                        attachmentGrid(attachments, width: maxInnerWidth)
                    }
                    if !item.images.isEmpty {
                        TranscriptMessageImages(images: item.images, width: maxInnerWidth, thumbnailSize: 80,
                                                onPreviewImage: onPreviewImage, contentChanged: contentChanged)
                    }
                    if showsText || !otherFiles.isEmpty {
                        messageBody(showsText: showsText, files: otherFiles, innerWidth: maxInnerWidth)
                    } else if needsAttentionDelivery {
                        deliveryLabel
                    }
                }
            }
            .modifier(UserMessageSurface(isVisible: showsMarker, reservesTopBadgeInset: showsFloatingBadge, maxWidth: width))
            .overlay(alignment: .topLeading) {
                if showsFloatingBadge {
                    UserMessageBrandBadge(text: BrandCopy.userMessage)
                        .offset(x: UserMessageBrandBadge.leadingOffset,
                                y: -UserMessageBrandBadge.height(for: typography) / 2)
                }
            }
            .padding(.top, topOverhang)

            if let queueFooter {
                Text(queueFooter)
                    .zivviFont(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .accessibilityIdentifier("message-queue-footer")
            }

            HStack(spacing: 8) {
                Text(timeDisplay)
                    .zivviFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(timeTooltip)
                if let onEdit, item.canRestoreToDraft {
                    Button {
                        onEdit(item)
                    } label: {
                        LightningIconView(.pencil, size: 12)
                    }
                    .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: focusedAction == .edit,
                                                        inset: false, cornerRadius: 5, height: 20, minimumWidth: 20))
                    .focused($focusedAction, equals: .edit)
                    .help("编辑")
                    .accessibilityLabel("编辑")
                    .accessibilityIdentifier("edit-\(item.timelineID)")
                }
                Button {
                    copyMessage()
                } label: {
                    LightningIconView(copiedFeedback ? .checkmark : .docOnDoc, size: 12)
                }
                .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: focusedAction == .copy,
                                                    inset: false, cornerRadius: 5, height: 20, minimumWidth: 20))
                .focused($focusedAction, equals: .copy)
                .disabled(item.editableText.isEmpty)
                .help("复制")
                .accessibilityLabel("复制")
                .accessibilityIdentifier("copy-\(item.timelineID)")
                if copiedFeedback {
                    Text("已复制")
                        .zivviFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 20)
            .revealedAction(showsFooter)
            .accessibilityElement(children: .contain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .task(id: imageMatch) {
            guard !imageMatch.files.isEmpty, !imageMatch.imageIDs.isEmpty else { return }
            let files = imageMatch.files
            let images = item.images.map(\.data)
            let matches = await Task.detached(priority: .utility) {
                TranscriptImageFiles.duplicates(in: files, images: images)
            }.value
            guard !Task.isCancelled else { return }
            matchedImages = (imageMatch, matches)
            contentChanged()
        }
        .onDisappear { copyFeedbackTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("用户消息")
        .accessibilityActions {
            if let onEdit, item.canRestoreToDraft {
                Button("编辑") { onEdit(item) }
            }
            if !item.editableText.isEmpty {
                Button("复制", action: copyMessage)
            }
        }
    }

    private var deliveryLabel: some View {
        DeliveryLabel(state: item.delivery)
            .padding(.bottom, item.delivery == .queued ? 2 : 0)
    }

    private func messageBody(showsText: Bool, files: [URL], innerWidth: CGFloat) -> some View {
        let lineSpacing = MarkdownStyle(
            profile: .conversation,
            width: MarkdownWidth(innerWidth),
            typography: typography
        ).body.lineSpacing()
        return VStack(alignment: .leading, spacing: 6) {
            if needsAttentionDelivery { deliveryLabel }
            if showsText {
                Text(verbatim: item.editableText)
                    .zivviFont(.body)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !files.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { fileLabels(files) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { fileLabels(files) }
                }
            }
        }
    }

    private func fileLabels(_ files: [URL]) -> some View {
        ForEach(files, id: \.self) { file in
            LightningLabel(icon: .paperclip, size: 11) {
                Text(verbatim: file.lastPathComponent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .zivviFont(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ZivviTheme.surface, in: .capsule)
            .help(file.path)
        }
    }

    private func attachmentGrid(_ attachments: [URL], width: CGFloat) -> some View {
        let spacing: CGFloat = 8
        let available = max(1, width)
        let size = min(80, available)
        let columns = max(1, Int((available + spacing) / (size + spacing)))
        let rowStarts = Array(stride(from: 0, to: attachments.count, by: columns))
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(rowStarts, id: \.self) { start in
                HStack(spacing: spacing) {
                    ForEach(start..<min(start + columns, attachments.count), id: \.self) { index in
                        attachmentThumbnail(attachments[index], index: index, size: size)
                    }
                }
            }
        }
    }

    @ViewBuilder private func attachmentThumbnail(_ file: URL, index: Int, size: CGFloat) -> some View {
        if VideoAttachmentThumbnail.isVideo(file) {
            VideoAttachmentThumbnail(file: file, size: size, onOpen: { NSWorkspace.shared.open(file) })
                .accessibilityIdentifier("open-video-\(item.timelineID)-\(index)")
        } else if let onPreviewImage {
            Button { onPreviewImage(.file(file)) } label: {
                ImageAttachmentThumbnail(file: file, size: size)
            }
            .buttonStyle(OverlayFeedbackButtonStyle(shape: RoundedRectangle(cornerRadius: ImageAttachmentThumbnail.cornerRadius)))
            .accessibilityLabel("预览 \(file.lastPathComponent)")
            .accessibilityIdentifier("preview-image-\(item.timelineID)-\(index)")
        } else {
            ImageAttachmentThumbnail(file: file, size: size)
        }
    }

    private func copyMessage() {
        guard !item.editableText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.editableText, forType: .string)
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
    private var thinking: Set<UUID> = []

    func groupBinding(for items: [TranscriptItem]) -> Binding<Bool> {
        Binding {
            !self.groups.isDisjoint(with: items.lazy.map(\.timelineID))
        } set: { expanded in
            if expanded { self.groups.insert(items[0].timelineID) }
            else { self.groups.subtract(items.lazy.map(\.timelineID)) }
        }
    }

    func detailBinding(for item: TranscriptItem, isSingle: Bool) -> Binding<Bool> {
        Binding {
            self.details.contains(item.timelineID) && (!isSingle || self.groups.contains(item.timelineID))
        } set: { expanded in
            if expanded {
                self.details.insert(item.timelineID)
                // Keep the enclosing tool group open if this running tool finishes and rolls into it.
                self.groups.insert(item.timelineID)
            } else {
                self.details.remove(item.timelineID)
                if isSingle { self.groups.remove(item.timelineID) }
            }
        }
    }

    func thinkingBinding(for turn: TurnRecord) -> Binding<Bool> {
        Binding {
            self.thinking.contains(turn.id)
        } set: { expanded in
            if expanded { self.thinking.insert(turn.id) }
            else { self.thinking.remove(turn.id) }
        }
    }
}

@MainActor struct ToolCallsSummary {
    let total: Int
    let statuses: [Status]
    let runningToolName: String?
    let commands: Int
    let edits: Int
    let reads: Int
    let searches: Int
    let listings: Int
    let finds: Int
    let writes: Int

    struct Status: Identifiable {
        let state: ToolState
        let count: Int
        var id: ToolState { state }
        var label: LocalizedStringResource {
            switch state {
            case .running: "\(count) 项执行中"
            case .failed: "失败 \(count) 项"
            case .interrupted: "\(count) 项已中断"
            case .completed: "已完成"
            }
        }
    }

    init(items: [TranscriptItem]) {
        total = items.count
        var counts: [ToolState: Int] = [:]
        var commands = 0
        var edits = 0
        var reads = 0
        var searches = 0
        var listings = 0
        var finds = 0
        var writes = 0
        var runningToolName: String?
        for item in items {
            guard let summary = item.toolSummary else { continue }
            counts[summary.state, default: 0] += 1
            if summary.state == .running { runningToolName = summary.name }
            switch ToolCallKind(name: summary.name) {
            case .command: commands += 1
            case .edit: edits += 1
            case .read: reads += 1
            case .search: searches += 1
            case .list: listings += 1
            case .find: finds += 1
            case .write: writes += 1
            case .other: break
            }
        }
        self.commands = commands
        self.edits = edits
        self.reads = reads
        self.searches = searches
        self.listings = listings
        self.finds = finds
        self.writes = writes
        self.runningToolName = runningToolName
        statuses = [ToolState.failed, .interrupted, .running].compactMap { state in
            counts[state].map { Status(state: state, count: $0) }
        }
    }

    var countLabel: LocalizedStringResource { "\(total) 项工具调用" }

    var composition: [LocalizedStringResource] {
        let classified = commands + edits + reads + searches + listings + finds + writes
        guard classified > 0 else { return [] }
        let other = total - classified
        var parts: [LocalizedStringResource] = []
        if edits > 0 { parts.append("\(edits) 次编辑") }
        if commands > 0 { parts.append("\(commands) 条命令") }
        if reads > 0 { parts.append("\(reads) 次读取") }
        if searches > 0 { parts.append("\(searches) 次搜索") }
        if listings > 0 { parts.append("\(listings) 次列目录") }
        if finds > 0 { parts.append("\(finds) 次文件查找") }
        if writes > 0 { parts.append("\(writes) 次写入") }
        if other > 0 { parts.append("其他 \(other) 项") }
        return parts
    }

    var description: String {
        var parts = [countLabel] + composition + statuses.map(\.label)
        if let runningToolName {
            let name = switch ToolCallKind(name: runningToolName) {
            case .command: String(localized: "运行命令")
            case .edit: String(localized: "编辑")
            case .read: String(localized: "读取")
            case .search: String(localized: "搜索")
            case .list: String(localized: "列出目录")
            case .find: String(localized: "查找文件")
            case .write: String(localized: "写入文件")
            case .other: runningToolName
            }
            parts.append("正在执行：\(name)")
        }
        return parts.map { String(localized: $0) }.joined(separator: String(localized: "，"))
    }
}

struct ToolCallsRow: View {
    let items: [TranscriptItem]
    let expansion: ToolCallExpansion
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onShowOutput: ((ToolOutputSelection) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    let contentChanged: () -> Void

    var body: some View {
        let runningItems = items.filter { $0.toolSummary?.state == .running }
        let finishedItems = items.filter { $0.toolSummary?.state != .running }

        if items.count == 1, let item = items.first {
            // The sole tool is also the group header; keep the same disclosure at completion.
            ToolRow(
                item: item,
                expanded: expansion.detailBinding(for: item, isSingle: true),
                workspaceDirectory: workspaceDirectory,
                onOpenFile: onOpenFile,
                onOpenToolDiff: onOpenToolDiff,
                onShowOutput: onShowOutput,
                onPreviewImage: onPreviewImage,
                showsRunningEffect: true,
                contentChanged: contentChanged
            )
        } else if !runningItems.isEmpty {
            // Workbench 2.0 Section 11.1: completed tools aggregate automatically;
            // currently running tools remain independently visible below the group.
            VStack(alignment: .leading, spacing: 2) {
                if !finishedItems.isEmpty {
                    aggregatedGroup(for: finishedItems, allItems: items)
                }
                ForEach(runningItems) { running in
                    ToolRow(
                        item: running,
                        expanded: expansion.detailBinding(for: running, isSingle: false),
                        workspaceDirectory: workspaceDirectory,
                        onOpenFile: onOpenFile,
                        onOpenToolDiff: onOpenToolDiff,
                        onShowOutput: onShowOutput,
                        onPreviewImage: onPreviewImage,
                        showsRunningEffect: true,
                        contentChanged: contentChanged
                    )
                }
            }
        } else {
            aggregatedGroup(for: items, allItems: items)
        }
    }

    private func aggregatedGroup(for groupItems: [TranscriptItem], allItems: [TranscriptItem]) -> some View {
        let expanded = expansion.groupBinding(for: allItems)
        let summary = ToolCallsSummary(items: groupItems)
        return ToolCallDisclosure(isExpanded: expanded, isRunning: false) {
            VStack(spacing: 2) {
                ForEach(groupItems) { item in
                    ToolRow(
                        item: item,
                        expanded: expansion.detailBinding(for: item, isSingle: false),
                        workspaceDirectory: workspaceDirectory,
                        onOpenFile: onOpenFile,
                        onOpenToolDiff: onOpenToolDiff,
                        onShowOutput: onShowOutput,
                        onPreviewImage: onPreviewImage,
                        contentChanged: contentChanged
                    )
                }
            }
            .padding(.leading, 16)
            .padding(.top, 2)
        } label: { emphasized in
            HStack(spacing: 7) {
                Label { Text(summary.countLabel) } icon: {
                    ToolCallIcon(glyph: .generic)
                }
                .zivviFont(.callout)
                .fixedSize()
                let parts = summary.composition
                if !parts.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: "· " + parts.map { String(localized: $0) }.joined(separator: String(localized: "、")))
                            .zivviFont(.caption)
                            .foregroundStyle(emphasized ? ZivviTheme.secondaryText : ZivviTheme.tertiaryText)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                ForEach(summary.statuses) { status in
                    Text(status.label).zivviFont(.caption).foregroundStyle(status.state.statusColor).fixedSize()
                }
                Spacer(minLength: 6)
                FlatDisclosureChevron(expanded: expanded.wrappedValue)
                    .frame(width: 12, alignment: .center)
                    .opacity(expanded.wrappedValue || emphasized ? 1 : 0)
            }
            .lineLimit(1)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.description)
        }
        .accessibilityIdentifier("tool-group-\(allItems[0].timelineID)")
        .onChange(of: expanded.wrappedValue) { _, _ in contentChanged() }
    }
}

struct TranscriptThinkingRow: View {
    let turn: TurnRecord
    @Binding var expanded: Bool
    var contentChanged: () -> Void = {}

    var body: some View {
        let thought = turn.thoughtText
        Group {
            if Self.isWaiting(thought) {
                Label { Text(Self.waitingTitle) } icon: {
                    ThinkingDotsIcon()
                }
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.tertiaryText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(Self.waitingTitle))
            } else {
                ToolCallDisclosure(isExpanded: $expanded) {
                    Text(verbatim: thought)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .flatSurface(ZivviTheme.mutedSurface)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("transcript-thinking-details")
                } label: { emphasized in
                    HStack(spacing: 7) {
                        ThinkingDotsIcon()
                        Text("思考中")
                            .zivviFont(.callout)
                            .fixedSize()
                        if !expanded, let preview = Self.previewLine(thought) {
                            Text(verbatim: preview)
                                .zivviFont(.caption)
                                .foregroundStyle(emphasized ? ZivviTheme.secondaryText : ZivviTheme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        FlatDisclosureChevron(expanded: expanded)
                            .opacity(emphasized || expanded ? 1 : 0)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("思考中"))
                    .accessibilityValue(thought)
                }
                .onChange(of: expanded) { _, _ in contentChanged() }
                .onChange(of: thought) { _, _ in if expanded { contentChanged() } }
            }
        }
        .accessibilityIdentifier("transcript-thinking")
    }

    static let waitingTitle: LocalizedStringResource = "等待回复"

    static func isWaiting(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    private static func previewLine(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line
    }
}

private struct ThinkingDotsIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Jannchie Icons `loading-grid`: nine dots pulse along diagonals.
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let period = 1.4
            let phase = reduceMotion ? 0.25 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            Canvas { context, size in
                let scale = size.width / 24
                for row in 0..<3 {
                    for column in 0..<3 {
                        let progress = phase - Double(row + column) / 8
                        let pulse = 0.5 - 0.5 * cos(2 * .pi * progress)
                        let radius = (0.5 + 1.3 * pulse) * scale
                        let x = (6.5 + 5.5 * CGFloat(column)) * scale
                        let y = (6.5 + 5.5 * CGFloat(row)) * scale
                        let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: dot), with: .foreground)
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
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
            Text(label).zivviFont(.caption2, weight: state == .queued ? .semibold : .regular)
            if state == .queued {
                InfinityLoadingIcon(size: 14)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(state == .unknown || state == .rejected ? ZivviTheme.warningText : Color.secondary)
        .accessibilityIdentifier("message-delivery-status")
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
    var statusColor: Color {
        switch self {
        case .running: ZivviTheme.runningText
        case .failed: ZivviTheme.errorText
        case .interrupted: ZivviTheme.warningText
        default: .secondary
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
                    Text("参数").zivviFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(tool.arguments).zivviFont(.caption, design: .monospaced).textSelection(.enabled)
                    }
                    .scrollIndicators(.never)
                }
                if !tool.output.isEmpty {
                    ZivviDivider()
                    ScrollView(.horizontal) {
                        Text(tool.output).zivviFont(.callout, design: .monospaced).textSelection(.enabled)
                    }
                    .scrollIndicators(.never)
                }
                if tool.truncated { Text("输出过长，仅显示部分内容。").zivviFont(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .onChange(of: tool) { _, _ in contentChanged() }
        }
    }
}
