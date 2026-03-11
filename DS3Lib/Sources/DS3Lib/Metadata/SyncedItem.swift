import Foundation
import SwiftData

/// Schema version 1 for the SyncedItem metadata model.
/// Uses VersionedSchema from day one for explicit migration management.
public enum SyncedItemSchemaV1: VersionedSchema {
    nonisolated(unsafe) public static var versionIdentifier = Schema.Version(1, 0, 0)
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

        /// Current sync status: pending, syncing, synced, error, conflict
        public var syncStatus: String

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
    public static var schemas: [any VersionedSchema.Type] { [SyncedItemSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// Type alias for the current schema version's SyncedItem.
public typealias SyncedItem = SyncedItemSchemaV1.SyncedItem
