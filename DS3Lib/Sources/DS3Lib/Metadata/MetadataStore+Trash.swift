import Foundation
import SwiftData

// MARK: - Trash Operations

public extension MetadataStore {
    func recordTrash(
        trashKey: String,
        originalKey: String,
        driveId: UUID,
        size: Int64
    ) throws {
        let now = Date()
        if let existing = try findItem(byKey: trashKey, driveId: driveId) {
            existing.originalKey = originalKey
            existing.syncStatus = SyncStatus.trashed.rawValue
            existing.size = size
            existing.lastModified = now
        } else {
            let item = SyncedItem(
                s3Key: trashKey,
                driveId: driveId,
                size: size,
                syncStatus: SyncStatus.trashed.rawValue
            )
            item.originalKey = originalKey
            item.lastModified = now
            modelExecutor.modelContext.insert(item)
        }
        try modelExecutor.modelContext.save()
    }

    struct TrashedItemInfo: Sendable {
        public let trashKey: String
        public let originalKey: String
        public let size: Int64
        public let trashedAt: Date?
    }

    func fetchTrashedItems(driveId: UUID) throws -> [TrashedItemInfo] {
        try fetchItems(driveId: driveId, status: .trashed).compactMap {
            guard let originalKey = $0.originalKey else { return nil }
            return TrashedItemInfo(
                trashKey: $0.s3Key,
                originalKey: originalKey,
                size: $0.size,
                trashedAt: $0.lastModified
            )
        }
    }

    func fetchOriginalKey(forTrashKey trashKey: String, driveId: UUID) throws -> String? {
        try findItem(byKey: trashKey, driveId: driveId)?.originalKey
    }

    func fetchTrashKey(forOriginalKey originalKey: String, driveId: UUID) throws -> String? {
        let statusValue = SyncStatus.trashed.rawValue
        let predicate = #Predicate<SyncedItem> {
            $0.driveId == driveId && $0.syncStatus == statusValue && $0.originalKey == originalKey
        }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncedItem>(predicate: predicate)).first?.s3Key
    }

    func removeTrashRecord(trashKey: String, driveId: UUID) throws {
        try deleteItem(byKey: trashKey, driveId: driveId)
    }

    func removeAllTrashRecords(driveId: UUID) throws {
        let items = try fetchItems(driveId: driveId, status: .trashed)
        if items.isEmpty { return }
        for item in items {
            modelExecutor.modelContext.delete(item)
        }
        try modelExecutor.modelContext.save()
    }
}
