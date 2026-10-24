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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(NSLocalizedString("NTFS Volumes", comment: ""))
                    if ntfs.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.badge.questionmark")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(NSLocalizedString("Connect an NTFS disk and it appears here.", comment: ""))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sidebarSecondary)
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
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 420)
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 360)
        .background(LinearGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom],
                                   startPoint: .top, endPoint: .bottom))
        .foregroundStyle(Theme.sidebarText)
        .environment(\.colorScheme, .dark)
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
                        .foregroundStyle(Theme.sidebarSecondary)
                }
            }
            Spacer()
            Menu {
                Button(NSLocalizedString("Open XT NTFS", comment: "")) { openMain() }
                Button(NSLocalizedString("Settings…", comment: "")) {
                    AppLifecycle.showApp()
                    AppActions.openSettings()
                }
                Button(NSLocalizedString("Check for Updates…", comment: "")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Divider()
                Button(NSLocalizedString("Quit XT NTFS", comment: "")) { AppLifecycle.quit() }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.sidebarSection)
            .padding(.horizontal, 14)
            .padding(.top, 4)
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
        .foregroundStyle(Theme.sidebarSecondary)
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
        HStack(alignment: .top, spacing: 12) {
            DriveIcon(volume: volume, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(connection)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.sidebarSecondary)
                        .lineLimit(1)
                }
                Text(sizeLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sidebarSecondary)
                if let total = volume.totalBytes, let free = volume.freeBytes, total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Theme.accent)
                                .frame(width: max(3, geo.size.width * CGFloat(total - free) / CGFloat(total)))
                        }
                    }
                    .frame(height: 4)
                }
                HStack(spacing: 5) {
                    StatusDot(status: volume.status)
                    Text(stateLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.sidebarSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let os = volume.operatingSystem, !os.isEmpty {
                        Text(os)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.sidebarSecondary)
                    }
                }
            }
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(hovering ? 0.10 : 0.05)))
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
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
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
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

    private var sizeLine: String {
        if let total = volume.totalBytes, let free = volume.freeBytes {
            return String(format: NSLocalizedString("%@ free of %@", comment: ""),
                          Format.size(free), Format.size(total))
        }
        return Format.size(volume.displaySize)
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

enum AppActions {
    static func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
