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
    var perform: (@escaping () -> Void) -> Void = { $0() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(request.title).pikachuFont(.title3, weight: .semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .pikachuFont(.caption)
                    .foregroundStyle(PikachuTheme.warningText)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)

            Text(request.message)
                .foregroundStyle(PikachuTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            PikachuDivider()

            HStack(spacing: 8) {
                if let alternative = request.alternative {
                    Button(alternative.title) {
                        perform(alternative.perform)
                    }
                    .buttonStyle(FlatControlButtonStyle())
                }
                Spacer(minLength: 0)
                if request.allowsCancel {
                    Button(request.cancelTitle, role: .cancel, action: cancel)
                        .buttonStyle(FlatControlButtonStyle(treatment: request.defaultsToCancel ? .prominent : .outlined))
                        .keyboardShortcut(request.defaultsToCancel ? .defaultAction : .cancelAction)
                }
                Button(request.confirmTitle, role: request.destructive ? .destructive : nil) {
                    perform(request.confirm)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: request.destructive || request.defaultsToCancel ? .outlined : .prominent))
                .keyboardShortcut(request.destructive || request.defaultsToCancel ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 448)
        .flatPanelContent()
        .onExitCommand(perform: request.defaultsToCancel ? cancel : nil)
    }
}
