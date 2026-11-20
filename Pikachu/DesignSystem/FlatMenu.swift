import SwiftUI

struct FlatMenu<Label: View, Content: View>: View {
    var width: CGFloat = 200
    var arrowEdge: Edge = .bottom
    var triggerTreatment: FlatControlButtonStyle.Treatment = .quiet
    var presentation: Binding<Bool>? = nil
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: (_ select: @escaping (@escaping () -> Void) -> Void) -> Content
    @State private var isOpen = false
    @State private var selectedAction: (() -> Void)?

    var body: some View {
        let presented = presentation ?? $isOpen
        Button { presented.wrappedValue.toggle() } label: { label() }
            .buttonStyle(FlatControlButtonStyle(treatment: triggerTreatment, isOpen: presented.wrappedValue, inset: false))
            .popover(isPresented: presented, arrowEdge: arrowEdge) {
                FlatMenuPanel(width: width) {
                    content { action in
                        guard presented.wrappedValue else { return }
                        selectedAction = action
                        presented.wrappedValue = false
                    }
                }
                .onExitCommand { presented.wrappedValue = false }
                .onDisappear {
                    let action = selectedAction
                    selectedAction = nil
                    action?()
                }
            }
    }
}

struct FlatMenuPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3, content: content)
            .pikachuFont(.callout)
            .buttonStyle(FlatControlButtonStyle())
            .padding(6)
            .frame(width: width, alignment: .leading)
            .flatPanelContent()
            .presentationBackground(PikachuTheme.surface)
            .focusSection()
    }
}

struct FlatMenuRow: View {
    let title: Text
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            title.multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .pikachuFont(.caption, weight: .semibold)
                    .foregroundStyle(PikachuTheme.accentText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }
}
