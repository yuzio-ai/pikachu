import SwiftUI

struct FlatControlButtonStyle: ButtonStyle {
    enum Treatment {
        case quiet, outlined, prominent
    }

    var treatment: Treatment = .quiet
    var isOpen = false
    var isSelected = false
    var selectedFill = ZivviTheme.selected
    var hasKeyboardFocus = false
    var inset = true
    var cornerRadius: CGFloat = 8
    var height: CGFloat? = nil
    var minimumWidth: CGFloat? = nil
    var outlineColor: Color? = nil
    var restingForegroundColor: Color? = nil
    var showsHoverBackground = true
    var showsPressedBackground = true
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fill: Color = if showsPressedBackground && isEnabled && configuration.isPressed {
            ZivviTheme.pressed
        } else if isOpen {
            ZivviTheme.selected
        } else if isSelected {
            selectedFill
        } else if showsHoverBackground && isEnabled && isHovered {
            treatment == .prominent ? ZivviTheme.prominentControlHover : ZivviTheme.controlHover
        } else if treatment == .prominent {
            ZivviTheme.selected
        } else if treatment == .outlined {
            ZivviTheme.surface
        } else {
            .clear
        }
        let outline: Color = switch treatment {
        case .quiet: .clear
        case .outlined: ZivviTheme.border
        case .prominent: ZivviTheme.selectionBorder
        }
        let foreground: Color = if treatment == .prominent {
            ZivviTheme.accentText
        } else if configuration.role == .destructive {
            ZivviTheme.errorText
        } else if let restingForegroundColor, !isEnabled || !isHovered {
            restingForegroundColor
        } else {
            ZivviTheme.primaryText
        }

        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, inset ? 8 : 0)
            .padding(.vertical, inset && height == nil ? 5 : 0)
            .frame(minWidth: minimumWidth)
            .frame(height: height)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(isEnabled && hasKeyboardFocus ? ZivviTheme.focusBorder : outlineColor ?? outline,
                                   lineWidth: 1).allowsHitTesting(false)
            }
            .contentShape(shape)
            .focusEffectDisabled(hasKeyboardFocus)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
