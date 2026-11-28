import Foundation
import Observation

@MainActor
@Observable
final class ProjectFilesControls {
    private(set) var isOpen = false
    @ObservationIgnored private(set) var visibilityRevision = UUID()
    var blocked = false

    func toggle() {
        guard !blocked else { return }
        setOpen(!isOpen)
    }

    func open() {
        guard !blocked else { return }
        setOpen(true)
    }

    func close() {
        setOpen(false)
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        visibilityRevision = UUID()
        isOpen = open
    }
}
