import AppKit
import XCTest
@testable import Pikachu

final class ComposerImagePasteTests: XCTestCase {
    @MainActor func testPlainTextIsNotAnImage() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep normal paste", forType: .string)
        XCTAssertNil(ClipboardImage.read(from: pasteboard))
        guard case .none = PastedAttachment.read(from: pasteboard) else {
            return XCTFail("Text pastes must fall through to the field editor")
        }
    }

    @MainActor func testVideoFileURLPastesAsAReferenceWithoutCopying() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-video-paste-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("clip.mp4")
        try Data().write(to: video)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([video as NSURL])

        guard case .attachment(.video(let pasted)) = PastedAttachment.read(from: pasteboard) else {
            return XCTFail("A pasted video file must become a video attachment")
        }
        XCTAssertEqual(pasted.standardizedFileURL, video.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["clip.mp4"])

        let folder = directory.appendingPathComponent("folder.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        guard case .none = PastedAttachment.read(from: pasteboard) else {
            return XCTFail("A directory named like a video file must not attach as a video")
        }
    }

    @MainActor func testVideoDataWithoutAFileAsksForAFinderCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data("movie bytes".utf8), forType: .init("public.mpeg-4"))

        guard case .unavailableVideo = PastedAttachment.read(from: pasteboard) else {
            return XCTFail("Video data without a file cannot be referenced")
        }
    }

    @MainActor func testImagePastePrefersPNGAndCreatesDistinctAttachments() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let bitmap = try makeBitmap()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(bitmap.tiffRepresentation, forType: .tiff)
        pasteboard.setData(png, forType: .png)
        let image = try XCTUnwrap(ClipboardImage.read(from: pasteboard))

        let first = try image.save(in: directory)
        let second = try image.save(in: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: first), png)
        XCTAssertEqual(try Data(contentsOf: second), png)
    }

    @MainActor func testTIFFClipboardImageIsSavedAsReadablePNG() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        pasteboard.setData(try makeBitmap().tiffRepresentation, forType: .tiff)
        let image = try XCTUnwrap(ClipboardImage.read(from: pasteboard))

        let file = try image.save(in: directory)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(bitmap.pixelsWide, 2)
        XCTAssertEqual(bitmap.pixelsHigh, 3)
    }

    func testPastedImagesDirectoryHonorsStateDirectoryIsolation() {
        let support = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        XCTAssertEqual(
            AppSettings.defaultPastedImagesDirectory(stateDirectory: nil, applicationSupport: support),
            support.appendingPathComponent("Pikachu/Pasted Images", isDirectory: true)
        )
        let isolatedState = URL(fileURLWithPath: "/tmp/custom-state", isDirectory: true)
        XCTAssertEqual(
            AppSettings.defaultPastedImagesDirectory(stateDirectory: isolatedState, applicationSupport: support),
            isolatedState.appendingPathComponent("Pasted Images", isDirectory: true)
        )
    }

    @MainActor func testRemoveUnusedPastedFileOnlyDeletesUnreferencedPastedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-paste-\(UUID())")
        let pastedDir = root.appendingPathComponent("Pasted Images", isDirectory: true)
        let externalDir = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try makeBitmap().tiffRepresentation, forType: .tiff)
        let image = try XCTUnwrap(ClipboardImage.read(from: pasteboard))

        let unused = try image.save(in: pastedDir)
        let referenced = try image.save(in: pastedDir)
        let external = externalDir.appendingPathComponent("user-file.png")
        try Data("keep".utf8).write(to: external)

        ClipboardImage.removeUnusedPastedFile(referenced, in: pastedDir, referenced: [referenced])
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))

        ClipboardImage.removeUnusedPastedFile(external, in: pastedDir, referenced: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))

        ClipboardImage.removeUnusedPastedFile(unused, in: pastedDir, referenced: [referenced])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }

    @MainActor private func makeBitmap() throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .calibratedRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData, 255, bitmap.bytesPerPlane)
        return bitmap
    }
}
