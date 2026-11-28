import SwiftUI

struct FlatToggleStyle: ToggleStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                if !compact {
                    configuration.label
                    Spacer(minLength: 8)
                }
                Capsule()
                    .fill(configuration.isOn ? ZivviTheme.accentText : ZivviTheme.mutedSurface)
                    .overlay {
                        Capsule().strokeBorder(configuration.isOn ? ZivviTheme.accentText : ZivviTheme.border)
                    }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? ZivviTheme.surface : ZivviTheme.secondaryText)
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: 34, height: 20)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(FlatControlButtonStyle(inset: false))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
