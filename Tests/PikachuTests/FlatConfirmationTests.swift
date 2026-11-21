import AppKit
import SwiftUI
import XCTest
@testable import Pikachu

@MainActor final class FlatConfirmationTests: XCTestCase {
    private var quitRequest: ConfirmationRequest {
        ConfirmationRequest(title: "停止任务并退出？",
                            message: "退出会停止任务，草稿会保留。",
                            confirmTitle: "停止并退出",
                            destructive: true,
                            allowsCancel: true,
                            cancelTitle: "继续工作",
                            defaultsToCancel: true,
                            confirm: {})
    }

    private func settle(_ panel: NSPanel) {
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testQuitDialogPanelSizesToItsContent() throws {
        let content = FlatConfirmation(request: quitRequest, cancel: {}, width: 360)
            .pikachuTypography(.standard)
        let intrinsic = NSHostingView(rootView: content).fittingSize
        XCTAssertEqual(intrinsic.width, 360, accuracy: 0.5)

        let panel = ConfirmationPanel.make(rootView: content)
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        settle(panel)

        // A transparent titlebar previously added its 32 pt height above the content,
        // so the window grew while the dialog stayed anchored to the bottom band.
        XCTAssertEqual(panel.frame.height, intrinsic.height, accuracy: 0.5)
        XCTAssertEqual(panel.frame.width, intrinsic.width, accuracy: 0.5)
        let host = try XCTUnwrap(panel.contentView)
        XCTAssertEqual(host.frame.height, intrinsic.height, accuracy: 0.5)
        XCTAssertFalse(panel.isReleasedWhenClosed, "the caller owns the panel until runModal returns")
    }

    func testDialogActionsScaleWithInterfaceFontSize() throws {
        func intrinsicSize(_ size: InterfaceFontSize) -> NSSize {
            NSHostingView(rootView: FlatConfirmation(request: quitRequest, cancel: {}, width: 360)
                .pikachuTypography(size)).fittingSize
        }

        let standard = intrinsicSize(.standard)
        let extraLarge = intrinsicSize(.extraLarge)
        XCTAssertEqual(standard.width, 360, accuracy: 0.5)
        XCTAssertEqual(extraLarge.width, 360, accuracy: 0.5)
        // The action row grows with the larger body text instead of clipping it.
        XCTAssertGreaterThan(extraLarge.height, standard.height + 4)
    }
}
