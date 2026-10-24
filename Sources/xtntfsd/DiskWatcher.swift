import Foundation
import DiskArbitration
import XTShared

/// Snapshot of the DiskArbitration description of one disk.
struct DiskDescription {
    var bsdName: String
    var volumeKind: String?
    var volumeName: String?
    var volumeUUID: String?
    var volumePath: URL?
    var mediaContent: String?
    var mediaSize: Int64
    var isWhole: Bool
    var isLeaf: Bool
    var isInternal: Bool
    var isEjectable: Bool
    var isWritable: Bool

    init(bsdName: String, dict: [String: Any]) {
        self.bsdName = bsdName
        volumeKind = dict[kDADiskDescriptionVolumeKindKey as String] as? String
        volumeName = dict[kDADiskDescriptionVolumeNameKey as String] as? String
        if let raw = dict[kDADiskDescriptionVolumeUUIDKey as String],
           CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = raw as! CFUUID
            volumeUUID = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
        }
        volumePath = dict[kDADiskDescriptionVolumePathKey as String] as? URL
        mediaContent = dict[kDADiskDescriptionMediaContentKey as String] as? String
        mediaSize = (dict[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        isWhole = (dict[kDADiskDescriptionMediaWholeKey as String] as? Bool) ?? false
        isLeaf = (dict[kDADiskDescriptionMediaLeafKey as String] as? Bool) ?? false
        isInternal = (dict[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
        isEjectable = (dict[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
        isWritable = (dict[kDADiskDescriptionMediaWritableKey as String] as? Bool) ?? true
    }

    var prefsKey: String {
        NTFSNames.prefsKey(uuid: volumeUUID, bsdName: bsdName, label: volumeName)
    }

    /// Partition types that may hold an NTFS file system.
    var mayBeNTFSPartition: Bool {
        guard let c = mediaContent else { return false }
        return c == "Windows_NTFS"
            || c.uppercased() == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
            || c == "Microsoft Basic Data"
            || c == "DOS_FAT_32"
    }
}

private final class DAResult {
    let semaphore = DispatchSemaphore(value: 0)
    var error: String?
}

private func dissenterMessage(_ d: DADissenter) -> String {
    if let s = DADissenterGetStatusString(d) as String?, !s.isEmpty { return s }
    let status = DADissenterGetStatus(d)
    return String(format: "DiskArbitration error 0x%08X", UInt32(bitPattern: status))
}

protocol DiskWatcherDelegate: AnyObject {
    /// Called on the DiskArbitration queue; must be fast. Return true to
    /// stop macOS (or another driver) from mounting this volume.
    func shouldBlockSystemMount(_ disk: DiskDescription) -> Bool
    func diskAppeared(_ disk: DiskDescription)
    func diskDisappeared(bsdName: String)
}

/// DiskArbitration session of the helper.
final class DiskWatcher {
    let session: DASession
    let queue = DispatchQueue(label: "xtntfs.diskarbitration")
    weak var delegate: DiskWatcherDelegate?

    private let lock = NSLock()
    private var allowOnce = Set<String>()

    init?() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
    }

    func start() {
        DASessionSetDispatchQueue(session, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskMountApprovalCallback(session, nil, { disk, ctx in
            guard let ctx else { return nil }
            let me = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            return me.approve(disk)
        }, ctx)

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            if let d = me.describe(disk) { me.delegate?.diskAppeared(d) }
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx, let name = DADiskGetBSDName(disk) else { return }
            let me = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            me.delegate?.diskDisappeared(bsdName: String(cString: name))
        }, ctx)
    }

    /// Let the next DiskArbitration mount of @bsd through (system driver).
    func allowSystemMountOnce(_ bsd: String) {
        lock.lock(); allowOnce.insert(bsd); lock.unlock()
    }

    private func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let d = describe(disk) else { return nil }
        lock.lock()
        let allowed = allowOnce.remove(d.bsdName) != nil
        lock.unlock()
        if allowed { return nil }
        guard delegate?.shouldBlockSystemMount(d) == true else { return nil }
        Log.info("Blocked system mount of \(d.bsdName) (\(d.volumeKind ?? "?")); XT NTFS will mount it")
        let dissenter = DADissenterCreate(kCFAllocatorDefault,
                                          DAReturn(truncatingIfNeeded: kDAReturnNotPermitted),
                                          "XT NTFS mounts this volume" as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    func describe(_ disk: DADisk) -> DiskDescription? {
        guard let cname = DADiskGetBSDName(disk),
              let dict = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return DiskDescription(bsdName: String(cString: cname), dict: dict)
    }

    func disk(_ bsd: String) -> DADisk? {
        bsd.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
    }

    func describe(bsd: String) -> DiskDescription? {
        guard let d = disk(bsd) else { return nil }
        return describe(d)
    }

    /// All disks currently known (used at start-up).
    func allPartitions() -> [DiskDescription] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return names.filter { $0.hasPrefix("disk") && NTFSNames.isValidBSDName($0) }
            .compactMap { describe(bsd: $0) }
    }

    // MARK: Synchronous wrappers (call from a queue other than `queue`)

    func unmount(bsd: String, force: Bool = false, whole: Bool = false) -> String? {
        guard let d = disk(bsd) else { return "No such disk: \(bsd)" }
        let box = DAResult()
        var options = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
        if whole { options |= kDADiskUnmountOptionWhole }
        DADiskUnmount(d, DADiskUnmountOptions(options), { _, dissenter, ctx in
            guard let ctx else { return }
            let box = Unmanaged<DAResult>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter { box.error = dissenterMessage(dissenter) }
            box.semaphore.signal()
        }, Unmanaged.passRetained(box).toOpaque())
        if box.semaphore.wait(timeout: .now() + 60) == .timedOut { return "Timed out unmounting \(bsd)" }
        return box.error
    }

    func mountWithSystem(bsd: String) -> String? {
        guard let d = disk(bsd) else { return "No such disk: \(bsd)" }
        allowSystemMountOnce(bsd)
        let box = DAResult()
        DADiskMount(d, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, ctx in
            guard let ctx else { return }
            let box = Unmanaged<DAResult>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter { box.error = dissenterMessage(dissenter) }
            box.semaphore.signal()
        }, Unmanaged.passRetained(box).toOpaque())
        if box.semaphore.wait(timeout: .now() + 60) == .timedOut { return "Timed out mounting \(bsd)" }
        return box.error
    }

    func eject(bsd: String) -> String? {
        guard let d = disk(bsd) else { return "No such disk: \(bsd)" }
        let box = DAResult()
        DADiskEject(d, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
            guard let ctx else { return }
            let box = Unmanaged<DAResult>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter { box.error = dissenterMessage(dissenter) }
            box.semaphore.signal()
        }, Unmanaged.passRetained(box).toOpaque())
        if box.semaphore.wait(timeout: .now() + 60) == .timedOut { return "Timed out ejecting \(bsd)" }
        return box.error
    }
}
