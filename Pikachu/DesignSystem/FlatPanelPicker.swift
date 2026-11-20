import SwiftUI

struct FlatPanelPicker<Selection: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Selection
    let options: [Selection]
    var detail: LocalizedStringKey? = nil
    let optionTitle: (Selection) -> Text
    @State private var showsOptions = false

    var body: some View {
        let selectedTitle = optionTitle(selection)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).pikachuFont(.body, weight: .semibold)
                    .accessibilityHidden(true)
                if let detail {
                    Text(detail).pikachuFont(.callout).foregroundStyle(PikachuTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)

            FlatMenu(width: 176, triggerTreatment: .outlined, presentation: $showsOptions) {
                HStack(spacing: 8) {
                    selectedTitle.lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    FlatDisclosureChevron(.down)
                }
                .foregroundStyle(PikachuTheme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 156)
            } content: { select in
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button { select { selection = option } } label: {
                        FlatMenuRow(title: optionTitle(option), selected: selected)
                    }
                    .buttonStyle(FlatControlButtonStyle(isOpen: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text("\(selectedTitle)，\(showsOptions ? Text("已展开") : Text("已折叠"))"))
        }
    }
}
