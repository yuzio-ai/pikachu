public struct TurnFileChanges: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case added, modified, deleted, renamed }

        public let path: String
        public let previousPath: String?
        public let kind: Kind
        public let added: Int?
        public let deleted: Int?
        public var id: String { path }

        public init(path: String, previousPath: String? = nil, kind: Kind, added: Int?, deleted: Int?) {
            self.path = path
            self.previousPath = previousPath
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
