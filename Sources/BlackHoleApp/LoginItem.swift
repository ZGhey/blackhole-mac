import Foundation
import ServiceManagement

/// Register the app to launch at login.
///
/// `SMAppService.mainApp` needs a real bundle with a stable identity — the same
/// signing identity that keeps the Screen Recording grant alive is what makes
/// this stick too. It fails silently when run straight from `swift run`.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether it took, so the UI can avoid showing a check mark for
    /// something the system refused.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled == enabled
        } catch {
            return false
        }
    }
}
