import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageAttachmentThumbnail: View {
    let file: URL
    var size: CGFloat = ImageAttachmentThumbnail.defaultSize
    var onPreview: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: (file: URL, image: CGImage)?
    @State private var isHovered = false
    @FocusState private var removeFocused: Bool

    static let defaultSize: CGFloat = 120
    static let cornerRadius: CGFloat = 9

    private struct Request: Equatable {
        let file: URL
        let maxPixels: Int
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        let request = Request(file: file, maxPixels: Int((size * displayScale).rounded(.up)))
        let showsRemove = isHovered || removeFocused
        let content = ZStack {
            if let thumbnail, thumbnail.file == file {
                Image(decorative: thumbnail.image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .pikachuFont(.caption)
                    Text(file.lastPathComponent)
                        .pikachuFont(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(8)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(PikachuTheme.mutedSurface)
        .clipShape(shape)
        .overlay { shape.strokeBorder(PikachuTheme.border).allowsHitTesting(false) }
        .contentShape(shape)

        Group {
            if let onPreview {
                Button(action: onPreview) { content }
                    .buttonStyle(OverlayFeedbackButtonStyle(shape: shape))
                    .accessibilityLabel("预览 \(file.lastPathComponent)")
                    .accessibilityIdentifier("preview-draft-image")
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
                    Image(systemName: "xmark")
                        .pikachuFont(.caption, weight: .semibold)
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
            let image = await Task.detached(priority: .utility) {
                Self.loadThumbnail(for: request.file, maxPixels: request.maxPixels)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image.map { (request.file, $0) }
        }
    }

    nonisolated static func isImage(_ file: URL) -> Bool {
        file.isFileURL && UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
    }

    nonisolated static func loadThumbnail(for file: URL, maxPixels: Int) -> CGImage? {
        let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        return loadThumbnail(from: source, maxPixels: maxPixels)
    }

    nonisolated static func loadThumbnail(from data: Data, maxPixels: Int) -> CGImage? {
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        return loadThumbnail(from: source, maxPixels: maxPixels)
    }

    private nonisolated static func loadThumbnail(from source: CGImageSource?, maxPixels: Int) -> CGImage? {
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
