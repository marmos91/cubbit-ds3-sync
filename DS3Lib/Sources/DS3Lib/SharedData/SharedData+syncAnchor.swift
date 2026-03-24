import FileProvider
import Foundation
import os.log

extension SharedData {
    private static let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    /// Returns the App Group UserDefaults, falling back to standard if unavailable.
    private static var syncAnchorDefaults: UserDefaults {
        if let defaults = UserDefaults(suiteName: DefaultSettings.appGroup) {
            return defaults
        }
        logger.warning("App Group UserDefaults unavailable, falling back to standard")
        return .standard
    }

    /// Loads the saved `NSFileProviderSyncAnchor` from UserDefaults, or creates a new one if none is found.
    /// `NSFileProviderSyncAnchor` is used to track changes in the file system.
    /// - Returns: the loaded `NSFileProviderSyncAnchor`, or a new one if none is found.
    public func loadSyncAnchorOrCreate() -> NSFileProviderSyncAnchor {
        if let savedSyncAnchorData = Self.syncAnchorDefaults.data(forKey: DefaultSettings.UserDefaultsKeys.syncAnchor) {
            return NSFileProviderSyncAnchor(savedSyncAnchorData)
        }
        let syncAnchor = NSFileProviderSyncAnchor(SyncAnchorPayload())
        self.persistSyncAnchor(syncAnchor)
        return syncAnchor
    }

    /// Persists the given `NSFileProviderSyncAnchor` to UserDefaults.
    /// - Parameter anchor: the anchor to persist.
    public func persistSyncAnchor(_ anchor: NSFileProviderSyncAnchor) {
        Self.syncAnchorDefaults.set(anchor.rawValue, forKey: DefaultSettings.UserDefaultsKeys.syncAnchor)
    }
}
