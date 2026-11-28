import SwiftUI

struct FlatDisclosureStyle: DisclosureGroupStyle {
    var chevronEdge: HorizontalEdge? = .leading
    var showsHoverBackground = true
    var showsPressedBackground = true

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    switch chevronEdge {
                    case .leading:
                        FlatDisclosureChevron(expanded: configuration.isExpanded)
                        configuration.label
                    case .trailing:
                        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                        FlatDisclosureChevron(expanded: configuration.isExpanded)
                    case nil:
                        configuration.label
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, showsHoverBackground: showsHoverBackground,
                                                showsPressedBackground: showsPressedBackground))
            .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已折叠"))

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct FlatDisclosureChevron: View {
    enum Direction: String {
        case forward, down, up
    }

    let direction: Direction
    nonisolated static let pointSize: CGFloat = 8

    init(_ direction: Direction) {
        self.direction = direction
    }

    init(expanded: Bool) {
        self.init(expanded ? .down : .forward)
    }

    var body: some View {
        LightningIconView(systemName: "chevron.\(direction.rawValue)", size: Self.pointSize + 3)
            .frame(width: 12)
    }
}
