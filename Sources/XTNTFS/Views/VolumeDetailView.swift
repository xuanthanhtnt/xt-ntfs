import SwiftUI
import XTShared

struct VolumeDetailView: View {
    @EnvironmentObject var model: AppModel
    var volume: Volume

    @State private var editingName = false
    @State private var newName = ""
    @State private var showErase = false
    @State private var confirmForceUnmount = false
    @FocusState private var nameFocused: Bool

    var busy: String? { model.busy[volume.bsdName] }
    var prefs: VolumePrefs { model.prefs(for: volume) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headline
                    usage
                    options
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.detailBackground)
        .sheet(isPresented: $showErase) {
            EraseSheet(volume: volume, isPresented: $showErase)
                .environmentObject(model)
        }
        .onAppear { model.analyzeUsageIfNeeded(volume) }
        .onChange(of: volume.mountPoint) { _ in model.analyzeUsageIfNeeded(volume) }
        // A scan stopped for an operation starts again once it is done.
        .onChange(of: busy) { b in if b == nil { model.analyzeUsageIfNeeded(volume) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            if volume.isMounted {
                ToolbarAction(title: NSLocalizedString("Unmount", comment: ""), systemImage: "eject.fill",
                              tint: Theme.mountBlue, enabled: busy == nil && volume.canUnmount) {
                    Task { await model.unmount(volume) }
                }
            } else {
                ToolbarAction(title: NSLocalizedString("Mount", comment: ""), systemImage: "externaldrive.fill.badge.plus",
                              tint: Theme.mountBlue, enabled: busy == nil) {
                    Task { await model.mount(volume) }
                }
            }
            ToolbarAction(title: NSLocalizedString("Verify", comment: ""), systemImage: "checkmark",
                          tint: Theme.verifyGreen, enabled: busy == nil && volume.canVerify && !volume.isRootVolume) {
                Task { await model.verify(volume) }
            }
            ToolbarAction(title: NSLocalizedString("Erase", comment: ""), systemImage: "eraser.fill",
                          tint: Theme.erasePink, enabled: busy == nil && volume.canErase) {
                showErase = true
            }
            ToolbarAction(title: NSLocalizedString("Startup", comment: ""), systemImage: "power.circle.fill",
                          tint: Theme.startupBlue, enabled: volume.operatingSystem != nil) {
                model.openStartupDiskSettings()
            }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(height: 70)
        .background(Theme.toolbarBackground)
    }

    // MARK: Icon, name and facts

    private var headline: some View {
        HStack(alignment: .top, spacing: 28) {
            DriveIcon(volume: volume, size: 118, showBadge: true)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 10) {
                nameField
                VStack(spacing: 0) {
                    InfoRow(label: NSLocalizedString("Mounted", comment: "")) {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(mountedText).foregroundStyle(Color.primary)
                            Spacer(minLength: 16)
                            if let mp = volume.mountPoint {
                                Button(mp) { model.reveal(volume) }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    InfoRow(label: NSLocalizedString("Device", comment: "")) { Text(volume.devicePath) }
                    if let bps = volume.linkSpeed {
                        InfoRow(label: NSLocalizedString("Connection", comment: "")) {
                            HStack(spacing: 6) {
                                Text(LinkSpeed.describe(bps))
                                if LinkSpeed.isSlow(bps) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help(LinkSpeedText.slowWarning)
                                }
                            }
                        }
                    }
                    InfoRow(label: NSLocalizedString("File System", comment: "")) { Text(fileSystemText) }
                    if let driver = volume.driverName {
                        InfoRow(label: NSLocalizedString("Driver", comment: "")) { Text(driver) }
                    }
                    InfoRow(label: NSLocalizedString("Operating System", comment: "")) {
                        Text(volume.operatingSystem ?? "")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                if let busy {
                    BusyLabel(text: busy)
                }
            }
        }
    }

    private var nameField: some View {
        HStack(spacing: 8) {
            if editingName {
                TextField("", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { editingName = false }
                    .frame(maxWidth: 320)
                Button(NSLocalizedString("Rename", comment: "")) { commitRename() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(volume.name)
                    .font(.system(size: 21, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !volume.isRootVolume && busy == nil {
                    Button {
                        newName = volume.name
                        editingName = true
                        nameFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("Rename volume", comment: ""))
                }
            }
        }
    }

    private func commitRename() {
        editingName = false
        let name = newName
        Task { await model.rename(volume, to: name) }
    }

    private var statusColor: Color {
        switch volume.status {
        case .readWrite: return Theme.statusRW
        case .readOnly: return Theme.statusRO
        case .unmounted: return Color.secondary
        }
    }

    private var mountedText: String {
        switch volume.status {
        case .readWrite: return NSLocalizedString("Yes", comment: "")
        case .readOnly: return NSLocalizedString("Yes, read-only", comment: "")
        case .unmounted: return NSLocalizedString("No", comment: "")
        }
    }

    private var fileSystemText: String {
        if volume.isNTFS {
            if volume.mountedByXT {
                let m = model.status?.mounts.first(where: { $0.bsdName == volume.bsdName })
                var details: [String] = []
                if let p = m?.profile { details.append(ProfileText.name(p)) }
                if m?.backend == .fskit { details.append("FSKit") }
                return "Microsoft NTFS · XT NTFS" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
            }
            return "Microsoft NTFS"
        }
        return volume.fileSystemName
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        if let total = volume.totalBytes, let free = volume.freeBytes {
            VStack(alignment: .leading, spacing: 6) {
                UsageBar(total: total, free: free, segments: segments(total: total, free: free))
                if let u = model.usage[volume.bsdName], !u.finished {
                    Text(String(format: NSLocalizedString("Analyzing… %d files", comment: ""), u.files))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(NSLocalizedString("Mount the volume to see how its space is used.", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func segments(total: Int64, free: Int64) -> [UsageSegment] {
        let used = max(0, total - free)
        guard volume.isNTFS, let u = model.usage[volume.bsdName] else {
            return [UsageSegment(name: NSLocalizedString("Other", comment: ""), bytes: used, color: Theme.catOther)]
        }
        let known = u.apps + u.audio + u.video + u.images + u.documents
        return [
            UsageSegment(name: NSLocalizedString("Apps", comment: ""), bytes: u.apps, color: Theme.catApps),
            UsageSegment(name: NSLocalizedString("Audio", comment: ""), bytes: u.audio, color: Theme.catAudio),
            UsageSegment(name: NSLocalizedString("Video", comment: ""), bytes: u.video, color: Theme.catVideo),
            UsageSegment(name: NSLocalizedString("Images", comment: ""), bytes: u.images, color: Theme.catImages),
            UsageSegment(name: NSLocalizedString("Documents", comment: ""), bytes: u.documents, color: Theme.catDocs),
            UsageSegment(name: NSLocalizedString("Other", comment: ""), bytes: max(0, used - known), color: Theme.catOther),
        ]
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 9) {
            if volume.isNTFS {
                Toggle(NSLocalizedString("Save Last Access Time", comment: ""), isOn: Binding(
                    get: { prefs.saveAccessTime },
                    set: { on in Task { await model.setPrefs(volume) { $0.saveAccessTime = on } } }))
                    .disabled(busy != nil || !model.helperRunning)
                    .help(NSLocalizedString("Update the last-access time of files when they are read. Off is faster.", comment: ""))
            }
            Toggle(NSLocalizedString("Enable Spotlight Indexing", comment: ""), isOn: Binding(
                get: { volume.isNTFS ? prefs.spotlight : spotlightOnForOther },
                set: { on in Task { await model.setSpotlight(volume, enabled: on) } }))
                .disabled(!volume.isMounted || volume.readOnly || busy != nil || !model.helperRunning)
            if volume.isNTFS {
                Toggle(NSLocalizedString("Mount in Read-only mode", comment: ""), isOn: Binding(
                    get: { prefs.readOnly },
                    set: { on in Task { await model.setPrefs(volume) { $0.readOnly = on } } }))
                    .disabled(busy != nil || !model.helperRunning)
                Toggle(NSLocalizedString("Do not mount automatically", comment: ""), isOn: Binding(
                    get: { prefs.noAutoMount },
                    set: { on in Task { await model.setPrefs(volume) { $0.noAutoMount = on } } }))
                    .disabled(busy != nil || !model.helperRunning)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .padding(.top, 30)
    }

    /// Spotlight state of non-NTFS volumes is owned by macOS; show it as on
    /// unless the volume opted out.
    private var spotlightOnForOther: Bool {
        guard let mp = volume.mountPoint else { return false }
        return !FileManager.default.fileExists(atPath: mp + "/.metadata_never_index")
    }
}

enum ProfileText {
    static func name(_ p: PerformanceProfile) -> String {
        switch p {
        case .compatible: return NSLocalizedString("Compatible", comment: "")
        case .balanced: return NSLocalizedString("Balanced", comment: "")
        case .turbo: return NSLocalizedString("Turbo", comment: "")
        }
    }

    static func detail(_ p: PerformanceProfile) -> String {
        switch p {
        case .compatible:
            return NSLocalizedString("Block device and kernel buffer cache, like stock ntfs-3g. Use if a disk misbehaves.", comment: "")
        case .balanced:
            return NSLocalizedString("Raw device I/O, 64 MB write-back cache, 1 MB transfers. Recommended.", comment: "")
        case .turbo:
            return NSLocalizedString("Raw device I/O, 256 MB cache, 8 MB transfers. Fastest for large files; eject before unplugging.", comment: "")
        }
    }
}

enum LinkSpeedText {
    static var slowWarning: String {
        NSLocalizedString("This disk is connected at USB 2.0 speed, which limits it to about 40 MB/s with any NTFS driver. Use a USB 3 cable (5 Gb/s or faster) and plug it straight into the Mac for full speed.", comment: "")
    }
}

enum BackendText {
    static func name(_ b: FUSEBackend) -> String {
        switch b {
        case .automatic: return NSLocalizedString("Automatic", comment: "")
        case .kernel: return NSLocalizedString("Kernel extension (fastest)", comment: "")
        case .fskit: return NSLocalizedString("FSKit (no kernel extension)", comment: "")
        }
    }

    static func detail(_ b: FUSEBackend) -> String {
        switch b {
        case .automatic:
            return NSLocalizedString("Uses the macFUSE kernel extension when it can be loaded; otherwise, on macOS 26 and later, mounts through FSKit.", comment: "")
        case .kernel:
            return NSLocalizedString("Fastest. On Macs with Apple silicon, kernel extensions must be allowed in Startup Security Utility.", comment: "")
        case .fskit:
            return NSLocalizedString("No kernel extension and no change to startup security (macOS 15.4+ with macFUSE 5). Slower than the kernel extension. Turn on macFUSE in System Settings › General › Login Items & Extensions › File System Extensions.", comment: "")
        }
    }
}
