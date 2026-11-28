import AppKit
import QuartzCore
import SwiftUI
import OrchestrationCore

/// AppKit virtualizes rows and caches measured visible heights. SwiftUI renders
/// visible content; offscreen accessibility queries use inexpensive text summaries.
struct NativeTranscript: NSViewRepresentable {
    @Environment(\.zivviTypography) private var typography
    let rows: [TranscriptDisplayRow]
    @Binding var follow: Bool
    var scrolledToTop: Binding<Bool>? = nil
    var extraTopClearance: CGFloat = 0
    var composerClearance: CGFloat = 0
    var jump: Jump?
    var workspaceDirectory: URL? = nil
    var approvalProjectDirectory: String? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var onShowToolOutput: ((ToolOutputSelection) -> Void)? = nil
    var replyFooters: [String: TranscriptReplyFooter] = [:]
    var queueFooter: TranscriptQueueFooter? = nil
    var scrollState: TranscriptScrollState? = nil
    var historyLoading = false
    static let topClearance: CGFloat = 20
    private static let rowVerticalInset = ZivviSpacing.timelineRowInset

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
        table.intercellSpacing = .init(width:0,height:ZivviSpacing.timelineRowGap); table.selectionHighlightStyle = .none
        table.rowHeight = 120
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = coordinator; table.dataSource = coordinator
        table.setAccessibilityIdentifier("transcript")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        WorkbenchScroller.install(in: scroll, axis: .vertical)
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
            DiagnosticMetrics.shared.register(coordinator)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator,selector:#selector(Coordinator.scrolled(_:)),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.userScrolled(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.liveScrollWillStart(_:)),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.liveScrollDidEnd(_:)),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: nil)
        return scroll
    }
    func updateNSView(_ scroll: TranscriptScroll, context: Context) {
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onOpenHandoffFile = onOpenHandoffFile
        context.coordinator.onEditUserMessage = onEditUserMessage
        context.coordinator.onPreviewImage = onPreviewImage
        context.coordinator.onShowToolOutput = onShowToolOutput
        context.coordinator.scrolledToTopBinding = scrolledToTop
        context.coordinator.attach(scrollState: scrollState)
        context.coordinator.update(rows, follow: $follow, fontSize: typography.size,
                                   workspaceDirectory: workspaceDirectory,
                                   approvalProjectDirectory: approvalProjectDirectory,
                                   replyFooters: replyFooters, queueFooter: queueFooter)
        context.coordinator.updateViewport(topClearance: extraTopClearance,
                                           composerClearance: composerClearance,
                                           jump: jump)
        if !historyLoading { context.coordinator.restoreSessionPosition() }
    }
    static func dismantleNSView(_ scroll: TranscriptScroll, coordinator: Coordinator) {
        if DiagnosticMetrics.shared.measuresPixels { DiagnosticMetrics.shared.unregister(coordinator) }
        coordinator.stopScrollSample()
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class TranscriptScroll: NSScrollView {
        var onResize: ((_ widthChanged: Bool) -> Void)?
        var onVerticalGesture: ((CGFloat) -> Void)?
        var forwardHorizontalWheel: (NSScrollView, NSEvent) -> Void = { $0.scrollWheel(with: $1) }
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
                // Include the hit itself when locating the innermost scroll view.
                if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.shift),
                   let hit = transcriptHit(at: location),
                   let target = sequence(first: hit, next: { $0.superview })
                       .first(where: { $0 is NSScrollView }) as? NSScrollView,
                   TranscriptHorizontalScrollMarker.matches(target) {
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
                forwardHorizontalWheel(target, event)
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
            forwardHorizontalWheel(target, began)
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

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, TranscriptScrollDiagnosticTarget {
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var rows: [NativeTranscriptRow] = []
        private var queueFooter: TranscriptQueueFooter?
        private var fontSize: InterfaceFontSize = .standard
        private var workspaceDirectory: URL?
        private var approvalProjectDirectory: String?
        var onOpenFile: ((URL) -> Void)?
        var onOpenHandoffFile: HandoffFileOpener?
        var onEditUserMessage: ((TranscriptItem) -> Void)?
        var onPreviewImage: ((ImagePreviewSelection) -> Void)?
        var onShowToolOutput: ((ToolOutputSelection) -> Void)?
        var scrolledToTopBinding: Binding<Bool>?
        private let toolExpansion = ToolCallExpansion()
        private let turnChangesExpansion = TurnChangesExpansion()
        private let handoffExpansion = HandoffRowExpansion()
        private let replyHover = TranscriptReplyHover()
        private let markdownStore = TranscriptMarkdownStore()
        private var pendingRestore: TranscriptReadingAnchor?
        private weak var scrollState: TranscriptScrollState?
        private let fallbackApprovalExpansion = ApprovalRecordExpansion()
        private var follow = true
        private var followBinding: Binding<Bool>?
        private var scrolledToTop = false
        private var lastJump: Jump?
        private var lastExtraTopClearance: CGFloat = 0
        private var lastComposerClearance: CGFloat = 0
        private var lastReadingColumnWidth: CGFloat?
        private var isLiveScrolling = false
        private var deferredBottomFollow = false
        private var scheduled = false
        private var refreshing = false
        private var changed = IndexSet(), upgrades = IndexSet()
        private var heights: [String:CGFloat] = [:], pendingHeights: [String:CGFloat] = [:]
        private var sampleDriver: TranscriptScrollSample?
        func attach(scrollState: TranscriptScrollState?) {
            guard self.scrollState !== scrollState else { return }
            self.scrollState = scrollState
            if let scrollState {
                scrollState.coordinator = self
                pendingRestore = scrollState.follow ? nil : scrollState.readingAnchor
                follow = scrollState.follow
                scrolledToTop = scrollState.scrolledToTop
            }
        }
        func setFollowFromUser(_ value: Bool) {
            pendingRestore = nil
            follow = value
            followBinding?.wrappedValue = value
            scrollState?.follow = value
            if value {
                scrollState?.jump = nil
                schedule()
            }
        }
        func jumpTo(messageID: String) {
            pendingRestore = nil
            follow = false
            followBinding?.wrappedValue = false
            scrollState?.follow = false
            let next = Jump(messageID: messageID)
            scrollState?.jump = next
            updateViewport(topClearance: lastExtraTopClearance, composerClearance: lastComposerClearance, jump: next)
            rememberPosition()
        }
        var diagnosticWindow: NSWindow? { scroll?.window }
        func startScrollSample() -> Bool {
            guard !follow, rows.count >= 5_000, let scroll, let table, scroll.window != nil else { return false }
            stopScrollSample()
            let firstRow = table.rows(in: table.visibleRect).location
            sampleDriver = TranscriptScrollSample(scroll: scroll, firstRow: firstRow)
            return true
        }
        func positionScrollSample(at row: Int) -> Bool {
            guard !follow, rows.count >= 5_000, rows.indices.contains(row), let scroll, let table,
                  scroll.window != nil else { return false }
            stopScrollSample()
            moveClip(toY: table.rect(ofRow: row).minY, in: scroll)
            return true
        }
        func stopScrollSample() { sampleDriver?.stop(); sampleDriver = nil }
        // Match SwiftUI's full viewport even when a legacy scroller consumes clip width.
        private var viewportWidth: CGFloat { scroll?.bounds.width ?? 600 }
        private func hostingRect(in tableView: NSTableView) -> NSRect {
            let visible = tableView.visibleRect
            guard !visible.isEmpty else { return visible }
            let margin = min(max(visible.height, 480), 1_200)
            return visible.insetBy(dx: 0, dy: -margin)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        private func estimate(_ row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }
            return rows[row].groupInset + contentEstimate(row)
        }
        private func contentEstimate(_ row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }
            let typography = ZivviTypography(size: fontSize)
            switch rows[row].content {
            case .modelChange: return ceil(typography.pointSize(for: .callout) * 1.38) + 18
            case .turnHeader: return ceil(typography.pointSize(for: .caption) * 1.25) + 14
            case .toolCalls, .thinking: return 24
            case .turnChanges: return 38
            case .turnFailure: return 96
            case .item(let item): return estimateItemHeight(item, typography: typography)
            }
        }
        private func estimateItemHeight(_ item: TranscriptItem, typography: ZivviTypography) -> CGFloat {
            let columnWidth = max(200, WorkbenchReadingColumn.width(in: viewportWidth))
            let bodySize = typography.pointSize(for: .body)
            let lineHeight = ceil(bodySize * (item.kind == .user ? 1.57 : 1.38))
            let rawText = item.kind == .user ? item.editableText : item.text
            let hasMessageSurface = item.kind == .user && item.delivery.showsBrandMessageMarker
            let textWidth = max(1, columnWidth - (hasMessageSurface ? 2 * UserMessageSurface.horizontalInset : 0))
            let charsPerLine = max(16, Int(floor(textWidth / (bodySize * 0.62))))
            var lineCount = 0
            rawText.enumerateSubstrings(in: rawText.startIndex..<rawText.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                let length = rawText.distance(from: range.lowerBound, to: range.upperBound)
                lineCount += max(1, (length + charsPerLine - 1) / charsPerLine)
            }
            if lineCount == 0 { lineCount = 1 }
            var estimated = CGFloat(lineCount) * lineHeight + (item.kind == .user ? (hasMessageSurface ? 68 : 36) : 16)
            if item.kind == .user, !item.attachedFiles.isEmpty {
                estimated += 88
            }
            return min(2_400, max(44, estimated))
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 120 }; return heights[rows[row].id] ?? estimate(row)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            if !tableView.rect(ofRow: row).intersects(hostingRect(in: tableView)) {
                let cell = (tableView.makeView(withIdentifier:.init("summary-cell"),owner:nil) as? SummaryCell) ?? SummaryCell()
                cell.viewportWidth = viewportWidth
                cell.label.font = ZivviTypography(size: fontSize).nsFont(.body)
                cell.label.setAccessibilityLabel(nil)
                switch rows[row].content {
                case .modelChange(_, let change):
                    cell.label.stringValue = change.title
                case .item(let item):
                    cell.label.stringValue = item.kind == .user ? item.editableText : item.text
                    if item.kind == .user {
                        cell.label.setAccessibilityLabel(String(localized: "用户消息"))
                    }
                case .turnHeader(let turn):
                    cell.label.stringValue = TurnHeaderSummary(turn: turn).accessibilityText
                case .turnChanges(let turn):
                    cell.label.stringValue = String(localized: "本轮 \(turn.fileChanges?.files.count ?? 0) 个文件变更")
                case .turnFailure(let turn):
                    cell.label.stringValue = turn.failure?.detail ?? String(localized: "执行失败")
                case .thinking(let turn):
                    cell.label.stringValue = TranscriptThinkingRow.isWaiting(turn.thoughtText)
                        ? String(localized: TranscriptThinkingRow.waitingTitle)
                        : "\(String(localized: "思考中"))：\(turn.thoughtText)"
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
        private lazy var premeasureHost: NSHostingView<TranscriptHost> = {
            let host = NSHostingView(rootView: TranscriptHost(
                row: nil, width: 600, fontSize: .standard, toolExpansion: toolExpansion,
                onEditUserMessage: nil, changed: {}
            ))
            host.sizingOptions = [.intrinsicContentSize]
            return host
        }()
        private func makeTranscriptHost(for content: NativeTranscriptRow, width: CGFloat, cell: HostCell?) -> TranscriptHost {
            let id = content.id
            let openHandoffFile: HandoffFileOpener?
            if onOpenHandoffFile == nil {
                openHandoffFile = nil
            } else {
                openHandoffFile = { [weak self] path, directory in
                    guard let open = self?.onOpenHandoffFile else { return .cancelled }
                    return await open(path, directory)
                }
            }
            return TranscriptHost(
                row: content,
                width: width,
                fontSize: fontSize,
                workspaceDirectory: workspaceDirectory,
                approvalProjectDirectory: approvalProjectDirectory,
                markdownStore: markdownStore,
                toolExpansion: toolExpansion,
                onOpenFile: onOpenFile == nil ? nil : { [weak self] in
                    self?.onOpenFile?($0)
                },
                onOpenHandoffFile: openHandoffFile,
                onEditUserMessage: onEditUserMessage,
                onPreviewImage: onPreviewImage == nil ? nil : { [weak self] in
                    self?.onPreviewImage?($0)
                },
                onShowToolOutput: { [weak self] in self?.onShowToolOutput?($0) },
                turnChangesExpansion: turnChangesExpansion,
                handoffExpansion: handoffExpansion,
                approvalExpansion: scrollState?.approvalExpansion ?? fallbackApprovalExpansion,
                replyHover: replyHover,
                queueFooter: queueFooter?.itemID == id ? queueFooter?.text : nil
            ) { [weak self, weak cell] in
                guard let cell else { return }
                self?.scheduleMeasure(for: cell, expectedID: id)
            }
        }
        private func configure(_ cell: HostCell, row: Int) {
            let content = rows[row], id = content.id
            cell.representedID = id
            cell.representedIndex = row
            let width = WorkbenchReadingColumn.width(in: viewportWidth)
            cell.columnLeading.constant = WorkbenchReadingColumn.inset(in: viewportWidth)
            let needsMeasurement = heights[id] == nil || cell.host.rootView.width != width || cell.host.rootView.row?.id != id || cell.host.rootView.workspaceDirectory != workspaceDirectory
            cell.host.rootView = makeTranscriptHost(for: content, width: width, cell: cell)
            if needsMeasurement {
                let measured = ceil(cell.host.fittingSize.height) + 2 * NativeTranscript.rowVerticalInset
                if measured.isFinite, measured >= 20, measured < 1_000_000,
                   abs((pendingHeights[id] ?? heights[id] ?? estimate(row)) - measured) > 1 {
                    pendingHeights[id] = measured
                    changed.insert(row)
                    if !refreshing { schedule() }
                }
                scheduleMeasure(for: cell, expectedID: id)
            }
        }
        private func premeasureBufferedRowIfNeeded(_ row: Int, width: CGFloat) {
            guard rows.indices.contains(row) else { return }
            let content = rows[row], id = content.id
            guard heights[id] == nil, pendingHeights[id] == nil else { return }
            premeasureHost.rootView = makeTranscriptHost(for: content, width: width, cell: nil)
            let measured = ceil(premeasureHost.fittingSize.height) + 2 * NativeTranscript.rowVerticalInset
            guard measured.isFinite, measured >= 20, measured < 1_000_000 else { return }
            if abs(estimate(row) - measured) > 1 {
                pendingHeights[id] = measured
                changed.insert(row)
                if !refreshing { schedule() }
            } else {
                heights[id] = measured
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
                  table.rect(ofRow: row).intersects(hostingRect(in: table)) else { return }
            pendingHeights[id] = height; changed.insert(row); schedule()
        }
        private func schedule() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }; self.scheduled = false; self.refreshing = true
                defer { self.refreshing = false }
                let upgrades = self.upgrades
                self.upgrades = []
                let anchor = self.follow ? nil : self.readAnchor()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    if !upgrades.isEmpty {
                        table.reloadData(forRowIndexes: upgrades, columnIndexes: IndexSet(integer: 0))
                    }
                    let changes = self.changed, pending = self.pendingHeights
                    self.changed = []; self.pendingHeights = [:]
                    // Commit cached heights immediately before invalidating AppKit's
                    // row cache; the delegate never changes estimates between notes.
                    self.heights.merge(pending) { _, new in new }
                    if !changes.isEmpty {
                        table.noteHeightOfRows(withIndexesChanged: changes)
                    }
                    if self.follow {
                        self.scrollToLatest()
                    } else if let anchor, !changes.isEmpty, changes.contains(where: { $0 < anchor.index }) {
                        self.restoreAnchor(anchor, at: anchor.index)
                    }
                }
                CATransaction.commit()
                self.updateScrolledToTop()
            }
        }
        @objc func scrolled(_ notification: Notification) {
            guard !refreshing, let table else { return }
            rememberPosition()
            updateScrolledToTop()
            let buffered = table.rows(in: hostingRect(in: table))
            guard buffered.location != NSNotFound else { return }
            let width = WorkbenchReadingColumn.width(in: viewportWidth)
            var premeasured = 0
            for row in buffered.location..<NSMaxRange(buffered) where rows.indices.contains(row) {
                let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                if view is SummaryCell {
                    upgrades.insert(row)
                    schedule()
                } else if let hostCell = view as? HostCell {
                    stageHeight(hostCell)
                } else if view == nil, premeasured < 12 {
                    let id = rows[row].id
                    if heights[id] == nil, pendingHeights[id] == nil {
                        premeasureBufferedRowIfNeeded(row, width: width)
                        premeasured += 1
                    }
                }
            }
        }
        @objc func selectionChanged(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, let scroll,
                  text.isDescendant(of: scroll), text.selectedRange().length > 0 else { return }
            setFollowFromUser(false)
            rememberPosition()
        }
        @objc func liveScrollWillStart(_ notification: Notification) {
            pendingRestore = nil
            isLiveScrolling = true
        }
        @objc func liveScrollDidEnd(_ notification: Notification) {
            isLiveScrolling = false
            updateFollowAfterUserScroll()
            if deferredBottomFollow {
                deferredBottomFollow = false
                if follow { schedule() }
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
            pendingRestore = nil
            defer { rememberPosition() }
            guard let table, let scroll, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY + scroll.contentInsets.bottom
            let isAtBottom = bottom - scroll.contentView.bounds.maxY <= 4
            guard follow != isAtBottom else { return }
            follow = isAtBottom
            followBinding?.wrappedValue = isAtBottom
            scrollState?.follow = isAtBottom
            if follow {
                if isLiveScrolling {
                    deferredBottomFollow = true
                } else {
                    schedule()
                }
            } else {
                deferredBottomFollow = false
            }
        }

        private func scrollToLatest() {
            guard let table, let scroll, !rows.isEmpty else { return }
            let bottom = table.rect(ofRow: rows.count - 1).maxY + scroll.contentInsets.bottom
            moveClip(toY: bottom - scroll.contentView.bounds.height, in: scroll)
        }

        func updateViewport(topClearance: CGFloat = 0, composerClearance: CGFloat, jump: Jump?) {
            guard let scroll, let table else { return }
            lastExtraTopClearance = topClearance
            lastComposerClearance = composerClearance
            let top = NativeTranscript.topClearance + topClearance
            let bottom = composerClearance + 8
            if abs(scroll.contentInsets.top - top) > 0.5 || abs(scroll.contentInsets.bottom - bottom) > 0.5 {
                scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
                if follow { schedule() }
            }
            updateScrolledToTop()
            guard let jump, jump != lastJump,
                  let row = rows.firstIndex(where: { $0.id == jump.messageID }) else { return }
            lastJump = jump
            moveClip(toY: table.rect(ofRow: row).minY - top, in: scroll)
        }

        private func updateScrolledToTop() {
            guard let table, let scroll, !rows.isEmpty else {
                publishScrolledToTop(false)
                return
            }
            let contentHeight = table.rect(ofRow: rows.count - 1).maxY
            let visibleHeight = scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
            let hasOverflow = contentHeight > visibleHeight + 4
            let atTop = hasOverflow && scroll.contentView.bounds.minY <= -scroll.contentInsets.top + 12
            publishScrolledToTop(atTop)
        }

        private func publishScrolledToTop(_ value: Bool) {
            guard scrolledToTop != value else { return }
            scrolledToTop = value
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrolledToTopBinding?.wrappedValue = self.scrolledToTop
                self.scrollState?.scrolledToTop = self.scrolledToTop
            }
        }

        func update(_ content: [TranscriptDisplayRow], follow binding: Binding<Bool>, fontSize: InterfaceFontSize = .standard,
                    workspaceDirectory: URL? = nil, approvalProjectDirectory: String? = nil,
                    replyFooters: [String: TranscriptReplyFooter] = [:], queueFooter: TranscriptQueueFooter? = nil) {
            let values = NativeTranscriptRow.project(content, footers: replyFooters,
                                                     typography: ZivviTypography(size: fontSize))
            followBinding = binding
            let effectiveFollow = scrollState?.follow ?? binding.wrappedValue
            let shouldFollow = effectiveFollow && !follow
            follow = effectiveFollow
            let fontChanged = self.fontSize != fontSize
            self.fontSize = fontSize
            let workspaceChanged = self.workspaceDirectory != workspaceDirectory
            self.workspaceDirectory = workspaceDirectory
            if workspaceChanged { markdownStore.clearPathCache() }
            let approvalProjectChanged = switch (self.approvalProjectDirectory, approvalProjectDirectory) {
            case let (previous?, current?): !previous.utf8.elementsEqual(current.utf8)
            case (nil, nil): false
            default: true
            }
            self.approvalProjectDirectory = approvalProjectDirectory
            if lastReadingColumnWidth == nil {
                lastReadingColumnWidth = WorkbenchReadingColumn.width(in: viewportWidth)
            }
            let replaced = rows.count != values.count || zip(rows, values).contains { !$0.hasSameItems(as: $1) }
            let footerChanged = self.queueFooter != queueFooter
            guard replaced || fontChanged || workspaceChanged || approvalProjectChanged || footerChanged else {
                if shouldFollow { schedule() }
                return
            }
            let anchor = follow ? nil : readAnchor()
            let previousRows = rows
            var affectedFooterIDs: Set<String> = []
            if footerChanged {
                if let old = self.queueFooter {
                    heights.removeValue(forKey: old.itemID)
                    affectedFooterIDs.insert(old.itemID)
                }
                if let queueFooter {
                    heights.removeValue(forKey: queueFooter.itemID)
                    affectedFooterIDs.insert(queueFooter.itemID)
                }
                self.queueFooter = queueFooter
            }
            if fontChanged || approvalProjectChanged {
                heights.removeAll()
            } else if !heights.isEmpty {
                let previous = Dictionary(
                    rows.lazy.filter { self.heights[$0.id] != nil }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let retained = Set(values.compactMap { row -> String? in
                    guard let old = previous[row.id], old.groupInset == row.groupInset else { return nil }
                    // Keep an expanded row's last measurement until its updated view is laid out.
                    if case .toolCalls = row.content, case .toolCalls = old.content { return row.id }
                    if case .thinking = row.content, case .thinking = old.content { return row.id }
                    return old.hasSameItems(as: row) ? row.id : nil
                })
                heights = heights.filter { retained.contains($0.key) }
            }
            rows = values; changed = []; upgrades = []; pendingHeights = [:]
            if fontChanged || workspaceChanged || approvalProjectChanged || !Self.preservesRowOrder(previousRows, values) {
                table?.reloadData()
            } else if let table {
                applyRowChanges(from: previousRows, to: values, affectedFooterIDs: affectedFooterIDs, in: table)
            }
            if follow {
                scrollToLatest()
            } else if let anchor, let lastIndex = values.indices.last {
                let row = values.firstIndex(where: { $0.readingID == anchor.row.readingID })
                    ?? values.firstIndex(where: { $0.contains(anchor.row.id) }) ?? min(anchor.index, lastIndex)
                restoreAnchor(anchor, at: row)
            }
        }

        /// Rows keep their identity across a live turn as long as their relative
        /// order holds, so only inserted and removed rows are handed to AppKit.
        /// Reloading every row would restart thumbnails and the running effect.
        private static func preservesRowOrder(_ old: [NativeTranscriptRow], _ new: [NativeTranscriptRow]) -> Bool {
            let oldIDs = old.map(\.id), newIDs = new.map(\.id)
            guard Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else { return false }
            let oldSet = Set(oldIDs), newSet = Set(newIDs)
            return oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains)
        }

        private func applyRowChanges(from previous: [NativeTranscriptRow], to values: [NativeTranscriptRow],
                                     affectedFooterIDs: Set<String>, in table: NSTableView) {
            let oldIDs = previous.map(\.id), newIDs = values.map(\.id)
            let oldSet = Set(oldIDs), newSet = Set(newIDs)
            let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
            let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
            if !removed.isEmpty || !inserted.isEmpty {
                table.beginUpdates()
                if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
                if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
                table.endUpdates()
                synchronizeAvailableIndexes(in: table)
            }
            let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var hostCellsToUpdate: [(Int, HostCell, String)] = []
            var rowsToReload = IndexSet()
            table.enumerateAvailableRowViews { rowView, row in
                guard values.indices.contains(row) else { return }
                let value = values[row]
                let contentChanged = oldByID[value.id].map { !$0.hasSameItems(as: value) } ?? false
                guard contentChanged || affectedFooterIDs.contains(value.id) else { return }
                if let cell = rowView.view(atColumn: 0) as? HostCell {
                    hostCellsToUpdate.append((row, cell, value.id))
                } else {
                    rowsToReload.insert(row)
                }
            }
            for (row, cell, id) in hostCellsToUpdate {
                configure(cell, row: row)
                if affectedFooterIDs.contains(id) {
                    changed.insert(row)
                    if !refreshing { schedule() }
                }
                scheduleMeasure(for: cell, expectedID: id)
            }
            if !rowsToReload.isEmpty {
                table.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
            }
        }

        /// AppKit keeps row views across insertions but does not re-ask for
        /// them, so later height measurements need the current row indexes.
        private func synchronizeAvailableIndexes(in table: NSTableView) {
            table.enumerateAvailableRowViews { rowView, row in
                guard rows.indices.contains(row),
                      let cell = rowView.view(atColumn: 0) as? HostCell,
                      cell.representedID == rows[row].id else { return }
                cell.representedIndex = row
            }
        }

        private struct ViewportAnchor {
            let index: Int
            let row: NativeTranscriptRow
            let offset: CGFloat
        }

        private func rememberPosition() {
            guard pendingRestore == nil, let scrollState else { return }
            if follow { scrollState.readingAnchor = nil; return }
            guard let anchor = readAnchor() else { return }
            let index = anchor.index
            scrollState.readingAnchor = TranscriptReadingAnchor(id: anchor.row.readingID, offset: anchor.offset,
                next: index + 1 < rows.count ? rows[index + 1].readingID : nil,
                previous: index > 0 ? rows[index - 1].readingID : nil)
        }

        func restoreSessionPosition() {
            guard let anchor = pendingRestore, let scroll, let table, !rows.isEmpty else { return }
            let index = anchor.resolve(in: rows.map(\.content)) ?? 0
            let rect = table.rect(ofRow: index)
            let offset = rows[index].readingID == anchor.id ? min(anchor.offset, max(0, rect.height - 1)) : 0
            moveClip(toY: rect.minY + offset, in: scroll)
            pendingRestore = nil
            rememberPosition()
        }

        private func readAnchor() -> ViewportAnchor? {
            guard let table, let scroll else { return nil }
            let y = scroll.contentView.bounds.minY
            if y < 0, let first = rows.first {
                return .init(index: 0, row: first, offset: y)
            }
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
                 (.turnFailure, .turnFailure), (.toolCalls, .toolCalls), (.thinking, .thinking):
                offset = anchor.row.readingID == replacement.readingID ? min(anchor.offset, max(0, rect.height - 1)) : 0
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
            let newColumnWidth = WorkbenchReadingColumn.width(in: viewportWidth)
            let columnWidthChanged = lastReadingColumnWidth.map { abs($0 - newColumnWidth) > 0.5 } ?? false
            lastReadingColumnWidth = newColumnWidth
            let buffered = table.rows(in: hostingRect(in: table))
            var bufferedIDs: Set<String> = []
            if buffered.location != NSNotFound {
                for row in buffered.location..<NSMaxRange(buffered) where rows.indices.contains(row) {
                    bufferedIDs.insert(rows[row].id)
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    if let hostCell = cell as? HostCell {
                        hostCell.columnLeading.constant = WorkbenchReadingColumn.inset(in: viewportWidth)
                        if hostCell.host.rootView.width != newColumnWidth {
                            configure(hostCell, row: row)
                        }
                    } else if let summaryCell = cell as? SummaryCell {
                        summaryCell.viewportWidth = viewportWidth
                    }
                }
            }
            if columnWidthChanged {
                heights = heights.filter { bufferedIDs.contains($0.key) }
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

struct TranscriptHorizontalScrollView<Content: View>: View {
    var showsIndicators = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            content().background { TranscriptHorizontalScrollMarker() }
        }
        .scrollIndicators(showsIndicators ? .automatic : .never)
    }
}

/// Identifies the native scroll view even when SwiftUI removes its scroller.
struct TranscriptHorizontalScrollMarker: NSViewRepresentable {
    private static let identifier = NSUserInterfaceItemIdentifier("Zivvi.TranscriptHorizontalScroll")

    static func matches(_ scrollView: NSScrollView) -> Bool {
        scrollView.identifier == identifier
    }

    func makeNSView(context: Context) -> Attachment { Attachment() }

    func updateNSView(_ view: Attachment, context: Context) { view.markScrollView() }

    final class Attachment: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            markScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            markScrollView()
        }

        func markScrollView() {
            guard let scrollView = enclosingScrollView, !(scrollView is NativeTranscript.TranscriptScroll) else { return }
            scrollView.identifier = TranscriptHorizontalScrollMarker.identifier
        }
    }
}
