import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Shows a video attachment as its poster frame. Zivvi never decodes or uploads the video;
/// opening hands the file to the system player.
struct VideoAttachmentThumbnail: View {
    let file: URL
    var size: CGFloat = ImageAttachmentThumbnail.defaultSize
    var onOpen: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var poster: Poster?
    @State private var isHovered = false
    @FocusState private var removeFocused: Bool

    private struct Poster {
        let file: URL
        let image: CGImage
        let duration: String?
    }

    private struct Request: Equatable {
        let file: URL
        let maxPixels: Int
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ImageAttachmentThumbnail.cornerRadius)
        let request = Request(file: file, maxPixels: max(1, Int((size * displayScale).rounded(.up))))
        let showsRemove = isHovered || removeFocused
        let showsPoster = poster?.file == file
        let content = ZStack {
            if let poster, showsPoster {
                Image(decorative: poster.image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                Color.black.opacity(0.18)
                LightningIconView(.playFill, size: 20, tint: ZivviTheme.brandYellow)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            } else {
                VStack(spacing: 4) {
                    LightningIconView(.film, size: 15)
                    Text(file.lastPathComponent)
                        .zivviFont(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(8)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(ZivviTheme.mutedSurface)
        .clipShape(shape)
        .overlay { shape.strokeBorder(ZivviTheme.border).allowsHitTesting(false) }
        .overlay(alignment: .bottomLeading) {
            if let poster, showsPoster, let duration = poster.duration {
                Text(verbatim: duration)
                    .zivviFont(.caption2, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: .capsule)
                    .padding(5)
                    .accessibilityLabel("时长 \(duration)")
            }
        }
        .contentShape(shape)

        Group {
            if let onOpen {
                Button(action: onOpen) { content }
                    .buttonStyle(OverlayFeedbackButtonStyle(shape: shape))
                    .accessibilityLabel("播放 \(file.lastPathComponent)")
                    .accessibilityIdentifier("open-video-attachment")
                    .accessibilityActions {
                        if let remove { Button("移除 \(file.lastPathComponent)", action: remove) }
                    }
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(file.lastPathComponent)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    LightningIconView(.xmark, size: 11)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 11))
                .focused($removeFocused)
                .help("移除 \(file.lastPathComponent)")
                .accessibilityLabel("移除 \(file.lastPathComponent)")
                .padding(5)
                .revealedAction(showsRemove)
            }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 && remove != nil }
        .help(file.path)
        .task(id: request) {
            let loaded = await Self.poster(for: request.file, maxPixels: request.maxPixels)
            guard !Task.isCancelled else { return }
            poster = loaded.map { Poster(file: request.file, image: $0.image, duration: $0.duration) }
        }
    }

    /// Containers the system file type database does not describe still count as video
    /// so they get an attachment chip instead of a text reference.
    private nonisolated static let fallbackExtensions: Set<String> = [
        "avi", "flv", "mkv", "mpg", "mpeg", "wmv"
    ]

    nonisolated static func isVideo(_ file: URL) -> Bool {
        guard file.isFileURL else { return false }
        let ext = file.pathExtension.lowercased()
        // `.ts` is TypeScript source in a coding workbench, not an MPEG-2 transport stream.
        guard ext != "ts" else { return false }
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true { return true }
        return fallbackExtensions.contains(ext)
    }

    /// Loads a representative frame. Any frame within the clip is enough for a cover, so the
    /// generator is allowed infinite tolerance to keep long videos fast to show.
    nonisolated static func poster(for file: URL, maxPixels: Int) async -> (image: CGImage, duration: String?)? {
        let asset = AVURLAsset(url: file)
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(\.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        // Many clips open on a black frame; a second in is more representative when the clip allows it.
        let time = CMTime(seconds: seconds.map { $0 > 2 ? 1 : $0 / 2 } ?? 0, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return (image, seconds.map(durationText))
    }

    nonisolated static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}
