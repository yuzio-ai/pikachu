import AppKit
import SwiftUI

enum MarkdownProfile: Equatable {
    case conversation
    case editorial
}

enum MarkdownWidth: Equatable {
    case narrow, compact, standard, wide

    init(_ available: CGFloat) {
        switch available {
        case ..<320: self = .narrow
        case ..<480: self = .compact
        case ..<720: self = .standard
        default: self = .wide
        }
    }

    var isCompact: Bool { self == .compact || self == .narrow }

    var editorialInsets: EdgeInsets {
        switch self {
        case .narrow: EdgeInsets(top: 16, leading: 12, bottom: 24, trailing: 12)
        case .compact: EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16)
        case .standard: EdgeInsets(top: 24, leading: 20, bottom: 32, trailing: 20)
        case .wide: EdgeInsets(top: 24, leading: 24, bottom: 32, trailing: 24)
        }
    }

    func editorialContentWidth(in available: CGFloat) -> CGFloat {
        min(720, max(1, available - editorialInsets.leading - editorialInsets.trailing))
    }
}

struct MarkdownStyle: Equatable {
    struct TypeStyle: Equatable {
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: NSFont.Weight

        var font: NSFont { .systemFont(ofSize: size, weight: weight) }
        var codeFont: NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

        func lineSpacing(monospaced: Bool = false) -> CGFloat {
            let base = monospaced ? codeFont : font
            return max(0, lineHeight - ceil(base.ascender - base.descender + base.leading))
        }
    }

    let profile: MarkdownProfile
    let width: MarkdownWidth
    let scale: CGFloat

    init(profile: MarkdownProfile, width: MarkdownWidth, typography: PikachuTypography, scale: CGFloat? = nil) {
        self.profile = profile
        self.width = width
        self.scale = scale ?? Self.textScale(for: typography)
    }

    static func textScale(for typography: PikachuTypography) -> CGFloat {
        typography.pointSize(for: .body) / PikachuTypography().pointSize(for: .body)
    }

    private var editorial: Bool { profile == .editorial }

    var body: TypeStyle { type(14, editorial ? 23 : 22) }
    var table: TypeStyle { type(13, 20) }
    var code: TypeStyle { type(13, 20) }
    var caption: TypeStyle { type(12, 18) }
    var paragraphGap: CGFloat { space(editorial ? 16 : 12) }
    var richBlockGap: CGFloat { space(editorial ? 20 : 16) }
    var dividerGap: CGFloat { space(editorial ? 24 : 20) }
    var consecutiveHeadingGap: CGFloat { space(editorial ? 16 : 12) }
    var looseListGap: CGFloat { space(editorial ? 12 : 8) }
    var tightListGap: CGFloat { space(editorial ? 6 : 4) }
    var quoteInset: CGFloat { space(width.isCompact ? 8 : 12) }
    var quoteRule: CGFloat { 2 }
    var listMarkerGap: CGFloat { space(width.isCompact ? 4 : 8) }
    var listMarkerWidth: CGFloat { space(width.isCompact ? 10 : 12) }
    var codeInset: CGFloat { space(width.isCompact ? 8 : editorial ? 16 : 12) }
    var tableColumnGap: CGFloat { space(width.isCompact ? 16 : 20) }
    var tableRowInset: CGFloat { space(width.isCompact ? 6 : 8) }

    func heading(_ level: Int) -> TypeStyle {
        let size: CGFloat
        let line: CGFloat
        switch level {
        case 1: (size, line) = editorial ? (28, 36) : (24, 32)
        case 2: (size, line) = editorial ? (22, 30) : (20, 28)
        case 3: (size, line) = editorial ? (18, 26) : (17, 24)
        case 4: (size, line) = editorial ? (16, 24) : (15, 22)
        default: (size, line) = (14, 22)
        }
        let cap: CGFloat = switch (width, level) {
        case (.narrow, 1): 22
        case (.narrow, 2): 18
        case (.compact, 1): 24
        case (.compact, 2): 20
        default: size
        }
        let resolvedSize = min(size, cap)
        return type(resolvedSize, line - (size - resolvedSize), level >= 6 ? .medium : .semibold)
    }

    func headingGap(_ level: Int, before: Bool) -> CGFloat {
        let gaps: (CGFloat, CGFloat) = switch level {
        case 1: editorial ? (40, 20) : (32, 16)
        case 2: editorial ? (32, 16) : (24, 12)
        case 3: editorial ? (24, 12) : (20, 8)
        default: editorial ? (20, 8) : (16, 8)
        }
        if width.isCompact {
            return space(before ? max(12, gaps.0 - (level <= 2 ? 8 : 4)) : max(8, gaps.1 - 4))
        }
        return space(before ? gaps.0 : gaps.1)
    }

    private func type(_ size: CGFloat, _ lineHeight: CGFloat, _ weight: NSFont.Weight = .regular) -> TypeStyle {
        TypeStyle(size: size * scale, lineHeight: lineHeight * scale, weight: weight)
    }

    private func space(_ points: CGFloat) -> CGFloat {
        // A smaller scale response keeps the text area useful in tight columns.
        (points * (scale + 1) / 2).rounded()
    }
}

enum MarkdownColors {
    static let text = PikachuTheme.primaryText
    static let secondary = PikachuTheme.secondaryText
    static let link = PikachuTheme.infoText
    static let code = PikachuTheme.mutedSurface
    static let inlineCode = PikachuTheme.selected

    static func divider(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? PikachuTheme.selectionBorder : PikachuTheme.subtleDivider
    }

    static func quote(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? PikachuTheme.focusBorder : PikachuTheme.selectionBorder
    }
}
