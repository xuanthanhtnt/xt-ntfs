import SwiftUI
import XTShared

/// The panel shown from the menu bar icon, laid out like Paragon's
/// "NTFS for Mac Menu": a header, one card per NTFS disk (icon, name,
/// size, connection, usage, state and a mount/eject button) and a footer.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: UpdaterBridge

    var ntfs: [Volume] { model.volumes.filter { $0.isNTFS } }
    var otherExternal: [Volume] {
        model.volumes.filter { !$0.isNTFS && $0.isEjectable && !$0.isInternal && $0.isMounted && !$0.noBrowse }
    }

    /// Height of the disk list. The menu bar window sizes itself to the
    /// ScrollView's ideal height, which is zero, so the list is measured and
    /// the ScrollView gets that height (scrolling only past `maxListHeight`).
    @State private var listHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: min(max(listHeight, 1), maxListHeight))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(NSLocalizedString("NTFS Volumes", comment: ""))
            if ntfs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("Connect an NTFS disk and it appears here.", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            ForEach(ntfs) { v in
                MenuVolumeCard(volume: v)
            }
            if !otherExternal.isEmpty {
                sectionTitle(NSLocalizedString("Other Volumes", comment: ""))
                ForEach(otherExternal) { v in
                    MenuVolumeCard(volume: v)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("XT NTFS").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button(NSLocalizedString("Open XT NTFS", comment: "")) { openMain() }
                SettingsMenuItem()
                Button(NSLocalizedString("Check for Updates…", comment: "")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Divider()
                Button(NSLocalizedString("Quit XT NTFS", comment: "")) { AppLifecycle.quit() }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            Button {
                openMain()
            } label: {
                Label(NSLocalizedString("Open XT NTFS", comment: ""), systemImage: "macwindow")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                AppLifecycle.quit()
            } label: {
                Label(NSLocalizedString("Quit XT NTFS", comment: ""), systemImage: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openMain() {
        AppLifecycle.showApp()
        if let w = AppLifecycle.mainWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private var statusColor: Color {
        model.installState == .running && model.config.driverEnabled ? Theme.statusRW : Theme.statusRO
    }

    private var statusLine: String {
        switch model.installState {
        case .running:
            return model.config.driverEnabled ? NSLocalizedString("XT NTFS driver enabled", comment: "")
                                              : NSLocalizedString("XT NTFS driver disabled", comment: "")
        case .notInstalled: return NSLocalizedString("Engine not installed", comment: "")
        case .outdated: return NSLocalizedString("Engine update required", comment: "")
        case .notResponding: return NSLocalizedString("Engine not responding", comment: "")
        case .unknown: return NSLocalizedString("Checking engine…", comment: "")
        }
    }
}

/// One disk in the menu bar panel.
struct MenuVolumeCard: View {
    @EnvironmentObject var model: AppModel
    var volume: Volume
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            DriveIcon(volume: volume, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(connection)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.size(volume.displaySize))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let free = volume.freeBytes {
                        Text(String(format: NSLocalizedString("%@ free", comment: ""), Format.size(free)))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let total = volume.totalBytes, let free = volume.freeBytes, total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(Theme.accent)
                                .frame(width: max(3, geo.size.width * CGFloat(total - free) / CGFloat(total)))
                        }
                    }
                    .frame(height: 4)
                    .padding(.vertical, 1)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(stateLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let os = volume.operatingSystem, !os.isEmpty {
                        Text(os)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }

    private var statusColor: Color {
        switch volume.status {
        case .readWrite: return Theme.statusRW
        case .readOnly: return Theme.statusRO
        case .unmounted: return Color.secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 4) {
            if let activity = model.busy[volume.bsdName] {
                ProgressView().controlSize(.small).help(activity)
            } else if volume.isMounted {
                if !volume.isInternal || volume.isEjectable {
                    iconButton("eject.fill", NSLocalizedString("Eject", comment: "")) {
                        Task { await model.eject(volume) }
                    }
                }
                if volume.isNTFS {
                    iconButton("arrow.down.right.and.arrow.up.left", NSLocalizedString("Unmount", comment: "")) {
                        Task { await model.unmount(volume) }
                    }
                }
            } else {
                iconButton("externaldrive.fill.badge.plus", NSLocalizedString("Mount", comment: "")) {
                    Task { await model.mount(volume) }
                }
            }
        }
        .frame(width: 26)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var connection: String {
        if let bps = volume.linkSpeed { return LinkSpeed.describe(bps) }
        if volume.isInternal { return NSLocalizedString("Internal", comment: "") }
        if let p = volume.deviceProtocol, !p.isEmpty {
            return String(format: NSLocalizedString("External %@", comment: ""), p)
        }
        return NSLocalizedString("External", comment: "")
    }

    private var stateLine: String {
        switch volume.status {
        case .unmounted:
            return NSLocalizedString("Not mounted", comment: "")
        case .readOnly:
            return volume.driverName.map { String(format: NSLocalizedString("Read-only · %@", comment: ""), $0) }
                ?? NSLocalizedString("Read-only", comment: "")
        case .readWrite:
            return volume.driverName.map { String(format: NSLocalizedString("Read/write · %@", comment: ""), $0) }
                ?? NSLocalizedString("Read/write", comment: "")
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// "Settings…" in the gear menu. Since macOS 14 the Settings scene only opens
/// through SwiftUI's `openSettings`; the old `showSettingsWindow:` selector
/// does nothing there.
private struct SettingsMenuItem: View {
    var body: some View {
        if #available(macOS 14, *) {
            OpenSettingsButton()
        } else {
            Button(NSLocalizedString("Settings…", comment: "")) { AppActions.openSettings() }
        }
    }

    @available(macOS 14, *)
    private struct OpenSettingsButton: View {
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Button(NSLocalizedString("Settings…", comment: "")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                AppActions.bringSettingsToFront()
            }
        }
    }
}

enum AppActions {
    /// macOS 13: open the Settings scene through the responder chain.
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil),
           !NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
            NSLog("XT NTFS: unable to open the Settings window")
        }
        bringSettingsToFront()
    }

    /// The app usually runs without a Dock icon, so the Settings window has
    /// to be raised explicitly or it can open behind other apps.
    static func bringSettingsToFront() {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("Settings") == true && $0.styleMask.contains(.titled)
            }) else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
    }
}
