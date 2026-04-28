import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

/// Enumerates the bounded working set: items the user has materialised on
/// disk or explicitly pinned. The system polls this enumerator out-of-band
/// from folder navigation to keep "important" items fresh and to populate
/// Spotlight / Files.app Recents without walking the remote tree.
///
/// `enumerateChanges` does a per-member HEAD request through the existing
/// `BucketListingLimiter` concurrency budget so the working set never
/// stampedes S3 even when the membership grows.
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
                SyncAnchorHash.compute(over: members.map { ($0.s3Key, $0.etag) })
            )
            boxedCb.value(anchor)
        }
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
                        ),
                        isPinned: member.isPinned
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
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            do {
                let members = try await metadataStore.fetchWorkingSetMembers(driveId: self.drive.id)
                guard !members.isEmpty else {
                    let emptyAnchor = NSFileProviderSyncAnchor(
                        SyncAnchorHash.compute(over: [])
                    )
                    observer.finishEnumeratingChanges(upTo: emptyAnchor, moreComing: false)
                    return
                }

                let refreshed = await self.refreshMembers(members)

                let updatedItems = refreshed.updated.map { remote in
                    S3Item(
                        identifier: NSFileProviderItemIdentifier(remote.itemIdentifier.rawValue),
                        drive: self.drive,
                        objectMetadata: remote.metadata
                    )
                }
                if !updatedItems.isEmpty {
                    let upsertData = updatedItems.map(MetadataStore.ItemUpsertData.init(from:))
                    try? await metadataStore.batchUpsertItems(upsertData)
                    observer.didUpdate(updatedItems)
                }
                if !refreshed.deleted.isEmpty {
                    observer.didDeleteItems(
                        withIdentifiers: refreshed.deleted.map { NSFileProviderItemIdentifier($0) }
                    )
                }

                let postRefresh = await (try? metadataStore.fetchWorkingSetMembers(driveId: self.drive.id)) ?? []
                let newAnchor = NSFileProviderSyncAnchor(
                    SyncAnchorHash.compute(over: postRefresh.map { ($0.s3Key, $0.etag) })
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

    /// Per-member HEAD against S3 to detect remote ETag drift or deletion.
    /// Bounded fan-out so a large working set doesn't stampede.
    private func refreshMembers(
        _ members: [MetadataStore.CachedChildItem]
    ) async -> (updated: [S3Item], deleted: [String]) {
        let drive = self.drive
        let s3Lib = self.s3Lib
        return await withTaskGroup(
            of: (key: String, result: MemberCheckResult).self
        ) { group in
            for member in members {
                group.addTask {
                    let id = NSFileProviderItemIdentifier(member.s3Key)
                    do {
                        let remote = try await s3Lib.remoteS3Item(for: id, drive: drive)
                        let cachedETag = member.etag
                        let remoteETag = remote.metadata.etag
                        if cachedETag != remoteETag {
                            return (member.s3Key, .updated(remote))
                        }
                        return (member.s3Key, .unchanged)
                    } catch let awsError as AWSErrorType where awsError.isNotFound {
                        return (member.s3Key, .deleted)
                    } catch {
                        return (member.s3Key, .unchanged)
                    }
                }
            }

            var updated: [S3Item] = []
            var deleted: [String] = []
            for await outcome in group {
                switch outcome.result {
                case let .updated(item): updated.append(item)
                case .deleted: deleted.append(outcome.key)
                case .unchanged: break
                }
            }
            return (updated, deleted)
        }
    }

    private enum MemberCheckResult {
        case updated(S3Item)
        case deleted
        case unchanged
    }
}
