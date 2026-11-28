import CoreGraphics

/// Geometry of the transcript scroll view, in the coordinate space of
/// SwiftUI's `ScrollGeometry` (offset 0 is the content origin; the top
/// content margin makes the resting offset negative).
struct TranscriptScrollMetrics: Equatable {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0

    static let bottomTolerance: CGFloat = 4
    static let topTolerance: CGFloat = 12

    var minOffsetY: CGFloat { -insetTop }
    var maxOffsetY: CGFloat { contentHeight + insetBottom - containerHeight }
    var isAtBottom: Bool { offsetY >= maxOffsetY - Self.bottomTolerance }
    var hasOverflow: Bool { contentHeight > containerHeight - insetTop - insetBottom + Self.bottomTolerance }
    var isAtTop: Bool { hasOverflow && offsetY <= minOffsetY + Self.topTolerance }
}

/// Decides whether the transcript keeps following the latest content.
///
/// Only a user-driven offset change may turn following off or on. Content
/// growth, container resizes and programmatic scrolls never change it, so a
/// streaming reply cannot pull a reader back down and a layout pass cannot
/// release a follower.
@MainActor final class TranscriptFollowModel {
    struct Outcome: Equatable {
        var follow: Bool
        var scrolledToTop: Bool
        var needsScrollToBottom: Bool
    }

    private(set) var follow = true
    private var last: TranscriptScrollMetrics?
    private var userPhase = false
    private var expectsProgrammaticMove = false

    var isActivelyScrolling: Bool { userPhase }

    /// An explicit request (jump to latest, jump to a message, new session).
    func setFollow(_ value: Bool) { follow = value }

    /// Call right before issuing a programmatic scroll so its offset change is
    /// not mistaken for the reader's own scrolling.
    func markProgrammaticScroll() { expectsProgrammaticMove = true }

    /// Clears any unconsumed programmatic scroll flag when real user input arrives.
    func noteUserScroll() { expectsProgrammaticMove = false }

    /// `active` is true while the user holds or flings the content.
    func setUserPhase(_ active: Bool) {
        userPhase = active
        if active { expectsProgrammaticMove = false }
    }

    func apply(_ metrics: TranscriptScrollMetrics, acceptsUnphasedMovement: Bool = true) -> Outcome {
        defer { last = metrics }
        var userDriven = userPhase
        if let last, !userDriven {
            let moved = metrics.offsetY - last.offsetY
            if abs(moved) >= 0.5 || (moved != 0 && acceptsUnphasedMovement) {
                if expectsProgrammaticMove {
                    expectsProgrammaticMove = false
                } else if !acceptsUnphasedMovement || (follow && !last.isAtBottom) {
                    // A follower that is not at the bottom is still settling: the initial
                    // anchor or a layout pass is moving it, not the reader.
                } else {
                    let containerSame = abs(metrics.containerHeight - last.containerHeight) < 0.5
                    let contentSame = abs(metrics.contentHeight - last.contentHeight) < 0.5
                    let contentShrank = metrics.contentHeight < last.contentHeight - 0.5
                    // Device events without a scroll phase (mouse wheel) move the
                    // offset while the layout stays put. Growth only moves it down.
                    userDriven = containerSame && (contentSame || (moved < 0 && !contentShrank))
                }
            } else if expectsProgrammaticMove, follow, metrics.isAtBottom {
                // A follow-to-bottom request that landed with zero delta is already settled.
                expectsProgrammaticMove = false
            }
        }
        if userDriven { follow = metrics.isAtBottom }
        let needsScroll = follow && !userDriven && !metrics.isAtBottom && !expectsProgrammaticMove
        if needsScroll { expectsProgrammaticMove = true }
        return Outcome(follow: follow, scrolledToTop: metrics.isAtTop, needsScrollToBottom: needsScroll)
    }
}
