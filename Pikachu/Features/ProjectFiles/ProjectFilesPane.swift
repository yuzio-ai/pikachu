import Observation
import SwiftUI

@MainActor
@Observable
final class ProjectFilesControls {
    struct DirectoryFocusRequest: Equatable {
        let keyboard: Bool
        let accessibility: Bool
        private let id = UUID()
    }

    private(set) var openingID: UUID?
    @ObservationIgnored private(set) var visibilityRevision = UUID()
    var isOpen: Bool { openingID != nil }
    private(set) var keyboardOpenRequest = 0
    private(set) var directoryFocusRequest: DirectoryFocusRequest?
    var blocked = false
    var toolbarTrailingInset: CGFloat = 10
    var titlebarHostTrailingInset: CGFloat = 60

    func toggle(keyboard: Bool = false) {
        guard !blocked else { return }
        directoryFocusRequest = nil
        setOpeningID(isOpen ? nil : UUID())
        keyboardOpenRequest = isOpen && keyboard ? keyboardOpenRequest + 1 : 0
    }

    func open() {
        guard !blocked, !isOpen else { return }
        directoryFocusRequest = nil
        setOpeningID(UUID())
        keyboardOpenRequest = 0
    }

    func close() {
        directoryFocusRequest = nil
        setOpeningID(nil)
    }

    private func setOpeningID(_ id: UUID?) {
        guard id != openingID else { return }
        visibilityRevision = UUID()
        openingID = id
    }

    func focusDirectory(keyboard: Bool, accessibility: Bool) {
        directoryFocusRequest = DirectoryFocusRequest(keyboard: keyboard, accessibility: accessibility)
    }
}

struct ProjectFilesPane: View {
    @Bindable var model: ProjectFilesModel
    let root: ProjectFilesRoot?
    let layout: ProjectFilesLayout
    let keyboardOpenRequest: Int
    var toolbarTrailingInset: CGFloat = 10
    var windowControls: ProjectFilesControls?
    var fileOpen: FileOpenConfiguration = .init()
    var canLaunch: @MainActor () -> Bool = { true }
    let close: () -> Void

    @FocusState private var focus: FocusTarget?
    @AccessibilityFocusState private var accessibilityFocus: FocusTarget?
    @State private var previewFocusRequest = 0
    @State private var wrapsLines = true
    @State private var preferredOpenMethod: ProjectFilesOpenMethod?
    @State private var showsBreadcrumbMenu = false
    @State private var showsSplitOpenMethods = false

    private enum FocusTarget: Hashable {
        case toolbar, directory, directoryToggle
    }

    private var selectedPath: ProjectFilePath? {
        model.root == root ? model.selected : nil
    }

    private var openMethod: ProjectFilesOpenMethod {
        let method = preferredOpenMethod ?? .configured(fileOpen.preference)
        if method == .configured(.custom), !method.isAvailable(in: fileOpen) {
            return .configured(.system)
        }
        return method
    }

    private var isMarkdown: Bool {
        guard let path = selectedPath else { return false }
        return ["md", "markdown", "mdown", "mkd"].contains((path.name as NSString).pathExtension.lowercased())
    }

    private var showsMarkdown: Bool { isMarkdown && model.rendersMarkdown }
    private var canOpenSelection: Bool { model.root == root && model.canOpenSelection }

    private var hasDirectory: Bool {
        root != nil && model.root == root && (layout.hasColumns ? !model.hidesDirectory : model.region == .directory)
    }

    private var hasPreview: Bool {
        root != nil && model.root == root && (layout.hasColumns || model.region == .preview)
    }

    var body: some View {
        VStack(spacing: 0) {
            if windowControls == nil, model.root == root, !model.tabs.isEmpty {
                ProjectFilesTabStrip(model: model, focusDirectory: focusDirectory, closePane: close)
                    .padding(.vertical, 4)
            }
            toolbar
            Divider()
            if model.root != root {
                FlatProgressView("正在读取目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if root != nil {
                let directoryWidth: CGFloat = layout.hasColumns ? 200 : layout.width
                let previewWidth = layout.hasColumns && hasDirectory ? layout.width - 201 : layout.width
                ZStack(alignment: .leading) {
                    directory
                        .frame(width: directoryWidth)
                        .opacity(hasDirectory ? 1 : 0)
                        .allowsHitTesting(hasDirectory)
                        .accessibilityHidden(!hasDirectory)
                    preview(width: previewWidth)
                        .frame(width: previewWidth)
                        .overlay(alignment: .leading) {
                            if layout.hasColumns, hasDirectory {
                                Rectangle().fill(PikachuTheme.subtleDivider).frame(width: 1).offset(x: -1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(hasPreview ? 1 : 0)
                        .allowsHitTesting(hasPreview)
                        .accessibilityHidden(!hasPreview)
                }
            } else {
                FlatEmptyState("没有可浏览的工作目录", systemImage: "folder",
                               description: Text("打开一个项目会话以查看文件。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($focus, equals: .toolbar)
            }
        }
        .frame(width: layout.width)
        .frame(maxHeight: .infinity)
        .background(PikachuTheme.pageBackground)
        .accessibilityIdentifier("project-files-pane")
        .onKeyPress(.escape) {
            guard !showsSplitOpenMethods, !showsBreadcrumbMenu else { return .ignored }
            close()
            return .handled
        }
        .onChange(of: root) {
            showsSplitOpenMethods = false
            showsBreadcrumbMenu = false
        }
        .task(id: windowControls?.directoryFocusRequest) {
            guard let request = windowControls?.directoryFocusRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, model.root == root, model.tabs.isEmpty else { return }
            focusDirectory(keyboard: request.keyboard, accessibility: request.accessibility)
        }
        .onChange(of: layout.hasColumns) { wasColumns, hasColumns in
            guard wasColumns, !hasColumns else {
                if hasColumns, model.hidesDirectory, focus == .directory { focus = .toolbar }
                return
            }
            if focus == .directory { model.region = .directory }
            else { model.region = model.selected == nil ? .directory : .preview }
        }
        .task(id: model.root == root ? keyboardOpenRequest : 0) {
            guard keyboardOpenRequest != 0, model.root == root else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            if hasDirectory {
                focus = .directory
            } else {
                focus = .toolbar
                if hasPreview { requestPreviewFocus() }
            }
        }
    }

    private func focusDirectory(keyboard: Bool, accessibility: Bool) {
        if keyboard { focus = .directory }
        if accessibility { accessibilityFocus = .directory }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if let root {
                ProjectFilesBreadcrumbs(root: root, path: selectedPath, folderMenu: $showsBreadcrumbMenu) { path in
                    model.revealDirectory(path)
                    focus = .directory
                }
                toolbarActions
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("文件预览").pikachuFont(.callout, weight: .semibold)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, toolbarTrailingInset)
        .padding(.vertical, 5)
    }

    private var toolbarActions: some View {
        HStack(spacing: 4) {
            if isMarkdown {
                toolbarButton(showsMarkdown ? "显示 Markdown 源码" : "预览 Markdown 格式",
                              icon: IconButtonLabel(assetName: showsMarkdown ? "ToolCallFileCode" : "MarkdownFileCheck"),
                              selected: showsMarkdown, id: "project-files-markdown", action: model.toggleMarkdown)
                    .disabled(!hasDocument || model.isLoadingFile)
            }
            toolbarButton(wrapsLines ? "关闭自动换行" : "开启自动换行",
                          icon: IconButtonLabel(systemName: "arrow.turn.down.left"),
                          selected: wrapsLines && !showsMarkdown, id: "project-files-wrap") {
                wrapsLines.toggle()
            }
            .disabled(!hasDocument || showsMarkdown)
            toolbarButton(directoryToggleTitle, icon: IconButtonLabel(assetName: "ProjectFilesFolderOpen"),
                          selected: hasDirectory, keyboardFocused: focus == .directoryToggle,
                          id: "project-files-toggle-directory", action: toggleDirectory)
                .focused($focus, equals: .directoryToggle)
                .disabled(model.root != root || (!layout.hasColumns && selectedPath == nil))
            toolbarButton("刷新项目文件", icon: IconButtonLabel(systemName: "arrow.clockwise"),
                          help: "从磁盘重新读取当前文件和已展开目录", keyboardFocused: focus == .toolbar,
                          id: "project-files-refresh", action: model.refresh)
                .focused($focus, equals: .toolbar)
                .disabled(model.root != root)
            ProjectFilesOpenControl(method: openMethod, configuration: fileOpen,
                                    canOpen: canOpenSelection, methodsMenu: $showsSplitOpenMethods,
                                    select: { preferredOpenMethod = $0 }, open: openSelection)
                .padding(.leading, layout.hasColumns ? 4 : 0)
        }
    }

    private var hasDocument: Bool {
        if selectedPath != nil, case .document(let document) = model.preview { return !document.text.isEmpty }
        return false
    }

    private var directoryToggleTitle: LocalizedStringKey {
        if !hasDirectory { return "显示目录" }
        return layout.hasColumns ? "隐藏目录" : "返回文件预览"
    }

    private func toolbarButton(_ title: LocalizedStringKey, icon: IconButtonLabel,
                               help: LocalizedStringKey? = nil, selected: Bool = false, keyboardFocused: Bool = false,
                               id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon }
            .buttonStyle(FlatControlButtonStyle(isSelected: selected, hasKeyboardFocus: keyboardFocused,
                                              inset: false, cornerRadius: 5))
            .help(help ?? title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(id)
    }

    private var directory: some View {
        VStack(spacing: 0) {
            Text("项目目录").pikachuFont(.caption, weight: .medium)
                .foregroundStyle(PikachuTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            treeRow(row)
                                .padding(.bottom, 1)
                                .overlay(alignment: .leading) {
                                    if row.depth > 0 { treeGuides(depth: treeDepth(row)) }
                                }
                                .id(row.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .scrollPosition(id: $model.treePosition, anchor: .top)
                .focusable(hasDirectory)
                .focused($focus, equals: .directory)
                .accessibilityLabel("项目目录")
                .accessibilityIdentifier("project-files-directory")
                .accessibilityFocused($accessibilityFocus, equals: .directory)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { key in
                    handleDirectoryKey(key.key)
                }
                .onKeyPress(keys: [.tab]) { key in
                    guard layout.hasColumns, !key.modifiers.contains(.shift), hasDocument,
                          !showsMarkdown else { return .ignored }
                    requestPreviewFocus()
                    return .handled
                }
                .onChange(of: model.focusedRow) { _, row in
                    if let row, focus == .directory { proxy.scrollTo(row) }
                }
                .onChange(of: model.directoryLocation) { _, location in
                    if let location, hasDirectory { proxy.scrollTo(location.row, anchor: .top) }
                }
                .onChange(of: hasDirectory) { _, visible in
                    if visible, let location = model.directoryLocation { proxy.scrollTo(location.row, anchor: .top) }
                }
            }
        }
        .background(PikachuTheme.pageBackground)
    }

    private let treeIndent: CGFloat = 10
    private let treeLeadingPadding: CGFloat = 5
    private let treeIconWidth: CGFloat = 14

    private func treeDepth(_ row: ProjectFilesModel.TreeRow) -> Int {
        min(row.depth, 12)
    }

    private func treeGuides(depth: Int) -> some View {
        Canvas { context, size in
            var lines = Path()
            for level in 0..<depth {
                let x = treeLeadingPadding + treeIconWidth / 2 + CGFloat(level) * treeIndent
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(lines, with: .color(PikachuTheme.subtleDivider), lineWidth: 1)
        }
        .frame(width: treeLeadingPadding + treeIconWidth / 2 + CGFloat(depth) * treeIndent)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func treeRow(_ row: ProjectFilesModel.TreeRow) -> some View {
        let leading = treeLeadingPadding + CGFloat(treeDepth(row)) * treeIndent
        switch row.content {
        case .entry(let entry):
            Button {
                activate(row, keyboard: false)
            } label: {
                HStack(spacing: 5) {
                    ProjectFileIcon(path: entry.path, kind: entry.kind, expanded: model.expanded.contains(entry.path))
                        .frame(width: treeIconWidth)
                    ProjectFileName(name: entry.path.name, separatesExtension: entry.kind != .directory)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pikachuFont(.caption)
                .padding(.leading, leading)
                .padding(.trailing, 5)
                .frame(minHeight: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(treeRowStyle(row, selected: model.selected == row.path))
            .focusable(false)
            .help(Text(verbatim: entry.path.relativePath))
            .accessibilityLabel(Text(verbatim: entry.path.relativePath))
            .accessibilityAddTraits(model.selected == row.path ? [.isSelected] : [])
            .accessibilityValue(directoryValue(entry))
        case .more:
            Button { activate(row, keyboard: false) } label: {
                Text("显示更多")
                    .pikachuFont(.caption)
                    .padding(.leading, leading + treeIconWidth + 5)
                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
            }
            .focusable(false)
            .buttonStyle(treeRowStyle(row))
        case .loading:
            FlatProgressView("正在读取目录…").padding(.vertical, 6)
                .padding(.leading, leading + treeIconWidth + 5)
        case .empty:
            treeMessage(Text("文件夹为空"), leading: leading)
        case .failure(let issue):
            treeMessage(Text(verbatim: issue.message), leading: leading)
        }
    }

    private func treeMessage(_ message: Text, leading: CGFloat) -> some View {
        message.foregroundStyle(PikachuTheme.secondaryText).pikachuFont(.caption)
            .padding(.vertical, 6).padding(.leading, leading + treeIconWidth + 5)
    }

    private func treeRowStyle(_ row: ProjectFilesModel.TreeRow, selected: Bool = false) -> FlatControlButtonStyle {
        FlatControlButtonStyle(isSelected: selected, hasKeyboardFocus: focus == .directory && model.focusedRow == row.id,
                               inset: false, cornerRadius: 5)
    }

    private func directoryValue(_ entry: ProjectFileEntry) -> Text {
        guard entry.kind == .directory else { return Text("") }
        return model.expanded.contains(entry.path) ? Text("已展开") : Text("已收起")
    }

    private func activate(_ row: ProjectFilesModel.TreeRow, keyboard: Bool) {
        model.focusedRow = row.id
        switch row.content {
        case .entry(let entry) where entry.kind == .directory:
            model.toggle(entry.path)
        case .entry(let entry):
            model.open(entry)
            if !layout.hasColumns, keyboard || focus == .directory {
                // The toolbar is available while the file loads. Only an explicit
                // action on an already loaded document can focus its text view.
                focus = .toolbar
                if keyboard { requestPreviewFocus() }
            }
        case .more:
            model.showMore(in: row.path, movesFocus: keyboard || focus == .directory)
        default:
            break
        }
    }

    private func handleDirectoryKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let actions = model.rows.filter(\.isActionable)
        guard !actions.isEmpty else { return .ignored }
        let current = actions.firstIndex { $0.id == model.focusedRow }
        switch key {
        case .upArrow, .downArrow:
            let index = current.map { max(0, min(actions.count - 1, $0 + (key == .upArrow ? -1 : 1))) } ?? 0
            model.focusedRow = actions[index].id
        case .return:
            activate(actions[current ?? 0], keyboard: true)
        case .leftArrow, .rightArrow:
            let row = actions[current ?? 0]
            if case .entry(let entry) = row.content,
               entry.kind == .directory, model.expanded.contains(row.path) != (key == .rightArrow) {
                model.toggle(row.path)
            } else if key == .leftArrow, row.path.parent != .root {
                model.focusedRow = .entry(row.path.parent)
            } else if key == .rightArrow, case .entry(let entry) = row.content,
                      entry.kind == .directory, let current, actions.indices.contains(current + 1),
                      actions[current + 1].path.isWithin(row.path) {
                model.focusedRow = actions[current + 1].id
            }
        default:
            return .ignored
        }
        return .handled
    }

    private func requestPreviewFocus() {
        if hasDocument, !showsMarkdown {
            previewFocusRequest += 1
        }
    }

    private func toggleDirectory() {
        if layout.hasColumns {
            model.hidesDirectory.toggle()
            if model.hidesDirectory, focus == .directory { focus = .directoryToggle }
        } else if hasDirectory {
            model.region = .preview
            focus = .directoryToggle
            requestPreviewFocus()
        } else {
            model.region = .directory
            focus = .directory
        }
    }

    private func openSelection() {
        guard canOpenSelection else { return }
        let method = openMethod
        let configuration = fileOpen
        model.openSelection(canLaunch: canLaunch) { request in
            await method.open(request, configuration: configuration)
        }
    }

    @ViewBuilder
    private func preview(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let path = selectedPath {
                switch model.preview {
                case .document(let document) where !document.text.isEmpty:
                    ZStack {
                        ProjectFileTextView(document: document, wrapsLines: wrapsLines,
                                            focusRequest: previewFocusRequest, isVisible: hasPreview && !showsMarkdown,
                                            targetLine: model.lineTarget?.path == path ? model.lineTarget : nil) {
                            close()
                            return true
                        }
                        .opacity(showsMarkdown ? 0 : 1)
                        .accessibilityHidden(showsMarkdown)
                        .allowsHitTesting(!showsMarkdown)
                        if showsMarkdown {
                            ProjectMarkdownPreview(text: document.text, paneWidth: width,
                                                   imageLoader: model.markdownImageLoader(for: path))
                        }
                    }
                    .id(path)
                case .document:
                    previewMessage("空文件")
                case .failure(let issue):
                    Text(verbatim: issue.message)
                        .pikachuFont(.callout)
                        .foregroundStyle(PikachuTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                case nil, .loading:
                    FlatProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                previewMessage("选择文件以预览")
            }
        }
        .frame(maxHeight: .infinity)
        .background(PikachuTheme.pageBackground)
        .accessibilityIdentifier("project-files-preview")
    }

    private func previewMessage(_ message: LocalizedStringKey) -> some View {
        Text(message).pikachuFont(.callout)
            .foregroundStyle(PikachuTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
    }
}

private struct ProjectMarkdownPreview: View {
    let text: String
    let paneWidth: CGFloat
    let imageLoader: MarkdownImageLoader?
    @State private var viewportWidth: CGFloat?
    @State private var topBlock: MarkdownBlockID?

    var body: some View {
        let availableWidth = min(paneWidth, viewportWidth ?? paneWidth)
        let width = MarkdownWidth(availableWidth)
        let contentWidth = width.editorialContentWidth(in: availableWidth)

        ScrollView {
            MarkdownContent(text: text, streaming: false, width: contentWidth, profile: .editorial,
                            hostWidth: availableWidth, linkPolicy: .projectPreview, imageLoader: imageLoader)
                .frame(width: contentWidth, alignment: .leading)
                .padding(width.editorialInsets)
                .frame(width: max(1, availableWidth))
        }
        .scrollPosition(id: $topBlock, anchor: .top)
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: CGFloat.self, of: \.visibleRect.width) { _, width in
            viewportWidth = width > 0 ? width : nil
        }
        .accessibilityLabel("Markdown 格式预览")
        .accessibilityIdentifier("project-files-markdown-preview")
    }
}

private struct ProjectFileName: View {
    let name: String
    let separatesExtension: Bool

    var body: some View {
        if separatesExtension, !name.hasPrefix("."), let dot = name.lastIndex(of: "."),
           name.index(after: dot) < name.endIndex {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    label(String(name[..<dot]))
                        .frame(idealWidth: 28, alignment: .leading)
                    Text(verbatim: String(name[dot...])).fixedSize()
                }
                label(name)
            }
        } else {
            label(name)
        }
    }

    private func label(_ value: String) -> some View {
        Text(verbatim: value).lineLimit(1).truncationMode(.middle)
    }
}
