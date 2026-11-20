import SwiftUI

extension View {
    /// Keep the action's slot and keyboard focus target, but never let an unseen action intercept a click.
    func revealedAction(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

/// For thumbnails and branded buttons whose own fill must stay visible.
struct OverlayFeedbackButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let opacity = !isEnabled ? 0 : configuration.isPressed ? 0.16 : isHovered ? 0.08 : 0
        configuration.label
            .overlay { shape.fill(PikachuTheme.primaryText.opacity(opacity)).allowsHitTesting(false) }
            .onHover { isHovered = $0 }
    }
}
