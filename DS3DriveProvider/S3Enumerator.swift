import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log
import SotoS3

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
    private let drive: DS3Drive
    private let recursively: Bool
    private let notificationManager: NotificationManager
    private let prefix: String?
    private let syncEngine: SyncEngine?
    private let metadataStore: MetadataStore?

    /// The parent key used for MetadataStore queries: `nil` for root, otherwise the raw identifier.
    private var parentKey: String? {
        self.parent == .rootContainer ? nil : self.parent.rawValue
    }

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

    func invalidate() {
        // No resources to release
    }

    /// Fetches cached children from MetadataStore and sends them to the observer.
    /// Returns `true` if cached items were found and sent, `false` otherwise.
    private func serveCachedItems(to observer: NSFileProviderEnumerationObserver) async throws -> Bool {
        guard let metadataStore = self.metadataStore else { return false }
        let cachedChildren = try await metadataStore.fetchChildren(
            parentKey: self.parentKey,
            driveId: self.drive.id
        )
        guard !cachedChildren.isEmpty else { return false }
        let items = self.s3Items(from: cachedChildren)
        observer.didEnumerate(items)
        return true
    }

    /// Converts MetadataStore cached children into S3Items for the File Provider observer.
    private func s3Items(from children: [MetadataStore.CachedChildItem]) -> [S3Item] {
        children.map { child in
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
    }

    /// Synthesizes virtual folder S3Items for parent directories that don't have
    /// explicit 0-byte marker objects in S3. When listing recursively (delimiter=nil),
    /// S3 only returns actual objects — virtual folders that exist only as key prefixes
    /// are not included. Without these, the File Provider system can't build a complete
    /// folder hierarchy and folder icons won't appear.
    static func synthesizeVirtualFolders(
        from items: [S3Item],
        drive: DS3Drive,
        prefix: String?
    ) -> [S3Item] {
        let existingKeys = Set(items.map { $0.itemIdentifier.rawValue })
        var synthesized: [S3Item] = []
        var seenDirs: Set<String> = []

        for item in items {
            let components = item.itemIdentifier.rawValue.split(
                separator: DefaultSettings.S3.delimiter,
                omittingEmptySubsequences: true
            )

            // Build each ancestor directory path (skip the item itself)
            for idx in 1..<components.count {
                let dirKey = components[0..<idx].joined(separator: String(DefaultSettings.S3.delimiter))
                    + String(DefaultSettings.S3.delimiter)

                // Skip the drive prefix (maps to rootContainer)
                if dirKey == prefix { continue }

                // Skip paths above the prefix
                if let prefix, !dirKey.hasPrefix(prefix) { continue }

                // Skip already-known folders
                if existingKeys.contains(dirKey) || seenDirs.contains(dirKey) { continue }

                seenDirs.insert(dirKey)
                synthesized.append(
                    S3Item(
                        identifier: NSFileProviderItemIdentifier(dirKey),
                        drive: drive,
                        objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
                    )
                )
            }
        }

        return synthesized
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        guard let metadataStore = self.metadataStore else {
            completionHandler(NSFileProviderSyncAnchor(Date()))
            return
        }

        let driveId = self.drive.id
        let boxedCb = UncheckedBox(value: completionHandler)

        Task {
            let snapshot = try? await metadataStore.fetchSyncAnchorSnapshot(driveId: driveId)
            let payload = SyncAnchorPayload(
                date: snapshot?.lastSyncDate ?? Date(),
                reconciliationId: SyncAnchorPayload.nilReconciliationId,
                itemCount: snapshot?.itemCount ?? 0
            )
            boxedCb.value(NSFileProviderSyncAnchor(payload))
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        self.logger.info("enumerateItems called for parent=\(self.parent.rawValue, privacy: .public) prefix=\(self.prefix ?? "nil", privacy: .public) recursive=\(self.recursively)")

        let boxedObserver = UncheckedBox(value: observer)
        Task {
            let observer = boxedObserver.value
            do {
                // When paused, serve from cache or return empty. No S3 calls.
                if (try? SharedData.default().isDrivePaused(self.drive.id)) == true {
                    let hadCachedItems = try await self.serveCachedItems(to: observer)
                    self.logger.debug("enumerateItems (paused): hadCachedItems=\(hadCachedItems) for prefix \(self.prefix ?? "nil", privacy: .public)")
                    observer.finishEnumerating(upTo: nil)
                    return
                }

                #if os(iOS)
                // On iOS, working set must never read from the cloud (WWDC 2017 Session 243).
                // Recursive S3 listings spike memory to 15+ MB → extension jetsammed.
                // Each restart resets the in-memory TTL cache → the working set
                // immediately fires another recursive listing → kill loop.
                // Per-folder enumerateItems handles navigation; MetadataStore is the cache.
                if self.recursively {
                    self.logger.info("enumerateItems: working set returns empty on iOS (no S3)")
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                #else
                // TTL gate for working set (recursive) enumeration: iOS calls this
                // every ~6 seconds. If we recently did a full S3 listing, skip it
                // entirely — the system already has items from the prior enumeration.
                // This prevents the working set from burning the iOS networking grace
                // period with repeated 1000+ item recursive S3 listings.
                if self.recursively && page.toContinuationToken() == nil {
                    let cacheKey = "__workingSet__"
                    let lastEnumerated = await EnumerationTimestampCache.shared.lastEnumerated(forPrefix: cacheKey)
                    if !isCacheStale(lastEnumerated: lastEnumerated, ttl: Self.cacheTTL) {
                        self.logger.info("enumerateItems: working set TTL fresh, skipping S3 listing")
                        observer.finishEnumerating(upTo: nil)
                        return
                    }
                    await EnumerationTimestampCache.shared.recordEnumeration(forPrefix: cacheKey)
                }
                #endif

                // Cache-first: for per-folder (non-recursive) first-page enumeration,
                // serve from MetadataStore if items are already known (e.g. from
                // the BFS indexer). This avoids hitting S3 when navigating
                // into subfolders of an already-indexed parent.
                if !self.recursively && page.toContinuationToken() == nil,
                   self.metadataStore != nil,
                   try await self.serveCachedItems(to: observer) {
                    observer.finishEnumerating(upTo: nil)

                    // TTL check: skip S3 refresh if recently enumerated
                    let cacheKey = self.parentKey ?? "__root__"
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

                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing, isFileOperation: false)

                // S3 fallback path (cache miss). If S3 fails (e.g. iOS networking
                // grace period exhausted), retry MetadataStore as last resort — BFS
                // may have populated it between the first cache check and now.
                do {
                    let (items, continuationToken) = try await self.s3Lib.listS3Items(
                        forDrive: self.drive,
                        withPrefix: self.prefix,
                        recursively: self.recursively,
                        withContinuationToken: page.toContinuationToken()
                    )

                    // For recursive (working set) enumeration, synthesize virtual parent
                    // folders. S3 recursive listing (delimiter=nil) returns only actual
                    // objects — virtual folders that exist only as key prefixes are missing.
                    // Without them the File Provider system can't build the folder tree.
                    var allItems = items
                    if self.recursively {
                        let virtualFolders = Self.synthesizeVirtualFolders(
                            from: items, drive: self.drive, prefix: self.prefix
                        )
                        if !virtualFolders.isEmpty {
                            self.logger.info("Synthesized \(virtualFolders.count) virtual folder(s) for working set")
                            allItems.append(contentsOf: virtualFolders)
                        }

                        // Filter out .trash/ items from the working set — trashed items
                        // are enumerated exclusively by TrashS3Enumerator to avoid
                        // identity conflicts with the system's trash tracking.
                        allItems = allItems.filter { item in
                            !S3Lib.isTrashedKey(item.itemIdentifier.rawValue, drive: self.drive)
                        }
                    }

                    // Signal observer FIRST so Finder shows items immediately
                    self.logger.info("enumerateItems S3 path: \(allItems.count) items (\(items.count) from S3) for prefix \(self.prefix ?? "nil", privacy: .public)")
                    // Log first 10 items at info level for debugging folder icon issues
                    for item in allItems.prefix(10) {
                        self.logger.info("  item: \(item.itemIdentifier.rawValue, privacy: .public) contentType=\(item.contentType.identifier, privacy: .public) isFolder=\(item.isFolder)")
                    }
                    if !allItems.isEmpty {
                        observer.didEnumerate(allItems)
                    }

                    let page = continuationToken.map { NSFileProviderPage($0) }

                    await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                    observer.finishEnumerating(upTo: page)

                    // Batch upsert into MetadataStore in the background (doesn't block display)
                    if let metadataStore = self.metadataStore, !allItems.isEmpty {
                        let upsertData = allItems.map { MetadataStore.ItemUpsertData(from: $0) }
                        Task.detached {
                            try? await metadataStore.batchUpsertItems(upsertData)
                        }
                    }
                } catch {
                    self.logger.warning("S3 listing failed, trying MetadataStore fallback for prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")

                    // Last-resort: BFS may have populated MetadataStore since our first check
                    if try await self.serveCachedItems(to: observer) {
                        self.logger.info("enumerateItems: MetadataStore fallback served items for prefix \(self.prefix ?? "nil", privacy: .public)")
                        observer.finishEnumerating(upTo: nil)
                        return
                    }

                    // Both S3 and MetadataStore fallback failed — propagate
                    throw error
                }
            } catch let error as FileProviderExtensionError {
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateItems S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch {
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    /// Fires a background S3 listing to refresh the MetadataStore cache after
    /// serving cached items from `enumerateItems`. This ensures the DB stays
    /// in sync with remote data even between polling cycles.
    private func refreshCacheInBackground() {
        Task.detached { [s3Lib, drive, prefix, parent, metadataStore, logger, recursively] in
            guard let metadataStore else { return }

            // Skip refresh when drive is paused
            if (try? SharedData.default().isDrivePaused(drive.id)) == true {
                logger.debug("Background cache refresh skipped (paused) for prefix \(prefix ?? "nil", privacy: .public)")
                return
            }

            do {
                var continuationToken: String?
                var allKeys = Set<String>()
                repeat {
                    let (items, nextToken) = try await s3Lib.listS3Items(
                        forDrive: drive,
                        withPrefix: prefix,
                        recursively: recursively,
                        withContinuationToken: continuationToken
                    )
                    continuationToken = nextToken

                    let upsertData = items.map { MetadataStore.ItemUpsertData(from: $0) }
                    allKeys.formUnion(upsertData.lazy.map(\.s3Key))
                    try await metadataStore.batchUpsertItems(upsertData)
                } while continuationToken != nil

                // Remove cached items that are no longer in S3 (only synced items,
                // preserving pending uploads and items in error/conflict state).
                if !recursively {
                    let parentKey: String? = parent == .rootContainer ? nil : parent.rawValue
                    try await metadataStore.pruneChildren(
                        parentKey: parentKey,
                        driveId: drive.id,
                        keepKeys: allKeys
                    )
                }

                // On macOS, signal the specific folder container so Finder picks up
                // the refreshed cache immediately. On iOS, skip the signal — it would
                // trigger enumerateChanges → SyncEngine.reconcile() (full recursive S3
                // listing), burning the networking grace period and causing the system
                // to briefly clear the folder view (thumbnails/icons disappear).
                // The updated MetadataStore cache will be served on next navigation.
                #if os(macOS)
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                    displayName: drive.name
                )
                let container = parent == .rootContainer ? NSFileProviderItemIdentifier.rootContainer : parent
                try? await NSFileProviderManager(for: domain)?
                    .signalEnumerator(for: container)
                logger.debug("Background cache refresh + signal(\(container.rawValue, privacy: .public)) complete for prefix \(prefix ?? "nil", privacy: .public)")
                #endif
            } catch {
                logger.debug("Background cache refresh failed for prefix \(prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // swiftlint:disable:next function_body_length
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let boxedObserver = UncheckedBox(value: observer)
        Task {
            let observer = boxedObserver.value
            // When paused, finish immediately with current anchor — no S3 calls.
            if (try? SharedData.default().isDrivePaused(self.drive.id)) == true {
                self.logger.debug("enumerateChanges (paused): finishing with current anchor for prefix \(self.prefix ?? "nil", privacy: .public)")
                return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            }

            #if os(iOS)
            // On iOS, skip ALL change enumeration. Even per-folder enumerateChanges
            // calls SyncEngine.reconcile() which does a full recursive S3 listing,
            // burning the networking grace period and spiking memory (→ jetsam).
            // Changes are discovered via per-folder enumerateItems (cache-first with
            // background S3 refresh) when the user navigates.
            self.logger.info("enumerateChanges: skipping on iOS for prefix \(self.prefix ?? "nil", privacy: .public)")
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            #else
            await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing, isFileOperation: false)

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

                    await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
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
                var updatedItems: [S3Item] = changedKeys.compactMap { key in
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

                // Synthesize virtual parent folders for new items so the
                // system can display them in the correct directory.
                if self.recursively && !updatedItems.isEmpty {
                    let virtualFolders = Self.synthesizeVirtualFolders(
                        from: updatedItems, drive: self.drive, prefix: self.prefix
                    )
                    updatedItems.append(contentsOf: virtualFolders)
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

                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                return observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch let error as FileProviderExtensionError {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateChanges S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch is SyncEngineError {
                self.logger.warning("Sync engine unavailable (network): skipping change enumeration")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } catch {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error, isFileOperation: false)
                return observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
            #endif
        }
    }
}

/// An enumerator that immediately finishes with no items.
/// Used for unsupported containers (e.g. trash) to avoid FP -1005 errors on startup.
class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {
        // No resources to release
    }

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
