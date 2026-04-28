import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

enum EnumeratorError: Error {
    case unsupported
    case missingParameters
}

/// Lazy, direct-children-only enumerator. Lists the parent container's
/// immediate children via a delimited `ListObjectsV2`, mirrors the result
/// into `MetadataStore`, and serves a per-container delta in
/// `enumerateChanges` by diffing against the cache.
///
/// Cubbit-specific business logic (anchor format, diff algorithm) lives in
/// `DS3Lib/Enumeration/`; this class is a thin File Provider adapter.
class S3Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    private let parent: NSFileProviderItemIdentifier
    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let notificationManager: NotificationManager
    private let prefix: String?
    private let metadataStore: MetadataStore?

    /// Parent key used for `MetadataStore` queries: `nil` for root,
    /// otherwise the raw identifier (the S3 key of the folder).
    private var parentKey: String? {
        self.parent == .rootContainer ? nil : self.parent.rawValue
    }

    init(
        parent: NSFileProviderItemIdentifier,
        s3Lib: S3Lib,
        notificationManager: NotificationManager,
        drive: DS3Drive,
        metadataStore: MetadataStore? = nil
    ) {
        self.parent = parent
        self.s3Lib = s3Lib
        self.drive = drive
        self.notificationManager = notificationManager
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

    // MARK: - currentSyncAnchor

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        guard let metadataStore = self.metadataStore else {
            completionHandler(nil)
            return
        }

        let driveId = self.drive.id
        let parentKey = self.parentKey
        let boxedCb = UncheckedBox(value: completionHandler)

        Task {
            let cached = await (try? metadataStore.fetchChildren(
                parentKey: parentKey, driveId: driveId
            )) ?? []
            let anchor = NSFileProviderSyncAnchor(
                SyncAnchorHash.compute(over: cached.map { ($0.s3Key, $0.etag) })
            )
            boxedCb.value(anchor)
        }
    }

    // MARK: - enumerateItems

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        self.logger.info(
            "enumerateItems: parent=\(self.parent.rawValue, privacy: .public) prefix=\(self.prefix ?? "nil", privacy: .public)"
        )

        let boxedObserver = UncheckedBox(value: observer)
        Task {
            let observer = boxedObserver.value
            await self.notificationManager.sendDriveChangedNotificationWithDebounce(
                status: .sync, isFileOperation: false
            )

            do {
                let (items, continuationToken) = try await self.s3Lib.listS3Items(
                    forDrive: self.drive,
                    withPrefix: self.prefix,
                    recursively: false,
                    withContinuationToken: page.toContinuationToken()
                )

                let visibleItems = items.filter {
                    S3Lib.isUserVisible($0.itemIdentifier.rawValue, drive: self.drive)
                }
                self.logger.info(
                    "enumerateItems: \(visibleItems.count) visible items (\(items.count) from S3)"
                )
                if !visibleItems.isEmpty {
                    observer.didEnumerate(visibleItems)
                }

                let nextPage = continuationToken.map { NSFileProviderPage($0) }
                observer.finishEnumerating(upTo: nextPage)

                await self.notificationManager.sendDriveChangedNotificationWithDebounce(
                    status: .idle, isFileOperation: false
                )

                // Mirror into MetadataStore. Only prune when we know we've seen
                // the entire folder (single page: no incoming and no outgoing
                // continuation token). For paginated folders pruning would
                // delete keys that arrived on other pages.
                if let metadataStore = self.metadataStore {
                    let upsertData = visibleItems.map(MetadataStore.ItemUpsertData.init(from:))
                    let isFirstPage = page.toContinuationToken() == nil
                    let parentKey = self.parentKey
                    let driveId = self.drive.id
                    Task.detached {
                        if !upsertData.isEmpty {
                            try? await metadataStore.batchUpsertItems(upsertData)
                        }
                        if isFirstPage, continuationToken == nil {
                            let allKeys = Set(upsertData.map(\.s3Key))
                            try? await metadataStore.pruneChildren(
                                parentKey: parentKey, driveId: driveId, keepKeys: allKeys
                            )
                        }
                    }
                }
            } catch {
                // S3 unreachable / throttled → fall back to cache on the first
                // page so the user still sees something. On subsequent pages
                // the observer already received partial results, so don't
                // duplicate.
                self.logger.warning(
                    "S3 listing failed for \(self.prefix ?? "nil", privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                await self.notificationManager.sendDriveChangedNotificationWithDebounce(
                    status: .error, isFileOperation: false
                )
                if page.toContinuationToken() == nil,
                   await (try? self.serveCachedItems(to: observer)) == true {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                if let awsErr = error as? AWSErrorType {
                    observer.finishEnumeratingWithError(awsErr.toFileProviderError())
                } else {
                    observer.finishEnumeratingWithError(
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
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
            // Trash container has its own enumerator; don't run change
            // detection here.
            if self.parent == .trashContainer {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            guard let metadataStore = self.metadataStore else {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            do {
                let local = await (try? metadataStore.fetchChildren(
                    parentKey: self.parentKey, driveId: self.drive.id
                )) ?? []
                let localMap: [String: String?] = Dictionary(
                    uniqueKeysWithValues: local.map { ($0.s3Key, $0.etag) }
                )

                let remoteItems = try await self.listAllRemoteChildren()
                let remoteMap: [String: String?] = Dictionary(
                    uniqueKeysWithValues: remoteItems.map { ($0.itemIdentifier.rawValue, $0.metadata.etag) }
                )

                let delta = EnumerationDiff.compute(local: localMap, remote: remoteMap)

                // Apply to local cache atomically: upsert the new/modified rows
                // and prune the deletions.
                let updatedItems = remoteItems.filter {
                    delta.newOrModified.contains($0.itemIdentifier.rawValue)
                }
                if !updatedItems.isEmpty {
                    let upsertData = updatedItems.map(MetadataStore.ItemUpsertData.init(from:))
                    try? await metadataStore.batchUpsertItems(upsertData)
                }
                if !delta.deleted.isEmpty {
                    let keepKeys = Set(remoteMap.keys)
                    try? await metadataStore.pruneChildren(
                        parentKey: self.parentKey,
                        driveId: self.drive.id,
                        keepKeys: keepKeys
                    )
                }

                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }
                if !delta.deleted.isEmpty {
                    observer.didDeleteItems(
                        withIdentifiers: delta.deleted.map { NSFileProviderItemIdentifier($0) }
                    )
                }

                let newAnchor = NSFileProviderSyncAnchor(
                    SyncAnchorHash.compute(over: remoteMap.map { ($0.key, $0.value) })
                )
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                self.logger.warning(
                    "enumerateChanges failed for \(self.prefix ?? "nil", privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                if let awsErr = error as? AWSErrorType {
                    observer.finishEnumeratingWithError(awsErr.toFileProviderError())
                } else {
                    observer.finishEnumeratingWithError(
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    /// Lists every page of direct children for the current container,
    /// transparently chasing the S3 continuation token. Used by
    /// `enumerateChanges` where the caller wants the full snapshot rather
    /// than streaming pages to an observer.
    private func listAllRemoteChildren() async throws -> [S3Item] {
        var collected: [S3Item] = []
        var continuationToken: String?
        repeat {
            let (items, nextToken) = try await self.s3Lib.listS3Items(
                forDrive: self.drive,
                withPrefix: self.prefix,
                recursively: false,
                withContinuationToken: continuationToken
            )
            collected.append(contentsOf: items.filter {
                S3Lib.isUserVisible($0.itemIdentifier.rawValue, drive: self.drive)
            })
            continuationToken = nextToken
        } while continuationToken != nil
        return collected
    }

    /// Fetches cached children from `MetadataStore` and forwards them to the
    /// observer. Returns whether any items were found.
    private func serveCachedItems(to observer: NSFileProviderEnumerationObserver) async throws -> Bool {
        guard let metadataStore = self.metadataStore else { return false }
        let cached = try await metadataStore.fetchChildren(
            parentKey: self.parentKey, driveId: self.drive.id
        )
        guard !cached.isEmpty else { return false }
        observer.didEnumerate(self.s3Items(from: cached))
        return true
    }

    /// Converts cached MetadataStore rows back into `S3Item`s.
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

    // MARK: - Virtual folder synthesis (kept for callers that recursively list)

    /// Synthesizes virtual folder `S3Item`s for parent directories that don't
    /// have explicit 0-byte marker objects in S3. Used by call sites that
    /// recursively list keys (e.g. during deep materialisation) to build a
    /// complete folder hierarchy.
    static func synthesizeVirtualFolders(
        from items: [S3Item],
        drive: DS3Drive,
        prefix: String?
    ) -> [S3Item] {
        let existingKeys = Set(items.map(\.itemIdentifier.rawValue))
        return synthesizeVirtualFolders(fromKeys: existingKeys, drive: drive, prefix: prefix)
    }

    /// Key-based overload that avoids retaining full S3Item objects.
    static func synthesizeVirtualFolders(
        fromKeys existingKeys: Set<String>,
        drive: DS3Drive,
        prefix: String?
    ) -> [S3Item] {
        var synthesized: [S3Item] = []
        var seenDirs: Set<String> = []

        for key in existingKeys {
            let components = key.split(
                separator: DefaultSettings.S3.delimiter,
                omittingEmptySubsequences: true
            )

            for idx in 1 ..< components.count {
                let dirKey = components[0 ..< idx].joined(separator: String(DefaultSettings.S3.delimiter))
                    + String(DefaultSettings.S3.delimiter)

                if dirKey == prefix { continue }
                if let prefix, !dirKey.hasPrefix(prefix) { continue }
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
}

/// An enumerator that immediately finishes with no items.
/// Used for unsupported containers to avoid FP -1005 errors on startup.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {
        // No resources to release
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
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
