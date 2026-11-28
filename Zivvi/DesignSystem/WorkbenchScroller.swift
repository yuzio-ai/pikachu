import AppKit
import SwiftUI

/// Draws a thinner thumb while AppKit owns the track, hit area and fade timing.
final class WorkbenchScroller: NSScroller {
    private let axis: Axis

    init(frame: NSRect, axis: Axis) {
        self.axis = axis
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }

        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let thickness: CGFloat = increasedContrast ? 6 : 3
        let thumb: NSRect
        if axis == .vertical {
            let width = min(thickness, knob.width)
            thumb = NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
        } else {
            let height = min(thickness, knob.height)
            thumb = NSRect(x: knob.minX, y: knob.midY - height / 2, width: knob.width, height: height)
        }
        ZivviTheme.scrollbarThumbColor(active: hitPart == .knob, increasedContrast: increasedContrast).setFill()
        let radius = min(thumb.width, thumb.height) / 2
        NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        if flag || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            super.drawKnobSlot(in: slotRect, highlight: flag)
        }
    }

    static func install(in scrollView: NSScrollView, axis: Axis) {
        let hasScroller = axis == .vertical ? scrollView.hasVerticalScroller : scrollView.hasHorizontalScroller
        guard hasScroller else { return }
        let keyPath = axis == .vertical ? \NSScrollView.verticalScroller : \NSScrollView.horizontalScroller
        let existing = scrollView[keyPath: keyPath]
        guard !(existing is WorkbenchScroller) else { return }

        let scroller = WorkbenchScroller(frame: existing?.frame ?? .zero, axis: axis)
        if let existing {
            scroller.controlSize = existing.controlSize
            scroller.doubleValue = existing.doubleValue
            scroller.knobProportion = existing.knobProportion
            scroller.isEnabled = existing.isEnabled
        }
        scrollView[keyPath: keyPath] = scroller
    }
}
