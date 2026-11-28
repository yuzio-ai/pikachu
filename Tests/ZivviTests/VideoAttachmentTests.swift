import AVFoundation
import XCTest
@testable import Zivvi

final class VideoAttachmentTests: XCTestCase {
    func testVideoContainersAreClassifiedWithoutDependingOnSystemTypes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["clip.mp4", "clip.mov", "clip.m4v", "clip.webm", "clip.MKV", "clip.avi"] {
            XCTAssertTrue(VideoAttachmentThumbnail.isVideo(directory.appendingPathComponent(name)), name)
        }
        for name in ["shot.png", "notes.txt", "archive.zip", "track.mp3", "index.ts"] {
            XCTAssertFalse(VideoAttachmentThumbnail.isVideo(directory.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(VideoAttachmentThumbnail.isVideo(URL(string: "https://example.com/clip.mp4")!))
    }

    func testPosterFrameAndDurationComeFromTheClip() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try await makeVideo(in: directory)

        let poster = await VideoAttachmentThumbnail.poster(for: video, maxPixels: 64)
        let frame = try XCTUnwrap(poster?.image)
        XCTAssertLessThanOrEqual(max(frame.width, frame.height), 64)
        XCTAssertEqual(poster?.duration, "0:01")
    }

    func testUnreadableClipHasNoPosterInsteadOfFailing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appendingPathComponent("broken.mp4")
        try Data("not a movie".utf8).write(to: broken)

        let poster = await VideoAttachmentThumbnail.poster(for: broken, maxPixels: 64)
        XCTAssertNil(poster)
        XCTAssertTrue(VideoAttachmentThumbnail.isVideo(broken))
    }

    func testDurationTextShiftsToHoursOnlyWhenNeeded() {
        XCTAssertEqual(VideoAttachmentThumbnail.durationText(0), "0:00")
        XCTAssertEqual(VideoAttachmentThumbnail.durationText(9.6), "0:10")
        XCTAssertEqual(VideoAttachmentThumbnail.durationText(72), "1:12")
        XCTAssertEqual(VideoAttachmentThumbnail.durationText(3_723), "1:02:03")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-video-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a short clip with AVFoundation so the tests never depend on external media tools.
    private func makeVideo(in directory: URL, name: String = "clip.mp4", seconds: Double = 1,
                           width: Int = 160, height: Int = 90) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height)
        )
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let frames = max(2, Int((seconds * 10).rounded()))
        for index in 0..<frames {
            try await receiver.append(try makePixelBuffer(attributes: attributes),
                                      with: CMTime(value: CMTimeValue(index), timescale: 10))
        }
        receiver.finish()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, "\(writer.error.map(String.init(describing:)) ?? "")")
        return url
    }

    private func makePixelBuffer(attributes: CVPixelBufferCreationAttributes) throws -> CVReadOnlyPixelBuffer {
        var buffer = try CVMutablePixelBuffer(attributes)
        buffer.withUnsafeBuffer { pixelBuffer in
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0x40, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        return CVReadOnlyPixelBuffer(buffer)
    }
}
