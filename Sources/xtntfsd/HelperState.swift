import Foundation
import XTShared

/// Thread-safe state shared by the request handlers, the disk watcher and
/// the mounter: configuration, active XT mounts and the event log.
final class HelperState {
    private let lock = NSLock()
    private var _config: EngineConfig
    private var mounts: [String: ManagedMount] = [:]
    private var events: [HelperEvent] = []
    private var nextEventID = 1

    init() {
        _config = HelperState.loadConfig()
    }

    var config: EngineConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    func updateConfig(_ change: (inout EngineConfig) -> Void) {
        lock.lock()
        change(&_config)
        let snapshot = _config
        lock.unlock()
        HelperState.saveConfig(snapshot)
    }

    // MARK: Mounts

    func setMount(_ m: ManagedMount) {
        lock.lock(); mounts[m.bsdName] = m; lock.unlock()
    }

    func mount(bsd: String) -> ManagedMount? {
        lock.lock(); defer { lock.unlock() }
        return mounts[bsd]
    }

    func removeMount(bsd: String) {
        lock.lock(); mounts[bsd] = nil; lock.unlock()
    }

    /// Records an XT mount found in the mount table (e.g. after a restart).
    @discardableResult
    func recordMount(from e: MountEntry, profile: PerformanceProfile) -> ManagedMount {
        let bsd = e.bsdName ?? e.from
        if let m = mount(bsd: bsd), m.mountPoint == e.on { return m }
        let m = ManagedMount(bsdName: bsd, devicePath: e.from, mountPoint: e.on,
                             volumeName: (e.on as NSString).lastPathComponent,
                             readOnly: e.readOnly,
                             profile: e.from.hasPrefix("/dev/rdisk") ? profile : .compatible)
        setMount(m)
        return m
    }

    /// Drops records whose mount has disappeared.
    func reconcile() {
        let table = MountTable.entries().filter { $0.isXT }
        lock.lock()
        for (bsd, m) in mounts where !table.contains(where: { $0.on == m.mountPoint }) {
            mounts[bsd] = nil
        }
        lock.unlock()
        for e in table { recordMount(from: e, profile: config.profile) }
    }

    var allMounts: [ManagedMount] {
        lock.lock(); defer { lock.unlock() }
        return Array(mounts.values).sorted { $0.bsdName < $1.bsdName }
    }

    // MARK: Events

    func addEvent(_ kind: HelperEventKind, bsd: String?, volume: String?, _ message: String) {
        lock.lock()
        let e = HelperEvent(id: nextEventID, kind: kind, bsdName: bsd, volumeName: volume, message: message)
        nextEventID += 1
        events.append(e)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        lock.unlock()
        Log.info("event \(kind.rawValue) \(bsd ?? "-"): \(message)")
    }

    func events(after id: Int) -> [HelperEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.id > id }
    }

    // MARK: Persistence

    private static func loadConfig() -> EngineConfig {
        guard let data = FileManager.default.contents(atPath: XTPaths.configPath),
              let c = try? XTCoding.decoder().decode(EngineConfig.self, from: data) else {
            return EngineConfig()
        }
        return c
    }

    private static func saveConfig(_ c: EngineConfig) {
        do {
            try FileManager.default.createDirectory(atPath: XTPaths.supportDir,
                                                    withIntermediateDirectories: true)
            let enc = XTCoding.encoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(c)
            try data.write(to: URL(fileURLWithPath: XTPaths.configPath), options: .atomic)
        } catch {
            Log.error("Could not save configuration: \(error.localizedDescription)")
        }
    }
}
