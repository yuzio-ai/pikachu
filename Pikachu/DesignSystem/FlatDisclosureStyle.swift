import SwiftUI

struct FlatDisclosureStyle: DisclosureGroupStyle {
    var chevronEdge: HorizontalEdge = .leading

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                let chevron = Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                    .pikachuFont(.micro, weight: .semibold)
                    .foregroundStyle(PikachuTheme.secondaryText)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                HStack(spacing: 7) {
                    if chevronEdge == .leading {
                        chevron
                        configuration.label
                    } else {
                        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                        chevron
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已折叠"))

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
