import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Handles composer shortcuts before the field editor treats Return as a commit or pastes an image as text.
struct ComposerInputEvents: NSViewRepresentable {
    let isFocused: FocusState<Bool>.Binding
    let canPasteImage: Bool
    let canSend: Bool
    let onPaste: (ClipboardImage) -> Void
    let onSend: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handleKey = { event, window in
            guard isFocused.wrappedValue else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "v" {
                guard canPasteImage, let image = ClipboardImage.read(from: .general) else { return false }
                onPaste(image)
                return true
            }
            // 36 is Return; 76 is keypad Enter. Do not bypass the input method when it has marked text.
            guard event.keyCode == 36 || event.keyCode == 76,
                  let editor = window.firstResponder as? NSTextView, editor.isEditable, !editor.hasMarkedText() else { return false }
            switch modifiers {
            case [], .shift:
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return true
            case .command:
                if canSend && !event.isARepeat { onSend() }
                return true
            default:
                return false
            }
        }
    }

    final class MonitorView: NSView {
        var handleKey: ((NSEvent, NSWindow) -> Bool)?
        private var monitor: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          window.attachedSheet == nil else { return false }
                    return self.handleKey?(event, window) == true
                }
                return consumed ? nil : event
            }
        }
    }
}

struct ClipboardImage {
    private let data: Data
    private let type: UTType

    static func read(from pasteboard: NSPasteboard) -> Self? {
        // Prefer ready-to-use formats. AppKit and macOS screenshots also offer TIFF.
        for type in [UTType.png, .jpeg, .gif, .webP, .tiff] {
            if let data = pasteboard.data(forType: .init(type.identifier)), !data.isEmpty {
                return Self(data: data, type: type)
            }
        }
        return nil
    }

    func save(in directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == type.identifier,
              CGImageSourceGetCount(source) > 0 else { throw CocoaError(.fileReadCorruptFile) }

        let output: Data
        let fileExtension: String
        if type == .tiff {
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            output = png as Data
            fileExtension = "png"
        } else {
            output = data
            fileExtension = type.preferredFilenameExtension ?? "png"
        }

        // Drafts and history keep the file URL, so it must outlive this app run.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Image-\(UUID().uuidString.prefix(12)).\(fileExtension)")
        try output.write(to: file, options: .atomic)
        return file
    }

    static func removeUnusedPastedFile(_ file: URL, in directory: URL, referenced: [URL]) {
        let target = file.resolvingSymlinksInPath().standardizedFileURL
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard target.deletingLastPathComponent() == root else { return }
        let kept = Set(referenced.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        guard !kept.contains(target) else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
