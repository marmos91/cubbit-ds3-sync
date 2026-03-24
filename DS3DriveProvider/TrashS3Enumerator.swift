import DS3Lib
@preconcurrency import FileProvider
import Foundation
import os.log

/// Enumerates items inside the `.trash/` prefix for a drive.
class TrashS3Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)
    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let metadataStore: MetadataStore?

    init(s3Lib: S3Lib, drive: DS3Drive, metadataStore: MetadataStore? = nil) {
        self.s3Lib = s3Lib
        self.drive = drive
        self.metadataStore = metadataStore
        super.init()
    }

    func invalidate() {
        // No resources to release
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        logger.info("TrashS3Enumerator: enumerateItems for drive \(self.drive.id, privacy: .public)")

        Task {
            do {
                // When paused, return empty
                if (try? SharedData.default().isDrivePaused(self.drive.id)) == true {
                    observer.finishEnumerating(upTo: nil)
                    return
                }

                let continuationToken = page.toContinuationToken()

                let (trashItems, nextToken) = try await self.s3Lib.listTrashedItems(
                    forDrive: self.drive,
                    withContinuationToken: continuationToken
                )

                var items: [S3Item] = []
                for trashItem in trashItems {
                    let trashKey = trashItem.itemIdentifier.rawValue
                    let originalKey = try? await self.metadataStore?.fetchOriginalKey(
                        forTrashKey: trashKey, driveId: self.drive.id
                    )

                    if let originalKey {
                        items.append(S3Item(
                            identifier: NSFileProviderItemIdentifier(originalKey),
                            drive: self.drive,
                            objectMetadata: S3Item.Metadata(
                                lastModified: trashItem.contentModificationDate,
                                size: trashItem.documentSize ?? 0
                            ),
                            forcedTrashed: true
                        ))
                    } else {
                        items.append(trashItem)
                    }
                }

                self.logger.info("TrashS3Enumerator: listed \(items.count) trashed items")

                if !items.isEmpty {
                    observer.didEnumerate(items)
                }

                let nextPage = nextToken.map { NSFileProviderPage($0) }
                observer.finishEnumerating(upTo: nextPage)
            } catch let error as S3ErrorType {
                self.logger.error("TrashS3Enumerator: S3 error \(error.errorCode, privacy: .public)")
                observer.finishEnumeratingWithError(error.toFileProviderError())
            } catch {
                self.logger.error("TrashS3Enumerator: error \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        logger.info("TrashS3Enumerator: enumerateChanges finishing with current anchor")
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        // Return a stable anchor so the system doesn't spin re-enumerating.
        // Changes are discovered via signalEnumerator(.trashContainer).
        completionHandler(NSFileProviderSyncAnchor(Data([0])))
    }
}
