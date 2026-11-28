import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

enum ApprovalCategory: Equatable {
    case command
    case edit
}

extension RuntimeInteraction {
    var approvalCategory: ApprovalCategory? {
        if let operation = toolApproval?.operation {
            switch operation {
            case .command: return .command
            case .edit: return .edit
            case .write, .inspect: return nil
            }
        }
        guard isPermissionApproval else { return nil }
        switch permissionContext?.toolKind {
        case "execute": return .command
        case "edit": return .edit
        case nil:
            return permissionContext?.fileDiffs.isEmpty == false ? .edit : nil
        default:
            return nil
        }
    }

    var usesUnifiedApprovalSheet: Bool {
        approvalCategory != nil
    }
}

enum ApprovalIntentResolver {
    static func resolve(
        category: ApprovalCategory,
        requestTitle: String,
        toolTitle: String?,
        toolSummary: String?,
        summary: String?,
        message: String,
        command: String?,
        filePaths: [String]
    ) -> (primary: String, secondary: String?) {
        let trimmedToolSummary = trimmedNonEmpty(toolSummary)
        let trimmedSummary = trimmedNonEmpty(summary)
        let trimmedMessage = trimmedNonEmpty(message)

        let candidates = [trimmedToolSummary, trimmedSummary, trimmedMessage].compactMap(\.self)
        if let primary = candidates.first(where: { !isRedundant($0, category: category, command: command, filePaths: filePaths) }) {
            let secondary = candidates.first {
                $0 != primary && !isRedundant($0, category: category, command: command, filePaths: filePaths)
            }
            return (primary, secondary)
        }

        for titleCandidate in [trimmedNonEmpty(requestTitle), trimmedNonEmpty(toolTitle)].compactMap(\.self) {
            if !isRedundant(titleCandidate, category: category, command: command, filePaths: filePaths) {
                return (titleCandidate, nil)
            }
        }

        let fallback = switch category {
        case .command: String(localized: "执行 Shell 命令")
        case .edit: String(localized: "修改文件")
        }
        return (fallback, nil)
    }

    private static func trimmedNonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeSingleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isRedundant(
        _ candidate: String,
        category: ApprovalCategory,
        command: String?,
        filePaths: [String]
    ) -> Bool {
        let normalized = normalizeSingleLine(candidate)
        switch category {
        case .command:
            if let command {
                let normalizedCommand = normalizeSingleLine(command)
                if !normalizedCommand.isEmpty && normalized == normalizedCommand {
                    return true
                }
            }
            return false
        case .edit:
            let lower = normalized.lowercased()
            for path in filePaths where !path.isEmpty {
                let filename = (path as NSString).lastPathComponent
                let candidates = [
                    path,
                    filename,
                    "修改 \(filename)",
                    "编辑 \(filename)",
                    "修改 \(path)",
                    "编辑 \(path)",
                    "Edit \(filename)",
                    "Edit \(path)",
                    "File \(filename)",
                    "File \(path)"
                ]
                if candidates.contains(where: { $0.lowercased() == lower }) {
                    return true
                }
            }
            return false
        }
    }
}

struct ApprovalContentSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(ZivviTheme.mutedSurface, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(ZivviTheme.border, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func approvalContentSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(ApprovalContentSurface(cornerRadius: cornerRadius))
    }
}

struct UnifiedApprovalSheet: View {
    let request: RuntimeInteraction
    let category: ApprovalCategory
    let projectDirectory: String?
    let expired: Bool
    let notice: String?
    let error: String?
    let submitting: Bool
    let reply: (InteractionResponse) -> Void
    let closeExpired: () -> Void

    @State private var technicalDetailsExpanded = false
    @State private var rawInputDisclosureHovered = false
    @State private var wrapsPreviewLines = true
    @State private var wrapsRawInputLines = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zivviTypography) private var typography

    private var context: RuntimePermissionContext? { request.permissionContext }
    private var approval: RuntimeToolApproval? { request.toolApproval }

    private var sessionDirectory: String? {
        let path = context?.sessionDirectory ?? approval?.workingDirectory ?? context?.workingDirectory
        return path.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var explicitWorkingDirectory: String? {
        let path = approval?.workingDirectory ?? context?.workingDirectory
        return path.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var distinctWorkingDirectory: String? {
        ApprovalPathFormatter.distinctDirectory(explicitWorkingDirectory, from: sessionDirectory)
    }

    private var commandText: String? {
        if case .command(let text, _) = approval?.operation {
            return text
        }
        return nil
    }

    private var commandTimeout: Double? {
        if case .command(_, let timeout) = approval?.operation {
            return timeout
        }
        return nil
    }

    private var diffGroups: [ApprovalPathFormatter.DiffGroup] {
        let diffs: [RuntimePermissionContext.FileDiff]
        if let contextDiffs = context?.fileDiffs, !contextDiffs.isEmpty {
            diffs = contextDiffs
        } else if case .edit(let path, let replacements) = approval?.operation {
            diffs = replacements.map { .init(path: path, oldText: $0.oldText, newText: $0.newText) }
        } else {
            diffs = []
        }
        return ApprovalPathFormatter.diffGroups(diffs, relativeTo: sessionDirectory, deduplicateResolvedPaths: true)
    }

    private var relatedPaths: [ApprovalPathFormatter.RelatedPath] {
        let allDiffs: [RuntimePermissionContext.FileDiff]
        if let contextDiffs = context?.fileDiffs, !contextDiffs.isEmpty {
            allDiffs = contextDiffs
        } else if case .edit(let path, let replacements) = approval?.operation {
            allDiffs = replacements.map { .init(path: path, oldText: $0.oldText, newText: $0.newText) }
        } else {
            allDiffs = []
        }
        return ApprovalPathFormatter.relatedPaths(context?.paths ?? [], excluding: allDiffs,
                                                  relativeTo: sessionDirectory, deduplicateResolvedPaths: true)
    }

    private var resolvedIntent: (primary: String, secondary: String?) {
        var filePaths: [String] = []
        let rawPaths = diffGroups.map(\.path) + relatedPaths.map(\.path)
        for path in rawPaths {
            filePaths.append(path)
            let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: sessionDirectory)
            filePaths.append(absolute)
            filePaths.append(ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory))
        }
        if filePaths.isEmpty, case .edit(let path, _) = approval?.operation {
            let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: sessionDirectory)
            filePaths = [path, absolute, ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory)]
        }
        return ApprovalIntentResolver.resolve(
            category: category,
            requestTitle: request.title,
            toolTitle: context?.toolTitle,
            toolSummary: context?.toolSummary,
            summary: context?.summary,
            message: request.permissionOptions.isEmpty ? "" : request.message,
            command: commandText,
            filePaths: filePaths
        )
    }

    private var resolvedToolIdentity: (name: String?, kind: String?) {
        let name = context?.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? (request.permissionOptions.isEmpty ? localToolName : nil)
        let kind = context?.toolKind.flatMap { $0.isEmpty ? nil : $0 } ?? (request.permissionOptions.isEmpty ? localToolKind : nil)
        return (name, kind)
    }

    private var localToolName: String {
        switch category {
        case .command: "bash"
        case .edit: "edit"
        }
    }

    private var localToolKind: String {
        switch category {
        case .command: "execute"
        case .edit: "edit"
        }
    }

    private var hasTechnicalDetails: Bool {
        resolvedToolIdentity.name != nil
            || resolvedToolIdentity.kind != nil
            || commandTimeout != nil
            || context?.rawInputJSON != nil
            || sessionDirectory != nil
            || (expired && !expiredOptionNames.isEmpty)
    }

    private var expiredOptionNames: [String] {
        request.permissionOptions.isEmpty ? request.options : request.permissionOptions.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
            if expired {
                UnifiedExpiredApprovalFooter(close: closeExpired)
                    .layoutPriority(1)
            } else {
                ToolApprovalFooter(
                    adaptive: true,
                    options: request.permissionOptions,
                    submitting: submitting,
                    awaitingToolDetails: context?.awaitingToolDetails == true,
                    reply: reply
                )
                .layoutPriority(1)
            }
        }
        .onChange(of: request.id) {
            technicalDetailsExpanded = false
            wrapsPreviewLines = true
            wrapsRawInputLines = true
        }
    }

    private var content: some View {
        let intent = resolvedIntent
        return VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                headerRow
                Text(verbatim: intent.primary)
                    .zivviFont(.title2, weight: .semibold)
                    .foregroundStyle(ZivviTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("approval-intent-title")
                if let secondary = intent.secondary {
                    Text(verbatim: secondary)
                        .zivviFont(.callout)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if category == .command {
                    commandTargetSection
                } else if diffGroups.isEmpty {
                    editFallbackTargetSection
                }
            }

            coreContentSection

            if hasTechnicalDetails {
                technicalDetailsSection
            }

            if !expired {
                if let notice {
                    Text(verbatim: notice)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
                if let error {
                    Text(verbatim: error)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.errorText)
                }
            }
        }
        .padding(ApprovalSheetLayout.inset)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                LightningIconView(category == .command ? .terminal : .squareAndPencil, size: 14)
                Text(category == .command ? LocalizedStringKey("执行命令") : LocalizedStringKey("修改文件"))
                    .zivviFont(.caption, weight: .medium)
            }
            .foregroundStyle(ZivviTheme.secondaryText)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if expired {
                LightningLabel("已超时", icon: .clockBadgeExclamationmark, size: 13)
                    .zivviFont(.caption, weight: .medium)
                    .foregroundStyle(ZivviTheme.warningText)
                    .accessibilityIdentifier("interaction-expired-status")
            } else {
                InteractionCountdown(expiresAt: request.expiresAt)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder
    private var commandTargetSection: some View {
        let primaryDirectory = distinctWorkingDirectory ?? sessionDirectory
        if let primaryDirectory, !primaryDirectory.isEmpty {
            ApprovalFlatPathRow(
                icon: "folder",
                path: primaryDirectory,
                projectDirectory: projectDirectory,
                identifier: distinctWorkingDirectory != nil ? "approval-command-directory" : "approval-working-directory"
            )
        }
        if !relatedPaths.isEmpty {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                ForEach(relatedPaths) { item in
                    ApprovalFlatPathRow(
                        icon: "doc.text",
                        path: item.path,
                        projectDirectory: projectDirectory,
                        identifier: "approval-affected-file"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var editFallbackTargetSection: some View {
        if case .edit(let path, _) = approval?.operation {
            ApprovalEditFileTargetHeader(
                path: path,
                projectDirectory: projectDirectory,
                relativeTo: sessionDirectory
            )
        } else if !relatedPaths.isEmpty {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                ForEach(relatedPaths) { item in
                    ApprovalEditFileTargetHeader(
                        path: item.path,
                        projectDirectory: projectDirectory,
                        relativeTo: sessionDirectory
                    )
                }
            }
        } else if let sessionDirectory, !sessionDirectory.isEmpty {
            ApprovalFlatPathRow(
                icon: "folder",
                path: sessionDirectory,
                projectDirectory: projectDirectory,
                identifier: "approval-working-directory"
            )
        }
    }

    @ViewBuilder
    private var coreContentSection: some View {
        switch category {
        case .command:
            if let commandText {
                CommandApprovalPreview(command: commandText, wrapsLines: $wrapsPreviewLines)
            } else if !expired, context?.awaitingToolDetails == true {
                awaitingDetailsNotice
            }
        case .edit:
            if !diffGroups.isEmpty {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
                    ForEach(diffGroups) { group in
                        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                            ApprovalEditFileTargetHeader(
                                path: group.path,
                                projectDirectory: projectDirectory,
                                relativeTo: sessionDirectory
                            )
                            ApprovalUnifiedDiffCard(
                                changes: group.changes,
                                maxHeight: max(180, ApprovalSheetLayout.previewLineHeight(typography: typography) * 14)
                            )
                        }
                    }
                }
            } else if !expired, context?.awaitingToolDetails == true {
                awaitingDetailsNotice
            }
        }
    }

    private var awaitingDetailsNotice: some View {
        Text("等待操作详情")
            .zivviFont(.callout)
            .foregroundStyle(ZivviTheme.secondaryText)
            .padding(ZivviSpacing.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .approvalContentSurface()
    }

    private var technicalDetailsSection: some View {
        let identity = resolvedToolIdentity
        let showsSessionDirectory = sessionDirectory != nil && (category == .edit || distinctWorkingDirectory != nil)
        let showsExpiredOptions = expired && !expiredOptionNames.isEmpty
        let hasMetadataGrid = identity.name != nil || identity.kind != nil || commandTimeout != nil
            || showsSessionDirectory || showsExpiredOptions
        let expandedBinding = Binding(
            get: { technicalDetailsExpanded },
            set: { newValue in
                if reduceMotion {
                    technicalDetailsExpanded = newValue
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        technicalDetailsExpanded = newValue
                    }
                }
            }
        )
        return DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                if hasMetadataGrid {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: ZivviSpacing.dialogLabelGap) {
                        if let name = identity.name {
                            technicalDetailRow("Tool") {
                                Text(verbatim: name)
                                    .zivviFont(.caption, design: .monospaced)
                                    .foregroundStyle(ZivviTheme.primaryText)
                                    .textSelection(.enabled)
                            }
                        }
                        if let kind = identity.kind {
                            technicalDetailRow("Action") {
                                Text(verbatim: kind)
                                    .zivviFont(.caption, design: .monospaced)
                                    .foregroundStyle(ZivviTheme.primaryText)
                                    .textSelection(.enabled)
                            }
                        }
                        if showsSessionDirectory, let sessionDirectory {
                            let displayed = ApprovalPathFormatter.displayPath(sessionDirectory, projectDirectory: projectDirectory)
                            technicalDetailRow("会话目录") {
                                Text(verbatim: displayed)
                                    .zivviFont(.caption, design: .monospaced)
                                    .foregroundStyle(ZivviTheme.primaryText)
                                    .textSelection(.enabled)
                                    .help(sessionDirectory)
                            }
                        }
                        if let commandTimeout {
                            technicalDetailRow("执行超时") {
                                Text("\(commandTimeout.formatted()) 秒")
                                    .zivviFont(.caption)
                                    .foregroundStyle(ZivviTheme.primaryText)
                            }
                        }
                        if showsExpiredOptions {
                            technicalDetailRow("选项") {
                                Text(verbatim: expiredOptionNames.joined(separator: " · "))
                                    .zivviFont(.caption)
                                    .foregroundStyle(ZivviTheme.secondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let rawInput = context?.rawInputJSON {
                    ApprovalJSONPreview(json: rawInput, wrapsLines: $wrapsRawInputLines)
                }
            }
            .padding(.top, ZivviSpacing.dialogItemGap)
        } label: {
            Text("技术详情")
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.secondaryText)
                .padding(.trailing, IconButtonLabel.side + 6)
                .frame(minHeight: IconButtonLabel.side, alignment: .leading)
        }
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .leading, showsHoverBackground: false,
                                                  showsPressedBackground: false))
        .overlay(alignment: .topTrailing) {
            if !technicalDetailsExpanded, let rawInput = context?.rawInputJSON {
                ApprovalHoverCopy(text: rawInput, title: "复制原始参数", identifier: "approval-raw-input-copy",
                                  hovered: rawInputDisclosureHovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { rawInputDisclosureHovered = $0 }
        .accessibilityIdentifier("approval-raw-input")
    }

    private func technicalDetailRow<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder value: () -> Content
    ) -> some View {
        GridRow {
            Text(label)
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.secondaryText)
                .gridColumnAlignment(.leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UnifiedExpiredApprovalFooter: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZivviDivider(color: ZivviTheme.subtleDivider)
                .padding(.horizontal, ApprovalSheetLayout.inset)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "dialog.close", defaultValue: "关闭"), action: close)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined,
                                                        outlineColor: ZivviTheme.selectionBorder.opacity(0.7)))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("interaction-close-expired")
            }
            .padding(.horizontal, ApprovalSheetLayout.inset)
            .padding(.vertical, 12)
        }
    }
}

private struct ApprovalFlatPathRow: View {
    let icon: String
    let path: String
    let projectDirectory: String?
    var relativeTo: String? = nil
    let identifier: String

    var body: some View {
        let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: relativeTo)
        let displayed = ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory, includesProjectName: true)
        ApprovalCopyArea(text: absolute, title: "复制路径", identifier: "\(identifier)-copy", alignment: .center) {
            HStack(alignment: .center, spacing: 6) {
                LightningIconView(systemName: icon, size: 13)
                    .frame(width: 14, alignment: .center)
                Text(verbatim: displayed)
                    .zivviFont(.callout)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(absolute)
                    .accessibilityIdentifier(identifier)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ApprovalEditFileTargetHeader: View {
    let path: String
    let projectDirectory: String?
    let relativeTo: String?

    var body: some View {
        let absolute = ApprovalPathFormatter.absolutePath(path, relativeTo: relativeTo)
        let displayed = ApprovalPathFormatter.displayPath(absolute, projectDirectory: projectDirectory, includesProjectName: true)
        let components = splitTargetComponents(displayed: displayed)
        ApprovalCopyArea(text: absolute, title: "复制路径", identifier: "approval-file-path-copy", alignment: .center) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                if let directory = components.directory {
                    HStack(alignment: .center, spacing: 6) {
                        LightningIconView(.folder, size: 13)
                            .frame(width: 14, alignment: .center)
                        Text(verbatim: directory)
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    LightningIconView(.docText, size: 13)
                        .frame(width: 14, alignment: .center)
                    Text(verbatim: components.fileName)
                        .zivviFont(.callout, weight: .medium)
                        .foregroundStyle(ZivviTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .help(absolute)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("approval-file-path")
        }
    }

    private func splitTargetComponents(displayed: String) -> (directory: String?, fileName: String) {
        let nsPath = displayed as NSString
        let fileName = nsPath.lastPathComponent
        let parent = nsPath.deletingLastPathComponent
        guard !parent.isEmpty, !fileName.isEmpty else {
            return (nil, displayed)
        }
        if parent.hasPrefix("/") {
            // Preserve absolute external directory format without shortening.
            return (parent, fileName)
        }
        let formatted = parent.split(separator: "/").joined(separator: " / ")
        return (formatted.isEmpty ? nil : formatted, fileName)
    }
}

struct ApprovalUnifiedDiffCard: View {
    let changes: [RuntimePermissionContext.FileDiff]
    var maxHeight: CGFloat = 260
    var pasteboard: NSPasteboard? = nil

    @Environment(\.zivviTypography) private var typography
    @State private var cache = DiffPresentationCache()
    @State private var expandedSegmentKeys: Set<String> = []
    @State private var expandAllContext = false

    private static let inlineRowRenderingLimit = 400
    private static let inlineHighlightLineLimit = 200
    private static let inlineHighlightCharacterLimit = 2_000

    @MainActor private final class DiffPresentationCache {
        private var cachedChanges: [RuntimePermissionContext.FileDiff]?
        private var cachedPresentation: ApprovalDiffPresentation?
        private var cachedLargeDiff: (key: LargeDiffCacheKey, text: NSAttributedString)?

        func presentation(for changes: [RuntimePermissionContext.FileDiff]) -> ApprovalDiffPresentation {
            if cachedChanges == changes, let cachedPresentation {
                return cachedPresentation
            }
            let built = ApprovalDiffPresentation.build(
                changes: changes,
                inlineHighlightLineLimit: ApprovalUnifiedDiffCard.inlineHighlightLineLimit,
                inlineHighlightCharacterLimit: ApprovalUnifiedDiffCard.inlineHighlightCharacterLimit
            )
            cachedChanges = changes
            cachedPresentation = built
            cachedLargeDiff = nil
            return built
        }

        func largeDiffAttributedText(
            key: LargeDiffCacheKey,
            build: () -> NSAttributedString
        ) -> NSAttributedString {
            if cachedLargeDiff?.key == key, let existing = cachedLargeDiff?.text {
                return existing
            }
            let built = build()
            cachedLargeDiff = (key, built)
            return built
        }
    }

    private struct LargeDiffCacheKey: Equatable {
        let presentation: ApprovalDiffPresentation
        let expandedSegmentKeys: Set<String>
        let expandAllContext: Bool
        let typography: ZivviTypography
    }

    init(
        changes: [RuntimePermissionContext.FileDiff],
        maxHeight: CGFloat = 260,
        pasteboard: NSPasteboard? = nil
    ) {
        self.changes = changes
        self.maxHeight = maxHeight
        self.pasteboard = pasteboard
    }

    private struct ApprovalDiffPresentation: Equatable {
        struct SegmentEntry: Equatable {
            let id: Int
            let isCollapsedContext: Bool
            let lines: [ToolEditDiff.Line]
            let inlineHighlights: [Int: ToolEditDiff.InlineChangedRanges]
        }

        struct ChangeGroup: Equatable {
            let segments: [SegmentEntry]

            var lineCount: Int { segments.reduce(0) { $0 + $1.lines.count } }
        }

        let groups: [ChangeGroup]
        let additions: Int
        let deletions: Int
        let hasCollapsedContext: Bool
        let collapsedLineCount: Int
        let copyText: String

        @MainActor static func build(
            changes: [RuntimePermissionContext.FileDiff],
            inlineHighlightLineLimit: Int,
            inlineHighlightCharacterLimit: Int
        ) -> ApprovalDiffPresentation {
            var groups: [ChangeGroup] = []
            var additions = 0
            var deletions = 0
            var hasCollapsedContext = false
            var collapsedLineCount = 0
            var copyBlocks: [String] = []

            for change in changes {
                let allLines = ToolEditDiff.approvalLines(oldText: change.oldText, newText: change.newText)
                for line in allLines {
                    switch line.kind {
                    case .insertion: additions += 1
                    case .removal: deletions += 1
                    case .context: break
                    }
                }
                let rawSegments = ToolEditDiff.approvalSegments(from: allLines)
                var entries: [SegmentEntry] = []
                var changeCopyBlocks: [String] = []
                for segment in rawSegments {
                    let isCollapsed: Bool
                    switch segment.content {
                    case .lines:
                        isCollapsed = false
                        changeCopyBlocks.append(ToolEditDiff.unifiedText(for: segment.lines))
                    case .collapsedContext:
                        isCollapsed = true
                        hasCollapsedContext = true
                        collapsedLineCount += segment.lines.count
                    }
                    let shouldComputeInline = !isCollapsed
                        && segment.lines.count <= inlineHighlightLineLimit
                        && segment.lines.allSatisfy { $0.text.count <= inlineHighlightCharacterLimit }
                    let highlights = shouldComputeInline ? ApprovalUnifiedDiffCard.pairedInlineHighlights(for: segment.lines) : [:]
                    entries.append(SegmentEntry(
                        id: segment.id,
                        isCollapsedContext: isCollapsed,
                        lines: segment.lines,
                        inlineHighlights: highlights
                    ))
                }
                if changeCopyBlocks.isEmpty && !allLines.isEmpty {
                    changeCopyBlocks.append(ToolEditDiff.unifiedText(for: allLines))
                }
                if !changeCopyBlocks.isEmpty {
                    copyBlocks.append(changeCopyBlocks.joined(separator: "\n...\n"))
                }
                groups.append(ChangeGroup(segments: entries))
            }

            return ApprovalDiffPresentation(
                groups: groups,
                additions: additions,
                deletions: deletions,
                hasCollapsedContext: hasCollapsedContext,
                collapsedLineCount: collapsedLineCount,
                copyText: copyBlocks.joined(separator: "\n...\n")
            )
        }
    }

    private func isSegmentExpanded(groupIndex: Int, segmentID: Int) -> Bool {
        expandAllContext || expandedSegmentKeys.contains("\(groupIndex)-\(segmentID)")
    }

    var body: some View {
        let presentation = cache.presentation(for: changes)
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack(spacing: 8) {
                Text("Diff")
                    .zivviFont(.caption, weight: .semibold)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if presentation.hasCollapsedContext {
                    Button {
                        if expandAllContext {
                            expandAllContext = false
                            expandedSegmentKeys.removeAll()
                        } else {
                            expandAllContext = true
                        }
                    } label: {
                        Text(expandAllContext ? LocalizedStringKey("收起上下文") : LocalizedStringKey("展开上下文"))
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false, height: IconButtonLabel.side))
                    .accessibilityIdentifier("edit-approval-toggle-context")
                }
                if presentation.additions > 0 || presentation.deletions > 0 {
                    HStack(spacing: 6) {
                        if presentation.additions > 0 {
                            Text(verbatim: "+\(presentation.additions)")
                                .foregroundStyle(ZivviTheme.diffAddition)
                        }
                        if presentation.deletions > 0 {
                            Text(verbatim: "−\(presentation.deletions)")
                                .foregroundStyle(ZivviTheme.diffDeletion)
                        }
                    }
                    .zivviFont(.caption, weight: .medium, design: .monospaced)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statsAccessibilityLabel(additions: presentation.additions,
                                                                deletions: presentation.deletions))
                    .accessibilityIdentifier("edit-approval-diff-stats")
                }
                ApprovalCopyButton(
                    text: presentation.copyText,
                    title: "复制差异",
                    identifier: "edit-approval-copy",
                    pasteboard: pasteboard
                )
            }
            .padding(.horizontal, ZivviSpacing.contentInset)
            .padding(.top, ZivviSpacing.contentInset)

            if presentation.groups.reduce(0, { $0 + $1.lineCount }) > Self.inlineRowRenderingLimit {
                largeDiffBody(presentation: presentation)
                    .padding(.horizontal, ZivviSpacing.contentInset)
                    .padding(.bottom, ZivviSpacing.contentInset)
            } else {
                diffBody(presentation: presentation)
                    .padding(.bottom, ZivviSpacing.contentInset)
            }
        }
        .approvalContentSurface()
        .accessibilityIdentifier("edit-approval-preview")
        .onChange(of: changes) { _, _ in
            expandedSegmentKeys.removeAll()
            expandAllContext = false
        }
    }

    private func largeDiffCacheKey(for presentation: ApprovalDiffPresentation) -> LargeDiffCacheKey {
        LargeDiffCacheKey(
            presentation: presentation,
            expandedSegmentKeys: expandedSegmentKeys,
            expandAllContext: expandAllContext,
            typography: typography
        )
    }

    private func statsAccessibilityLabel(additions: Int, deletions: Int) -> Text {
        if additions > 0 && deletions > 0 {
            return Text("新增 \(additions) 行，删除 \(deletions) 行")
        } else if additions > 0 {
            return Text("新增 \(additions) 行")
        } else {
            return Text("删除 \(deletions) 行")
        }
    }

    @ViewBuilder
    private func largeDiffBody(presentation: ApprovalDiffPresentation) -> some View {
        let key = largeDiffCacheKey(for: presentation)
        let rendered = cache.largeDiffAttributedText(key: key) {
            buildLargeDiffAttributedText(presentation: presentation)
        }
        ApprovalTextScrollView(
            text: rendered.string,
            maxHeight: maxHeight,
            nativeAttributedText: rendered,
            wrapsLines: false
        )
    }

    private static func dynamicColor(_ color: Color, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).withAlphaComponent(alpha)
            }
            return resolved
        }
    }

    private func buildLargeDiffAttributedText(presentation: ApprovalDiffPresentation) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: typography.pointSize(for: .callout), weight: .regular)
        let primary = Self.dynamicColor(ZivviTheme.primaryText)
        let secondary = Self.dynamicColor(ZivviTheme.secondaryText)
        let tertiary = Self.dynamicColor(ZivviTheme.tertiaryText)
        let additionColor = ZivviTheme.diffAdditionColor
        let deletionColor = ZivviTheme.diffDeletionColor
        let additionBg = ZivviTheme.diffAdditionBackgroundColor
        let deletionBg = ZivviTheme.diffDeletionBackgroundColor

        let result = NSMutableAttributedString()
        var isFirstLine = true

        func appendLine(
            _ text: String,
            prefix: String,
            prefixColor: NSColor,
            textColor: NSColor,
            background: NSColor?,
            ending: ToolEditDiff.Ending? = nil
        ) {
            if !isFirstLine {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            isFirstLine = false
            var prefixAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: prefixColor]
            var textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            if let background {
                prefixAttrs[.backgroundColor] = background
                textAttrs[.backgroundColor] = background
            }
            result.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
            result.append(NSAttributedString(string: text, attributes: textAttrs))
            if let ending {
                var endingAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondary]
                if let background {
                    endingAttrs[.backgroundColor] = background
                }
                result.append(NSAttributedString(string: " [\(ending.label)]", attributes: endingAttrs))
            }
        }

        for (groupIndex, group) in presentation.groups.enumerated() {
            if groupIndex > 0 {
                appendLine("⋯", prefix: "", prefixColor: tertiary, textColor: tertiary, background: nil)
            }
            if group.segments.isEmpty {
                appendLine(String(localized: "（无文本差异）"), prefix: "", prefixColor: secondary, textColor: secondary, background: nil)
                continue
            }
            for segment in group.segments {
                if segment.isCollapsedContext && !isSegmentExpanded(groupIndex: groupIndex, segmentID: segment.id) {
                    let hint = String(localized: "⋯ 已折叠 \(segment.lines.count) 行未修改上下文")
                    appendLine(hint, prefix: "", prefixColor: tertiary, textColor: tertiary, background: nil)
                    continue
                }
                for line in segment.lines {
                    switch line.kind {
                    case .context:
                        appendLine(line.text, prefix: "  ", prefixColor: tertiary, textColor: secondary, background: nil, ending: line.ending)
                    case .removal:
                        appendLine(line.text, prefix: "− ", prefixColor: deletionColor, textColor: primary, background: deletionBg, ending: line.ending)
                    case .insertion:
                        appendLine(line.text, prefix: "+ ", prefixColor: additionColor, textColor: primary, background: additionBg, ending: line.ending)
                    }
                }
            }
        }
        return result
    }

    @ViewBuilder
    private func diffBody(presentation: ApprovalDiffPresentation) -> some View {
        ApprovalDiffViewport(maxHeight: maxHeight, lineHeight: ApprovalSheetLayout.previewLineHeight(typography: typography)) {
            diffRows(presentation: presentation, viewportWidth: 0).hidden().accessibilityHidden(true)
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    diffRows(presentation: presentation, viewportWidth: viewport.size.width)
                        .textSelection(.enabled)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
            }
        }
    }

    private func diffRows(presentation: ApprovalDiffPresentation, viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.groups.indices, id: \.self) { groupIndex in
                if groupIndex > 0 {
                    HStack(spacing: 6) {
                        Text(verbatim: "⋯")
                            .zivviFont(.caption, design: .monospaced)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                    }
                    .padding(.horizontal, ZivviSpacing.contentInset)
                    .padding(.vertical, 3)
                }
                let group = presentation.groups[groupIndex]
                if group.segments.isEmpty {
                    Text("（无文本差异）")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .padding(.horizontal, ZivviSpacing.contentInset)
                        .padding(.vertical, 4)
                } else {
                    ForEach(group.segments, id: \.id) { segment in
                        if segment.isCollapsedContext && !isSegmentExpanded(groupIndex: groupIndex, segmentID: segment.id) {
                            Button {
                                expandedSegmentKeys.insert("\(groupIndex)-\(segment.id)")
                            } label: {
                                HStack(spacing: 6) {
                                    Text(verbatim: "⋯")
                                        .zivviFont(.caption, design: .monospaced)
                                    Text("展开 \(segment.lines.count) 行未修改上下文")
                                        .zivviFont(.caption)
                                }
                                .foregroundStyle(ZivviTheme.secondaryText)
                                .padding(.horizontal, ZivviSpacing.contentInset)
                                .padding(.vertical, 4)
                                .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("edit-approval-expand-context-\(groupIndex)-\(segment.id)")
                        } else {
                            ForEach(segment.lines.indices, id: \.self) { lineIndex in
                                ApprovalUnifiedDiffLineRow(
                                    line: segment.lines[lineIndex],
                                    inlineRanges: segment.inlineHighlights[lineIndex],
                                    minimumWidth: viewportWidth
                                )
                            }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private static func pairedInlineHighlights(for lines: [ToolEditDiff.Line]) -> [Int: ToolEditDiff.InlineChangedRanges] {
        var result: [Int: ToolEditDiff.InlineChangedRanges] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removal else {
                index += 1
                continue
            }
            let removalStart = index
            while index < lines.count, lines[index].kind == .removal { index += 1 }
            let removalEnd = index
            let insertionStart = index
            while index < lines.count, lines[index].kind == .insertion { index += 1 }
            let insertionEnd = index

            let removalCount = removalEnd - removalStart
            let insertionCount = insertionEnd - insertionStart
            if removalCount > 0 && removalCount == insertionCount {
                for offset in 0..<removalCount {
                    let rIndex = removalStart + offset
                    let iIndex = insertionStart + offset
                    let ranges = ToolEditDiff.inlineChangedRanges(
                        oldLine: lines[rIndex].text,
                        newLine: lines[iIndex].text
                    )
                    if ranges.oldRange != nil || ranges.newRange != nil {
                        result[rIndex] = ranges
                        result[iIndex] = ranges
                    }
                }
            }
        }
        return result
    }
}

private struct ApprovalUnifiedDiffLineRow: View {
    let line: ToolEditDiff.Line
    let inlineRanges: ToolEditDiff.InlineChangedRanges?
    let minimumWidth: CGFloat

    private var marker: String {
        switch line.kind {
        case .context: "  "
        case .removal: "− "
        case .insertion: "+ "
        }
    }

    private var accentColor: Color? {
        switch line.kind {
        case .context: nil
        case .removal: ZivviTheme.diffDeletion
        case .insertion: ZivviTheme.diffAddition
        }
    }

    var body: some View {
        Text(renderedAttributedLine)
            .zivviFont(.callout, design: .monospaced)
            .padding(.horizontal, ZivviSpacing.contentInset)
            .padding(.vertical, 2)
            .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
            .background(accentColor?.opacity(0.10) ?? .clear)
            .accessibilityLabel(accessibilityPrefix + line.text)
    }

    private var accessibilityPrefix: String {
        switch line.kind {
        case .context: ""
        case .removal: String(localized: "删除：")
        case .insertion: String(localized: "新增：")
        }
    }

    private var renderedAttributedLine: AttributedString {
        var prefix = AttributedString(marker)
        prefix.swiftUI.foregroundColor = accentColor ?? ZivviTheme.tertiaryText

        var code = AttributedString(line.text)
        code.swiftUI.foregroundColor = line.kind == .context ? ZivviTheme.secondaryText : ZivviTheme.primaryText

        if let accentColor {
            let changedRange = line.kind == .removal ? inlineRanges?.oldRange : inlineRanges?.newRange
            if let changedRange,
               let attrStart = AttributedString.Index(changedRange.lowerBound, within: code),
               let attrEnd = AttributedString.Index(changedRange.upperBound, within: code) {
                code[attrStart..<attrEnd].swiftUI.backgroundColor = accentColor.opacity(0.24)
            }
        }

        var result = prefix + code
        if let ending = line.ending {
            var badge = AttributedString(" [\(ending.label)]")
            badge.swiftUI.foregroundColor = ZivviTheme.secondaryText
            result += badge
        }
        return result
    }
}

private struct ApprovalDiffViewport: Layout {
    let maxHeight: CGFloat
    let lineHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let contentSize = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: nil))
        return CGSize(width: width ?? contentSize.width, height: min(maxHeight, max(lineHeight, ceil(contentSize.height))))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)
        subviews[0].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: nil, height: nil))
        subviews[1].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
