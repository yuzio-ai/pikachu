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

    func makeCoordinator() -> Coordinator {
        Coordinator(visibility: $sidebarVisibility, workspace: workspace, gitStore: gitStore, fontSize: typography.size)
    }

    func makeNSView(context: Context) -> WindowAttachment {
        let view = WindowAttachment()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachment, context: Context) {
        context.coordinator.update(visibility: $sidebarVisibility, detailWidth: detailWidth, hasSession: hasSession, fontSize: typography.size)
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

        private let toolbar = NSToolbar(identifier: "PikachuWorkbenchToolbar")
        private weak var window: NSWindow?
        private var visibility: Binding<NavigationSplitViewVisibility>
        private var sidebarVisible: Bool
        private var detailWidth: CGFloat = 0
        private var overflowCheckScheduled = false
        private var hasSession: Bool
        private let workspace: WorkspaceController
        private let gitStore: GitStatusStore
        private var fontSize: InterfaceFontSize
        private let sessionHost: NSHostingView<WindowSessionControls>
        private let sessionWidth: NSLayoutConstraint
        private let sessionHeight: NSLayoutConstraint
        private weak var headingLabel: NSTextField?
        private weak var headingStack: NSStackView?
        private weak var toggleHost: NSHostingView<SidebarToggleButton>?
        private var toggleLabel: String { sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏") }

        init(visibility: Binding<NavigationSplitViewVisibility>, workspace: WorkspaceController, gitStore: GitStatusStore, fontSize: InterfaceFontSize) {
            self.visibility = visibility
            self.workspace = workspace
            self.gitStore = gitStore
            self.fontSize = fontSize
            sidebarVisible = visibility.wrappedValue != .detailOnly
            hasSession = workspace.viewed != nil
            let typography = PikachuTypography(size: fontSize)
            let host = NSHostingView(rootView: WindowSessionControls(workspace: workspace, gitStore: gitStore, fontSize: fontSize))
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
            if let window, window.toolbar === toolbar { window.toolbar = nil }
            window = newWindow
            guard let newWindow else { return }
            newWindow.titleVisibility = .hidden
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.toolbarStyle = .unified
            newWindow.titlebarSeparatorStyle = .none
            newWindow.toolbar = toolbar
            toolbar.isVisible = true
        }

        func update(visibility: Binding<NavigationSplitViewVisibility>, detailWidth: CGFloat, hasSession: Bool, fontSize: InterfaceFontSize) {
            self.visibility = visibility
            self.detailWidth = detailWidth
            self.hasSession = hasSession
            if self.fontSize != fontSize {
                self.fontSize = fontSize
                let typography = PikachuTypography(size: fontSize)
                sessionHost.rootView = WindowSessionControls(workspace: workspace, gitStore: gitStore, fontSize: fontSize)
                sessionHeight.constant = typography.titlebarControlHeight
                headingLabel?.font = typography.nsFont(.callout, weight: .semibold)
                if let headingStack {
                    headingStack.invalidateIntrinsicContentSize()
                    headingStack.layoutSubtreeIfNeeded()
                    headingStack.frame.size = headingStack.fittingSize
                }
                toggleHost?.rootView = SidebarToggleButton(title: toggleLabel, fontSize: fontSize) { [weak self] in
                    self?.toggleSidebar()
                }
            }
            let visible = visibility.wrappedValue != .detailOnly
            let sidebarChanged = sidebarVisible != visible
            sidebarVisible = visible
            let sessionWidthChanged = sizeSessionItem()

            guard !toolbar.items.isEmpty else { return }
            if sidebarChanged {
                for index in toolbar.items.indices.reversed() where toolbar.items[index].itemIdentifier != Self.sessionID {
                    toolbar.removeItem(at: index)
                }
                for (index, identifier) in sidebarItems.enumerated() {
                    toolbar.insertItem(withItemIdentifier: identifier, at: index)
                }
            }
            let sessionIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.sessionID }
            if hasSession, sessionIndex == nil {
                toolbar.insertItem(withItemIdentifier: Self.sessionID, at: toolbar.items.count)
            } else if !hasSession, let sessionIndex {
                toolbar.removeItem(at: sessionIndex)
            } else if hasSession, sessionWidthChanged || sidebarChanged {
                scheduleRecoveryFromOverflow()
            }
        }

        private func sizeSessionItem() -> Bool {
            guard detailWidth > 0 else { return false }
            // The detail measurement excludes the sidebar; leave room for the toolbar insets.
            // With the sidebar closed the traffic lights and toggle also share this width.
            let width = floor(max(150, detailWidth - (sidebarVisible ? 32 : 152)))
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
                guard self.window?.toolbar === self.toolbar, self.hasSession,
                      self.toolbar.visibleItems?.contains(where: { $0.itemIdentifier == Self.sessionID }) == false,
                      let index = self.toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.sessionID }) else { return }
                // An overflowed item is detached, so AppKit may still be using its pre-resize width.
                // Re-register the item at its new size while keeping the same session host.
                self.toolbar.removeItem(at: index)
                self.toolbar.insertItem(withItemIdentifier: Self.sessionID, at: index)
            }
        }

        private var sidebarItems: [NSToolbarItem.Identifier] {
            sidebarVisible ? [Self.headingID, .flexibleSpace, Self.toggleID, .sidebarTrackingSeparator] : [Self.toggleID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.headingID, .flexibleSpace, Self.toggleID, .sidebarTrackingSeparator, Self.sessionID]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            sidebarItems + (hasSession ? [Self.sessionID] : [])
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
                return item
            case Self.toggleID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = toggleLabel
                item.toolTip = toggleLabel
                item.target = self
                item.action = #selector(toggleSidebar)
                let toggle = NSHostingView(rootView: SidebarToggleButton(title: toggleLabel, fontSize: fontSize) { [weak self] in
                    self?.toggleSidebar()
                })
                toggleHost = toggle
                toggle.sizingOptions = []
                NSLayoutConstraint.activate([
                    toggle.widthAnchor.constraint(equalToConstant: IconButtonLabel.side),
                    toggle.heightAnchor.constraint(equalToConstant: IconButtonLabel.side)
                ])
                toggle.frame.size = .init(width: IconButtonLabel.side, height: IconButtonLabel.side)
                item.view = toggle
                item.isBordered = false
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
                return item
            default:
                return nil // AppKit supplies the standard spacer and tracking separator.
            }
        }

        @objc private func toggleSidebar() {
            visibility.wrappedValue = sidebarVisible ? .detailOnly : .all
        }
    }
}

private struct SidebarToggleButton: View {
    let title: String
    let fontSize: InterfaceFontSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconButtonLabel(systemName: "sidebar.left")
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .pikachuTypography(fontSize)
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
    }
}

private struct WindowSessionControls: View {
    let workspace: WorkspaceController
    let gitStore: GitStatusStore
    let fontSize: InterfaceFontSize

    var body: some View {
        if let viewed = workspace.viewed {
            SessionHeader(workspace: workspace, presentation: viewed, gitStore: gitStore)
                .id(viewed.id)
                .padding(.horizontal, 2)
                .pikachuTypography(fontSize)
        }
    }
}
