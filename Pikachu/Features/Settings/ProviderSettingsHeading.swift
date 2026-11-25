import AppKit
import ApplicationServices
import SwiftUI

struct ProviderConnectionGroupAnchor: Hashable {
    let runtimeID: String
}

struct ProviderConnectionGroup<Content: View>: View {
    let runtimeID: String
    let request: ProviderConnectionRequest?
    let scroll: ScrollViewProxy
    let consume: (ProviderConnectionRequest) -> Bool
    let title: LocalizedStringResource
    @ViewBuilder let content: (ProviderSettingsHeading) -> Content
    @State private var headingRequest = 0

    var body: some View {
        let anchor = ProviderConnectionGroupAnchor(runtimeID: runtimeID)
        content(ProviderSettingsHeading(title, request: headingRequest))
            .id(anchor)
            .task(id: request) {
                guard !Task.isCancelled, let request, request.runtimeID == runtimeID, consume(request) else { return }
                scroll.scrollTo(anchor, anchor: .top)
                headingRequest = request.sequence
            }
    }
}

struct ProviderSettingsHeading: NSViewRepresentable {
    @Environment(\.pikachuTypography) private var typography
    private let title: LocalizedStringResource
    private let request: Int

    init(_ title: LocalizedStringResource, request: Int) {
        self.title = title
        self.request = request
    }

    func makeNSView(context: Context) -> Heading {
        let heading = Heading(labelWithString: String(localized: title))
        heading.textColor = NSColor(PikachuTheme.primaryText)
        heading.setAccessibilityRole(NSAccessibility.Role(rawValue: kAXHeadingRole as String))
        return heading
    }

    func updateNSView(_ heading: Heading, context: Context) {
        let label = String(localized: title)
        heading.stringValue = label
        heading.setAccessibilityLabel(label)
        heading.font = typography.nsFont(.headline)
        heading.requestFocus(request)
    }

    final class Heading: NSTextField {
        private var requestedFocus = 0
        private var deliveredFocus = 0

        override var acceptsFirstResponder: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            scheduleFocus()
        }

        func requestFocus(_ request: Int) {
            guard requestedFocus != request else { return }
            requestedFocus = request
            scheduleFocus()
        }

        private func scheduleFocus() {
            // SwiftUI may update this view before the sheet's native focus pass.
            DispatchQueue.main.async { [weak self] in self?.deliverFocus() }
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            scheduleFocus()
        }

        private func deliverFocus() {
            guard requestedFocus > deliveredFocus, let window, window.isKeyWindow,
                  window.makeFirstResponder(self), window.firstResponder === self else { return }
            deliveredFocus = requestedFocus
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }
}
