import Foundation
import UserNotifications
import XTShared

/// Posts user notifications for engine events, honouring the settings in
/// "Alerts & Notifications".
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ event: HelperEvent) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Prefs.notifyAll) else { return }
        switch event.kind {
        case .mounted, .unmounted:
            guard d.bool(forKey: Prefs.notifyMounts) else { return }
        case .mountFailed:
            guard d.bool(forKey: Prefs.notifyFailures) else { return }
        case .hibernated, .dirty:
            guard d.bool(forKey: Prefs.notifyWarnings) else { return }
        case .info:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = title(for: event)
        content.body = NSLocalizedString(event.message, comment: "")
        if event.kind == .mountFailed { content.sound = .default }
        let request = UNNotificationRequest(identifier: "xtntfs.event.\(event.id).\(event.date.timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func title(for e: HelperEvent) -> String {
        let name = e.volumeName ?? e.bsdName ?? "NTFS"
        switch e.kind {
        case .mounted: return String(format: NSLocalizedString("“%@” is ready", comment: ""), name)
        case .unmounted: return String(format: NSLocalizedString("“%@” was unmounted", comment: ""), name)
        case .mountFailed: return String(format: NSLocalizedString("Could not mount “%@”", comment: ""), name)
        case .hibernated: return String(format: NSLocalizedString("“%@” is hibernated by Windows", comment: ""), name)
        case .dirty: return String(format: NSLocalizedString("“%@” needs attention", comment: ""), name)
        case .info: return "XT NTFS"
        }
    }
}

/// UserDefaults keys for app-side preferences.
enum Prefs {
    static let appearance = "appearance"            // "system" | "light" | "dark"
    static let showMenuBar = "showMenuBar"
    static let notifyAll = "notifyAll"
    static let notifyMounts = "notifyMounts"
    static let notifyFailures = "notifyFailures"
    static let notifyWarnings = "notifyWarnings"
    static let benchmarkSize = "benchmarkSizeMB"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appearance: "system",
            showMenuBar: true,
            notifyAll: true,
            notifyMounts: true,
            notifyFailures: true,
            notifyWarnings: true,
            benchmarkSize: 1024,
        ])
    }
}
