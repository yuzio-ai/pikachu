import Foundation

public enum TranscriptFileLinks {
    public static func enrich(_ blocks: [MarkdownBlock], workspaceDirectory: URL?) -> [MarkdownBlock] {
        enrich(blocks, workspaceDirectory: workspaceDirectory) { FileManager.default.fileExists(atPath: $0) }
    }

    public static func enrich(
        _ blocks: [MarkdownBlock],
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> [MarkdownBlock] {
        var cache: [String: URL?] = [:]
        return enrich(blocks, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists)
    }

    public static func enrich(_ text: AttributedString, workspaceDirectory: URL?) -> AttributedString {
        var cache: [String: URL?] = [:]
        return enrich(text, workspaceDirectory: workspaceDirectory, cache: &cache) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    public static func openableFileURL(for url: URL, workspaceDirectory: URL?) -> URL? {
        openableFileURL(for: url, workspaceDirectory: workspaceDirectory) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    public static func openableFileURL(
        for url: URL,
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> URL? {
        if url.isFileURL {
            return existingFileURL(forRawPath: url.path, fileExists: fileExists)
        }
        guard url.scheme == nil, let workspaceDirectory else { return nil }
        return openableFileURL(forRelativePath: decodedRelativePath(from: url),
                               workspaceDirectory: workspaceDirectory,
                               fileExists: fileExists)
    }

    public static func openableFileURL(forRelativePath path: String, workspaceDirectory: URL?) -> URL? {
        openableFileURL(forRelativePath: path, workspaceDirectory: workspaceDirectory) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    public static func openableFileURL(
        forRelativePath path: String,
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> URL? {
        guard let workspaceDirectory else { return nil }
        let (basePath, _) = splitLineReference(path)
        guard !basePath.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: basePath, relativeTo: workspaceDirectory).standardizedFileURL
        return fileExists(resolved.path) ? resolved : nil
    }

    private static func enrich(
        _ blocks: [MarkdownBlock],
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> [MarkdownBlock] {
        blocks.map { block in
            switch block.kind {
            case .paragraph, .heading:
                return MarkdownBlock(
                    id: block.id,
                    sourceOffset: block.sourceOffset,
                    kind: block.kind,
                    content: enrich(block.content, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists)
                )
            case .list(let ordered, let items):
                let enrichedItems = items.map { item in
                    MarkdownListItem(
                        id: item.id,
                        sourceOffset: item.sourceOffset,
                        ordinal: item.ordinal,
                        blocks: enrich(item.blocks, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists),
                        taskChecked: item.taskChecked
                    )
                }
                return MarkdownBlock(id: block.id, sourceOffset: block.sourceOffset, kind: .list(ordered: ordered, items: enrichedItems),
                                     content: block.content, isLooseList: block.isLooseList)
            case .table(let table):
                let enrichedRows = table.rows.map { row in
                    MarkdownTable.Row(
                        id: row.id,
                        sourceOffset: row.sourceOffset,
                        isHeader: row.isHeader,
                        cells: row.cells.map { enrich($0, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists) }
                    )
                }
                return MarkdownBlock(
                    id: block.id,
                    sourceOffset: block.sourceOffset,
                    kind: .table(.init(columns: table.columns, rows: enrichedRows)),
                    content: block.content
                )
            case .quote(let children):
                return MarkdownBlock(
                    id: block.id,
                    sourceOffset: block.sourceOffset,
                    kind: .quote(enrich(children, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists)),
                    content: block.content
                )
            case .code, .divider:
                return block
            }
        }
    }

    private static func enrich(
        _ text: AttributedString,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            let slice = text[run.range]
            if let existingLink = run.link {
                var span = AttributedString(slice)
                if existingLink.scheme == nil,
                   let resolved = resolvedLinkURL(forRawReference: decodedRelativePath(from: existingLink),
                                                  fragment: existingLink.fragment,
                                                  workspaceDirectory: workspaceDirectory,
                                                  cache: &cache,
                                                  fileExists: fileExists) {
                    span.link = resolved
                }
                result.append(span)
                continue
            }

            if run.inlinePresentationIntent?.contains(.code) == true {
                result.append(enrichInlineCode(slice, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists))
                continue
            }

            result.append(enrichPlainText(slice, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists))
        }
        return result
    }

    private static func enrichInlineCode(
        _ slice: AttributedSubstring,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> AttributedString {
        let raw = String(slice.characters)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = resolvedLinkURL(forCandidate: trimmed, workspaceDirectory: workspaceDirectory,
                                             cache: &cache, fileExists: fileExists) else {
            return AttributedString(slice)
        }
        if trimmed == raw {
            var span = AttributedString(slice)
            span.link = resolved
            return span
        }
        guard let range = raw.range(of: trimmed),
              let attrRange = slice.range(of: trimmed) else {
            return AttributedString(slice)
        }
        var output = AttributedString()
        if range.lowerBound > raw.startIndex {
            output.append(AttributedString(slice[slice.startIndex..<attrRange.lowerBound]))
        }
        var linked = AttributedString(slice[attrRange])
        linked.link = resolved
        output.append(linked)
        if range.upperBound < raw.endIndex {
            output.append(AttributedString(slice[attrRange.upperBound..<slice.endIndex]))
        }
        return output
    }

    private static func enrichPlainText(
        _ slice: AttributedSubstring,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> AttributedString {
        let string = String(slice.characters)
        let matches = linkMatches(in: string, workspaceDirectory: workspaceDirectory, cache: &cache, fileExists: fileExists)
        guard !matches.isEmpty else { return AttributedString(slice) }

        var output = AttributedString()
        var stringCursor = string.startIndex
        var attrCursor = slice.startIndex
        for match in matches {
            if stringCursor < match.range.lowerBound {
                let gap = string.distance(from: stringCursor, to: match.range.lowerBound)
                let nextAttr = slice.characters.index(attrCursor, offsetBy: gap)
                output.append(AttributedString(slice[attrCursor..<nextAttr]))
                attrCursor = nextAttr
                stringCursor = match.range.lowerBound
            }
            let length = string.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let matchEnd = slice.characters.index(attrCursor, offsetBy: length)
            var linked = AttributedString(slice[attrCursor..<matchEnd])
            linked.link = match.url
            output.append(linked)
            attrCursor = matchEnd
            stringCursor = match.range.upperBound
        }
        if stringCursor < string.endIndex {
            output.append(AttributedString(slice[attrCursor..<slice.endIndex]))
        }
        return output
    }

    private struct PathMatch {
        let range: Range<String.Index>
        let url: URL
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"[^\s()<>\[\]{}"'`，。、；：！？（）【】「」《》“”]+"#
    )

    private static let asciiPathRegex = try! NSRegularExpression(
        pattern: #"(?:file://[A-Za-z0-9._~/%+-]+|(?:~/|/|\./|\.\./)?[A-Za-z0-9._~+-]+(?:/[A-Za-z0-9._~+-]+)+/?|[A-Za-z0-9._+-]+\.[A-Za-z0-9]{1,16})(?::\d+(?::\d+)?)?(?:#L\d+(?:-L\d+)?)?"#
    )

    private static func linkMatches(
        in string: String,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> [PathMatch] {
        let fullRange = NSRange(string.startIndex..<string.endIndex, in: string)
        var results: [PathMatch] = []

        for match in tokenRegex.matches(in: string, range: fullRange) {
            guard let tokenRange = Range(match.range, in: string) else { continue }
            let token = String(string[tokenRange])

            if let cleaned = cleanToken(token, in: string, range: tokenRange) {
                if cleaned.text.contains("://") && !cleaned.text.hasPrefix("file://") { continue }
                if let url = resolvedLinkURL(forCandidate: cleaned.text, workspaceDirectory: workspaceDirectory,
                                             cache: &cache, fileExists: fileExists) {
                    results.append(.init(range: cleaned.range, url: url))
                    continue
                }
            }

            // Handle CJK prose attached directly to an ASCII path (e.g. "在Zivvi/App/AppSettings.swift中").
            let nsTokenRange = NSRange(tokenRange, in: string)
            for sub in asciiPathRegex.matches(in: string, range: nsTokenRange) {
                guard let subRange = Range(sub.range, in: string) else { continue }
                if let last = results.last, last.range.overlaps(subRange) { continue }
                let candidate = trimTrailingSentencePunctuation(String(string[subRange]), in: string, range: subRange)
                if let url = resolvedLinkURL(forCandidate: candidate.text, workspaceDirectory: workspaceDirectory,
                                             cache: &cache, fileExists: fileExists) {
                    results.append(.init(range: candidate.range, url: url))
                }
            }
        }
        return results
    }

    private static func cleanToken(
        _ token: String,
        in source: String,
        range: Range<String.Index>
    ) -> (text: String, range: Range<String.Index>)? {
        let trimmed = trimTrailingSentencePunctuation(token, in: source, range: range)
        guard !trimmed.text.isEmpty else { return nil }
        return trimmed
    }

    private static func trimTrailingSentencePunctuation(
        _ text: String,
        in source: String,
        range: Range<String.Index>
    ) -> (text: String, range: Range<String.Index>) {
        let trailingPunctuation: Set<Character> = [":", ",", ".", ";", "!", "?"]
        let lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let prev = source.index(before: upper)
            if trailingPunctuation.contains(source[prev]) {
                upper = prev
            } else {
                break
            }
        }
        return (String(source[lower..<upper]), lower..<upper)
    }

    private static func resolvedLinkURL(
        forCandidate candidate: String,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> URL? {
        if let cached = cache[candidate] {
            return cached
        }
        let resolved = computeResolvedLinkURL(forCandidate: candidate, workspaceDirectory: workspaceDirectory, fileExists: fileExists)
        cache[candidate] = resolved
        return resolved
    }

    private static func computeResolvedLinkURL(
        forCandidate candidate: String,
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> URL? {
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("file://") {
            guard let url = URL(string: candidate), url.isFileURL else { return nil }
            guard let existing = existingFileURL(forRawPath: url.path, fileExists: fileExists) else { return nil }
            return appendingFragment(url.fragment, to: existing)
        }

        // Ignore web or custom URI schemes (https://, mailto:, etc.).
        if candidate.contains("://") { return nil }

        let (withoutFragment, explicitFragment) = splitFragment(candidate)
        let (basePath, lineNumber) = splitLineReference(withoutFragment)
        guard looksLikePath(basePath) else { return nil }

        let fragment = explicitFragment ?? lineNumber.map { "L\($0)" }
        return resolvedLinkURL(forRawReference: basePath, fragment: fragment,
                               workspaceDirectory: workspaceDirectory, fileExists: fileExists)
    }

    private static func resolvedLinkURL(
        forRawReference reference: String,
        fragment: String?,
        workspaceDirectory: URL?,
        cache: inout [String: URL?],
        fileExists: (String) -> Bool
    ) -> URL? {
        let key = "\(reference)#\(fragment ?? "")"
        if let cached = cache[key] { return cached }
        let resolved = resolvedLinkURL(forRawReference: reference, fragment: fragment,
                                       workspaceDirectory: workspaceDirectory, fileExists: fileExists)
        cache[key] = resolved
        return resolved
    }

    private static func resolvedLinkURL(
        forRawReference reference: String,
        fragment: String?,
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> URL? {
        let (basePath, lineNumber) = splitLineReference(reference)
        guard !basePath.isEmpty else { return nil }

        let resolved: URL
        if basePath.hasPrefix("~/") {
            resolved = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(basePath.dropFirst(2)))
                .standardizedFileURL
        } else if basePath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: basePath).standardizedFileURL
        } else if let workspaceDirectory {
            resolved = URL(fileURLWithPath: basePath, relativeTo: workspaceDirectory).standardizedFileURL
        } else {
            return nil
        }

        guard fileExists(resolved.path) else { return nil }
        let normalizedFragment = fragment ?? lineNumber.map { "L\($0)" }
        return appendingFragment(normalizedFragment, to: resolved)
    }

    private static func existingFileURL(forRawPath rawPath: String, fileExists: (String) -> Bool) -> URL? {
        let direct = URL(fileURLWithPath: rawPath).standardizedFileURL
        if fileExists(direct.path) {
            return direct
        }
        let (basePath, _) = splitLineReference(rawPath)
        guard basePath != rawPath, !basePath.isEmpty else { return nil }
        let fallback = URL(fileURLWithPath: basePath).standardizedFileURL
        return fileExists(fallback.path) ? fallback : nil
    }

    private static func decodedRelativePath(from url: URL) -> String {
        let raw = url.relativePath.isEmpty ? url.relativeString : url.relativePath
        return raw.removingPercentEncoding ?? raw
    }

    private static func splitFragment(_ text: String) -> (path: String, fragment: String?) {
        guard let hash = text.firstIndex(of: "#") else { return (text, nil) }
        let path = String(text[..<hash])
        let fragment = String(text[text.index(after: hash)...])
        return (path, fragment.isEmpty ? nil : fragment)
    }

    private static let lineSuffixRegex = try! NSRegularExpression(pattern: #":(\d+)(?::\d+)?$"#)

    private static func splitLineReference(_ text: String) -> (path: String, line: String?) {
        let (withoutFragment, _) = splitFragment(text)
        let nsRange = NSRange(withoutFragment.startIndex..<withoutFragment.endIndex, in: withoutFragment)
        guard let match = lineSuffixRegex.firstMatch(in: withoutFragment, range: nsRange),
              let fullRange = Range(match.range, in: withoutFragment),
              let lineRange = Range(match.range(at: 1), in: withoutFragment) else {
            return (withoutFragment, nil)
        }
        return (String(withoutFragment[..<fullRange.lowerBound]), String(withoutFragment[lineRange]))
    }

    private static func looksLikePath(_ path: String) -> Bool {
        guard !path.isEmpty, path != ".", path != ".." else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") {
            return path.count > 1
        }
        if path.contains("/") {
            return true
        }
        guard let dot = path.lastIndex(of: "."), dot > path.startIndex else { return false }
        let ext = path[path.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 16 && ext.allSatisfy(\.isASCII) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func appendingFragment(_ fragment: String?, to fileURL: URL) -> URL {
        guard let fragment, !fragment.isEmpty,
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        components.fragment = fragment
        return components.url ?? fileURL
    }
}
