import SwiftUI

struct ProjectFilesTabStrip: View {
    let model: ProjectFilesModel
    let focusDirectory: (_ keyboard: Bool, _ accessibility: Bool) -> Void
    let closePane: () -> Void

    @FocusState private var focus: FocusTarget?
    @AccessibilityFocusState private var accessibilityFocus: FocusTarget?

    private enum FocusTarget: Hashable {
        case tab(ProjectFilePath), closeTab(ProjectFilePath)

        var tabPath: ProjectFilePath {
            switch self {
            case .tab(let path), .closeTab(let path): path
            }
        }
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        let path = tab.id
                        FileTab(path: path, kind: tab.kind, selected: model.selected == path, focus: $focus,
                                accessibilityFocus: $accessibilityFocus,
                                select: { model.activateTab(path) }, close: { closeTab(path) })
                            .id(path)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel("已打开的文件")
            .accessibilityIdentifier("project-files-tabs")
            .onKeyPress(.escape) {
                closePane()
                return .handled
            }
            .onChange(of: model.tabLocation, initial: true) { _, location in
                if let location, location.path == model.selected,
                   let path = Self.openTabPath(location.path, in: model.tabs) {
                    scroll.scrollTo(path)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in
                if let path = Self.resizeScrollTarget(accessibilityPath: accessibilityFocus?.tabPath,
                                                      keyboardPath: focus?.tabPath,
                                                      selectedPath: model.selected,
                                                      tabs: model.tabs) {
                    scroll.scrollTo(path)
                }
            }
            .onChange(of: focus) { _, target in
                if let path = Self.openTabPath(target?.tabPath, in: model.tabs) { scroll.scrollTo(path) }
            }
            .onChange(of: accessibilityFocus) { _, target in
                if let path = Self.openTabPath(target?.tabPath, in: model.tabs) { scroll.scrollTo(path) }
            }
        }
    }

    static func openTabPath(_ path: ProjectFilePath?, in tabs: [ProjectFilesModel.Tab]) -> ProjectFilePath? {
        guard let path, tabs.contains(where: { $0.id == path }) else { return nil }
        return path
    }

    /// Resolves the scroll target when the strip width changes so an active VoiceOver tab stays visible.
    static func resizeScrollTarget(accessibilityPath: ProjectFilePath?, keyboardPath: ProjectFilePath?,
                                   selectedPath: ProjectFilePath?, tabs: [ProjectFilesModel.Tab]) -> ProjectFilePath? {
        openTabPath(accessibilityPath, in: tabs)
            ?? openTabPath(keyboardPath, in: tabs)
            ?? openTabPath(selectedPath, in: tabs)
    }

    private func closeTab(_ path: ProjectFilePath) {
        let needsFocus = focus?.tabPath == path
        let needsAccessibilityFocus = accessibilityFocus?.tabPath == path
        let neighbor = model.closeTab(path)
        if let neighbor {
            if needsFocus { focus = .tab(neighbor) }
            if needsAccessibilityFocus { accessibilityFocus = .tab(neighbor) }
        } else if needsFocus || needsAccessibilityFocus {
            focusDirectory(needsFocus, needsAccessibilityFocus)
        }
    }

    private struct FileTab: View {
        let path: ProjectFilePath
        let kind: ProjectFileEntry.Kind
        let selected: Bool
        let focus: FocusState<FocusTarget?>.Binding
        let accessibilityFocus: AccessibilityFocusState<FocusTarget?>.Binding
        let select: () -> Void
        let close: () -> Void
        @State private var hovered = false

        var body: some View {
            let focused = focus.wrappedValue
            let showsClose = hovered || focused?.tabPath == path || accessibilityFocus.wrappedValue?.tabPath == path
            HStack(spacing: 0) {
                ZStack {
                    ProjectFileIcon(path: path, kind: kind)
                        .pikachuFont(.caption)
                        .foregroundStyle(PikachuTheme.secondaryText)
                        .opacity(showsClose ? 0 : 1)
                        .allowsHitTesting(false)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .pikachuFont(.caption2, weight: .semibold)
                            .opacity(showsClose ? 1 : 0)
                            .frame(width: IconButtonLabel.side, height: IconButtonLabel.side)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FlatControlButtonStyle(hasKeyboardFocus: focused == .closeTab(path), inset: false))
                    .focused(focus, equals: .closeTab(path))
                    .allowsHitTesting(showsClose)
                    .accessibilityLabel("关闭 \(path.name)")
                    .accessibilityValue(Text(verbatim: path.relativePath))
                    .accessibilityFocused(accessibilityFocus, equals: .closeTab(path))
                }
                Button(action: select) {
                    Text(verbatim: path.name)
                        .pikachuFont(.caption, weight: selected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.trailing, 8)
                        .frame(minWidth: 68, maxWidth: 152, minHeight: 26, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FlatControlButtonStyle(isSelected: selected, hasKeyboardFocus: focused == .tab(path),
                                                  inset: false, cornerRadius: 5))
                .focused(focus, equals: .tab(path))
                .accessibilityLabel(Text(verbatim: path.relativePath))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityFocused(accessibilityFocus, equals: .tab(path))
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(selected ? PikachuTheme.selected : Color.clear, in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .help(Text(verbatim: path.relativePath))
        }
    }
}

struct ProjectFileIcon: View {
    let path: ProjectFilePath
    let kind: ProjectFileEntry.Kind
    var expanded = false

    private var symbol: String {
        switch kind {
        case .directory: expanded ? "chevron.down" : "chevron.right"
        case .link: "link"
        case .other: "questionmark.square"
        case .file:
            switch (path.name as NSString).pathExtension.lowercased() {
            case "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "js", "jsx", "ts", "tsx",
                 "py", "rb", "sh", "zsh", "java", "kt", "html", "css", "sql":
                "chevron.left.forwardslash.chevron.right"
            case "md", "markdown", "mdown", "mkd": "doc.plaintext"
            case "json", "jsonc", "plist", "xcstrings", "xcconfig", "yml", "yaml", "toml", "ini", "xml":
                "gearshape"
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg", "ico": "photo"
            default: "doc"
            }
        }
    }

    var body: some View {
        Image(systemName: symbol).accessibilityHidden(true)
    }
}
