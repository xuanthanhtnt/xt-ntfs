import SwiftUI
import AppKit
import Combine
import Sparkle
import UserNotifications
import XTShared

/// Publishes Sparkle's "can check" state for SwiftUI menus.
final class UpdaterBridge: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    var updater: SPUUpdater { controller.updater }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        AppearanceManager.apply(UserDefaults.standard.string(forKey: Prefs.appearance) ?? "system")
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.showMenuBar)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    // Show notifications even when the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct XTNTFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updater = UpdaterBridge()
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("XT NTFS", id: "main") {
            MainView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(NSLocalizedString("Check for Updates…", comment: "")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) {
                Button(NSLocalizedString("XT NTFS Website", comment: "")) { NSWorkspace.shared.open(XTPaths.homepage) }
                Button(NSLocalizedString("Show Engine Log", comment: "")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: XTPaths.logPath))
                }
            }
        }

        Settings {
            SettingsView(updater: updater.updater)
                .environmentObject(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView(updater: updater)
                .environmentObject(model)
        } label: {
            Image(systemName: model.volumes.contains { $0.mountedByXT } ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
        }
    }
}
