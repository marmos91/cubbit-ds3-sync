import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

/// Enumerates the working set: items flagged `isMaterialized` in the local
/// cache. The flag is additive — `S3Enumerator` sets it on every enumerated
/// child (so the set grows with folder navigation) and
/// `materializedItemsDidChange` unions it with Apple's on-disk list.
///
/// `enumerateChanges` HEADs each member via a bounded `withTaskGroup`
/// (capped at `DefaultSettings.Extension.workingSetRefreshConcurrency`) to
/// detect remote ETag drift or 404s without stampeding S3.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let metadataStore: MetadataStore?

    init(
        s3Lib: S3Lib,
        drive: DS3Drive,
        metadataStore: MetadataStore?
    ) {
        self.s3Lib = s3Lib
        self.drive = drive
        self.metadataStore = metadataStore
        super.init()
    }

    func invalidate() {
        // No resources to release
    }

    // MARK: - currentSyncAnchor

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let metadataStore = self.metadataStore
        let driveId = self.drive.id
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let members = await (try? metadataStore?.fetchWorkingSetMembers(driveId: driveId)) ?? []
            let anchor = NSFileProviderSyncAnchor(
                SyncAnchorHash.compute(over: members.map(WorkingSetEnumerator.entry(from:)))
            )
            boxedCb.value(anchor)
        }
    }

    /// Maps a cached working-set member to the Sendable struct expected by
    /// `SyncAnchorHash.compute(over:)`. Extracted so anchor sites stay
    /// one-liners and SwiftLint's large-tuple rule never fires.
    fileprivate static func entry(
        from member: MetadataStore.CachedChildItem
    ) -> SyncAnchorHash.WorkingSetEntry {
        SyncAnchorHash.WorkingSetEntry(
            key: member.s3Key,
            etag: member.etag,
            thumbnailReadyAt: member.thumbnailReadyAt
        )
    }

    // MARK: - enumerateItems

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        let boxedObserver = UncheckedBox(value: observer)
        let _: Task<Void, Never> = Task {
            let observer = boxedObserver.value
            guard let metadataStore = self.metadataStore else {
                observer.finishEnumerating(upTo: nil)
                return
            }
            do {
                let members = try await metadataStore.fetchWorkingSetMembers(driveId: self.drive.id)
                let items = members.map { member in
                    S3Item(
                        identifier: NSFileProviderItemIdentifier(member.s3Key),
                        drive: self.drive,
                        objectMetadata: S3Item.Metadata(
                            etag: member.etag,
                            contentType: member.contentType,
                            lastModified: member.lastModified,
                            size: NSNumber(value: member.size),
                            syncStatus: member.syncStatus
                        )
                    )
                }
                if !items.isEmpty {
                    observer.didEnumerate(items)
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                self.logger.warning(
                    "WorkingSetEnumerator: enumerateItems failed: \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    // MARK: - enumerateChanges

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let boxedObserver = UncheckedBox(value: observer)
        let _: Task<Void, Never> = Task {
            let observer = boxedObserver.value
            guard let metadataStore = self.metadataStore else {
                self.logger.error(
                    "WorkingSetEnumerator: enumerateChanges called with nil metadataStore"
                )
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.cannotSynchronize) as NSError
                )
                return
            }

            do {
                let members = try await metadataStore.fetchWorkingSetMembers(driveId: self.drive.id)
                guard !members.isEmpty else {
                    let emptyAnchor = NSFileProviderSyncAnchor(
                        SyncAnchorHash.compute(over: [SyncAnchorHash.WorkingSetEntry]())
                    )
                    observer.finishEnumeratingChanges(upTo: emptyAnchor, moreComing: false)
                    return
                }

                let refreshed = await self.refreshMembers(members)
                await self.applyEtagDrift(refreshed: refreshed, observer: observer, store: metadataStore)
                await self.applyThumbnailReady(
                    members: members, refreshed: refreshed,
                    observer: observer, store: metadataStore
                )
                await self.applyDeletions(refreshed: refreshed, observer: observer, store: metadataStore)

                let postRefresh = await (try? metadataStore.fetchWorkingSetMembers(driveId: self.drive.id)) ?? []
                let newAnchor = NSFileProviderSyncAnchor(
                    SyncAnchorHash.compute(over: postRefresh.map(WorkingSetEnumerator.entry(from:)))
                )
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                self.logger.warning(
                    "WorkingSetEnumerator: enumerateChanges failed: \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    /// Persist + emit items whose remote ETag has drifted from our cache.
    private func applyEtagDrift(
        refreshed: (updated: [S3Item], deleted: [String]),
        observer: NSFileProviderChangeObserver,
        store: MetadataStore
    ) async {
        let updatedItems = refreshed.updated.map { remote in
            S3Item(
                identifier: NSFileProviderItemIdentifier(remote.itemIdentifier.rawValue),
                drive: self.drive,
                objectMetadata: remote.metadata
            )
        }
        guard !updatedItems.isEmpty else { return }
        let upsertData = updatedItems.map { MetadataStore.ItemUpsertData(from: $0) }
        do {
            try await store.batchUpsertItems(upsertData)
        } catch {
            self.logger.warning(
                "WorkingSetEnumerator: failed to persist updated items: \(error.localizedDescription, privacy: .public)"
            )
        }
        observer.didUpdate(updatedItems)
    }

    /// Issue #153: re-emit rows whose `thumbnailReadyAt` was set by the iOS
    /// foreground backfill driver after a sidecar PUT, so Files.app
    /// invalidates its per-item thumbnail cache. The HEAD-driven `applyEtagDrift`
    /// path only fires when the original's etag drifts; sidecar landings
    /// don't change the original, so this side-channel is required.
    /// After emitting, clears the one-shot flag.
    private func applyThumbnailReady(
        members: [MetadataStore.CachedChildItem],
        refreshed: (updated: [S3Item], deleted: [String]),
        observer: NSFileProviderChangeObserver,
        store: MetadataStore
    ) async {
        let updatedKeys = Set(refreshed.updated.map(\.itemIdentifier.rawValue))
        let readyMembers = members.filter {
            $0.thumbnailReadyAt != nil && !updatedKeys.contains($0.s3Key)
        }
        guard !readyMembers.isEmpty else { return }
        let readyItems = readyMembers.map { member in
            S3Item(
                identifier: NSFileProviderItemIdentifier(member.s3Key),
                drive: self.drive,
                objectMetadata: S3Item.Metadata(
                    etag: member.etag,
                    contentType: member.contentType,
                    lastModified: member.lastModified,
                    size: NSNumber(value: member.size),
                    syncStatus: member.syncStatus
                )
            )
        }
        observer.didUpdate(readyItems)
        self.logger.info(
            "WorkingSetEnumerator: re-emitted \(readyItems.count, privacy: .public) after sidecar render (#153)"
        )
        let driveId = self.drive.id
        let clearedKeys = readyMembers.map(\.s3Key)
        do {
            try await store.clearThumbnailReady(forKeys: clearedKeys, driveId: driveId)
        } catch {
            self.logger.warning(
                "WorkingSetEnumerator: failed to clear thumbnailReadyAt: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Persist + emit deletions for keys that returned 404 to HEAD. Removes
    /// rows from the metadata store BEFORE notifying so the post-refresh
    /// anchor excludes them; otherwise the next 30 s tick re-HEADs the same
    /// gone-forever keys and re-reports `didDeleteItems` indefinitely.
    private func applyDeletions(
        refreshed: (updated: [S3Item], deleted: [String]),
        observer: NSFileProviderChangeObserver,
        store: MetadataStore
    ) async {
        guard !refreshed.deleted.isEmpty else { return }
        let driveId = self.drive.id
        let deletedKeys = refreshed.deleted
        do {
            try await store.batchDeleteItems(
                deletedKeys.map { (s3Key: $0, driveId: driveId) }
            )
        } catch {
            self.logger.error(
                "WorkingSetEnumerator: failed to remove deleted keys from store: \(error.localizedDescription, privacy: .public)"
            )
        }
        observer.didDeleteItems(
            withIdentifiers: deletedKeys.map { NSFileProviderItemIdentifier($0) }
        )
    }

    /// Per-member HEAD against S3 to detect remote ETag drift or deletion.
    /// Uses a sliding-window concurrency cap so a large working set (grown via
    /// additive `isMaterialized` visits) doesn't stampede S3 or spike extension
    /// memory on each 30 s tick.
    private func refreshMembers(
        _ members: [MetadataStore.CachedChildItem]
    ) async -> (updated: [S3Item], deleted: [String]) {
        let maxConcurrency = DefaultSettings.Extension.workingSetRefreshConcurrency
        return await withTaskGroup(
            of: (key: String, result: MemberCheckResult).self
        ) { group in
            var updated: [S3Item] = []
            var deleted: [String] = []
            var nextIndex = 0

            // Seed the initial window.
            while nextIndex < min(maxConcurrency, members.count) {
                let member = members[nextIndex]
                nextIndex += 1
                group.addTask { [self] in await self.checkMember(member) }
            }

            // Drain one result, then enqueue the next to keep the window full.
            for await outcome in group {
                switch outcome.result {
                case let .updated(item): updated.append(item)
                case .deleted: deleted.append(outcome.key)
                case .unchanged: break
                }
                if nextIndex < members.count {
                    let member = members[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in await self.checkMember(member) }
                }
            }

            return (updated, deleted)
        }
    }

    private func checkMember(
        _ member: MetadataStore.CachedChildItem
    ) async -> (key: String, result: MemberCheckResult) {
        let id = NSFileProviderItemIdentifier(member.s3Key)
        do {
            let remote = try await self.s3Lib.remoteS3Item(for: id, drive: self.drive)
            if member.etag != remote.metadata.etag {
                return (member.s3Key, .updated(remote))
            }
            return (member.s3Key, .unchanged)
        } catch let awsError as AWSErrorType where awsError.isNotFound {
            return (member.s3Key, .deleted)
        } catch {
            return (member.s3Key, .unchanged)
        }
    }

    private enum MemberCheckResult {
        case updated(S3Item)
        case deleted
        case unchanged
    }
}
