import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Pikachu

final class ImagePreviewTests: XCTestCase {
    func testFitScaleNeverUpscalesSmallImagesAndFitsLargeImages() {
        XCTAssertEqual(
            ImagePreviewViewportMath.fitScale(imageSize: CGSize(width: 400, height: 300),
                                              viewportSize: CGSize(width: 1000, height: 700)),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImagePreviewViewportMath.fitScale(imageSize: CGSize(width: 2400, height: 1600),
                                              viewportSize: CGSize(width: 1200, height: 600)),
            0.375,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImagePreviewViewportMath.fitScale(imageSize: .zero, viewportSize: CGSize(width: 800, height: 600)),
            1.0
        )
    }

    func testZoomStepsSkipNearMatchesAndRespectBounds() {
        let fitScale: CGFloat = 0.42
        let firstIn = ImagePreviewViewportMath.nextZoomInScale(from: fitScale, fitScale: fitScale)
        XCTAssertEqual(firstIn, 0.50, accuracy: 0.0001)

        // From 98%, next step skips 100% (< 8% delta) and jumps to 125%.
        let skipNear = ImagePreviewViewportMath.nextZoomInScale(from: 0.98, fitScale: 0.98)
        XCTAssertEqual(skipNear, 1.25, accuracy: 0.0001)

        let zoomOutFromSmallFit = ImagePreviewViewportMath.nextZoomOutScale(from: 0.25, fitScale: 0.15)
        XCTAssertEqual(zoomOutFromSmallFit, 0.15, accuracy: 0.0001)

        let maxClamp = ImagePreviewViewportMath.nextZoomInScale(from: 5.0, fitScale: 0.5)
        XCTAssertEqual(maxClamp, 5.0, accuracy: 0.0001)
        XCTAssertFalse(ImagePreviewViewportMath.canZoomIn(from: 5.0))
        XCTAssertFalse(ImagePreviewViewportMath.canZoomOut(from: 0.25, fitScale: 0.5))
        XCTAssertFalse(ImagePreviewViewportMath.canZoomOut(from: 0.25, fitScale: 0.25))
    }

    func testToggleAndDoubleTapAlternateBetweenFitAndDetail() {
        // Large image: Fit (0.5) <-> 100%
        XCTAssertEqual(ImagePreviewViewportMath.toggledScale(current: nil, fitScale: 0.5) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertNil(ImagePreviewViewportMath.toggledScale(current: 1.0, fitScale: 0.5))

        // Small image: Fit (1.0) <-> 200%
        XCTAssertEqual(ImagePreviewViewportMath.toggledScale(current: nil, fitScale: 1.0) ?? -1, 2.0, accuracy: 0.0001)
        XCTAssertNil(ImagePreviewViewportMath.toggledScale(current: 2.0, fitScale: 1.0))

        XCTAssertEqual(ImagePreviewViewportMath.doubleTapScale(current: nil, fitScale: 0.4) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ImagePreviewViewportMath.doubleTapScale(current: nil, fitScale: 1.0) ?? -1, 2.0, accuracy: 0.0001)
        XCTAssertNil(ImagePreviewViewportMath.doubleTapScale(current: 1.5, fitScale: 0.5))
    }

    func testPanOffsetClampsWithinScaledOverflowBounds() {
        let image = CGSize(width: 1000, height: 800)
        let viewport = CGSize(width: 800, height: 600)

        XCTAssertFalse(ImagePreviewViewportMath.canPan(imageSize: image, scale: 0.5, viewportSize: viewport))
        XCTAssertEqual(
            ImagePreviewViewportMath.clampedOffset(CGSize(width: 120, height: -90),
                                                   imageSize: image, scale: 0.5, viewportSize: viewport),
            .zero
        )

        XCTAssertTrue(ImagePreviewViewportMath.canPan(imageSize: image, scale: 1.0, viewportSize: viewport))
        let clamped = ImagePreviewViewportMath.clampedOffset(
            CGSize(width: 240, height: -180),
            imageSize: image, scale: 1.0, viewportSize: viewport
        )
        XCTAssertEqual(clamped.width, 100, accuracy: 0.0001)
        XCTAssertEqual(clamped.height, -100, accuracy: 0.0001)
    }

    func testSuggestedSaveFilenamePreservesCompatibleExtensionAndAppendsMissing() {
        XCTAssertEqual(
            ImagePreviewViewportMath.suggestedSaveFilename(name: "docs/screenshot", utType: .png),
            "screenshot.png"
        )
        XCTAssertEqual(
            ImagePreviewViewportMath.suggestedSaveFilename(name: "photo.jpg", utType: .jpeg),
            "photo.jpg"
        )
        XCTAssertEqual(
            ImagePreviewViewportMath.suggestedSaveFilename(name: "diagram.png", utType: .png),
            "diagram.png"
        )
        XCTAssertEqual(
            ImagePreviewViewportMath.suggestedSaveFilename(name: "/", utType: .png),
            "image.png"
        )
    }

    @MainActor
    func testSelectionLoadsFullResolutionAndCopiesToPrivatePasteboard() throws {
        let pngData = try makeTestPNGData(width: 640, height: 320)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try pngData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let fileSelection = ImagePreviewSelection.file(file)
        XCTAssertEqual(fileSelection.displayName, file.lastPathComponent)
        XCTAssertEqual(fileSelection.helpText, file.path)
        let loadedFileImage = try XCTUnwrap(fileSelection.loadPreviewImage())
        XCTAssertEqual(loadedFileImage.width, 640)
        XCTAssertEqual(loadedFileImage.height, 320)

        let toolSelection = ImagePreviewSelection.toolResult(pngData, name: "artifacts/output")
        XCTAssertEqual(toolSelection.displayName, "output")
        XCTAssertEqual(toolSelection.helpText, "artifacts/output")
        XCTAssertEqual(AttachmentImagePreview.imageType(from: pngData), .png)
        let loadedToolImage = try XCTUnwrap(toolSelection.loadPreviewImage())
        XCTAssertEqual(loadedToolImage.width, 640)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(AttachmentImagePreview.copyToPasteboard(loadedToolImage, pasteboard: pasteboard))
        XCTAssertFalse(pasteboard.readObjects(forClasses: [NSImage.self])?.isEmpty ?? true)
    }

    @MainActor
    func testWorkbenchPresentsWindowLightboxAndHidesToolbarControls() async throws {
        let pngData = try makeTestPNGData(width: 1600, height: 1000)
        let imageFile = FileManager.default.temporaryDirectory.appendingPathComponent("lightbox-\(UUID()).png")
        try pngData.write(to: imageFile)
        defer { try? FileManager.default.removeItem(at: imageFile) }

        let project = ProjectRecord(path: FileManager.default.temporaryDirectory.path)
        let reference = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [project]
        snapshot.sessions = [reference]
        snapshot.selectedSessionID = reference.id
        let store = PreviewMemoryStore(snapshot)
        let workspace = WorkspaceController(store: store) { _, _ in FakeRuntime() }
        await workspace.start()

        let visibility = PreviewSidebarVisibility()
        let host = NSHostingView(rootView: WorkbenchView(
            workspace: workspace, settings: AppSettings(), quitRequest: 0, openSettingsRequest: 0,
            terminate: { _, cancel in cancel() },
            sidebarVisibility: Binding(get: { visibility.value }, set: { visibility.value = $0 }),
            initialImagePreview: .file(imageFile)
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        await settle(window)
        await settle(window)

        let toolbar = try XCTUnwrap(window.toolbar)
        for item in toolbar.items where item.view != nil {
            XCTAssertTrue(item.view?.isHidden == true, "Expected toolbar item \(item.itemIdentifier.rawValue) to hide while lightbox is presented")
        }
        if let toggleItem = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "PikachuSidebarToggle" }) {
            XCTAssertFalse(toggleItem.isEnabled)
        }

        // Click the backdrop area outside the centered image and floating bars to dismiss.
        let backdropPoint = NSPoint(x: 18, y: 18)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: backdropPoint, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        await settle(window)
        await settle(window)

        for item in toolbar.items where item.view != nil {
            XCTAssertFalse(item.view?.isHidden == true, "Expected toolbar item \(item.itemIdentifier.rawValue) to reappear after closing lightbox")
        }
        if let toggleItem = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "PikachuSidebarToggle" }) {
            XCTAssertTrue(toggleItem.isEnabled)
        }
    }

    @MainActor
    func testAttachmentImagePreviewRendersAtMinimumAndDefaultSizes() async throws {
        let pngData = try makeTestPNGData(width: 1600, height: 1000)
        var dismissed = false
        let preview = AttachmentImagePreview(selection: .toolResult(pngData, name: "docs/preview.png")) {
            dismissed = true
        }
        let host = NSHostingView(rootView: preview)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        await settle(window)
        XCTAssertEqual(host.bounds.size.width, 860, accuracy: 1)
        XCTAssertEqual(host.bounds.size.height, 620, accuracy: 1)

        window.setContentSize(NSSize(width: 1120, height: 780))
        await settle(window)
        XCTAssertEqual(host.bounds.size.width, 1120, accuracy: 1)
        XCTAssertEqual(host.bounds.size.height, 780, accuracy: 1)

        // Pressing Escape dismisses the lightbox.
        if let escapeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber,
                                              context: nil, characters: "\u{1B}",
                                              charactersIgnoringModifiers: "\u{1B}",
                                              isARepeat: false, keyCode: 53) {
            window.sendEvent(escapeEvent)
        }
        await settle(window)
        XCTAssertTrue(dismissed)
    }

    @MainActor
    private func settle(_ window: NSWindow) async {
        for _ in 0..<8 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func makeTestPNGData(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor PreviewMemoryStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

@MainActor @Observable
private final class PreviewSidebarVisibility {
    var value: NavigationSplitViewVisibility = .all
}
