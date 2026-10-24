import SwiftUI
import XTShared

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: UpdaterBridge

    var external: [Volume] {
        model.volumes.filter { $0.isNTFS || ($0.isEjectable && !$0.isInternal) }
    }

    var body: some View {
        if external.isEmpty {
            Text(NSLocalizedString("No external volumes", comment: ""))
        }
        ForEach(external) { v in
            Menu {
                VolumeMenu(volume: v)
            } label: {
                Text(menuTitle(v))
            }
        }
        Divider()
        Text(statusLine)
        Divider()
        Button(NSLocalizedString("Open XT NTFS", comment: "")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text(NSLocalizedString("Settings…", comment: ""))
            }
            .keyboardShortcut(",")
        } else {
            Button(NSLocalizedString("Settings…", comment: "")) {
                NSApp.activate(ignoringOtherApps: true)
                AppActions.openSettings()
            }
            .keyboardShortcut(",")
        }
        Button(NSLocalizedString("Check for Updates…", comment: "")) { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button(NSLocalizedString("Quit XT NTFS", comment: "")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(_ v: Volume) -> String {
        let state: String
        switch v.status {
        case .readWrite: state = "●"
        case .readOnly: state = "◐"
        case .unmounted: state = "○"
        }
        return "\(state)  \(v.name) — \(Format.size(v.displaySize))"
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

enum AppActions {
    static func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
