import Foundation
import ServiceManagement

/// Enum used to store default settings for the application
enum DefaultSettings {
    /// The application group used to share data between the app and the file provider extension.
    /// Important: it does need to match the application group set in the app and the file provider extension's entitlements.
    static let appGroup = "group.io.cubbit.CubbitDS3Sync"
    
    /// Api key name prefix used to identify the api key created by the app between the ones created by the user.
    static let apiKeyNamePrefix = "DS3Sync-for-macOS"
    
    /// Wheter to start the app at login or not.
    static let loginItemSet = false
    
    /// Wheter to show the tutorial or not at startup.
    static let tutorialShown = false
    
    /// Max number of drives an user can create.
    static let maxDrives = 3
    
    /// User defaults keys used to store data. They can be changed without breaking the app.
    enum UserDefaultsKeys {
        static let appUUID = "io.cubbit.CubbitDS3Sync.userDefaults.appUUID"
        static let tutorial = "io.cubbit.CubbitDS3Sync.userDefaults.tutorialShown"
        static let syncAnchor = "io.cubbit.CubbitDS3Sync.userDefaults.syncAnchor"
        static let loginItemSet = "io.cubbit.CubbitDS3Sync.userDefaults.loginItemSet"
    }
    
    /// An unique identifier for the app. It is used to identify the specific app instance when creating API keys.
    /// A random UUID is created when the app starts for the first time and it is stored in the user defaults, to be retrieved at the next execution.
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
    
    /// The application version number as string. It is retrieved from the app bundle.
    static let appVersion: String = {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()
    
    /// The application build number as string. It is retrieved from the app bundle.
    static let appBuild: String = {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }()
    
    /// Whether the app is set to start at login or not.
    static let appIsLoginItem: Bool = {
        return SMAppService().status.rawValue == 1
    }()
    
    /// Settings related to the tray menu.
    enum Tray {
        // An interval to reset the drive stats in seconds.
        static let driveStatsReset = 5.0
    }
    
    /// Default settings related to the FileProvider extension.
    enum Extension {
        /// An interval to debounce the status change notifications sent by the file provider extension.
        /// It is used to avoid sending too many notifications when the status changes rapidly.
        static let statusChangeDebounceInterval = 1.5
    }
    
    /// Default settings related to the filenames used to store data in the app group container.
    enum FileNames {
        /// The name of the file used to store the drives list.
        static let drivesFileName = "drives.json"
        
        /// The name of the file used to store the API keys list.
        static let accountSessionFileName = "accountSession.json"
        
        /// The name of the file used to store the S3 credentials.
        static let credentialsFileName = "credentials.json"
        
        /// The name of the file used to store the account information.
        static let accountFileName = "account.json"
    }
    
    /// Group of settings related to the S3 client.
    enum S3 {
        /// Max number of objects to retrieve in a single list request.
        static let listBatchSize = 2000
        
        /// Character used as delimiter
        static let delimiter: Character = "/"
        
        /// Multipart upload part size in bytes.
        static let multipartUploadPartSize = 5 * 1024 * 1024 // 5 MB
        
        /// Multipart upload threshold to use multipart upload in bytes.
        static let multipartThreshold = 5 * 1024 * 1024 // 5 MB
        
        /// Timeout set for the S3 requests in seconds.
        static let timeoutInSeconds: Int64 = 5 * 60 // 5 minutes
        
        /// Max number of retries for a failed request.
        static let maxRetries = 5
    }
    
    /// Settings related to the notifications sent between the main app and the file provider extension.
    enum Notifications {
        /// Name of the notification to send when a drive status changes
        static let driveStatusChanged = "io.cubbit.CubbitDS3Sync.notifications.driveStatusChanged"
        
        /// Name of the notification to send while performing transfers
        static let driveTransferStats = "io.cubbit.CubbitDS3Sync.notifications.driveTransferStats"
    }
}
