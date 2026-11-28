import Darwin
import Foundation

final class WorkspaceLaunchLock {
    enum Acquisition {
        case acquired(WorkspaceLaunchLock)
        case heldBy(pid_t)
    }

    let storeURL: URL
    private let descriptor: Int32

    private init(storeURL: URL, descriptor: Int32) {
        self.storeURL = storeURL
        self.descriptor = descriptor
    }

    deinit {
        // Keep the sidecar in place so every launcher locks the same inode.
        close(descriptor)
    }

    static func acquire(for configuredURL: URL) throws -> Acquisition {
        let directory = configuredURL.deletingLastPathComponent().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let storeURL = directory.appendingPathComponent(configuredURL.lastPathComponent).resolvingSymlinksInPath()
        try checkStorePath(storeURL)

        let lockURL = storeURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw systemError }
        var keepDescriptor = false
        defer { if !keepDescriptor { close(descriptor) } }

        var file = stat()
        guard fstat(descriptor, &file) == 0 else { throw systemError }
        guard (file.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }

        // A record lock lets the kernel identify the owner even during concurrent startup.
        // Open this sidecar only once per process, since closing any descriptor releases its locks.
        for _ in 0..<2 {
            var request = flock()
            request.l_type = Int16(F_WRLCK)
            request.l_whence = Int16(SEEK_SET)
            if setOrQueryLock(F_SETLK, descriptor, &request) == 0 {
                keepDescriptor = true
                return .acquired(WorkspaceLaunchLock(storeURL: storeURL, descriptor: descriptor))
            }
            guard errno == EAGAIN || errno == EACCES else { throw systemError }
            guard setOrQueryLock(F_GETLK, descriptor, &request) == 0 else { throw systemError }
            if request.l_type != F_UNLCK, request.l_pid > 0 {
                return .heldBy(request.l_pid)
            }
            // The previous owner can exit between F_SETLK and F_GETLK.
        }
        throw POSIXError(.EAGAIN)
    }

    private static func checkStorePath(_ url: URL) throws {
        var file = stat()
        if lstat(url.path, &file) == 0 {
            // Reject unresolved links, including dangling links, before opening the database.
            guard (file.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }
        } else if errno != ENOENT {
            throw systemError
        }
    }

    private static func setOrQueryLock(_ command: Int32, _ descriptor: Int32, _ request: inout flock) -> Int32 {
        withUnsafeMutablePointer(to: &request) { fcntl(descriptor, command, UnsafeMutableRawPointer($0)) }
    }

    private static var systemError: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
