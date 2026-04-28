import Foundation
import SwiftData

/// Schema version 7. Adds `isPinned` (Bool, default false) so the working-set
/// enumerator can return user-pinned items alongside materialised ones without
/// walking the remote tree (enumeration rewrite).
public enum SyncedItemSchemaV7: VersionedSchema {
    public nonisolated static let versionIdentifier = Schema.Version(7, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [SyncedItem.self, SyncAnchorRecord.self]
    }

    public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord

    @Model
    public final class SyncedItem {
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
        public var isPinned: Bool = false
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
}
