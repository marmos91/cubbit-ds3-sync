import Foundation
import SwiftData

/// Schema version 1 for the SyncedItem metadata model.
/// Uses VersionedSchema from day one for explicit migration management.
public enum SyncedItemSchemaV1: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self]
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
        @Transient public var status: SyncStatus {
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
    public nonisolated static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per drive, not globally)
        public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// Composite unique key: "driveId:s3Key". Ensures uniqueness per drive.
        @Attribute(.unique) public var uniqueKey: String

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
        @Transient public var status: SyncStatus {
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

        /// The original S3 key before the item was trashed. Nil for non-trashed items.
        /// Used by TrashS3Enumerator to return the correct identifier so the system
        /// can match trashed items with their original location for "Recover".
        public var originalKey: String?

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
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
    case trashed

    /// Whether this status represents an in-progress or failure state that
    /// should not be silently overwritten by a default `.synced` upsert.
    public var isTransient: Bool {
        switch self {
        case .error, .syncing, .conflict:
            true
        case .pending, .synced, .trashed:
            false
        }
    }
}

public enum ThumbnailStatus: String, Codable, Sendable {
    case notApplicable
    case pending
    case uploaded
    case failed
}

public enum SyncedItemSchemaV3: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    /// SyncAnchorRecord is unchanged from V2; reusing the same @Model class
    /// avoids SwiftData "failed to cast model" traps when fetching pre-existing
    /// rows after migration.
    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per drive, not globally)
        public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// Composite unique key: "driveId:s3Key". Ensures uniqueness per drive.
        @Attribute(.unique) public var uniqueKey: String

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
        @Transient public var status: SyncStatus {
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

        /// The original S3 key before the item was trashed. Nil for non-trashed items.
        /// Used by TrashS3Enumerator to return the correct identifier so the system
        /// can match trashed items with their original location for "Recover".
        public var originalKey: String?

        public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

        @Transient public var thumbnail: ThumbnailStatus {
            get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
            set { thumbnailStatus = newValue.rawValue }
        }

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue,
            thumbnailStatus: String = ThumbnailStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
            self.thumbnailStatus = thumbnailStatus
        }
    }
}

/// Schema version 4 for the SyncedItem metadata model.
/// Adds `thumbnailFailCount: Int = 0` to SyncedItem (Phase 13 D-29).
/// Per Pitfall 10, the strike rule is `count >= maxFailStrikes` (3 strikes →
/// `.failed`); reset condition is the original ETag changing on upsert (D-31).
public enum SyncedItemSchemaV4: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    /// SyncAnchorRecord is unchanged from V2/V3; reusing the same @Model class
    /// avoids SwiftData "failed to cast model" traps (verified V3 pattern).
    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per drive, not globally)
        public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// Composite unique key: "driveId:s3Key". Ensures uniqueness per drive.
        @Attribute(.unique) public var uniqueKey: String

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
        @Transient public var status: SyncStatus {
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
        public var isMaterialized: Bool = false

        /// The original S3 key before the item was trashed. Nil for non-trashed items.
        public var originalKey: String?

        public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

        @Transient public var thumbnail: ThumbnailStatus {
            get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
            set { thumbnailStatus = newValue.rawValue }
        }

        /// Number of consecutive thumbnail render+PUT failures. Incremented by
        /// `MetadataStore.setThumbnailFailure` on each failure; transitions
        /// `thumbnailStatus` to `.failed` when `>= DefaultSettings.Thumbnail.maxFailStrikes`
        /// (3). Reset to 0 by the upsert path when the persisted ETag differs
        /// from the freshly-listed ETag (D-31). Phase 13 D-29.
        public var thumbnailFailCount: Int = 0

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue,
            thumbnailStatus: String = ThumbnailStatus.pending.rawValue,
            thumbnailFailCount: Int = 0
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
            self.thumbnailStatus = thumbnailStatus
            self.thumbnailFailCount = thumbnailFailCount
        }
    }
}

/// Schema version 5. Drops `thumbnailFailCount` (Phase 13.2 D-05, D-06, D-07).
///
/// The 3-strike rule moved to `ThumbnailFallbackLimiter` (in-memory, reset on
/// extension launch — see Phase 13.2 D-19). Persisting strike state in
/// SwiftData was the wrong granularity once the BFS-driven coordinator was
/// removed (Plan 06 + 07).
///
/// `thumbnailStatus` survives until V6 (Plan 09) because the upload-hook in
/// `ThumbnailUploader` still writes `.notApplicable` / `.uploaded` to it
/// through Plan 08; D-08 removes those writes in the same plan that ships V6.
public enum SyncedItemSchemaV5: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(5, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    /// SyncAnchorRecord is unchanged from V2/V3/V4; reusing the same @Model class
    /// avoids SwiftData "failed to cast model" traps (verified V3+V4 pattern,
    /// Pitfall 3 from PATTERNS.md).
    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        /// The full S3 object key (unique per drive, not globally).
        ///
        /// `hashModifier: "v5"` forces a distinct schema checksum for V5 — V5
        /// is structurally identical to V3 (V3 has all V5 fields, V4 added
        /// `thumbnailFailCount`, V5 dropped it back). Without this modifier
        /// SwiftData throws "Duplicate version checksums across stages" when
        /// the migration plan references both V3 and V5. Phase 13.2 D-06.
        @Attribute(hashModifier: "v5") public var s3Key: String

        /// The drive this item belongs to (explicit, not inferred from bucket/prefix)
        public var driveId: UUID

        /// Composite unique key: "driveId:s3Key". Ensures uniqueness per drive.
        @Attribute(.unique) public var uniqueKey: String

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
        @Transient public var status: SyncStatus {
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
        public var isMaterialized: Bool = false

        /// The original S3 key before the item was trashed. Nil for non-trashed items.
        public var originalKey: String?

        public var thumbnailStatus: String = ThumbnailStatus.pending.rawValue

        @Transient public var thumbnail: ThumbnailStatus {
            get { ThumbnailStatus(rawValue: thumbnailStatus) ?? .pending }
            set { thumbnailStatus = newValue.rawValue }
        }

        // thumbnailFailCount: REMOVED in V5 (Phase 13.2 D-05). The 3-strike rule
        // lives in ThumbnailFallbackLimiter as in-memory state (D-19, D-20).

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue,
            thumbnailStatus: String = ThumbnailStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
            self.thumbnailStatus = thumbnailStatus
        }
    }
}

/// Schema version 6. Drops `thumbnailStatus` + the `thumbnail` transient
/// (Phase 13.2 D-05, D-08, D-23). With the BFS coordinator + sweeper gone
/// (Plans 06, 07), upload-hook `.notApplicable` / `.uploaded` writes removed
/// (Plan 09 / D-08), and `consumeThumbnail`'s `markPending` parameter stripped
/// (Plan 09), no consumer remains. "Is the thumbnail uploaded?" is now
/// answered by S3 itself via `getThumbnailBytes` (bytes or nil).
public enum SyncedItemSchemaV6: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(6, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        /// `hashModifier: "v6"` forces a distinct schema checksum because V6
        /// is structurally identical to V2 (V3 added `thumbnailStatus`, V4
        /// added `thumbnailFailCount`, V5 dropped fail count, V6 drops status).
        /// Without this modifier SwiftData throws "Duplicate version checksums
        /// across stages" (Phase 13.2 D-06, mirrors V5).
        @Attribute(hashModifier: "v6") public var s3Key: String
        public var driveId: UUID
        @Attribute(.unique) public var uniqueKey: String
        public var etag: String?
        public var lastModified: Date?
        public var localFileHash: String?
        public var syncStatus: String
        @Transient public var status: SyncStatus {
            get { SyncStatus(rawValue: syncStatus) ?? .pending }
            set { syncStatus = newValue.rawValue }
        }
        public var parentKey: String?
        public var contentType: String?
        public var size: Int64
        public var isMaterialized: Bool = false
        public var originalKey: String?
        // thumbnailStatus + thumbnail transient: REMOVED in V6 (D-05, D-08, D-23).

        public init(
            s3Key: String,
            driveId: UUID,
            size: Int64 = 0,
            syncStatus: String = SyncStatus.pending.rawValue
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.uniqueKey = "\(driveId.uuidString):\(s3Key)"
            self.size = size
            self.syncStatus = syncStatus
        }
    }
}

/// Migration plan for SyncedItem schema versions.
public enum SyncedItemMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            SyncedItemSchemaV1.self,
            SyncedItemSchemaV2.self,
            SyncedItemSchemaV3.self,
            SyncedItemSchemaV4.self,
            SyncedItemSchemaV5.self,
            SyncedItemSchemaV6.self,
            SyncedItemSchemaV7.self
        ]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7]
    }

    /// Lightweight migration from V1 to V2:
    /// - Adds isMaterialized (Bool, default false) to SyncedItem
    /// - Adds SyncAnchorRecord as a new entity
    /// - Adds originalKey (String?, default nil) to SyncedItem
    nonisolated static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV1.self,
        toVersion: SyncedItemSchemaV2.self
    )

    nonisolated static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV2.self,
        toVersion: SyncedItemSchemaV3.self
    )

    /// Lightweight migration from V3 to V4:
    /// - Adds thumbnailFailCount (Int, default 0) to SyncedItem (Phase 13 D-29)
    nonisolated static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV3.self,
        toVersion: SyncedItemSchemaV4.self
    )

    /// Lightweight migration from V4 to V5 (Phase 13.2 D-05, D-06, D-07):
    /// - Drops `thumbnailFailCount` from SyncedItem.
    /// SwiftData "remove field" migrations are an under-trodden path; validated
    /// by `SchemaV5MigrationTests` against a seeded V4 store.
    nonisolated static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV4.self,
        toVersion: SyncedItemSchemaV5.self
    )

    /// Lightweight migration from V5 to V6 (Phase 13.2 D-05, D-08, D-23):
    /// - Drops `thumbnailStatus` from SyncedItem.
    /// Final schema cleanup of the thumbnail subsystem — after Plan 09 no
    /// thumbnail-specific SwiftData fields remain. Validated by
    /// `SchemaV6MigrationTests` against a seeded V5 store.
    nonisolated static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV5.self,
        toVersion: SyncedItemSchemaV6.self
    )

    /// Lightweight migration from V6 to V7:
    /// - Adds `isPinned` (Bool, default false) to SyncedItem.
    nonisolated static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: SyncedItemSchemaV6.self,
        toVersion: SyncedItemSchemaV7.self
    )
}

/// Type alias for the current schema version's SyncedItem.
/// (`SyncAnchorRecord` typealias lives in `SyncAnchorRecord.swift`.)
public typealias SyncedItem = SyncedItemSchemaV7.SyncedItem
