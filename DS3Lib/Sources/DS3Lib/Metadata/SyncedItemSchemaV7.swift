import Foundation
import SwiftData

/// Schema version 7. Adds `thumbnailReadyAt: Date?` to SyncedItem so the
/// iOS foreground backfill driver can mark a row when its sidecar lands.
/// `WorkingSetEnumerator.enumerateChanges` re-emits those rows as `didUpdate`,
/// which forces Files.app to invalidate its per-item thumbnail cache and
/// re-fetch (issue #153).
///
/// Extracted from `SyncedItem.swift` (which is at SwiftLint's file_length
/// ceiling). New schema versions should land here or in their own files.
///
/// SyncAnchorRecord is unchanged from V2/V3/V4/V5/V6.
public enum SyncedItemSchemaV7: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(7, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
        /// `hashModifier: "v7"` forces a distinct schema checksum because V7
        /// adds a new optional field (`thumbnailReadyAt`) that SwiftData
        /// otherwise hashes identically to V6 if the column is added without
        /// the modifier — mirrors V5/V6 patterns (Pitfall 6).
        @Attribute(hashModifier: "v7") public var s3Key: String
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

        /// Set by the iOS foreground backfill driver after a sidecar PUT
        /// succeeds. Read by `WorkingSetEnumerator.enumerateChanges` to
        /// re-emit the item as `didUpdate` and trigger Files.app to
        /// invalidate its per-item thumbnail cache. Cleared back to nil
        /// after the change is reported, so the field acts as a one-shot
        /// flag rather than a permanent timestamp. Issue #153.
        public var thumbnailReadyAt: Date?

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
