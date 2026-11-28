import AppKit
@testable import Zivvi

/// True for the transcript's scroll view under either engine: the AppKit table
/// engine's `TranscriptScroll` or the `NSScrollView` behind `SwiftUITranscript`.
@MainActor func isTranscriptScrollView(_ view: NSView) -> Bool {
    view is NativeTranscript.TranscriptScroll ||
        (view as? NSScrollView)?.identifier == SwiftUITranscript.scrollIdentifier
}

@MainActor func findTranscriptScrollView(in view: NSView) -> NSScrollView? {
    if isTranscriptScrollView(view) { return view as? NSScrollView }
    return view.subviews.lazy.compactMap { findTranscriptScrollView(in: $0) }.first
}
