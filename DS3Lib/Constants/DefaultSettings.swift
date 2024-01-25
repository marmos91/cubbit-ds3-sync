import Foundation
import ServiceManagement

enum DefaultSettings {
    static let appGroup = "group.io.cubbit.CubbitDS3Sync"
    static let apiKeyNamePrefix = "DS3Sync-for-macOS"
    
    static let syncSetup = false
    static let loginItemSet = false
    static let tutorialShown = false
    
    static let maxDrives = 3
    
    enum UserDefaultsKeys {
        static let appUUID = "appUUID"
        static let tutorial = "tutorialShown"
        static let syncAnchor = "syncAnchor"
        static let loginItemSet = "loginItemSet"
    }
    
    static let appUUID = {
        if let userDefaults = UserDefaults(suiteName: DefaultSettings.appGroup) {
            if let uuid = userDefaults.string(forKey: DefaultSettings.UserDefaultsKeys.appUUID) {
                return uuid
            } else {
                let uuid = UUID().uuidString
                userDefaults.set(uuid, forKey: DefaultSettings.UserDefaultsKeys.appUUID)
                return uuid
            }
        } else {
            return UUID().uuidString
        }
    }()
    
    static let appVersion: String = {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()
    
    static let appIsLoginItem: Bool = {
        return SMAppService().status.rawValue == 1
    }()
    
    enum Extension {
        static let payloadsFolderName = "payloads"
        static let statusChangeDebounceInterval = 1.5
    }
    
    enum FileNames {
        static let drivesFileName = "drives.json"
        static let accountSessionFileName = "accountSession.json"
        static let credentialsFileName = "credentials.json"
        static let accountFileName = "account.json"
    }
    
    enum S3 {
        static let listBatchSize = 2000
        static let delimiter: Character = "/"
        static let multipartUploadPartSize = 5 * 1024 * 1024
        static let multipartThreshold = 5 * 1024 * 1024
        static let timeoutInSeconds: Int64 = 5 * 60
        static let maxRetries = 5
    }
    
    enum Notifications {
        static let driveChanged = "io.cubbit.CubbitDS3Sync.notifications.driveChanged"
    }
}
