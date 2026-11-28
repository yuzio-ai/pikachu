import AppKit
import SwiftUI

/// One-to-one mapping for all 83 app-owned functional icons from `LightningIcons.xcassets`.
enum LightningIcon: String, CaseIterable, Sendable, Hashable {
    // Arrows & Navigation (15)
    case arrowClockwise = "arrow.clockwise"
    case arrowDown = "arrow.down"
    case arrowDownToLine = "arrow.down.to.line"
    case arrowLeftArrowRight = "arrow.left.arrow.right"
    case arrowRightCircle = "arrow.right.circle"
    case arrowTriangle2Circlepath = "arrow.triangle.2.circlepath"
    case arrowTriangleBranch = "arrow.triangle.branch"
    case arrowTriangleheadClockwise = "arrow.trianglehead.clockwise"
    case arrowTurnDownLeft = "arrow.turn.down.left"
    case arrowUpCircle = "arrow.up.circle"
    case arrowUpCircleFill = "arrow.up.circle.fill"
    case arrowUpForwardSquare = "arrow.up.forward.square"
    case arrowUpRight = "arrow.up.right"
    case arrowUpRightSquare = "arrow.up.right.square"
    case arrowUturnBackward = "arrow.uturn.backward"

    // Chevrons (5)
    case chevronDown = "chevron.down"
    case chevronForward = "chevron.forward"
    case chevronLeft = "chevron.left"
    case chevronRight = "chevron.right"
    case chevronUp = "chevron.up"

    // Actions & Editing (15)
    case archivebox = "archivebox"
    case checkmark = "checkmark"
    case checkmarkSquare = "checkmark.square"
    case docOnDoc = "doc.on.doc"
    case ellipsis = "ellipsis"
    case magnifyingglass = "magnifyingglass"
    case minus = "minus"
    case paperclip = "paperclip"
    case pencil = "pencil"
    case plus = "plus"
    case square = "square"
    case squareAndArrowDown = "square.and.arrow.down"
    case squareAndPencil = "square.and.pencil"
    case trash = "trash"
    case xmark = "xmark"

    // Panels & Toolbar (12)
    case bubbleLeft = "bubble.left"
    case bubbleLeftAndBubbleRight = "bubble.left.and.bubble.right"
    case chartBar = "chart.bar"
    case cpu = "cpu"
    case cylinderSplit1x2 = "cylinder.split.1x2"
    case gaugeWithDotsNeedle33percent = "gauge.with.dots.needle.33percent"
    case gearshape = "gearshape"
    case insetFilledRightthirdRectangle = "inset.filled.rightthird.rectangle"
    case personCropCircle = "person.crop.circle"
    case sidebarLeft = "sidebar.left"
    case sidebarRight = "sidebar.right"
    case terminal = "terminal"

    // Files, Media & Code (11)
    case chevronLeftForwardslashChevronRight = "chevron.left.forwardslash.chevron.right"
    case doc = "doc"
    case docPlaintext = "doc.plaintext"
    case docText = "doc.text"
    case docZipper = "doc.zipper"
    case film = "film"
    case folder = "folder"
    case folderBadgePlus = "folder.badge.plus"
    case link = "link"
    case photo = "photo"
    case questionmarkSquare = "questionmark.square"

    // Status & Alerts (25)
    case bell = "bell"
    case bellBadgeFill = "bell.badge.fill"
    case bellSlash = "bell.slash"
    case boltFill = "bolt.fill"
    case checkmarkCircle = "checkmark.circle"
    case checkmarkCircleFill = "checkmark.circle.fill"
    case circle = "circle"
    case circleFill = "circle.fill"
    case clock = "clock"
    case clockArrowCirclepath = "clock.arrow.circlepath"
    case clockBadgeExclamationmark = "clock.badge.exclamationmark"
    case exclamationmarkCircle = "exclamationmark.circle"
    case exclamationmarkCircleFill = "exclamationmark.circle.fill"
    case exclamationmarkTriangle = "exclamationmark.triangle"
    case exclamationmarkTriangleFill = "exclamationmark.triangle.fill"
    case infoCircle = "info.circle"
    case minusCircle = "minus.circle"
    case pencilCircle = "pencil.circle"
    case playCircleFill = "play.circle.fill"
    case playFill = "play.fill"
    case plusCircle = "plus.circle"
    case starFill = "star.fill"
    case stopCircle = "stop.circle"
    case stopFill = "stop.fill"
    case xmarkCircleFill = "xmark.circle.fill"

    var assetName: String {
        "lightning_" + rawValue.replacingOccurrences(of: ".", with: "_")
    }

    /// Directional glyphs that mirror in right-to-left layouts; explicit left/right symbols stay fixed.
    var mirrorsInRTL: Bool {
        self == .chevronForward || self == .arrowUpForwardSquare
    }
}

/// Independent mapping for all 21 brand-specific icons from `LightningBrandIcons.xcassets`.
enum LightningBrandIcon: String, CaseIterable, Sendable, Hashable {
    case active = "active"
    case activity = "activity"
    case agent = "agent"
    case approval = "approval"
    case complete = "complete"
    case context = "context"
    case energy = "energy"
    case error = "error"
    case files = "files"
    case model = "model"
    case multiAgent = "multi-agent"
    case newSession = "new-session"
    case pause = "pause"
    case queue = "queue"
    case retry = "retry"
    case send = "send"
    case sessions = "sessions"
    case settings = "settings"
    case steer = "steer"
    case stop = "stop"
    case tools = "tools"

    var assetName: String {
        "lightning_brand_" + rawValue.replacingOccurrences(of: "-", with: "_")
    }
}

/// Renders an app-owned functional icon from `LightningIcons.xcassets` using unified `ZivviTheme.iconYellow`.
/// Falls back explicitly to a yellow SF Symbol only if a dynamic name is outside the 83-icon catalog.
struct LightningIconView: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.isEnabled) private var isEnabled

    private let icon: LightningIcon?
    private let fallbackSystemName: String?
    private let size: CGFloat
    private let tint: Color
    private let bundle: Bundle

    init(_ icon: LightningIcon, size: CGFloat = 16, tint: Color = ZivviTheme.iconYellow, bundle: Bundle = .main) {
        self.icon = icon
        self.fallbackSystemName = nil
        self.size = size
        self.tint = tint
        self.bundle = bundle
    }

    init(systemName: String, size: CGFloat = 16, tint: Color = ZivviTheme.iconYellow, bundle: Bundle = .main) {
        if let mapped = LightningIcon(rawValue: systemName) {
            self.icon = mapped
            self.fallbackSystemName = nil
        } else {
            self.icon = nil
            self.fallbackSystemName = systemName
        }
        self.size = size
        self.tint = tint
        self.bundle = bundle
    }

    var body: some View {
        Group {
            if let icon {
                Image(icon.assetName, bundle: bundle)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: icon.mirrorsInRTL && layoutDirection == .rightToLeft ? -1 : 1, y: 1)
            } else if let fallbackSystemName {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(tint)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityHidden(true)
    }
}

/// Renders one of the 21 brand-exclusive icons from `LightningBrandIcons.xcassets` using unified `ZivviTheme.iconYellow`.
struct LightningBrandIconView: View {
    @Environment(\.isEnabled) private var isEnabled

    private let icon: LightningBrandIcon
    private let size: CGFloat
    private let tint: Color
    private let bundle: Bundle

    init(_ icon: LightningBrandIcon, size: CGFloat = 16, tint: Color = ZivviTheme.iconYellow, bundle: Bundle = .main) {
        self.icon = icon
        self.size = size
        self.tint = tint
        self.bundle = bundle
    }

    var body: some View {
        Image(icon.assetName, bundle: bundle)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
    }
}

/// Drop-in replacement for `Label(..., systemImage:)` using the unified yellow icon system while preserving Label semantics.
struct LightningLabel<Title: View>: View {
    private let icon: AnyView
    private let title: Title

    init(_ titleKey: LocalizedStringKey, icon: LightningIcon, size: CGFloat = 14,
         tint: Color = ZivviTheme.iconYellow) where Title == Text {
        self.title = Text(titleKey)
        self.icon = AnyView(LightningIconView(icon, size: size, tint: tint))
    }

    init(_ titleKey: LocalizedStringKey, systemImage: String, size: CGFloat = 14,
         tint: Color = ZivviTheme.iconYellow) where Title == Text {
        self.title = Text(titleKey)
        self.icon = AnyView(LightningIconView(systemName: systemImage, size: size, tint: tint))
    }

    init(_ titleKey: LocalizedStringKey, brandIcon: LightningBrandIcon, size: CGFloat = 14,
         tint: Color = ZivviTheme.iconYellow) where Title == Text {
        self.title = Text(titleKey)
        self.icon = AnyView(LightningBrandIconView(brandIcon, size: size, tint: tint))
    }

    init(verbatim title: String, icon: LightningIcon, size: CGFloat = 14,
         tint: Color = ZivviTheme.iconYellow) where Title == Text {
        self.title = Text(verbatim: title)
        self.icon = AnyView(LightningIconView(icon, size: size, tint: tint))
    }

    init(verbatim title: String, brandIcon: LightningBrandIcon, size: CGFloat = 14,
         tint: Color = ZivviTheme.iconYellow) where Title == Text {
        self.title = Text(verbatim: title)
        self.icon = AnyView(LightningBrandIconView(brandIcon, size: size, tint: tint))
    }

    init(icon: LightningIcon, size: CGFloat = 14, tint: Color = ZivviTheme.iconYellow,
         @ViewBuilder title: () -> Title) {
        self.title = title()
        self.icon = AnyView(LightningIconView(icon, size: size, tint: tint))
    }

    init(brandIcon: LightningBrandIcon, size: CGFloat = 14, tint: Color = ZivviTheme.iconYellow,
         @ViewBuilder title: () -> Title) {
        self.title = title()
        self.icon = AnyView(LightningBrandIconView(brandIcon, size: size, tint: tint))
    }

    var body: some View {
        Label {
            title
        } icon: {
            icon
        }
    }
}

extension NSImage {
    static func lightningTemplateImage(_ icon: LightningIcon, bundle: Bundle = .main) -> NSImage? {
        guard let image = bundle.image(forResource: icon.assetName) else { return nil }
        image.isTemplate = true
        return image
    }

    static func lightningBrandTemplateImage(_ icon: LightningBrandIcon, bundle: Bundle = .main) -> NSImage? {
        guard let image = bundle.image(forResource: icon.assetName) else { return nil }
        image.isTemplate = true
        return image
    }
}
