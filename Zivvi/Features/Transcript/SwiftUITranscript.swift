import AppKit
import SwiftUI
import OrchestrationCore

/// Per-transcript objects that must outlive individual rows: SwiftUI may drop
/// and recreate a lazily realized row, but its expansion state stays here.
@MainActor final class TranscriptSharedState {
    let toolExpansion = ToolCallExpansion()
    let turnChangesExpansion = TurnChangesExpansion()
    let handoffExpansion = HandoffRowExpansion()
    let replyHover = TranscriptReplyHover()
    let markdownStore = TranscriptMarkdownStore()
}

/// Reaches the AppKit scroll view behind SwiftUI's `ScrollView` for scroller
/// styling, diagnostics and the final within-row correction after a SwiftUI jump.
@MainActor final class TranscriptScrollHandle {
    weak var scroll: NSScrollView?
    var lastMetrics: TranscriptScrollMetrics?
    var sample: TranscriptScrollSample?
    struct ReadingRow {
        weak var view: NSView?
        let index: Int
        let next: TranscriptReadingID?
        let previous: TranscriptReadingID?
    }

    var readingRows: [TranscriptReadingID: ReadingRow] = [:]
    var pendingRestore: TranscriptReadingAnchor?
    var restoreTarget: TranscriptReadingID?
    var offTargetPasses = 0
    var restoreRetries = 0
    private var lastAppliedRestore: (id: TranscriptReadingID, targetY: CGFloat, frameMinY: CGFloat)?
    var isAppKitLiveScrolling = false
    private var sawAppKitLiveScroll = false
    private var liveScrollGeneration = 0
    private var isDraggingVerticalScroller = false
    private weak var lastConsumedEvent: NSEvent?
    var installed = false

    private var sampleScheduled = false
    var publishScheduled = false
    var mountGeneration = 0
    var pendingScrolledToTop: Bool?
    var pendingNeedsScrollToBottom = false
    var lastPublishedFollow = true

    /// SwiftUI reports row frames and scroll geometry separately during the same layout pass.
    func afterLayout(_ action: @escaping @MainActor () -> Void) {
        guard installed, !sampleScheduled else { return }
        sampleScheduled = true
        let generation = mountGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.installed, self.mountGeneration == generation else { return }
            self.sampleScheduled = false
            action()
        }
    }

    func markAppKitLiveScroll() {
        liveScrollGeneration &+= 1
        let generation = liveScrollGeneration
        sawAppKitLiveScroll = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.liveScrollGeneration == generation else { return }
            self.sawAppKitLiveScroll = false
        }
    }

    func clearPendingLiveScrollMarker() {
        sawAppKitLiveScroll = false
        liveScrollGeneration &+= 1
    }

    func endAppKitLiveScroll() {
        isAppKitLiveScrolling = false
        isDraggingVerticalScroller = false
        markAppKitLiveScroll()
    }

    func endLiveScrollTracking() {
        isAppKitLiveScrolling = false
        isDraggingVerticalScroller = false
        clearPendingLiveScrollMarker()
    }

    func resetForUninstall() {
        endLiveScrollTracking()
        lastConsumedEvent = nil
        lastMetrics = nil
        sampleScheduled = false
        publishScheduled = false
        mountGeneration &+= 1
        pendingScrolledToTop = nil
        pendingNeedsScrollToBottom = false
    }

    func consumeDirectScrollInput(
        _ event: NSEvent?,
        markConsumed: Bool = true,
        isPrimaryButtonPressed: Bool = (NSEvent.pressedMouseButtons & 1) != 0
    ) -> Bool {
        if isAppKitLiveScrolling || sawAppKitLiveScroll {
            if markConsumed { sawAppKitLiveScroll = false }
            return true
        }
        guard let event, let scroll, let window = scroll.window, event.window === window,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25,
              lastConsumedEvent !== event else {
            if event?.type == .leftMouseUp { isDraggingVerticalScroller = false }
            return false
        }
        let matched: Bool
        switch event.type {
        case .scrollWheel:
            isDraggingVerticalScroller = false
            let point = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.bounds.contains(point), abs(event.scrollingDeltaY) > 0 else { return false }
            let superviewPoint = scroll.superview?.convert(event.locationInWindow, from: nil) ?? point
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
               let hit = scroll.hitTest(superviewPoint),
               let nested = sequence(first: hit, next: { $0.superview }).first(where: { $0 is NSScrollView }) as? NSScrollView,
               nested !== scroll {
                matched = false
            } else {
                matched = true
            }
        case .leftMouseDown:
            guard let scroller = scroll.verticalScroller, !scroller.isHidden, scroller.alphaValue > 0.01 else {
                isDraggingVerticalScroller = false
                return false
            }
            let scrollerPoint = scroller.convert(event.locationInWindow, from: nil)
            matched = scroller.bounds.contains(scrollerPoint)
            isDraggingVerticalScroller = matched
        case .leftMouseDragged:
            guard isPrimaryButtonPressed,
                  let scroller = scroll.verticalScroller, !scroller.isHidden, scroller.alphaValue > 0.01 else {
                isDraggingVerticalScroller = false
                return false
            }
            let scrollerPoint = scroller.convert(event.locationInWindow, from: nil)
            matched = isDraggingVerticalScroller || scroller.bounds.contains(scrollerPoint)
        case .keyDown:
            isDraggingVerticalScroller = false
            guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: scroll) else { return false }
            // Home, End, Page Up/Down and the vertical arrow keys.
            matched = [115, 119, 116, 121, 125, 126].contains(event.keyCode)
        default:
            isDraggingVerticalScroller = false
            matched = false
        }
        if matched, markConsumed { lastConsumedEvent = event }
        return matched
    }

    var metrics: TranscriptScrollMetrics? {
        guard let clip = scroll?.contentView, clip.documentView != nil else { return nil }
        let document = clip.documentRect
        let viewport = clip.bounds
        return .init(offsetY: clip.isFlipped ? viewport.minY - document.minY : document.maxY - viewport.maxY,
                     contentHeight: document.height, containerHeight: viewport.height)
    }

    private func visibleFrame(for row: ReadingRow, in clip: NSClipView) -> CGRect? {
        guard let view = row.view, view.isDescendant(of: clip) else { return nil }
        let frame = view.convert(view.bounds, to: clip)
        let viewport = clip.bounds
        guard frame.height > 0, frame.maxY > viewport.minY, frame.minY < viewport.maxY else { return nil }
        let top = clip.isFlipped ? frame.minY - viewport.minY : viewport.maxY - frame.maxY
        return CGRect(x: 0, y: top, width: frame.width, height: frame.height)
    }

    func capture() -> TranscriptReadingAnchor? {
        guard let clip = scroll?.contentView else { return nil }
        var first: (id: TranscriptReadingID, row: ReadingRow, frame: CGRect)?
        for (id, row) in readingRows {
            guard row.index < (first?.row.index ?? .max), let frame = visibleFrame(for: row, in: clip) else { continue }
            first = (id, row, frame)
        }
        guard let first else { return nil }
        return .init(id: first.id, offset: -first.frame.minY, next: first.row.next, previous: first.row.previous)
    }

    func removeReadingRow(_ id: TranscriptReadingID, view: NSView) {
        if readingRows[id]?.view === view { readingRows.removeValue(forKey: id) }
    }

    /// Row frames are relative to the viewport. Apply only the remaining distance,
    /// then confirm it from the next delivered layout before releasing the anchor.
    func finishRestore(markProgrammatic: () -> Void, retryScroll: (TranscriptReadingID) -> Void) {
        guard let anchor = pendingRestore, let id = restoreTarget, let scroll else { return }
        let clip = scroll.contentView
        guard let row = readingRows[id], let frame = visibleFrame(for: row, in: clip) else {
            // An initial scroll anchor pass can supersede `onAppear`'s `scrollTo(id:)`;
            // retry once only after layout has settled on other rows without reaching `id`.
            if readingRows.values.contains(where: { visibleFrame(for: $0, in: clip) != nil }) {
                offTargetPasses += 1
                if offTargetPasses >= 2, restoreRetries == 0 {
                    restoreRetries = 1
                    retryScroll(id)
                }
            }
            return
        }
        offTargetPasses = 0
        if let last = lastAppliedRestore, last.id == id,
           abs(last.targetY - clip.bounds.minY) <= 0.5,
           abs(last.frameMinY - frame.minY) <= 0.5 {
            return
        }
        lastAppliedRestore = nil
        let offset = id == anchor.id ? min(anchor.offset, max(0, frame.height - 1)) : 0
        var bounds = clip.bounds
        let distance = frame.minY + offset
        bounds.origin.y += clip.isFlipped ? distance : -distance
        let target = clip.constrainBoundsRect(bounds).origin
        if abs(target.y - clip.bounds.minY) <= 0.5 {
            cancelRestore()
        } else {
            markProgrammatic()
            lastAppliedRestore = (id: id, targetY: target.y, frameMinY: frame.minY)
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    func cancelRestore() {
        pendingRestore = nil
        restoreTarget = nil
        offTargetPasses = 0
        restoreRetries = 0
        lastAppliedRestore = nil
    }
}

/// The conversation as a native SwiftUI `ScrollView` + `LazyVStack`. Scrolling,
/// momentum and layout all belong to the system; this view only decides when
/// the viewport follows the newest content (`TranscriptFollowModel`).
struct SwiftUITranscript: View {
    @Environment(\.zivviTypography) private var typography
    let entries: [NativeTranscriptRow]
    let scrollState: TranscriptScrollState
    var historyLoading = false
    var extraTopClearance: CGFloat = 0
    var composerClearance: CGFloat = 0
    var workspaceDirectory: URL? = nil
    var approvalProjectDirectory: String? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onOpenHandoffFile: HandoffFileOpener? = nil
    var onEditUserMessage: ((TranscriptItem) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var onShowToolOutput: ((ToolOutputSelection) -> Void)? = nil
    var onSwitchModel: (() -> Void)? = nil
    var onOpenConnectionSettings: (() -> Void)? = nil
    var onSafeRetry: (() -> Void)? = nil
    var queueFooter: TranscriptQueueFooter? = nil

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var model = TranscriptFollowModel()
    @State private var shared = TranscriptSharedState()
    @State private var handle = TranscriptScrollHandle()
    @State private var viewportWidth: CGFloat = 600

    /// Marks the backing `NSScrollView`; the horizontal code-block marker uses another value.
    static let scrollIdentifier = NSUserInterfaceItemIdentifier("Zivvi.SwiftUITranscriptScroll")

    var body: some View {
        let width = WorkbenchReadingColumn.width(in: viewportWidth)
        let inset = WorkbenchReadingColumn.inset(in: viewportWidth)
        let tracksReadingPosition = !scrollState.follow
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZivviSpacing.timelineRowGap) {
                ForEach(entries.enumerated(), id: \.element.readingID) { index, row in
                    let id = row.readingID
                    let next = index + 1 < entries.count ? entries[index + 1].readingID : nil
                    let previous = index > 0 ? entries[index - 1].readingID : nil
                    TranscriptHost(
                        row: row,
                        width: width,
                        fontSize: typography.size,
                        workspaceDirectory: workspaceDirectory,
                        approvalProjectDirectory: approvalProjectDirectory,
                        markdownStore: shared.markdownStore,
                        toolExpansion: shared.toolExpansion,
                        onOpenFile: onOpenFile,
                        onOpenToolDiff: onOpenToolDiff,
                        onOpenHandoffFile: onOpenHandoffFile,
                        onEditUserMessage: onEditUserMessage,
                        onPreviewImage: onPreviewImage,
                        onShowToolOutput: onShowToolOutput,
                        onSwitchModel: onSwitchModel,
                        onOpenConnectionSettings: onOpenConnectionSettings,
                        onSafeRetry: onSafeRetry,
                        turnChangesExpansion: shared.turnChangesExpansion,
                        handoffExpansion: shared.handoffExpansion,
                        approvalExpansion: scrollState.approvalExpansion,
                        replyHover: shared.replyHover,
                        queueFooter: queueFooter?.itemID == row.id ? queueFooter?.text : nil,
                        resetsIdentityOnReuse: false,
                        changed: {}
                    )
                    .padding(.vertical, ZivviSpacing.timelineRowInset)
                    .padding(.leading, inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if tracksReadingPosition {
                            TranscriptReadingRowMarker(handle: handle, id: id, index: index, next: next, previous: previous) {
                                if handle.pendingRestore != nil || (!model.isActivelyScrolling && !handle.isAppKitLiveScrolling) {
                                    sampleAfterLayout()
                                }
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .background {
                TranscriptScrollLocator(
                    handle: handle,
                    scrollState: scrollState,
                    diagnosticJump: diagnosticJump,
                    onGeometryChange: updateScrollMetrics,
                    onUserScroll: {
                        model.noteUserScroll()
                    },
                    onScrollSettled: {
                        if !model.follow && !model.isActivelyScrolling {
                            sampleAfterLayout()
                        }
                    }
                )
            }
        }
        .accessibilityIdentifier("transcript")
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(scrollState.follow ? .bottom : nil, for: .sizeChanges)
        .contentMargins(.top, NativeTranscript.topClearance + extraTopClearance, for: .scrollContent)
        .contentMargins(.bottom, composerClearance + 8, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { handle.cancelRestore() }
            model.setUserPhase(phase == .interacting || phase == .decelerating)
            if phase == .idle, !handle.isAppKitLiveScrolling, !model.follow {
                sampleAfterLayout()
            }
        }
        .onChange(of: scrollState.jump) { _, jump in
            if ownsMount, let jump { handle.cancelRestore(); scroll(to: .init(jump.messageID)) }
        }
        .onChange(of: restoreDestination) { _, target in restoreIfReady(target) }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
            guard ownsMount, let text = note.object as? NSTextView, let scroll = handle.scroll,
                  let window = scroll.window, window.firstResponder === text,
                  text.isDescendant(of: scroll), text.selectedRange().length > 0 else { return }
            handle.cancelRestore()
            handle.lastPublishedFollow = false
            handle.pendingNeedsScrollToBottom = false
            model.setFollow(false)
            scrollState.follow = false
            rememberPosition()
        }
        .onChange(of: scrollState.follow) { _, follow in
            guard ownsMount else { return }
            handle.lastPublishedFollow = follow
            if !follow { handle.pendingNeedsScrollToBottom = false }
            model.setFollow(follow)
        }
        .onChange(of: workspaceDirectory) { _, _ in shared.markdownStore.clearPathCache() }
        .onAppear { install() }
        .onDisappear { uninstall() }
    }

    private var ownsMount: Bool {
        handle.installed && scrollState.activeMountOwner == ObjectIdentifier(handle)
    }

    private func updateScrollMetrics() {
        guard ownsMount else { return }
        defer {
            if !model.follow, handle.pendingRestore != nil || (!model.isActivelyScrolling && !handle.isAppKitLiveScrolling) {
                sampleAfterLayout()
            }
        }
        guard let metrics = handle.metrics, metrics != handle.lastMetrics else { return }
        let offsetMoved = handle.lastMetrics.map { metrics.offsetY != $0.offsetY } ?? false
        handle.lastMetrics = metrics
        let userInput = handle.consumeDirectScrollInput(NSApp?.currentEvent, markConsumed: offsetMoved)
        if userInput {
            handle.cancelRestore()
            model.noteUserScroll()
        }
        schedulePublish(model.apply(metrics, acceptsUnphasedMovement: userInput))
    }

    private func schedulePublish(_ outcome: TranscriptFollowModel.Outcome) {
        handle.pendingScrolledToTop = outcome.scrolledToTop
        if outcome.needsScrollToBottom { handle.pendingNeedsScrollToBottom = true }
        guard !handle.publishScheduled else { return }
        handle.publishScheduled = true
        let generation = handle.mountGeneration
        DispatchQueue.main.async {
            guard handle.installed, handle.mountGeneration == generation else { return }
            handle.publishScheduled = false
            let scrolledToTop = handle.pendingScrolledToTop
            let needsScrollToBottom = handle.pendingNeedsScrollToBottom
            handle.pendingScrolledToTop = nil
            handle.pendingNeedsScrollToBottom = false

            guard ownsMount else { return }
            if scrollState.follow != handle.lastPublishedFollow { return }
            let follow = model.follow
            if scrollState.follow != follow {
                handle.lastPublishedFollow = follow
                scrollState.follow = follow
                if follow {
                    scrollState.jump = nil
                    scrollState.readingAnchor = nil
                }
            }
            if let scrolledToTop, scrollState.scrolledToTop != scrolledToTop {
                scrollState.scrolledToTop = scrolledToTop
            }
            if needsScrollToBottom && follow && handle.lastMetrics?.isAtBottom == false {
                scrollToBottom()
            }
        }
    }

    private func scrollToBottom() {
        handle.clearPendingLiveScrollMarker()
        model.markProgrammaticScroll()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
    }

    private func scroll(to id: TranscriptReadingID) {
        handle.clearPendingLiveScrollMarker()
        handle.lastPublishedFollow = false
        handle.pendingNeedsScrollToBottom = false
        if scrollState.follow { scrollState.follow = false }
        model.setFollow(false)
        model.markProgrammaticScroll()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(id: id, anchor: .top) }
    }

    private func sampleAfterLayout() {
        handle.afterLayout {
            guard ownsMount else { return }
            handle.finishRestore(
                markProgrammatic: { model.markProgrammaticScroll() },
                retryScroll: { scroll(to: $0) }
            )
            rememberPosition()
        }
    }

    private func rememberPosition() {
        guard ownsMount, handle.pendingRestore == nil else { return }
        if model.follow { scrollState.readingAnchor = nil; return }
        if let anchor = handle.capture() { scrollState.readingAnchor = anchor }
    }

    private var restoreDestination: TranscriptReadingID? {
        guard !historyLoading, let anchor = handle.pendingRestore, !entries.isEmpty else { return nil }
        return entries[anchor.resolve(inEntries: entries) ?? 0].readingID
    }

    private func restoreIfReady(_ target: TranscriptReadingID?) {
        guard ownsMount, handle.pendingRestore != nil, target != handle.restoreTarget else { return }
        handle.restoreTarget = target
        handle.offTargetPasses = 0
        handle.restoreRetries = 0
        guard let target else { return }
        scroll(to: target)
        sampleAfterLayout()
    }

    private func install() {
        let owner = ObjectIdentifier(handle)
        scrollState.activeMountOwner = owner
        handle.installed = true
        handle.lastPublishedFollow = scrollState.follow
        handle.pendingRestore = scrollState.follow ? nil : scrollState.readingAnchor
        model.setFollow(scrollState.follow)
        if handle.pendingRestore != nil {
            restoreIfReady(restoreDestination)
            scrollState.jump = nil
        } else if !scrollState.follow, let jump = scrollState.jump {
            scroll(to: .init(jump.messageID))
        } else {
            scrollState.jump = nil
        }
        scrollState.scrollToLatest = {
            handle.cancelRestore()
            handle.lastPublishedFollow = true
            handle.pendingNeedsScrollToBottom = false
            model.setFollow(true)
            scrollToBottom()
        }
        updateScrollMetrics()
    }

    private var diagnosticJump: ((Int) -> Bool)? {
        guard DiagnosticMetrics.shared.measuresPixels else { return nil }
        return { index in
            guard ownsMount, entries.indices.contains(index) else { return false }
            handle.sample?.stop()
            handle.sample = nil
            // Start the sample with the requested row at the viewport edge.
            let id = entries[index].readingID
            handle.cancelRestore()
            handle.pendingRestore = .init(id: id, offset: 0, next: nil, previous: nil)
            restoreIfReady(id)
            return true
        }
    }

    private func uninstall() {
        let owner = ObjectIdentifier(handle)
        if scrollState.activeMountOwner == owner {
            rememberPosition()
            scrollState.scrollToLatest = nil
            scrollState.activeMountOwner = nil
        }
        handle.installed = false
        handle.resetForUninstall()
        handle.cancelRestore()
        handle.sample?.stop()
        handle.sample = nil
    }
}

/// Gives each realized row a frame in the same AppKit coordinate space as the clip view.
private struct TranscriptReadingRowMarker: NSViewRepresentable {
    let handle: TranscriptScrollHandle
    let id: TranscriptReadingID
    let index: Int
    let next: TranscriptReadingID?
    let previous: TranscriptReadingID?
    let geometryChanged: () -> Void

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {
        if let oldID = view.id, oldID != id { view.handle?.removeReadingRow(oldID, view: view) }
        view.handle = handle
        view.id = id
        view.geometryChanged = geometryChanged
        handle.readingRows[id] = .init(view: view, index: index, next: next, previous: previous)
        geometryChanged()
    }

    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        if let id = view.id { view.handle?.removeReadingRow(id, view: view) }
        view.geometryChanged = nil
    }

    final class Marker: NSView {
        weak var handle: TranscriptScrollHandle?
        var id: TranscriptReadingID?
        var geometryChanged: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            geometryChanged?()
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { geometryChanged?() }
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            let changed = frame.origin != newOrigin
            super.setFrameOrigin(newOrigin)
            if changed { geometryChanged?() }
        }
    }
}

/// Styles SwiftUI's own vertical scroller like the rest of the workbench and
/// records the backing scroll view for diagnostics.
private struct TranscriptScrollLocator: NSViewRepresentable {
    let handle: TranscriptScrollHandle
    let scrollState: TranscriptScrollState
    let diagnosticJump: ((Int) -> Bool)?
    let onGeometryChange: () -> Void
    let onUserScroll: () -> Void
    let onScrollSettled: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        if diagnosticJump != nil { DiagnosticMetrics.shared.register(view) }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.handle = handle
        view.onGeometryChange = onGeometryChange
        view.onUserScroll = onUserScroll
        view.onScrollSettled = onScrollSettled
        if let diagnosticJump {
            view.scrollState = scrollState
            view.diagnosticJump = diagnosticJump
        }
        view.resolve()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.teardownObservers()
        view.diagnosticJump = nil
        if DiagnosticMetrics.shared.measuresPixels { DiagnosticMetrics.shared.unregister(view) }
    }

    final class Probe: NSView, TranscriptScrollDiagnosticTarget {
        weak var scrollState: TranscriptScrollState?
        weak var handle: TranscriptScrollHandle?
        var diagnosticJump: ((Int) -> Bool)?
        var onGeometryChange: (() -> Void)?
        var onUserScroll: (() -> Void)?
        var onScrollSettled: (() -> Void)?
        var diagnosticWindow: NSWindow? { window }

        private weak var observedScroll: NSScrollView?
        private weak var observedDocument: NSView?
        private var observers: [NSObjectProtocol] = []

        func positionScrollSample(at row: Int) -> Bool { diagnosticJump?(row) ?? false }

        func startScrollSample() -> Bool {
            guard scrollState?.follow == false, let handle, let scroll = handle.scroll else { return false }
            handle.sample?.stop()
            handle.sample = TranscriptScrollSample(scroll: scroll, firstRow: 0)
            return true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func teardownObservers() {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
            observers.removeAll()
            observedScroll = nil
            observedDocument = nil
            handle?.endLiveScrollTracking()
        }

        func resolve() {
            guard let scroll = enclosingScrollView else { return }
            handle?.scroll = scroll
            if scroll.identifier != SwiftUITranscript.scrollIdentifier {
                scroll.identifier = SwiftUITranscript.scrollIdentifier
            }
            WorkbenchScroller.install(in: scroll, axis: .vertical)
            if scroll.verticalScroller?.controlSize != .small {
                scroll.verticalScroller?.controlSize = .small
            }
            let document = scroll.documentView
            guard observedScroll !== scroll || observedDocument !== document else { return }
            teardownObservers()
            observedScroll = scroll
            observedDocument = document
            let center = NotificationCenter.default
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onGeometryChange?() }
                },
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handle?.isAppKitLiveScrolling = true
                        self?.handle?.cancelRestore()
                        self?.onUserScroll?()
                    }
                },
                center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handle?.markAppKitLiveScroll()
                        self?.handle?.cancelRestore()
                        self?.onUserScroll?()
                    }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handle?.endAppKitLiveScroll()
                        self?.onScrollSettled?()
                    }
                },
            ]
            if let document {
                document.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onGeometryChange?() }
                })
            }
            onGeometryChange?()
        }
    }
}
