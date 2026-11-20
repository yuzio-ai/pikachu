import AppKit
import SwiftUI

enum PikachuTheme {
    static let workspace = adaptive(light: 0xFBFBFB, dark: 0x181818)
    static let sidebar = adaptive(light: 0xF4F4F4, dark: 0x202020)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x242424)
    static let mutedSurface = adaptive(light: 0xF2F2F2, dark: 0x2B2B2B)
    static let border = adaptive(light: 0xDADADA, dark: 0x484848)
    static let subtleDivider = adaptive(light: 0xE7E7E7, dark: 0x343434)
    static let primaryText = Color(nsColor: primaryTextColor)
    static let secondaryText = adaptive(light: 0x606060, dark: 0xBDBDBD)
    static let tertiaryText = adaptive(light: 0x6E6E6E, dark: 0xA0A0A0)
    static let selected = adaptive(light: 0xE8E8E8, dark: 0x363636)
    static let messageBubble = adaptive(light: 0xEEEEEE, dark: 0x303030)
    static let selectionBorder = adaptive(light: 0x858585, dark: 0x888888)
    static let focusBorder = adaptive(light: 0x6C6C6C, dark: 0xA0A0A0)
    static let accentText = adaptive(light: 0x444444, dark: 0xDEDEDE)
    static let hover = adaptive(light: 0xEEEEEE, dark: 0x2C2C2C)
    static let pressed = adaptive(light: 0xDFDFDF, dark: 0x404040)
    static let warningText = adaptive(light: 0x805300, dark: 0xF0BB65)
    static let mutedWarningText = adaptive(light: 0x8F6633, dark: 0xD9AD70)
    static let warningSurface = adaptive(light: 0xF5E8CD, dark: 0x423422)
    static let errorText = adaptive(light: 0xAC343F, dark: 0xF38E97)
    static let runningText = adaptive(light: 0x226B51, dark: 0x7AC9A6)
    static let lightningYellow = Color(nsColor: rgb(0xF0B524))

    private static let primaryTextColor = adaptiveNSColor(light: 0x222222, dark: 0xF2F2F2)
    private static let scrollbarThumb = adaptiveNSColor(light: 0x929292, dark: 0x797979)
    private static let activeScrollbarThumb = adaptiveNSColor(light: 0x666666, dark: 0xAAAAAA)

    static func inputBorder(focused: Bool) -> Color {
        focused ? focusBorder : border
    }

    static func scrollbarThumbColor(active: Bool, increasedContrast: Bool) -> NSColor {
        if increasedContrast { return primaryTextColor }
        return active ? activeScrollbarThumb : scrollbarThumb
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    private static func adaptiveNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

/// Shared by the SwiftUI composer and AppKit transcript without constraining either viewport.
enum WorkbenchReadingColumn {
    static let maximumWidth: CGFloat = 800
    static let minimumGutter: CGFloat = 24

    static func width(in viewport: CGFloat) -> CGFloat {
        min(maximumWidth, max(0, viewport - 2 * minimumGutter))
    }

    static func inset(in viewport: CGFloat) -> CGFloat {
        max(0, (viewport - width(in: viewport)) / 2)
    }
}

extension View {
    func flatPanelContent() -> some View {
        foregroundStyle(PikachuTheme.primaryText, PikachuTheme.secondaryText)
            .background(PikachuTheme.surface)
    }

    func flatSurface(_ fill: Color = PikachuTheme.surface, radius: CGFloat = 8,
                     border: Color = PikachuTheme.border) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
    }

    func flatInputSurface() -> some View {
        modifier(FlatInputSurface())
    }
}

private struct FlatInputSurface: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .flatSurface(PikachuTheme.workspace, border: PikachuTheme.inputBorder(focused: focused))
    }
}

struct PikachuDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle().fill(PikachuTheme.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}
