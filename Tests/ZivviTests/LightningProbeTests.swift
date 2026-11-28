import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
import OrchestrationCore
@testable import Zivvi

@MainActor
final class LightningProbeTests: XCTestCase {
    func testSwiftUITranscriptClearsLightningAfterToolCompletion() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let tool = TranscriptItem(id: "command", kind: .tool, tool: .init(
            id: "command", name: "bash", arguments: #"{"command":"sleep 3"}"#, state: .running))
        let host = NSHostingView(rootView: TranscriptView(items: [tool])
            .background(ZivviTheme.workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }

        let scroll = try XCTUnwrap(findTranscriptScrollView(in: host))
        XCTAssertEqual(scroll.identifier, SwiftUITranscript.scrollIdentifier)

        func hasLightning() throws -> Bool {
            let clip = scroll.contentView
            let inset = WorkbenchReadingColumn.inset(in: clip.bounds.width) + 28
            let rect = clip.convert(clip.bounds.insetBy(dx: inset, dy: 0), to: host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                    if (r - g > 0.12 && g - b > 0.12) || (b - g > 0.10 && g - r > 0.19) {
                        return true
                    }
                }
            }
            return false
        }

        var visible = false
        for _ in 0..<15 {
            if try hasLightning() {
                visible = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(visible, "Expected the running tool to paint a lightning arc")
        tool.tool?.state = .completed
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
        XCTAssertFalse(try hasLightning())
    }
}
