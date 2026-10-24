import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One entry of the kernel mount table (getmntinfo).
public struct MountEntry: Equatable, Sendable {
    public var from: String
    public var on: String
    public var fsType: String
    public var readOnly: Bool
    public var noBrowse: Bool
    public var totalBytes: Int64
    public var freeBytes: Int64

    /// BSD name of the device ("disk4s1") for /dev/diskXsY or /dev/rdiskXsY.
    public var bsdName: String? {
        if from.hasPrefix("/dev/rdisk") { return String(from.dropFirst(6)) }
        if from.hasPrefix("/dev/disk") { return String(from.dropFirst(5)) }
        return nil
    }

    /// Mounted by the XT engine (ntfs-3g on macFUSE).
    public var isXT: Bool {
        (fsType == "macfuse" || fsType == "osxfuse") && bsdName != nil
    }

    /// Human-readable name of the driver that owns this mount.
    public var driverName: String {
        switch fsType {
        case "macfuse", "osxfuse": return bsdName != nil ? "XT NTFS" : "macFUSE"
        case "ufsd_NTFS": return "Paragon NTFS"
        case "tuxera_ntfs": return "Tuxera NTFS"
        case "ntfs": return "macOS (read-only)"
        default: return fsType
        }
    }
}

public enum MountTable {
    private static func string<T>(_ tuple: inout T, capacity: Int) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    public static func entries() -> [MountEntry] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var out: [MountEntry] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            var s = buf[i]
            let from = string(&s.f_mntfromname, capacity: Int(MAXPATHLEN))
            let on = string(&s.f_mntonname, capacity: Int(MAXPATHLEN))
            let type = string(&s.f_fstypename, capacity: Int(MFSTYPENAMELEN))
            let flags = UInt64(s.f_flags)
            let bsize = Int64(s.f_bsize)
            out.append(MountEntry(
                from: from, on: on, fsType: type,
                readOnly: flags & UInt64(MNT_RDONLY) != 0,
                noBrowse: flags & UInt64(MNT_DONTBROWSE) != 0,
                totalBytes: Int64(s.f_blocks) * bsize,
                freeBytes: Int64(s.f_bavail) * bsize))
        }
        return out
    }

    public static func entries(forBSD bsd: String) -> [MountEntry] {
        entries().filter { $0.bsdName == bsd }
    }

    public static func entry(at path: String) -> MountEntry? {
        entries().first { $0.on == path }
    }

    /// Live usage numbers for a mount point.
    public static func usage(of path: String) -> (total: Int64, free: Int64)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let b = Int64(s.f_bsize)
        return (Int64(s.f_blocks) * b, Int64(s.f_bavail) * b)
    }
}
