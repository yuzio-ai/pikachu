import AppKit
import SwiftUI

struct IconButtonLabel: View {
    nonisolated static let side: CGFloat = 26

    private enum Source {
        case system(String)
        case brand(LightningBrandIcon)
        case asset(String)
    }

    @Environment(\.zivviTypography) private var typography
    @Environment(\.isEnabled) private var isEnabled
    private let source: Source
    private let tint: Color

    init(systemName: String, weight: Font.Weight? = nil, tint: Color = ZivviTheme.iconYellow) {
        _ = weight
        source = .system(systemName)
        self.tint = tint
    }

    init(brandIcon: LightningBrandIcon, tint: Color = ZivviTheme.iconYellow) {
        source = .brand(brandIcon)
        self.tint = tint
    }

    init(assetName: String, tint: Color = ZivviTheme.iconYellow) {
        source = .asset(assetName)
        self.tint = tint
    }

    var body: some View {
        let iconSide = typography.pointSize(for: .callout) + 3
        Group {
            switch source {
            case let .system(name):
                LightningIconView(systemName: name, size: iconSide, tint: tint)
            case let .brand(brandIcon):
                LightningBrandIconView(brandIcon, size: iconSide, tint: tint)
            case let .asset(name):
                let side = typography.pointSize(for: .callout) + 4
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .foregroundStyle(tint)
                    .opacity(isEnabled ? 1 : 0.45)
            }
        }
        .frame(width: Self.side, height: Self.side)
    }
}

struct ToolCallIcon: View {
    @Environment(\.zivviTypography) private var typography
    enum Glyph: String {
        case read = "ToolCallFileArrowRight"
        case list = "ToolCallFile"
        case search = "ToolCallFileSearch"
        case edit = "ToolCallFileCode"
        case terminal = "ToolCallTerminal"
        case generic = "ToolCallTools"
    }

    let glyph: Glyph

    var body: some View {
        // The artwork is inset inside its SVG view box.
        let side = typography.pointSize(for: .caption) + 4
        Image(glyph.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .foregroundStyle(ZivviTheme.iconYellow)
            .accessibilityHidden(true)
    }
}

private let gitIconStroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)

struct GitBranchIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var line = Path()
            line.move(to: CGPoint(x: 6 * w, y: 3 * h))
            line.addLine(to: CGPoint(x: 6 * w, y: 15 * h))
            line.move(to: CGPoint(x: 18 * w, y: 9 * h))
            line.addCurve(to: CGPoint(x: 6 * w, y: 18 * h),
                          control1: CGPoint(x: 18 * w, y: 14 * h),
                          control2: CGPoint(x: 12 * w, y: 18 * h))
            var topCircle = Path()
            topCircle.addEllipse(in: CGRect(x: 15 * w, y: 3 * h, width: 6 * w, height: 6 * h))
            var bottomCircle = Path()
            bottomCircle.addEllipse(in: CGRect(x: 3 * w, y: 15 * h, width: 6 * w, height: 6 * h))
            context.stroke(line, with: .foreground, style: gitIconStroke)
            context.stroke(topCircle, with: .foreground, style: gitIconStroke)
            context.stroke(bottomCircle, with: .foreground, style: gitIconStroke)
        }
        .foregroundStyle(ZivviTheme.iconYellow)
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

struct GitCommitIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 9 * w, y: 9 * h, width: 6 * w, height: 6 * h))
            var lines = Path()
            lines.move(to: CGPoint(x: 3 * w, y: 12 * h))
            lines.addLine(to: CGPoint(x: 9 * w, y: 12 * h))
            lines.move(to: CGPoint(x: 15 * w, y: 12 * h))
            lines.addLine(to: CGPoint(x: 21 * w, y: 12 * h))
            context.stroke(circle, with: .foreground, style: gitIconStroke)
            context.stroke(lines, with: .foreground, style: gitIconStroke)
        }
        .foregroundStyle(ZivviTheme.iconYellow)
        .frame(width: 14, height: 13)
        .accessibilityHidden(true)
    }
}

struct FileTextIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width / 24
            let h = size.height / 24
            var outline = Path()
            outline.move(to: CGPoint(x: 14 * w, y: 2 * h))
            outline.addLine(to: CGPoint(x: 6 * w, y: 2 * h))
            outline.addQuadCurve(to: CGPoint(x: 4 * w, y: 4 * h), control: CGPoint(x: 4 * w, y: 2 * h))
            outline.addLine(to: CGPoint(x: 4 * w, y: 20 * h))
            outline.addQuadCurve(to: CGPoint(x: 6 * w, y: 22 * h), control: CGPoint(x: 4 * w, y: 22 * h))
            outline.addLine(to: CGPoint(x: 18 * w, y: 22 * h))
            outline.addQuadCurve(to: CGPoint(x: 20 * w, y: 20 * h), control: CGPoint(x: 20 * w, y: 22 * h))
            outline.addLine(to: CGPoint(x: 20 * w, y: 8 * h))
            outline.closeSubpath()

            var fold = Path()
            fold.move(to: CGPoint(x: 14 * w, y: 2 * h))
            fold.addLine(to: CGPoint(x: 14 * w, y: 8 * h))
            fold.addLine(to: CGPoint(x: 20 * w, y: 8 * h))

            var lines = Path()
            lines.move(to: CGPoint(x: 8 * w, y: 13 * h))
            lines.addLine(to: CGPoint(x: 16 * w, y: 13 * h))
            lines.move(to: CGPoint(x: 8 * w, y: 17 * h))
            lines.addLine(to: CGPoint(x: 16 * w, y: 17 * h))

            context.stroke(outline, with: .foreground, style: gitIconStroke)
            context.stroke(fold, with: .foreground, style: gitIconStroke)
            context.stroke(lines, with: .foreground, style: gitIconStroke)
        }
        .foregroundStyle(ZivviTheme.iconYellow)
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

struct ProviderLogo: View {
    let provider: String
    var model: String? = nil
    private static let frameSide: CGFloat = 13
    private static let defaultSide: CGFloat = 12

    /// Visible marks sit in one optical band next to 13 pt text, so wide or
    /// thin-stroked marks may fill the whole frame instead of the default 12 pt.
    private struct Mark {
        let asset: String
        let side: CGFloat
    }
    private static let marks: [String: Mark] = [
        "openai": .init(asset: "openai", side: defaultSide), "openai-codex": .init(asset: "openai", side: defaultSide),
        "anthropic": .init(asset: "anthropic", side: defaultSide),
        // The whale reads smaller than square marks; it needs the full frame.
        "deepseek": .init(asset: "deepseek", side: frameSide),
        "google": .init(asset: "googlegemini", side: frameSide), "google-vertex": .init(asset: "googlegemini", side: frameSide),
        "google-gemini-cli": .init(asset: "googlegemini", side: frameSide), "gemini": .init(asset: "googlegemini", side: frameSide),
        "antigravity": .init(asset: "antigravity", side: frameSide),
        "acp:antigravity": .init(asset: "antigravity", side: frameSide),
        "google-antigravity": .init(asset: "antigravity", side: frameSide),
        // Qwen's mark is detailed enough that 12 pt cannot resolve its inner strokes.
        "qwen": .init(asset: "qwen", side: frameSide), "qwen-token-plan": .init(asset: "qwen", side: frameSide),
        "qwen-token-plan-cn": .init(asset: "qwen", side: frameSide),
        "qwen-token-plan-individual": .init(asset: "qwen", side: frameSide),
        "qwen-token-plan-individual-cn": .init(asset: "qwen", side: frameSide),
        "dashscope": .init(asset: "qwen", side: frameSide),
        // GLM ships as Z.ai; the bold bars already carry enough weight at 12 pt.
        "zai": .init(asset: "zai", side: defaultSide), "zai-coding-cn": .init(asset: "zai", side: defaultSide),
        "glm": .init(asset: "zai", side: defaultSide), "zhipu": .init(asset: "zai", side: defaultSide),
    ]
    private static let aggregatorProviders: Set<String> = [
        "", "antigravity", "acp:antigravity", "google-antigravity"
    ]
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in Set(marks.values.map(\.asset)) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            images[name] = image
        }
        return images
    }()

    private static func mark(for provider: String, model: String? = nil) -> Mark? {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let direct = marks[normalizedProvider]
        let canInferFromModel = direct == nil
            || aggregatorProviders.contains(normalizedProvider)
            || normalizedProvider.hasPrefix("acp:")
        if canInferFromModel, let model, let inferred = inferredMark(forModel: model) {
            return inferred
        }
        return direct
    }

    private static func inferredMark(forModel model: String) -> Mark? {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        if lower.contains("gemini") { return .init(asset: "googlegemini", side: frameSide) }
        if lower.contains("claude") { return .init(asset: "anthropic", side: defaultSide) }
        if lower.contains("deepseek") { return .init(asset: "deepseek", side: frameSide) }
        if lower.contains("qwen") { return .init(asset: "qwen", side: frameSide) }
        if lower.contains("glm") { return .init(asset: "zai", side: defaultSide) }
        if lower.contains("gpt") || lower.contains("codex")
            || lower.range(of: #"\bo[134](?:\b|-)"#, options: .regularExpression) != nil {
            return .init(asset: "openai", side: defaultSide)
        }
        return nil
    }

    /// Maps a provider/model pair to the bundled mark, or nil when no asset
    /// matches and the generic chip icon applies.
    static func assetName(for provider: String, model: String? = nil) -> String? {
        mark(for: provider, model: model)?.asset
    }

    /// The calibrated draw size inside the 13 pt frame.
    static func drawSide(for provider: String, model: String? = nil) -> CGFloat {
        mark(for: provider, model: model)?.side ?? defaultSide
    }

    var body: some View {
        Group {
            if let mark = Self.mark(for: provider, model: model), let image = Self.images[mark.asset] {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: mark.side, height: mark.side)
            } else {
                LightningIconView(.cpu, size: Self.defaultSide)
            }
        }
        .frame(width: Self.frameSide, height: Self.frameSide)
        .accessibilityHidden(true)
    }
}
