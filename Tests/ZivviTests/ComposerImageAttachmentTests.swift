import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Zivvi

final class ComposerImageAttachmentTests: XCTestCase {
    func testRecognizesImageAttachmentsButNotOtherFiles() {
        XCTAssertTrue(ImageAttachmentThumbnail.isImage(URL(fileURLWithPath: "/tmp/Screenshot.PNG")))
        XCTAssertTrue(ImageAttachmentThumbnail.isImage(URL(fileURLWithPath: "/tmp/Photo.heic")))
        XCTAssertFalse(ImageAttachmentThumbnail.isImage(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(ImageAttachmentThumbnail.isImage(URL(fileURLWithPath: "/tmp/report.pdf")))
        XCTAssertFalse(ImageAttachmentThumbnail.isImage(URL(string: "https://example.com/image.png")!))
    }

    func testThumbnailDownsamplesWithoutChangingAspectRatio() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let source = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let thumbnail = try XCTUnwrap(ImageAttachmentThumbnail.loadThumbnail(for: file, maxPixels: 240))
        XCTAssertEqual(thumbnail.width, 240)
        XCTAssertEqual(thumbnail.height, 120)
    }

    func testMissingImageFallsBackToPlaceholder() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        XCTAssertNil(ImageAttachmentThumbnail.loadThumbnail(for: file, maxPixels: 240))
    }
}
