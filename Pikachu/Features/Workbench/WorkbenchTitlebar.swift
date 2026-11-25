import AppKit
import SwiftUI
import OrchestrationCore

/// Hosts the sidebar controls and the viewed session in the same window toolbar.
struct WorkbenchTitlebar: NSViewRepresentable {
    @Environment(\.pikachuTypography) private var typography
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let workspace: WorkspaceController
    let gitStore: GitStatusStore
    let detailWidth: CGFloat
    let hasSession: Bool
    var isLightboxPresented = false
    let projectFiles: ProjectFilesControls
    let filesModel: ProjectFilesModel
    let filesRoot: ProjectFilesRoot?
    let filesWidth: CGFloat
    let filesFocus: ProjectFilesFocusBridge
    let createSession: (UUID) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(visibility: $sidebarVisibility, workspace: workspace, gitStore: gitStore,
                    fontSize: typography.size, projectFiles: projectFiles, filesModel: filesModel,
                    filesRoot: filesRoot, filesWidth: filesWidth, filesFocus: filesFocus,
                    createSession: createSession, manageSession: manageSession)
    }

    func makeNSView(context: Context) -> WindowAttachment {
        let view = WindowAttachment()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachment, context: Context) {
        context.coordinator.update(visibility: $sidebarVisibility, detailWidth: detailWidth,
                                   hasSession: hasSession, fontSize: typography.size,
                                   isLightboxPresented: isLightboxPresented, filesOpen: projectFiles.isOpen,
                                   filesBlocked: projectFiles.blocked, filesRoot: filesRoot, filesWidth: filesWidth)
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
        private static let headingID = NSToolbarItem.Identifier("PikachuSidebarHeading")
        private static let toggleID = NSToolbarItem.Identifier("PikachuSidebarToggle")
        private static let sessionID = NSToolbarItem.Identifier("PikachuSessionHeader")
        private static let filesID = NSToolbarItem.Identifier("PikachuProjectFiles")

        private let toolbar = NSToolbar(identifier: "PikachuWorkbenchToolbar")
        private weak var window: NSWindow?
        private var previousBackdrop: (color: NSColor?, transparentTitlebar: Bool)?
        private var visibility: Binding<NavigationSplitViewVisibility>
        private var sidebarVisible: Bool
        private var detailWidth: CGFloat = 0
        private var overflowCheckScheduled = false
        private var toolbarInsetsUpdateScheduled = false
        private var hasTitlebarContent: Bool
        private var isLightboxPresented = false
        private let projectFiles: ProjectFilesControls
        private let filesFocus: ProjectFilesFocusBridge
        private weak var filesItem: NSToolbarItem?
        private var filesButtonHeight: NSLayoutConstraint?
        private var fontSize: InterfaceFontSize
        private let sessionHost: NSHostingView<WindowSessionControls>
        private let sessionWidth: NSLayoutConstraint
        private let sessionHeight: NSLayoutConstraint
        private weak var headingLabel: NSTextField?
        private weak var headingStack: NSStackView?
        private weak var toggleHost: NSHostingView<SidebarToggleButton>?
        private weak var toggleItem: NSToolbarItem?
        private var toggleLabel: String { sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏") }

        init(visibility: Binding<NavigationSplitViewVisibility>, workspace: WorkspaceController, gitStore: GitStatusStore,
             fontSize: InterfaceFontSize, projectFiles: ProjectFilesControls, filesModel: ProjectFilesModel,
             filesRoot: ProjectFilesRoot?, filesWidth: CGFloat, filesFocus: ProjectFilesFocusBridge,
             createSession: @escaping (UUID) -> Void,
             manageSession: @escaping (SessionManagementAction, UUID) -> Void) {
            self.visibility = visibility
            self.projectFiles = projectFiles
            self.filesFocus = filesFocus
            self.fontSize = fontSize
            sidebarVisible = visibility.wrappedValue != .detailOnly
            hasTitlebarContent = workspace.viewed != nil || projectFiles.isOpen
            let typography = PikachuTypography(size: fontSize)
            let host = NSHostingView(rootView: WindowSessionControls(workspace: workspace, gitStore: gitStore,
                                                                    projectFiles: projectFiles, filesModel: filesModel,
                                                                    filesRoot: filesRoot, filesWidth: filesWidth,
                                                                    filesFocus: filesFocus,
                                                                    fontSize: fontSize, createSession: createSession,
                                                                    manageSession: manageSession))
            sessionHost = host
            sessionWidth = host.widthAnchor.constraint(equalToConstant: 200)
            sessionHeight = host.heightAnchor.constraint(equalToConstant: typography.titlebarControlHeight)
            super.init()
            sessionHost.sizingOptions = []
            sessionHost.frame = NSRect(x: 0, y: 0, width: 200, height: typography.titlebarControlHeight)
            NSLayoutConstraint.activate([
                sessionWidth,
                sessionHeight
            ])
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
            newWindow.backgroundColor = PikachuTheme.pageBackgroundColor
            newWindow.titlebarAppearsTransparent = true
            newWindow.toolbarStyle = .unified
            newWindow.titlebarSeparatorStyle = .none
            newWindow.toolbar = toolbar
            toolbar.isVisible = true
            scheduleToolbarInsetsUpdate()
        }

        func update(visibility: Binding<NavigationSplitViewVisibility>, detailWidth: CGFloat, hasSession: Bool,
                    fontSize: InterfaceFontSize, isLightboxPresented: Bool, filesOpen: Bool, filesBlocked: Bool,
                    filesRoot: ProjectFilesRoot?, filesWidth: CGFloat) {
            self.visibility = visibility
            self.detailWidth = detailWidth
            hasTitlebarContent = hasSession || filesOpen
            self.isLightboxPresented = isLightboxPresented
            let fontChanged = self.fontSize != fontSize
            if fontChanged || sessionHost.rootView.filesRoot != filesRoot || sessionHost.rootView.filesWidth != filesWidth {
                var content = sessionHost.rootView
                content.fontSize = fontSize
                content.filesRoot = filesRoot
                content.filesWidth = filesWidth
                sessionHost.rootView = content
            }
            if fontChanged {
                self.fontSize = fontSize
                let typography = PikachuTypography(size: fontSize)
                sessionHeight.constant = typography.titlebarControlHeight
                if let button = filesFocus.toolbarButton {
                    filesButtonHeight?.constant = typography.titlebarControlHeight
                    button.image = filesIcon(typography: typography)
                }
                headingLabel?.font = typography.nsFont(.callout, weight: .semibold)
                if let headingStack {
                    headingStack.invalidateIntrinsicContentSize()
                    headingStack.layoutSubtreeIfNeeded()
                    headingStack.frame.size = headingStack.fittingSize
                }
            }
            applyLightboxVisibility()
            updateFilesItem(open: filesOpen, blocked: filesBlocked)
            let visible = visibility.wrappedValue != .detailOnly
            let sidebarChanged = sidebarVisible != visible
            let previousSidebarItemCount = sidebarItems.count
            sidebarVisible = visible
            let sessionWidthChanged = sizeSessionItem()

            guard !toolbar.items.isEmpty else { return }
            if sidebarChanged {
                // Keep the focused toggle attached while changing the items around it.
                for index in toolbar.items.indices.prefix(previousSidebarItemCount).reversed()
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
            let sessionIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.sessionID }
            if hasTitlebarContent, sessionIndex == nil {
                let filesIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.filesID } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: Self.sessionID, at: filesIndex)
            } else if !hasTitlebarContent, let sessionIndex {
                toolbar.removeItem(at: sessionIndex)
            } else if hasTitlebarContent, sessionWidthChanged || sidebarChanged || fontChanged {
                scheduleRecoveryFromOverflow()
            }
            scheduleToolbarInsetsUpdate()
        }

        private func applyLightboxVisibility() {
            sessionHost.isHidden = isLightboxPresented
            toggleHost?.isHidden = isLightboxPresented
            toggleItem?.isEnabled = !isLightboxPresented
            headingStack?.isHidden = isLightboxPresented
        }

        private func sizeSessionItem() -> Bool {
            guard detailWidth > 0 else { return false }
            // The detail measurement excludes the sidebar; leave room for the toolbar insets.
            // With the sidebar closed the traffic lights and toggle also share this width.
            let width = floor(max(150, detailWidth - (sidebarVisible ? 54 : 198)))
            guard sessionWidth.constant != width else { return false }
            sessionWidth.constant = width
            sessionHost.frame.size.width = width
            sessionHost.invalidateIntrinsicContentSize()
            return true
        }

        private func scheduleRecoveryFromOverflow() {
            guard !overflowCheckScheduled else { return }
            overflowCheckScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overflowCheckScheduled = false
                guard self.window?.toolbar === self.toolbar, self.hasTitlebarContent,
                      self.toolbar.visibleItems?.contains(where: { $0.itemIdentifier == Self.sessionID }) == false,
                      let index = self.toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.sessionID }) else { return }
                // An overflowed item is detached, so AppKit may still be using its pre-resize width.
                // Re-register the item at its new size while keeping the same session host.
                self.toolbar.removeItem(at: index)
                self.toolbar.insertItem(withItemIdentifier: Self.sessionID, at: index)
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
                // The window can restore its toolbar background during the initial layout.
                if !window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = true
                }
                if let button = self.filesFocus.toolbarButton, button.window === window, !button.isHidden,
                   self.filesItem?.isVisible == true {
                    let buttonFrame = contentView.convert(button.bounds, from: button)
                    let inset = max(0, contentView.bounds.maxX - buttonFrame.maxX)
                    if abs(self.projectFiles.toolbarTrailingInset - inset) >= 0.5 {
                        self.projectFiles.toolbarTrailingInset = inset
                    }
                }
                if self.sessionHost.window === window, !self.sessionHost.isHidden {
                    // The panel width includes the native toggle and the toolbar's right margin.
                    let hostFrame = contentView.convert(self.sessionHost.bounds, from: self.sessionHost)
                    let inset = max(0, contentView.bounds.maxX - hostFrame.maxX)
                    if abs(self.projectFiles.titlebarHostTrailingInset - inset) >= 0.5 {
                        self.projectFiles.titlebarHostTrailingInset = inset
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
            [Self.headingID, .flexibleSpace, Self.toggleID, .sidebarTrackingSeparator, Self.sessionID, Self.filesID]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            sidebarItems + [.flexibleSpace] + (hasTitlebarContent ? [Self.sessionID] : []) + [Self.filesID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            switch identifier {
            case Self.sessionID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = String(localized: "会话")
                item.view = sessionHost
                item.isBordered = false
                item.visibilityPriority = .high
                sessionHost.isHidden = isLightboxPresented
                return item
            case Self.filesID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                let typography = PikachuTypography(size: fontSize)
                let button = ProjectFilesToolbarButton(frame: NSRect(x: 0, y: 0, width: IconButtonLabel.side,
                                                                       height: typography.titlebarControlHeight))
                let height = button.heightAnchor.constraint(equalToConstant: typography.titlebarControlHeight)
                filesButtonHeight = height
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: IconButtonLabel.side),
                    height
                ])
                button.setButtonType(.toggle)
                button.isBordered = false
                button.focusRingType = .none
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                button.image = filesIcon(typography: typography)
                button.target = self
                button.action = #selector(toggleFiles)
                button.setAccessibilityIdentifier("project-files-toolbar-toggle")
                item.view = button
                item.isBordered = false
                item.target = self
                item.action = #selector(toggleFiles)
                item.visibilityPriority = .user
                filesItem = item
                filesFocus.toolbarButton = button
                updateFilesItem(open: projectFiles.isOpen, blocked: projectFiles.blocked)
                return item
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
                item.paletteLabel = "Pikachu"
                let icon = NSImageView()
                icon.image = NSImage(named: "SidebarBrandMark")
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.setAccessibilityElement(false)
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16)
                ])
                let name = NSTextField(labelWithString: "Pikachu")
                name.font = PikachuTypography(size: fontSize).nsFont(.callout, weight: .semibold)
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
            default:
                return nil // AppKit supplies the standard spacer and tracking separator.
            }
        }

        private func filesIcon(typography: PikachuTypography) -> NSImage? {
            NSImage(systemSymbolName: "inset.filled.rightthird.rectangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: typography.pointSize(for: .callout), weight: .regular))
        }

        private func updateFilesItem(open: Bool, blocked: Bool) {
            let label = open ? String(localized: "关闭项目文件面板") : String(localized: "显示项目文件")
            filesItem?.label = label
            filesItem?.toolTip = label
            filesItem?.isEnabled = !blocked
            if let button = filesFocus.toolbarButton {
                button.state = open ? .on : .off
                button.isEnabled = !blocked
                button.isHidden = isLightboxPresented
                button.setAccessibilityLabel(label)
                button.setAccessibilityExpanded(open)
                button.toolTip = label
                button.needsDisplay = true
            }
        }

        @objc private func toggleFiles() {
            projectFiles.toggle(keyboard: false)
        }

        @objc private func toggleSidebar() {
            visibility.wrappedValue = sidebarVisible ? .detailOnly : .all
        }
    }
}

private final class ProjectFilesToolbarButton: NSButton {
    private var pointerTracking: NSTrackingArea?
    private var hovered = false {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = IconButtonLabel.side
        let feedbackBounds = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let shape = NSBezierPath(roundedRect: feedbackBounds, xRadius: 8, yRadius: 8)
        let fill: Color? = if isEnabled && isHighlighted {
            PikachuTheme.pressed
        } else if state == .on {
            PikachuTheme.selected
        } else if isEnabled && hovered && window?.isKeyWindow == true {
            PikachuTheme.controlHover
        } else {
            nil
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let fill {
                NSColor(fill).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
                shape.fill()
            }
            if isEnabled, window?.firstResponder === self, window?.isKeyWindow == true {
                NSColor(PikachuTheme.focusBorder).setStroke()
                NSBezierPath(roundedRect: feedbackBounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
                    .stroke()
            }
            if let icon = image?.withSymbolConfiguration(.init(paletteColors: [NSColor(PikachuTheme.primaryText)])) {
                let frame = NSRect(x: bounds.midX - icon.size.width / 2, y: bounds.midY - icon.size.height / 2,
                                   width: icon.size.width, height: icon.size.height)
                icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
            }
        }
    }
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
        .pikachuTypography(fontSize)
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(expanded ? Text("已展开") : Text("已折叠"))
    }
}

private struct WindowSessionControls: View {
    let workspace: WorkspaceController
    let gitStore: GitStatusStore
    let projectFiles: ProjectFilesControls
    let filesModel: ProjectFilesModel
    var filesRoot: ProjectFilesRoot?
    var filesWidth: CGFloat
    let filesFocus: ProjectFilesFocusBridge
    var fontSize: InterfaceFontSize
    let createSession: (UUID) -> Void
    let manageSession: (SessionManagementAction, UUID) -> Void

    var body: some View {
        let tabsWidth = projectFiles.isOpen ? max(0, filesWidth - projectFiles.titlebarHostTrailingInset) : nil
        Group {
            if let viewed = workspace.viewed {
                SessionHeader(workspace: workspace, presentation: viewed, gitStore: gitStore,
                              preferredTabsWidth: tabsWidth, createSession: createSession, manageSession: manageSession) {
                    fileTabs
                }
            } else if let tabsWidth {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    fileTabs.frame(maxWidth: tabsWidth)
                }
            }
        }
        .pikachuTypography(fontSize)
        .scrollIndicators(.never)
    }

    private var fileTabs: some View {
        ZStack(alignment: .leading) {
            if filesRoot == filesModel.root, !filesModel.tabs.isEmpty {
                ProjectFilesTabStrip(model: filesModel,
                                     focusDirectory: projectFiles.focusDirectory(keyboard:accessibility:)) {
                    filesFocus.closeFromPane()
                    projectFiles.close()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
