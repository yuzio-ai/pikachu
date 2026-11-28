import AppKit
import SwiftUI
import OrchestrationCore

/// Full-width Editor Area for Files (Markdown preview/edit, code/text edit, image preview),
/// Git Diffs, Historical Tool Diffs, and Commit Details. Contains NO redundant file tree.
struct WorkbenchEditorArea: View {
    @Bindable var tabsModel: WorkbenchTabsModel
    let fileOpen: FileOpenConfiguration
    let gitStore: GitStatusStore
    let canOpenExternally: @MainActor () -> Bool

    @Environment(\.zivviTypography) private var typography
    @State private var focusRequest = 0
    @State private var copiedPath = false
    @State private var copiedDiff = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabsModel.activeEditorTab {
                contextBar(for: tab)
                ZivviDivider(color: ZivviTheme.subtleDivider)

                if let conflict = tab.externalConflict {
                    conflictBanner(conflict, for: tab)
                    ZivviDivider(color: ZivviTheme.subtleDivider)
                }
                if let saveError = tab.saveError {
                    HStack(spacing: 8) {
                        LightningIconView(.exclamationmarkTriangle, size: 13)
                        Text(verbatim: saveError)
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.errorText)
                        Spacer(minLength: 0)
                        Button("关闭") { tab.saveError = nil }
                            .buttonStyle(FlatControlButtonStyle())
                            .zivviFont(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ZivviTheme.mutedSurface)
                    ZivviDivider(color: ZivviTheme.subtleDivider)
                }

                contentBody(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FlatEmptyState(
                    "未打开文件或变更",
                    systemImage: "doc.text",
                    description: Text("从左侧项目的「文件」或「Git」模式选择条目以在此阅读、编辑或审查。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ZivviTheme.pageBackground)
        .disabled(tabsModel.isPreparingToTerminate)
        .accessibilityIdentifier("workbench-editor-area")
    }

    @ViewBuilder
    private func contextBar(for tab: WorkbenchTabsModel.EditorTab) -> some View {
        HStack(spacing: 8) {
            pathBreadcrumb(for: tab)
            Spacer(minLength: 8)
            contextActions(for: tab)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(ZivviTheme.pageBackground)
    }

    @ViewBuilder
    private func pathBreadcrumb(for tab: WorkbenchTabsModel.EditorTab) -> some View {
        switch tab.kind {
        case .file(_, let rootPath, let projectName, let path, _):
            let fullPath = URL(fileURLWithPath: rootPath, isDirectory: true).appending(path: path.relativePath).path
            HStack(spacing: 5) {
                Text(verbatim: "\(projectName) / \(path.relativePath)")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(fullPath)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullPath, forType: .string)
                    copiedPath = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPath = false
                    }
                } label: {
                    LightningIconView(copiedPath ? .checkmark : .docOnDoc, size: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .help("复制完整路径")
                .accessibilityLabel("复制完整路径")
            }
        case .gitDiff(_, _, let projectName, let path, let previousPath, let scope, _):
            HStack(spacing: 6) {
                Text(verbatim: "\(projectName) / \(previousPath.map { "\($0) → \(path)" } ?? path)")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: scope.comparisonLabel)
                    .zivviFont(.caption2, weight: .medium)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ZivviTheme.mutedSurface, in: Capsule())
            }
        case .toolDiff(_, let projectName, let title):
            HStack(spacing: 6) {
                Text(verbatim: [projectName, tab.toolDiffPath].compactMap { $0 }.joined(separator: " / "))
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: title)
                    .zivviFont(.caption2, weight: .medium)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ZivviTheme.mutedSurface, in: Capsule())
            }
        case .commit(_, _, let projectName, _, let shortHash, _):
            HStack(spacing: 6) {
                Text(verbatim: "\(projectName) · Commit \(shortHash)")
                    .zivviFont(.caption, weight: .medium)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func contextActions(for tab: WorkbenchTabsModel.EditorTab) -> some View {
        switch tab.kind {
        case .file(_, let rootPath, _, _, _):
            HStack(spacing: 6) {
                if tab.isDirty {
                    Button {
                        Task {
                            _ = await tabsModel.saveTab(tab) {
                                gitStore.refresh(directory: rootPath, force: true)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if tab.isSaving {
                                FlatProgressView().controlSize(.mini)
                            }
                            Text("保存")
                                .zivviFont(.caption, weight: .medium)
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .prominent, height: 24))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(tab.isSaving)
                    .accessibilityIdentifier("editor-save-file")
                }

                if tab.kind.isMarkdownFile {
                    HStack(spacing: 2) {
                        modeButton("预览", active: tab.isMarkdownPreview) {
                            tab.isMarkdownPreview = true
                        }
                        modeButton("编辑", active: !tab.isMarkdownPreview) {
                            tab.isMarkdownPreview = false
                            focusRequest += 1
                        }
                    }
                    .padding(2)
                    .background(ZivviTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityIdentifier("markdown-mode-switcher")
                }

                if !tab.kind.isImageFile && !(tab.kind.isMarkdownFile && tab.isMarkdownPreview) {
                    Button {
                        tab.wrapsLines.toggle()
                    } label: {
                        LightningIconView(.arrowTurnDownLeft, size: 12)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(FlatControlButtonStyle(isSelected: tab.wrapsLines, inset: false, cornerRadius: 5))
                    .help(tab.wrapsLines ? "关闭自动换行" : "开启自动换行")
                    .accessibilityLabel(tab.wrapsLines ? "关闭自动换行" : "开启自动换行")
                }

                Button {
                    tabsModel.reloadTab(tab)
                } label: {
                    LightningIconView(.arrowClockwise, size: 12)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .help("从磁盘刷新文件")
                .accessibilityLabel("刷新文件")

                Button {
                    guard let request = tabsModel.externalOpenRequest(for: tab, canOpen: canOpenExternally) else { return }
                    Task { await TranscriptFileOpener.open(request, configuration: fileOpen) }
                } label: {
                    LightningIconView(.arrowUpForwardSquare, size: 12)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .disabled(tab.openTarget == nil || !canOpenExternally())
                .help("在外部应用中打开")
                .accessibilityLabel("在外部应用中打开")
            }

        case .gitDiff:
            HStack(spacing: 6) {
                if let diff = tab.diffDocument, !diff.isBinary {
                    GitInlineStatBadge(added: diff.additions, deleted: diff.deletions)
                }
                if let raw = tab.diffDocument?.rawText, !raw.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(raw, forType: .string)
                        copiedDiff = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedDiff = false
                        }
                    } label: {
                        LightningIconView(copiedDiff ? .checkmark : .docOnDoc, size: 12)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                    .help("复制 Unified Diff")
                    .accessibilityLabel("复制 Unified Diff")
                }
                Button {
                    tabsModel.reloadTab(tab)
                } label: {
                    LightningIconView(.arrowClockwise, size: 12)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .help("刷新 Diff")
                .accessibilityLabel("刷新 Diff")
            }

        case .toolDiff:
            if let lines = tab.toolDiff?.lines {
                let addCount = lines.count { $0.kind == .insertion }
                let delCount = lines.count { $0.kind == .removal }
                HStack(spacing: 6) {
                    GitInlineStatBadge(added: addCount, deleted: delCount)
                    Button {
                        guard let currentLines = tab.toolDiff?.lines else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ToolEditDiff.unifiedText(for: currentLines), forType: .string)
                    } label: {
                        LightningIconView(.docOnDoc, size: 12)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                    .help("复制历史 Diff")
                    .accessibilityLabel("复制历史 Diff")
                }
            }

        case .commit(_, _, _, let hash, _, _):
            HStack(spacing: 6) {
                if let detail = tab.commitDetail,
                   let add = detail.summary.additions,
                   let del = detail.summary.deletions {
                    GitInlineStatBadge(added: add, deleted: del)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hash, forType: .string)
                } label: {
                    LightningIconView(.docOnDoc, size: 12)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                .help("复制完整 Commit SHA")
                .accessibilityLabel("复制 Commit SHA")
            }
        }
    }

    private func modeButton(_ title: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .zivviFont(.caption2, weight: active ? .medium : .regular)
                .foregroundStyle(active ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(active ? ZivviTheme.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func conflictBanner(_ conflict: WorkbenchTabsModel.ExternalConflict,
                                for tab: WorkbenchTabsModel.EditorTab) -> some View {
        HStack(spacing: 8) {
            LightningIconView(.exclamationmarkTriangleFill, size: 14)
            Text(verbatim: conflict.message)
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("放弃编辑并重新加载") {
                tabsModel.reloadTab(tab, discardDraft: true)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 24))
            .zivviFont(.caption2)
            Button("覆盖保存") {
                guard let revision = conflict.diskRevision else { return }
                Task {
                    _ = await tabsModel.saveTab(tab, overwriteRevision: revision) {
                        if let root = tab.kind.rootPath {
                            gitStore.refresh(directory: root, force: true)
                        }
                    }
                }
            }
            .buttonStyle(FlatControlButtonStyle(treatment: .prominent, height: 24))
            .zivviFont(.caption2)
            .disabled(conflict.diskRevision == nil || tab.isSaving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ZivviTheme.warningSurface)
    }

    @ViewBuilder
    private func contentBody(for tab: WorkbenchTabsModel.EditorTab) -> some View {
        switch tab.kind {
        case .file:
            fileContentView(for: tab)
        case .gitDiff:
            if tab.isLoadingDiff && tab.diffDocument == nil {
                FlatProgressView("正在生成 Diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = tab.diffDocument {
                EditorUnifiedDiffView(document: diff)
            } else {
                FlatEmptyState("无可用差异", systemImage: "arrow.left.arrow.right",
                               description: Text("当前变更没有可展示的文本差异。"))
            }
        case .toolDiff(_, _, let title):
            if let diff = tab.toolDiff {
                EditorToolDiffView(path: diff.path, title: title, lines: diff.lines)
            } else {
                FlatEmptyState("无可用差异", systemImage: "arrow.left.arrow.right",
                               description: Text("当前变更没有可展示的文本差异。"))
            }
        case .commit:
            if tab.isLoadingCommit && tab.commitDetail == nil {
                FlatProgressView("正在读取提交详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = tab.commitDetail {
                EditorCommitDetailView(detail: detail)
            } else {
                FlatEmptyState("无法读取提交详情", systemImage: "exclamationmark.triangle",
                               description: Text("请确认 Git 仓库状态正常后重试。"))
            }
        }
    }

    @ViewBuilder
    private func fileContentView(for tab: WorkbenchTabsModel.EditorTab) -> some View {
        switch tab.contentState {
        case .loading:
            FlatProgressView("正在读取文件…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let cgImage):
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 960, maxHeight: 720)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let issue):
            FlatEmptyState("无法预览文件", systemImage: "doc.text", description: Text(verbatim: issue.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let savedDoc):
            if tab.kind.isMarkdownFile && tab.isMarkdownPreview {
                let text = tab.currentText ?? savedDoc.text
                GeometryReader { proxy in
                    let widthTier = MarkdownWidth(proxy.size.width)
                    let contentWidth = widthTier.editorialContentWidth(in: proxy.size.width)
                    ScrollView {
                        MarkdownContent(
                            text: text,
                            streaming: false,
                            width: contentWidth,
                            profile: .editorial,
                            hostWidth: proxy.size.width,
                            linkPolicy: .projectPreview,
                            imageLoader: tabsModel.markdownImageLoader(for: tab)
                        )
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(widthTier.editorialInsets)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else {
                let doc = tab.currentEditableDocument ?? savedDoc
                ProjectFileTextView(
                    document: doc,
                    wrapsLines: tab.wrapsLines,
                    focusRequest: focusRequest,
                    targetLine: tab.targetLine,
                    isEditable: !tabsModel.isPreparingToTerminate,
                    onTextChange: { updated in
                        tabsModel.updateDraft(updated, for: tab)
                    }
                )
            }
        }
    }
}

/// Renders a live Git Unified Diff with real old/new line numbers, subtle red/green row tints,
/// and inline character-level highlights on paired deletion/addition lines.
struct EditorUnifiedDiffView: View {
    let document: GitDiffDocument
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let error = document.errorMessage {
            FlatEmptyState("无法显示 Diff", systemImage: "exclamationmark.triangle", description: Text(verbatim: error))
        } else if document.isBinary {
            FlatEmptyState("二进制文件变更", systemImage: "doc.zipper",
                           description: Text("无法以文本形式展示二进制文件的逐行差异。"))
        } else if document.isEmpty {
            FlatEmptyState("没有文本差异", systemImage: "checkmark.circle",
                           description: Text("当前比较基准（\(document.comparisonLabel)）下无逐行变更。"))
        } else {
            let inlineHighlights = computePairedInlineHighlights(document.lines)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.lines) { line in
                        diffRow(line, highlight: inlineHighlights[line.id])
                    }
                    if document.truncated {
                        Text("差异内容较长，仅展示前 \(document.lines.count) 行。")
                            .zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.warningText)
                            .padding(12)
                    }
                }
                .padding(.vertical, 8)
                .frame(minWidth: 520, alignment: .leading)
            }
            .textSelection(.enabled)
        }
    }

    private func diffRow(_ line: GitDiffLine, highlight: Range<String.Index>?) -> some View {
        let isDark = colorScheme == .dark
        let rowBG: Color = switch line.kind {
        case .addition: ZivviTheme.diffAddition.opacity(isDark ? 0.14 : 0.10)
        case .deletion: ZivviTheme.diffDeletion.opacity(isDark ? 0.15 : 0.10)
        case .hunkHeader: ZivviTheme.mutedSurface
        case .context, .meta: Color.clear
        }
        let marker: String = switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .hunkHeader, .meta: ""
        }
        let markerColor: Color = switch line.kind {
        case .addition: ZivviTheme.diffAddition
        case .deletion: ZivviTheme.diffDeletion
        default: ZivviTheme.tertiaryText
        }

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if line.kind == .hunkHeader || line.kind == .meta {
                Text(verbatim: line.text)
                    .zivviFont(.caption, design: .monospaced)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                Text(verbatim: line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(ZivviTheme.tertiaryText)
                    .padding(.trailing, 8)
                Text(verbatim: line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(ZivviTheme.tertiaryText)
                    .padding(.trailing, 10)
                Text(verbatim: marker)
                    .foregroundStyle(markerColor)
                    .frame(width: 14, alignment: .center)
                styledCodeText(line.text, kind: line.kind, highlight: highlight, isDark: isDark)
                    .padding(.trailing, 16)
            }
            Spacer(minLength: 0)
        }
        .zivviFont(.caption, design: .monospaced)
        .monospacedDigit()
        .padding(.vertical, 1.5)
        .background(rowBG)
    }

    private func styledCodeText(_ text: String, kind: GitDiffLine.Kind, highlight: Range<String.Index>?, isDark: Bool) -> Text {
        guard let highlight, kind == .addition || kind == .deletion else {
            return Text(verbatim: text).foregroundStyle(ZivviTheme.primaryText)
        }
        var attr = AttributedString(text)
        attr.foregroundColor = ZivviTheme.primaryText
        if let start = AttributedString.Index(highlight.lowerBound, within: attr),
           let end = AttributedString.Index(highlight.upperBound, within: attr),
           start < end {
            let tint = kind == .addition ? ZivviTheme.diffAddition : ZivviTheme.diffDeletion
            attr[start..<end].backgroundColor = tint.opacity(isDark ? 0.32 : 0.22)
        }
        return Text(attr)
    }

    private func computePairedInlineHighlights(_ lines: [GitDiffLine]) -> [Int: Range<String.Index>] {
        var result: [Int: Range<String.Index>] = [:]
        var i = 0
        while i + 1 < lines.count {
            if lines[i].kind == .deletion && lines[i + 1].kind == .addition {
                let ranges = ToolEditDiff.inlineChangedRanges(oldLine: lines[i].text, newLine: lines[i + 1].text)
                if let oldRange = ranges.oldRange { result[lines[i].id] = oldRange }
                if let newRange = ranges.newRange { result[lines[i + 1].id] = newRange }
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }
}

/// Renders a historical tool edit diff (explicitly distinct from live Git Diff).
struct EditorToolDiffView: View {
    let path: String
    let title: String
    let lines: [ToolEditDiff.Line]

    var body: some View {
        let converted = lines.enumerated().map { idx, line -> GitDiffLine in
            let kind: GitDiffLine.Kind = switch line.kind {
            case .context: .context
            case .insertion: .addition
            case .removal: .deletion
            }
            return GitDiffLine(id: idx, kind: kind, oldLineNumber: nil, newLineNumber: nil, text: line.text)
        }
        let doc = GitDiffDocument(
            path: path,
            previousPath: nil,
            scope: .workingTreeVsHEAD,
            comparisonLabel: title,
            status: .modified,
            additions: lines.count { $0.kind == .insertion },
            deletions: lines.count { $0.kind == .removal },
            isBinary: false,
            isEmpty: converted.isEmpty,
            truncated: false,
            rawText: ToolEditDiff.unifiedText(for: lines),
            lines: converted,
            errorMessage: nil
        )
        EditorUnifiedDiffView(document: doc)
    }
}

/// Renders a Git Commit detail tab: message metadata, changed file list, and per-file Unified Diffs.
struct EditorCommitDetailView: View {
    let detail: GitCommitDetail

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: detail.summary.subject)
                            .zivviFont(.title3, weight: .semibold)
                            .foregroundStyle(ZivviTheme.primaryText)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Text(verbatim: detail.summary.shortHash)
                                .zivviFont(.caption, design: .monospaced)
                                .foregroundStyle(ZivviTheme.secondaryText)
                            Text(verbatim: detail.summary.author)
                                .zivviFont(.caption)
                                .foregroundStyle(ZivviTheme.secondaryText)
                            Text(detail.summary.date, format: .dateTime.year().month().day().hour().minute())
                                .zivviFont(.caption)
                                .foregroundStyle(ZivviTheme.tertiaryText)
                        }
                        if !detail.body.isEmpty {
                            Text(verbatim: detail.body)
                                .zivviFont(.callout)
                                .foregroundStyle(ZivviTheme.secondaryText)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }

                    ZivviDivider(color: ZivviTheme.subtleDivider)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("变更文件（\(detail.files.count)）")
                            .zivviFont(.caption, weight: .semibold)
                            .foregroundStyle(ZivviTheme.secondaryText)
                        ForEach(detail.files) { file in
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("commit-diff-\(file.path)", anchor: .top)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    GitStatusCodeBadge(status: file.status)
                                    Text(verbatim: file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                                        .zivviFont(.caption, design: .monospaced)
                                        .foregroundStyle(ZivviTheme.primaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if file.stat.hasVisibleChange {
                                        GitInlineStatBadge(added: file.stat.added, deleted: file.stat.deleted)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
                        }
                    }

                    ForEach(detail.diffDocuments, id: \.path) { doc in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(verbatim: doc.path)
                                    .zivviFont(.caption, weight: .semibold, design: .monospaced)
                                    .foregroundStyle(ZivviTheme.primaryText)
                                Spacer(minLength: 4)
                                if !doc.isBinary {
                                    GitInlineStatBadge(added: doc.additions, deleted: doc.deletions)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(ZivviTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .id("commit-diff-\(doc.path)")

                            EditorUnifiedDiffView(document: doc)
                                .frame(minHeight: min(460, max(120, CGFloat(doc.lines.count) * 20 + 24)))
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}
