import AppKit
import SwiftUI
import os
import ProcessSupervision

@MainActor protocol TranscriptScrollDiagnosticTarget: AnyObject {
    var diagnosticWindow: NSWindow? { get }
    func startScrollSample() -> Bool
    func positionScrollSample(at row: Int) -> Bool
}

/// Explicit, separately bundled diagnostics. Records only timing/counts, never text.
/// A draw/transaction commit is a client endpoint, not proof of pixel presentation.
@MainActor final class DiagnosticMetrics {
    static let shared = DiagnosticMetrics()
    var enabled: Bool { destination != nil }
    private let destination: URL?
    private let pixels: WindowPixelCapture?
    var measuresPixels: Bool { pixels != nil }
    let scrollStartRow: Int?
    private let scrollTargets = NSHashTable<AnyObject>.weakObjects()

    func register(_ target: any TranscriptScrollDiagnosticTarget) { scrollTargets.add(target) }
    func unregister(_ target: any TranscriptScrollDiagnosticTarget) { scrollTargets.remove(target) }

    func scrollTarget(in window: NSWindow) -> (any TranscriptScrollDiagnosticTarget)? {
        scrollTargets.allObjects.lazy.compactMap { $0 as? any TranscriptScrollDiagnosticTarget }
            .first { $0.diagnosticWindow === window }
    }

    private let writer = DispatchQueue(label:"ai.yuzio.zivvi.diagnostic-metrics")
    private let log = OSLog(subsystem:"ai.yuzio.zivvi",category:.pointsOfInterest)
    private var monitor: Any?
    private var marks = 0
    private var firstEditor = false
    private let processStart: Double?
    private init() {
        let config = Bundle.main.url(forResource:"DiagnosticsConfiguration",withExtension:"json").flatMap { try? Data(contentsOf:$0) }.flatMap { try? JSONDecoder().decode([String:String].self,from:$0) }
        scrollStartRow = config?["--scroll-start-row"].flatMap(Int.init)
        destination = config?["--metrics"].map { URL(fileURLWithPath:$0) }
        pixels = config?["--pixel-metrics"].flatMap { WindowPixelCapture(destination: URL(fileURLWithPath: $0)) }
        processStart = ProcessIdentity.read(getpid()).map { Double($0.seconds)+Double($0.microseconds)/1e6 }
        guard destination != nil else { return }
        record("diagnostics-ready")
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.scrollWheel]) { event in
            let consumed = MainActor.assumeIsolated {
                if self.measuresPixels, event.type == .keyDown,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                   let window = event.window ?? NSApp.keyWindow, let target = self.scrollTarget(in: window) {
                    let key = event.charactersIgnoringModifiers?.lowercased()
                    if key == "g", target.startScrollSample() { return true }
                    if key == "h", let row = self.scrollStartRow, target.positionScrollSample(at: row) { return true }
                }
                if event.type == .scrollWheel { self.record("scroll-event",uptime:event.timestamp) }
                else if event.window?.firstResponder is NSTextView, !event.modifierFlags.contains(.command), event.characters?.isEmpty == false {
                    self.record("key-event",uptime:event.timestamp)
                }
                return false
            }
            return consumed ? nil : event
        }
    }
    func record(_ name: String, tag: String = "", uptime: Double? = nil) {
        guard let destination, marks < 10_000 else { return }; marks += 1
        let time = Date().timeIntervalSince1970
        var fields: [String:Any] = ["name":name,"tag":tag,"pid":getpid(),"wall":time,"uptime":uptime ?? ProcessInfo.processInfo.systemUptime]
        if name == "first-editor-client-draw", let processStart { fields["processToClientDrawMS"] = (time-processStart)*1_000 }
        guard var bytes = try? JSONSerialization.data(withJSONObject:fields,options:.sortedKeys) else { return }; bytes.append(10)
        os_signpost(.event,log:log,name:"DiagnosticMetric","%{public}s %{public}s",name,tag)
        let data = bytes
        writer.async {
            if !FileManager.default.fileExists(atPath:destination.path) { _ = FileManager.default.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600]) }
            if let file = try? FileHandle(forWritingTo:destination) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf:data) }
        }
    }
    func drawn(_ tag: String, in view: NSView) {
        guard destination != nil else { return }
        pixels?.observe(view, tag: tag)
        record("client-draw",tag:tag)
        if tag.hasPrefix("editor:"), !firstEditor { firstEditor = true; record("first-editor-client-draw") }
    }
}

struct DiagnosticDrawProbe: NSViewRepresentable {
    let tag: String
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { if view.marker != tag { view.marker = tag; view.needsDisplay = true } }
    final class Probe: NSView {
        var marker = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); if window?.isVisible == true { DiagnosticMetrics.shared.drawn(marker, in: self) } }
    }
}

extension View {
    func diagnosticDraw(_ tag: String) -> some View {
        background { if DiagnosticMetrics.shared.enabled { DiagnosticDrawProbe(tag:tag) } }
    }
}
