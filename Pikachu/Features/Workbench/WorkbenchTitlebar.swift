import AppKit
import SwiftUI

/// Places the brand before the toolbar separator that follows the sidebar divider.
struct WorkbenchTitlebar: NSViewRepresentable {
    @Binding var sidebarVisibility: NavigationSplitViewVisibility

    func makeCoordinator() -> Coordinator { Coordinator(visibility: $sidebarVisibility) }

    func makeNSView(context: Context) -> WindowAttachment {
        let view = WindowAttachment()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachment, context: Context) {
        context.coordinator.update(visibility: $sidebarVisibility)
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
        private static let brandID = NSToolbarItem.Identifier("PikachuSidebarBrand")
        private static let toggleID = NSToolbarItem.Identifier("PikachuSidebarToggle")

        private let toolbar = NSToolbar(identifier: "PikachuWorkbenchToolbar")
        private weak var window: NSWindow?
        private var visibility: Binding<NavigationSplitViewVisibility>
        private var sidebarVisible: Bool
        private var toggleLabel: String { sidebarVisible ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏") }

        init(visibility: Binding<NavigationSplitViewVisibility>) {
            self.visibility = visibility
            sidebarVisible = visibility.wrappedValue != .detailOnly
            super.init()
            toolbar.delegate = self
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            if let window, window.toolbar === toolbar { window.toolbar = nil }
            window = newWindow
            guard let newWindow else { return }
            newWindow.titleVisibility = .hidden
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.toolbar = toolbar
        }

        func update(visibility: Binding<NavigationSplitViewVisibility>) {
            self.visibility = visibility
            let visible = visibility.wrappedValue != .detailOnly
            guard sidebarVisible != visible else { return }
            sidebarVisible = visible
            guard let toggleIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.toggleID }) else { return }
            let toggle = toolbar.items[toggleIndex]
            // With the split collapsed the toggle belongs in the main toolbar.
            if visible {
                toolbar.insertItem(withItemIdentifier: Self.brandID, at: toggleIndex + 1)
                toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: toggleIndex + 2)
            } else {
                for index in toolbar.items.indices.reversed() where toolbar.items[index].itemIdentifier != Self.toggleID {
                    toolbar.removeItem(at: index)
                }
            }
            toggle.label = toggleLabel
            toggle.toolTip = toggleLabel
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.toggleID, Self.brandID, .sidebarTrackingSeparator]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            sidebarVisible ? toolbarAllowedItemIdentifiers(toolbar) : [Self.toggleID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            switch identifier {
            case Self.toggleID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = toggleLabel
                item.toolTip = toggleLabel
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: toggleLabel)
                item.target = self
                item.action = #selector(toggleSidebar)
                return item
            case Self.brandID:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.label = "Pikachu"
                let icon = NSImageView(image: NSApp.applicationIconImage)
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.setAccessibilityElement(false)
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 18),
                    icon.heightAnchor.constraint(equalToConstant: 18)
                ])
                let name = NSTextField(labelWithString: "Pikachu")
                name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                let brand = NSStackView(views: [icon, name])
                brand.alignment = .centerY
                brand.spacing = 6
                brand.frame.size = brand.fittingSize
                item.view = brand
                return item
            default:
                return nil // AppKit supplies the standard tracking separator.
            }
        }

        @objc private func toggleSidebar() {
            visibility.wrappedValue = sidebarVisible ? .detailOnly : .all
        }
    }
}
