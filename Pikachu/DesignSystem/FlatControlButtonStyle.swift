import SwiftUI

struct FlatControlButtonStyle: ButtonStyle {
    enum Treatment {
        case quiet, outlined, prominent
    }

    var treatment: Treatment = .quiet
    var isOpen = false
    var inset = true
    var cornerRadius: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fill: Color = if isEnabled && configuration.isPressed {
            PikachuTheme.pressed
        } else if isOpen || treatment == .prominent {
            PikachuTheme.selected
        } else if isEnabled && isHovered {
            PikachuTheme.hover
        } else if treatment == .outlined {
            PikachuTheme.surface
        } else {
            .clear
        }
        let outline: Color = switch treatment {
        case .quiet: .clear
        case .outlined: PikachuTheme.border
        case .prominent: PikachuTheme.selectionBorder
        }
        let foreground: Color = if treatment == .prominent {
            PikachuTheme.accentText
        } else if configuration.role == .destructive {
            PikachuTheme.errorText
        } else {
            PikachuTheme.primaryText
        }

        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, inset ? 8 : 0)
            .padding(.vertical, inset ? 5 : 0)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(outline, lineWidth: 1).allowsHitTesting(false) }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
