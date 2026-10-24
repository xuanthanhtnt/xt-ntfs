import Foundation

/// Fixed names and locations shared by the app, the helper and the
/// install scripts. Keep in sync with Resources/scripts/*.sh.
public enum XTPaths {
    public static let helperLabel = "com.xuanthanhtnt.xtntfs.helper"
    public static let socketPath = "/var/run/com.xuanthanhtnt.xtntfs.sock"
    public static let supportDir = "/Library/Application Support/XTNTFS"
    public static let engineDir = supportDir + "/engine"
    public static let configPath = supportDir + "/config.json"
    public static let volumeIconPath = supportDir + "/VolumeIcon.icns"
    public static let helperBinary = "/Library/PrivilegedHelperTools/" + helperLabel
    public static let launchDaemonPlist = "/Library/LaunchDaemons/" + helperLabel + ".plist"
    public static let logPath = "/Library/Logs/XTNTFS.log"

    public static let macFUSEBundle = "/Library/Filesystems/macfuse.fs"
    public static let macFUSELibrary = "/usr/local/lib/libfuse.2.dylib"

    public static let repository = "xuanthanhtnt/xt-ntfs"
    public static let homepage = URL(string: "https://xuanthanhtnt.github.io/xt-ntfs/")!
    public static let releasesPage = URL(string: "https://github.com/xuanthanhtnt/xt-ntfs/releases")!
    public static let macFUSEDownload = URL(string: "https://macfuse.github.io/")!
    public static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// Version of the app/helper wire protocol. Bump on incompatible changes.
public let XTProtocolVersion = 1

// MARK: - Engine configuration

public enum DirtyVolumePolicy: String, Codable, CaseIterable, Sendable {
    /// Run a consistency check first and mount only if it passes.
    case verifyBeforeMount
    /// Let ntfs-3g replay/reset the journal and mount read-write.
    case mountAnyway
    /// Mount read-only and leave the volume untouched.
    case mountReadOnly
}

public enum HibernatedPolicy: String, Codable, CaseIterable, Sendable {
    /// Mount read-only and let the user decide from the app.
    case ask
    /// Always mount read-only.
    case mountReadOnly
    /// Delete the hibernation data and mount read-write (Windows loses the
    /// hibernated session).
    case removeHibernation
}

public enum PerformanceProfile: String, Codable, CaseIterable, Sendable {
    /// Block device, stock ntfs-3g behaviour. Slowest, most conservative.
    case compatible
    /// Raw device + XT cache, 1 MiB transfers, macOS metadata kept.
    case balanced
    /// Raw device + bigger cache, 8 MiB transfers, no com.apple xattrs.
    case turbo
}

/// Which macFUSE backend serves XT mounts.
public enum FUSEBackend: String, Codable, CaseIterable, Sendable {
    /// Kernel extension when it can be loaded, otherwise FSKit (macOS 15.4+
    /// with macFUSE 5 or later).
    case automatic
    /// macFUSE kernel extension (VFS): fastest; on Apple silicon it needs
    /// kernel extensions allowed in Startup Security Utility.
    case kernel
    /// macFUSE FSKit backend: runs in user space with no kernel extension,
    /// slower than the kernel backend.
    case fskit
}

/// Per-volume preferences, keyed by volume UUID (or BSD name + label when
/// the volume has no UUID).
public struct VolumePrefs: Codable, Equatable, Sendable {
    public var readOnly: Bool
    public var noAutoMount: Bool
    public var spotlight: Bool
    /// Update last-access times on reads (off by default: every read would
    /// otherwise turn into a metadata write).
    public var saveAccessTime: Bool

    public init(readOnly: Bool = false, noAutoMount: Bool = false, spotlight: Bool = false,
                saveAccessTime: Bool = false) {
        self.readOnly = readOnly
        self.noAutoMount = noAutoMount
        self.spotlight = spotlight
        self.saveAccessTime = saveAccessTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        noAutoMount = try c.decodeIfPresent(Bool.self, forKey: .noAutoMount) ?? false
        spotlight = try c.decodeIfPresent(Bool.self, forKey: .spotlight) ?? false
        saveAccessTime = try c.decodeIfPresent(Bool.self, forKey: .saveAccessTime) ?? false
    }
}

public struct EngineConfig: Codable, Equatable, Sendable {
    public var driverEnabled: Bool
    public var dirtyPolicy: DirtyVolumePolicy
    public var hibernatedPolicy: HibernatedPolicy
    public var profile: PerformanceProfile
    public var windowsNames: Bool
    public var backend: FUSEBackend
    public var volumes: [String: VolumePrefs]

    public init(driverEnabled: Bool = true,
                dirtyPolicy: DirtyVolumePolicy = .verifyBeforeMount,
                hibernatedPolicy: HibernatedPolicy = .ask,
                profile: PerformanceProfile = .balanced,
                windowsNames: Bool = true,
                backend: FUSEBackend = .automatic,
                volumes: [String: VolumePrefs] = [:]) {
        self.driverEnabled = driverEnabled
        self.dirtyPolicy = dirtyPolicy
        self.hibernatedPolicy = hibernatedPolicy
        self.profile = profile
        self.windowsNames = windowsNames
        self.backend = backend
        self.volumes = volumes
    }

    // Tolerate missing keys so older config files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driverEnabled = try c.decodeIfPresent(Bool.self, forKey: .driverEnabled) ?? true
        dirtyPolicy = (try? c.decodeIfPresent(DirtyVolumePolicy.self, forKey: .dirtyPolicy)) ?? .verifyBeforeMount
        hibernatedPolicy = (try? c.decodeIfPresent(HibernatedPolicy.self, forKey: .hibernatedPolicy)) ?? .ask
        profile = (try? c.decodeIfPresent(PerformanceProfile.self, forKey: .profile)) ?? .balanced
        windowsNames = try c.decodeIfPresent(Bool.self, forKey: .windowsNames) ?? true
        backend = (try? c.decodeIfPresent(FUSEBackend.self, forKey: .backend)) ?? .automatic
        volumes = try c.decodeIfPresent([String: VolumePrefs].self, forKey: .volumes) ?? [:]
    }

    public func prefs(forKey key: String) -> VolumePrefs {
        volumes[key] ?? VolumePrefs()
    }
}

// MARK: - Status

public struct ManagedMount: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String
    public var devicePath: String
    public var mountPoint: String
    public var volumeName: String
    public var readOnly: Bool
    public var profile: PerformanceProfile
    /// Backend actually used (nil for mounts found after a helper restart).
    public var backend: FUSEBackend?
    public var mountedAt: Date

    public init(bsdName: String, devicePath: String, mountPoint: String, volumeName: String,
                readOnly: Bool, profile: PerformanceProfile, backend: FUSEBackend? = nil,
                mountedAt: Date = Date()) {
        self.bsdName = bsdName
        self.devicePath = devicePath
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.readOnly = readOnly
        self.profile = profile
        self.backend = backend
        self.mountedAt = mountedAt
    }
}

public enum HelperEventKind: String, Codable, Sendable {
    case mounted, mountFailed, unmounted, hibernated, dirty, info
}

public struct HelperEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var date: Date
    public var kind: HelperEventKind
    public var bsdName: String?
    public var volumeName: String?
    public var message: String

    public init(id: Int, date: Date = Date(), kind: HelperEventKind, bsdName: String?,
                volumeName: String?, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.message = message
    }
}

public struct HelperStatus: Codable, Sendable {
    public var helperVersion: String
    public var protocolVersion: Int
    public var engineVersion: String
    public var macFUSEInstalled: Bool
    public var macFUSEVersion: String?
    public var config: EngineConfig
    public var mounts: [ManagedMount]
    public var events: [HelperEvent]

    public init(helperVersion: String, protocolVersion: Int, engineVersion: String,
                macFUSEInstalled: Bool, macFUSEVersion: String?, config: EngineConfig,
                mounts: [ManagedMount], events: [HelperEvent]) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.engineVersion = engineVersion
        self.macFUSEInstalled = macFUSEInstalled
        self.macFUSEVersion = macFUSEVersion
        self.config = config
        self.mounts = mounts
        self.events = events
    }
}

// MARK: - Wire protocol

public enum HelperCommand: String, Codable, Sendable {
    case status
    case setConfig
    case setVolumePrefs
    case mount
    case unmount
    case eject
    case verify
    case repair
    case erase
    case rename
    case setSpotlight
    case unmountAll
    case mountWithSystem
    /// Exit; launchd starts the helper again (picks up new permissions).
    case restart
}

public enum EraseFormat: String, Codable, CaseIterable, Sendable {
    case ntfs, exfat, fat32, apfs, hfsplus

    /// diskutil personality name for non-NTFS formats.
    public var diskutilName: String? {
        switch self {
        case .ntfs: return nil
        case .exfat: return "ExFAT"
        case .fat32: return "MS-DOS FAT32"
        case .apfs: return "APFS"
        case .hfsplus: return "JHFS+"
        }
    }
}

public struct HelperRequest: Codable, Sendable {
    public var command: HelperCommand
    public var bsdName: String?
    public var readOnly: Bool?
    public var label: String?
    public var format: EraseFormat?
    public var enabled: Bool?
    public var prefsKey: String?
    public var prefs: VolumePrefs?
    public var config: EngineConfig?
    public var sinceEvent: Int?

    public init(command: HelperCommand, bsdName: String? = nil, readOnly: Bool? = nil,
                label: String? = nil, format: EraseFormat? = nil, enabled: Bool? = nil,
                prefsKey: String? = nil, prefs: VolumePrefs? = nil, config: EngineConfig? = nil,
                sinceEvent: Int? = nil) {
        self.command = command
        self.bsdName = bsdName
        self.readOnly = readOnly
        self.label = label
        self.format = format
        self.enabled = enabled
        self.prefsKey = prefsKey
        self.prefs = prefs
        self.config = config
        self.sinceEvent = sinceEvent
    }
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var output: String?
    public var status: HelperStatus?
    /// Set when an unmount failed because the volume is busy: the processes
    /// using it (may be empty when they could not be determined).
    public var inUse: [String]?

    public init(ok: Bool, error: String? = nil, output: String? = nil, status: HelperStatus? = nil) {
        self.ok = ok
        self.error = error
        self.output = output
        self.status = status
    }
}

public enum XTCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

// MARK: - Helpers

public enum NTFSNames {
    /// A name usable as a mount point component under /Volumes.
    public static func mountName(for label: String?, bsdName: String) -> String {
        var name = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: "\0", with: "")
        if name.isEmpty || name == "." || name == ".." {
            name = "NTFS " + bsdName
        }
        // Keep it a sane length (mount names are limited by MAXPATHLEN).
        if name.utf8.count > 200 {
            name = String(name.prefix(100))
        }
        return name
    }

    /// Key under which per-volume preferences are stored.
    public static func prefsKey(uuid: String?, bsdName: String, label: String?) -> String {
        if let uuid, !uuid.isEmpty { return uuid.uppercased() }
        return "\(bsdName)|\(label ?? "")"
    }

    /// "disk4s1" -> "disk4"
    public static func wholeDisk(of bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let rest = bsdName.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        return "disk" + digits
    }

    /// True for "disk4s1"-style partition names (not snapshots like disk3s1s1).
    public static func isValidBSDName(_ s: String) -> Bool {
        guard s.hasPrefix("disk"), s.count <= 32 else { return false }
        let rest = s.dropFirst(4)
        guard let first = rest.first, first.isASCII, first.isNumber, rest.last?.isNumber == true else { return false }
        return rest.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "s" }
    }
}
