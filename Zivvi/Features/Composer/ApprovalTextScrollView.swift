import AppKit
import SwiftUI

struct ApprovalTextScrollView: View {
    let text: String
    let maxHeight: CGFloat
    var highlightedText: AttributedString? = nil
    var nativeAttributedText: NSAttributedString? = nil
    var wrapsLines = true
    @Environment(\.zivviTypography) private var typography

    private static let nativeScrollThresholdBytes = 32_768
    private static let nonContiguousThresholdBytes = 524_288

    var body: some View {
        let lineHeight = ApprovalSheetLayout.previewLineHeight(typography: typography)
        if nativeAttributedText != nil || text.utf8.count > Self.nativeScrollThresholdBytes {
            ApprovalNativeTextScrollView(
                text: text,
                highlightedText: highlightedText,
                nativeAttributedText: nativeAttributedText,
                wrapsLines: wrapsLines,
                maxHeight: maxHeight,
                lineHeight: lineHeight,
                font: .monospacedSystemFont(ofSize: typography.pointSize(for: .callout), weight: .regular),
                usesNonContiguousLayout: text.utf8.count > Self.nonContiguousThresholdBytes
            )
        } else {
            let preview = ApprovalVerbatimText(text: text, highlightedText: highlightedText, wrapsLines: wrapsLines)
            ApprovalTextViewport(wrapsLines: wrapsLines, maxHeight: maxHeight, lineHeight: lineHeight) {
                preview.hidden().accessibilityHidden(true)
                ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical]) {
                    preview.textSelection(.enabled)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                .id(wrapsLines)
            }
        }
    }
}

private struct ApprovalTextViewport: Layout {
    let wrapsLines: Bool
    let maxHeight: CGFloat
    let lineHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let textSize = subviews[0].sizeThatFits(textProposal(width: width))
        return CGSize(width: width ?? textSize.width, height: min(maxHeight, max(lineHeight, ceil(textSize.height))))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)
        subviews[0].place(at: origin, anchor: .topLeading, proposal: textProposal(width: bounds.width))
        subviews[1].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    private func textProposal(width: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: wrapsLines ? width : nil, height: nil)
    }
}

private struct ApprovalVerbatimText: View {
    let text: String
    var highlightedText: AttributedString? = nil
    var wrapsLines = true

    var body: some View {
        Group {
            if text.isEmpty {
                Text("（空）").foregroundStyle(ZivviTheme.secondaryText)
            } else if let highlightedText {
                Text(highlightedText)
            } else {
                Text(verbatim: text)
            }
        }
        .zivviFont(.callout, design: .monospaced)
        .fixedSize(horizontal: !wrapsLines, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ApprovalNativeTextScrollView: NSViewRepresentable {
    let text: String
    let highlightedText: AttributedString?
    let nativeAttributedText: NSAttributedString?
    let wrapsLines: Bool
    let maxHeight: CGFloat
    let lineHeight: CGFloat
    let font: NSFont
    let usesNonContiguousLayout: Bool

    func makeNSView(context: Context) -> ApprovalScrollView {
        ApprovalScrollView()
    }

    func updateNSView(_ view: ApprovalScrollView, context: Context) {
        view.update(
            text: text,
            highlightedText: highlightedText,
            nativeAttributedText: nativeAttributedText,
            wrapsLines: wrapsLines,
            font: font,
            lineHeight: lineHeight,
            usesNonContiguousLayout: usesNonContiguousLayout
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ApprovalScrollView, context: Context) -> CGSize? {
        nsView.update(
            text: text,
            highlightedText: highlightedText,
            nativeAttributedText: nativeAttributedText,
            wrapsLines: wrapsLines,
            font: font,
            lineHeight: lineHeight,
            usesNonContiguousLayout: usesNonContiguousLayout
        )
        let proposedWidth = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return nsView.preferredSize(proposedWidth: proposedWidth, maxHeight: maxHeight, lineHeight: lineHeight)
    }
}

final class ApprovalScrollView: NSScrollView, NSLayoutManagerDelegate {
    fileprivate static let unconstrainedContainerDimension: CGFloat = 10_000_000

    private let textView = ApprovalReadOnlyTextView()
    private var currentText: String?
    private var currentHighlightedText: AttributedString?
    private var currentNativeAttributedText: NSAttributedString?
    private var currentFont: NSFont?
    private var wrapsLines = true
    private var usesNonContiguousLayout = false
    private var hasInitialized = false
    private var hasCompletedNonContiguousLayout = false
    private var estimatedFloorHeight: CGFloat = 0
    private var estimatedFloorWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        contentView.copiesOnScroll = true
        textView.layoutManager?.delegate = self
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func update(
        text: String,
        highlightedText: AttributedString?,
        nativeAttributedText: NSAttributedString?,
        wrapsLines: Bool,
        font: NSFont,
        lineHeight: CGFloat,
        usesNonContiguousLayout: Bool
    ) {
        let contentChanged = !hasInitialized
            || currentText != text
            || currentHighlightedText != highlightedText
            || currentNativeAttributedText !== nativeAttributedText
        let fontChanged = currentFont != font
        let wrapChanged = !hasInitialized || self.wrapsLines != wrapsLines
        let layoutModeChanged = self.usesNonContiguousLayout != usesNonContiguousLayout

        guard contentChanged || fontChanged || wrapChanged || layoutModeChanged else { return }

        hasInitialized = true
        self.wrapsLines = wrapsLines
        self.usesNonContiguousLayout = usesNonContiguousLayout
        currentFont = font

        if layoutModeChanged {
            textView.layoutManager?.allowsNonContiguousLayout = usesNonContiguousLayout
        }

        if wrapChanged {
            configureWrapMode(wrapsLines)
        }

        if contentChanged || fontChanged {
            currentText = text
            currentHighlightedText = highlightedText
            currentNativeAttributedText = nativeAttributedText
            hasCompletedNonContiguousLayout = false
            updateEstimatedBounds(text: text, font: font, lineHeight: lineHeight, usesNonContiguousLayout: usesNonContiguousLayout)
            applyContent(text: text, highlightedText: highlightedText, nativeAttributedText: nativeAttributedText, font: font)
        }

        if wrapChanged || contentChanged {
            scrollToOrigin()
        }

        sizeDocument()
        invalidateIntrinsicContentSize()
    }

    func preferredSize(proposedWidth: CGFloat?, maxHeight: CGFloat, lineHeight: CGFloat) -> CGSize {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return CGSize(width: proposedWidth ?? 0, height: min(maxHeight, lineHeight))
        }

        let targetContainerWidth: CGFloat
        if wrapsLines {
            if let proposedWidth {
                targetContainerWidth = max(1, proposedWidth)
            } else if contentView.bounds.width > 0 {
                targetContainerWidth = contentView.bounds.width
            } else {
                targetContainerWidth = Self.unconstrainedContainerDimension
            }
        } else {
            targetContainerWidth = Self.unconstrainedContainerDimension
        }

        if textContainer.containerSize.width != targetContainerWidth {
            textContainer.containerSize = NSSize(width: targetContainerWidth, height: Self.unconstrainedContainerDimension)
        }

        let measuredHeight: CGFloat
        let measuredWidth: CGFloat

        if usesNonContiguousLayout && !hasCompletedNonContiguousLayout {
            let totalLength = textView.textStorage?.length ?? 0
            let sampleRange = NSRange(location: 0, length: min(totalLength, 32_768))
            layoutManager.ensureLayout(forCharacterRange: sampleRange)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: sampleRange, actualCharacterRange: nil)
            let sampleRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            measuredHeight = max(sampleRect.maxY, layoutManager.extraLineFragmentRect.maxY, estimatedFloorHeight)
            measuredWidth = proposedWidth ?? max(1, ceil(sampleRect.maxX), estimatedFloorWidth)
        } else {
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            measuredHeight = max(used.maxY, layoutManager.extraLineFragmentRect.maxY)
            measuredWidth = proposedWidth ?? max(1, ceil(used.maxX))
        }

        return CGSize(
            width: proposedWidth ?? measuredWidth,
            height: min(maxHeight, max(lineHeight, ceil(measuredHeight)))
        )
    }

    override func layout() {
        super.layout()
        sizeDocument()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if currentNativeAttributedText != nil {
                let length = textView.textStorage?.length ?? 0
                if length > 0 {
                    textView.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length))
                }
            } else if let highlighted = currentHighlightedText, let font = currentFont {
                let converted = Self.convertAttributedString(
                    highlighted,
                    font: font,
                    defaultForeground: NSColor(ZivviTheme.primaryText)
                )
                textView.textStorage?.setAttributedString(converted)
            } else {
                textView.textColor = NSColor(ZivviTheme.primaryText)
            }
            textView.needsDisplay = true
        }
    }

    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
    ) {
        guard layoutFinishedFlag else { return }
        Task { @MainActor [weak self] in
            guard let self, self.usesNonContiguousLayout, !self.hasCompletedNonContiguousLayout else { return }
            self.hasCompletedNonContiguousLayout = true
            self.sizeDocument()
        }
    }

    private func updateEstimatedBounds(
        text: String,
        font: NSFont,
        lineHeight: CGFloat,
        usesNonContiguousLayout: Bool
    ) {
        guard usesNonContiguousLayout else {
            estimatedFloorHeight = 0
            estimatedFloorWidth = 0
            return
        }
        var lineCount = 1
        var currentLineScalars = 0
        var maxLineScalars = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                lineCount += 1
                if currentLineScalars > maxLineScalars { maxLineScalars = currentLineScalars }
                currentLineScalars = 0
            } else if (byte & 0xC0) != 0x80 {
                currentLineScalars += 1
            }
        }
        if currentLineScalars > maxLineScalars { maxLineScalars = currentLineScalars }

        let exactLineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? lineHeight
        let charAdvance = ("0" as NSString).size(withAttributes: [.font: font]).width
        estimatedFloorHeight = CGFloat(lineCount) * max(1, exactLineHeight)
        estimatedFloorWidth = CGFloat(maxLineScalars) * max(1, charAdvance)
    }

    private func applyContent(
        text: String,
        highlightedText: AttributedString?,
        nativeAttributedText: NSAttributedString?,
        font: NSFont
    ) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let nativeAttributedText {
                textView.isRichText = true
                textView.font = font
                textView.textStorage?.setAttributedString(nativeAttributedText)
            } else if let highlightedText {
                textView.isRichText = true
                textView.font = font
                let converted = Self.convertAttributedString(
                    highlightedText,
                    font: font,
                    defaultForeground: NSColor(ZivviTheme.primaryText)
                )
                textView.textStorage?.setAttributedString(converted)
            } else {
                textView.isRichText = false
                textView.font = font
                textView.textColor = NSColor(ZivviTheme.primaryText)
                textView.string = text
            }
        }
    }

    private func configureWrapMode(_ wrapsLines: Bool) {
        if wrapsLines {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            let width = max(1, contentView.bounds.width)
            textView.textContainer?.containerSize = NSSize(width: width, height: Self.unconstrainedContainerDimension)
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: Self.unconstrainedContainerDimension,
                height: Self.unconstrainedContainerDimension
            )
        }
    }

    private func sizeDocument() {
        let viewport = contentView.bounds.size
        guard viewport.width > 0 else { return }
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        if wrapsLines {
            if textContainer.containerSize.width != viewport.width {
                textContainer.containerSize = NSSize(width: viewport.width, height: Self.unconstrainedContainerDimension)
            }
            if !usesNonContiguousLayout {
                layoutManager.ensureLayout(for: textContainer)
            }
            let used = layoutManager.usedRect(for: textContainer)
            let height = max(used.maxY, layoutManager.extraLineFragmentRect.maxY)
            let floorHeight = (usesNonContiguousLayout && !hasCompletedNonContiguousLayout) ? estimatedFloorHeight : 0
            let targetSize = NSSize(
                width: viewport.width,
                height: max(viewport.height, ceil(height), ceil(floorHeight))
            )
            if textView.frame.size != targetSize {
                textView.setFrameSize(targetSize)
            }
        } else {
            if textContainer.containerSize.width != Self.unconstrainedContainerDimension {
                textContainer.containerSize = NSSize(
                    width: Self.unconstrainedContainerDimension,
                    height: Self.unconstrainedContainerDimension
                )
            }
            if !usesNonContiguousLayout {
                layoutManager.ensureLayout(for: textContainer)
            }
            let used = layoutManager.usedRect(for: textContainer)
            let height = max(used.maxY, layoutManager.extraLineFragmentRect.maxY)
            let useFloor = usesNonContiguousLayout && !hasCompletedNonContiguousLayout
            let floorHeight = useFloor ? estimatedFloorHeight : 0
            let floorWidth = useFloor ? estimatedFloorWidth : 0
            let targetSize = NSSize(
                width: max(viewport.width, ceil(used.maxX), ceil(floorWidth)),
                height: max(viewport.height, ceil(height), ceil(floorHeight))
            )
            if textView.frame.size != targetSize {
                textView.setFrameSize(targetSize)
            }
        }
    }

    private func scrollToOrigin() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private static func convertAttributedString(
        _ source: AttributedString,
        font: NSFont,
        defaultForeground: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in source.runs {
            let substring = String(source[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: run.swiftUI.foregroundColor.map { NSColor($0) } ?? defaultForeground
            ]
            if let background = run.swiftUI.backgroundColor {
                attributes[.backgroundColor] = NSColor(background)
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }
}

private final class ApprovalReadOnlyTextView: NSTextView {
    private let ownedStorage: NSTextStorage

    override var acceptsFirstResponder: Bool { true }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: ApprovalScrollView.unconstrainedContainerDimension))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        ownedStorage = storage
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(
            width: ApprovalScrollView.unconstrainedContainerDimension,
            height: ApprovalScrollView.unconstrainedContainerDimension
        )
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && enclosingScrollView?.isFindBarVisible != true {
            if window?.performKeyEquivalent(with: event) == true {
                return
            }
            if nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: nil) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true {
            super.cancelOperation(sender)
            return
        }
        if nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) == true {
            return
        }
        if let event = NSApp.currentEvent, event.keyCode == 53 {
            _ = window?.performKeyEquivalent(with: event)
        }
    }
}
