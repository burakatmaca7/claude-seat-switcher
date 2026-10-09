import Foundation
import ServiceManagement

/// "Open at login" through the system's own login-item service (System Settings → General → Login Items).
/// Turned on once on first launch; after that it only changes when the user flips the toggle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item: %@", error.localizedDescription)
        }
    }

    /// First launch only: enable, so the menu is there after a restart.
    static func enableOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { set(true) }
    }
}
