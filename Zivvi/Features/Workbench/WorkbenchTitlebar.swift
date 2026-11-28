import AppKit
import SwiftUI
import OrchestrationCore

/// Hosts the Zivvi brand mark, sidebar toggle, and the Dual Tab Groups (Conversation + Editor Tabs)
/// directly in the native macOS unified titlebar row so tabs align at the very top of the window.
struct WorkbenchTitlebar: NSViewRepresentable {
    @Environment(\.zivviTypography) private var typography
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let workspace: WorkspaceController
    let tabsModel: WorkbenchTabsModel
    let gitStore: GitStatusStore
    let detailWidth: CGFloat
    let showsEditorArea: Bool
    let editorWidth: CGFloat
    var isLightboxPresented = false
    let onSelectSession: (UUID) -> Void
    let onCloseSession: (UUID) -> Void
    let onNewSession: () -> Void
    let onManageSession: (SessionManagementAction, UUID) -> Void
    let onJumpToGit: (ProjectRecord) -> Void
    let onToggleEditor: () -> Void
    let onRequestCloseEditorTab: (WorkbenchTabsModel.EditorTab) -> Void
    let onCollapseEditor: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            visibility: $sidebarVisibility,
            workspace: workspace,
            tabsModel: tabsModel,
            gitStore: gitStore,
            fontSize: typography.size,
            showsEditorArea: showsEditorArea,
            editorWidth: editorWidth,
            onSelectSession: onSelectSession,
            onCloseSession: onCloseSession,
            onNewSession: onNewSession,
            onManageSession: onManageSession,
            onJumpToGit: onJumpToGit,
            onToggleEditor: onToggleEditor,
            onRequestCloseEditorTab: onRequestCloseEditorTab,
            onCollapseEditor: onCollapseEditor
        )
    }

    func makeNSView(context: Context) -> WindowAttachment {
        let view = WindowAttachment()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachment, context: Context) {
        context.coordinator.update(
            visibility: $sidebarVisibility,
            detailWidth: detailWidth,
            showsEditorArea: showsEditorArea,
            editorWidth: editorWidth,
            fontSize: typography.size,
            isLightboxPresented: isLightboxPresented
        )
    }

    static func dismantleNSView(_ view: WindowAttachment, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.attach(to: nil)
    }

    final class WindowAttachment: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Install after SwiftUI finishes attaching the split-view columns.
            Task { @MainActor [weak self] in
                guard let self else { return }
                coordinator?.attach(to: window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        private static let headingID = NSToolbarItem.Identifier("ZivviSidebarHeading")
        private static let toggleID = NSToolbarItem.Identifier("ZivviSidebarToggle")
        private static let tabBarsID = NSToolbarItem.Identifier("ZivviTabBars")

        private let toolbar = NSToolbar(identifier: "ZivviWorkbenchToolbar2")
        private weak var window: NSWindow?
        private var previousBackdrop: (color: NSColor?, transparentTitlebar: Bool)?
        private var visibility: Binding<NavigationSplitViewVisibility>
        private var sidebarVisible: Bool
        private var detailWidth: CGFloat = 0
        private var overflowCheckScheduled = false
        private var toolbarInsetsUpdateScheduled = false
        private var isLightboxPresented = false
        private var fontSize: InterfaceFontSize
        private var showsEditorArea: Bool
        private var editorWidth: CGFloat
        private var trailingInset: CGFloat = 12
        private let tabBarsHost: ToolbarTabBarsHostingView<WindowTabBarsHost>
        private let tabBarsWidth: NSLayoutConstraint
        private let tabBarsHeight: NSLayoutConstraint
        private weak var headingLabel: NSTextField?
        private weak var headingStack: NSStackView?
        private weak var toggleHost: NSHostingView<SidebarToggleButton>?
        private weak var toggleItem: NSToolbarItem?

        private var toggleLabel: String {
            sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏")
        }

        init(
            visibility: Binding<NavigationSplitViewVisibility>,
            workspace: WorkspaceController,
            tabsModel: WorkbenchTabsModel,
            gitStore: GitStatusStore,
            fontSize: InterfaceFontSize,
            showsEditorArea: Bool,
            editorWidth: CGFloat,
            onSelectSession: @escaping (UUID) -> Void,
            onCloseSession: @escaping (UUID) -> Void,
            onNewSession: @escaping () -> Void,
            onManageSession: @escaping (SessionManagementAction, UUID) -> Void,
            onJumpToGit: @escaping (ProjectRecord) -> Void,
            onToggleEditor: @escaping () -> Void,
            onRequestCloseEditorTab: @escaping (WorkbenchTabsModel.EditorTab) -> Void,
            onCollapseEditor: @escaping () -> Void
        ) {
            self.visibility = visibility
            self.fontSize = fontSize
            self.sidebarVisible = visibility.wrappedValue != .detailOnly
            self.showsEditorArea = showsEditorArea
            self.editorWidth = editorWidth

            let typography = ZivviTypography(size: fontSize)
            let root = WindowTabBarsHost(
                workspace: workspace,
                tabsModel: tabsModel,
                gitStore: gitStore,
                showsEditorArea: showsEditorArea,
                editorWidth: editorWidth,
                trailingInset: 12,
                fontSize: fontSize,
                onSelectSession: onSelectSession,
                onCloseSession: onCloseSession,
                onNewSession: onNewSession,
                onManageSession: onManageSession,
                onJumpToGit: onJumpToGit,
                onToggleEditor: onToggleEditor,
                onRequestCloseEditorTab: onRequestCloseEditorTab,
                onCollapseEditor: onCollapseEditor
            )
            let host = ToolbarTabBarsHostingView(rootView: root)
            tabBarsHost = host
            tabBarsWidth = host.widthAnchor.constraint(equalToConstant: 240)
            tabBarsHeight = host.heightAnchor.constraint(equalToConstant: typography.titlebarControlHeight)
            super.init()
            tabBarsHost.sizingOptions = []
            tabBarsHost.frame = NSRect(x: 0, y: 0, width: 240, height: typography.titlebarControlHeight)
            NSLayoutConstraint.activate([tabBarsWidth, tabBarsHeight])
            toolbar.displayMode = .iconOnly
            toolbar.allowsDisplayModeCustomization = false
            toolbar.delegate = self
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            if let window, window.toolbar === toolbar {
                window.toolbar = nil
                if let previousBackdrop {
                    window.backgroundColor = previousBackdrop.color
                    window.titlebarAppearsTransparent = previousBackdrop.transparentTitlebar
                }
            }
            previousBackdrop = nil
            window = newWindow
            guard let newWindow else { return }
            previousBackdrop = (newWindow.backgroundColor, newWindow.titlebarAppearsTransparent)
            newWindow.titleVisibility = .hidden
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.backgroundColor = ZivviTheme.pageBackgroundColor
            newWindow.titlebarAppearsTransparent = true
            newWindow.toolbarStyle = .unifiedCompact
            newWindow.titlebarSeparatorStyle = .none
            newWindow.toolbar = toolbar
            toolbar.isVisible = true
            scheduleToolbarInsetsUpdate()
        }

        func update(
            visibility: Binding<NavigationSplitViewVisibility>,
            detailWidth: CGFloat,
            showsEditorArea: Bool,
            editorWidth: CGFloat,
            fontSize: InterfaceFontSize,
            isLightboxPresented: Bool
        ) {
            self.visibility = visibility
            self.detailWidth = detailWidth
            self.isLightboxPresented = isLightboxPresented

            let fontChanged = self.fontSize != fontSize
            let editorLayoutChanged = self.showsEditorArea != showsEditorArea || abs(self.editorWidth - editorWidth) >= 0.5
            self.showsEditorArea = showsEditorArea
            self.editorWidth = editorWidth

            if fontChanged || editorLayoutChanged {
                var content = tabBarsHost.rootView
                content.fontSize = fontSize
                content.showsEditorArea = showsEditorArea
                content.editorWidth = editorWidth
                tabBarsHost.rootView = content
            }

            if fontChanged {
                self.fontSize = fontSize
                let typography = ZivviTypography(size: fontSize)
                tabBarsHeight.constant = typography.titlebarControlHeight
                headingLabel?.font = typography.nsFont(.callout, weight: .semibold)
                if let headingStack {
                    headingStack.invalidateIntrinsicContentSize()
                    headingStack.layoutSubtreeIfNeeded()
                    headingStack.frame.size = headingStack.fittingSize
                }
            }

            tabBarsHost.isHidden = isLightboxPresented
            toggleHost?.isHidden = isLightboxPresented
            toggleItem?.isEnabled = !isLightboxPresented
            headingStack?.isHidden = isLightboxPresented

            let visible = visibility.wrappedValue != .detailOnly
            let sidebarChanged = sidebarVisible != visible
            let previousCount = sidebarItems.count
            sidebarVisible = visible
            let tabBarsWidthChanged = sizeTabBarsItem()

            guard !toolbar.items.isEmpty else { return }
            if sidebarChanged {
                for index in toolbar.items.indices.prefix(previousCount).reversed()
                    where toolbar.items[index].itemIdentifier != Self.toggleID {
                    toolbar.removeItem(at: index)
                }
                for (index, identifier) in sidebarItems.enumerated() where identifier != Self.toggleID {
                    toolbar.insertItem(withItemIdentifier: identifier, at: index)
                }
            }
            if sidebarChanged || fontChanged {
                toggleHost?.rootView = sidebarToggleView
                toggleItem?.label = toggleLabel
                toggleItem?.toolTip = toggleLabel
            }

            if !toolbar.items.contains(where: { $0.itemIdentifier == Self.tabBarsID }) {
                toolbar.insertItem(withItemIdentifier: Self.tabBarsID, at: toolbar.items.count)
            } else if tabBarsWidthChanged || sidebarChanged || fontChanged {
                scheduleRecoveryFromOverflow()
            }
            scheduleToolbarInsetsUpdate()
        }

        private func sizeTabBarsItem() -> Bool {
            guard detailWidth > 0 else { return false }
            let width = floor(max(180, detailWidth - (sidebarVisible ? 44 : 196)))
            guard tabBarsWidth.constant != width else { return false }
            tabBarsWidth.constant = width
            tabBarsHost.frame.size.width = width
            tabBarsHost.invalidateIntrinsicContentSize()
            return true
        }

        private func scheduleRecoveryFromOverflow() {
            guard !overflowCheckScheduled else { return }
            overflowCheckScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overflowCheckScheduled = false
                guard self.window?.toolbar === self.toolbar,
                      self.toolbar.visibleItems?.contains(where: { $0.itemIdentifier == Self.tabBarsID }) == false,
                      let index = self.toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.tabBarsID }) else { return }
                self.toolbar.removeItem(at: index)
                self.toolbar.insertItem(withItemIdentifier: Self.tabBarsID, at: index)
                self.scheduleToolbarInsetsUpdate()
            }
        }

        private func scheduleToolbarInsetsUpdate() {
            guard !toolbarInsetsUpdateScheduled else { return }
            toolbarInsetsUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toolbarInsetsUpdateScheduled = false
                guard let window = self.window, window.toolbar === self.toolbar,
                      let contentView = window.contentView else { return }
                if !window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = true
                }
                if self.tabBarsHost.window === window, !self.tabBarsHost.isHidden {
                    let hostFrame = contentView.convert(self.tabBarsHost.bounds, from: self.tabBarsHost)
                    let inset = max(0, contentView.bounds.maxX - hostFrame.maxX)
                    if abs(self.trailingInset - inset) >= 0.5 {
                        self.trailingInset = inset
                        var content = self.tabBarsHost.rootView
                        content.trailingInset = inset
                        self.tabBarsHost.rootView = content
                    }
                }
            }
        }

        private var sidebarItems: [NSToolbarItem.Identifier] {
            sidebarVisible ? [Self.headingID, .flexibleSpace, Self.toggleID, .sidebarTrackingSeparator] : [Self.toggleID]
        }

        private var sidebarToggleView: SidebarToggleButton {
            SidebarToggleButton(title: toggleLabel, fontSize: fontSize, expanded: sidebarVisible) { [weak self] in
                self?.toggleSidebar()
            }
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.headingID, .flexibleSpace, Self.toggleID, .sidebarTrackingSeparator, Self.tabBarsID]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            sidebarItems + [Self.tabBarsID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            switch identifier {
            case Self.toggleID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = toggleLabel
                item.toolTip = toggleLabel
                item.target = self
                item.action = #selector(toggleSidebar)
                let toggle = NSHostingView(rootView: sidebarToggleView)
                toggleHost = toggle
                toggleItem = item
                toggle.sizingOptions = []
                NSLayoutConstraint.activate([
                    toggle.widthAnchor.constraint(equalToConstant: IconButtonLabel.side),
                    toggle.heightAnchor.constraint(equalToConstant: IconButtonLabel.side)
                ])
                toggle.frame.size = .init(width: IconButtonLabel.side, height: IconButtonLabel.side)
                item.view = toggle
                item.isBordered = false
                item.isEnabled = !isLightboxPresented
                toggle.isHidden = isLightboxPresented
                return item

            case Self.headingID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.paletteLabel = "Zivvi"
                let icon = NSHostingView(rootView: LightningBrandIconView(.agent, size: 16))
                icon.sizingOptions = []
                icon.setAccessibilityElement(false)
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16)
                ])
                icon.frame.size = .init(width: 16, height: 16)
                let name = NSTextField(labelWithString: "Zivvi")
                name.font = ZivviTypography(size: fontSize).nsFont(.callout, weight: .semibold)
                let heading = NSStackView(views: [icon, name])
                heading.alignment = .centerY
                heading.spacing = 4
                heading.frame.size = heading.fittingSize
                headingLabel = name
                headingStack = heading
                item.view = heading
                item.isBordered = false
                heading.isHidden = isLightboxPresented
                return item

            case Self.tabBarsID:
                _ = sizeTabBarsItem()
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = String(localized: "标签页")
                item.view = tabBarsHost
                item.isBordered = false
                tabBarsHost.isHidden = isLightboxPresented
                return item

            default:
                return nil
            }
        }

        @objc private func toggleSidebar() {
            visibility.wrappedValue = sidebarVisible ? .detailOnly : .all
        }
    }
}

private final class ToolbarTabBarsHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct SidebarToggleButton: View {
    let title: String
    let fontSize: InterfaceFontSize
    let expanded: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            IconButtonLabel(systemName: "sidebar.left")
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: expanded, hasKeyboardFocus: focused, inset: false))
        .focused($focused)
        .zivviTypography(fontSize)
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(expanded ? Text("已展开") : Text("已折叠"))
    }
}

private struct WindowTabBarsHost: View {
    let workspace: WorkspaceController
    let tabsModel: WorkbenchTabsModel
    let gitStore: GitStatusStore
    var showsEditorArea: Bool
    var editorWidth: CGFloat
    var trailingInset: CGFloat
    var fontSize: InterfaceFontSize
    let onSelectSession: (UUID) -> Void
    let onCloseSession: (UUID) -> Void
    let onNewSession: () -> Void
    let onManageSession: (SessionManagementAction, UUID) -> Void
    let onJumpToGit: (ProjectRecord) -> Void
    let onToggleEditor: () -> Void
    let onRequestCloseEditorTab: (WorkbenchTabsModel.EditorTab) -> Void
    let onCollapseEditor: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ConversationTabBar(
                workspace: workspace,
                tabsModel: tabsModel,
                gitStore: gitStore,
                isEditorVisible: showsEditorArea,
                hasEditorTabs: !tabsModel.editorTabs.isEmpty,
                onSelectSession: onSelectSession,
                onCloseSession: onCloseSession,
                onNewSession: onNewSession,
                onManageSession: onManageSession,
                onJumpToGit: onJumpToGit,
                onToggleEditor: onToggleEditor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsEditorArea {
                ZivviDivider(axis: .vertical, color: ZivviTheme.subtleDivider)
                    .padding(.vertical, 3)
                EditorTabBar(
                    tabsModel: tabsModel,
                    onRequestCloseTab: onRequestCloseEditorTab,
                    onCollapseEditor: onCollapseEditor
                )
                .frame(width: max(180, editorWidth - trailingInset))
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zivviTypography(fontSize)
        .scrollIndicators(.never)
    }
}
