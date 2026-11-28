import Foundation
import Darwin
import CProcessInspection

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let parent: Int32
    public let seconds: UInt64
    public let microseconds: UInt64
    public let status: UInt32
    public static func read(_ pid: Int32) -> ProcessIdentity? {
        var value = zv_process_identity()
        guard zv_process_identity_for(pid, &value) == 0, value.uid == getuid() || value.status == 5 else { return nil }
        return .init(pid: pid, parent: value.ppid, seconds: value.seconds,
                     microseconds: value.microseconds, status: value.status)
    }
    public func sameProcess(as other: ProcessIdentity) -> Bool {
        pid == other.pid && seconds == other.seconds && microseconds == other.microseconds
    }
    public var live: Bool { status != 5 } // SZOMB: no execution remains, may await reaping.
    public func signal(_ value: Int32) -> Bool {
        guard let now = Self.read(pid), sameProcess(as: now), now.live else { return false }
        return kill(pid, value) == 0
    }
    public static func snapshot() throws -> [ProcessIdentity] {
        var pids = [Int32](repeating: 0, count: 32768)
        let count = zv_list_pids(&pids, Int32(pids.count))
        guard count > 0, count < pids.count else { throw ProbeError.failure("Process enumeration unavailable or overflowed") }
        return pids.prefix(Int(count)).filter { $0 > 0 }.compactMap(Self.read)
    }
    public static func marked(_ identities: [ProcessIdentity], token: String) throws -> [ProcessIdentity] {
        guard let scan = token.withCString({ zv_marker_scan_create($0) }) else {
            throw ProbeError.failure("Cannot initialize process marker scan")
        }
        defer { zv_marker_scan_destroy(scan) }
        return identities.filter { zv_marker_scan_matches(scan, $0.pid) == 1 }
    }
}
