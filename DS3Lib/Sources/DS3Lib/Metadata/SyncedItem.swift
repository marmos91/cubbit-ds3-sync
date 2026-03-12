import Foundation
import SwiftData

/// Schema version 1 for the SyncedItem metadata model.
/// Uses VersionedSchema from day one for explicit migration management.
public enum SyncedItemSchemaV1: VersionedSchema {
    nonisolated(unsafe) public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [SyncedItem.self] }

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per item across all drives)
        @Attribute(.unique) public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// S3 ETag for version tracking
        public var etag: String?

        /// S3 LastModified timestamp
        public var lastModified: Date?

        /// Local file content hash for change detection
        public var localFileHash: String?

        /// Current sync status stored as raw string for SwiftData compatibility.
        /// Use `status` computed property for type-safe access.
        public var syncStatus: String

        /// Type-safe accessor for `syncStatus`.
        @Transient
        public var status: SyncStatus {
            get { SyncStatus(rawValue: syncStatus) ?? .pending }
            set { syncStatus = newValue.rawValue }
        }

        /// Parent S3 key (folder containing this item)
        public var parentKey: String?

        /// MIME content type
        public var contentType: String?

        /// File size in bytes
        public var size: Int64

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.size = size
            self.syncStatus = syncStatus
        }
    }
}

/// Schema version 2 for the SyncedItem metadata model.
/// Adds isMaterialized field to SyncedItem and introduces SyncAnchorRecord entity.
public enum SyncedItemSchemaV2: VersionedSchema {
    nonisolated(unsafe) public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per item across all drives)
        @Attribute(.unique) public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// S3 ETag for version tracking
        public var etag: String?

        /// S3 LastModified timestamp
        public var lastModified: Date?

        /// Local file content hash for change detection
        public var localFileHash: String?

        /// Current sync status stored as raw string for SwiftData compatibility.
        /// Use `status` computed property for type-safe access.
        public var syncStatus: String

        /// Type-safe accessor for `syncStatus`.
        @Transient
        public var status: SyncStatus {
            get { SyncStatus(rawValue: syncStatus) ?? .pending }
            set { syncStatus = newValue.rawValue }
        }

        /// Parent S3 key (folder containing this item)
        public var parentKey: String?

        /// MIME content type
        public var contentType: String?

        /// File size in bytes
        public var size: Int64

        /// Whether this item has been downloaded locally (for display purposes only).
        /// Defaults to false. Added in V2.
        public var isMaterialized: Bool = false

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.size = size
            self.syncStatus = syncStatus
            self.isMaterialized = false
        }
    }

    /// Per-drive sync anchor tracking entity.
    /// Stores the last sync date, failure count, and item count for each drive.
    @Model
    public final class SyncAnchorRecord {
        /// The drive this anchor belongs to (unique per drive)
        @Attribute(.unique) public var driveId: UUID

        /// The timestamp of the last sync attempt
        public var lastSyncDate: Date

        /// The timestamp of the last successful sync (nil if never succeeded)
        public var lastSuccessfulSync: Date?

        /// Number of consecutive sync failures (resets on success)
        public var consecutiveFailures: Int = 0

        /// Number of items tracked for this drive
        public var itemCount: Int = 0

        public init(driveId: UUID, lastSyncDate: Date = Date()) {
            self.driveId = driveId
            self.lastSyncDate = lastSyncDate
        }
    }
}

/// Sync status values as a Swift enum with raw string values.
public enum SyncStatus: String, Codable, Sendable {
    case pending
    case syncing
    case synced
    case error
    case conflict
}

/// Migration plan for SyncedItem schema versions.
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SyncedItemSchemaV1.self, SyncedItemSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Lightweight migration from V1 to V2:
    /// - Adds isMaterialized (Bool, default false) to SyncedItem
    /// - Adds SyncAnchorRecord as a new entity
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self,
        toVersion: SyncedItemSchemaV2.self
    )
}

/// Type alias for the current schema version's SyncedItem.
public typealias SyncedItem = SyncedItemSchemaV2.SyncedItem
