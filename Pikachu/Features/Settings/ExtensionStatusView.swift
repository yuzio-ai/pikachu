import SwiftUI
import OrchestrationCore

struct ExtensionStatusView: View {
    let controller: SessionController
    let viewportHeight: CGFloat
    @Binding var expanded: Bool
    private struct Entry: Identifiable { let id: String; let text: String }
    private var entries: [Entry] { controller.extensionStatus.map { Entry(id: $0.key, text: $0.value) }.sorted { $0.id < $1.id } }
    var body: some View {
        DisclosureGroup("扩展状态", isExpanded: $expanded) {
            ViewThatFits(in: .vertical) {
                statusRows
                ScrollView { statusRows }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: min(180, viewportHeight / 4))
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
        .pikachuFont(.caption).padding(8).flatSurface(PikachuTheme.mutedSurface, radius: 9)
        .padding(.horizontal, 24).padding(.vertical, 4)
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                Text(entry.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
