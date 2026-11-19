import SwiftUI

struct ComposerControlSurface: ViewModifier {
    let isOpen: Bool
    let isEnabled: Bool
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        if isOpen {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
        if isHovered && isEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
        }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(backgroundColor, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct ComposerControlButtonStyle: ButtonStyle {
    let isOpen: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = {
            if !isEnabled { return .clear }
            if isOpen {
                return Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.13)
            }
            if configuration.isPressed {
                return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.11)
            }
            if isHovered {
                return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
            }
            return .clear
        }()

        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
