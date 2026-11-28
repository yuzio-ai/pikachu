import AppKit
import SwiftUI

enum ZivviTheme {
    static let workspace = adaptive(light: 0xFBFBFB, dark: 0x181818)
    static let pageBackgroundColor = adaptiveNSColor(light: 0xF4F4F4, dark: 0x202020)
    static let pageBackground = Color(nsColor: pageBackgroundColor)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x242424)
    static let mutedSurface = adaptive(light: 0xF2F2F2, dark: 0x2B2B2B)
    static let border = adaptive(light: 0xDADADA, dark: 0x484848)
    static let subtleDivider = adaptive(light: 0xE7E7E7, dark: 0x343434)
    static let primaryText = Color(nsColor: primaryTextColor)
    static let secondaryText = adaptive(light: 0x606060, dark: 0xBDBDBD)
    static let tertiaryText = adaptive(light: 0x6E6E6E, dark: 0xA0A0A0)
    static let selected = adaptive(light: 0xE8E8E8, dark: 0x363636)
    static let userMessageSurface = adaptive(light: 0xEEEEEE, dark: 0x303030)
    static let selectionBorder = adaptive(light: 0x858585, dark: 0x888888)
    static let focusBorder = adaptive(light: 0x6C6C6C, dark: 0xA0A0A0)
    static let accentText = adaptive(light: 0x444444, dark: 0xDEDEDE)
    static let controlHover = adaptive(light: 0xEEEEEE, dark: 0x2C2C2C)
    static let prominentControlHover = adaptive(light: 0xE2E2E2, dark: 0x3B3B3B)
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
    static let diffAdditionColor = adaptiveNSColor(light: 0x226B51, dark: 0x7AC9A6)
    static let diffDeletionColor = adaptiveNSColor(light: 0xAC343F, dark: 0xF38E97)
    static let diffAdditionBackgroundColor = adaptiveNSColor(light: 0x226B51, dark: 0x7AC9A6, alpha: 0.10)
    static let diffDeletionBackgroundColor = adaptiveNSColor(light: 0xAC343F, dark: 0xF38E97, alpha: 0.10)
    static let diffAddition = Color(nsColor: diffAdditionColor)
    static let diffDeletion = Color(nsColor: diffDeletionColor)
    static let brandYellow = Color(nsColor: rgb(0xFFCC00))
    static let lightningYellow = brandYellow
    static let iconYellowColor = adaptiveNSColor(light: 0xA87900, dark: 0xFFD22B)
    static let iconYellow = Color(nsColor: iconYellowColor)
    static let iconYellowHoverSurface = iconYellow.opacity(0.10)
    static let iconYellowSelectedSurface = iconYellow.opacity(0.16)
    static let brandBadgeText = Color(nsColor: darkInk)

    private static let darkInk = rgb(0x222222)
    private static let primaryTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0xF2F2F2) : darkInk
    }

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
        return primaryTextColor.withAlphaComponent(active ? 0.38 : 0.18)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    private static func adaptiveNSColor(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: alpha)
        }
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
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
    static let inset = ZivviSpacing.contentInset
    static let compactInset: CGFloat = 6
    static let spacing: CGFloat = 7
    static let hoverDelay: Duration = .milliseconds(500)
}

extension View {
    func anchoredPreviewCard() -> some View {
        padding(AnchoredCardStyle.inset)
            .flatSurface(radius: AnchoredCardStyle.cornerRadius)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    func anchoredCardTitle() -> some View {
        zivviFont(.callout, weight: .medium)
            .foregroundStyle(ZivviTheme.primaryText)
    }

    /// Leave the outer outline, arrow and shadow to the native popover rather than drawing a second card inside it.
    func anchoredPopoverCard(width: CGFloat, inset: CGFloat = AnchoredCardStyle.inset,
                             background: Color = ZivviTheme.pageBackground) -> some View {
        zivviFont(.callout)
            .padding(inset)
            .frame(width: width, alignment: .leading)
            .anchoredPopoverSurface(background: background)
    }

    func anchoredAdaptivePopoverCard(minWidth: CGFloat, maxWidth: CGFloat, inset: CGFloat = AnchoredCardStyle.inset,
                                     background: Color = ZivviTheme.pageBackground) -> some View {
        zivviFont(.callout)
            .padding(inset)
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
            .anchoredPopoverSurface(background: background)
    }

    private func anchoredPopoverSurface(background: Color) -> some View {
        flatPanelContent(background: background)
            .presentationBackground(background)
            .presentationCornerRadius(AnchoredCardStyle.cornerRadius)
    }

    func flatPanelContent(background: Color = ZivviTheme.pageBackground) -> some View {
        foregroundStyle(ZivviTheme.primaryText, ZivviTheme.secondaryText)
            .background(background)
    }

    func flatSurface(_ fill: Color = ZivviTheme.surface, radius: CGFloat = 8,
                     border: Color = ZivviTheme.border) -> some View {
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
            .flatSurface(ZivviTheme.workspace, border: ZivviTheme.inputBorder(focused: focused))
    }
}

enum ZivviSpacing {
    static let contentInset: CGFloat = 12
    static let dialogLabelGap: CGFloat = 4
    static let dialogItemGap: CGFloat = 8
    static let dialogSectionGap: CGFloat = 16
    static let menuItemGap: CGFloat = 3
    static let messageGroup: CGFloat = 32
    static let messageAfterUserGroup: CGFloat = 16
    static let timelineRowInset: CGFloat = 3
    static let timelineRowGap: CGFloat = 4
}

struct UserMessageBrandBadge: View {
    static let cornerRadius: CGFloat = 7
    static let strokeWidth: CGFloat = 2.5
    static let leadingOffset: CGFloat = 14
    static let horizontalPadding: CGFloat = 8

    @Environment(\.zivviTypography) private var typography
    let text: String

    static func height(for typography: ZivviTypography) -> CGFloat {
        max(22, ceil(typography.pointSize(for: .caption) + 10.5))
    }

    static func topOverhang(for typography: ZivviTypography) -> CGFloat {
        ceil(height(for: typography) / 2 + strokeWidth)
    }

    static func bubbleTopInset(for typography: ZivviTypography) -> CGFloat {
        max(16, topOverhang(for: typography) + 2)
    }

    static func minimumBubbleWidth(for typography: ZivviTypography) -> CGFloat {
        let baseFont = typography.nsFont(.caption, weight: .semibold)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let textWidth = ceil((BrandCopy.userMessage as NSString).size(withAttributes: [.font: italicFont]).width)
        let badgeWidth = textWidth + 2 * horizontalPadding
        return max(72, badgeWidth + leadingOffset + UserMessageSurface.cornerRadius)
    }

    var body: some View {
        let height = Self.height(for: typography)
        let innerShape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let outerShape = RoundedRectangle(cornerRadius: Self.cornerRadius + Self.strokeWidth, style: .continuous)
        Text(verbatim: text)
            .italic()
            .zivviFont(.caption, weight: .semibold)
            .foregroundStyle(ZivviTheme.brandBadgeText)
            .fixedSize()
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: height)
            .background(ZivviTheme.lightningYellow, in: innerShape)
            .background {
                outerShape
                    .fill(ZivviTheme.pageBackground)
                    .padding(-Self.strokeWidth)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct UserMessageSurface: ViewModifier {
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 12
    static let bottomInset: CGFloat = 13
    static let cornerRadius: CGFloat = 12

    @Environment(\.zivviTypography) private var typography
    @Environment(\.colorSchemeContrast) private var contrast
    var isVisible = true
    var reservesTopBadgeInset = false
    var maxWidth: CGFloat? = nil

    private var resolvedHorizontalInset: CGFloat {
        guard isVisible else { return 0 }
        guard let maxWidth else { return Self.horizontalInset }
        return min(Self.horizontalInset, max(0, floor((maxWidth - 1) / 2)))
    }

    private var resolvedTopInset: CGFloat {
        guard isVisible else { return 0 }
        guard reservesTopBadgeInset else { return Self.verticalInset }
        return UserMessageBrandBadge.bubbleTopInset(for: typography)
    }

    private var resolvedBottomInset: CGFloat {
        guard isVisible else { return 0 }
        return reservesTopBadgeInset ? Self.bottomInset : Self.verticalInset
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content
            .padding(.horizontal, resolvedHorizontalInset)
            .padding(.top, resolvedTopInset)
            .padding(.bottom, resolvedBottomInset)
            .background(isVisible ? ZivviTheme.userMessageSurface : .clear, in: shape)
            .overlay {
                if isVisible && contrast == .increased {
                    shape.strokeBorder(ZivviTheme.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct ZivviDivider: View {
    @Environment(\.pixelLength) private var pixelLength
    var axis: Axis = .horizontal
    var color = ZivviTheme.border

    var body: some View {
        Rectangle().fill(color)
            .frame(width: axis == .vertical ? pixelLength : nil, height: axis == .horizontal ? pixelLength : nil)
            .accessibilityHidden(true)
    }
}

struct FeedbackBanner: View {
    let text: String
    let warning: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            LightningIconView(warning ? .exclamationmarkTriangle : .infoCircle, size: 14)
            Text(text).zivviFont(.callout).textSelection(.enabled); Spacer(minLength: 0)
        }.padding(ZivviSpacing.contentInset).frame(maxWidth: .infinity, alignment: .leading)
            .flatSurface(ZivviTheme.mutedSurface, radius: 10)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
