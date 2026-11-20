import AppKit
import SwiftUI

enum InterfaceFontSize: String, CaseIterable, Sendable, Identifiable {
    case compact
    case standard
    case large
    case extraLarge

    private static let preferenceKey = "interface-font-size"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .compact: "紧凑"
        case .standard: "默认"
        case .large: "较大"
        case .extraLarge: "超大"
        }
    }

    var canIncrease: Bool {
        nextIndex != nil
    }

    var canDecrease: Bool {
        previousIndex != nil
    }

    func increased() -> Self {
        nextIndex.map { Self.allCases[$0] } ?? self
    }

    func decreased() -> Self {
        previousIndex.map { Self.allCases[$0] } ?? self
    }

    private var nextIndex: Int? {
        guard let index = Self.allCases.firstIndex(of: self),
              Self.allCases.indices.contains(index + 1) else { return nil }
        return index + 1
    }

    private var previousIndex: Int? {
        guard let index = Self.allCases.firstIndex(of: self),
              Self.allCases.indices.contains(index - 1) else { return nil }
        return index - 1
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .standard
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

struct PikachuTypography: Equatable, Sendable {
    enum TextRole: CaseIterable, Sendable {
        case micro
        case badge
        case caption2
        case caption
        case subheadline
        case callout
        case body
        case headline
        case title3
        case title2
        case hero
    }

    let size: InterfaceFontSize

    init(size: InterfaceFontSize = .standard) {
        self.size = size
    }

    func pointSize(for role: TextRole) -> CGFloat {
        switch (role, size) {
        case (.micro, .compact): 9
        case (.micro, .standard): 10
        case (.micro, .large): 11
        case (.micro, .extraLarge): 11.5

        case (.badge, .compact): 9
        case (.badge, .standard): 10
        case (.badge, .large): 10.5
        case (.badge, .extraLarge): 11

        case (.caption2, .compact): 10
        case (.caption2, .standard): 11
        case (.caption2, .large): 12
        case (.caption2, .extraLarge): 13

        case (.caption, .compact): 10
        case (.caption, .standard): 11.5
        case (.caption, .large): 12.5
        case (.caption, .extraLarge): 13.5

        case (.subheadline, .compact): 11
        case (.subheadline, .standard): 12.5
        case (.subheadline, .large): 13.5
        case (.subheadline, .extraLarge): 14.5

        case (.callout, .compact): 12
        case (.callout, .standard): 13
        case (.callout, .large): 14
        case (.callout, .extraLarge): 15

        case (.body, .compact), (.headline, .compact): 13
        case (.body, .standard), (.headline, .standard): 14
        case (.body, .large), (.headline, .large): 15
        case (.body, .extraLarge), (.headline, .extraLarge): 16

        case (.title3, .compact): 15
        case (.title3, .standard): 16
        case (.title3, .large): 17
        case (.title3, .extraLarge): 18

        case (.title2, .compact): 17
        case (.title2, .standard): 18
        case (.title2, .large): 19
        case (.title2, .extraLarge): 20

        case (.hero, .compact): 28
        case (.hero, .standard): 30
        case (.hero, .large): 32
        case (.hero, .extraLarge): 34
        }
    }

    func font(_ role: TextRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        let resolvedWeight = weight ?? (role == .headline ? .semibold : .regular)
        return .system(size: pointSize(for: role), weight: resolvedWeight, design: design)
    }

    func nsFont(_ role: TextRole, weight: NSFont.Weight? = nil) -> NSFont {
        let resolvedWeight = weight ?? (role == .headline ? .semibold : .regular)
        return .systemFont(ofSize: pointSize(for: role), weight: resolvedWeight)
    }

    var sidebarTimeWidth: CGFloat {
        switch size {
        case .compact: 42
        case .standard: 46
        case .large: 49
        case .extraLarge: 53
        }
    }

    var projectBadgeCompactSize: CGFloat {
        switch size {
        case .compact: 17
        case .standard: 18
        case .large: 19
        case .extraLarge: 20
        }
    }

    var projectBadgeSize: CGSize {
        switch size {
        case .compact: CGSize(width: 21, height: 19)
        case .standard: CGSize(width: 22, height: 20)
        case .large: CGSize(width: 23, height: 21)
        case .extraLarge: CGSize(width: 24, height: 22)
        }
    }

    var composerActionButtonSize: CGFloat {
        switch size {
        case .compact, .standard: 28
        case .large: 30
        case .extraLarge: 32
        }
    }

    var titlebarControlHeight: CGFloat {
        max(28, ceil(pointSize(for: .headline) * 2))
    }
}

private struct PikachuTypographyKey: EnvironmentKey {
    static let defaultValue = PikachuTypography(size: .standard)
}

extension EnvironmentValues {
    var pikachuTypography: PikachuTypography {
        get { self[PikachuTypographyKey.self] }
        set { self[PikachuTypographyKey.self] = newValue }
    }
}

private struct PikachuFontModifier: ViewModifier {
    @Environment(\.pikachuTypography) private var typography
    let role: PikachuTypography.TextRole
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(typography.font(role, weight: weight, design: design))
    }
}

extension View {
    func pikachuTypography(_ size: InterfaceFontSize) -> some View {
        let typography = PikachuTypography(size: size)
        return environment(\.pikachuTypography, typography)
            .font(typography.font(.body))
    }

    func pikachuFont(
        _ role: PikachuTypography.TextRole,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(PikachuFontModifier(role: role, weight: weight, design: design))
    }
}
