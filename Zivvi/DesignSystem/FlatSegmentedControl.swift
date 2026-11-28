import SwiftUI

struct FlatSegmentedControl<Value: Hashable, Segment: View>: View {
    let title: LocalizedStringKey
    let values: [Value]
    @Binding var selection: Value
    var readOnly = false
    @ViewBuilder let segment: (Value) -> Segment
    @FocusState private var focus: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                if readOnly {
                    segmentLabel(value)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .flatSurface(radius: 6)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Button { selection = value } label: { segmentLabel(value) }
                        .buttonStyle(FlatControlButtonStyle(treatment: value == selection ? .outlined : .quiet,
                                                           isSelected: value == selection, selectedFill: ZivviTheme.surface,
                                                           hasKeyboardFocus: value == focus,
                                                           cornerRadius: 6))
                        .focused($focus, equals: value)
                        .accessibilityAddTraits(value == selection ? .isSelected : [])
                }
            }
        }
        .padding(2)
        .background(ZivviTheme.mutedSurface, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .onMoveCommand { direction in
            guard let focus, let index = values.firstIndex(of: focus) else { return }
            let next: Int
            switch direction {
            case .left: next = index - 1
            case .right: next = index + 1
            default: return
            }
            guard values.indices.contains(next) else { return }
            selection = values[next]
            self.focus = values[next]
        }
    }

    private func segmentLabel(_ value: Value) -> some View {
        segment(value)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 26, maxWidth: .infinity, minHeight: 20)
    }
}
