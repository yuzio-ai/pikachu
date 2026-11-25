import SwiftUI

extension EnvironmentValues {
    @Entry var settingsCompactRows = false
}

struct SettingsControlRow<Title: View, Control: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let control: () -> Control
    @Environment(\.settingsCompactRows) private var compact

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            title().frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
}

struct FlatPanelPicker<Selection: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Selection
    let options: [Selection]
    var detail: LocalizedStringKey? = nil
    var maximumMenuHeight: CGFloat? = nil
    let optionTitle: (Selection) -> Text
    @State private var showsOptions = false

    var body: some View {
        let selectedTitle = optionTitle(selection)
        SettingsControlRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).pikachuFont(.body)
                    .accessibilityHidden(true)
                if let detail {
                    Text(detail).pikachuFont(.callout).foregroundStyle(PikachuTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } control: {
            FlatMenu(width: 176, triggerTreatment: .outlined, restoresTriggerFocus: true, presentation: $showsOptions) {
                HStack(spacing: 8) {
                    selectedTitle.lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    FlatDisclosureChevron(.down)
                }
                .foregroundStyle(PikachuTheme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 156)
            } content: { select in
                FlatMenuItems(items: options.map { option in
                    FlatMenuItem(id: option, title: optionTitle(option), selected: option == selection) {
                        select { selection = option }
                    }
                }, maximumHeight: maximumMenuHeight)
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text("\(selectedTitle)，\(showsOptions ? Text("已展开") : Text("已折叠"))"))
        }
    }
}
