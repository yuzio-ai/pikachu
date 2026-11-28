import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

@MainActor @Observable final class ModelDirectoryState {
    enum LoadStatus: Equatable {
        case loading, ready, outdated, failed(String)
    }

    enum LoadResult {
        case models([RuntimeModel]), failed(String)
    }

    enum SaveSource: Hashable {
        case defaultModel, model(String)
    }

    struct SaveFailure: Equatable {
        let id = UUID()
        let source: SaveSource
        let message: String
    }

    var search = ""
    var showsHidden = false
    private(set) var models: [RuntimeModel] = []
    var saveFailure: SaveFailure?
    private var collapsedSearch: String?
    private var requestedRevision: Int?
    private var loadStatus: LoadStatus = .loading

    var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hiddenExpanded: Bool { query.isEmpty ? showsHidden : collapsedSearch != query }

    func toggleHidden() {
        if query.isEmpty { showsHidden.toggle() }
        else { collapsedSearch = hiddenExpanded ? query : nil }
    }

    func resetSearchExpansion() {
        collapsedSearch = nil
    }

    func loadStatus(for configurationRevision: Int) -> LoadStatus {
        if let requestedRevision, requestedRevision != configurationRevision { return .outdated }
        return loadStatus
    }

    func beginLoad(revision: Int) {
        requestedRevision = revision
        loadStatus = .loading
    }

    func finishLoad(_ result: LoadResult, requested revision: Int, current configurationRevision: Int) {
        guard requestedRevision == revision, configurationRevision == revision else { return }
        switch result {
        case .models(let models):
            self.models = models
            loadStatus = .ready
        case .failed(let message):
            loadStatus = .failed(message)
        }
    }

}

struct ModelSettingsCatalogue {
    let all: [RuntimeModel]
    let available: Set<String>
    let favorites: Set<String>
    let hidden: Set<String>
    let defaultModelID: String?

    init(models: [RuntimeModel], preferences: WorkspaceModelPreferences) {
        var seen: Set<String> = []
        all = (models + preferences.savedModelReferences).filter { seen.insert($0.id).inserted }
        available = Set(models.map(\.id))
        favorites = Set(preferences.favorites.map(\.id))
        hidden = preferences.hiddenModelIDs
        defaultModelID = preferences.defaultModel?.id
    }

    func rowStatus(for modelID: String, verified: Bool) -> ModelSettingsRowStatus {
        ModelSettingsRowStatus(favorite: favorites.contains(modelID), isDefault: defaultModelID == modelID,
                               availability: !verified ? .unverified : available.contains(modelID) ? .available : .unavailable)
    }
}

struct ModelSettingsRowStatus {
    enum Availability: Equatable {
        case available, unverified, unavailable

        var title: LocalizedStringKey? {
            switch self {
            case .available: nil
            case .unverified: "无法验证"
            case .unavailable: "当前不可用"
            }
        }
    }

    let favorite: Bool
    let isDefault: Bool
    let availability: Availability
}
