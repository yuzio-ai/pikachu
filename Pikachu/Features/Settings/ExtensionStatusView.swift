import SwiftUI
import OrchestrationCore

struct ExtensionStatusView: View {
    let controller: SessionController
    @State private var expanded = false
    private struct Entry: Identifiable { let id: String; let text: String }
    private var entries: [Entry] { controller.extensionStatus.map { Entry(id: $0.key, text: $0.value) }.sorted { $0.id < $1.id } }
    var body: some View {
        DisclosureGroup("扩展状态", isExpanded: $expanded) {
            ForEach(entries) { entry in Text(entry.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(.caption).padding(8).glassEffect(in: .rect(cornerRadius: 9))
        .padding(.horizontal, 24).padding(.vertical, 4)
    }
}
