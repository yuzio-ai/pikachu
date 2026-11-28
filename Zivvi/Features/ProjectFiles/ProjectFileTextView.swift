import AppKit
import SwiftUI

struct ProjectFileLineTarget: Equatable {
    let line: Int
    let id = UUID()
}

struct ProjectFileTextView: NSViewRepresentable {
    let document: ProjectFileDocument
    let wrapsLines: Bool
    let focusRequest: Int
    var targetLine: ProjectFileLineTarget? = nil
    var isEditable: Bool = false
    var onTextChange: ((String) -> Void)? = nil
    @Environment(\.zivviTypography) private var typography

    func makeNSView(context: Context) -> ProjectFileScrollView {
        let view = ProjectFileScrollView()
        view.lastFocusRequest = focusRequest
        return view
    }

    func updateNSView(_ view: ProjectFileScrollView, context: Context) {
        view.isEditable = isEditable
        view.onTextChange = onTextChange
        let font = NSFont.monospacedSystemFont(
            ofSize: typography.pointSize(for: .caption), weight: .regular
        )
        view.update(document: document, font: font, wrapsLines: wrapsLines, targetLine: targetLine)
        if focusRequest != view.lastFocusRequest {
            view.lastFocusRequest = focusRequest
            view.focusReader()
        }
    }
}

final class ProjectFileScrollView: NSScrollView, NSTextViewDelegate {
    private struct Anchor {
        let line: Int
        let column: Int
        let offset: CGFloat
        let horizontalOffset: CGFloat
    }

    private let reader = ProjectFileReaderTextView()
    private let lineNumbers = ProjectFileLineNumbers()
    private var gutterWidth: CGFloat = 44
    private var document: ProjectFileDocument?
    private var laidOutWidth: CGFloat?
    private var wrapsLines = true
    private var restoredWrapPosition: (anchor: Anchor, viewport: NSRect)?
    private var pendingResizeAnchor: Anchor?
    private var pendingLineReveal: Int?
    private var lastLineTargetID: UUID?
    private var isApplyingExternalUpdate = false
    var lastFocusRequest = 0
    var onTextChange: ((String) -> Void)?
    var isEditable: Bool {
        get { reader.isEditable }
        set {
            guard reader.isEditable != newValue else { return }
            reader.isEditable = newValue
            reader.allowsUndo = newValue
            reader.isAutomaticQuoteSubstitutionEnabled = false
            reader.isAutomaticDashSubstitutionEnabled = false
            reader.isAutomaticTextReplacementEnabled = false
            reader.isAutomaticSpellingCorrectionEnabled = false
            reader.insertionPointColor = NSColor(ZivviTheme.primaryText)
        }
    }
    init() {
        super.init(frame: .zero)
        drawsBackground = false
        reader.delegate = self
        documentView = reader
        lineNumbers.scrollView = self
        lineNumbers.setAccessibilityElement(false)
        addSubview(lineNumbers, positioned: .above, relativeTo: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalUpdate else { return }
        let updated = reader.string
        let nextDoc = ProjectFileDocument(updated)
        document = nextDoc
        lineNumbers.document = nextDoc
        updateGutterIfNeeded(for: nextDoc)
        sizeDocument()
        lineNumbers.needsDisplay = true
        onTextChange?(updated)
    }

    private func updateGutterIfNeeded(for doc: ProjectFileDocument) {
        guard let font = reader.font else { return }
        let digits = String(doc.lineStarts.count) as NSString
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let needed = max(44, ceil(digits.size(withAttributes: [.font: digitFont]).width) + 14)
        if abs(needed - gutterWidth) > 0.5 {
            gutterWidth = needed
            reader.textContainerInset = NSSize(width: gutterWidth + 11, height: 10)
            positionLineNumbers()
        }
    }

    func focusReader() {
        window?.makeFirstResponder(reader)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width, pendingResizeAnchor == nil {
            // Tiling the narrower clip can reset its bounds before layout runs.
            pendingResizeAnchor = readingAnchor()
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        let viewport = contentView.bounds
        if restoredWrapPosition?.viewport != viewport {
            restoredWrapPosition = nil
        }
        super.layout()
        positionLineNumbers()
        let resizeAnchor = pendingResizeAnchor ?? (contentView.bounds.width != laidOutWidth ? readingAnchor() : nil)
        pendingResizeAnchor = nil
        sizeDocument()
        if pendingLineReveal != nil {
            revealPendingLine()
        } else if let position = restoredWrapPosition, contentView.bounds != viewport {
            // AppKit can reset the clip origin when it tiles after the wrapped document shrinks.
            reveal(position.anchor, preserveDuringLayout: true)
        } else if let resizeAnchor {
            reveal(resizeAnchor)
        }
    }

    func update(document next: ProjectFileDocument, font: NSFont, wrapsLines: Bool = true,
                targetLine: ProjectFileLineTarget? = nil) {
        let lineChanged = targetLine?.id != lastLineTargetID
        if lineChanged {
            lastLineTargetID = targetLine?.id
            pendingLineReveal = targetLine?.line
        }
        let textChanged = document?.id != next.id
        let fontChanged = reader.font != font
        let wrapChanged = self.wrapsLines != wrapsLines
        guard textChanged || fontChanged || wrapChanged || lineChanged else { return }

        if !textChanged && !fontChanged && !wrapChanged {
            revealPendingLine()
            return
        }

        let old = document
        let contentsChanged = old.map { !$0.text.utf16.elementsEqual(next.text.utf16) } ?? true
        if !contentsChanged, !fontChanged, !wrapChanged {
            document = next
            lineNumbers.document = next
            revealPendingLine()
            return
        }
        let anchor = pendingResizeAnchor ?? readingAnchor()
        pendingResizeAnchor = nil
        restoredWrapPosition = nil
        self.wrapsLines = wrapsLines
        document = next
        lineNumbers.document = next
        if contentsChanged {
            isApplyingExternalUpdate = true
            reader.string = next.text
            isApplyingExternalUpdate = false
        }
        if fontChanged {
            reader.font = font
            reader.textColor = NSColor(ZivviTheme.primaryText)
        }
        let digits = String(next.lineStarts.count) as NSString
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        gutterWidth = max(44, ceil(digits.size(withAttributes: [.font: digitFont]).width) + 14)
        reader.textContainerInset = NSSize(width: gutterWidth + 11, height: 10)
        positionLineNumbers()
        sizeDocument()
        if pendingLineReveal != nil {
            revealPendingLine()
        } else if let old, let anchor {
            let line = contentsChanged ? next.restoredLine(from: old, at: anchor.line) : anchor.line
            let column = next.hasSameLine(line, as: old, at: anchor.line) ? anchor.column : 0
            reveal(Anchor(line: line, column: column, offset: anchor.offset,
                          horizontalOffset: anchor.horizontalOffset), preserveDuringLayout: wrapChanged)
        } else {
            scroll(to: 0)
        }
        lineNumbers.needsDisplay = true
    }

    private func revealPendingLine() {
        guard let line = pendingLineReveal, let document, !document.text.isEmpty,
              laidOutWidth != nil, contentView.bounds.height > 0 else { return }
        pendingLineReveal = nil
        let lineIndex = max(0, min(document.lineStarts.count - 1, line - 1))
        reveal(Anchor(line: lineIndex, column: 0, offset: 0, horizontalOffset: 0))
    }

    private func positionLineNumbers() {
        let clip = contentView.frame
        lineNumbers.frame = NSRect(x: clip.minX, y: clip.minY, width: gutterWidth, height: clip.height)
    }

    private func sizeDocument() {
        let viewport = contentView.bounds.size
        guard viewport.width > 65, viewport.height > 0 else { return }
        let width = wrapsLines ? max(1, viewport.width - reader.textContainerInset.width - 11) : .greatestFiniteMagnitude
        let container = reader.textContainer!
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        laidOutWidth = viewport.width

        let layout = reader.layoutManager!
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(used.maxY, layout.extraLineFragmentRect.maxY)
            + reader.textContainerInset.height * 2
        let documentWidth = wrapsLines ? viewport.width : max(viewport.width, ceil(used.maxX) + reader.textContainerInset.width + 11)
        let size = NSSize(width: documentWidth, height: max(viewport.height, ceil(height)))
        if reader.frame.size != size { reader.setFrameSize(size) }
    }

    private func readingAnchor() -> Anchor? {
        guard let document, !document.text.isEmpty, let layout = reader.layoutManager,
              laidOutWidth != nil, layout.numberOfGlyphs > 0 else { return nil }
        let origin = reader.textContainerOrigin
        let top = max(0, contentView.bounds.minY - origin.y)
        let glyph = min(layout.glyphIndex(for: NSPoint(x: 0, y: top), in: reader.textContainer!),
                        layout.numberOfGlyphs - 1)
        let character = layout.characterIndexForGlyph(at: glyph)
        let line = document.line(at: character)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return Anchor(line: line, column: character - document.lineStarts[line],
                      offset: contentView.bounds.minY - origin.y - fragment.minY,
                      horizontalOffset: contentView.bounds.minX)
    }

    private func reveal(_ anchor: Anchor, preserveDuringLayout: Bool = false) {
        guard let document, !document.text.isEmpty, let layout = reader.layoutManager,
              laidOutWidth != nil else { return }
        let character = document.lineStarts[anchor.line] + anchor.column
        let y: CGFloat
        if character >= (document.text as NSString).length {
            y = layout.extraLineFragmentRect.minY
        } else {
            let glyph = layout.glyphIndexForCharacter(at: character)
            y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        scroll(to: reader.textContainerOrigin.y + y + anchor.offset, horizontal: anchor.horizontalOffset)
        if preserveDuringLayout {
            restoredWrapPosition = (anchor, contentView.bounds)
        }
    }

    private func scroll(to y: CGFloat, horizontal: CGFloat = 0) {
        var bounds = contentView.bounds
        bounds.origin = NSPoint(x: wrapsLines ? 0 : horizontal, y: y)
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func reflectScrolledClipView(_ view: NSClipView) {
        super.reflectScrolledClipView(view)
        lineNumbers.needsDisplay = true
    }
}

private final class ProjectFileReaderTextView: NSTextView {
    private let ownedStorage: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        ownedStorage = storage
        super.init(frame: .zero, textContainer: container)

        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        textContainerInset = NSSize(width: 55, height: 10)
        isEditable = false
        isSelectable = true
        isRichText = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        drawsBackground = false
        setAccessibilityIdentifier("project-files-text")
        setAccessibilityLabel(String(localized: "文件正文"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
}

final class ProjectFileLineNumbers: NSView {
    weak var scrollView: NSScrollView?
    var document: ProjectFileDocument?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dirty = dirtyRect.intersection(bounds)
        guard !dirty.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirty).addClip()
        NSColor(ZivviTheme.mutedSurface).setFill()
        dirty.fill()
        guard let document, let scrollView, let reader = scrollView.documentView as? NSTextView,
              let layout = reader.layoutManager, let container = reader.textContainer, let font = reader.font else { return }

        let viewport = scrollView.contentView.bounds
        let origin = reader.textContainerOrigin
        let clipTop = viewport.minY - origin.y
        let visible = NSRect(x: 0, y: clipTop + dirty.minY, width: viewport.width, height: dirty.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor(ZivviTheme.secondaryText)
        ]
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            let line = document.line(at: character)
            guard document.lineStarts[line] == character else { return }
            self.drawNumber(line + 1, at: used.minY - clipTop, attributes: attributes)
        }
        let extraLine = layout.extraLineFragmentUsedRect
        if document.lineStarts.last == (document.text as NSString).length,
           extraLine.height > 0, extraLine.maxY >= visible.minY, extraLine.minY <= visible.maxY {
            drawNumber(document.lineStarts.count, at: extraLine.minY - clipTop, attributes: attributes)
        }
    }

    private func drawNumber(_ line: Int, at y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let number = NSAttributedString(string: String(line), attributes: attributes)
        number.draw(at: NSPoint(x: max(2, bounds.width - number.size().width - 7), y: y))
    }
}
