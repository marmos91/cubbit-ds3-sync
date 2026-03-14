import Foundation
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib

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
            let date = (try? await metadataStore.fetchSyncAnchorSnapshot(driveId: driveId))?.lastSyncDate ?? Date()
            cb.handler(NSFileProviderSyncAnchor(date))
        }
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Task {
            do {
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing)

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
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateItems S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch {
                self.logger.error("enumerateItems failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .indexing)

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

                // Create new sync anchor from current date
                let newAnchor = NSFileProviderSyncAnchor(Date())

                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch let error as FileProviderExtensionError {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toPresentableError())
            } catch let error as S3ErrorType {
                self.logger.error("enumerateChanges S3 error for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.errorCode, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
                return observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch is SyncEngineError {
                self.logger.warning("Sync engine unavailable (network): skipping change enumeration")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .idle)
                return observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } catch {
                self.logger.error("enumerateChanges failed for drive \(self.drive.id, privacy: .public) prefix \(self.prefix ?? "nil", privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.notificationManager.sendDriveChangedNotificationWithDebounce(status: .error)
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
