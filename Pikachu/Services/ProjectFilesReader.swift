import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProjectFilePath: Hashable, Sendable {
    static let root = Self(components: [])

    let components: [String]
    var name: String { components.last ?? "" }
    var relativePath: String { components.joined(separator: "/") }
    var parent: Self { Self(components: Array(components.dropLast())) }

    func appending(_ name: String) -> Self {
        Self(components: components + [name])
    }

    func isWithin(_ directory: Self) -> Bool {
        components.starts(with: directory.components)
    }

    func markdownImagePath(for reference: URL) -> Self? {
        guard let url = URLComponents(url: reference, resolvingAgainstBaseURL: false),
              url.scheme == nil, url.host == nil, url.query == nil, url.fragment == nil,
              !url.percentEncodedPath.isEmpty, !url.percentEncodedPath.hasPrefix("/") else { return nil }
        var result = parent.components
        for part in url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let name = part.removingPercentEncoding else { return nil }
            if name == "." { continue }
            if name == ".." {
                guard !result.isEmpty else { return nil }
                result.removeLast()
            } else {
                guard ProjectFilesReader.validComponent(name) else { return nil }
                result.append(name)
            }
        }
        guard !result.isEmpty else { return nil }
        return Self(components: result)
    }

    static func relativePath(from fileURL: URL, within rootPath: String) -> Self? {
        guard fileURL.isFileURL else { return nil }
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let relativeComponents: ArraySlice<String>
        if fileComponents.count > rootComponents.count, fileComponents.starts(with: rootComponents) {
            relativeComponents = fileComponents.dropFirst(rootComponents.count)
        } else {
            let resolvedRootComponents = rootURL.resolvingSymlinksInPath().pathComponents
            guard fileComponents.count > resolvedRootComponents.count,
                  fileComponents.starts(with: resolvedRootComponents) else { return nil }
            relativeComponents = fileComponents.dropFirst(resolvedRootComponents.count)
        }
        let components = Array(relativeComponents)
        guard !components.isEmpty, components.allSatisfy(ProjectFilesReader.validComponent) else { return nil }
        return Self(components: components)
    }

    static func handoffReference(_ path: String, recordedBase: String? = nil, in directory: URL) throws -> Self {
        guard directory.isFileURL, !path.isEmpty, !path.contains("\0"), !path.contains("://") else {
            throw ProjectFileIssue.handoffPathOutsideDirectory
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let file: URL
        if path.hasPrefix("/") {
            guard !components.contains("..") else { throw ProjectFileIssue.handoffPathOutsideDirectory }
            file = URL(fileURLWithPath: path)
        } else {
            let relative = components.drop(while: { $0 == "." })
            guard !relative.isEmpty, relative.allSatisfy(ProjectFilesReader.validComponent) else {
                throw ProjectFileIssue.handoffPathOutsideDirectory
            }
            guard let recordedBase, recordedBase.hasPrefix("/"), !recordedBase.contains("\0"),
                  !recordedBase.split(separator: "/").contains("..") else {
                throw ProjectFileIssue.handoffPathUnknown
            }
            file = URL(fileURLWithPath: recordedBase, isDirectory: true)
                .appending(path: relative.joined(separator: "/"), directoryHint: .notDirectory)
        }
        guard let relative = relativePath(from: file, within: directory.path) else {
            throw ProjectFileIssue.handoffPathOutsideDirectory
        }
        return relative
    }
}

struct ProjectFileEntry: Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case directory, file, link, other }

    let path: ProjectFilePath
    let kind: Kind
    var id: ProjectFilePath { path }
}

enum ProjectFileIssue: Error, Equatable, Sendable {
    case rootUnavailable, missing, replaced, permission, link, unsupported, tooLarge, unreadable
    case handoffPathUnknown, handoffPathOutsideDirectory

    var message: String {
        switch self {
        case .rootUnavailable: String(localized: "工作目录不可用")
        case .missing: String(localized: "文件或文件夹已移除")
        case .replaced: String(localized: "文件已更换，请刷新预览")
        case .permission: String(localized: "没有读取权限")
        case .link: String(localized: "无法预览符号链接")
        case .unsupported: String(localized: "无法预览此文件格式")
        case .tooLarge: String(localized: "文件超过 512 KiB 的预览上限")
        case .unreadable: String(localized: "读取失败")
        case .handoffPathUnknown: String(localized: "无法确定交接文件的路径基准")
        case .handoffPathOutsideDirectory: String(localized: "无法在项目文件中打开")
        }
    }
}

struct ProjectFilePreview: Sendable {
    let contents: Result<ProjectFileDocument, ProjectFileIssue>
    let openTarget: ProjectFilesReader.OpenTarget
}

protocol ProjectFilesReading: Sendable {
    func bindRoot(at path: String) async throws -> ProjectFilesReader.Root
    func directory(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> [ProjectFileEntry]
    func read(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> ProjectFilePreview
    func readMarkdownImage(at root: ProjectFilesReader.Root, path: ProjectFilePath) async throws -> CGImage
    func validateOpenTarget(_ target: ProjectFilesReader.OpenTarget) async throws
}

/// The actor serializes local I/O off the UI executor.
actor ProjectFilesReader: ProjectFilesReading {
    static let maximumBytes = 512 * 1024
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW

    /// Keep the original directory open for the lifetime of the binding so its identity
    /// cannot be reused after removal.
    final class Root: Sendable {
        fileprivate let path: String
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
        private let descriptor: Int32

        fileprivate init(path: String, descriptor: Int32, metadata: stat) {
            self.path = path
            self.descriptor = descriptor
            device = metadata.st_dev
            inode = metadata.st_ino
        }

        deinit { close(descriptor) }
    }

    /// Pin the file supplied to the preview so its identity cannot be recycled
    /// while it is selected or a launch failure is still pending.
    final class OpenTarget: Sendable {
        let url: URL
        private let root: Root
        private let path: ProjectFilePath
        private let descriptor: Int32
        private let device: dev_t
        private let inode: ino_t

        fileprivate init(root: Root, path: ProjectFilePath, descriptor: Int32, metadata: stat) {
            self.root = root
            self.path = path
            self.descriptor = descriptor
            device = metadata.st_dev
            inode = metadata.st_ino
            url = URL(fileURLWithPath: root.path, isDirectory: true)
                .appending(path: path.relativePath, directoryHint: .notDirectory)
        }

        deinit { close(descriptor) }

        /// Recheck the path immediately before each external dispatch. Launch
        /// Services and editors still control how they resolve the URL afterward.
        fileprivate func validate() throws {
            let (current, metadata) = try ProjectFilesReader.openFile(at: root, path: path)
            defer { close(current) }
            guard metadata.st_dev == device, metadata.st_ino == inode else { throw ProjectFileIssue.replaced }
            try ProjectFilesReader.validate(root)
        }
    }

    func validateOpenTarget(_ target: OpenTarget) throws {
        try Task.checkCancellation()
        try target.validate()
    }

    func bindRoot(at path: String) throws -> Root {
        try Task.checkCancellation()
        let descriptor = open(path, Self.directoryFlags)
        guard descriptor >= 0 else { throw ProjectFileIssue.rootUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            throw ProjectFileIssue.rootUnavailable
        }
        return Root(path: path, descriptor: descriptor, metadata: metadata)
    }

    func directory(at root: Root, path: ProjectFilePath) throws -> [ProjectFileEntry] {
        try Task.checkCancellation()
        let descriptor = try Self.openDirectory(at: root, path: path)
        guard let stream = fdopendir(descriptor) else {
            let error = Self.issue(errno)
            close(descriptor)
            throw error
        }
        defer { closedir(stream) }

        var result: [ProjectFileEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw Self.issue(errno) }
                break
            }
            let type = item.pointee.d_type
            let name = withUnsafeBytes(of: &item.pointee.d_name) { bytes in
                String(validatingCString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard let name, name != ".", name != "..", name != ".git" else { continue }
            let kind: ProjectFileEntry.Kind
            switch Int32(type) {
            case DT_DIR: kind = .directory
            case DT_LNK: kind = .link
            case DT_REG: kind = .file
            case DT_UNKNOWN: kind = (try? Self.kind(of: name, in: descriptor)) ?? .other
            default: kind = .other
            }
            result.append(ProjectFileEntry(path: path.appending(name), kind: kind))
        }
        result.sort { lhs, rhs in
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            let order = lhs.path.name.localizedStandardCompare(rhs.path.name)
            return order == .orderedSame ? lhs.path.name < rhs.path.name : order == .orderedAscending
        }
        try Self.validate(root)
        return result
    }

    func read(at root: Root, path: ProjectFilePath) throws -> ProjectFilePreview {
        try Task.checkCancellation()
        let (descriptor, metadata) = try Self.openFile(at: root, path: path)
        let target = OpenTarget(root: root, path: path, descriptor: descriptor, metadata: metadata)
        let contents: Result<ProjectFileDocument, ProjectFileIssue>
        do {
            let data = try Self.readData(from: descriptor, size: metadata.st_size)
            contents = .success(try Self.decodeText(data))
        } catch let issue as ProjectFileIssue where issue == .tooLarge || issue == .unsupported {
            contents = .failure(issue)
        }
        try Self.validate(root)
        return ProjectFilePreview(contents: contents, openTarget: target)
    }

    func readMarkdownImage(at root: Root, path: ProjectFilePath) throws -> CGImage {
        try Task.checkCancellation()
        let (descriptor, metadata) = try Self.openFile(at: root, path: path)
        defer { close(descriptor) }
        let data = try Self.readData(from: descriptor, size: metadata.st_size)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .gif, .webP].contains(where: { $0.identifier == identifier }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 24_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ProjectFileIssue.unsupported }
        try Self.validate(root)
        return image
    }

    private static func readData(from descriptor: Int32, size: off_t) throws -> Data {
        guard size <= maximumBytes else { throw ProjectFileIssue.tooLarge }

        var data = Data()
        data.reserveCapacity(Int(size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while data.count < Self.maximumBytes {
            try Task.checkCancellation()
            let count = min(buffer.count, Self.maximumBytes - data.count)
            let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            if received == 0 { break }
            if received < 0 {
                if errno == EINTR { continue }
                throw issue(errno)
            }
            data.append(contentsOf: buffer.prefix(received))
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw issue(errno) }
        guard metadata.st_size <= Self.maximumBytes else { throw ProjectFileIssue.tooLarge }
        return data
    }

    private static func decodeText(_ data: Data) throws -> ProjectFileDocument {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: {
            $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13
        }) else { throw ProjectFileIssue.unsupported }
        return ProjectFileDocument(text)
    }

    private static func openFile(at root: Root, path: ProjectFilePath) throws -> (Int32, stat) {
        guard validComponent(path.name) else { throw ProjectFileIssue.unsupported }
        let parent = try openDirectory(at: root, path: path.parent)
        defer { close(parent) }
        switch try kind(of: path.name, in: parent) {
        case .link: throw ProjectFileIssue.link
        case .file: break
        default: throw ProjectFileIssue.unsupported
        }

        let descriptor = openat(parent, path.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw issue(errno) }
        var metadata = stat()
        if fstat(descriptor, &metadata) != 0 {
            let error = issue(errno)
            close(descriptor)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ProjectFileIssue.unsupported
        }
        return (descriptor, metadata)
    }

    private static func openBoundRoot(_ root: Root) throws -> Int32 {
        let descriptor = open(root.path, Self.directoryFlags)
        guard descriptor >= 0 else { throw ProjectFileIssue.rootUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_dev == root.device, metadata.st_ino == root.inode else {
            close(descriptor)
            throw ProjectFileIssue.rootUnavailable
        }
        return descriptor
    }

    private static func validate(_ root: Root) throws {
        try Task.checkCancellation()
        close(try openBoundRoot(root))
    }

    private static func openDirectory(at root: Root, path: ProjectFilePath) throws -> Int32 {
        var descriptor = try openBoundRoot(root)
        do {
            for component in path.components {
                try Task.checkCancellation()
                guard validComponent(component) else { throw ProjectFileIssue.unsupported }
                let next = openat(descriptor, component, Self.directoryFlags)
                if next < 0 {
                    let error = errno
                    if (try? kind(of: component, in: descriptor)) == .link { throw ProjectFileIssue.link }
                    throw issue(error)
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    fileprivate static func validComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && component != ".git"
            && !component.contains("/") && !component.contains("\0")
    }

    private static func kind(of name: String, in parent: Int32) throws -> ProjectFileEntry.Kind {
        var item = stat()
        guard fstatat(parent, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else { throw issue(errno) }
        switch item.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .link
        default: return .other
        }
    }

    private static func issue(_ code: Int32) -> ProjectFileIssue {
        switch code {
        case EACCES, EPERM: .permission
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .link
        default: .unreadable
        }
    }
}

struct ProjectFileDocument: Sendable {
    let id = UUID()
    let text: String
    /// Logical line starts expressed in the UTF-16 offsets used by TextKit.
    let lineStarts: [Int]

    init(_ text: String) {
        self.text = text
        var starts = [0]
        var position = 0
        var previousWasCR = false
        for unit in text.utf16 {
            position += 1
            switch unit {
            case 0x0A where previousWasCR: starts[starts.count - 1] = position
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: starts.append(position)
            default: break
            }
            previousWasCR = unit == 0x0D
        }
        lineStarts = starts
    }

    func line(at character: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= character { low = mid } else { high = mid }
        }
        return low
    }

    func restoredLine(from old: Self, at line: Int) -> Int {
        let fallback = min(line, lineStarts.count - 1)
        if text == old.text { return fallback }
        let previous = old.text as NSString
        let current = text as NSString
        let anchor = old.lineText(at: line, in: previous)
        var bestMatch: (index: Int, context: Int)?
        for index in lineStarts.indices {
            guard lineText(at: index, in: current) == anchor else { continue }
            let matches = [-2, -1, 1, 2].reduce(into: 0) { count, offset in
                guard old.lineStarts.indices.contains(line + offset), lineStarts.indices.contains(index + offset) else { return }
                if old.lineText(at: line + offset, in: previous) == lineText(at: index + offset, in: current) { count += 1 }
            }
            if let bestMatch, bestMatch.context > matches ||
                (bestMatch.context == matches && abs(bestMatch.index - line) <= abs(index - line)) { continue }
            bestMatch = (index, matches)
        }
        return bestMatch?.index ?? fallback
    }

    func hasSameLine(_ index: Int, as old: Self, at oldIndex: Int) -> Bool {
        lineText(at: index, in: text as NSString) == old.lineText(at: oldIndex, in: old.text as NSString)
    }

    private func lineText(at index: Int, in value: NSString) -> String {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : value.length
        return value.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .newlines)
    }
}
