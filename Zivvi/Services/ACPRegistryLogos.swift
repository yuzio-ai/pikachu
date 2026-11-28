import AppKit
import AgentRuntimeCore

@MainActor enum ACPRegistryLogos {
    private struct Entry: Decodable {
        let id: String
        let name: String
    }

    private static let directory = "ACPAgentLogos"
    private static let entries: [Entry] = {
        guard let index = Bundle.main.url(forResource: "Index", withExtension: "json", subdirectory: directory),
              let data = try? Data(contentsOf: index),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }()
    private static let ids = Set(entries.map(\.id))
    private static let entriesByName = Dictionary(grouping: entries) { normalized($0.name) }
    private static var images: [String: NSImage] = [:]

    static func registryID(for profile: RuntimeAgentProfile) -> String? {
        if let id = profile.registryID { return id }
        if profile.isAntigravityPreset { return "antigravity-acp" }
        guard let matches = entriesByName[normalized(profile.name)], matches.count == 1 else { return nil }
        return matches.first?.id
    }

    static func image(for id: String) -> NSImage? {
        if let cached = images[id] { return cached }
        guard ids.contains(id),
              let url = Bundle.main.url(forResource: id, withExtension: "svg", subdirectory: directory),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        images[id] = image
        return image
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
