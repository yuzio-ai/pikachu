import SwiftUI

struct FlatControlButtonStyle: ButtonStyle {
    enum Treatment {
        case quiet, outlined, prominent
    }

    var treatment: Treatment = .quiet
    var isOpen = false
    var inset = true
    var cornerRadius: CGFloat = 8
    var height: CGFloat? = nil
    var outlineColor: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fill: Color = if isEnabled && configuration.isPressed {
            PikachuTheme.pressed
        } else if isOpen {
            PikachuTheme.selected
        } else if isEnabled && isHovered {
            treatment == .prominent ? PikachuTheme.prominentControlHover : PikachuTheme.controlHover
        } else if treatment == .prominent {
            PikachuTheme.selected
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
            .padding(.vertical, inset && height == nil ? 5 : 0)
            .frame(height: height)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(outlineColor ?? outline, lineWidth: 1).allowsHitTesting(false) }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
