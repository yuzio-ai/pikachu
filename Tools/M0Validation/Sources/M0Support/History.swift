import Foundation

/// M0 format probe, not the product history or model-context implementation.
/// Returns active branch entries including compaction/context-edit metadata.
public struct HistoryProbe {
    public let branch: [Record]
    public let entries: [Record]
    public let incompleteTail: Bool
    public static func read(_ bytes: Data) throws -> HistoryProbe {
        var decoder = JSONLDecoder()
        let records = try decoder.feed(bytes)
        guard let header = records.first, header["type"] as? String == "session", header["version"] as? Int == 3 else {
            throw ProbeError.failure("Unsupported or missing session header")
        }
        let entries = Array(records.dropFirst())
        var byID: [String: Record] = [:]
        for r in entries {
            guard let id = r["id"] as? String, byID[id] == nil else { throw ProbeError.failure("Missing/duplicate entry id") }
            byID[id] = r
        }
        var branch: [Record] = [], seen = Set<String>()
        var id = entries.last?["id"] as? String
        while let current = id {
            guard seen.insert(current).inserted, let entry = byID[current] else { throw ProbeError.failure("Broken/cyclic parent chain") }
            branch.append(entry)
            id = entry["parentId"] as? String
        }
        return HistoryProbe(branch: branch.reversed(), entries: entries, incompleteTail: !decoder.pending.isEmpty)
    }
}
