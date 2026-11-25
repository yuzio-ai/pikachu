import Foundation
import SwiftData
import OrchestrationCore

enum WorkspaceSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Library.self] }
    @Model final class Library {
        @Attribute(.unique) var key: String
        var revision: Int64
        var payload: Data
        init(revision: Int64, payload: Data) { key = "workspace"; self.revision = revision; self.payload = payload }
    }
}

/// One atomic, versioned metadata document. Frozen dialogue segments are stored separately.
/// Only neutral Codable values cross this actor; no SwiftData objects reach views.
public actor SwiftDataWorkspaceStore: WorkspaceStore {
    private let container: ModelContainer
    private let sessionHistoryDirectory: URL
    private var context: ModelContext?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sessionHistoryDirectory = url.appendingPathExtension("session-history")
        let schema = Schema(versionedSchema: WorkspaceSchemaV1.self)
        let config = ModelConfiguration("Pikachu", schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
    }
    private func modelContext() -> ModelContext {
        if let context { return context }
        let created = ModelContext(container); created.autosaveEnabled = false; context = created; return created
    }
    public func load() throws -> WorkspaceSnapshot {
        let values = try modelContext().fetch(FetchDescriptor<WorkspaceSchemaV1.Library>())
        guard values.count <= 1 else { throw RuntimeStorageError.invalid }
        guard let value = values.first else { return .init() }
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: value.payload)
        guard snapshot.version == 1, snapshot.revision == value.revision else { throw RuntimeStorageError.invalid }
        return snapshot
    }
    public func save(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.version == 1 else { throw RuntimeStorageError.invalid }
        let context = modelContext()
        do {
            let payload = try JSONEncoder().encode(snapshot)
            let existing = try context.fetch(FetchDescriptor<WorkspaceSchemaV1.Library>())
            guard existing.count <= 1 else { throw RuntimeStorageError.invalid }
            if let record = existing.first {
                // A delayed autosave must not replace a newer durable checkpoint.
                guard snapshot.revision > record.revision else { return }
                record.payload = payload; record.revision = snapshot.revision
            } else { context.insert(WorkspaceSchemaV1.Library(revision: snapshot.revision, payload: payload)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }

    public func saveSessionHistory(_ history: SessionHistorySnapshot, segmentID: UUID) async throws {
        try FileManager.default.createDirectory(at: sessionHistoryDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(history)
        try data.write(to: sessionHistoryURL(segmentID), options: .atomic)
    }

    public func loadSessionHistory(segmentID: UUID) async throws -> SessionHistorySnapshot {
        let data = try Data(contentsOf: sessionHistoryURL(segmentID))
        return try JSONDecoder().decode(SessionHistorySnapshot.self, from: data)
    }

    public func pruneSessionHistory(retaining segmentIDs: Set<UUID>) async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessionHistoryDirectory.path) else { return }
        let entries = try manager.contentsOfDirectory(at: sessionHistoryDirectory, includingPropertiesForKeys: nil)
        for entry in entries where entry.pathExtension == "json" {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                  !segmentIDs.contains(id) else { continue }
            try manager.removeItem(at: entry)
        }
    }

    public func removeSessionHistory(segmentIDs: Set<UUID>) async throws {
        for id in segmentIDs {
            do { try FileManager.default.removeItem(at: sessionHistoryURL(id)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
        }
    }

    private func sessionHistoryURL(_ id: UUID) -> URL {
        sessionHistoryDirectory.appendingPathComponent(id.uuidString, isDirectory: false).appendingPathExtension("json")
    }
}
private enum RuntimeStorageError: Error { case invalid }
