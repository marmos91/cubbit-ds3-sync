import Foundation
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib

enum EnumeratorError: Error {
    case unsupported
    case missingParameters
}

/// Actor-isolated cache for tracking last enumeration timestamps per folder prefix.
/// Used by the cache-first + TTL pattern to skip redundant S3 refreshes.
private actor EnumerationTimestampCache {
    static let shared = EnumerationTimestampCache()
    private var timestamps: [String: Date] = [:]

    func lastEnumerated(forPrefix prefix: String) -> Date? {
        timestamps[prefix]
    }

    func recordEnumeration(forPrefix prefix: String) {
        timestamps[prefix] = Date()
    }
}

class S3Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    /// Time-to-live for cached enumeration results. If a folder was enumerated
    /// less than this many seconds ago, skip the S3 refresh.
    private static let cacheTTL: TimeInterval = 60

    private let parent: NSFileProviderItemIdentifier

    private let s3Lib: S3Lib
    private var drive: DS3Drive
    private let recursively: Bool
    private let notificationManager: NotificationManager
    private var prefix: String?
    private let syncEngine: SyncEngine?
    private let metadataStore: MetadataStore?

    init(
        parent: NSFileProviderItemIdentifier,
        s3Lib: S3Lib,
        notificationManager: NotificationManager,
        drive: DS3Drive,
        recursive: Bool = false,
        syncEngine: SyncEngine? = nil,
        metadataStore: MetadataStore? = nil
    ) {
        self.parent = parent
        self.s3Lib = s3Lib
        self.drive = drive
        self.recursively = recursive
        self.notificationManager = notificationManager
        self.syncEngine = syncEngine
        self.metadataStore = metadataStore
        switch self.parent {
        case .rootContainer, .trashContainer, .workingSet:
            self.prefix = self.drive.syncAnchor.prefix
        default:
            self.prefix = parent.rawValue
        }

        super.init()
    }

    func invalidate() {}

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        guard let metadataStore = self.metadataStore else {
            completionHandler(NSFileProviderSyncAnchor(Date()))
            return
        }

        let cb = UnsafeCallback(completionHandler)
        let driveId = self.drive.id

        Task {
            let snapshot = try? await metadataStore.fetchSyncAnchorSnapshot(driveId: driveId)
            let payload = SyncAnchorPayload(
                date: snapshot?.lastSyncDate ?? Date(),
                reconciliationId: SyncAnchorPayload.nilReconciliationId,
                itemCount: snapshot?.itemCount ?? 0
            )
            cb.handler(NSFileProviderSyncAnchor(payload))
        }
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Task {
            do {
                // Cache-first: for per-folder (non-recursive) first-page enumeration,
                // serve from MetadataStore if items are already known (e.g. from
                // the BFS indexer). This avoids hitting S3 when navigating
                // into subfolders of an already-indexed parent.
                if !self.recursively && page.toContinuationToken() == nil,
                   let metadataStore = self.metadataStore {
                    let parentKey: String? = self.parent == .rootContainer ? nil : self.parent.rawValue
                    let cachedChildren = try await metadataStore.fetchChildren(
                        parentKey: parentKey,
                        driveId: self.drive.id
                    )

                    if !cachedChildren.isEmpty {
                        let items = cachedChildren.map { child in
                            S3Item(
                                identifier: NSFileProviderItemIdentifier(child.s3Key),
                                drive: self.drive,
                                objectMetadata: S3Item.Metadata(
                                    etag: child.etag,
                                    contentType: child.contentType,
                                    lastModified: child.lastModified,
                                    size: NSNumber(value: child.size),
                                    syncStatus: child.syncStatus
                                )
                            )
                        }

                        self.logger.debug("enumerateItems: serving \(items.count) cached items for prefix \(self.prefix ?? "nil", privacy: .public)")
                        observer.didEnumerate(items)
                        observer.finishEnumerating(upTo: nil)

                        // TTL check: skip S3 refresh if recently enumerated
                        let cacheKey = parentKey ?? "__root__"
                        let lastEnumerated = await EnumerationTimestampCache.shared.lastEnumerated(forPrefix: cacheKey)
                        if !isCacheStale(lastEnumerated: lastEnumerated, ttl: Self.cacheTTL) {
                            self.logger.debug("enumerateItems: TTL fresh, skipping S3 refresh for \(self.prefix ?? "nil", privacy: .public)")
                            return
                        }

                        // Schedule background S3 refresh and record timestamp
                        await EnumerationTimestampCache.shared.recordEnumeration(forPrefix: cacheKey)
                        self.refreshCacheInBackground()
                        return
                    }
                }

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing, isFileOperation: false)

                let (items, continuationToken) = try await self.s3Lib.listS3Items(
                    forDrive: self.drive,
                    withPrefix: self.prefix,
                    recursively: self.recursively,
                    withContinuationToken: page.toContinuationToken()
                )

                // Signal observer FIRST so Finder shows items immediately
                if !items.isEmpty {
                    observer.didEnumerate(items)
                }

                let page = continuationToken.map { NSFileProviderPage($0) }

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                observer.finishEnumerating(upTo: page)

                // Batch upsert into MetadataStore in the background (doesn't block display)
                if let metadataStore = self.metadataStore, !items.isEmpty {
                    let upsertData = items.map { MetadataStore.ItemUpsertData(from: $0) }
                    Task.detached {
                        try? await metadataStore.batchUpsertItems(upsertData)
                    }
                }
            } catch let error as FileProviderExtensionError {
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateItems S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch {
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    /// Fires a background S3 listing to refresh the MetadataStore cache after
    /// serving cached items from `enumerateItems`. This ensures the DB stays
    /// in sync with remote data even between polling cycles.
    private func refreshCacheInBackground() {
        Task.detached { [s3Lib, drive, prefix, metadataStore, logger, recursively] in
            guard let metadataStore else { return }

            do {
                var continuationToken: String?
                repeat {
                    let (items, nextToken) = try await s3Lib.listS3Items(
                        forDrive: drive,
                        withPrefix: prefix,
                        recursively: recursively,
                        withContinuationToken: continuationToken
                    )
                    continuationToken = nextToken

                    let upsertData = items.map { MetadataStore.ItemUpsertData(from: $0) }
                    try await metadataStore.batchUpsertItems(upsertData)
                } while continuationToken != nil

                logger.debug("Background cache refresh complete for prefix \(prefix ?? "nil", privacy: .public)")
            } catch {
                logger.debug("Background cache refresh failed for prefix \(prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing, isFileOperation: false)

            do {
                self.logger.debug("Enumerating changes for prefix \(self.prefix ?? "nil")")

                if self.parent == .trashContainer {
                    // NOTE: skipping trash
                    return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                }

                guard let syncEngine = self.syncEngine else {
                    // Fall back to simple listing if SyncEngine is unavailable
                    self.logger.warning("SyncEngine unavailable, falling back to timestamp-based enumeration")
                    let (changedItems, _) = try await self.s3Lib.listS3Items(
                        forDrive: self.drive,
                        withPrefix: self.prefix,
                        recursively: self.recursively,
                        fromDate: anchor.toDate()
                    )

                    if !changedItems.isEmpty {
                        observer.didUpdate(changedItems)
                    }

                    self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                    return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                }

                // Use SyncEngine for full reconciliation
                let adapter = S3LibListingAdapter(s3Lib: self.s3Lib, drive: self.drive)

                let result = try await syncEngine.reconcile(
                    driveId: self.drive.id,
                    s3Provider: adapter,
                    bucket: self.drive.syncAnchor.bucket.name,
                    prefix: self.drive.syncAnchor.prefix
                )

                // Convert new + modified keys to S3Item instances for the observer
                let changedKeys = result.newKeys.union(result.modifiedKeys)
                let updatedItems: [S3Item] = changedKeys.compactMap { key in
                    guard let info = result.remoteItems[key] else { return nil }
                    return S3Item(
                        identifier: NSFileProviderItemIdentifier(key),
                        drive: self.drive,
                        objectMetadata: S3Item.Metadata(
                            etag: info.etag,
                            lastModified: info.lastModified,
                            size: NSNumber(value: info.size)
                        )
                    )
                }

                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }

                // Report deleted items
                if !result.deletedKeys.isEmpty {
                    let deletedIdentifiers = result.deletedKeys.map {
                        NSFileProviderItemIdentifier($0)
                    }
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                let snapshot = try? await self.metadataStore?.fetchSyncAnchorSnapshot(driveId: self.drive.id)
                let newAnchor = NSFileProviderSyncAnchor(SyncAnchorPayload(
                    date: snapshot?.lastSyncDate ?? Date(),
                    itemCount: snapshot?.itemCount ?? 0
                ))

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                return observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch let error as FileProviderExtensionError {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateChanges S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch is SyncEngineError {
                self.logger.warning("Sync engine unavailable (network): skipping change enumeration")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } catch {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }
}

/// An enumerator that immediately finishes with no items.
/// Used for unsupported containers (e.g. trash) to avoid FP -1005 errors on startup.
class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
}

class WorkingSetS3Enumerator: S3Enumerator, @unchecked Sendable {
    init(
        parent: NSFileProviderItemIdentifier,
        s3Lib: S3Lib,
        notificationManager: NotificationManager,
        drive: DS3Drive,
        syncEngine: SyncEngine? = nil,
        metadataStore: MetadataStore? = nil
    ) {
        // Enumerate everything from the root, recursively.
        super.init(
            parent: parent,
            s3Lib: s3Lib,
            notificationManager: notificationManager,
            drive: drive,
            recursive: true,
            syncEngine: syncEngine,
            metadataStore: metadataStore
        )
    }
}
