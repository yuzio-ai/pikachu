public struct TurnFileChanges: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case added, modified, deleted, renamed }

        public let path: String
        public let previousPath: String?
        /// Absolute directory recorded by the producer for relative paths in this change.
        public let pathBase: String?
        public let kind: Kind
        public let added: Int?
        public let deleted: Int?
        public var id: String { path }

        public init(path: String, previousPath: String? = nil, pathBase: String? = nil,
                    kind: Kind, added: Int?, deleted: Int?) {
            self.path = path
            self.previousPath = previousPath
            self.pathBase = pathBase
            self.kind = kind
            self.added = added
            self.deleted = deleted
        }
    }

    public let files: [File]

    public init(files: [File]) {
        self.files = files
    }
}
