import AppKit
import CoreText
import Observation
import OrchestrationCore

struct TaskStatusSnapshot {
    var running: [SessionReference] = []
    var awaitingApproval: [SessionReference] = []
    var unreadCompletions: [SessionReference] = []

    @MainActor init(workspace: WorkspaceController?) {
        guard let workspace else { return }
        for session in workspace.state.sessions {
            switch SidebarSessionStatus.resolve(execution: workspace.execution(for: session.id),
                                                needsReview: false, hasDraft: false) {
            case .running, .retrying: running.append(session)
            case .awaitingApproval: awaitingApproval.append(session)
            default: break
            }
            if session.hasUnreadCompletion { unreadCompletions.append(session) }
        }
    }
}

@MainActor final class TaskStatusMenu: NSObject, NSMenuDelegate {
    private struct Destination {
        let sessionID: UUID
        let acknowledgesCompletion: Bool
    }

    private weak var appDelegate: AppDelegate?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let logo = NSImage(named: "SidebarBrandMark")

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        item.button?.imagePosition = .imageOnly
        menu.delegate = self
        item.menu = menu
        refreshLabel()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    private func refreshLabel() {
        let snapshot = withObservationTracking {
            TaskStatusSnapshot(workspace: appDelegate?.workspace)
        } onChange: { [weak self] in
            // Observation fires before the mutation; read after it on the main actor.
            Task { @MainActor in self?.refreshLabel() }
        }
        let running = snapshot.running.count
        let approval = snapshot.awaitingApproval.count
        let unread = snapshot.unreadCompletions.count
        let summary = String(localized: "Pikachu：运行中 \(running)，待审批 \(approval)，未读 \(unread)")
        item.button?.image = makeStatusImage([
            (running, String(localized: "运行")),
            (approval, String(localized: "审批")),
            (unread, String(localized: "未读"))
        ])
        item.button?.toolTip = summary
        item.button?.setAccessibilityLabel(summary)
    }

    private func makeStatusImage(_ metrics: [(count: Int, label: String)]) -> NSImage {
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let captionFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        func line(_ text: String, font: NSFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        let minColumnWidth = ceil(CTLineGetTypographicBounds(line("00", font: countFont), nil, nil, nil))
        let columns = metrics.map { metric in
            let count = line(metric.count.formatted(), font: countFont)
            let caption = line(metric.label, font: captionFont)
            let countWidth = CTLineGetTypographicBounds(count, nil, nil, nil)
            let captionWidth = CTLineGetTypographicBounds(caption, nil, nil, nil)
            return (count: count, caption: caption, countWidth: countWidth, captionWidth: captionWidth,
                    width: ceil(max(minColumnWidth, countWidth, captionWidth)))
        }
        let logoSize: CGFloat = 16
        let spacing: CGFloat = 5
        let height: CGFloat = 22
        let width = logoSize + columns.reduce(0) { $0 + spacing + $1.width }
        // A single template image keeps native menu-bar tinting and click behavior on NSStatusBarButton.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { [logo] _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            logo?.draw(in: NSRect(x: 0, y: (height - logoSize) / 2, width: logoSize, height: logoSize))
            context.textMatrix = .identity
            var x = logoSize + spacing
            for column in columns {
                context.textPosition = CGPoint(x: x + (column.width - column.captionWidth) / 2, y: 13)
                CTLineDraw(column.caption, context)
                context.textPosition = CGPoint(x: x + (column.width - column.countWidth) / 2, y: 2)
                CTLineDraw(column.count, context)
                x += column.width + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(actionItem(String(localized: "打开工作台"), action: #selector(showWorkbench)))
        menu.addItem(.separator())

        let workspace = appDelegate?.workspace
        let snapshot = TaskStatusSnapshot(workspace: workspace)
        let projectNames = Dictionary((workspace?.state.projects ?? []).map { ($0.id, $0.displayName) },
                                      uniquingKeysWith: { first, _ in first })
        addGroup(String(localized: "运行中"), sessions: snapshot.running, projectNames: projectNames)
        addGroup(String(localized: "待审批"), sessions: snapshot.awaitingApproval, projectNames: projectNames)
        addGroup(String(localized: "已完成"), sessions: snapshot.unreadCompletions,
                 projectNames: projectNames, acknowledgesCompletion: true)
    }

    private func addGroup(_ title: String, sessions: [SessionReference], projectNames: [UUID: String],
                          acknowledgesCompletion: Bool = false) {
        let group = menuItem(String(localized: "\(title)（\(sessions.count)）"), action: nil)
        if !sessions.isEmpty {
            let submenu = NSMenu()
            for session in sessions {
                let entry = actionItem(session.displayTitle, action: #selector(openSession(_:)))
                entry.subtitle = projectNames[session.projectID]
                entry.representedObject = Destination(sessionID: session.id, acknowledgesCompletion: acknowledgesCompletion)
                submenu.addItem(entry)
            }
            group.submenu = submenu
        }
        menu.addItem(group)
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let entry = menuItem(title, action: action)
        entry.target = self
        return entry
    }

    private func menuItem(_ title: String, action: Selector?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        entry.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        return entry
    }

    @objc private func showWorkbench() {
        appDelegate?.openWorkbenchFromStatusMenu()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? Destination else { return }
        appDelegate?.openWorkbenchFromStatusMenu(sessionID: destination.sessionID, acknowledgesCompletion: destination.acknowledgesCompletion)
    }
}
