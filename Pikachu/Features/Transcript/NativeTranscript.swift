import AppKit
import SwiftUI
import OrchestrationCore

/// AppKit virtualizes rows and caches measured visible heights. SwiftUI renders
/// visible content; offscreen accessibility queries use inexpensive text summaries.
struct NativeTranscript: NSViewRepresentable {
    @Environment(\.pikachuTypography) private var typography
    let rows: [TranscriptDisplayRow]
    @Binding var follow: Bool
    var composerClearance: CGFloat = 0
    var jump: Jump?
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((URL) -> Void)? = nil
    var onShowToolOutput: ((ToolOutputSelection) -> Void)? = nil
    var replyFooters: [String: TranscriptReplyFooter] = [:]
    var queueFooter: TranscriptQueueFooter? = nil
    static let topClearance: CGFloat = 20
    private static let rowVerticalInset: CGFloat = 3

    struct Jump: Equatable {
        let messageID: String
        private let requestID = UUID()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TranscriptScroll {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    static func makeScrollView(coordinator: Coordinator) -> TranscriptScroll {
        let scroll = TranscriptScroll(), table = NSTableView()
        table.style = .plain
        let column = NSTableColumn(identifier:.init("message")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.backgroundColor = .clear
        table.intercellSpacing = .init(width:0,height:4); table.selectionHighlightStyle = .none
        table.rowHeight = 120
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = coordinator; table.dataSource = coordinator
        table.setAccessibilityIdentifier("transcript")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.verticalScroller = TranscriptScroller(frame: .zero)
        scroll.verticalScroller?.controlSize = .small
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.onResize = { [weak coordinator] widthChanged in
            coordinator?.resized(widthChanged: widthChanged)
        }
        scroll.onVerticalGesture = { [weak coordinator] deltaY in
            coordinator?.scrollByUser(deltaY)
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
    func updateNSView(_ scroll: TranscriptScroll, context: Context) {
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onEditUserMessage = onEditUserMessage
        context.coordinator.onPreviewImage = onPreviewImage
        context.coordinator.onShowToolOutput = onShowToolOutput
        context.coordinator.update(rows, follow: $follow, fontSize: typography.size,
                                   workspaceDirectory: workspaceDirectory,
                                   replyFooters: replyFooters, queueFooter: queueFooter)
        context.coordinator.updateViewport(composerClearance: composerClearance, jump: jump)
    }
    static func dismantleNSView(_ scroll: TranscriptScroll, coordinator: Coordinator) {
        coordinator.stopScrollSample()
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class TranscriptScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { true }

        override func drawKnob() {
            let knob = rect(for: .knob)
            guard !knob.isEmpty else { return }
            let width = min(6, knob.width)
            let thumb = NSRect(x: bounds.maxX - width, y: knob.minY, width: width, height: knob.height)
            let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            PikachuTheme.scrollbarThumbColor(active: hitPart == .knob, increasedContrast: increasedContrast).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
        }

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
            if flag { super.drawKnobSlot(in: slotRect, highlight: flag) }
        }
    }

    final class TranscriptScroll: NSScrollView {
        var onResize: ((_ widthChanged: Bool) -> Void)?
        var onVerticalGesture: ((CGFloat) -> Void)?
        private var lastContentSize: NSSize = .zero
        private var wheelMonitor: Any?
        private enum GestureRoute {
            case awaitingDirection(CGVector)
            case vertical
            case horizontal
        }
        private static let directionThreshold: CGFloat = 4
        private var gestureRoute: GestureRoute?
        private weak var gestureTarget: NSScrollView?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            gestureRoute = nil
            gestureTarget = nil
            if let wheelMonitor {
                NSEvent.removeMonitor(wheelMonitor)
                self.wheelMonitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return false }
                    return self.routeScrollEvent(event, at: event.locationInWindow)
                }
                return consumed ? nil : event
            }
        }

        func routeScrollEvent(_ event: NSEvent, at location: NSPoint) -> Bool {
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let vertical = abs(deltaY) > abs(deltaX)
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                guard vertical, !event.modifierFlags.contains(.shift), transcriptHit(at: location) != nil else { return false }
                scrollWheel(with: event)
                return true
            }

            if event.phase == .began {
                gestureRoute = nil
                gestureTarget = nil
                // A scroller is outside its clip view, so enclosingScrollView
                // can skip the scroll view that owns it.
                if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.shift),
                   let hit = transcriptHit(at: location),
                   let target = sequence(first: hit, next: { $0.superview })
                       .first(where: { $0 is NSScrollView }) as? NSScrollView,
                   target.hasHorizontalScroller, !target.hasVerticalScroller {
                    gestureRoute = .awaitingDirection(.zero)
                    gestureTarget = target
                }
            }

            let gestureFinished = event.phase == .cancelled || event.momentumPhase == .ended
            if case .horizontal = gestureRoute {
                let target = gestureTarget
                let targetIsAttached = target?.window === window && target?.isDescendant(of: contentView) == true
                if gestureFinished || !targetIsAttached {
                    gestureRoute = nil
                    gestureTarget = nil
                }
                guard targetIsAttached, let target, event.phase != .mayBegin else { return false }
                target.scrollWheel(with: event)
                return true
            }
            if gestureFinished {
                gestureRoute = nil
                gestureTarget = nil
                return false
            }

            let hasMovement = deltaX != 0 || deltaY != 0
            var routedDeltaY = deltaY
            if case .awaitingDirection(let pending) = gestureRoute {
                if event.phase == .ended {
                    gestureRoute = nil
                    gestureTarget = nil
                    return false
                }
                guard event.phase == .began || event.phase == .changed else { return false }

                // Hold even a zero-delta began until the axis is known. If AppKit
                // gets the neutral start, later horizontal changed events can stall.
                let movement = CGVector(dx: pending.dx + deltaX, dy: pending.dy + deltaY)
                let horizontalDistance = abs(movement.dx)
                let verticalDistance = abs(movement.dy)
                guard max(horizontalDistance, verticalDistance) >= Self.directionThreshold else {
                    gestureRoute = .awaitingDirection(movement)
                    return true
                }
                if horizontalDistance >= verticalDistance {
                    gestureRoute = nil
                    guard event.phase == .changed, beginHorizontalGesture(from: event, deltaX: movement.dx) else {
                        gestureTarget = nil
                        return false
                    }
                    gestureRoute = .horizontal
                    return true
                }
                gestureRoute = .vertical
                gestureTarget = nil
                routedDeltaY = movement.dy
            }

            guard case .vertical = gestureRoute, hasMovement, event.phase != .mayBegin else { return false }
            if routedDeltaY != 0 {
                onVerticalGesture?(routedDeltaY)
            }
            return true
        }

        private func beginHorizontalGesture(from event: NSEvent, deltaX: CGFloat) -> Bool {
            guard let target = gestureTarget, target.window === window, target.isDescendant(of: contentView),
                  let sample = event.cgEvent?.copy() else { return false }
            // A buffered gesture needs a new native began. Its first movement
            // contains only the horizontal distance selected by the router.
            sample.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
            sample.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            sample.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            sample.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            let roundedDeltaX = Int64(deltaX.rounded())
            sample.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: roundedDeltaX)
            sample.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: roundedDeltaX)
            sample.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
            guard let began = NSEvent(cgEvent: sample) else { return false }
            target.scrollWheel(with: began)
            return true
        }

        private func transcriptHit(at location: NSPoint) -> NSView? {
            guard let root = window?.contentView,
                  let hit = root.hitTest(root.superview?.convert(location, from: nil) ?? location),
                  hit === contentView || hit.isDescendant(of: contentView) else { return nil }
            return hit
        }

        override func layout() {
            super.layout()
            let size = NSSize(width: bounds.width, height: contentSize.height)
            let widthChanged = size.width != lastContentSize.width
            let heightChanged = abs(size.height - lastContentSize.height) > 1
            guard widthChanged || heightChanged else { return }
            lastContentSize = size
            onResize?(widthChanged)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var rows: [NativeTranscriptRow] = []
        private var queueFooter: TranscriptQueueFooter?
        private var fontSize: InterfaceFontSize = .standard
        private var workspaceDirectory: URL?
        var onOpenFile: ((URL) -> Void)?
        var onEditUserMessage: ((TranscriptItem) -> Void)?
        var onPreviewImage: ((URL) -> Void)?
        var onShowToolOutput: ((ToolOutputSelection) -> Void)?
        private let toolExpansion = ToolCallExpansion()
        private let turnChangesExpansion = TurnChangesExpansion()
        private let replyHover = TranscriptReplyHover()
        private var follow = true
        private var followBinding: Binding<Bool>?
        private var lastJump: Jump?
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
        // Match SwiftUI's full viewport even when a legacy scroller consumes clip width.
        private var viewportWidth: CGFloat { scroll?.bounds.width ?? 600 }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        private func estimate(_ row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }
            switch rows[row].content {
            case .turnHeader: return ceil(PikachuTypography(size: fontSize).pointSize(for: .caption) * 1.25) + 14
            case .toolCalls, .thinking: return 24
            case .turnChanges: return 38
            case .item: return 120
            }
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }; return heights[rows[row].id] ?? estimate(row)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            if !tableView.rect(ofRow:row).intersects(tableView.visibleRect) {
                let cell = (tableView.makeView(withIdentifier:.init("summary-cell"),owner:nil) as? SummaryCell) ?? SummaryCell()
                cell.viewportWidth = viewportWidth
                cell.label.font = PikachuTypography(size: fontSize).nsFont(.body)
                switch rows[row].content {
                case .item(let item):
                    cell.label.stringValue = item.text
                case .turnHeader(let turn):
                    cell.label.stringValue = TurnHeaderSummary(turn: turn).accessibilityText
                case .turnChanges(let turn):
                    cell.label.stringValue = String(localized: "本轮 \(turn.fileChanges?.files.count ?? 0) 个文件变更")
                case .thinking:
                    cell.label.stringValue = String(localized: "思考中")
                case .toolCalls(let tools):
                    if tools.count == 1, let tool = tools.first?.toolSummary {
                        cell.label.stringValue = ToolCallPresentation(tool).accessibilityDescription
                    } else {
                        cell.label.stringValue = ToolCallsSummary(items: tools).description
                    }
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
            let width = WorkbenchReadingColumn.width(in: viewportWidth)
            cell.columnLeading.constant = WorkbenchReadingColumn.inset(in: viewportWidth)
            let needsMeasurement = heights[id] == nil || cell.host.rootView.width != width || cell.host.rootView.row?.id != id || cell.host.rootView.workspaceDirectory != workspaceDirectory
            cell.host.rootView = TranscriptHost(
                row: content,
                width: width,
                fontSize: fontSize,
                workspaceDirectory: workspaceDirectory,
                toolExpansion: toolExpansion,
                onOpenFile: onOpenFile == nil ? nil : { [weak self] in
                    self?.onOpenFile?($0)
                },
                onEditUserMessage: onEditUserMessage,
                onPreviewImage: { [weak self] in self?.onPreviewImage?($0) },
                onShowToolOutput: { [weak self] in self?.onShowToolOutput?($0) },
                turnChangesExpansion: turnChangesExpansion,
                replyHover: replyHover,
                queueFooter: queueFooter?.itemID == id ? queueFooter?.text : nil
            ) { [weak self, weak cell] in
                self?.scheduleMeasure(for: cell, expectedID: id)
            }
            if needsMeasurement {
                scheduleMeasure(for: cell, expectedID: id)
            }
        }
        private func scheduleMeasure(for cell: HostCell?, expectedID: String) {
            DispatchQueue.main.async { [weak self, weak cell] in
                guard let self, let cell, cell.representedID == expectedID else { return }
                cell.host.invalidateIntrinsicContentSize(); cell.host.layoutSubtreeIfNeeded()
                self.stageHeight(cell)
            }
        }
        @objc func hostResized(_ notification: Notification) {
            guard let host = notification.object as? NSView, let cell = host.superview as? HostCell else { return }
            stageHeight(cell)
        }
        private func stageHeight(_ cell: HostCell) {
            let row = cell.representedIndex
            guard let id = cell.representedID, rows.indices.contains(row), rows[row].id == id, let table else { return }
            let height = max(20, ceil(cell.host.frame.height) + 2 * NativeTranscript.rowVerticalInset)
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
        // Only user-initiated scrolling changes the follow preference.
        @objc func userScrolled(_ notification: Notification) {
            updateFollowAfterUserScroll()
        }

        func scrollByUser(_ deltaY: CGFloat) {
            guard let scroll, moveClip(toY: scroll.contentView.bounds.minY - deltaY, in: scroll) else { return }
            updateFollowAfterUserScroll()
        }

        private func updateFollowAfterUserScroll() {
            guard let table, let scroll, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY + scroll.contentInsets.bottom
            let isAtBottom = bottom - scroll.contentView.bounds.maxY <= 4
            guard follow != isAtBottom else { return }
            follow = isAtBottom
            followBinding?.wrappedValue = isAtBottom
            if follow { schedule() }
        }

        private func scrollToLatest() {
            guard let table, let scroll, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY + scroll.contentInsets.bottom
            moveClip(toY: bottom - scroll.contentView.bounds.height, in: scroll)
        }

        func updateViewport(composerClearance: CGFloat, jump: Jump?) {
            guard let scroll, let table else { return }
            let bottom = composerClearance + 8
            if scroll.contentInsets.top != NativeTranscript.topClearance || abs(scroll.contentInsets.bottom - bottom) > 0.5 {
                scroll.contentInsets = NSEdgeInsets(top: NativeTranscript.topClearance, left: 0, bottom: bottom, right: 0)
                if follow { schedule() }
            }
            guard let jump, jump != lastJump,
                  let row = rows.firstIndex(where: { $0.id == jump.messageID }) else { return }
            lastJump = jump
            moveClip(toY: table.rect(ofRow: row).minY - NativeTranscript.topClearance, in: scroll)
        }

        func update(_ content: [TranscriptDisplayRow], follow binding: Binding<Bool>, fontSize: InterfaceFontSize = .standard,
                    workspaceDirectory: URL? = nil,
                    replyFooters: [String: TranscriptReplyFooter] = [:], queueFooter: TranscriptQueueFooter? = nil) {
            let values = content.map { NativeTranscriptRow(content: $0, replyFooter: replyFooters[$0.id]) }
            followBinding = binding
            let shouldFollow = binding.wrappedValue && !follow
            follow = binding.wrappedValue
            let fontChanged = self.fontSize != fontSize
            self.fontSize = fontSize
            let workspaceChanged = self.workspaceDirectory != workspaceDirectory
            self.workspaceDirectory = workspaceDirectory
            let replaced = rows.count != values.count || zip(rows, values).contains { !$0.hasSameItems(as: $1) }
            let footerChanged = self.queueFooter != queueFooter
            guard replaced || fontChanged || workspaceChanged || footerChanged else {
                if shouldFollow { schedule() }
                return
            }
            let anchor = follow ? nil : readAnchor()
            if footerChanged {
                if let old = self.queueFooter { heights.removeValue(forKey: old.itemID) }
                if let queueFooter { heights.removeValue(forKey: queueFooter.itemID) }
                self.queueFooter = queueFooter
            }
            if fontChanged {
                heights.removeAll()
            } else if !heights.isEmpty {
                let previous = Dictionary(
                    rows.lazy.filter { self.heights[$0.id] != nil }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let retained = Set(values.compactMap { row -> String? in
                    guard let old = previous[row.id] else { return nil }
                    // Keep an expanded row's last measurement until its updated view is laid out.
                    if case .toolCalls = row.content, case .toolCalls = old.content { return row.id }
                    return old.hasSameItems(as: row) ? row.id : nil
                })
                heights = heights.filter { retained.contains($0.key) }
            }
            rows = values; changed = []; upgrades = []; pendingHeights = [:]
            table?.reloadData()
            if follow {
                scrollToLatest()
            } else if let anchor, let lastIndex = values.indices.last {
                let row = values.firstIndex(where: { $0.contains(anchor.row.id) }) ?? min(anchor.index, lastIndex)
                restoreAnchor(anchor, at: row)
            }
        }

        private struct ViewportAnchor {
            let index: Int
            let row: NativeTranscriptRow
            let offset: CGFloat
        }

        private func readAnchor() -> ViewportAnchor? {
            guard let table, let scroll else { return nil }
            let y = scroll.contentView.bounds.minY
            // The viewport can start in the inter-row gap.
            let row = table.rows(in: NSRect(x: 0, y: max(0, y), width: table.bounds.width, height: table.intercellSpacing.height + 1)).location
            guard rows.indices.contains(row) else { return nil }
            return .init(index: row, row: rows[row], offset: y - table.rect(ofRow: row).minY)
        }

        private func restoreAnchor(_ anchor: ViewportAnchor, at index: Int) {
            guard let table, let scroll, rows.indices.contains(index) else { return }
            let replacement = rows[index]
            let rect = table.rect(ofRow: index)
            let offset: CGFloat
            switch (anchor.row.content, replacement.content) {
            case (.item, .item), (.turnHeader, .turnHeader), (.turnChanges, .turnChanges),
                 (.toolCalls, .toolCalls):
                offset = anchor.row.id == replacement.id ? min(anchor.offset, max(0, rect.height - 1)) : 0
            default:
                // A folded group has no corresponding point inside the old tool detail.
                offset = 0
            }
            moveClip(toY: rect.minY + offset, in: scroll)
        }

        @discardableResult
        private func moveClip(toY y: CGFloat, in scroll: NSScrollView) -> Bool {
            let clip = scroll.contentView
            var proposed = clip.bounds
            proposed.origin.y = y
            let destination = clip.constrainBoundsRect(proposed).origin
            guard destination != clip.bounds.origin else { return false }
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            return true
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
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                if let hostCell = cell as? HostCell {
                    hostCell.columnLeading.constant = WorkbenchReadingColumn.inset(in: viewportWidth)
                    if hostCell.host.rootView.width != WorkbenchReadingColumn.width(in: viewportWidth) {
                        configure(hostCell, row: row)
                    }
                } else if let summaryCell = cell as? SummaryCell {
                    summaryCell.viewportWidth = viewportWidth
                }
            }
            schedule()
        }
    }
    final class SummaryCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        var viewportWidth: CGFloat? { didSet { layoutLabel() } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            identifier = .init("summary-cell")
            label.maximumNumberOfLines = 3
            addSubview(label)
            resizeSubviews(withOldSize: .zero)
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            layoutLabel()
        }

        private func layoutLabel() {
            let inset = NativeTranscript.rowVerticalInset
            let width = viewportWidth ?? bounds.width
            label.frame = NSRect(x: WorkbenchReadingColumn.inset(in: width), y: inset,
                                 width: WorkbenchReadingColumn.width(in: width), height: max(0, bounds.height - 2 * inset))
        }

        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
    final class HostCell: NSTableCellView {
        var representedID: String?
        var representedIndex = -1
        var observed = false
        fileprivate let host = NSHostingView(rootView: TranscriptHost(row: nil, width: 600, fontSize: .standard, toolExpansion: ToolCallExpansion(), onEditUserMessage: nil, changed: {}))
        fileprivate lazy var columnLeading = host.leadingAnchor.constraint(equalTo: leadingAnchor)
        override init(frame frameRect: NSRect) {
            super.init(frame:frameRect); identifier = .init("message-cell")
            host.sizingOptions = [.intrinsicContentSize]
            host.translatesAutoresizingMaskIntoConstraints = false; addSubview(host)
            NSLayoutConstraint.activate([
                columnLeading,
                host.topAnchor.constraint(equalTo: topAnchor, constant: NativeTranscript.rowVerticalInset)
            ])
        }
        convenience init() { self.init(frame:.zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
}
@MainActor private struct NativeTranscriptRow {
    let content: TranscriptDisplayRow
    let replyFooter: TranscriptReplyFooter?

    var id: String { content.id }

    func hasSameItems(as other: Self) -> Bool {
        guard content.hasSameItems(as: other.content) else { return false }
        switch (replyFooter, other.replyFooter) {
        case (nil, nil): return true
        case (let footer?, let otherFooter?): return footer.hasSameItems(as: otherFooter)
        default: return false
        }
    }

    func contains(_ itemID: String) -> Bool { content.contains(itemID) }
}

private struct TranscriptHost: View {
    let row: NativeTranscriptRow?
    let width: CGFloat
    let fontSize: InterfaceFontSize
    var workspaceDirectory: URL? = nil
    let toolExpansion: ToolCallExpansion
    var onOpenFile: ((URL) -> Void)? = nil
    let onEditUserMessage: ((TranscriptItem) -> Void)?
    var onPreviewImage: ((URL) -> Void)? = nil
    var onShowToolOutput: ((ToolOutputSelection) -> Void)? = nil
    var turnChangesExpansion = TurnChangesExpansion()
    var replyHover = TranscriptReplyHover()
    var queueFooter: String? = nil
    let changed: () -> Void
    var body: some View {
        if let row {
            Group {
                switch row.content {
                case .item(let item) where item.kind == .assistant:
                    replyRegion(row) { messageRow(item) }
                case .item(let item):
                    messageRow(item)
                case .turnHeader(let turn):
                    TurnHeaderView(turn: turn)
                        .accessibilityIdentifier(row.id)
                case .turnChanges(let turn):
                    if let changes = turn.fileChanges {
                        replyRegion(row) {
                            TurnChangesRow(changes: changes, id: row.id, expansion: turnChangesExpansion,
                                           workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile,
                                           contentChanged: changed)
                        }
                    }
                case .thinking:
                    TranscriptThinkingRow()
                case .toolCalls(let tools):
                    ToolCallsRow(items: tools, expansion: toolExpansion, onShowOutput: onShowToolOutput, contentChanged: changed)
                }
            }
            .id(row.id)
            .pikachuTypography(fontSize)
            .disclosureGroupStyle(FlatDisclosureStyle())
            .environment(\.openURL, TranscriptFileOpener.openAction(workspaceDirectory: workspaceDirectory, openFile: onOpenFile))
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .transaction { $0.animation = nil }
        }
    }

    private func messageRow(_ item: TranscriptItem) -> some View {
        TranscriptRow(item: item, width: width, workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile,
                      onEditUserMessage: onEditUserMessage,
                      onPreviewImage: onPreviewImage, queueFooter: queueFooter, contentChanged: changed)
    }

    private func replyRegion<Content: View>(_ row: NativeTranscriptRow, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            if let reply = row.replyFooter {
                AssistantReplyActions(reply: reply, rowID: row.id, hover: replyHover)
            }
        }
        .contentShape(.rect)
        .onHover { replyHover.setHovered($0, rowID: row.id) }
        .onDisappear { replyHover.setHovered(false, rowID: row.id) }
    }
}
