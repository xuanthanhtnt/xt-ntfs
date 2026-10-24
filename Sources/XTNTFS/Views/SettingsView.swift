import SwiftUI
import ServiceManagement
import Sparkle
import XTShared

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var updater: SPUUpdater

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(NSLocalizedString("General", comment: ""), systemImage: "gearshape") }
            UpdateSettings(updater: updater)
                .tabItem { Label(NSLocalizedString("Updates", comment: ""), systemImage: "arrow.triangle.2.circlepath") }
            AlertSettings()
                .tabItem { Label(NSLocalizedString("Alerts & Notifications", comment: ""), systemImage: "bell.badge") }
            MenuBarSettings()
                .tabItem { Label(NSLocalizedString("Menu Bar", comment: ""), systemImage: "menubar.rectangle") }
        }
        .frame(width: 640)
        .environmentObject(model)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("XT NTFS").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 10) {
                        Circle().fill(model.config.driverEnabled && model.helperRunning ? Theme.statusRW : Theme.statusRO)
                            .frame(width: 8, height: 8)
                        Text(model.config.driverEnabled ? NSLocalizedString("Enabled", comment: "")
                                                        : NSLocalizedString("Disabled", comment: ""))
                            .font(.system(size: 13, weight: .semibold))
                        Button(model.config.driverEnabled ? NSLocalizedString("Disable", comment: "")
                                                          : NSLocalizedString("Enable", comment: "")) {
                            let on = !model.config.driverEnabled
                            Task { await model.updateConfig { $0.driverEnabled = on } }
                        }
                        .frame(width: 110)
                        .disabled(!model.helperRunning)
                    }
                    Text(NSLocalizedString("Warning: when disabled, XT NTFS does not mount NTFS volumes; macOS mounts them read-only.", comment: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(NSLocalizedString("Uninstall…", comment: "")) { confirmUninstall = true }
                        .padding(.top, 16)
                        .disabled(!EngineInstaller.isInstalledOnDisk)
                }
                .frame(width: 260, alignment: .leading)
                VStack(spacing: 14) {
                    AppearancePreview(appearance: appearance)
                    Picker(NSLocalizedString("Appearance:", comment: ""), selection: $appearance) {
                        Text(NSLocalizedString("System", comment: "")).tag("system")
                        Text(NSLocalizedString("Light", comment: "")).tag("light")
                        Text(NSLocalizedString("Dark", comment: "")).tag("dark")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .onChange(of: appearance) { AppearanceManager.apply($0) }
                }
            }
            .padding(22)

            Divider()

            Form {
                Picker(NSLocalizedString("What to do when mounting dirty volumes?", comment: ""), selection: Binding(
                    get: { model.config.dirtyPolicy },
                    set: { v in Task { await model.updateConfig { $0.dirtyPolicy = v } } })) {
                    Text(NSLocalizedString("Verify before mount", comment: "")).tag(DirtyVolumePolicy.verifyBeforeMount)
                    Text(NSLocalizedString("Mount anyway", comment: "")).tag(DirtyVolumePolicy.mountAnyway)
                    Text(NSLocalizedString("Mount in read-only mode", comment: "")).tag(DirtyVolumePolicy.mountReadOnly)
                }
                Picker(NSLocalizedString("What to do with hibernated Windows?", comment: ""), selection: Binding(
                    get: { model.config.hibernatedPolicy },
                    set: { v in Task { await model.updateConfig { $0.hibernatedPolicy = v } } })) {
                    Text(NSLocalizedString("Ask what to do", comment: "")).tag(HibernatedPolicy.ask)
                    Text(NSLocalizedString("Mount in read-only mode", comment: "")).tag(HibernatedPolicy.mountReadOnly)
                    Text(NSLocalizedString("Remove hibernation data and mount", comment: "")).tag(HibernatedPolicy.removeHibernation)
                }
                Picker(NSLocalizedString("Performance profile:", comment: ""), selection: Binding(
                    get: { model.config.profile },
                    set: { v in Task { await model.updateConfig { $0.profile = v } } })) {
                    ForEach(PerformanceProfile.allCases, id: \.self) { Text(ProfileText.name($0)).tag($0) }
                }
                Toggle(NSLocalizedString("Only allow file names that Windows accepts", comment: ""), isOn: Binding(
                    get: { model.config.windowsNames },
                    set: { v in Task { await model.updateConfig { $0.windowsNames = v } } }))
            }
            .formStyle(.columns)
            .disabled(!model.helperRunning)
            .padding(22)
            .background(Theme.detailBackground.opacity(0.5))
        }
        .alert(NSLocalizedString("Uninstall XT NTFS engine?", comment: ""), isPresented: $confirmUninstall) {
            Button(NSLocalizedString("Uninstall", comment: ""), role: .destructive) {
                Task { await model.uninstallEngine() }
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("NTFS volumes mounted by XT NTFS will be unmounted and the background service removed. You can then move the app to the Trash.", comment: ""))
        }
    }
}

struct AppearancePreview: View {
    var appearance: String
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(LinearGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom], startPoint: .top, endPoint: .bottom))
                .frame(width: 70)
            Rectangle().fill(appearance == "dark" ? Color(white: 0.18) : (appearance == "light" ? Color(white: 0.93) : Theme.detailBackground))
        }
        .frame(width: 280, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.15)))
        .overlay(alignment: .center) {
            AppGlyph(size: 46).offset(x: 35)
        }
    }
}

enum AppearanceManager {
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    var updater: SPUUpdater
    @State private var autoCheck = true
    @State private var autoDownload = false
    @State private var lastCheck: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(NSLocalizedString("Check for available updates automatically", comment: ""), isOn: $autoCheck)
                .onChange(of: autoCheck) { updater.automaticallyChecksForUpdates = $0 }
            Toggle(NSLocalizedString("Download and install updates automatically", comment: ""), isOn: $autoDownload)
                .onChange(of: autoDownload) { updater.automaticallyDownloadsUpdates = $0 }
                .disabled(!autoCheck)
            HStack {
                Button(NSLocalizedString("Check for Updates Now…", comment: "")) { updater.checkForUpdates() }
                if let lastCheck {
                    Text(String(format: NSLocalizedString("Last checked: %@", comment: ""),
                                lastCheck.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(String(format: NSLocalizedString("Current version: %@", comment: ""), XTBuild.fullVersion))
                .font(.system(size: 12))
            Text(NSLocalizedString("Updates are downloaded from GitHub Releases and verified with an EdDSA signature before installation.", comment: ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Link(NSLocalizedString("Release notes", comment: ""), destination: XTPaths.releasesPage)
                Link(NSLocalizedString("Website", comment: ""), destination: XTPaths.homepage)
            }
            .font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            autoCheck = updater.automaticallyChecksForUpdates
            autoDownload = updater.automaticallyDownloadsUpdates
            lastCheck = updater.lastUpdateCheckDate
        }
    }
}

// MARK: - Alerts

struct AlertSettings: View {
    @AppStorage(Prefs.notifyAll) private var all = true
    @AppStorage(Prefs.notifyMounts) private var mounts = true
    @AppStorage(Prefs.notifyFailures) private var failures = true
    @AppStorage(Prefs.notifyWarnings) private var warnings = true

    var body: some View {
        HStack(alignment: .top) {
            Text(NSLocalizedString("Notifications:", comment: ""))
            VStack(alignment: .leading, spacing: 9) {
                Toggle(NSLocalizedString("Notify me about all events", comment: ""), isOn: $all)
                Group {
                    Toggle(NSLocalizedString("Notify me about successful mounts", comment: ""), isOn: $mounts)
                    Toggle(NSLocalizedString("Notify me about failed mounts", comment: ""), isOn: $failures)
                    Toggle(NSLocalizedString("Notify me about hibernated or dirty volumes", comment: ""), isOn: $warnings)
                }
                .padding(.leading, 20)
                .disabled(!all)
                Button(NSLocalizedString("Open Notification Settings", comment: "")) {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .padding(.top, 8)
            }
        }
        .toggleStyle(.checkbox)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menu bar

struct MenuBarSettings: View {
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("XT NTFS Menu", comment: "")).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Circle().fill(showMenuBar ? Theme.statusRW : Color.secondary).frame(width: 8, height: 8)
                Text(showMenuBar ? NSLocalizedString("ON", comment: "") : NSLocalizedString("OFF", comment: ""))
                    .font(.system(size: 13, weight: .semibold))
                Button(showMenuBar ? NSLocalizedString("OFF", comment: "") : NSLocalizedString("ON", comment: "")) {
                    showMenuBar.toggle()
                }
                .frame(width: 110)
            }
            Text(NSLocalizedString("When ON, the menu shows your volumes and lets you mount, unmount and verify them. XT NTFS keeps running in the menu bar after you close its window.", comment: ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(NSLocalizedString("Launch on system startup", comment: ""), isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
            if let loginError {
                Text(loginError).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
