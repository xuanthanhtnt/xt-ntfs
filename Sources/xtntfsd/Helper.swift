import Foundation
import XTShared

/// The privileged service: owns the socket server, the DiskArbitration
/// watcher and the serial queue on which disk operations run.
final class Helper: DiskWatcherDelegate {
    let state = HelperState()
    let watcher: DiskWatcher
    let mounter: Mounter
    /// All operations that touch disks run here, one at a time.
    let ops = DispatchQueue(label: "xtntfs.operations")
    private let clients = DispatchQueue(label: "xtntfs.clients", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let pendingLock = NSLock()
    private var pending = Set<String>()

    init() {
        guard let w = DiskWatcher() else {
            Log.error("Could not create a DiskArbitration session")
            exit(1)
        }
        watcher = w
        mounter = Mounter(watcher: w, state: state)
        watcher.delegate = self
    }

    func start() {
        Log.info("XT NTFS helper \(XTBuild.fullVersion) starting; engine: \(System.engineVersion); macFUSE: \(System.macFUSEVersion ?? "not installed")")
        state.reconcile()
        startServer()
        watcher.start()
    }

    // MARK: DiskWatcherDelegate (called on the DiskArbitration queue)

    func shouldBlockSystemMount(_ disk: DiskDescription) -> Bool {
        let config = state.config
        guard config.driverEnabled, System.macFUSEInstalled,
              FileManager.default.isExecutableFile(atPath: System.tool("ntfs-3g")),
              mounter.isNTFS(disk) else { return false }
        let prefs = config.prefs(forKey: disk.prefsKey)
        if !prefs.noAutoMount { scheduleMount(disk.bsdName) }
        return true
    }

    func diskAppeared(_ disk: DiskDescription) {
        let config = state.config
        guard config.driverEnabled, System.macFUSEInstalled,
              FileManager.default.isExecutableFile(atPath: System.tool("ntfs-3g")) else { return }
        guard !disk.isWhole || disk.isLeaf else { return }
        // Only volumes that another driver mounted before we were running,
        // or that macOS left unmounted.
        let mounts = MountTable.entries(forBSD: disk.bsdName)
        if mounts.contains(where: { $0.isXT }) { return }
        guard mounter.isNTFS(disk) else { return }
        if config.prefs(forKey: disk.prefsKey).noAutoMount { return }
        if !mounts.isEmpty || disk.volumePath == nil {
            scheduleMount(disk.bsdName)
        }
    }

    func diskDisappeared(bsdName: String) {
        guard let m = state.mount(bsd: bsdName) else { return }
        ops.async { [self] in
            // The device is gone; drop the dead FUSE mount if it lingers.
            if MountTable.entry(at: m.mountPoint) != nil {
                Shell.run("/sbin/umount", ["-f", m.mountPoint], timeout: 30)
            }
            if FileManager.default.fileExists(atPath: m.mountPoint), !System.isMountPoint(m.mountPoint) {
                try? FileManager.default.removeItem(atPath: m.mountPoint)
            }
            state.removeMount(bsd: bsdName)
            state.addEvent(.unmounted, bsd: bsdName, volume: m.volumeName,
                           "The disk was disconnected. Always eject NTFS disks before unplugging them to avoid data loss.")
        }
    }

    private func scheduleMount(_ bsd: String) {
        pendingLock.lock()
        let fresh = pending.insert(bsd).inserted
        pendingLock.unlock()
        guard fresh else { return }
        // Give DiskArbitration a moment to finish with the disk.
        ops.asyncAfter(deadline: .now() + 0.4) { [self] in
            pendingLock.lock(); pending.remove(bsd); pendingLock.unlock()
            do {
                try mounter.mount(bsd: bsd)
            } catch {
                Log.error("Automatic mount of \(bsd) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Socket server

    private func startServer() {
        do {
            listenFD = try SocketIO.listen(path: XTPaths.socketPath, mode: 0o666)
        } catch {
            Log.error("Cannot listen on \(XTPaths.socketPath): \(error.localizedDescription)")
            exit(1)
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .global())
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.resume()
        acceptSource = src
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            close(fd)
            return
        }
        clients.async { [self] in
            defer { close(fd) }
            SocketIO.setTimeouts(fd, seconds: 3600)
            let response: HelperResponse
            do {
                let line = try SocketIO.readLine(fd)
                let request = try XTCoding.decoder().decode(HelperRequest.self, from: line)
                response = handle(request, uid: uid)
            } catch {
                response = HelperResponse(ok: false, error: "Bad request: \(error.localizedDescription)")
            }
            if var data = try? XTCoding.encoder().encode(response) {
                data.append(0x0A)
                try? SocketIO.writeAll(fd, data)
            }
        }
    }

    // MARK: Requests

    private func status(since: Int) -> HelperStatus {
        state.reconcile()
        return HelperStatus(helperVersion: XTBuild.fullVersion,
                            protocolVersion: XTProtocolVersion,
                            engineVersion: System.engineVersion,
                            macFUSEInstalled: System.macFUSEInstalled,
                            macFUSEVersion: System.macFUSEVersion,
                            config: state.config,
                            mounts: state.allMounts,
                            events: state.events(after: since))
    }

    private func handle(_ req: HelperRequest, uid: uid_t) -> HelperResponse {
        let adminOnly: Set<HelperCommand> = [.setConfig, .verify, .repair, .erase, .rename,
                                             .setSpotlight, .setVolumePrefs, .unmountAll]
        if adminOnly.contains(req.command) && !System.isAdmin(uid: uid) {
            return HelperResponse(ok: false, error: "This action requires an administrator account.")
        }
        if let bsd = req.bsdName, !NTFSNames.isValidBSDName(bsd) {
            return HelperResponse(ok: false, error: "Invalid disk identifier.")
        }

        switch req.command {
        case .status:
            return HelperResponse(ok: true, status: status(since: req.sinceEvent ?? 0))

        case .setConfig:
            guard let new = req.config else { return HelperResponse(ok: false, error: "Missing configuration.") }
            let old = state.config
            state.updateConfig { c in
                c.driverEnabled = new.driverEnabled
                c.dirtyPolicy = new.dirtyPolicy
                c.hibernatedPolicy = new.hibernatedPolicy
                c.profile = new.profile
                c.windowsNames = new.windowsNames
            }
            if new.driverEnabled && !old.driverEnabled {
                // Pick up NTFS volumes that are mounted read-only or not at all.
                ops.async { [self] in
                    for d in watcher.allPartitions() { diskAppeared(d) }
                }
            }
            return HelperResponse(ok: true, status: status(since: Int.max))

        case .setVolumePrefs:
            guard let key = req.prefsKey, let prefs = req.prefs else {
                return HelperResponse(ok: false, error: "Missing volume preferences.")
            }
            let old = state.config.prefs(forKey: key)
            state.updateConfig { $0.volumes[key] = prefs }
            return perform { self.mounter.applyPrefs(bsd: req.bsdName, key: key, old: old, new: prefs); return nil }

        case .mount:
            guard let bsd = req.bsdName else { return missingDisk() }
            return perform { try self.mounter.mount(bsd: bsd, readOnly: req.readOnly); return nil }

        case .mountWithSystem:
            guard let bsd = req.bsdName else { return missingDisk() }
            return perform {
                if let err = self.watcher.mountWithSystem(bsd: bsd) { throw EngineError(err) }
                return nil
            }

        case .unmount:
            guard let bsd = req.bsdName else { return missingDisk() }
            return perform { try self.mounter.unmount(bsd: bsd, force: req.enabled ?? false); return nil }

        case .eject:
            guard let bsd = req.bsdName else { return missingDisk() }
            return perform { try self.mounter.eject(bsd: bsd); return nil }

        case .unmountAll:
            return perform { self.mounter.unmountAll(); return nil }

        case .verify, .repair:
            guard let bsd = req.bsdName else { return missingDisk() }
            return perform { try self.mounter.verify(bsd: bsd, repair: req.command == .repair) }

        case .erase:
            guard let bsd = req.bsdName, let format = req.format else { return missingDisk() }
            return perform { try self.mounter.erase(bsd: bsd, format: format, label: req.label ?? "Untitled") }

        case .rename:
            guard let bsd = req.bsdName, let label = req.label else { return missingDisk() }
            return perform { try self.mounter.rename(bsd: bsd, label: label); return nil }

        case .setSpotlight:
            guard let bsd = req.bsdName, let enabled = req.enabled else { return missingDisk() }
            return perform {
                if let key = req.prefsKey {
                    self.state.updateConfig { c in
                        var p = c.prefs(forKey: key)
                        p.spotlight = enabled
                        c.volumes[key] = p
                    }
                }
                if let mp = MountTable.entries(forBSD: bsd).first?.on {
                    self.mounter.applySpotlight(mountPoint: mp, enabled: enabled)
                }
                return nil
            }
        }
    }

    private func missingDisk() -> HelperResponse {
        HelperResponse(ok: false, error: "Missing disk identifier.")
    }

    /// Runs a disk operation on the serial queue and waits for the result.
    private func perform(_ work: @escaping () throws -> String?) -> HelperResponse {
        var response = HelperResponse(ok: true)
        ops.sync {
            do {
                let out = try work()
                response = HelperResponse(ok: true, output: out, status: status(since: Int.max))
            } catch {
                response = HelperResponse(ok: false, error: error.localizedDescription,
                                          status: status(since: Int.max))
            }
        }
        return response
    }
}
