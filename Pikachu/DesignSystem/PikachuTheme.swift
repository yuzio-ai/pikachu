import AppKit
import SwiftUI

enum PikachuTheme {
    static let workspace = adaptive(light: 0xFBFBFB, dark: 0x181818)
    static let sidebar = adaptive(light: 0xF4F4F4, dark: 0x202020)
    static let sidebarRowHover = adaptive(light: 0xFAFAFA, dark: 0x272727)
    static let sidebarRowSelected = adaptive(light: 0xFFFFFF, dark: 0x303030)
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
    static let infoText = adaptive(light: 0x245E9E, dark: 0x91BEF8)
    static let draftText = adaptive(light: 0x6844A5, dark: 0xC5AAFA)
    static let sidebarWarningDot = adaptive(light: 0xAC5B00, dark: 0xFFB020)
    static let sidebarRunningDot = adaptive(light: 0x008052, dark: 0x35DB91)
    static let sidebarUnreadDot = adaptive(light: 0x0068D9, dark: 0x65B3FF)
    static let lightningYellow = Color(nsColor: rgb(0xF0B524))

    private static let primaryTextColor = adaptiveNSColor(light: 0x222222, dark: 0xF2F2F2)
    private static let scrollbarThumb = adaptiveNSColor(light: 0x929292, dark: 0x797979)
    private static let activeScrollbarThumb = adaptiveNSColor(light: 0x666666, dark: 0xAAAAAA)

    private static let projectTints = [
        infoText, // blue
        draftText, // violet
        adaptive(light: 0x96396C, dark: 0xF2A3CC), // pink
        adaptive(light: 0xA03636, dark: 0xF6A5A5), // red
        adaptive(light: 0x884712, dark: 0xF3B47D), // orange
        adaptive(light: 0x745600, dark: 0xE7C665), // gold
        adaptive(light: 0x38652D, dark: 0xA9CE90), // green
        adaptive(light: 0x14645F, dark: 0x82CEC4), // teal
    ]

    static func projectTint(id: UUID) -> Color {
        // Use a random byte from the persisted ID so the tint never changes on redraw or rename.
        projectTints[Int(id.uuid.0) % projectTints.count]
    }

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

/// Visual defaults shared by the mouse-transparent preview and interactive popovers.
enum AnchoredCardStyle {
    static let cornerRadius: CGFloat = 8
    static let inset: CGFloat = 12
    static let compactInset: CGFloat = 6
    static let spacing: CGFloat = 7
}

extension View {
    func anchoredCardTitle() -> some View {
        pikachuFont(.callout, weight: .medium)
            .foregroundStyle(PikachuTheme.primaryText)
    }

    /// Leave the outer outline, arrow and shadow to the native popover rather than drawing a second card inside it.
    func anchoredPopoverCard(width: CGFloat, inset: CGFloat = AnchoredCardStyle.inset) -> some View {
        pikachuFont(.callout)
            .padding(inset)
            .frame(width: width, alignment: .leading)
            .flatPanelContent()
            .presentationBackground(PikachuTheme.surface)
            .presentationCornerRadius(AnchoredCardStyle.cornerRadius)
    }

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
