import AppKit
import SwiftUI
import OrchestrationCore

@MainActor struct NativeTranscriptRow {
    let content: TranscriptDisplayRow
    let replyFooter: TranscriptReplyFooter?

    let groupInset: CGFloat
    let readingID: TranscriptReadingID

    init(content: TranscriptDisplayRow, replyFooter: TranscriptReplyFooter?, groupInset: CGFloat = 0,
         readingID: TranscriptReadingID? = nil) {
        self.content = content
        self.replyFooter = replyFooter
        self.groupInset = groupInset
        self.readingID = readingID ?? TranscriptReadingID(content.id)
    }

    static func project(_ rows: [TranscriptDisplayRow], footers: [String: TranscriptReplyFooter],
                        typography: ZivviTypography = .init()) -> [Self] {
        var counts: [String: Int] = [:]
        return rows.enumerated().map { index, row in
            let id = row.id
            let occurrence = counts[id, default: 0]
            counts[id] = occurrence + 1
            return Self(content: row, replyFooter: footers[id],
                        groupInset: groupInset(before: row, after: index > 0 ? rows[index - 1] : nil,
                                               typography: typography),
                        readingID: .init(id, occurrence: occurrence))
        }
    }

    static func groupInset(before row: TranscriptDisplayRow, after previous: TranscriptDisplayRow?,
                           typography: ZivviTypography = .init()) -> CGFloat {
        guard let previous else { return 0 }
        let ordinaryGap = ZivviSpacing.timelineRowGap + 2 * ZivviSpacing.timelineRowInset
        if case .item(let item) = row, item.kind == .user, item.handoff == nil {
            let overhang = item.delivery.showsBrandMessageMarker
                ? UserMessageBrandBadge.topOverhang(for: typography)
                : 0
            return max(0, ZivviSpacing.messageGroup - ordinaryGap - overhang)
        }
        if case .item(let previousItem) = previous, previousItem.kind == .user, previousItem.handoff == nil {
            return max(0, ZivviSpacing.messageAfterUserGroup - ordinaryGap)
        }
        guard startsTurn(row) else { return 0 }
        return max(0, ZivviSpacing.messageGroup - ordinaryGap)
    }

    private static func startsTurn(_ row: TranscriptDisplayRow) -> Bool {
        if case .turnHeader = row { return true }
        return false
    }

    var id: String { readingID.messageID }

    func hasSameItems(as other: Self) -> Bool {
        guard readingID == other.readingID, groupInset == other.groupInset,
              content.hasSameItems(as: other.content) else { return false }
        switch (replyFooter, other.replyFooter) {
        case (nil, nil): return true
        case (let footer?, let otherFooter?): return footer.hasSameItems(as: otherFooter)
        default: return false
        }
    }

    func contains(_ itemID: String) -> Bool { content.contains(itemID) }
}

struct TranscriptHost: View {
    let row: NativeTranscriptRow?
    let width: CGFloat
    let fontSize: InterfaceFontSize
    var workspaceDirectory: URL? = nil
    var approvalProjectDirectory: String? = nil
    var markdownStore: TranscriptMarkdownStore? = nil
    let toolExpansion: ToolCallExpansion
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    let onEditUserMessage: ((TranscriptItem) -> Void)?
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var onShowToolOutput: ((ToolOutputSelection) -> Void)? = nil
    var onSwitchModel: (() -> Void)? = nil
    var onOpenConnectionSettings: (() -> Void)? = nil
    var onSafeRetry: (() -> Void)? = nil
    var turnChangesExpansion = TurnChangesExpansion()
    var handoffExpansion = HandoffRowExpansion()
    var approvalExpansion = ApprovalRecordExpansion()
    var replyHover = TranscriptReplyHover()
    var queueFooter: String? = nil
    /// Only needed when AppKit reuses a single `NSHostingView` across distinct rows.
    var resetsIdentityOnReuse = true
    let changed: () -> Void
    var body: some View {
        if let row {
            rowBody(row)
                .padding(.top, row.groupInset)
                .zivviTypography(fontSize)
                .disclosureGroupStyle(FlatDisclosureStyle())
                .environment(\.openURL, TranscriptFileOpener.openAction(workspaceDirectory: workspaceDirectory, openFile: onOpenFile))
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder
    private func rowBody(_ row: NativeTranscriptRow) -> some View {
        let content = Group {
            switch row.content {
            case .item(let item) where item.kind == .assistant:
                replyRegion(row) { messageRow(item) }
            case .item(let item):
                messageRow(item)
            case .modelChange(_, let change):
                SessionTransitionRow(title: change.title)
                    .accessibilityIdentifier(row.id)
            case .turnHeader(let turn):
                TurnHeaderView(turn: turn)
                    .accessibilityIdentifier(row.id)
            case .turnChanges(let turn):
                if let changes = turn.fileChanges {
                    replyRegion(row) {
                        TurnChangesRow(changes: changes, id: row.id, expansion: turnChangesExpansion,
                                       workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile,
                                       contentChanged: changed)
                    }
                }
            case .turnFailure(let turn):
                if let failure = turn.failure {
                    TurnExecutionErrorView(
                        failure: failure,
                        occurredAt: turn.endedAt ?? turn.startedAt,
                        onSwitchModel: onSwitchModel,
                        onOpenSettings: onOpenConnectionSettings,
                        onSafeRetry: onSafeRetry,
                        contentChanged: changed
                    )
                    .accessibilityIdentifier(row.id)
                }
            case .thinking(let turn):
                TranscriptThinkingRow(turn: turn, expanded: toolExpansion.thinkingBinding(for: turn),
                                      contentChanged: changed)
            case .toolCalls(let tools):
                ToolCallsRow(
                    items: tools,
                    expansion: toolExpansion,
                    workspaceDirectory: workspaceDirectory,
                    onOpenFile: onOpenFile,
                    onOpenToolDiff: onOpenToolDiff,
                    onShowOutput: onShowToolOutput,
                    onPreviewImage: onPreviewImage,
                    contentChanged: changed
                )
            }
        }
        if resetsIdentityOnReuse {
            content.id(row.id)
        } else {
            content
        }
    }

    private func messageRow(_ item: TranscriptItem) -> some View {
        TranscriptRow(item: item, width: width, workspaceDirectory: workspaceDirectory,
                      approvalProjectDirectory: approvalProjectDirectory,
                      markdownStore: markdownStore, onOpenFile: onOpenFile,
                      onOpenHandoffFile: onOpenHandoffFile,
                      onEditUserMessage: onEditUserMessage,
                      onPreviewImage: onPreviewImage, queueFooter: queueFooter,
                      handoffExpansion: handoffExpansion, approvalExpansion: approvalExpansion, contentChanged: changed)
    }

    private func replyRegion<Content: View>(_ row: NativeTranscriptRow, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            if let reply = row.replyFooter {
                AssistantReplyActions(reply: reply, rowID: row.id, hover: replyHover)
            }
        }
        .contentShape(.rect)
        .onHover { replyHover.setHovered($0, rowID: row.id) }
        .onDisappear { replyHover.setHovered(false, rowID: row.id) }
    }
}
