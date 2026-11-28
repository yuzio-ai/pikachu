import XCTest
@testable import Zivvi

final class TranscriptMarkerHoverTests: XCTestCase {
    func testClickDismissesPreviewWithoutRemovingHoverFeedback() throws {
        var hover = TranscriptMarkerHover()
        hover.movePointer(to: "message")
        let request = try XCTUnwrap(hover.request)
        hover.present(request)
        XCTAssertTrue(hover.isPresented)

        hover.dismissPreview()
        hover.movePointer(to: "message")
        hover.present(request)
        XCTAssertEqual(hover.hoveredID, "message")
        XCTAssertNil(hover.request)
        XCTAssertFalse(hover.isPresented)
    }

    func testReenteringSameMarkerRequiresNewDelay() throws {
        var hover = TranscriptMarkerHover()
        hover.movePointer(to: "message")
        let first = try XCTUnwrap(hover.request)
        hover.movePointer(to: nil)
        hover.movePointer(to: "message")
        let second = try XCTUnwrap(hover.request)

        XCTAssertNotEqual(first, second)
        hover.present(first)
        XCTAssertFalse(hover.isPresented)
        hover.present(second)
        XCTAssertTrue(hover.isPresented)
    }

    func testScrollRestartsDelayEvenIfPointerStaysOverSameMarker() throws {
        var hover = TranscriptMarkerHover()
        hover.movePointer(to: "message")
        let beforeScroll = try XCTUnwrap(hover.request)
        hover.present(beforeScroll)

        hover.setScrolling(true)
        XCTAssertEqual(hover.hoveredID, "message")
        XCTAssertNil(hover.request)
        XCTAssertFalse(hover.isPresented)

        hover.setScrolling(false)
        let afterScroll = try XCTUnwrap(hover.request)
        XCTAssertNotEqual(afterScroll, beforeScroll)
        hover.present(beforeScroll)
        XCTAssertFalse(hover.isPresented)
        hover.present(afterScroll)
        XCTAssertTrue(hover.isPresented)
    }

    func testScrollUsesMarkerNowUnderStationaryPointer() throws {
        var hover = TranscriptMarkerHover()
        hover.movePointer(to: "first")
        let oldRequest = try XCTUnwrap(hover.request)
        hover.setScrolling(true)
        hover.updateScrollPosition(markerID: "second")
        XCTAssertEqual(hover.hoveredID, "second")
        XCTAssertNil(hover.request)

        hover.setScrolling(false)
        let newRequest = try XCTUnwrap(hover.request)
        XCTAssertEqual(newRequest.markerID, "second")
        hover.present(oldRequest)
        XCTAssertFalse(hover.isPresented)
        hover.present(newRequest)
        XCTAssertTrue(hover.isPresented)
    }

    func testWheelOffsetWithoutScrollPhaseAndPointerExit() throws {
        var hover = TranscriptMarkerHover()
        hover.movePointer(to: "message")
        let first = try XCTUnwrap(hover.request)
        hover.present(first)
        hover.updateScrollPosition(markerID: "message")
        let afterWheel = try XCTUnwrap(hover.request)
        XCTAssertNotEqual(afterWheel, first)
        XCTAssertFalse(hover.isPresented)

        hover.setScrolling(true)
        hover.movePointer(to: nil)
        hover.setScrolling(false)
        XCTAssertNil(hover.hoveredID)
        XCTAssertNil(hover.request)
        XCTAssertFalse(hover.isPresented)
    }
}
