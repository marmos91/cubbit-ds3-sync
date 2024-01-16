import Foundation
import FileProvider
import os.log

extension SharedData {
    func loadSyncAnchorOrCreate() -> NSFileProviderSyncAnchor {
        if let savedSyncAnchorData = UserDefaults.standard.data(forKey: DefaultSettings.UserDefaultsKeys.syncAnchor) {
            return NSFileProviderSyncAnchor(savedSyncAnchorData)
       } else {
           let syncAnchor = NSFileProviderSyncAnchor(Date())
           self.persistSyncAnchor(syncAnchor)
           return syncAnchor
       }
    }
    
    func persistSyncAnchor(_ anchor: NSFileProviderSyncAnchor) {
        UserDefaults.standard.set(anchor.rawValue, forKey: DefaultSettings.UserDefaultsKeys.syncAnchor)
        UserDefaults.standard.synchronize()
    }
}
