import AppKit
import SwiftUI

struct ToolOutputTextView: NSViewRepresentable {
    let text: String
    let wrapsLines: Bool
    @Environment(\.pikachuTypography) private var typography

    func makeNSView(context: Context) -> ToolOutputScrollView {
        ToolOutputScrollView()
    }

    func updateNSView(_ view: ToolOutputScrollView, context: Context) {
        let font = NSFont.monospacedSystemFont(ofSize: typography.pointSize(for: .caption), weight: .regular)
        view.update(text: text, font: font, wrapsLines: wrapsLines)
    }
}

/// The output is one selectable text document. TextKit maps a stable character index
/// between the old and new layouts when the reader changes wrapping.
final class ToolOutputScrollView: NSScrollView {
    private struct ReadingAnchor {
        let character: Int
        let offset: NSPoint
    }

    private let storage: NSTextStorage
    private let reader: NSTextView
    private let textLayout: NSLayoutManager
    private let container: NSTextContainer
    private let inset = NSSize(width: 12, height: 12)
    private var output: String?
    private var wrapsLines = true
    private var restoredPosition: (anchor: ReadingAnchor, viewport: NSRect)?

    init() {
        let storage = NSTextStorage()
        let textLayout = NSLayoutManager()
        let container = NSTextContainer(containerSize: .zero)
        storage.addLayoutManager(textLayout)
        textLayout.addTextContainer(container)
        self.storage = storage
        self.textLayout = textLayout
        self.container = container
        reader = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        reader.textContainerInset = inset
        reader.isEditable = false
        reader.isSelectable = true
        reader.isRichText = false
        reader.isHorizontallyResizable = false
        reader.isVerticallyResizable = false
        reader.drawsBackground = false
        reader.textColor = NSColor(PikachuTheme.primaryText)
        reader.setAccessibilityIdentifier("tool-full-output")

        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .automatic
        documentView = reader
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func layout() {
        super.layout()
        sizeDocument()
    }

    func update(text: String, font: NSFont, wrapsLines: Bool) {
        let textChanged = output != text
        let fontChanged = reader.font != font
        let wrappingChanged = self.wrapsLines != wrapsLines
        guard textChanged || fontChanged || wrappingChanged else { return }

        // Reflow can expose a different leading glyph even when the reader has not moved.
        let previousAnchor = restoredPosition.flatMap { $0.viewport == contentView.bounds ? $0.anchor : nil }
        let anchor = textChanged ? nil : (previousAnchor ?? readingAnchor())
        restoredPosition = nil
        self.wrapsLines = wrapsLines
        hasHorizontalScroller = !wrapsLines
        if textChanged {
            output = text
            reader.string = text
        }
        if textChanged || fontChanged {
            reader.font = font
            reader.textColor = NSColor(PikachuTheme.primaryText)
        }
        sizeDocument()
        if let anchor {
            let glyph = textLayout.glyphIndexForCharacter(at: anchor.character)
            let glyphOrigin = leadingOrigin(of: glyph)
            let textOrigin = reader.textContainerOrigin
            scrollTo(NSPoint(
                x: wrapsLines ? 0 : glyphOrigin.x + textOrigin.x + anchor.offset.x,
                y: glyphOrigin.y + textOrigin.y + anchor.offset.y
            ))
            restoredPosition = (anchor, contentView.bounds)
        } else if textChanged {
            scrollTo(.zero)
        }
    }

    private func sizeDocument() {
        var viewport = contentView.bounds.size
        // Each legacy scrollbar can consume space and trigger the other one.
        for _ in 0..<3 {
            guard resizeDocument(in: viewport), scrollerStyle == .legacy else { return }
            tile()
            let tiledViewport = contentView.bounds.size
            guard tiledViewport != viewport else { return }
            viewport = tiledViewport
        }
    }

    private func resizeDocument(in viewport: NSSize) -> Bool {
        guard viewport.width > inset.width * 2 else { return false }
        let textWidth = wrapsLines ? viewport.width - inset.width * 2 : CGFloat.greatestFiniteMagnitude
        if textWidth != container.containerSize.width {
            container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        textLayout.ensureLayout(for: container)
        let textBounds = textLayout.usedRect(for: container)
        let height = max(textBounds.maxY, textLayout.extraLineFragmentRect.maxY) + inset.height * 2
        let width = wrapsLines ? viewport.width : max(viewport.width, ceil(textBounds.maxX + inset.width * 2))
        let size = NSSize(width: width, height: max(viewport.height, ceil(height)))
        guard reader.frame.size != size else { return false }
        reader.setFrameSize(size)
        return true
    }

    private func readingAnchor() -> ReadingAnchor? {
        let glyphCount = textLayout.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        let textOrigin = reader.textContainerOrigin
        let viewport = contentView.bounds.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y)
        let top = NSPoint(x: max(0, viewport.minX), y: max(0, viewport.minY))
        let topGlyph = min(textLayout.glyphIndex(for: top, in: container), glyphCount - 1)
        var glyph = topGlyph
        if viewport.minX > 0 {
            // Short lines above the visible text may be entirely to the left of the viewport.
            let range = NSRange(location: topGlyph, length: glyphCount - topGlyph)
            textLayout.enumerateLineFragments(forGlyphRange: range) { line, used, _, _, stop in
                if line.minY >= viewport.maxY {
                    stop.pointee = true
                } else if used.maxX > viewport.minX && used.minX < viewport.maxX {
                    let point = NSPoint(x: top.x, y: max(top.y, line.midY))
                    glyph = self.textLayout.glyphIndex(for: point, in: self.container)
                    stop.pointee = true
                }
            }
        }
        let origin = leadingOrigin(of: glyph)
        return ReadingAnchor(
            character: textLayout.characterIndexForGlyph(at: glyph),
            offset: NSPoint(x: viewport.minX - origin.x, y: viewport.minY - origin.y)
        )
    }

    private func leadingOrigin(of glyph: Int) -> NSPoint {
        let fragment = textLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = textLayout.location(forGlyphAt: glyph)
        return NSPoint(x: fragment.minX + location.x, y: fragment.minY)
    }

    private func scrollTo(_ origin: NSPoint) {
        var bounds = contentView.bounds
        bounds.origin = origin
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }
}
