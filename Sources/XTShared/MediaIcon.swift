import Foundation
import DiskArbitration

/// The icon macOS itself uses for a disk (yellow USB drive, internal disk,
/// SD card...), as named by the storage driver in the disk's
/// DiskArbitration description. Used for the volume icon of XT mounts, so
/// Finder shows the same icon as for any other disk, and by the app.
public enum MediaIcon {
    private static let lock = NSLock()
    private static var bundleDirs: [String: String] = [:]
    private static var scanned = false

    private static let extensionDirs = ["/System/Library/Extensions", "/Library/Extensions",
                                        "/System/Library/DriverExtensions", "/Library/DriverExtensions"]

    /// Path of the .icns file for a disk description, nil if unknown.
    public static func path(description d: [String: Any]) -> String? {
        if let icon = d[kDADiskDescriptionMediaIconKey as String] as? [String: Any],
           let bundle = icon["CFBundleIdentifier"] as? String,
           let file = icon["IOBundleResourceFile"] as? String,
           let dir = bundleDirectory(bundle) {
            let p = dir + "/Contents/Resources/" + file
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return fallback(internal: (d[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false,
                        removable: (d[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false)
    }

    /// The generic storage icons that ship with macOS.
    public static func fallback(internal: Bool, removable: Bool) -> String? {
        let base = "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/"
        let names = internal ? ["Internal.icns"] : removable ? ["Removable.icns", "External.icns"] : ["External.icns"]
        for n in names where FileManager.default.fileExists(atPath: base + n) { return base + n }
        return nil
    }

    /// Directory of the kernel extension (or driver) with a bundle id.
    private static func bundleDirectory(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let d = bundleDirs[id] { return d }
        if id == "com.apple.iokit.IOStorageFamily" {
            let d = "/System/Library/Extensions/IOStorageFamily.kext"
            if FileManager.default.fileExists(atPath: d) {
                bundleDirs[id] = d
                return d
            }
        }
        if !scanned {
            scanned = true
            let fm = FileManager.default
            for root in extensionDirs {
                guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for n in names where n.hasSuffix(".kext") || n.hasSuffix(".dext") {
                    record(root + "/" + n)
                    // Drivers nested inside a family kext.
                    let plugins = root + "/" + n + "/Contents/PlugIns"
                    for p in (try? fm.contentsOfDirectory(atPath: plugins)) ?? [] where p.hasSuffix(".kext") {
                        record(plugins + "/" + p)
                    }
                }
            }
        }
        return bundleDirs[id]
    }

    private static func record(_ dir: String) {
        guard let info = NSDictionary(contentsOfFile: dir + "/Contents/Info.plist"),
              let id = info["CFBundleIdentifier"] as? String,
              bundleDirs[id] == nil else { return }
        bundleDirs[id] = dir
    }
}
