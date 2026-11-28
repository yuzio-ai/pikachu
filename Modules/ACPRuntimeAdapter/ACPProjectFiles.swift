import Darwin
import Foundation

/// Descriptor-relative operations keep the project boundary intact even when a
/// path component is changed to a symbolic link during an operation.
struct ACPProjectFiles: Sendable {
    static let maximumBytes = 4 * 1_024 * 1_024
    let root: String
    private let declaredRoot: String

    init(workspace: URL) {
        declaredRoot = workspace.standardizedFileURL.path
        if let resolved = realpath(declaredRoot, nil) {
            root = String(cString: resolved)
            free(resolved)
        } else {
            root = declaredRoot
        }
    }

    func read(_ path: String, line: Int?, limit: Int?) throws -> String {
        try withParent(path) { directory, name in
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw Failure.fileUnavailable }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= Self.maximumBytes,
                  let data = try handle.read(upToCount: Self.maximumBytes + 1),
                  data.count <= Self.maximumBytes,
                  let content = String(data: data, encoding: .utf8) else {
                if info.st_mode & S_IFMT == S_IFREG, info.st_size == 0 { return "" }
                throw Failure.fileUnavailable
            }
            if limit == 0 { return "" }
            guard line != nil || limit != nil else { return content }
            // Splitting bytes preserves CRLF, the original final newline and blank lines.
            var result = Data()
            var number = 1
            let first = line ?? 1
            var remaining = limit ?? Int.max
            var start = data.startIndex
            for index in data.indices where data[index] == 10 {
                if number >= first && remaining > 0 {
                    result.append(data[start...index])
                    remaining -= 1
                }
                if remaining == 0 { break }
                number += 1
                start = index + 1
            }
            if remaining > 0 && number >= first && start < data.endIndex {
                result.append(data[start...])
            }
            return String(decoding: result, as: UTF8.self)
        }
    }

    func previousTextForWrite(_ path: String) throws -> String? {
        let exists = try withParent(path) { parent, name in
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw Failure.fileUnavailable }
            return false
        }
        return exists ? try read(path, line: nil, limit: nil) : nil
    }

    func requiresConfirmation(_ path: String) throws -> Bool {
        try withParent(path) { parent, name in
            let components = try relativeComponents(path).map { $0.lowercased() }
            let base = name.lowercased()
            let executableNames: Set<String> = ["agents.md", "claude.md", "gemini.md", "makefile",
                "dockerfile", "package.json", "deno.json", "pyproject.toml", "cargo.toml", "package.swift",
                "justfile", "rakefile", "gemfile", "build.gradle", "settings.gradle", "pom.xml", "cmakelists.txt"]
            let executableExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "command", "bat", "ps1",
                "xcconfig", "pbxproj", "xcscheme", "entitlements"]
            var info = stat()
            let status = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)
            if status == 0, info.st_mode & S_IFMT != S_IFREG { throw Failure.fileUnavailable }
            if status != 0, errno != ENOENT { throw Failure.fileUnavailable }
            return components.contains(where: { $0.hasPrefix(".") || ["scripts", "hooks", "skills"].contains($0) })
                || executableNames.contains(base)
                || executableExtensions.contains(URL(fileURLWithPath: base).pathExtension)
                || (status == 0 && info.st_mode & 0o111 != 0)
        }
    }

    func write(_ path: String, content: String, confirmed: Bool) throws {
        guard content.utf8.count <= Self.maximumBytes else { throw Failure.fileUnavailable }
        if !confirmed, try requiresConfirmation(path) { throw Failure.confirmationRequired }
        try withParent(path) { directory, name in
            var info = stat()
            let exists = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            guard exists ? info.st_mode & S_IFMT == S_IFREG : errno == ENOENT else {
                throw Failure.fileUnavailable
            }
            if exists, info.st_mode & 0o111 != 0, !confirmed { throw Failure.confirmationRequired }
            let temp = ".zivvi-acp-\(UUID().uuidString)"
            let fd = openat(directory, temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.fileUnavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer {
                try? handle.close()
                _ = unlinkat(directory, temp, 0)
            }
            try handle.write(contentsOf: Data(content.utf8))
            if exists, fchmod(fd, info.st_mode & 0o777) != 0 { throw Failure.fileUnavailable }
            try handle.close()
            guard isWithinRoot(directory), renameat(directory, temp, directory, name) == 0 else {
                throw Failure.fileUnavailable
            }
        }
    }

    func workingDirectory(_ path: String?) throws -> URL {
        guard let path, path != root, path != declaredRoot else { return URL(fileURLWithPath: root, isDirectory: true) }
        let components = try relativeComponents(path)
        let resolved = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(components.joined(separator: "/"), isDirectory: true)
        var isDirectory: ObjCBool = false
        let resolvedPath = resolved.path
        guard let canonical = realpath(resolvedPath, nil) else { throw Failure.outsideWorkspace }
        defer { free(canonical) }
        guard String(cString: canonical) == resolvedPath,
              FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Failure.outsideWorkspace }
        return resolved
    }

    private func relativeComponents(_ path: String) throws -> [String] {
        let prefixes = [root, declaredRoot].map { $0 == "/" ? "/" : $0 + "/" }
        guard !path.utf8.contains(0), let prefix = prefixes.first(where: { path.hasPrefix($0) }) else {
            throw Failure.outsideWorkspace
        }
        let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            throw Failure.outsideWorkspace
        }
        return components
    }

    private func withParent<T>(_ path: String, _ operation: (Int32, String) throws -> T) throws -> T {
        let components = try relativeComponents(path)
        var current = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Failure.outsideWorkspace }
        defer { close(current) }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.outsideWorkspace }
            close(current)
            current = next
        }
        guard isWithinRoot(current), let name = components.last else { throw Failure.outsideWorkspace }
        return try operation(current, name)
    }

    private func isWithinRoot(_ descriptor: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }
        guard status == 0, let path = buffer.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else { return false }
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    enum Failure: Error {
        case outsideWorkspace, fileUnavailable, confirmationRequired
    }
}
