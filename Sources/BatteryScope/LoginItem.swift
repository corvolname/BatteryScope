import Foundation
import ServiceManagement

/// "Launch at login" via `SMAppService`, guarded so a failure surfaces as a message rather
/// than a crash. macOS also refuses to register an app that is running from a translocated
/// or read-only location, which is exactly the case this reports on.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func update(enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
