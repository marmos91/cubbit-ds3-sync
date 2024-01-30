import SwiftUI

/// Manages the status of the app.
@Observable class AppStatusManager {
    static var instance: AppStatusManager?
    
    var status: AppStatus = .idle
    
    private init() {}
    
    /// The default instance of the AppStatusManager.
    /// - Returns: the default instance of the AppStatusManager.
    static public func `default`() -> AppStatusManager {
        if AppStatusManager.instance == nil {
            AppStatusManager.instance = AppStatusManager()
        }
        
        return AppStatusManager.instance!
    }
}
