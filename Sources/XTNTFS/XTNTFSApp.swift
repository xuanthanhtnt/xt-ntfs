import SwiftUI
import AppKit
import Combine
import Sparkle
import UserNotifications
import XTShared

/// How the app ends. With the menu bar icon on, quitting from the app menu,
/// the Dock or ⌘Q only closes the window and the Dock icon: XT NTFS keeps
/// running in the menu bar (like Paragon's menu). "Quit XT NTFS" in the
/// menu bar panel, an update, a log out or a shutdown really quit.
enum AppLifecycle {
    static var quitForReal = false

    static var menuBarEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.showMenuBar) }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Quit for real (menu bar panel).
    static func quit() {
        quitForReal = true
        NSApp.terminate(nil)
    }

    /// Hide every window and the Dock icon; keep running in the menu bar.
    static func moveToMenuBar() {
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) {
            w.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Bring back the Dock icon and the main window (if it still exists).
    static func showApp() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// True when macOS asks the app to quit for a log out, restart or shutdown.
    static var systemIsEndingSession: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue
        else { return false }
        let ending: [OSType] = [OSType(kAEShutDown), OSType(kAERestart), OSType(kAELogOut), OSType(kAEReallyLogOut)]
        return ending.contains(reason)
    }
}

/// Lets Sparkle quit the app to install an update.
final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        AppLifecycle.quitForReal = true
    }
}

/// Publishes Sparkle's "can check" state for SwiftUI menus.
final class UpdaterBridge: ObservableObject {
    let controller: SPUStandardUpdaterController
    private let delegate = SparkleDelegate()
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
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
        // Closing the main window leaves the app in the menu bar only.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { note in
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") == true,
                  AppLifecycle.menuBarEnabled else { return }
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppLifecycle.menuBarEnabled
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppLifecycle.quitForReal || !AppLifecycle.menuBarEnabled || AppLifecycle.systemIsEndingSession {
            return .terminateNow
        }
        AppLifecycle.moveToMenuBar()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opened again from Finder, Spotlight or the Dock: show the window.
        AppLifecycle.showApp()
        return AppLifecycle.mainWindow == nil
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
        .menuBarExtraStyle(.window)
    }
}
