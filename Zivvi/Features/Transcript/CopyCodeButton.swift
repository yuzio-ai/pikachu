import AppKit
import SwiftUI

struct CopyCodeButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            LightningLabel("复制", icon: .docOnDoc, size: 12)
                .zivviFont(.caption)
                .fixedSize()
        }
        .buttonStyle(FlatControlButtonStyle())
        .help("复制代码")
        .accessibilityLabel("复制代码")
    }
}
