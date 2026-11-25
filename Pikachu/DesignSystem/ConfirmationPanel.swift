import AppKit
import SwiftUI

/// Hosts a shared confirmation dialog in a titled panel with a transparent titlebar.
@MainActor
enum ConfirmationPanel {
    static func make<Content: View>(rootView: Content) -> NSPanel {
        let host = NSHostingView(rootView: rootView.scrollIndicators(.never))
        // A transparent titlebar otherwise reserves its full height inside the hosting view,
        // leaving an empty band above the content that makes the dialog look top-heavy.
        host.safeAreaRegions = []
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Pikachu"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PikachuTheme.pageBackgroundColor
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        return panel
    }
}
