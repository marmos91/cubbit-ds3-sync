import Foundation
#if os(macOS)
import ServiceManagement
#endif

/// Log subsystem identifiers for Console.app filtering
public enum LogSubsystem {
    /// Used by the main app and DS3Lib
    public static let app = "io.cubbit.DS3Drive"
    /// Used by the File Provider extension
    public static let provider = "io.cubbit.DS3Drive.provider"
}

/// Log categories for Console.app filtering
public enum LogCategory: String, Sendable {
    /// File sync operations
    case sync
    /// Authentication flow
    case auth
    /// Upload/download data transfer
    case transfer
    /// File Provider extension lifecycle
    case `extension`
    /// Main app lifecycle
    case app
    /// Metadata operations
    case metadata
}

/// Enum used to store default settings for the application
public enum DefaultSettings {
    /// The application group used to share data between the app and the file provider extension.
    /// Important: it does need to match the application group set in the app and the file provider extension's entitlements.
    public static let appGroup = "group.X889956QSM.io.cubbit.DS3Drive"

    /// Api key name prefix used to identify the api key created by the app between the ones created by the user.
    public static let apiKeyNamePrefix = "DS3Drive-for-macOS"

    /// Whether to start the app at login or not.
    public static let loginItemSet = false

    /// Whether to show the tutorial or not at startup.
    public static let tutorialShown = false

    /// Max number of drives a user can create.
    public static let maxDrives = 3

    /// Default tenant name shown in the UI when no tenant is configured.
    public static let defaultTenantName = "NGC"

    /// User defaults keys used to store data. They can be changed without breaking the app.
    public enum UserDefaultsKeys {
        public static let appUUID = "io.cubbit.DS3Drive.userDefaults.appUUID"
        public static let tutorial = "io.cubbit.DS3Drive.userDefaults.tutorialShown"
        public static let syncAnchor = "io.cubbit.DS3Drive.userDefaults.syncAnchor"
        public static let loginItemSet = "io.cubbit.DS3Drive.userDefaults.loginItemSet"
        public static let lastTenant = "io.cubbit.DS3Drive.userDefaults.lastTenant"
        public static let lastCoordinatorURL = "io.cubbit.DS3Drive.userDefaults.lastCoordinatorURL"
    }

    /// A unique identifier for the app. It is used to identify the specific app instance when creating API keys.
    /// A random UUID is created when the app starts for the first time and it is stored in the user defaults, to be retrieved at the next execution.
    public static let appUUID = {
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
    public static let appVersion: String = {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()

    /// The application build number as string. It is retrieved from the app bundle.
    public static let appBuild: String = {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }()

    /// Whether the app is set to start at login or not.
    public static let appIsLoginItem: Bool = {
        #if os(macOS)
        return SMAppService().status == .enabled
        #else
        return false
        #endif
    }()

    /// Settings related to the tray menu.
    public enum Tray {
        /// An interval to reset the drive stats in seconds.
        public static let driveStatsReset = 5.0
    }

    /// Default settings related to the FileProvider extension.
    public enum Extension {
        /// An interval to debounce the status change notifications sent by the file provider extension.
        /// It is used to avoid sending too many notifications when the status changes rapidly.
        public static let statusChangeDebounceInterval = 1.5

        /// Minimum interval between transfer speed notifications (seconds).
        /// Limits how often the tray UI refreshes during streaming downloads/uploads.
        public static let transferSpeedThrottleInterval = 0.5

        /// Minimum interval between auth failure notifications from the same drive (seconds).
        /// Prevents repeated S3 auth failures within one extension from flooding the main app.
        public static let authFailureCooldownSeconds = 30.0

        /// Interval in seconds between periodic remote change polling signals.
        public static let pollingIntervalSeconds: Int = 30
    }

    /// Default settings related to the filenames used to store data in the app group container.
    public enum FileNames {
        /// The name of the file used to store the drives list.
        public static let drivesFileName = "drives.json"

        /// The name of the file used to store the API keys list.
        public static let accountSessionFileName = "accountSession.json"

        /// The name of the file used to store the S3 credentials.
        public static let credentialsFileName = "credentials.json"

        /// The name of the file used to store the account information.
        public static let accountFileName = "account.json"

        /// The name of the file used to store the tenant name.
        public static let tenantFileName = "tenant.txt"

        /// The name of the file used to store the coordinator URL.
        public static let coordinatorURLFileName = "coordinatorURL.txt"

        /// The name of the file used to store per-drive pause state.
        public static let pauseStateFileName = "pauseState.json"

        /// The name of the file used to store per-drive trash settings.
        public static let trashSettingsFileName = "trashSettings.json"

        /// The name of the file used to signal an empty-trash request from the app to the extension.
        public static let emptyTrashFlagFileName = "emptyTrashFlag.json"
    }

    /// Group of settings related to the S3 client.
    public enum S3 {
        /// Max number of objects to retrieve in a single list request.
        public static let listBatchSize = 2000

        /// Character used as delimiter
        public static let delimiter: Character = "/"

        /// Multipart upload part size in bytes.
        public static let multipartUploadPartSize = 5 * 1024 * 1024 // 5 MB

        /// Multipart upload threshold to use multipart upload in bytes.
        public static let multipartThreshold = 5 * 1024 * 1024 // 5 MB

        /// Max number of keys per S3 DeleteObjects request (hard AWS limit).
        public static let deleteBatchSize = 1000

        /// Maximum number of concurrent part uploads during multipart upload.
        public static let multipartUploadConcurrency = 4

        /// Timeout set for the S3 requests in seconds.
        public static let timeoutInSeconds: Int64 = 5 * 60 // 5 minutes

        /// Connection timeout in seconds (shorter than request timeout for faster offline detection)
        public static let connectionTimeoutInSeconds: Int64 = 30

        /// Max number of retries for a failed request.
        public static let maxRetries = 5

        /// Seconds to wait between full BFS passes (root-to-leaf refresh cycles).
        public static let bfsCycleIntervalSeconds = 60

        /// Milliseconds to pause between BFS levels to avoid starving user operations.
        public static let bfsLevelDelayMs = 200

        /// S3 key prefix used for the trash folder inside each drive's prefix.
        public static let trashPrefix = ".trash/"
    }

    /// Settings related to the trash feature.
    public enum Trash {
        /// Default number of days to retain trashed items before auto-purge.
        public static let defaultRetentionDays = 30

        /// Interval in seconds between auto-purge cycles (1 hour).
        public static let purgeIntervalSeconds = 3600
    }

    /// Settings related to the notifications sent between the main app and the file provider extension.
    public enum Notifications {
        /// Name of the notification to send when a drive status changes
        public static let driveStatusChanged = "io.cubbit.DS3Drive.notifications.driveStatusChanged"

        /// Name of the notification to send while performing transfers
        public static let driveTransferStats = "io.cubbit.DS3Drive.notifications.driveTransferStats"

        /// Name of the notification to send when the file provider extension fails to initialize
        public static let extensionInitFailed = "io.cubbit.DS3Drive.notifications.extensionInitFailed"

        /// Name of the notification to send when a conflict is detected
        public static let conflictDetected = "io.cubbit.DS3Drive.notifications.conflictDetected"

        /// Name of the notification to send when authentication fails
        public static let authFailure = "io.cubbit.DS3Drive.notifications.authFailure"

        /// Name of the notification to send commands from the app to the extension
        public static let command = "io.cubbit.DS3Drive.notifications.command"
    }
}
