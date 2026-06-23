import Foundation
import ServiceManagement

/// Launch-at-login toggle via the modern SMAppService API.
enum LoginItem {
    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoginItem toggle failed: \(error)")
        }
    }
}
