import SwiftUI
import os.log

/// Manages the status of the app.
@Observable final class AppStatusManager {
    static var instance: AppStatusManager?

    @ObservationIgnored
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

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
