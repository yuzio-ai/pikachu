import SwiftUI

struct FlatEmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text
    let iconColor: Color
    let actions: Actions

    init(_ title: LocalizedStringKey, systemImage: String, description: Text,
         iconColor: Color = ZivviTheme.iconYellow, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.iconColor = iconColor
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            LightningIconView(systemName: systemImage, size: 20, tint: ZivviTheme.iconYellow)
                .frame(width: 42, height: 42)
                .flatSurface(ZivviTheme.mutedSurface, radius: 10)
            Text(title)
                .zivviFont(.title3, weight: .semibold)
                .foregroundStyle(ZivviTheme.primaryText)
                .accessibilityAddTraits(.isHeader)
            description
                .zivviFont(.callout)
                .foregroundStyle(ZivviTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
