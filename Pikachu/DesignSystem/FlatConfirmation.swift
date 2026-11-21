import SwiftUI

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    var destructive = true
    var allowsCancel = true
    var cancelTitle: LocalizedStringKey = "取消"
    var defaultsToCancel = false
    var alternative: Action?
    let confirm: () -> Void

    struct Action {
        let title: LocalizedStringKey
        let perform: () -> Void
    }
}

struct FlatConfirmation: View {
    let request: ConfirmationRequest
    let cancel: () -> Void
    var width: CGFloat = 448
    var perform: (@escaping () -> Void) -> Void = { $0() }

    @Environment(\.pikachuTypography) private var typography

    private var actionHeight: CGFloat {
        max(26, ceil(typography.pointSize(for: .body) * 2))
    }

    private var actionMinWidth: CGFloat {
        max(88, ceil(typography.pointSize(for: .body) * 6.3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            message
            PikachuDivider().padding(.top, 16)
            actions.padding(.top, 14)
        }
        .padding(20)
        .frame(width: width)
        .flatPanelContent()
        .onExitCommand(perform: request.defaultsToCancel ? cancel : nil)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .pikachuFont(.callout)
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            Text(request.title)
                .pikachuFont(.title3, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var message: some View {
        Text(request.message)
            .pikachuFont(.body)
            .foregroundStyle(PikachuTheme.secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let alternative = request.alternative {
                Button(alternative.title) {
                    perform(alternative.perform)
                }
                .buttonStyle(FlatControlButtonStyle(height: actionHeight, minimumWidth: actionMinWidth))
            }
            Spacer(minLength: 0)
            if request.allowsCancel {
                Button(request.cancelTitle, role: .cancel, action: cancel)
                    .buttonStyle(FlatControlButtonStyle(treatment: request.defaultsToCancel ? .prominent : .outlined,
                                                        height: actionHeight, minimumWidth: actionMinWidth))
                    .keyboardShortcut(request.defaultsToCancel ? .defaultAction : .cancelAction)
            }
            Button(request.confirmTitle, role: request.destructive ? .destructive : nil) {
                perform(request.confirm)
            }
            .buttonStyle(FlatControlButtonStyle(treatment: request.destructive || request.defaultsToCancel ? .outlined : .prominent,
                                                height: actionHeight, minimumWidth: actionMinWidth))
            .keyboardShortcut(request.destructive || request.defaultsToCancel ? nil : .defaultAction)
        }
    }

    private var iconName: String {
        request.destructive ? "exclamationmark.triangle" : "info.circle"
    }

    private var iconTint: Color {
        request.destructive ? PikachuTheme.warningText : PikachuTheme.infoText
    }
}
