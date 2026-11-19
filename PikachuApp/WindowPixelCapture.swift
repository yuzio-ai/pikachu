import AppKit
import CoreMedia
import ScreenCaptureKit

/// Opt-in release validation. Only this process's window is captured. The
/// stream stores geometry, timestamps and pixel statistics, never image data.
@MainActor final class WindowPixelCapture {
    private var stream: SCStream?
    private var pending = false
    private let output: PixelOutput

    init?(destination: URL) {
        guard let output = PixelOutput(destination: destination) else { return nil }
        self.output = output
    }

    func observe(_ view: NSView, tag: String) {
        guard let window = view.window, let screen = window.screen else { return }
        let frame = window.frame
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let topLeft = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                             width: rect.width, height: rect.height)
        output.setRegion(topLeft, editor: tag.hasPrefix("editor:"))
        guard stream == nil, !pending else { return }
        pending = true
        let number = CGWindowID(window.windowNumber)
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let mode = CGDisplayCopyDisplayMode(display)
        let scale = screen.backingScaleFactor
        let refresh = mode?.refreshRate ?? 0
        Task {
            do {
                let content = try await SCShareableContent.currentProcess
                guard let ownWindow = content.windows.first(where: {
                    $0.windowID == number && $0.owningApplication?.processID == getpid()
                }) else { throw CocoaError(.fileNoSuchFile) }
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let config = SCStreamConfiguration()
                config.width = Int((frame.width * scale).rounded())
                config.height = Int((frame.height * scale).rounded())
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.minimumFrameInterval = .init(value: 1, timescale: 120)
                config.ignoreShadowsSingleWindow = true
                config.showsCursor = false
                let capture = SCStream(filter: filter, configuration: config, delegate: output)
                try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                output.write(["kind": "start", "pid": getpid(), "windowID": number, "display": display,
                              "refreshHz": refresh, "width": config.width, "height": config.height,
                              "pointWidth": frame.width, "pointHeight": frame.height, "backingScale": scale,
                              "screenPermission": CGPreflightScreenCaptureAccess()])
                try await capture.startCapture()
                stream = capture
            } catch {
                output.write(["kind": "error", "pid": getpid(), "detail": String(describing: error)])
            }
        }
    }
}

private final class PixelOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ai.yuzio.pikachu.window-pixels")
    private let file: FileHandle
    private let regionLock = NSLock()
    private var editor = CGRect.zero
    private var transcript = CGRect.zero
    private var frames = 0

    init?(destination: URL) {
        let files = FileManager.default
        if !files.fileExists(atPath: destination.path) {
            guard files.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        guard let file = try? FileHandle(forWritingTo: destination), (try? file.seekToEnd()) != nil else { return nil }
        self.file = file
    }

    func setRegion(_ rect: CGRect, editor isEditor: Bool) {
        regionLock.withLock {
            if isEditor { editor = rect } else { transcript = rect }
        }
    }

    func write(_ value: [String: Any]) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        queue.async { try? self.file.write(contentsOf: encoded + Data([10])) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        write(["kind": "error", "pid": getpid(), "detail": String(describing: error)])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, frames < 12_000,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                           as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              let ticks = info[.displayTime] as? UInt64 else { return }
        frames += 1
        let time = CMClockMakeHostTimeFromSystemUnits(ticks).seconds
        var record: [String: Any] = ["kind": "frame", "pid": getpid(), "displayTime": time,
                                     "deliveryUptime": ProcessInfo.processInfo.systemUptime, "status": raw]
        if (status == .complete || status == .started), let buffer = sample.imageBuffer {
            let (composer, messages) = regionLock.withLock { (editor, transcript) }
            let scale = (info[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
            let content = (info[.contentRect] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let ratio = (info[.contentScale] as? NSNumber)?.doubleValue ?? 1
            record["geometry"] = [content.minX, content.minY, content.width, content.height, scale, ratio]
            record["editor"] = [composer.minX, composer.minY, composer.width, composer.height]
            record["transcript"] = [messages.minX, messages.minY, messages.width, messages.height]
            record["pixelStats"] = Self.measure(buffer, scale: scale * ratio, origin: content.origin,
                                               composer: composer, transcript: messages)
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        try? file.write(contentsOf: encoded + Data([10]))
    }

    private static func measure(_ buffer: CVPixelBuffer, scale: Double, origin: CGPoint,
                                composer: CGRect, transcript: CGRect) -> [String: Any] {
        guard scale.isFinite, scale >= 0.5, scale <= 4,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [:] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return [:] }
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func crop(_ rect: CGRect) -> CGRect {
            let scaled = CGRect(x: (rect.minX + origin.x) * scale, y: (rect.minY + origin.y) * scale,
                                width: rect.width * scale, height: rect.height * scale)
            return scaled.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        }
        var stats: [String: Any] = ["buffer": [width, height]]
        if composer.width > 200 {
            let line = crop(CGRect(x: composer.minX + 12, y: composer.minY + 10,
                                   width: composer.width - 24, height: 23))
            if !line.isNull {
                let bg = Int(pixels[Int(line.midY) * stride + (Int(line.maxX) - 3) * 4 + 1])
                var ink = 0, right = 0
                var columns: [Int] = []
                for x in Int(line.minX)..<Int(line.maxX) {
                    var hits = 0
                    for y in Int(line.minY)..<Int(line.maxY) {
                        let i = y * stride + x * 4
                        let b = Int(pixels[i]), g = Int(pixels[i+1]), r = Int(pixels[i+2])
                        if abs(g - bg) > 75 && max(r, g, b) - min(r, g, b) < 28 { hits += 1 }
                    }
                    if hits >= 4 { right = x - Int(line.minX); ink += hits; columns.append(right) }
                }
                stats["glyphRight"] = right; stats["glyphInk"] = ink
                stats["glyphColumns"] = columns.count
            }
        }
        if transcript.width > 150, transcript.height > 120 {
            // Inset from the toggle, scrollbar, edges and selection bands.
            let body = crop(transcript.insetBy(dx: 32, dy: 55))
            if !body.isNull {
                var hash: UInt64 = 14695981039346656037
                for y in Swift.stride(from: Int(body.minY), to: Int(body.maxY), by: 5) {
                    for x in Swift.stride(from: Int(body.minX), to: Int(body.maxX), by: 5) {
                        hash = (hash ^ UInt64(pixels[y * stride + x * 4 + 1])) &* 1099511628211
                    }
                }
                stats["transcriptHash"] = String(hash, radix: 16)
            }
        }
        return stats
    }
}

/// Requests constant viewport motion through the normal AppKit clip view.
/// The display link drives the test workload; only captured pixels supply
/// the frame measurement. An idle gap inside the interval counts in full.
@MainActor final class TranscriptScrollSample: NSObject {
    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var start: CFTimeInterval?
    private let firstRow: Int
    private let initialY: CGFloat
    private let velocity: CGFloat
    private let duration = 4.0

    private var lastTarget: CFTimeInterval?
    private var maximumTargetGap: CFTimeInterval = 0
    private var steps = 0

    init(scroll: NSScrollView, firstRow: Int) {
        self.scroll = scroll
        self.firstRow = firstRow
        initialY = scroll.contentView.bounds.minY
        velocity = initialY >= 8_000 ? -1_800 : 1_800
        super.init()
        let link = scroll.displayLink(target: self, selector: #selector(step(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scroll, scroll.window?.isKeyWindow == true else { stop(); return }
        if start == nil {
            start = link.targetTimestamp
            DiagnosticMetrics.shared.record("scroll-offset", tag: "row=\(firstRow) y=\(initialY)")
            DiagnosticMetrics.shared.record("scroll-motion-start", tag: String(Int(velocity)))
        }
        if let lastTarget { maximumTargetGap = max(maximumTargetGap, link.targetTimestamp - lastTarget) }
        lastTarget = link.targetTimestamp
        steps += 1
        guard let start else { return }
        let elapsed = link.targetTimestamp - start
        let clip = scroll.contentView
        let proposed = CGRect(origin: CGPoint(x: clip.bounds.minX, y: initialY + velocity * min(duration, elapsed)),
                              size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        if elapsed >= duration {
            DiagnosticMetrics.shared.record("scroll-motion-end")
            DiagnosticMetrics.shared.record("scroll-driver-summary", tag: "callbacks=\(steps) maxTargetGapMS=\(maximumTargetGap * 1_000)")
            stop()
        }
    }

    func stop() { link?.invalidate(); link = nil }
}
