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

/// One atomic, versioned metadata document. Conversation text remains in Pi files.
/// Only neutral Codable values cross this actor; no SwiftData objects reach views.
public actor SwiftDataWorkspaceStore: WorkspaceStore {
    private let container: ModelContainer
    private var context: ModelContext?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
}
private enum RuntimeStorageError: Error { case invalid }
