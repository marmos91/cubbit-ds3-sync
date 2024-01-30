import Foundation
import ServiceManagement

/// Set the app to start at login.
/// - Parameter value: whether to start at login.
/// - Throws: if the app cannot be registered or unregistered.
func setLoginItem(_ value: Bool) throws {
    let smAppService = SMAppService()
    
    if value {
        try smAppService.register()
    } else {
        try smAppService.unregister()
    }
}
