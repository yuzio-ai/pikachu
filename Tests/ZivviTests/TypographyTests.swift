import AppKit
import OrchestrationCore
import SwiftUI
import XCTest
@testable import Zivvi

@MainActor final class TypographyTests: XCTestCase {
    func testInterfaceFontSizeDefaultsToStandardAndPersistsRoundTrip() throws {
        let suiteName = "TypographyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(InterfaceFontSize.saved(in: defaults), .standard)

        defaults.set("unexpected-value", forKey: "interface-font-size")
        XCTAssertEqual(InterfaceFontSize.saved(in: defaults), .standard)

        for size in InterfaceFontSize.allCases {
            size.save(to: defaults)
            XCTAssertEqual(InterfaceFontSize.saved(in: defaults), size)
        }
    }

    func testInterfaceFontSizeStepBounds() {
        XCTAssertFalse(InterfaceFontSize.compact.canDecrease)
        XCTAssertEqual(InterfaceFontSize.compact.decreased(), .compact)
        XCTAssertTrue(InterfaceFontSize.compact.canIncrease)
        XCTAssertEqual(InterfaceFontSize.compact.increased(), .standard)

        XCTAssertEqual(InterfaceFontSize.standard.increased(), .large)
        XCTAssertEqual(InterfaceFontSize.large.increased(), .extraLarge)

        XCTAssertFalse(InterfaceFontSize.extraLarge.canIncrease)
        XCTAssertEqual(InterfaceFontSize.extraLarge.increased(), .extraLarge)
        XCTAssertTrue(InterfaceFontSize.extraLarge.canDecrease)
        XCTAssertEqual(InterfaceFontSize.extraLarge.decreased(), .large)
    }

    func testTypographyPointSizesScaleMonotonicallyAcrossPresets() {
        let ordered = InterfaceFontSize.allCases.map(ZivviTypography.init(size:))
        for role in ZivviTypography.TextRole.allCases {
            let sizes = ordered.map { $0.pointSize(for: role) }
            for index in 1..<sizes.count {
                XCTAssertGreaterThan(sizes[index], sizes[index - 1], "Expected \(role) to grow across presets")
            }
            for typography in ordered {
                XCTAssertEqual(typography.nsFont(role).pointSize, typography.pointSize(for: role), accuracy: 0.01)
            }
        }

        XCTAssertEqual(ZivviTypography(size: .compact).pointSize(for: .body), 13)
        XCTAssertEqual(ZivviTypography(size: .standard).pointSize(for: .body), 14)
        XCTAssertEqual(ZivviTypography(size: .large).pointSize(for: .body), 15)
        XCTAssertEqual(ZivviTypography(size: .extraLarge).pointSize(for: .body), 16)
    }

    func testSwiftUIUsesTabularDigitsForDefaultAndExplicitTypography() {
        for size in InterfaceFontSize.allCases {
            let widths = (0...9).map { digit in
                let text = Text(verbatim: String(repeating: String(digit), count: 8))
                return (
                    NSHostingView(rootView: text.zivviTypography(size)).fittingSize.width,
                    NSHostingView(rootView: text.zivviFont(.caption, weight: .medium)
                        .zivviTypography(size)).fittingSize.width
                )
            }
            for width in widths.dropFirst() {
                XCTAssertEqual(width.0, widths[0].0, accuracy: 0.01)
                XCTAssertEqual(width.1, widths[0].1, accuracy: 0.01)
            }
            XCTAssertGreaterThan(widths[0].0, 0)
            XCTAssertGreaterThan(widths[0].1, 0)
        }
    }

    func testAppKitUsesTabularDigitsAcrossTypographyPresets() {
        for size in InterfaceFontSize.allCases {
            let typography = ZivviTypography(size: size)
            for role in ZivviTypography.TextRole.allCases {
                let font = typography.nsFont(role)
                let widths = (0...9).map { String($0).size(withAttributes: [.font: font]).width }
                for width in widths.dropFirst() {
                    XCTAssertEqual(width, widths[0], accuracy: 0.01)
                }
            }
        }
    }

    func testNativeTranscriptInvalidatesAndRemeasuresHeightsOnFontSizeChange() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)

        let paragraph = Array(repeating: "Zivvi typography scaling verification line.", count: 8).joined(separator: " ")
        let rows: [TranscriptDisplayRow] = [
            .item(.init(id: "long-message", kind: .assistant, text: paragraph))
        ]

        coordinator.update(rows, follow: .constant(false), fontSize: .compact)
        await settleLayout(scroll)
        let compactHeight = table.rect(ofRow: 0).height

        coordinator.update(rows, follow: .constant(false), fontSize: .extraLarge)
        await settleLayout(scroll)
        let extraLargeHeight = table.rect(ofRow: 0).height

        XCTAssertGreaterThan(extraLargeHeight, compactHeight)
    }

    func testIconButtonTargetStaysFixedAcrossInterfaceSizes() {
        XCTAssertEqual(FlatDisclosureChevron.pointSize, 8)
        XCTAssertEqual(FlatDisclosureChevron(expanded: false).direction, .forward)
        XCTAssertEqual(FlatDisclosureChevron(expanded: true).direction, .down)
        for size in InterfaceFontSize.allCases {
            let host = NSHostingView(rootView: IconButtonLabel(systemName: "ellipsis").zivviTypography(size))
            XCTAssertEqual(host.fittingSize, CGSize(width: 26, height: 26))
        }
    }

    func testNativeTranscriptRemeasuresShortRowsWithoutDroppingToEstimateOnFontSizeChange() async throws {
        let coordinator = NativeTranscript.Coordinator()
        let scroll = NativeTranscript.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)

        let rows: [TranscriptDisplayRow] = [
            .item(.init(id: "short-message", kind: .assistant, text: "OK"))
        ]

        coordinator.update(rows, follow: .constant(false), fontSize: .standard)
        await settleLayout(scroll)
        let beforeHeight = table.rect(ofRow: 0).height
        XCTAssertLessThan(beforeHeight, 100)

        coordinator.update(rows, follow: .constant(false), fontSize: .compact)
        await settleLayout(scroll)
        let afterHeight = table.rect(ofRow: 0).height
        XCTAssertLessThan(afterHeight, 100)
    }

    private func settleLayout(_ view: NSView) async {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
