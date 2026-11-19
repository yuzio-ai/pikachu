import AppKit
import SwiftUI

struct CopyCodeButton: NSViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator(text:text) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title:String(localized:"复制"),target:context.coordinator,action:#selector(Coordinator.copyCode))
        button.image = NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:nil)
        button.imagePosition = .imageLeading; button.bezelStyle = .glass
        button.font = .systemFont(ofSize:NSFont.smallSystemFontSize)
        button.setAccessibilityLabel(String(localized:"复制代码")); button.toolTip = String(localized:"复制代码")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.text = text }
    @MainActor final class Coordinator: NSObject {
        var text: String
        init(text: String) { self.text = text }
        @objc func copyCode() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
    }
}
