import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentImagePreview: View {
    struct Selection: Identifiable {
        let file: URL
        var id: URL { file }
    }

    private enum Source: Equatable, Sendable {
        case file(URL)
        case toolResult(Data, name: String)

        var name: String {
            switch self {
            case .file(let file): file.lastPathComponent
            case .toolResult(_, let name): name
            }
        }

        nonisolated func loadPreview() -> CGImage? {
            switch self {
            case .file(let file): ImageAttachmentThumbnail.loadThumbnail(for: file, maxPixels: 2800)
            case .toolResult(let data, _): ImageAttachmentThumbnail.loadThumbnail(from: data, maxPixels: 2800)
            }
        }
    }

    private let source: Source

    init(file: URL) { source = .file(file) }
    init(toolResult: Data, name: String) { source = .toolResult(toolResult, name: name) }

    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: source.name)
                    .pikachuFont(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel(source.name)
                } else if loaded {
                    Text("无法预览此图片。")
                        .foregroundStyle(.secondary)
                } else {
                    FlatProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PikachuTheme.mutedSurface, in: .rect(cornerRadius: 8))
            if case .file(let file) = source {
                HStack {
                    Spacer()
                    Button("打开原图") { NSWorkspace.shared.open(file) }
                        .disabled(image == nil)
                }
            }
        }
        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
        .padding(16)
        .frame(width: 560, height: 430)
        .flatPanelContent()
        .accessibilityIdentifier("attachment-image-preview")
        .task(id: source) {
            let preview = await Task.detached(priority: .userInitiated) { [source] in
                source.loadPreview()
            }.value
            guard !Task.isCancelled else { return }
            image = preview
            loaded = true
        }
    }
}

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
