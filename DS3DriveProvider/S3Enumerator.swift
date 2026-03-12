import Foundation
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib

/// Wraps a non-Sendable callback for safe use across Task boundaries.
/// The wrapper is safe because the underlying handler is set once at init and never mutated.
private final class UnsafeCallback<T>: @unchecked Sendable {
    let handler: T
    init(_ handler: T) { self.handler = handler }
}

enum EnumeratorError: Error {
    case unsupported
    case missingParameters
}

class S3Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

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
        self.prefix = self.drive.syncAnchor.prefix

        switch self.parent {
        case .rootContainer, .trashContainer, .workingSet:
            break
        default:
            self.prefix = parent.rawValue
        }

        super.init()
    }

    func invalidate() {}

    // NOTE: gets called when the extension wants to get the last sync point (could be a timestamp)
    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        guard let metadataStore = self.metadataStore else {
            // Fall back to current date if MetadataStore is unavailable
            completionHandler(NSFileProviderSyncAnchor(Date()))
            return
        }

        // Wrap non-Sendable callback for safe use across Task boundary
        let cb = UnsafeCallback(completionHandler)
        let driveId = self.drive.id

        Task {
            do {
                if let snapshot = try await metadataStore.fetchSyncAnchorSnapshot(driveId: driveId) {
                    cb.handler(NSFileProviderSyncAnchor(snapshot.lastSyncDate))
                } else {
                    // No anchor record yet -- return anchor from current date
                    cb.handler(NSFileProviderSyncAnchor(Date()))
                }
            } catch {
                cb.handler(NSFileProviderSyncAnchor(Date()))
            }
        }
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Task {
            do {
                self.notificationManager.sendDriveChangedNotification(status: .indexing)

                let (items, continuationToken) = try await self.s3Lib.listS3Items(
                    forDrive: self.drive,
                    withPrefix: self.prefix,
                    recursively: self.recursively,
                    withContinuationToken: page.toContinuationToken()
                )

                // Upsert items into MetadataStore for subsequent enumerateChanges calls
                if let metadataStore = self.metadataStore {
                    for item in items {
                        try await metadataStore.upsertItem(
                            s3Key: item.itemIdentifier.rawValue,
                            driveId: self.drive.id,
                            etag: item.metadata.etag,
                            lastModified: item.metadata.lastModified,
                            syncStatus: .synced,
                            parentKey: item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue,
                            contentType: item.metadata.contentType,
                            size: Int64(truncating: item.metadata.size)
                        )
                    }
                }

                if !items.isEmpty {
                    observer.didEnumerate(items)
                }

                let page = continuationToken.map { NSFileProviderPage($0) }

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumerating(upTo: page)

            } catch let error as FileProviderExtensionError {
                self.logger.error("A FileProvider error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("A S3 error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch {
                self.logger.error("A generic error occurred while list objects \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            self.notificationManager.sendDriveChangedNotification(status: .indexing)

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

                    self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
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
                if !changedKeys.isEmpty {
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
                }

                // Report deleted items
                if !result.deletedKeys.isEmpty {
                    let deletedIdentifiers = result.deletedKeys.map {
                        NSFileProviderItemIdentifier($0)
                    }
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                // Create new sync anchor from current date
                let newAnchor = NSFileProviderSyncAnchor(Date())

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                self.logger.error("An error occurred while enumerating changes: \(error)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error)
            }
        }
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
