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

    // Performs a paginated reconciliation cycle for the given drive.
    // Streams S3 listing pages and diffs each page against MetadataStore incrementally,
    // avoiding loading the full remote state into memory for large buckets.
    //
    // Note: new/modified items are applied per-page, but the sync anchor is only
    // advanced after all pages complete. If the extension is terminated mid-pagination,
    // already-applied changes will be re-processed on the next cycle (idempotent upserts).
    // swiftlint:disable:next function_body_length
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
            // Step 2: Fetch local state
            let localKeysAndEtags = try await metadataStore.fetchItemKeysAndEtags(driveId: driveId)
            let localKeysAndStatuses = try await metadataStore.fetchItemKeysAndStatuses(driveId: driveId)
            let localKeySet = Set(localKeysAndEtags.keys)

            var allNewKeys = Set<String>()
            var allModifiedKeys = Set<String>()
            var allRemoteItems: [String: S3ObjectInfo] = [:]
            var seenRemoteKeys = Set<String>()
            var totalRemoteCount = 0

            // Step 3: Stream pages from S3 and diff incrementally
            var continuationToken: String?
            repeat {
                let page = try await s3Provider.listItemsPage(
                    bucket: bucket, prefix: prefix, continuationToken: continuationToken
                )

                let pageKeys = Set(page.items.keys)
                seenRemoteKeys.formUnion(pageKeys)
                totalRemoteCount += page.items.count

                let pageNewKeys = pageKeys.subtracting(localKeySet)
                allNewKeys.formUnion(pageNewKeys)

                let pageModifiedKeys = computeModifiedKeys(
                    commonKeys: pageKeys.intersection(localKeySet),
                    remoteItems: page.items,
                    localEtags: localKeysAndEtags
                )
                allModifiedKeys.formUnion(pageModifiedKeys)

                for key in pageNewKeys.union(pageModifiedKeys) {
                    allRemoteItems[key] = page.items[key]
                }

                try await applyChanges(
                    driveId: driveId,
                    newKeys: pageNewKeys,
                    modifiedKeys: pageModifiedKeys,
                    deletedKeys: [],
                    remoteItems: page.items
                )

                continuationToken = page.continuationToken
            } while continuationToken != nil

            // Step 4: Compute deletions
            let deletedKeys = computeDeletedKeys(
                localKeySet: localKeySet,
                remoteKeySet: seenRemoteKeys,
                localStatuses: localKeysAndStatuses
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

            // Step 6: Apply deletions
            try await applyChanges(
                driveId: driveId,
                newKeys: [],
                modifiedKeys: [],
                deletedKeys: deletedKeys,
                remoteItems: [:]
            )

            // Step 7: Check if recovering from previous failures
            let previousFailures = try await metadataStore.fetchSyncAnchorSnapshot(driveId: driveId)?.consecutiveFailures ?? 0

            // Step 8: Advance sync anchor
            try await metadataStore.advanceSyncAnchor(driveId: driveId, itemCount: totalRemoteCount)

            // Step 9: Notify delegate
            if previousFailures > 0 {
                delegate?.syncEngineDidRecoverFromError(driveId: driveId)
            }
            delegate?.syncEngineDidComplete(driveId: driveId)

            let result = ReconciliationResult(
                newKeys: allNewKeys,
                modifiedKeys: allModifiedKeys,
                deletedKeys: deletedKeys,
                remoteItems: allRemoteItems,
                massDeletionDetected: massDeletionDetected
            )

            logger.info(
                "Reconciliation complete for drive \(driveId.uuidString, privacy: .public): \(allNewKeys.count) new, \(allModifiedKeys.count) modified, \(deletedKeys.count) deleted"
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
    /// - Batch-upserts new and modified items with syncStatus .synced
    /// - Hard deletes removed items
    private func applyChanges(
        driveId: UUID,
        newKeys: Set<String>,
        modifiedKeys: Set<String>,
        deletedKeys: Set<String>,
        remoteItems: [String: S3ObjectInfo]
    ) async throws {
        // Batch upsert new and modified items
        let upsertData = newKeys.union(modifiedKeys).map { key in
            let info = remoteItems[key]
            return MetadataStore.ItemUpsertData(
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
        if !upsertData.isEmpty {
            try await metadataStore.batchUpsertItems(upsertData)
        }

        // Hard delete removed items from MetadataStore
        for key in deletedKeys {
            try await metadataStore.deleteItem(byKey: key, driveId: driveId)
        }
    }
}
