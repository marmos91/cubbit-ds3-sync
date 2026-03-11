import SwiftUI
import os.log

/// Manages the global status of the app, displayed in the menu bar tray icon.
@Observable public final class AppStatusManager: @unchecked Sendable {
    static var instance: AppStatusManager?

    @ObservationIgnored
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    /// The current app status (idle, syncing, error, offline, info)
    public var status: AppStatus = .idle

    private init() {}

    /// The default singleton instance of the AppStatusManager.
    /// - Returns: the default instance of the AppStatusManager.
    public static func `default`() -> AppStatusManager {
        if AppStatusManager.instance == nil {
            AppStatusManager.instance = AppStatusManager()
        }

        return AppStatusManager.instance!
    }
}
