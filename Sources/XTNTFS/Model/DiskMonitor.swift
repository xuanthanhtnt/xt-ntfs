import Foundation
import DiskArbitration
import XTShared

/// Watches DiskArbitration (as the logged-in user) and turns the disk list
/// into sidebar volumes.
final class DiskMonitor {
    private let session: DASession?
    private var disks: [String: [String: Any]] = [:]
    private var pending: DispatchWorkItem?
    var onChange: (() -> Void)?

    init() {
        session = DASessionCreate(kCFAllocatorDefault)
    }

    func start() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue().update(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx, let name = DADiskGetBSDName(disk) else { return }
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.disks[String(cString: name)] = nil
            me.scheduleChange()
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue().update(disk)
        }, ctx)
    }

    private func update(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk),
              let dict = DADiskCopyDescription(disk) as? [String: Any] else { return }
        disks[String(cString: name)] = dict
        scheduleChange()
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Builds the sidebar list from the current DiskArbitration snapshot and
    /// the mount table. `xtMounts` come from the helper.
    func volumes(xtMounts: [ManagedMount]) -> [Volume] {
        let table = MountTable.entries()
        var result: [Volume] = []

        let hiddenNames: Set<String> = ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware",
                                        "iSCPreboot", "EFI", "Boot OS X", "Apple_Boot"]
        let snapshot = disks

        for (bsd, d) in snapshot {
            guard NTFSNames.isValidBSDName(bsd) else { continue }
            let kind = (d[kDADiskDescriptionVolumeKindKey as String] as? String) ?? ""
            let isWhole = (d[kDADiskDescriptionMediaWholeKey as String] as? Bool) ?? false
            let isLeaf = (d[kDADiskDescriptionMediaLeafKey as String] as? Bool) ?? false
            let mountable = (d[kDADiskDescriptionVolumeMountableKey as String] as? Bool) ?? false
            let content = (d[kDADiskDescriptionMediaContentKey as String] as? String) ?? ""
            let daName = d[kDADiskDescriptionVolumeNameKey as String] as? String
            let entries = table.filter { $0.bsdName == bsd }
            let mount = entries.first(where: { $0.isXT }) ?? entries.first
            let xt = xtMounts.first { $0.bsdName == bsd }

            // Skip partition maps, APFS containers, EFI and similar.
            let hasFS = !kind.isEmpty || mount != nil
            if !hasFS { continue }
            if isWhole && !isLeaf && mount == nil { continue }
            if kind.lowercased() == "msdos", (daName ?? "").uppercased() == "EFI" { continue }
            if content == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" { continue }   // EFI system partition
            if let n = daName, hiddenNames.contains(n) { continue }
            if let on = mount?.on, on.hasPrefix("/System/Volumes/") || on.hasPrefix("/private/var/vm") { continue }
            if mount == nil && !mountable && !kind.lowercased().contains("ntfs") { continue }
            // Unmounted APFS volumes on the internal disk are system roles
            // (the sealed system volume, Preboot, VM, ...).
            let internal = (d[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
            if mount == nil && internal && kind.lowercased() == "apfs" { continue }

            let lowerKind = kind.lowercased()
            let isNTFS = lowerKind.contains("ntfs") || (mount?.isXT ?? false)
                || (lowerKind.isEmpty && content == "Windows_NTFS")

            var uuid: String?
            if let raw = d[kDADiskDescriptionVolumeUUIDKey as String],
               CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() {
                uuid = CFUUIDCreateString(kCFAllocatorDefault, (raw as! CFUUID)) as String?
            }

            var name = daName ?? ""
            if let xt { name = xt.volumeName }
            else if name.isEmpty, let on = mount?.on { name = (on as NSString).lastPathComponent }
            if mount?.on == "/" , name.isEmpty { name = "Macintosh HD" }
            if name.isEmpty { name = bsd }

            var v = Volume(
                bsdName: bsd,
                name: name,
                mediaSize: (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
                fsKind: isNTFS ? "ntfs" : kind,
                isNTFS: isNTFS,
                uuid: uuid,
                mountPoint: mount?.on,
                mountFSType: mount?.fsType,
                readOnly: mount?.readOnly ?? false,
                noBrowse: mount?.noBrowse ?? false,
                mountedByXT: mount?.isXT ?? false,
                isInternal: (d[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false,
                isEjectable: ((d[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false)
                    || ((d[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false)
                    || !((d[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? true),
                isWholeDisk: isWhole,
                mediaName: d[kDADiskDescriptionMediaNameKey as String] as? String,
                deviceProtocol: d[kDADiskDescriptionDeviceProtocolKey as String] as? String,
                totalBytes: nil, freeBytes: nil, operatingSystem: nil)
            if let mp = v.mountPoint, let u = MountTable.usage(of: mp) {
                v.totalBytes = u.total
                v.freeBytes = u.free
                v.operatingSystem = DiskMonitor.detectOS(at: mp)
            }
            result.append(v)
        }

        // A root snapshot (disk3s1s1) is not a "valid" BSD name above; add it.
        if !result.contains(where: { $0.isRootVolume }), let root = table.first(where: { $0.on == "/" }),
           let bsd = root.bsdName {
            let u = MountTable.usage(of: "/")
            result.append(Volume(bsdName: bsd, name: FileManager.default.displayName(atPath: "/"),
                                 mediaSize: u?.total ?? 0, fsKind: root.fsType, isNTFS: false, uuid: nil,
                                 mountPoint: "/", mountFSType: root.fsType, readOnly: root.readOnly,
                                 noBrowse: root.noBrowse, mountedByXT: false, isInternal: true,
                                 isEjectable: false, isWholeDisk: false, mediaName: nil, deviceProtocol: nil,
                                 totalBytes: u?.total, freeBytes: u?.free,
                                 operatingSystem: DiskMonitor.detectOS(at: "/")))
        }

        return result.sorted { a, b in
            if a.isNTFS != b.isNTFS { return a.isNTFS }
            if a.isRootVolume != b.isRootVolume { return a.isRootVolume }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func detectOS(at mountPoint: String) -> String? {
        let base = mountPoint == "/" ? "" : mountPoint
        let fm = FileManager.default
        let plist = base + "/System/Library/CoreServices/SystemVersion.plist"
        if let d = NSDictionary(contentsOfFile: plist),
           let v = d["ProductVersion"] as? String {
            return "macOS \(v)"
        }
        if fm.fileExists(atPath: base + "/Windows/System32/ntoskrnl.exe")
            || fm.fileExists(atPath: base + "/Windows/System32") {
            return "Windows"
        }
        return nil
    }
}
