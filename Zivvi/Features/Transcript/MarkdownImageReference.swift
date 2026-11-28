import SwiftUI
import Observation

struct MarkdownImageLoader {
    let revision: UUID
    let canLoad: (URL) -> Bool
    let load: @MainActor (URL) async throws -> CGImage
}

extension EnvironmentValues {
    @Entry var markdownImageLoader: MarkdownImageLoader? = nil
}

@MainActor @Observable final class MarkdownImageRequest {
    struct Key: Equatable {
        let revision: UUID
        let attempt: UUID
    }

    enum Status {
        case placeholder, loading, failed, loaded(CGImage)
    }

    private var attempt: UUID?
    private var result: (key: Key, status: Status)?

    func request() { attempt = UUID() }

    func key(for loader: MarkdownImageLoader?, url: URL) -> Key? {
        guard let attempt, let loader, loader.canLoad(url) else { return nil }
        return Key(revision: loader.revision, attempt: attempt)
    }

    func status(for key: Key?) -> Status {
        guard let result, result.key == key else { return .placeholder }
        return result.status
    }

    func update(url: URL, loader: MarkdownImageLoader?, key: Key?) async {
        guard !Task.isCancelled, key == self.key(for: loader, url: url) else { return }
        guard let key, let loader else {
            result = nil
            return
        }
        result = (key, .loading)
        do {
            let image = try await loader.load(url)
            guard !Task.isCancelled, result?.key == key, attempt == key.attempt else { return }
            result = (key, .loaded(image))
        } catch {
            guard !Task.isCancelled, result?.key == key, attempt == key.attempt else { return }
            result = error is CancellationError ? nil : (key, .failed)
        }
    }
}

struct MarkdownImageReference: View {
    @Environment(\.markdownImageLoader) private var loader
    @State private var request = MarkdownImageRequest()
    let url: URL
    let alt: String
    let width: CGFloat
    let style: MarkdownStyle

    private var imageLabel: String {
        alt.isEmpty || alt == "\u{FFFC}" ? String(localized: "图片") : alt
    }

    var body: some View {
        let key = request.key(for: loader, url: url)
        let status = request.status(for: key)
        Group {
            if case .loaded(let image) = status {
                Image(image, scale: 1, label: Text(verbatim: imageLabel))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(width, CGFloat(image.width)))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(verbatim: imageLabel).textSelection(.enabled)
                    } icon: {
                        LightningIconView(.photo, size: 14)
                    }
                    if let loader, loader.canLoad(url) {
                        if case .failed = status {
                            Text("无法显示图片")
                        }
                        Button("显示图片", action: request.request)
                            .buttonStyle(FlatControlButtonStyle())
                            .disabled(isLoading(status))
                    }
                }
                .font(Font(style.caption.font))
                .foregroundStyle(MarkdownColors.secondary)
            }
        }
        .task(id: key) {
            await request.update(url: url, loader: loader, key: key)
        }
    }

    private func isLoading(_ status: MarkdownImageRequest.Status) -> Bool {
        if case .loading = status { return true }
        return false
    }
}
