import SwiftUI
import AgentRuntimeCore

enum ModelListSection: String, Identifiable {
    case favorites, others, hidden

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .favorites: "收藏"
        case .others: "其他模型"
        case .hidden: "已从选择器隐藏"
        }
    }

    /// Hidden wins over favorite: a saved favorite that is switched off is listed once,
    /// under the hidden section, and keeps a filled star so it can be saved again.
    static func group(_ models: [RuntimeModel], favorites: Set<String>, hidden: Set<String>) -> [(section: ModelListSection, models: [RuntimeModel])] {
        [
            (.favorites, models.filter { favorites.contains($0.id) && !hidden.contains($0.id) }),
            (.others, models.filter { !favorites.contains($0.id) && !hidden.contains($0.id) }),
            (.hidden, models.filter { hidden.contains($0.id) }),
        ].filter { !$0.1.isEmpty }
    }
}
