import SwiftUI
import AgentRuntimeCore

struct CodingAgentLabel: View {
    let runtimeID: String
    var displayName: String? = nil
    var agents: [RuntimeAgentProfile] = []

    var body: some View {
        let name = displayName ?? Self.displayName(for: runtimeID, agents: agents)
        HStack(spacing: 6) {
            CodingAgentIcon(runtimeID: runtimeID, displayName: name, agents: agents)
            Text(verbatim: name)
        }
    }

    static func displayName(for runtimeID: String, agents: [RuntimeAgentProfile] = []) -> String {
        if let profile = agents.first(where: { $0.id == runtimeID }) {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if runtimeID == RuntimeAgentProfile.antigravityRuntimeID { return "Antigravity" }
        if runtimeID.hasPrefix(RuntimeAgentProfile.acpRuntimePrefix) {
            let suffix = String(runtimeID.dropFirst(RuntimeAgentProfile.acpRuntimePrefix.count))
            if !suffix.isEmpty { return suffix }
        }
        return runtimeID
    }

    static func initials(for name: String) -> String {
        let letters = String(name.lazy.filter(\.isLetter).prefix(2)).uppercased()
        if !letters.isEmpty { return letters }
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
    }
}

struct CodingAgentIcon: View {
    let runtimeID: String
    var displayName: String? = nil
    var agents: [RuntimeAgentProfile] = []
    var side: CGFloat = 17

    var body: some View {
        let resolvedName = displayName ?? CodingAgentLabel.displayName(for: runtimeID, agents: agents)
        let profile = agents.first { $0.id == runtimeID }
        let registryID = profile.flatMap(ACPRegistryLogos.registryID(for:))
            ?? (runtimeID == RuntimeAgentProfile.antigravityRuntimeID ? "antigravity-acp" : nil)
        ACPAgentLogo(name: resolvedName, registryID: registryID, side: side)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct ACPAgentLogo: View {
    let name: String
    let registryID: String?
    let side: CGFloat

    var body: some View {
        Group {
            if let registryID, let image = ACPRegistryLogos.image(for: registryID) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(PikachuTheme.primaryText)
                    .padding(max(1, side * 0.12))
            } else if registryID == "antigravity-acp" {
                Image("AntigravityAgentLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(max(1, side * 0.12))
            } else {
                Text(verbatim: CodingAgentLabel.initials(for: name))
                    .pikachuFont(.badge, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(PikachuTheme.secondaryText)
                    .frame(width: side, height: side)
                    .background(PikachuTheme.mutedSurface, in: .rect(cornerRadius: 4))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

enum ModelPresentation {
    struct Snapshot {
        let name: String
        let date: String

        var displayDate: String { date.replacingOccurrences(of: "-", with: "") }
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "openai": "OpenAI"
        case "openai-codex": "OpenAI Codex"
        case "anthropic": "Anthropic"
        case "deepseek": "DeepSeek"
        case "google": "Google"
        case "google-vertex": "Google Vertex"
        case "google-gemini-cli": "Google Gemini CLI"
        case "antigravity", "acp:antigravity", "google-antigravity": "Antigravity"
        case "qwen": "Qwen"
        case "qwen-token-plan": "Qwen Token Plan"
        case "qwen-token-plan-cn": "Qwen Token Plan (CN)"
        case "qwen-token-plan-individual": "Qwen Token Plan Individual"
        case "qwen-token-plan-individual-cn": "Qwen Token Plan Individual (CN)"
        default: provider
        }
    }

    static func matches(_ model: RuntimeModel, query: String) -> Bool {
        if query.isEmpty || model.name.localizedStandardContains(query) || model.id.localizedStandardContains(query)
            || providerName(model.provider).localizedStandardContains(query) { return true }
        guard let snapshot = snapshot(model) else { return false }
        return snapshot.date.localizedStandardContains(query) || snapshot.displayDate.localizedStandardContains(query)
    }

    static func snapshot(_ model: RuntimeModel) -> Snapshot? {
        let suffix: String
        let date: String
        if model.provider == "openai", let releaseDate = openAISnapshotDate(model.modelID) {
            suffix = releaseDate
            date = suffix
        } else if tokenPlanProviders.contains(model.provider), let snapshotDate = tokenPlanSnapshots[model.modelID] {
            suffix = snapshotDate.replacingOccurrences(of: "-", with: "")
            date = snapshotDate
        } else {
            return nil
        }

        let name = model.name
        for ending in [" \(suffix)", "-\(suffix)", " (\(suffix))"] where name.hasSuffix(ending) {
            return Snapshot(name: String(name.dropLast(ending.count)), date: date)
        }
        return Snapshot(name: name, date: date)
    }

    private static func openAISnapshotDate(_ id: String) -> String? {
        guard let match = id.firstMatch(of: /-([0-9]{4}-[0-9]{2}-[0-9]{2})$/) else { return nil }
        let text = String(match.1)
        let style = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let date = try? style.parse(text), style.format(date) == text else { return nil }
        return text
    }

    private static let tokenPlanProviders: Set<String> = [
        "qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual", "qwen-token-plan-individual-cn"
    ]
    // Explicit Token Plan model IDs. A numeric suffix elsewhere can be a version or parameter count.
    private static let tokenPlanSnapshots = [
        "deepseek-v4.1-flash-1017": "10-17", "deepseek-v4-pro-0813": "08-13", "deepseek-v4-flash-0731": "07-31"
    ]
}
