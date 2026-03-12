import Foundation
import os.log

/// Errors specific to SyncEngine operations.
public enum SyncEngineError: Error, Sendable {
    case networkUnavailable
}

/// Core reconciliation orchestrator.
/// Compares S3 remote state against local MetadataStore to detect new, modified, and deleted items.
/// Tracks sync anchor advancement and consecutive failure counts.
///
/// Design decisions (from CONTEXT.md):
/// - Full reconciliation on every call (S3 listObjectsV2 vs MetadataStore diff)
/// - Hard delete SyncedItem records when remote deletion detected
/// - Threshold warning at >50% deletions (log but proceed)
/// - 3 consecutive failures = error state notified via delegate
/// - NetworkMonitor check before operations
/// - SyncEngine owns ALL MetadataStore writes during reconciliation
public actor SyncEngine {
    private let metadataStore: MetadataStore
    private let networkMonitor: NetworkMonitor
    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)
    private weak var delegate: (any SyncEngineDelegate)?

    /// Threshold: if more than this fraction of items are detected as deleted, flag mass deletion.
    private let massDeletionThreshold: Double = 0.5

    /// Number of consecutive failures before entering error state.
    private let errorStateThreshold: Int = 3

    public init(metadataStore: MetadataStore, networkMonitor: NetworkMonitor) {
        self.metadataStore = metadataStore
        self.networkMonitor = networkMonitor
    }

    /// Sets the delegate that receives sync status callbacks.
    public func setDelegate(_ delegate: any SyncEngineDelegate) {
        self.delegate = delegate
    }

    /// Performs a full reconciliation cycle for the given drive.
    ///
    /// Steps:
    /// 1. Check network connectivity
    /// 2. Fetch all remote items from S3
    /// 3. Fetch all local items from MetadataStore (as Sendable key/etag/status maps)
    /// 4. Compute new, modified, and deleted key sets
    /// 5. Check mass deletion threshold
    /// 6. Update MetadataStore (upsert new/modified, delete removed)
    /// 7. Advance sync anchor (also resets failure count)
    /// 8. Notify delegate
    ///
    /// On failure: increment failure count, notify delegate if threshold reached, re-throw.
    public func reconcile(
        driveId: UUID,
        s3Provider: some S3ListingProvider,
        bucket: String,
        prefix: String?
    ) async throws -> ReconciliationResult {
        // Step 1: Network check
        guard await networkMonitor.isConnected else {
            logger.warning("Reconciliation skipped: network unavailable for drive \(driveId.uuidString, privacy: .public)")
            throw SyncEngineError.networkUnavailable
        }

        do {
            // Step 2: Fetch remote items from S3
            let remoteItems = try await s3Provider.listAllItems(bucket: bucket, prefix: prefix)
            let remoteKeySet = Set(remoteItems.keys)

            // Step 3: Fetch local state as Sendable types
            let localKeysAndEtags = try await metadataStore.fetchItemKeysAndEtags(driveId: driveId)
            let localKeysAndStatuses = try await metadataStore.fetchItemKeysAndStatuses(driveId: driveId)
            let localKeySet = Set(localKeysAndEtags.keys)

            // Step 4: Compute diffs
            let newKeys = remoteKeySet.subtracting(localKeySet)

            let deletedKeys = computeDeletedKeys(
                localKeySet: localKeySet,
                remoteKeySet: remoteKeySet,
                localStatuses: localKeysAndStatuses
            )

            let commonKeys = remoteKeySet.intersection(localKeySet)
            let modifiedKeys = computeModifiedKeys(
                commonKeys: commonKeys,
                remoteItems: remoteItems,
                localEtags: localKeysAndEtags
            )

            // Step 5: Mass deletion check
            let localCount = localKeySet.count
            let massDeletionDetected = localCount > 0
                && Double(deletedKeys.count) > Double(localCount) * massDeletionThreshold

            if massDeletionDetected {
                logger.warning(
                    "Mass deletion detected for drive \(driveId.uuidString, privacy: .public): \(deletedKeys.count)/\(localCount) items deleted (>\(Int(self.massDeletionThreshold * 100))% threshold)"
                )
            }

            // Step 6: Update MetadataStore
            try await applyChanges(
                driveId: driveId,
                newKeys: newKeys,
                modifiedKeys: modifiedKeys,
                deletedKeys: deletedKeys,
                remoteItems: remoteItems
            )

            // Step 7: Advance sync anchor (resets failure count)
            try await metadataStore.advanceSyncAnchor(driveId: driveId, itemCount: remoteItems.count)

            // Step 8: Notify delegate
            delegate?.syncEngineDidComplete(driveId: driveId)

            let result = ReconciliationResult(
                newKeys: newKeys,
                modifiedKeys: modifiedKeys,
                deletedKeys: deletedKeys,
                remoteItems: remoteItems,
                massDeletionDetected: massDeletionDetected
            )

            logger.info(
                "Reconciliation complete for drive \(driveId.uuidString, privacy: .public): \(newKeys.count) new, \(modifiedKeys.count) modified, \(deletedKeys.count) deleted"
            )

            return result
        } catch {
            // On failure: increment failure count, check error state threshold
            let failureCount = try await metadataStore.incrementFailureCount(driveId: driveId)

            logger.error(
                "Reconciliation failed for drive \(driveId.uuidString, privacy: .public) (failure \(failureCount)/\(self.errorStateThreshold)): \(error.localizedDescription, privacy: .public)"
            )

            if failureCount >= errorStateThreshold {
                delegate?.syncEngineDidEnterErrorState(driveId: driveId, error: error)
            }

            throw error
        }
    }

    // MARK: - Private Helpers

    /// Compute which local keys should be considered deleted.
    /// Only items with syncStatus == .synced qualify for deletion detection.
    private func computeDeletedKeys(
        localKeySet: Set<String>,
        remoteKeySet: Set<String>,
        localStatuses: [String: String]
    ) -> Set<String> {
        let missingFromRemote = localKeySet.subtracting(remoteKeySet)
        return missingFromRemote.filter { key in
            localStatuses[key] == SyncStatus.synced.rawValue
        }
    }

    /// Compute which common keys have different ETags (modified remotely).
    private func computeModifiedKeys(
        commonKeys: Set<String>,
        remoteItems: [String: S3ObjectInfo],
        localEtags: [String: String?]
    ) -> Set<String> {
        Set(commonKeys.filter { key in
            let remoteEtag = remoteItems[key]?.etag
            let localEtag = localEtags[key].flatMap { $0 }
            return remoteEtag != localEtag
        })
    }

    /// Apply reconciliation changes to MetadataStore.
    /// - Upserts new and modified items with syncStatus .synced
    /// - Hard deletes removed items
    private func applyChanges(
        driveId: UUID,
        newKeys: Set<String>,
        modifiedKeys: Set<String>,
        deletedKeys: Set<String>,
        remoteItems: [String: S3ObjectInfo]
    ) async throws {
        // Upsert new and modified items
        for key in newKeys.union(modifiedKeys) {
            let info = remoteItems[key]
            try await metadataStore.upsertItem(
                s3Key: key,
                driveId: driveId,
                etag: info?.etag,
                lastModified: info?.lastModified,
                syncStatus: .synced,
                parentKey: info?.parentKey,
                contentType: info?.contentType,
                size: info?.size ?? 0
            )
        }

        // Hard delete removed items from MetadataStore
        for key in deletedKeys {
            try await metadataStore.deleteItem(byKey: key)
        }
    }
}
