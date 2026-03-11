import Foundation
import FileProvider
import os.log

extension SharedData {
    /// Loads the saved `NSFileProviderSyncAnchor` from UserDefaults, or creates a new one if none is found. `NSFileProviderSyncAnchor` is used to track changes in the file system.
    /// - Returns: the loaded `NSFileProviderSyncAnchor`, or a new one if none is found.
    func loadSyncAnchorOrCreate() -> NSFileProviderSyncAnchor {
        if let savedSyncAnchorData = UserDefaults.standard.data(forKey: DefaultSettings.UserDefaultsKeys.syncAnchor) {
            return NSFileProviderSyncAnchor(savedSyncAnchorData)
       } else {
           let syncAnchor = NSFileProviderSyncAnchor(Date())
           self.persistSyncAnchor(syncAnchor)
           return syncAnchor
       }
    }
    
    /// Persists the given `NSFileProviderSyncAnchor` to UserDefaults.
    /// - Parameter anchor: the anchor to persist.
    func persistSyncAnchor(_ anchor: NSFileProviderSyncAnchor) {
        UserDefaults.standard.set(anchor.rawValue, forKey: DefaultSettings.UserDefaultsKeys.syncAnchor)
        UserDefaults.standard.synchronize()
    }
}
