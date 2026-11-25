import Foundation

enum PikachuReleaseCheck {
    private static let endpoint = URL(string: "https://api.github.com/repos/yuzio-ai/pikachu/releases/latest")!
    static let releasePage = URL(string: "https://github.com/yuzio-ai/pikachu/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func newerVersion(tag: String, installed: String) -> String? {
        func components(_ value: String) -> (String, [Int])? {
            let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            let numbers = parts.compactMap { part in
                part.utf8.allSatisfy { (48...57).contains($0) } ? Int(part) : nil
            }
            guard numbers.count == parts.count else { return nil }
            return (version, numbers + Array(repeating: 0, count: 3 - numbers.count))
        }
        guard let (version, candidate) = components(tag), let (_, current) = components(installed),
              current.lexicographicallyPrecedes(candidate) else { return nil }
        return version
    }

    static func latestVersion(installed: String) async throws -> String? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil } // No public stable release yet.
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return newerVersion(tag: release.tag_name, installed: installed)
    }
}
