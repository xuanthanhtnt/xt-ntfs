import Foundation
import AppKit
import XTShared

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Optional destructive action offered next to Cancel.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

struct ReportItem: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var bsdName: String
    var failed: Bool
    var canRepair: Bool
}

struct UsageBreakdown: Equatable {
    var apps: Int64 = 0
    var audio: Int64 = 0
    var video: Int64 = 0
    var images: Int64 = 0
    var documents: Int64 = 0
    var files = 0
    var finished = false
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Selection: Hashable {
        case volume(String)
        case engine
    }

    @Published var volumes: [Volume] = []
    @Published var selection: Selection?
    @Published var status: HelperStatus?
    @Published var installState: EngineInstaller.InstallState = .unknown
    @Published var busy: [String: String] = [:]
    @Published var engineActivity: String?
    @Published var alert: AlertItem?
    @Published var report: ReportItem?
    @Published var usage: [String: UsageBreakdown] = [:]
    @Published var benchmarkHistory: [BenchmarkResult] = BenchmarkHistory.load()
    @Published var recentEvents: [HelperEvent] = []
    @Published var macFUSEInstalled = EngineInstaller.macFUSEInstalled

    private let monitor = DiskMonitor()
    private var timer: Timer?
    private var lastEventID = 0
    private var started = false
    private var usageTasks: [String: Task<Void, Never>] = [:]

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // `-XTSelect engine` opens the engine page (used for screenshots).
        if UserDefaults.standard.string(forKey: "XTSelect") == "engine" { selection = .engine }
        monitor.onChange = { [weak self] in
            Task { @MainActor in self?.rebuild() }
        }
        monitor.start()
        Task { await refreshStatus(initial: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatus(initial: false) }
        }
    }

    func refreshStatus(initial: Bool = false) async {
        let s = await HelperClient.status(since: initial ? 0 : lastEventID)
        macFUSEInstalled = EngineInstaller.macFUSEInstalled
        installState = EngineInstaller.state(for: s)
        if let s {
            let fresh = s.events
            if let last = fresh.last?.id { lastEventID = max(lastEventID, last) }
            if !initial {
                for e in fresh { Notifier.post(e) }
            }
            recentEvents = Array((recentEvents + fresh).suffix(30))
            status = s
        } else {
            status = nil
        }
        rebuild()
    }

    func rebuild() {
        let list = monitor.volumes(xtMounts: status?.mounts ?? [])
        if list != volumes { volumes = list }
        switch selection {
        case .volume(let id) where list.contains(where: { $0.id == id }):
            break
        case .engine:
            break
        default:
            if let first = list.first { selection = .volume(first.id) }
        }
    }

    var selectedVolume: Volume? {
        if case .volume(let id) = selection { return volumes.first { $0.id == id } }
        return nil
    }

    var helperRunning: Bool { status != nil }
    var config: EngineConfig { status?.config ?? EngineConfig() }

    func prefs(for v: Volume) -> VolumePrefs { config.prefs(forKey: v.prefsKey) }

    // MARK: Generic helper call

    @discardableResult
    private func run(_ bsd: String?, _ activity: String, _ request: HelperRequest) async -> HelperResponse? {
        guard helperRunning else {
            needsEngineAlert()
            return nil
        }
        if let bsd { busy[bsd] = activity } else { engineActivity = activity }
        defer {
            if let bsd { busy[bsd] = nil } else { engineActivity = nil }
        }
        do {
            let r = try await HelperClient.perform(request)
            if let s = r.status { status = s }
            rebuild()
            return r
        } catch let busyError as VolumeBusyError where request.command == .unmount || request.command == .eject {
            offerForce(busyError, request: request, activity: activity)
            await refreshStatus()
            return nil
        } catch {
            alert = AlertItem(title: activity, message: error.localizedDescription)
            await refreshStatus()
            return nil
        }
    }

    /// The volume could not be unmounted because apps are using it: say
    /// which ones and offer to force it, like Disk Utility does.
    private func offerForce(_ error: VolumeBusyError, request: HelperRequest, activity: String) {
        let eject = request.command == .eject
        alert = AlertItem(
            title: NSLocalizedString("The volume is in use", comment: ""),
            message: error.localizedDescription + "\n\n"
                + NSLocalizedString("Forcing it closes those files; the apps may lose unsaved changes.", comment: ""),
            actionTitle: eject ? NSLocalizedString("Force Eject", comment: "")
                               : NSLocalizedString("Force Unmount", comment: ""),
            action: { [weak self] in
                guard let self else { return }
                var forced = request
                forced.enabled = true
                Task { _ = await self.run(request.bsdName, activity, forced) }
            })
    }

    private func needsEngineAlert() {
        alert = AlertItem(
            title: NSLocalizedString("The XT NTFS engine is not running", comment: ""),
            message: NSLocalizedString("Install or update the engine from the XT NTFS page at the bottom of the sidebar.", comment: ""))
        selection = .engine
    }

    /// Fallback for non-NTFS volumes when the helper is unavailable.
    private func diskutil(_ args: [String], bsd: String, activity: String) async {
        busy[bsd] = activity
        defer { busy[bsd] = nil }
        let result: (Int32, String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (127, error.localizedDescription)); return
                }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
        }
        if result.0 != 0 { alert = AlertItem(title: activity, message: result.1) }
        rebuild()
    }

    // MARK: Volume actions

    func mount(_ v: Volume, readOnly: Bool? = nil) async {
        let activity = NSLocalizedString("Mounting…", comment: "")
        if v.isNTFS {
            if !macFUSEInstalled { selection = .engine; return }
            await run(v.bsdName, activity, HelperRequest(command: .mount, bsdName: v.bsdName, readOnly: readOnly))
        } else if helperRunning {
            await run(v.bsdName, activity, HelperRequest(command: .mountWithSystem, bsdName: v.bsdName))
        } else {
            await diskutil(["mount", v.bsdName], bsd: v.bsdName, activity: activity)
        }
    }

    func unmount(_ v: Volume, force: Bool = false) async {
        let activity = NSLocalizedString("Unmounting…", comment: "")
        if helperRunning {
            await run(v.bsdName, activity, HelperRequest(command: .unmount, bsdName: v.bsdName, enabled: force))
        } else {
            await diskutil(["unmount", v.bsdName], bsd: v.bsdName, activity: activity)
        }
    }

    func eject(_ v: Volume) async {
        let activity = NSLocalizedString("Ejecting…", comment: "")
        if helperRunning {
            await run(v.bsdName, activity, HelperRequest(command: .eject, bsdName: v.bsdName))
        } else {
            await diskutil(["eject", v.wholeDisk], bsd: v.bsdName, activity: activity)
        }
    }

    func verify(_ v: Volume, repair: Bool = false) async {
        let activity = repair ? NSLocalizedString("Repairing…", comment: "") : NSLocalizedString("Verifying…", comment: "")
        guard helperRunning else { needsEngineAlert(); return }
        busy[v.bsdName] = activity
        defer { busy[v.bsdName] = nil }
        do {
            let r = try await HelperClient.send(HelperRequest(command: repair ? .repair : .verify, bsdName: v.bsdName))
            if let s = r.status { status = s }
            let text = (r.ok ? r.output : r.error) ?? ""
            report = ReportItem(
                title: String(format: repair ? NSLocalizedString("Repair of “%@”", comment: "")
                                             : NSLocalizedString("Verification of “%@”", comment: ""), v.name),
                text: text.isEmpty ? NSLocalizedString("No problems were found.", comment: "") : text,
                bsdName: v.bsdName, failed: !r.ok, canRepair: !r.ok && !repair)
        } catch {
            alert = AlertItem(title: activity, message: error.localizedDescription)
        }
        rebuild()
    }

    func erase(_ v: Volume, format: EraseFormat, label: String) async {
        let r = await run(v.bsdName, NSLocalizedString("Erasing…", comment: ""),
                          HelperRequest(command: .erase, bsdName: v.bsdName, label: label, format: format))
        if r != nil { usage[v.bsdName] = nil }
    }

    func rename(_ v: Volume, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != v.name else { return }
        await run(v.bsdName, NSLocalizedString("Renaming…", comment: ""),
                  HelperRequest(command: .rename, bsdName: v.bsdName, label: trimmed))
    }

    func setSpotlight(_ v: Volume, enabled: Bool) async {
        await run(v.bsdName, NSLocalizedString("Updating Spotlight…", comment: ""),
                  HelperRequest(command: .setSpotlight, bsdName: v.bsdName, enabled: enabled, prefsKey: v.prefsKey))
    }

    func setPrefs(_ v: Volume, _ change: (inout VolumePrefs) -> Void) async {
        var p = prefs(for: v)
        change(&p)
        await run(v.bsdName, NSLocalizedString("Applying…", comment: ""),
                  HelperRequest(command: .setVolumePrefs, bsdName: v.bsdName, prefsKey: v.prefsKey, prefs: p))
    }

    func updateConfig(_ change: (inout EngineConfig) -> Void) async {
        var c = config
        change(&c)
        await run(nil, NSLocalizedString("Saving settings…", comment: ""), HelperRequest(command: .setConfig, config: c))
    }

    func openStartupDiskSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Startup-Disk-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.startupdisk"]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    func reveal(_ v: Volume) {
        guard let mp = v.mountPoint else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mp)
    }

    // MARK: Engine

    func installEngine() async {
        engineActivity = NSLocalizedString("Installing engine…", comment: "")
        defer { engineActivity = nil }
        do {
            try await EngineInstaller.install()
        } catch is CancellationError {
        } catch {
            alert = AlertItem(title: NSLocalizedString("Installation failed", comment: ""),
                              message: error.localizedDescription)
        }
        await refreshStatus(initial: true)
    }

    func restartEngine() async {
        engineActivity = NSLocalizedString("Restarting engine…", comment: "")
        defer { engineActivity = nil }
        _ = try? await HelperClient.send(HelperRequest(command: .restart), timeout: 10)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for _ in 0..<40 {
            if await HelperClient.status(since: Int.max) != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await refreshStatus(initial: true)
    }

    /// True when the helper reported that macOS privacy protection blocked
    /// access to a disk (the helper needs Full Disk Access).
    var diskAccessBlocked: Bool {
        recentEvents.suffix(5).contains { $0.message.hasPrefix("macOS blocked XT NTFS") }
    }

    func uninstallEngine() async {
        engineActivity = NSLocalizedString("Removing engine…", comment: "")
        defer { engineActivity = nil }
        do {
            try await EngineInstaller.uninstall()
        } catch is CancellationError {
        } catch {
            alert = AlertItem(title: NSLocalizedString("Uninstall failed", comment: ""),
                              message: error.localizedDescription)
        }
        await refreshStatus(initial: true)
    }

    // MARK: Usage breakdown

    func analyzeUsageIfNeeded(_ v: Volume) {
        guard v.isNTFS, let mp = v.mountPoint, usage[v.bsdName] == nil, usageTasks[v.bsdName] == nil else { return }
        usage[v.bsdName] = UsageBreakdown()
        let bsd = v.bsdName
        usageTasks[bsd] = Task.detached(priority: .utility) { [model = self] in
            let result = UsageScanner.scan(mountPoint: mp) { partial in
                Task { @MainActor in model.usage[bsd] = partial }
            }
            await model.finishUsage(bsd: bsd, result: result)
        }
    }

    private func finishUsage(bsd: String, result: UsageBreakdown) {
        usage[bsd] = result
        usageTasks[bsd] = nil
    }

    func addBenchmark(_ r: BenchmarkResult) {
        benchmarkHistory.insert(r, at: 0)
        BenchmarkHistory.save(benchmarkHistory)
    }

    func clearBenchmarks() {
        benchmarkHistory = []
        BenchmarkHistory.save([])
    }
}

/// Walks a volume and adds up allocated sizes per file category.
enum UsageScanner {
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "wma", "alac", "opus"]
    static let video: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "mpg", "mpeg", "ts", "m2ts", "3gp", "flv"]
    static let images: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw",
                                      "cr2", "cr3", "nef", "arw", "dng", "psd", "svg"]
    static let documents: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages",
                                         "numbers", "key", "md", "csv", "odt", "ods", "epub"]

    static func scan(mountPoint: String, progress: @escaping (UsageBreakdown) -> Void) -> UsageBreakdown {
        var b = UsageBreakdown()
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: mountPoint),
                                                     includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else {
            b.finished = true
            return b
        }
        let deadline = Date().addingTimeInterval(120)
        while let url = e.nextObject() as? URL {
            if Task.isCancelled || Date() > deadline || b.files > 3_000_000 { break }
            guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
            let path = url.path.lowercased()
            let ext = url.pathExtension.lowercased()
            if path.contains(".app/") { b.apps += size }
            else if audio.contains(ext) { b.audio += size }
            else if video.contains(ext) { b.video += size }
            else if images.contains(ext) { b.images += size }
            else if documents.contains(ext) { b.documents += size }
            b.files += 1
            if b.files % 5000 == 0 { progress(b) }
        }
        b.finished = true
        return b
    }
}
