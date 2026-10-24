import SwiftUI
import XTShared

struct EngineView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    AppGlyph(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("XT NTFS").font(.system(size: 24, weight: .semibold))
                        Text(String(format: NSLocalizedString("Version %@", comment: ""), XTBuild.fullVersion))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let a = model.engineActivity { BusyLabel(text: a) }
                }
                setupCard
                statusCard
                profileCard
                BenchmarkView()
                eventsCard
            }
            .padding(30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.detailBackground)
    }

    // MARK: Setup / problems

    @ViewBuilder
    private var setupCard: some View {
        if !model.macFUSEInstalled {
            Card(title: NSLocalizedString("macFUSE is required", comment: ""), systemImage: "puzzlepiece.extension.fill", tint: Theme.statusRO) {
                Text(NSLocalizedString("XT NTFS runs its NTFS engine on macFUSE. Install macFUSE, allow its system extension in System Settings › Privacy & Security, then restart if asked. Macs with Apple silicon must allow kernel extensions in Startup Security Utility first (the same step Paragon NTFS requires).", comment: ""))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(NSLocalizedString("Download macFUSE", comment: "")) { NSWorkspace.shared.open(XTPaths.macFUSEDownload) }
                    Button(NSLocalizedString("Open Privacy & Security", comment: "")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(u) }
                    }
                }
            }
        }
        switch model.installState {
        case .notInstalled, .notResponding:
            Card(title: NSLocalizedString("Install the XT NTFS engine", comment: ""), systemImage: "arrow.down.circle.fill", tint: Theme.accent) {
                Text(NSLocalizedString("The engine is a small background service that mounts NTFS volumes read-write as soon as they are connected, just like a native driver. Installing it asks for an administrator password.", comment: ""))
                    .fixedSize(horizontal: false, vertical: true)
                Button(NSLocalizedString("Install Engine…", comment: "")) { Task { await model.installEngine() } }
                    .disabled(model.engineActivity != nil)
            }
        case .outdated(let installed):
            Card(title: NSLocalizedString("Engine update available", comment: ""), systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: Theme.accent) {
                Text(String(format: NSLocalizedString("The installed engine (%@) does not match this app (%@).", comment: ""), installed, XTBuild.fullVersion))
                Button(NSLocalizedString("Update Engine…", comment: "")) { Task { await model.installEngine() } }
                    .disabled(model.engineActivity != nil)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Status

    private var statusCard: some View {
        Card(title: NSLocalizedString("Status", comment: ""), systemImage: "gauge.with.dots.needle.67percent", tint: Theme.verifyGreen) {
            VStack(spacing: 0) {
                InfoRow(label: NSLocalizedString("XT NTFS driver", comment: "")) {
                    HStack(spacing: 8) {
                        Circle().fill(model.config.driverEnabled && model.helperRunning ? Theme.statusRW : Theme.statusRO)
                            .frame(width: 7, height: 7)
                        Text(model.config.driverEnabled ? NSLocalizedString("Enabled", comment: "") : NSLocalizedString("Disabled", comment: ""))
                            .foregroundStyle(Color.primary)
                        Button(model.config.driverEnabled ? NSLocalizedString("Disable", comment: "") : NSLocalizedString("Enable", comment: "")) {
                            let on = !model.config.driverEnabled
                            Task { await model.updateConfig { $0.driverEnabled = on } }
                        }
                        .disabled(!model.helperRunning)
                    }
                }
                InfoRow(label: NSLocalizedString("Engine service", comment: "")) {
                    Text(model.status.map { String(format: NSLocalizedString("Running · %@", comment: ""), $0.helperVersion) }
                         ?? NSLocalizedString("Not running", comment: ""))
                }
                InfoRow(label: NSLocalizedString("NTFS engine", comment: "")) {
                    Text(model.status?.engineVersion ?? "—")
                }
                InfoRow(label: "macFUSE") {
                    Text(model.macFUSEInstalled ? (EngineInstaller.macFUSEVersion ?? NSLocalizedString("Installed", comment: ""))
                                                : NSLocalizedString("Not installed", comment: ""))
                }
                InfoRow(label: NSLocalizedString("Mounted by XT NTFS", comment: "")) {
                    Text("\(model.status?.mounts.count ?? 0)")
                }
            }
            if !model.config.driverEnabled {
                Text(NSLocalizedString("While the driver is disabled, NTFS volumes are mounted by macOS (read-only) or by another installed NTFS driver.", comment: ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Profile

    private var profileCard: some View {
        Card(title: NSLocalizedString("Performance", comment: ""), systemImage: "speedometer", tint: Theme.erasePink) {
            Picker("", selection: Binding(
                get: { model.config.profile },
                set: { p in Task { await model.updateConfig { $0.profile = p } } })) {
                ForEach(PerformanceProfile.allCases, id: \.self) { p in
                    Text(ProfileText.name(p)).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .disabled(!model.helperRunning)
            Text(ProfileText.detail(model.config.profile))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(NSLocalizedString("The profile applies to volumes mounted from now on. Unmount and mount a volume to switch it.", comment: ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Events

    private var eventsCard: some View {
        Card(title: NSLocalizedString("Recent Activity", comment: ""), systemImage: "list.bullet.rectangle", tint: Theme.startupBlue) {
            if model.recentEvents.isEmpty {
                Text(NSLocalizedString("No activity yet.", comment: "")).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.recentEvents.reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(e.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(e.volumeName ?? e.bsdName ?? "").font(.system(size: 11.5, weight: .semibold))
                            Text(NSLocalizedString(e.message, comment: "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Rounded panel with a title row.
struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    var tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.system(size: 13.5, weight: .semibold))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            content()
                .font(.system(size: 12))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.toolbarBackground))
    }
}
