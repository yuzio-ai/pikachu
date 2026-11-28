import SwiftUI

/// Two independent classification dimensions for Composer Notices (Workbench 2.0 Section 13):
/// 1) Status semantics (Information / Progress / Warning / Error)
/// 2) Interaction shape (Informational / ActionableRow / NoticeWithAction)
enum ComposerNoticeSeverity: Int, Comparable {
    case error = 0
    case warning = 1
    case progress = 2
    case information = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var systemImage: String {
        switch self {
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .progress: "arrow.triangle.2.circlepath"
        case .information: "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .error: ZivviTheme.errorText
        case .warning: ZivviTheme.warningText
        case .progress: ZivviTheme.secondaryText
        case .information: ZivviTheme.secondaryText
        }
    }
}

struct ComposerNoticeItem: Identifiable {
    enum Interaction {
        /// Pure display: no background, no chevron, not focusable as a button.
        case informational
        /// Entire row is clickable: subtle neutral surface + always-visible trailing chevron.
        case actionableRow(hint: String, action: () -> Void)
        /// Display notice with an explicit trailing button (prevents accidental triggers).
        case withAction(label: String, isBusy: Bool, action: () -> Void)
    }

    let id: String
    let priority: Int
    let severity: ComposerNoticeSeverity
    let text: String
    let interaction: Interaction
    var dismiss: (() -> Void)? = nil
    var accessibilityID: String? = nil
}

/// Vertical stack of Composer Notices participating in normal flow directly above ComposerView.
/// Never overlays transcript content; collapses to zero height when empty.
struct ComposerNoticesStack: View {
    let items: [ComposerNoticeItem]
    let maxHeight: CGFloat

    var body: some View {
        if !items.isEmpty {
            let sorted = items.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.severity < rhs.severity
            }
            Group {
                if sorted.count > 4 && maxHeight > 60 {
                    // Keep the highest-priority blocking item pinned, scroll the rest cleanly.
                    VStack(alignment: .leading, spacing: 4) {
                        ComposerNoticeRow(item: sorted[0])
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(sorted.dropFirst()) { item in
                                    ComposerNoticeRow(item: item)
                                }
                            }
                        }
                        .frame(maxHeight: max(56, maxHeight - 36))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sorted) { item in
                            ComposerNoticeRow(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
            .accessibilityIdentifier("composer-notices-stack")
        }
    }
}

private struct ComposerNoticeRow: View {
    let item: ComposerNoticeItem
    @State private var isHovered = false

    var body: some View {
        switch item.interaction {
        case .informational:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                leadingIcon
                Text(verbatim: item.text)
                    .zivviFont(.caption)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let dismiss = item.dismiss {
                    dismissButton(action: dismiss)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 24)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(item.accessibilityID ?? "notice-\(item.id)")

        case .actionableRow(let hint, let action):
            HStack(spacing: 6) {
                Button(action: action) {
                    HStack(alignment: .center, spacing: 6) {
                        leadingIcon
                        Text(verbatim: item.text)
                            .zivviFont(.caption, weight: .medium)
                            .foregroundStyle(ZivviTheme.primaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LightningIconView(.chevronRight, size: 12)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(hint)
                .accessibilityIdentifier(item.accessibilityID ?? "notice-\(item.id)")

                if let dismiss = item.dismiss {
                    dismissButton(action: dismiss)
                        .padding(.trailing, 4)
                }
            }
            .background(
                isHovered ? ZivviTheme.controlHover : ZivviTheme.mutedSurface,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { isHovered = $0 }

        case .withAction(let label, let isBusy, let action):
            HStack(alignment: .center, spacing: 8) {
                leadingIcon
                Text(verbatim: item.text)
                    .zivviFont(.caption)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: action) {
                    HStack(spacing: 4) {
                        if isBusy { FlatProgressView().controlSize(.mini) }
                        Text(verbatim: label)
                            .zivviFont(.caption2, weight: .medium)
                    }
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 24))
                .disabled(isBusy)
                .fixedSize()
                if let dismiss = item.dismiss {
                    dismissButton(action: dismiss)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 28)
            .accessibilityIdentifier(item.accessibilityID ?? "notice-\(item.id)")
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if item.severity == .progress {
            FlatProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else {
            LightningIconView(systemName: item.severity.systemImage, size: 14)
                .frame(width: 14, alignment: .center)
        }
    }

    private var textColor: Color {
        switch item.severity {
        case .error: ZivviTheme.errorText
        case .warning: ZivviTheme.primaryText
        case .progress, .information: ZivviTheme.secondaryText
        }
    }

    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LightningIconView(.xmark, size: 11)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 4))
        .help("关闭提示")
        .accessibilityLabel("关闭提示")
    }
}
