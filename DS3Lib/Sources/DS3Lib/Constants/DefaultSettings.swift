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
    case sync
    case auth
    case transfer
    case `extension`
    case app
    case metadata
    case thumbnail
}

/// Enum used to store default settings for the application
public enum DefaultSettings {
    /// The application group used to share data between the app and the file provider extension.
    /// Important: it does need to match the application group set in the app and the file provider extension's
    /// entitlements.
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
        public static let autoCheckUpdates = "io.cubbit.DS3Drive.userDefaults.autoCheckUpdates"
        public static let lastUpdateCheck = "io.cubbit.DS3Drive.userDefaults.lastUpdateCheck"
    }

    /// A unique identifier for the app. It is used to identify the specific app instance when creating API keys.
    /// A random UUID is created when the app starts for the first time and it is stored in the user defaults, to be
    /// retrieved at the next execution.
    public static let appUUID = {
        guard let userDefaults = UserDefaults(suiteName: DefaultSettings.appGroup) else {
            return UUID().uuidString
        }

        if let uuid = userDefaults.string(forKey: DefaultSettings.UserDefaultsKeys.appUUID) {
            return uuid
        }

        let uuid = UUID().uuidString
        userDefaults.set(uuid, forKey: DefaultSettings.UserDefaultsKeys.appUUID)
        return uuid
    }()

    /// The application version number as string. It is retrieved from the app bundle.
    public static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// The application build number as string. It is retrieved from the app bundle.
    public static let appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// Whether the user has opted the app into launch-at-login. Evaluated
    /// on each access so Preferences and tutorial replay reflect changes
    /// made within the same process. Returns true for both `.enabled`
    /// and `.requiresApproval` — the latter means the user registered
    /// but still needs to confirm in System Settings → Login Items. In
    /// both cases the user has consented and the UI should reflect that.
    public static var appIsLoginItem: Bool {
        #if os(macOS)
            switch SMAppService().status {
            case .enabled, .requiresApproval:
                return true
            default:
                return false
            }
        #else
            return false
        #endif
    }

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

        /// The name of the file used to store per-drive trash settings.
        public static let trashSettingsFileName = "trashSettings.json"

        /// The name of the file used to signal an empty-trash request from the app to the extension.
        public static let emptyTrashFlagFileName = "emptyTrashFlag.json"

        /// The name of the file used to store per-drive thumbnail settings.
        public static let thumbnailSettingsFileName = "thumbnailSettings.json"
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

        /// S3 key prefix used for the thumbnails folder inside each drive's prefix.
        public static let thumbnailsPrefix = ".thumbnails/"

        /// Maximum long-edge dimension for generated thumbnails (pixels).
        public static let thumbnailMaxDimension = 512

        /// JPEG compression quality for generated thumbnails (0.0 to 1.0).
        public static let thumbnailJPEGQuality: Float = 0.7
    }

    /// Settings related to the trash feature.
    public enum Trash {
        /// Default number of days to retain trashed items before auto-purge.
        public static let defaultRetentionDays = 30

        /// Interval in seconds between auto-purge cycles (1 hour).
        public static let purgeIntervalSeconds = 3600
    }

    public enum Thumbnail {
        public static let formatVersion = 1

        // Soto prepends `x-amz-meta-` automatically; pass bare keys.
        public static let sourceETagMetadataKey = "source-etag"
        public static let formatVersionMetadataKey = "ds3drive-thumb-version"

        public static let maxSinglePartBytes = 500_000

        public static let rasterExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif"
        ]

        /// Number of pending thumbnails the BFS-tail backfill coordinator processes per pass.
        /// Per Phase 13 D-18; Phase 14+ may tune this adaptively. Sequential, thermal-gated.
        public static let backfillBatchSize: Int = 5

        /// Maximum number of orphan thumbnail keys deleted per BFS pass tail.
        /// Per Phase 13 D-26 — caps cleanup work per pass; natural BFS cadence handles the rest.
        public static let maxOrphanDeletesPerPass: Int = 50

        /// Maximum render+PUT failures before a SyncedItem transitions thumbnailStatus to .failed.
        /// Per Phase 13 D-29 — terminates retry loop on permanently unprocessable items.
        /// ETag change resets count (D-31).
        public static let maxFailStrikes: Int = 3
    }

    /// Settings related to update checking.
    public enum Update {
        /// Interval between automatic update checks (4 hours).
        public static let checkIntervalSeconds: TimeInterval = 4 * 60 * 60

        /// GitHub Releases API endpoint for the latest release.
        public static let gitHubReleasesURL = "https://api.github.com/repos/cubbit/cubbit-ds3-drive/releases/latest"
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
