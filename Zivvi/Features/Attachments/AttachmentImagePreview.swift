import AppKit
import ImageIO
import OrchestrationCore
import SwiftUI
import UniformTypeIdentifiers

struct ImagePreviewSelection: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case file(URL)
        case embedded(Data, name: String)
    }

    let id = UUID()
    let source: Source
    var toolResult: ToolResultSource?

    static func file(_ file: URL) -> Self { Self(source: .file(file)) }
    static func embedded(_ data: Data, name: String) -> Self { Self(source: .embedded(data, name: name)) }

    @MainActor func trackingToolOutput(_ item: TranscriptItem) -> Self {
        var selection = self
        selection.toolResult = ToolResultSource(item: item)
        return selection
    }

    @MainActor var isCurrent: Bool {
        guard let toolResult, case .embedded(let data, _) = source else { return true }
        return toolResult.current?.tool?.outputImage == data
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    var displayName: String {
        switch source {
        case .file(let file):
            return file.lastPathComponent
        case .embedded(_, let name):
            let component = URL(fileURLWithPath: name).lastPathComponent
            return component.isEmpty || component == "/" ? name : component
        }
    }

    var helpText: String {
        switch source {
        case .file(let file): file.path
        case .embedded(_, let name): name
        }
    }

    nonisolated func loadPreviewImage() -> CGImage? {
        switch source {
        case .file(let file):
            ImageAttachmentThumbnail.loadThumbnail(for: file, maxPixels: ImagePreviewViewportMath.maximumPreviewPixels)
        case .embedded(let data, _):
            ImageAttachmentThumbnail.loadThumbnail(from: data, maxPixels: ImagePreviewViewportMath.maximumPreviewPixels)
        }
    }
}

enum ImagePreviewViewportMath {
    nonisolated static let maximumPreviewPixels = 8192
    nonisolated static let maximumScale: CGFloat = 5.0
    nonisolated static let zoomSteps: [CGFloat] = [
        0.10, 0.15, 0.25, 0.33, 0.50, 0.67, 0.75, 1.00, 1.25, 1.50, 2.00, 2.50, 3.00, 4.00, 5.00
    ]

    nonisolated static func fitScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(1, min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height))
    }

    nonisolated static func minimumScale(fitScale: CGFloat) -> CGFloat {
        max(0.10, min(fitScale, 0.25))
    }

    nonisolated static func clampScale(_ scale: CGFloat, fitScale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale(fitScale: fitScale), scale))
    }

    nonisolated static func nextZoomInScale(from current: CGFloat, fitScale: CGFloat) -> CGFloat {
        let next = zoomSteps.first { $0 > current * 1.08 } ?? maximumScale
        return clampScale(next, fitScale: fitScale)
    }

    nonisolated static func nextZoomOutScale(from current: CGFloat, fitScale: CGFloat) -> CGFloat {
        let minScale = minimumScale(fitScale: fitScale)
        let previous = zoomSteps.last { $0 < current / 1.08 } ?? minScale
        return clampScale(previous, fitScale: fitScale)
    }

    nonisolated static func canZoomIn(from current: CGFloat) -> Bool {
        current < maximumScale - 0.005
    }

    nonisolated static func canZoomOut(from current: CGFloat, fitScale: CGFloat) -> Bool {
        current > minimumScale(fitScale: fitScale) + 0.005
    }

    nonisolated static func toggledScale(current: CGFloat?, fitScale: CGFloat) -> CGFloat? {
        guard current == nil else { return nil }
        return abs(fitScale - 1) > 0.02 ? 1.0 : 2.0
    }

    nonisolated static func doubleTapScale(current: CGFloat?, fitScale: CGFloat) -> CGFloat? {
        if let current, abs(current - fitScale) > 0.02 {
            return nil
        }
        return fitScale >= 0.98 ? 2.0 : max(1.0, min(maximumScale, fitScale * 2.0))
    }

    nonisolated static func clampedOffset(_ proposed: CGSize, imageSize: CGSize, scale: CGFloat, viewportSize: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width * scale - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height * scale - viewportSize.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }

    nonisolated static func canPan(imageSize: CGSize, scale: CGFloat, viewportSize: CGSize) -> Bool {
        imageSize.width * scale > viewportSize.width + 0.5 || imageSize.height * scale > viewportSize.height + 0.5
    }

    nonisolated static func suggestedSaveFilename(name: String, utType: UTType?) -> String {
        let component = URL(fileURLWithPath: name).lastPathComponent
        let base = component.isEmpty || component == "/" ? "image" : component
        guard let ext = utType?.preferredFilenameExtension else { return base }
        let existingExt = URL(fileURLWithPath: base).pathExtension
        if existingExt.isEmpty {
            return "\(base).\(ext)"
        }
        if let utType, let existingType = UTType(filenameExtension: existingExt), existingType.conforms(to: utType) {
            return base
        }
        return "\(base).\(ext)"
    }
}

struct AttachmentImagePreview: View {
    let selection: ImagePreviewSelection
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var image: CGImage?
    @State private var loaded = false
    @State private var containerSize: CGSize = .zero
    @State private var manualScale: CGFloat?
    @State private var pinchMultiplier: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var copiedFeedback = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var actionError: String?
    @FocusState private var isFocused: Bool

    private var fitViewportSize: CGSize {
        CGSize(width: max(1, containerSize.width - 56), height: max(1, containerSize.height - 128))
    }

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    private var fitScale: CGFloat {
        ImagePreviewViewportMath.fitScale(imageSize: imageSize, viewportSize: fitViewportSize)
    }

    private var baseScale: CGFloat {
        manualScale ?? fitScale
    }

    private var effectiveScale: CGFloat {
        ImagePreviewViewportMath.clampScale(baseScale * pinchMultiplier, fitScale: fitScale)
    }

    private var canPan: Bool {
        guard image != nil else { return false }
        return ImagePreviewViewportMath.canPan(imageSize: imageSize, scale: effectiveScale, viewportSize: fitViewportSize)
    }

    private var displayedOffset: CGSize {
        guard canPan else { return .zero }
        return ImagePreviewViewportMath.clampedOffset(
            CGSize(width: offset.width + dragTranslation.width, height: offset.height + dragTranslation.height),
            imageSize: imageSize,
            scale: effectiveScale,
            viewportSize: fitViewportSize
        )
    }

    private var backdropColor: Color {
        reduceTransparency ? Color(white: 0.08) : Color.black.opacity(0.76)
    }

    var body: some View {
        ZStack {
            Button(action: dismiss) {
                backdropColor
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
            }
            .buttonStyle(LightboxBackdropButtonStyle())
            .accessibilityHidden(true)

            canvasContent

            VStack(spacing: 0) {
                topBar
                if let actionError {
                    Text(verbatim: actionError)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.errorText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ZivviTheme.surface, in: Capsule())
                        .overlay { Capsule().strokeBorder(ZivviTheme.border) }
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
                        .padding(.top, ZivviSpacing.dialogItemGap)
                }
                Spacer(minLength: 0)
                if image != nil {
                    zoomControls
                        .padding(.bottom, 16)
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self, of: \.size) { containerSize = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onExitCommand(perform: dismiss)
        .onKeyPress { handleKeyPress($0) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("attachment-image-preview")
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
        .task(id: selection) {
            resetForNewSelection()
            let preview = await Task.detached(priority: .userInitiated) { [selection] in
                selection.loadPreviewImage()
            }.value
            guard !Task.isCancelled else { return }
            image = preview
            loaded = true
        }
        .onChange(of: containerSize) { _, _ in
            clampOffsetIfNeeded()
        }
    }

    @ViewBuilder
    private var canvasContent: some View {
        if let image {
            let renderedWidth = imageSize.width * effectiveScale
            let renderedHeight = imageSize.height * effectiveScale
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: renderedWidth, height: renderedHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .offset(displayedOffset)
                .contentShape(Rectangle())
                .gesture(magnifyGesture)
                .gesture(panGesture, including: canPan ? .all : .none)
                .onTapGesture(count: 2) {
                    applyScale(ImagePreviewViewportMath.doubleTapScale(current: manualScale, fitScale: fitScale))
                }
                .accessibilityLabel(selection.displayName)
                .accessibilityIdentifier("attachment-image-preview-canvas")
        } else if loaded {
            VStack(spacing: 8) {
                LightningIconView(.photo, size: 22)
                Text("无法预览此图片。")
                    .zivviFont(.body)
                    .foregroundStyle(ZivviTheme.primaryText)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .flatSurface(ZivviTheme.surface, radius: 12)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        } else {
            FlatProgressView("正在加载图片…")
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .flatSurface(ZivviTheme.surface, radius: 12)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: selection.displayName)
                    .zivviFont(.callout, weight: .medium)
                    .foregroundStyle(ZivviTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let image {
                    Text(verbatim: "\(image.width) × \(image.height)")
                        .zivviFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(ZivviTheme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(ZivviTheme.border).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            .help(selection.helpText)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: copyImage) {
                    LightningIconView(copiedFeedback ? .checkmark : .docOnDoc, size: 15)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 15, height: 30))
                .keyboardShortcut("c", modifiers: .command)
                .disabled(image == nil)
                .help(copiedFeedback ? Text("已复制图片") : Text("复制图片 (⌘C)"))
                .accessibilityLabel(copiedFeedback ? Text("已复制图片") : Text("复制图片"))
                .accessibilityIdentifier("image-preview-copy")

                switch selection.source {
                case .file(let file):
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        LightningIconView(.folder, size: 15)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 15, height: 30))
                    .help("在访达中显示")
                    .accessibilityLabel(Text("在访达中显示"))
                    .accessibilityIdentifier("image-preview-reveal")

                    Button { NSWorkspace.shared.open(file) } label: {
                        LightningIconView(.arrowUpRightSquare, size: 15)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 15, height: 30))
                    .disabled(image == nil)
                    .help("打开原图")
                    .accessibilityLabel(Text("打开原图"))
                    .accessibilityIdentifier("image-preview-open-original")

                case .embedded(let data, let name):
                    Button { saveEmbeddedImage(data: data, name: name) } label: {
                        LightningIconView(.arrowDownToLine, size: 15)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 15, height: 30))
                    .disabled(image == nil)
                    .help("保存图片…")
                    .accessibilityLabel(Text("保存图片…"))
                    .accessibilityIdentifier("image-preview-save")
                }

                Button(action: dismiss) {
                    LightningIconView(.xmark, size: 15)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false, cornerRadius: 15, height: 30))
                .keyboardShortcut(.cancelAction)
                .help("关闭 (Esc)")
                .accessibilityLabel(Text("关闭"))
                .accessibilityIdentifier("image-preview-close")
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        }
        // Keep clear of the window traffic lights on the leading edge.
        .padding(.leading, 88)
        .padding(.trailing, 16)
    }

    private var zoomControls: some View {
        let percentage = Int((effectiveScale * 100).rounded())
        let showingFit = manualScale == nil || abs(effectiveScale - fitScale) <= 0.02
        return HStack(spacing: 2) {
            Button(action: zoomOut) {
                LightningIconView(.minus, size: 14)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 14, height: 28))
            .disabled(!ImagePreviewViewportMath.canZoomOut(from: effectiveScale, fitScale: fitScale))
            .help("缩小 (-)")
            .accessibilityLabel(Text("缩小"))
            .accessibilityIdentifier("image-preview-zoom-out")

            Button {
                applyScale(ImagePreviewViewportMath.toggledScale(current: manualScale, fitScale: fitScale))
            } label: {
                Text(verbatim: "\(percentage)%")
                    .zivviFont(.callout, weight: .medium)
                    .monospacedDigit()
                    .frame(minWidth: 52)
                    .frame(height: 28)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 14, height: 28))
            .help(showingFit ? Text("切换到实际大小 (0)") : Text("切换到适应窗口 (0)"))
            .accessibilityLabel(Text("缩放比例 \(percentage)%"))
            .accessibilityHint(showingFit ? Text("切换到实际大小") : Text("切换到适应窗口"))
            .accessibilityIdentifier("image-preview-zoom-reset")

            Button(action: zoomIn) {
                LightningIconView(.plus, size: 14)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 14, height: 28))
            .disabled(!ImagePreviewViewportMath.canZoomIn(from: effectiveScale))
            .help("放大 (+)")
            .accessibilityLabel(Text("放大"))
            .accessibilityIdentifier("image-preview-zoom-in")
        }
        .padding(3)
        .background(ZivviTheme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(ZivviTheme.border).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinchMultiplier = value.magnification
            }
            .onEnded { value in
                let target = ImagePreviewViewportMath.clampScale(baseScale * value.magnification, fitScale: fitScale)
                pinchMultiplier = 1
                applyScale(target, animated: false)
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { value in
                offset = ImagePreviewViewportMath.clampedOffset(
                    CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                    imageSize: imageSize,
                    scale: effectiveScale,
                    viewportSize: fitViewportSize
                )
                dragTranslation = .zero
            }
    }

    private func zoomIn() {
        applyScale(ImagePreviewViewportMath.nextZoomInScale(from: effectiveScale, fitScale: fitScale))
    }

    private func zoomOut() {
        applyScale(ImagePreviewViewportMath.nextZoomOutScale(from: effectiveScale, fitScale: fitScale))
    }

    private func resetZoom() {
        applyScale(nil)
    }

    private func applyScale(_ target: CGFloat?, animated: Bool = true) {
        let update = {
            manualScale = target
            if let target {
                offset = ImagePreviewViewportMath.clampedOffset(offset, imageSize: imageSize, scale: target, viewportSize: fitViewportSize)
            } else {
                offset = .zero
            }
        }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.16), update)
        } else {
            update()
        }
    }

    private func clampOffsetIfNeeded() {
        guard canPan else {
            offset = .zero
            return
        }
        offset = ImagePreviewViewportMath.clampedOffset(offset, imageSize: imageSize, scale: effectiveScale, viewportSize: fitViewportSize)
    }

    private func resetForNewSelection() {
        image = nil
        loaded = false
        manualScale = nil
        pinchMultiplier = 1
        offset = .zero
        dragTranslation = .zero
        copiedFeedback = false
        copyFeedbackTask?.cancel()
        actionError = nil
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            dismiss()
            return .handled
        }
        let nonShiftModifiers = press.modifiers.subtracting([.shift, .numericPad])
        guard nonShiftModifiers.isEmpty else { return .ignored }
        switch press.characters {
        case "+", "=":
            if ImagePreviewViewportMath.canZoomIn(from: effectiveScale) { zoomIn() }
            return .handled
        case "-":
            if ImagePreviewViewportMath.canZoomOut(from: effectiveScale, fitScale: fitScale) { zoomOut() }
            return .handled
        case "0":
            resetZoom()
            return .handled
        default:
            break
        }
        guard canPan else { return .ignored }
        let step: CGFloat = 48
        switch press.key {
        case .leftArrow:
            nudgeOffset(dx: step, dy: 0)
            return .handled
        case .rightArrow:
            nudgeOffset(dx: -step, dy: 0)
            return .handled
        case .upArrow:
            nudgeOffset(dx: 0, dy: step)
            return .handled
        case .downArrow:
            nudgeOffset(dx: 0, dy: -step)
            return .handled
        default:
            return .ignored
        }
    }

    private func nudgeOffset(dx: CGFloat, dy: CGFloat) {
        offset = ImagePreviewViewportMath.clampedOffset(
            CGSize(width: offset.width + dx, height: offset.height + dy),
            imageSize: imageSize,
            scale: effectiveScale,
            viewportSize: fitViewportSize
        )
    }

    private func copyImage() {
        guard selection.isCurrent, let image, Self.copyToPasteboard(image) else { return }
        copiedFeedback = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedFeedback = false
        }
    }

    private func saveEmbeddedImage(data: Data, name: String) {
        guard selection.isCurrent else { return }
        actionError = nil
        let detectedType = Self.imageType(from: data)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ImagePreviewViewportMath.suggestedSaveFilename(name: name, utType: detectedType)
        if let detectedType {
            panel.allowedContentTypes = [detectedType]
        }
        let writeFile: (URL) -> Void = { url in
            guard selection.isCurrent else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                actionError = String(localized: "无法保存此图片。")
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    writeFile(url)
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            writeFile(url)
        }
    }

    nonisolated static func imageType(from data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String? else {
            return nil
        }
        return UTType(identifier)
    }

    @discardableResult
    static func copyToPasteboard(_ image: CGImage, pasteboard: NSPasteboard = .general) -> Bool {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.clearContents()
        return pasteboard.writeObjects([nsImage])
    }
}

private struct LightboxBackdropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
