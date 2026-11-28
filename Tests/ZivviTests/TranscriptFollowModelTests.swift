import XCTest
@testable import Zivvi

@MainActor
final class TranscriptFollowModelTests: XCTestCase {
    private func metrics(offset: CGFloat, content: CGFloat = 2_000, container: CGFloat = 600) -> TranscriptScrollMetrics {
        .init(offsetY: offset, contentHeight: content, containerHeight: container, insetTop: 20, insetBottom: 100)
    }

    // maxOffset = 2000 + 100 - 600 = 1500, minOffset = -20 with the defaults above.
    func testBottomAndTopDetectionAccountForInsetsAndTolerance() {
        XCTAssertTrue(metrics(offset: 1_500).isAtBottom)
        XCTAssertTrue(metrics(offset: 1_497).isAtBottom)
        XCTAssertFalse(metrics(offset: 1_490).isAtBottom)
        XCTAssertTrue(metrics(offset: -20).isAtTop)
        XCTAssertFalse(metrics(offset: 200).isAtTop)
        // Content that fits has no top state but is always at the bottom.
        let short = metrics(offset: -20, content: 300)
        XCTAssertTrue(short.isAtBottom)
        XCTAssertFalse(short.isAtTop)
    }

    func testGrowthWhileFollowingKeepsFollowingAndRequestsBottom() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        // The content grew by 200 and the offset did not follow yet.
        let outcome = model.apply(metrics(offset: 1_500, content: 2_200))
        XCTAssertTrue(outcome.follow)
        XCTAssertTrue(outcome.needsScrollToBottom)
        // The programmatic scroll lands at the new bottom.
        let landed = model.apply(metrics(offset: 1_700, content: 2_200))
        XCTAssertTrue(landed.follow)
        XCTAssertFalse(landed.needsScrollToBottom)
    }

    func testUserGestureAwayFromBottomReleasesFollowAndReturningRestoresIt() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        model.setUserPhase(true)
        XCTAssertFalse(model.apply(metrics(offset: 1_000)).follow)
        // Streaming growth while the reader is away neither follows nor scrolls.
        let grown = model.apply(metrics(offset: 1_000, content: 2_400))
        XCTAssertFalse(grown.follow)
        XCTAssertFalse(grown.needsScrollToBottom)
        let back = model.apply(metrics(offset: 1_900, content: 2_400))
        XCTAssertTrue(back.follow)
        model.setUserPhase(false)
    }

    func testPhaselessWheelMovementReleasesFollow() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        XCTAssertFalse(model.apply(metrics(offset: 1_460)).follow)
        XCTAssertFalse(model.apply(metrics(offset: 1_100)).follow)
        // A wheel step back to the bottom resumes following.
        XCTAssertTrue(model.apply(metrics(offset: 1_500)).follow)
    }

    func testUpwardWheelMovementDuringGrowthStillReleasesFollow() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        let outcome = model.apply(metrics(offset: 1_300, content: 2_050))
        XCTAssertFalse(outcome.follow)
        XCTAssertFalse(outcome.needsScrollToBottom)
    }

    func testSubpointWheelMovementCanCrossTheBottomTolerance() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_496.1), acceptsUnphasedMovement: false)
        model.noteUserScroll()
        let outcome = model.apply(metrics(offset: 1_495.9), acceptsUnphasedMovement: true)
        XCTAssertFalse(outcome.follow)
        XCTAssertFalse(outcome.needsScrollToBottom)
    }

    func testProgrammaticScrollNeverChangesFollow() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        model.setFollow(false)
        model.markProgrammaticScroll()
        // A jump lands mid-history with no layout change.
        let jumped = model.apply(metrics(offset: 400))
        XCTAssertFalse(jumped.follow)
        XCTAssertFalse(jumped.needsScrollToBottom)

        model.setFollow(true)
        model.markProgrammaticScroll()
        // A jump to latest first lands short of the bottom, then settles.
        XCTAssertTrue(model.apply(metrics(offset: 1_200)).follow)
        XCTAssertTrue(model.apply(metrics(offset: 1_500)).follow)
    }

    func testContainerResizeKeepsFollowing() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        // The composer grows; the viewport shrinks and the max offset rises.
        let outcome = model.apply(metrics(offset: 1_500, container: 540))
        XCTAssertTrue(outcome.follow)
        XCTAssertTrue(outcome.needsScrollToBottom)
    }

    func testInitialAnchorMovementIsNotMistakenForTheReader() {
        let model = TranscriptFollowModel()
        XCTAssertTrue(model.apply(metrics(offset: -20)).follow)
        // The system anchors the first layout at the bottom without a scroll phase.
        let anchored = model.apply(metrics(offset: 1_500))
        XCTAssertTrue(anchored.follow)
        XCTAssertFalse(anchored.needsScrollToBottom)
        // From the bottom, the same kind of movement is the reader scrolling up.
        XCTAssertFalse(model.apply(metrics(offset: 1_200)).follow)
    }

    func testScrolledToTopIsReportedForEveryMetricUpdate() {
        let model = TranscriptFollowModel()
        XCTAssertTrue(model.apply(metrics(offset: -20)).scrolledToTop)
        XCTAssertFalse(model.apply(metrics(offset: 300)).scrolledToTop)
    }

    func testZeroDeltaProgrammaticScrollAtBottomDoesNotSwallowNextWheelScroll() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        model.markProgrammaticScroll()
        _ = model.apply(metrics(offset: 1_500))
        let outcome = model.apply(metrics(offset: 1_440))
        XCTAssertFalse(outcome.follow)
        XCTAssertFalse(outcome.needsScrollToBottom)
    }

    func testNoteUserScrollClearsPendingProgrammaticMove() {
        let model = TranscriptFollowModel()
        _ = model.apply(metrics(offset: 1_500))
        model.markProgrammaticScroll()
        // A real user scroll arriving before the programmatic move settles must not be swallowed.
        model.noteUserScroll()
        let away = model.apply(metrics(offset: 1_440))
        XCTAssertFalse(away.follow)
        XCTAssertFalse(away.needsScrollToBottom)
        XCTAssertTrue(model.apply(metrics(offset: 1_500)).follow)
    }
}
