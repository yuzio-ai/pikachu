import SwiftUI

struct FlatEmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text
    let iconColor: Color
    let actions: Actions

    init(_ title: LocalizedStringKey, systemImage: String, description: Text,
         iconColor: Color = PikachuTheme.accentText, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.iconColor = iconColor
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .pikachuFont(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 42, height: 42)
                .flatSurface(PikachuTheme.mutedSurface, radius: 10)
                .accessibilityHidden(true)
            Text(title)
                .pikachuFont(.title3, weight: .semibold)
                .foregroundStyle(PikachuTheme.primaryText)
                .accessibilityAddTraits(.isHeader)
            description
                .pikachuFont(.callout)
                .foregroundStyle(PikachuTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
