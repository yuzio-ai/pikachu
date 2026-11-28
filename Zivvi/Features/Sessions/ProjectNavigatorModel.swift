import Foundation
import Observation
import OrchestrationCore

enum ProjectNavigationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case sessions
    case files
    case git

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .sessions: "会话"
        case .files: "文件"
        case .git: "Git"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        }
    }
}

/// Holds independent per-project navigation state (mode, expansion, file tree model)
/// so switching modes or projects never closes tabs or stops background Agents.
@MainActor
@Observable
final class ProjectNavigatorModel {
    private static let modesDefaultsKey = "project-navigator-modes"
    private static let collapsedDefaultsKey = "project-navigator-collapsed"

    private var modes: [UUID: ProjectNavigationMode] = [:]
    private var collapsedProjects: Set<UUID> = []
    @ObservationIgnored private var fileTrees: [UUID: ProjectFilesModel] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader: any ProjectFilesReading

    init(defaults: UserDefaults = .standard, reader: any ProjectFilesReading = ProjectFilesReader()) {
        self.defaults = defaults
        self.reader = reader
        if let savedModes = defaults.dictionary(forKey: Self.modesDefaultsKey) as? [String: String] {
            for (key, value) in savedModes {
                if let id = UUID(uuidString: key), let mode = ProjectNavigationMode(rawValue: value) {
                    modes[id] = mode
                }
            }
        }
        if let savedCollapsed = defaults.array(forKey: Self.collapsedDefaultsKey) as? [String] {
            collapsedProjects = Set(savedCollapsed.compactMap(UUID.init(uuidString:)))
        }
    }

    func mode(for projectID: UUID) -> ProjectNavigationMode {
        modes[projectID] ?? .sessions
    }

    func isExpanded(for projectID: UUID) -> Bool {
        !collapsedProjects.contains(projectID)
    }

    func toggleExpanded(for projectID: UUID) {
        if collapsedProjects.contains(projectID) {
            collapsedProjects.remove(projectID)
        } else {
            collapsedProjects.insert(projectID)
        }
        persist()
    }

    func setExpanded(_ expanded: Bool, for projectID: UUID) {
        let changed = expanded ? collapsedProjects.remove(projectID) != nil : collapsedProjects.insert(projectID).inserted
        if changed { persist() }
    }

    func setMode(_ mode: ProjectNavigationMode, for project: ProjectRecord, gitStore: GitStatusStore) {
        modes[project.id] = mode
        collapsedProjects.remove(project.id)
        persist()
        switch mode {
        case .sessions:
            break
        case .files:
            _ = fileTree(for: project)
            gitStore.refresh(directory: project.path)
        case .git:
            gitStore.refresh(directory: project.path, force: true)
            gitStore.refreshCommits(directory: project.path)
        }
    }

    func fileTree(for project: ProjectRecord) -> ProjectFilesModel {
        if let existing = fileTrees[project.id] {
            existing.bind(to: project.path)
            return existing
        }
        let model = ProjectFilesModel(reader: reader)
        model.bind(to: project.path)
        fileTrees[project.id] = model
        return model
    }

    func removeProject(_ id: UUID) {
        modes.removeValue(forKey: id)
        collapsedProjects.remove(id)
        fileTrees.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        let encodedModes = Dictionary(uniqueKeysWithValues: modes.map { ($0.key.uuidString, $0.value.rawValue) })
        defaults.set(encodedModes, forKey: Self.modesDefaultsKey)
        defaults.set(collapsedProjects.map(\.uuidString), forKey: Self.collapsedDefaultsKey)
    }
}
