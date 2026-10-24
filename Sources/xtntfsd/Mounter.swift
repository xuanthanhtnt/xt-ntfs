import Foundation
import XTShared

struct EngineError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Performs all disk operations. Every method runs on the helper's serial
/// operations queue, so two operations never touch a device at once.
final class Mounter {
    private let watcher: DiskWatcher
    private let state: HelperState

    init(watcher: DiskWatcher, state: HelperState) {
        self.watcher = watcher
        self.state = state
    }

    // MARK: Queries

    func isNTFS(_ d: DiskDescription) -> Bool {
        if let kind = d.volumeKind?.lowercased() {
            if kind.contains("ntfs") { return true }
            if !kind.isEmpty, kind != "unknown" { return false }
        }
        guard d.isLeaf || !d.isWhole, d.mayBeNTFSPartition || d.volumeKind == nil else { return false }
        return System.bootSectorOEM(bsd: d.bsdName) == "NTFS    "
    }

    func xtMount(of bsd: String) -> MountEntry? {
        MountTable.entries(forBSD: bsd).first { $0.isXT }
    }

    // MARK: Mount

    @discardableResult
    func mount(bsd: String, readOnly forcedReadOnly: Bool? = nil, label labelOverride: String? = nil) throws -> ManagedMount {
        guard NTFSNames.isValidBSDName(bsd) else { throw EngineError("Invalid disk identifier.") }
        guard System.macFUSEInstalled else {
            throw EngineError("macFUSE is not installed. Install macFUSE to mount NTFS volumes in read-write mode.")
        }
        guard FileManager.default.isExecutableFile(atPath: System.tool("ntfs-3g")) else {
            throw EngineError("The XT NTFS engine is not installed. Open XT NTFS and install it.")
        }
        if let existing = xtMount(of: bsd) {
            return state.recordMount(from: existing, profile: state.config.profile)
        }
        guard let desc = watcher.describe(bsd: bsd) else { throw EngineError("Disk \(bsd) was not found.") }

        // Take the device away from any other driver (macOS read-only
        // driver, Paragon, a previous macFUSE mount...).
        for e in MountTable.entries(forBSD: bsd) {
            Log.info("Unmounting \(e.on) (\(e.fsType)) before XT mount")
            if let err = unmountPath(e.on, force: false) {
                throw EngineError("The volume is in use and could not be unmounted: \(err)")
            }
        }
        if !System.enginePIDs(bsd: bsd).isEmpty {
            System.waitForEngineExit(bsd: bsd, timeout: 15)
        }

        let config = state.config
        let prefs = config.prefs(forKey: desc.prefsKey)
        var readOnly = forcedReadOnly ?? prefs.readOnly
        var extra: [String] = []
        let label = labelOverride ?? volumeLabel(desc)

        // Check hibernation / unclean state before mounting read-write.
        if !readOnly {
            let probe = Shell.run(System.tool("ntfs-3g.probe"), ["--readwrite", "/dev/" + bsd], timeout: 120)
            switch probe.status {
            case 0:
                break
            case 14: // NTFS_VOLUME_HIBERNATED
                switch config.hibernatedPolicy {
                case .removeHibernation:
                    extra.append("remove_hiberfile")
                    state.addEvent(.hibernated, bsd: bsd, volume: label,
                                   "Windows hibernation data was removed so the volume could be mounted read-write.")
                case .ask, .mountReadOnly:
                    readOnly = true
                    state.addEvent(.hibernated, bsd: bsd, volume: label,
                                   "Windows is hibernated or uses Fast Startup on this volume. It was mounted read-only.")
                }
            case 15: // NTFS_VOLUME_UNCLEAN_UNMOUNT
                switch config.dirtyPolicy {
                case .mountAnyway:
                    state.addEvent(.dirty, bsd: bsd, volume: label,
                                   "The volume was not unmounted cleanly; the journal was reset during mount.")
                case .mountReadOnly:
                    readOnly = true
                    extra.append("norecover")
                    state.addEvent(.dirty, bsd: bsd, volume: label,
                                   "The volume was not unmounted cleanly and was mounted read-only.")
                case .verifyBeforeMount:
                    let check = Shell.run(System.tool("ntfsfix"), ["--no-action", "/dev/" + bsd], timeout: 1800)
                    if check.ok {
                        state.addEvent(.dirty, bsd: bsd, volume: label,
                                       "The volume was not unmounted cleanly. It passed verification and was mounted.")
                    } else {
                        readOnly = true
                        extra.append("norecover")
                        state.addEvent(.dirty, bsd: bsd, volume: label,
                                       "The volume needs repair and was mounted read-only. Use Verify in XT NTFS or chkdsk on Windows.")
                    }
                }
            case 12:
                throw EngineError("\(bsd) does not contain an NTFS file system.")
            case 16:
                throw EngineError("The volume is in use by another process.")
            case 17:
                throw EngineError("This NTFS volume is part of a software RAID and cannot be mounted.")
            default:
                // Other states (e.g. corruption) are reported by ntfs-3g below.
                if !probe.combined.isEmpty { Log.warn("probe \(bsd): \(probe.status) \(probe.combined)") }
            }
        }

        let profile = config.profile
        let device = profile == .compatible ? "/dev/" + bsd : "/dev/r" + bsd
        let mountPoint = try makeMountPoint(name: NTFSNames.mountName(for: label, bsdName: bsd))
        var opts = options(profile: profile, label: NTFSNames.mountName(for: label, bsdName: bsd),
                           readOnly: readOnly, windowsNames: config.windowsNames)
        opts.append(contentsOf: extra)

        Log.info("Mounting \(device) at \(mountPoint) [\(profile.rawValue)\(readOnly ? ", read-only" : "")]")
        let started = Date()
        let r = Shell.run(System.tool("ntfs-3g"), [device, mountPoint, "-o", opts.joined(separator: ",")],
                          env: environment(for: profile), timeout: 300)
        if !r.ok || !waitForMount(mountPoint) {
            try? FileManager.default.removeItem(atPath: mountPoint)
            let msg = explain(r)
            state.addEvent(.mountFailed, bsd: bsd, volume: label, msg)
            Log.error("Mount of \(bsd) failed: \(r.status) \(r.combined)")
            throw EngineError(msg)
        }
        Log.info("Mounted \(bsd) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

        // Safety net: if another driver mounted the same device meanwhile
        // (e.g. a late automount), take it down so only XT owns the device.
        usleep(800_000)
        for e in MountTable.entries(forBSD: bsd) where !e.isXT {
            Log.warn("Removing competing mount \(e.on) (\(e.fsType)) of \(bsd)")
            unmountPath(e.on, force: true)
        }

        if !readOnly { prepareVolume(at: mountPoint) }
        applySpotlight(mountPoint: mountPoint, enabled: prefs.spotlight)

        let m = ManagedMount(bsdName: bsd, devicePath: device, mountPoint: mountPoint,
                             volumeName: label ?? bsd, readOnly: readOnly, profile: profile)
        state.setMount(m)
        state.addEvent(.mounted, bsd: bsd, volume: label,
                       readOnly ? "Mounted read-only." : "Mounted read-write.")
        return m
    }

    private func volumeLabel(_ d: DiskDescription) -> String? {
        if let n = d.volumeName, !n.isEmpty { return n }
        let r = Shell.run(System.tool("ntfslabel"), ["--no-action", "/dev/" + d.bsdName], timeout: 30)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    private func options(profile: PerformanceProfile, label: String, readOnly: Bool,
                         windowsNames: Bool) -> [String] {
        let owner = System.consoleUser()
        let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
        var o = [
            "volname=\(escaped)",
            "local",
            "allow_other",
            "defer_permissions",
            "uid=\(owner?.uid ?? 0)",
            "gid=\(owner?.gid ?? 0)",
            "dmask=022",
            "fmask=133",
            "user_xattr",
            "daemon_timeout=120",
        ]
        if FileManager.default.fileExists(atPath: XTPaths.volumeIconPath) {
            o.append("volicon=\(XTPaths.volumeIconPath.replacingOccurrences(of: ",", with: "\\,"))")
        }
        switch profile {
        case .compatible:
            break
        case .balanced:
            o += ["noatime", "big_writes", "noappledouble", "negative_vncache", "iosize=1048576"]
        case .turbo:
            o += ["noatime", "big_writes", "noappledouble", "negative_vncache", "iosize=8388608"]
        }
        if windowsNames { o.append("windows_names") }
        if readOnly { o.append("ro") }
        return o
    }

    private func environment(for profile: PerformanceProfile) -> [String: String] {
        switch profile {
        case .compatible:
            return ["XTNTFS_RAWIO": "0"]
        case .balanced:
            return ["XTNTFS_CACHE_MB": "64", "XTNTFS_LINE_KB": "256", "XTNTFS_DIRECT_KB": "1024",
                    "XTNTFS_DIRTY_MB": "16", "XTNTFS_FLUSH_MS": "1000"]
        case .turbo:
            return ["XTNTFS_CACHE_MB": "256", "XTNTFS_LINE_KB": "512", "XTNTFS_DIRECT_KB": "1024",
                    "XTNTFS_DIRTY_MB": "64", "XTNTFS_FLUSH_MS": "2000"]
        }
    }

    private func makeMountPoint(name: String) throws -> String {
        let fm = FileManager.default
        var candidate = "/Volumes/" + name
        var i = 1
        while fm.fileExists(atPath: candidate) {
            let busy = System.isMountPoint(candidate)
            let empty = ((try? fm.contentsOfDirectory(atPath: candidate)) ?? ["x"]).isEmpty
            if !busy && empty {
                try? fm.removeItem(atPath: candidate)
                break
            }
            candidate = "/Volumes/\(name) \(i)"
            i += 1
        }
        do {
            try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o755])
        } catch {
            throw EngineError("Could not create mount point \(candidate): \(error.localizedDescription)")
        }
        return candidate
    }

    private func waitForMount(_ path: String) -> Bool {
        for _ in 0..<50 {
            if MountTable.entry(at: path) != nil { return true }
            usleep(100_000)
        }
        return false
    }

    private func explain(_ r: CommandResult) -> String {
        let text = r.combined
        let lower = text.lowercased()
        if lower.contains("fuse") && (lower.contains("not available") || lower.contains("load")
                                       || lower.contains("device not configured")) {
            return "macFUSE could not be loaded. Allow the macFUSE system extension in System Settings > Privacy & Security, then try again."
        }
        if lower.contains("hibernat") || lower.contains("fast restart") {
            return "Windows is hibernated or uses Fast Startup. Shut Windows down completely or choose a hibernation option in XT NTFS settings."
        }
        if lower.contains("bitlocker") || lower.contains("fve") {
            return "This volume is encrypted with BitLocker and cannot be mounted."
        }
        if r.timedOut { return "Mounting timed out." }
        return text.isEmpty ? "ntfs-3g exited with status \(r.status)." : text
    }

    /// Small tweaks that keep macOS from adding work to the volume.
    private func prepareVolume(at mountPoint: String) {
        let fm = FileManager.default
        let fsevents = mountPoint + "/.fseventsd"
        if !fm.fileExists(atPath: fsevents + "/no_log") {
            try? fm.createDirectory(atPath: fsevents, withIntermediateDirectories: true)
            fm.createFile(atPath: fsevents + "/no_log", contents: Data())
        }
    }

    func applySpotlight(mountPoint: String, enabled: Bool) {
        Shell.run("/usr/bin/mdutil", ["-i", enabled ? "on" : "off", mountPoint], timeout: 60)
    }

    // MARK: Unmount

    func unmount(bsd: String, force: Bool = false) throws {
        let mounts = MountTable.entries(forBSD: bsd)
        guard !mounts.isEmpty else {
            state.removeMount(bsd: bsd)
            return
        }
        for e in mounts {
            if let err = unmountPath(e.on, force: force) {
                throw EngineError("Could not unmount \(e.on). Close any files or apps using it and try again.\n\(err)")
            }
            if e.isXT {
                // Wait for ntfs-3g to write back its cache and close the device.
                if !System.waitForEngineExit(bsd: bsd, timeout: 120) {
                    Log.warn("ntfs-3g for \(bsd) still running after unmount")
                }
                if FileManager.default.fileExists(atPath: e.on), !System.isMountPoint(e.on) {
                    try? FileManager.default.removeItem(atPath: e.on)
                }
            }
        }
        let name = state.mount(bsd: bsd)?.volumeName
        state.removeMount(bsd: bsd)
        state.addEvent(.unmounted, bsd: bsd, volume: name, "Unmounted. It is safe to disconnect the volume.")
    }

    /// Unmounts one mount point (never by device, so a competing mount of
    /// the same device is not confused with ours). Returns an error text.
    @discardableResult
    func unmountPath(_ path: String, force: Bool) -> String? {
        var r = Shell.run("/usr/sbin/diskutil", ["unmount", path], timeout: 120)
        if !r.ok && force {
            r = Shell.run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 120)
        }
        if r.ok || MountTable.entry(at: path) == nil { return nil }
        let u = Shell.run("/sbin/umount", force ? ["-f", path] : [path], timeout: 120)
        if u.ok || MountTable.entry(at: path) == nil { return nil }
        return r.combined.isEmpty ? u.combined : r.combined
    }

    func unmountAll() {
        for e in MountTable.entries() where e.isXT {
            if let bsd = e.bsdName { try? unmount(bsd: bsd, force: true) }
        }
    }

    func eject(bsd: String) throws {
        let whole = NTFSNames.wholeDisk(of: bsd)
        for e in MountTable.entries() where e.isXT {
            if let b = e.bsdName, NTFSNames.wholeDisk(of: b) == whole {
                try unmount(bsd: b)
            }
        }
        if let err = watcher.unmount(bsd: whole, whole: true) {
            throw EngineError(err)
        }
        if let err = watcher.eject(bsd: whole) {
            throw EngineError(err)
        }
    }

    // MARK: Verify / repair

    func verify(bsd: String, repair: Bool) throws -> String {
        guard let desc = watcher.describe(bsd: bsd) else { throw EngineError("Disk \(bsd) was not found.") }
        if isNTFS(desc) {
            let wasXT = xtMount(of: bsd)
            let wasReadOnly = wasXT?.readOnly
            if !MountTable.entries(forBSD: bsd).isEmpty { try unmount(bsd: bsd) }
            let args = repair ? ["/dev/" + bsd] : ["--no-action", "/dev/" + bsd]
            let r = Shell.run(System.tool("ntfsfix"), args, timeout: 3600)
            var report = r.combined
            if repair && r.ok {
                report += "\n\nBasic repairs were made. Windows will run a full check (chkdsk) the next time this volume is connected to a Windows PC."
            }
            if wasXT != nil || state.config.driverEnabled {
                do { try mount(bsd: bsd, readOnly: wasReadOnly) } catch {
                    report += "\n\nRemount failed: \(error.localizedDescription)"
                }
            }
            if !r.ok { throw EngineError(report.isEmpty ? "Verification failed." : report) }
            return report
        }
        let r = Shell.run("/usr/sbin/diskutil", [repair ? "repairVolume" : "verifyVolume", bsd], timeout: 3600)
        if !r.ok { throw EngineError(r.combined) }
        return r.combined
    }

    // MARK: Erase

    func erase(bsd: String, format: EraseFormat, label: String) throws -> String {
        guard let desc = watcher.describe(bsd: bsd) else { throw EngineError("Disk \(bsd) was not found.") }
        let kind = desc.volumeKind?.lowercased() ?? ""
        if kind == "apfs" || desc.mediaContent?.uppercased() == "41504653-0000-11AA-AA11-00306543ECAC" {
            throw EngineError("APFS volumes can be erased with Disk Utility.")
        }
        if desc.isWhole && !desc.isLeaf {
            throw EngineError("Select a volume (partition), not a whole disk.")
        }
        if desc.isInternal && !isNTFS(desc) {
            throw EngineError("Internal volumes other than NTFS cannot be erased here. Use Disk Utility.")
        }
        let cleanLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        let finalLabel = cleanLabel.isEmpty ? "Untitled" : cleanLabel

        if !MountTable.entries(forBSD: bsd).isEmpty { try unmount(bsd: bsd, force: true) }

        if let personality = format.diskutilName {
            let r = Shell.run("/usr/sbin/diskutil", ["eraseVolume", personality, finalLabel, bsd], timeout: 3600)
            if !r.ok { throw EngineError(r.combined) }
            return r.combined
        }

        // NTFS: make sure the partition type is one Windows recognises.
        if !desc.mayBeNTFSPartition {
            watcher.allowSystemMountOnce(bsd)
            let r = Shell.run("/usr/sbin/diskutil", ["eraseVolume", "ExFAT", "XTNTFS", bsd], timeout: 600)
            if !r.ok { throw EngineError(r.combined) }
            _ = watcher.unmount(bsd: bsd, force: true)
        }
        let r = Shell.run(System.tool("mkntfs"), ["--fast", "--force", "--label", finalLabel, "/dev/" + bsd],
                          timeout: 3600)
        if !r.ok { throw EngineError(r.combined) }
        // Remember defaults for the fresh volume, then mount it.
        usleep(500_000)
        do { try mount(bsd: bsd, label: finalLabel) } catch {
            return r.combined + "\n\nThe volume was formatted but could not be mounted: \(error.localizedDescription)"
        }
        return "Formatted \(bsd) as NTFS (\(finalLabel))."
    }

    // MARK: Rename

    func rename(bsd: String, label: String) throws {
        let newLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty else { throw EngineError("The name cannot be empty.") }
        guard let desc = watcher.describe(bsd: bsd) else { throw EngineError("Disk \(bsd) was not found.") }
        if isNTFS(desc) {
            let was = xtMount(of: bsd)
            if !MountTable.entries(forBSD: bsd).isEmpty { try unmount(bsd: bsd) }
            let r = Shell.run(System.tool("ntfslabel"), ["/dev/" + bsd, newLabel], timeout: 120)
            if !r.ok { throw EngineError(r.combined) }
            if was != nil || state.config.driverEnabled {
                try mount(bsd: bsd, readOnly: was?.readOnly, label: newLabel)
            }
            return
        }
        let r = Shell.run("/usr/sbin/diskutil", ["rename", bsd, newLabel], timeout: 120)
        if !r.ok { throw EngineError(r.combined) }
    }

    // MARK: Preferences

    func applyPrefs(bsd: String?, key: String, old: VolumePrefs, new: VolumePrefs) {
        guard let bsd else { return }
        if let m = xtMount(of: bsd) {
            if old.readOnly != new.readOnly {
                do {
                    try unmount(bsd: bsd)
                    try mount(bsd: bsd, readOnly: new.readOnly)
                } catch {
                    state.addEvent(.mountFailed, bsd: bsd, volume: nil, error.localizedDescription)
                }
            } else if old.spotlight != new.spotlight {
                applySpotlight(mountPoint: m.on, enabled: new.spotlight)
            }
        }
    }
}
