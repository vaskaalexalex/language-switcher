import Foundation
import ServiceManagement

enum LoginItem {
    static func apply(_ enabled: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enabled {
                if svc.status != .enabled {
                    try svc.register()
                }
            } else {
                if svc.status == .enabled {
                    try svc.unregister()
                }
            }
        } catch {
            NSLog("[LanguageSwitcher] LoginItem.apply(\(enabled)) failed: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
