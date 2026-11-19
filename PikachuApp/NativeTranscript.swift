import AppKit
import SwiftUI
import OrchestrationCore

/// AppKit virtualizes rows and caches measured visible heights. SwiftUI renders
/// visible content; offscreen accessibility queries use inexpensive text summaries.
struct NativeTranscript: NSViewRepresentable {
    let rows: [TranscriptDisplayRow]
    @Binding var follow: Bool
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = TranscriptScroll(), table = NSTableView()
        table.style = .plain
        let column = NSTableColumn(identifier:.init("message")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.backgroundColor = .clear
        table.intercellSpacing = .init(width:0,height:16); table.selectionHighlightStyle = .none
        table.rowHeight = 120
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = coordinator; table.dataSource = coordinator
        table.setAccessibilityIdentifier("transcript")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.onResize = { [weak coordinator] widthChanged in
            coordinator?.resized(widthChanged: widthChanged)
        }
        coordinator.table = table; coordinator.scroll = scroll
        if DiagnosticMetrics.shared.measuresPixels {
            DiagnosticMetrics.shared.runScrollSample = { [weak coordinator] in coordinator?.startScrollSample() ?? false }
            DiagnosticMetrics.shared.positionScrollSample = { [weak coordinator] in coordinator?.positionScrollSample(at: $0) ?? false }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator,selector:#selector(Coordinator.scrolled(_:)),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.userScrolled(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onEditUserMessage = onEditUserMessage
        context.coordinator.update(rows, follow: $follow)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopScrollSample()
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        NotificationCenter.default.removeObserver(coordinator)
    }
    final class TranscriptScroll: NSScrollView {
        var onResize: ((_ widthChanged: Bool) -> Void)?
        private var lastContentSize: NSSize = .zero

        override func layout() {
            super.layout()
            let size = contentSize
            let widthChanged = abs(size.width - lastContentSize.width) > 1
            let heightChanged = abs(size.height - lastContentSize.height) > 1
            guard widthChanged || heightChanged else { return }
            lastContentSize = size
            onResize?(widthChanged)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var rows: [TranscriptDisplayRow] = []
        private var turnHeaders: [Int: TurnRecord] = [:]
        var onEditUserMessage: ((TranscriptItem) -> Void)?
        private let toolGroupExpansion = ToolGroupExpansion()
        private var follow = true
        private var followBinding: Binding<Bool>?
        private var scheduled = false
        private var refreshing = false
        private var changed = IndexSet(), upgrades = IndexSet()
        private var heights: [String:CGFloat] = [:], pendingHeights: [String:CGFloat] = [:]
        private var sampleDriver: TranscriptScrollSample?
        func startScrollSample() -> Bool {
            guard !follow, rows.count >= 5_000, let scroll, let table, scroll.window?.isKeyWindow == true else { return false }
            stopScrollSample()
            let firstRow = table.rows(in: table.visibleRect).location
            sampleDriver = TranscriptScrollSample(scroll: scroll, firstRow: firstRow)
            return true
        }
        func positionScrollSample(at row: Int) -> Bool {
            guard !follow, rows.count >= 5_000, rows.indices.contains(row), let scroll, let table,
                  scroll.window?.isKeyWindow == true else { return false }
            stopScrollSample()
            moveClip(toY: table.rect(ofRow: row).minY, in: scroll)
            return true
        }
        func stopScrollSample() { sampleDriver?.stop(); sampleDriver = nil }
        private var width: CGFloat { max(100,(scroll?.contentSize.width ?? 600)-48) }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        private func estimate(_ row: Int) -> CGFloat { rows.indices.contains(row) && rows[row].isTool ? 54 : 120 }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }; return heights[rows[row].id] ?? estimate(row)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            if !tableView.rect(ofRow:row).intersects(tableView.visibleRect) {
                let cell = (tableView.makeView(withIdentifier:.init("summary-cell"),owner:nil) as? SummaryCell) ?? SummaryCell()
                switch rows[row] {
                case .item(let item):
                    cell.label.stringValue = item.tool.map { $0.name + " · " + $0.state.rawValue } ?? item.text
                case .completedTools(let tools):
                    cell.label.stringValue = String(localized: "\(tools.count) 项工具调用已完成")
                }
                return cell
            }
            let cell = (tableView.makeView(withIdentifier:.init("message-cell"),owner:nil) as? HostCell) ?? HostCell()
            if !cell.observed {
                cell.observed = true; cell.host.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self,selector:#selector(hostResized(_:)),name:NSView.frameDidChangeNotification,object:cell.host)
            }
            configure(cell,row:row); return cell
        }
        private func configure(_ cell: HostCell, row: Int) {
            let content = rows[row], id = content.id
            cell.representedID = id
            cell.representedIndex = row
            cell.host.rootView = TranscriptHost(
                row: content,
                turnHeader: turnHeaders[row],
                width: width,
                toolGroupExpansion: toolGroupExpansion,
                onEditUserMessage: onEditUserMessage
            ) { [weak self, weak cell] in
                DispatchQueue.main.async {
                    guard let self, let cell, cell.representedID == id else { return }
                    cell.host.invalidateIntrinsicContentSize(); cell.host.layoutSubtreeIfNeeded()
                    self.stageHeight(cell)
                }
            }
        }
        @objc func hostResized(_ notification: Notification) {
            guard let host = notification.object as? NSView, let cell = host.superview as? HostCell else { return }
            stageHeight(cell)
        }
        private func stageHeight(_ cell: HostCell) {
            let row = cell.representedIndex
            guard let id = cell.representedID, rows.indices.contains(row), rows[row].id == id, let table else { return }
            let height = max(44, ceil(cell.host.frame.height) + 16)
            guard height.isFinite, height < 1_000_000,
                  abs((pendingHeights[id] ?? heights[id] ?? estimate(row)) - height) > 1,
                  table.rect(ofRow: row).intersects(table.visibleRect) else { return }
            pendingHeights[id] = height; changed.insert(row); schedule()
        }
        private func schedule() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }; self.scheduled = false; self.refreshing = true
                defer { self.refreshing = false }
                let upgrades = self.upgrades, changes = self.changed, pending = self.pendingHeights
                self.upgrades = []; self.changed = []; self.pendingHeights = [:]
                let anchor = self.follow || changes.isEmpty ? nil : self.readAnchor()
                if !upgrades.isEmpty { table.reloadData(forRowIndexes:upgrades,columnIndexes:IndexSet(integer:0)) }
                // Commit cached heights immediately before invalidating AppKit's
                // row cache; the delegate never changes estimates between notes.
                self.heights.merge(pending) { _,new in new }
                if !changes.isEmpty, self.follow {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        table.noteHeightOfRows(withIndexesChanged: changes)
                    }
                } else if !changes.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: changes)
                }
                if self.follow {
                    self.scrollToLatest()
                } else if let anchor {
                    self.restoreAnchor(anchor, at: anchor.index)
                }
            }
        }
        @objc func scrolled(_ notification: Notification) {
            guard !refreshing, let table else { return }
            let visible = table.rows(in:table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<NSMaxRange(visible) where rows.indices.contains(row) {
                if table.view(atColumn:0,row:row,makeIfNecessary:false) is SummaryCell { upgrades.insert(row); schedule() }
            }
        }
        // Programmatic row-height and scroll changes also move the clip view.
        // Only AppKit's user scroll notification changes the follow preference.
        @objc func userScrolled(_ notification: Notification) {
            guard let table, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY
            let isAtBottom = bottom - table.visibleRect.maxY <= 4
            guard follow != isAtBottom else { return }
            follow = isAtBottom
            followBinding?.wrappedValue = isAtBottom
            if follow { schedule() }
        }

        private func scrollToLatest() {
            guard let table, let scroll, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY
            moveClip(toY: bottom - scroll.contentView.bounds.height, in: scroll)
        }

        func update(_ values: [TranscriptDisplayRow], follow binding: Binding<Bool>) {
            followBinding = binding
            let shouldFollow = binding.wrappedValue && !follow
            follow = binding.wrappedValue
            let newTurnHeaders = TranscriptDisplayRow.turnHeaders(for: values)
            let headersChanged = newTurnHeaders.count != turnHeaders.count || newTurnHeaders.contains { key, val in turnHeaders[key] !== val }
            let replaced = rows.count != values.count || zip(rows, values).contains { !$0.hasSameItems(as: $1) }
            guard replaced else {
                if headersChanged {
                    turnHeaders = newTurnHeaders
                    if let table {
                        let visible = table.rows(in: table.visibleRect)
                        if visible.location != NSNotFound {
                            for row in visible.location..<NSMaxRange(visible) where rows.indices.contains(row) {
                                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostCell {
                                    configure(cell, row: row)
                                }
                            }
                        }
                    }
                }
                if shouldFollow { schedule() }
                return
            }
            let anchor = follow ? nil : readAnchor()
            if !heights.isEmpty {
                let previous = Dictionary(
                    rows.lazy.filter { self.heights[$0.id] != nil }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let retained = Set(values.compactMap { row in
                    previous[row.id]?.hasSameItems(as: row) == true ? row.id : nil
                })
                heights = heights.filter { retained.contains($0.key) }
            }
            rows = values; turnHeaders = newTurnHeaders; changed = []; upgrades = []; pendingHeights = [:]
            table?.reloadData()
            if follow {
                scrollToLatest()
            } else if let anchor, let row = values.firstIndex(where: { $0.contains(anchor.row.id) }) {
                restoreAnchor(anchor, at: row)
            }
        }

        private struct ViewportAnchor {
            let index: Int
            let row: TranscriptDisplayRow
            let offset: CGFloat
        }

        private func readAnchor() -> ViewportAnchor? {
            guard let table else { return nil }
            let y = table.visibleRect.minY
            // The viewport can start in the inter-row gap.
            let row = table.rows(in: NSRect(x: 0, y: y, width: table.bounds.width, height: table.intercellSpacing.height + 1)).location
            guard rows.indices.contains(row) else { return nil }
            return .init(index: row, row: rows[row], offset: y - table.rect(ofRow: row).minY)
        }

        private func restoreAnchor(_ anchor: ViewportAnchor, at index: Int) {
            guard let table, let scroll, rows.indices.contains(index) else { return }
            let replacement = rows[index]
            let rect = table.rect(ofRow: index)
            let offset: CGFloat
            switch (anchor.row, replacement) {
            case (.item, .item), (.completedTools, .completedTools):
                offset = anchor.row.id == replacement.id ? min(anchor.offset, max(0, rect.height - 1)) : 0
            default:
                // A folded group has no corresponding point inside the old tool detail.
                offset = 0
            }
            moveClip(toY: rect.minY + offset, in: scroll)
        }

        private func moveClip(toY y: CGFloat, in scroll: NSScrollView) {
            let clip = scroll.contentView
            var proposed = clip.bounds
            proposed.origin.y = max(0, y)
            let destination = clip.constrainBoundsRect(proposed).origin
            guard destination != clip.bounds.origin else { return }
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
        }

        func resized(widthChanged: Bool) {
            guard let table, !rows.isEmpty else { return }
            guard widthChanged else {
                if follow { schedule() }
                return
            }
            let visible = table.rows(in:table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<NSMaxRange(visible) where rows.indices.contains(row) {
                if let cell = table.view(atColumn:0,row:row,makeIfNecessary:false) as? HostCell { configure(cell,row:row) }
            }; schedule()
        }
    }
    final class SummaryCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            identifier = .init("summary-cell")
            label.maximumNumberOfLines = 3
            addSubview(label)
            resizeSubviews(withOldSize: .zero)
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            label.frame = NSRect(x: 24, y: 8, width: max(0, bounds.width - 48), height: max(0, bounds.height - 16))
        }

        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
    final class HostCell: NSTableCellView {
        var representedID: String?
        var representedIndex = -1
        var observed = false
        fileprivate let host = NSHostingView(rootView: TranscriptHost(row: nil, turnHeader: nil, width: 600, toolGroupExpansion: ToolGroupExpansion(), onEditUserMessage: nil, changed: {}))
        override init(frame frameRect: NSRect) {
            super.init(frame:frameRect); identifier = .init("message-cell")
            host.sizingOptions = [.intrinsicContentSize]
            host.translatesAutoresizingMaskIntoConstraints = false; addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:leadingAnchor,constant:24),host.topAnchor.constraint(equalTo:topAnchor,constant:8),host.widthAnchor.constraint(greaterThanOrEqualToConstant:100)])
        }
        convenience init() { self.init(frame:.zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
}
private struct TranscriptHost: View {
    let row: TranscriptDisplayRow?
    let turnHeader: TurnRecord?
    let width: CGFloat
    let toolGroupExpansion: ToolGroupExpansion
    let onEditUserMessage: ((TranscriptItem) -> Void)?
    let changed: () -> Void
    var body: some View {
        if let row {
            Group {
                switch row {
                case .item(let item):
                    TranscriptRow(item: item, turnHeader: turnHeader, width: width, onEditUserMessage: onEditUserMessage, contentChanged: changed)
                case .completedTools(let tools):
                    CompletedToolsRow(items: tools, turnHeader: turnHeader, expansion: toolGroupExpansion, contentChanged: changed)
                }
            }
            .id(row.id)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .transaction { $0.animation = nil }
        }
    }
}
