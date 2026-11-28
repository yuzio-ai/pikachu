import SwiftUI

struct FlatMenu<Label: View, Content: View>: View {
    var width: CGFloat = 200
    var arrowEdge: Edge = .bottom
    var triggerTreatment: FlatControlButtonStyle.Treatment = .quiet
    var triggerSelected = false
    var restoresTriggerFocus = false
    var presentation: Binding<Bool>? = nil
    var onEscape: (() -> Bool)? = nil
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: (_ select: @escaping (@escaping () -> Void) -> Void) -> Content
    @State private var isOpen = false
    @State private var pendingAction = FlatMenuPendingAction()
    @FocusState private var triggerFocused: Bool

    var body: some View {
        let presented = presentation ?? $isOpen
        let trigger = Button { presented.wrappedValue.toggle() } label: { label() }
            .buttonStyle(FlatControlButtonStyle(treatment: triggerTreatment, isOpen: presented.wrappedValue,
                                              isSelected: triggerSelected, inset: false))
            .accessibilityValue(presented.wrappedValue ? Text("已展开") : Text("已折叠"))
        Group {
            if restoresTriggerFocus { trigger.focused($triggerFocused) }
            else { trigger }
        }
            .popover(isPresented: presented, arrowEdge: arrowEdge) {
                FlatMenuPanel(width: width) {
                    content { action in
                        guard presented.wrappedValue, pendingAction.schedule(action) else { return }
                        presented.wrappedValue = false
                    }
                }
                .onKeyPress(.escape) {
                    if onEscape?() != true { presented.wrappedValue = false }
                    return .handled
                }
                .onExitCommand {
                    if onEscape?() != true { presented.wrappedValue = false }
                }
                .onDisappear {
                    let action = pendingAction.take()
                    if restoresTriggerFocus {
                        triggerFocused = true
                    }
                    onDismiss?()
                    action?()
                }
            }
    }
}

struct FlatMenuPendingAction {
    private var action: (() -> Void)?

    mutating func schedule(_ body: @escaping () -> Void) -> Bool {
        guard action == nil else { return false }
        action = body
        return true
    }

    mutating func take() -> (() -> Void)? {
        defer { action = nil }
        return action
    }
}

struct FlatMenuItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: Text
    var icon: Image? = nil
    var enabled = true
    var selected = false
    var dividerBefore = false
    var opensSubmenu = false
    var accessibilityID: String? = nil
    let action: () -> Void
}

struct FlatMenuItems<ID: Hashable>: View {
    let items: [FlatMenuItem<ID>]
    var iconSize: CGFloat = 15
    var maximumHeight: CGFloat? = nil
    var initialFocus: ID? = nil
    var onBack: (() -> Void)? = nil
    @FocusState private var focus: ID?
    @FocusState private var emptyMenuFocused: Bool

    var body: some View {
        let enabledIDs = items.filter(\.enabled).map(\.id)
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: ZivviSpacing.menuItemGap) {
                    ForEach(items) { item in
                        if item.dividerBefore { ZivviDivider() }
                        Button(action: item.action) {
                            FlatMenuRow(title: item.title, selected: item.selected, icon: item.icon, iconSize: iconSize,
                                        opensSubmenu: item.opensSubmenu)
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: item.selected,
                                                          hasKeyboardFocus: focus == item.id))
                        .disabled(!item.enabled)
                        .focused($focus, equals: item.id)
                        .accessibilityAddTraits(item.selected ? .isSelected : [])
                        .accessibilityIdentifier(item.accessibilityID ?? "flat-menu-item-\(item.id)")
                        .id(item.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: maximumHeight ?? 260)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
            .focusable(enabledIDs.isEmpty)
            .focused($emptyMenuFocused)
            .task(id: enabledIDs) {
                guard !enabledIDs.isEmpty else {
                    emptyMenuFocused = true
                    return
                }
                if let focus, enabledIDs.contains(focus) { return }
                focus = initialFocus.flatMap { enabledIDs.contains($0) ? $0 : nil }
                    ?? items.first { $0.enabled && $0.selected }?.id
                    ?? enabledIDs.first
            }
            .onChange(of: focus) { _, id in
                if let id { scroll.scrollTo(id) }
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .tab]) { key in
                guard !enabledIDs.isEmpty else { return .handled }
                let backwards = key.key == .upArrow || (key.key == .tab && key.modifiers.contains(.shift))
                let index = focus.flatMap { enabledIDs.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
                focus = enabledIDs[(index + (backwards ? -1 : 1) + enabledIDs.count) % enabledIDs.count]
                return .handled
            }
            .onKeyPress(keys: [.return, .rightArrow], phases: .down) { key in
                guard let item = items.first(where: { $0.enabled && $0.id == focus }) else { return .ignored }
                guard key.key == .return || item.opensSubmenu else { return .ignored }
                item.action()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard let onBack else { return .ignored }
                onBack()
                return .handled
            }
        }
    }
}

struct FlatMenuPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.menuItemGap, content: content)
            .buttonStyle(FlatControlButtonStyle())
            .anchoredPopoverCard(width: width, inset: AnchoredCardStyle.compactInset, background: ZivviTheme.surface)
            .focusSection()
    }
}

struct FlatMenuRow: View {
    let title: Text
    var selected = false
    var icon: Image? = nil
    var lightningIcon: LightningIcon? = nil
    var brandIcon: LightningBrandIcon? = nil
    var iconSize: CGFloat = 15
    var opensSubmenu = false

    var body: some View {
        HStack(spacing: 8) {
            if let lightningIcon {
                LightningIconView(lightningIcon, size: iconSize)
            } else if let brandIcon {
                LightningBrandIconView(brandIcon, size: iconSize)
            } else if let icon {
                icon.resizable().scaledToFit().frame(width: iconSize, height: iconSize).accessibilityHidden(true)
            }
            title.multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if selected {
                LightningIconView(.checkmark, size: 13)
            } else if opensSubmenu {
                FlatDisclosureChevron(.forward)
            }
        }
        .padding(.vertical, 2)
    }
}
