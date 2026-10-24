import Foundation
import XTShared

/// A volume shown in the sidebar.
struct Volume: Identifiable, Equatable {
    var id: String { bsdName }
    var bsdName: String
    var name: String
    var mediaSize: Int64
    var fsKind: String            // DiskArbitration kind ("ntfs", "apfs", ...)
    var isNTFS: Bool
    var uuid: String?
    var mountPoint: String?
    var mountFSType: String?      // getmntinfo type of the active mount
    var readOnly: Bool
    var noBrowse: Bool
    var mountedByXT: Bool
    var isInternal: Bool
    var isEjectable: Bool
    var isWholeDisk: Bool
    var mediaName: String?
    var deviceProtocol: String?
    var totalBytes: Int64?
    var freeBytes: Int64?
    var operatingSystem: String?
    /// USB link speed in bits per second (nil if not USB or unknown).
    var linkSpeed: Int64? = nil

    var isMounted: Bool { mountPoint != nil }
    var devicePath: String { "/dev/" + bsdName }
    var wholeDisk: String { NTFSNames.wholeDisk(of: bsdName) }
    var prefsKey: String { NTFSNames.prefsKey(uuid: uuid, bsdName: bsdName, label: name) }
    var isRootVolume: Bool { mountPoint == "/" }

    var fileSystemName: String {
        if isNTFS { return "NTFS" }
        switch fsKind.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "ExFAT"
        case "msdos": return "FAT32"
        case "udf": return "UDF"
        case "cd9660": return "ISO 9660"
        case "": return NSLocalizedString("Unknown", comment: "")
        default: return fsKind.uppercased()
        }
    }

    var driverName: String? {
        guard let t = mountFSType else { return nil }
        if mountedByXT { return "XT NTFS" }
        return MountEntry(from: devicePath, on: mountPoint ?? "", fsType: t, readOnly: readOnly,
                          noBrowse: noBrowse, totalBytes: 0, freeBytes: 0).driverName
    }

    var usedBytes: Int64? {
        guard let t = totalBytes, let f = freeBytes else { return nil }
        return max(0, t - f)
    }

    /// Size shown under the name (capacity of the file system when mounted).
    var displaySize: Int64 { totalBytes ?? mediaSize }

    enum Status { case readWrite, readOnly, unmounted }
    var status: Status {
        guard isMounted else { return .unmounted }
        return readOnly ? .readOnly : .readWrite
    }

    var canErase: Bool {
        if isRootVolume || fsKind.lowercased() == "apfs" { return false }
        if isInternal && !isNTFS { return false }
        return !isWholeDisk || isNTFS
    }

    var canVerify: Bool { isNTFS || ["hfs", "apfs", "exfat", "msdos"].contains(fsKind.lowercased()) }
    var canUnmount: Bool { isMounted && !isRootVolume && !(mountPoint ?? "").hasPrefix("/System/") }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ v: Int64) -> String { bytes.string(fromByteCount: v) }

    static func rate(_ mbps: Double) -> String {
        mbps >= 100 ? String(format: "%.0f MB/s", mbps) : String(format: "%.1f MB/s", mbps)
    }
}
