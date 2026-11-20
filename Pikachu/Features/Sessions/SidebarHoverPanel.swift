import AppKit
import SwiftUI

/// A delayed, mouse-transparent preview that can extend past the sidebar without taking focus.
struct SidebarHoverPanel<Content: View>: NSViewRepresentable {
    let active: Bool
    let content: Content

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.update(active: active, content: content)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.dismiss()
    }

    final class Anchor: NSView {
        private var active = false
        private var content: Content?
        private var pending: Task<Void, Never>?
        private var monitor: Any?
        private var panel: NSPanel?
        private var host: NSHostingView<Content>?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                dismiss()
                active = false
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func update(active: Bool, content: Content) {
            self.content = content
            if let host, let panel, let window {
                host.rootView = content
                position(panel, size: host.fittingSize, in: window)
            }
            guard self.active != active else { return }
            self.active = active
            dismiss()
            guard active, let window, window.isKeyWindow else { return }

            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.dismiss() }
                return event
            }
            pending = Task { [weak self] in
                try? await Task.sleep(for: AnchoredCardStyle.hoverDelay)
                guard !Task.isCancelled else { return }
                self?.show()
            }
        }

        @objc private func windowChanged(_ notification: Notification) { dismiss() }

        func dismiss() {
            pending?.cancel()
            pending = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            host = nil
        }

        private func show() {
            guard let content, let window, window.isKeyWindow,
                  visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
                dismiss()
                return
            }
            let host = NSHostingView(rootView: content)
            host.appearance = effectiveAppearance
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.contentView = host
            self.host = host
            self.panel = panel
            position(panel, size: host.fittingSize, in: window)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }

        private func position(_ panel: NSPanel, size: NSSize, in window: NSWindow) {
            let row = window.convertToScreen(convert(bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? row.insetBy(dx: -size.width, dy: -size.height)
            panel.setFrame(SidebarHoverPanelPlacement.frame(for: size, beside: row, within: screen), display: true)
        }
    }
}

enum SidebarHoverPanelPlacement {
    static func frame(for size: CGSize, beside row: CGRect, within screen: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let right = row.maxX + margin
        let left = row.minX - size.width - margin
        let preferredX = right + size.width <= screen.maxX - margin || left < screen.minX + margin ? right : left
        return CGRect(x: max(screen.minX + margin, min(preferredX, screen.maxX - size.width - margin)),
                      y: max(screen.minY + margin, min(row.maxY - size.height, screen.maxY - size.height - margin)),
                      width: size.width, height: size.height)
    }
}
