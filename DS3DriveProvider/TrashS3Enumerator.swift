import Foundation
@preconcurrency import FileProvider
import os.log
import SotoS3
import DS3Lib

/// Enumerates items inside the `.trash/` prefix for a drive.
/// Simpler than `S3Enumerator` — no MetadataStore caching, no BFS,
/// just direct S3 listing with pagination.
class TrashS3Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)
    private let s3Lib: S3Lib
    private let drive: DS3Drive

    init(s3Lib: S3Lib, drive: DS3Drive) {
        self.s3Lib = s3Lib
        self.drive = drive
        super.init()
    }

    func invalidate() {}

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

                let (items, nextToken) = try await self.s3Lib.listTrashedItems(
                    forDrive: self.drive,
                    withContinuationToken: continuationToken
                )

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
        // Trash changes are infrequent — just ask the system to re-enumerate everything
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(NSFileProviderSyncAnchor(Date()))
    }
}
