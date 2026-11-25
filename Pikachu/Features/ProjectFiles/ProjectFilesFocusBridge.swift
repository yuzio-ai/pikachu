import AppKit
import SwiftUI

@MainActor
final class ProjectFilesFocusBridge {
    private weak var window: NSWindow?
    private weak var returnResponder: NSResponder?
    weak var toolbarButton: NSButton?
    private var requestsRestore = false
    private var hasCapturedFocus = false

    func capture() {
        hasCapturedFocus = window != nil
        returnResponder = window?.firstResponder
        requestsRestore = false
    }

    func closeFromPane() { requestsRestore = true }

    func clear() {
        returnResponder = nil
        hasCapturedFocus = false
        requestsRestore = false
    }

    func restoreIfNeeded() {
        guard hasCapturedFocus, let window, requestsRestore || window.firstResponder === window.contentView else {
            clear()
            return
        }
        let responder = returnResponder
        clear()
        if let view = responder as? NSView, view.window === window, window.makeFirstResponder(view) { return }
        if let toolbarButton, toolbarButton.window === window { window.makeFirstResponder(toolbarButton) }
    }

    struct Attachment: NSViewRepresentable {
        let bridge: ProjectFilesFocusBridge

        func makeNSView(context: Context) -> WindowView {
            let view = WindowView()
            view.bridge = bridge
            return view
        }

        func updateNSView(_ nsView: WindowView, context: Context) {}

        final class WindowView: NSView {
            weak var bridge: ProjectFilesFocusBridge?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                bridge?.window = window
            }
        }
    }
}
