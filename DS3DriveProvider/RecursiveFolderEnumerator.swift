import Foundation
@preconcurrency import FileProvider
import os.log
import DS3Lib

/// Performs paginated recursive enumeration of a folder tree in S3.
/// Used when the system materializes a folder (e.g. "Download Now") to discover
/// all descendants so the File Provider can download them.
///
/// Uses a single flat recursive listing (no delimiter) so all items are discovered
/// quickly — this stabilizes the total item count early, giving linear progress in Finder.
/// After each page, items are batch-upserted into MetadataStore and the working set
/// enumerator is signaled so downloads can begin immediately.
final class RecursiveFolderEnumerator: @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let metadataStore: MetadataStore?
    private let manager: NSFileProviderManager?
    private let notificationManager: NotificationManager?

    init(
        s3Lib: S3Lib,
        drive: DS3Drive,
        metadataStore: MetadataStore?,
        manager: NSFileProviderManager?,
        notificationManager: NotificationManager? = nil
    ) {
        self.s3Lib = s3Lib
        self.drive = drive
        self.metadataStore = metadataStore
        self.manager = manager
        self.notificationManager = notificationManager
    }

    /// Entry point — enumerates all descendants of `folderPrefix` using a flat recursive listing.
    func enumerateRecursively(folderPrefix: String) async {
        logger.info("Recursive enumeration starting for prefix \(folderPrefix, privacy: .public)")

        let delimiter = DefaultSettings.S3.delimiter
        let delimiterString = String(delimiter)
        let prefixSegmentCount = folderPrefix.split(separator: delimiter).count
        var continuationToken: String?
        var totalItemCount = 0

        repeat {
            guard !Task.isCancelled else { return }

            do {
                let (items, nextToken) = try await s3Lib.listS3Items(
                    forDrive: drive,
                    withPrefix: folderPrefix,
                    recursively: true,
                    withContinuationToken: continuationToken
                )
                continuationToken = nextToken

                // Build upsert data from S3 items and synthesize implicit parent folders.
                var upsertMap: [String: MetadataStore.ItemUpsertData] = [:]

                for item in items {
                    let key = item.itemIdentifier.rawValue
                    upsertMap[key] = MetadataStore.ItemUpsertData(from: item)

                    // Synthesize implicit parent folders (same logic as S3LibListingAdapter).
                    // When listing recursively, S3 only returns objects — intermediate folders
                    // without explicit zero-byte markers are absent.
                    var segments = key.split(separator: delimiter)
                    segments.removeLast()

                    while segments.count > prefixSegmentCount {
                        let folderKey = segments.joined(separator: delimiterString) + delimiterString

                        if upsertMap[folderKey] != nil {
                            break
                        }

                        let folderParentKey: String? = segments.count == prefixSegmentCount + 1
                            ? nil
                            : segments.dropLast().joined(separator: delimiterString) + delimiterString

                        upsertMap[folderKey] = MetadataStore.ItemUpsertData(
                            s3Key: folderKey,
                            driveId: drive.id,
                            syncStatus: .synced,
                            parentKey: folderParentKey,
                            size: 0
                        )

                        segments.removeLast()
                    }
                }

                // Batch upsert all items + synthesized folders in a single DB save.
                if let metadataStore, !upsertMap.isEmpty {
                    try await metadataStore.batchUpsertItems(Array(upsertMap.values))
                }

                totalItemCount += upsertMap.count
                logger.debug("Recursive enumeration page: \(upsertMap.count) items (total \(totalItemCount)) for \(folderPrefix, privacy: .public)")

                // Signal working set so the system discovers items and can start downloads.
                do {
                    try await manager?.signalEnumerator(for: .workingSet)
                } catch {
                    logger.warning("Failed to signal working set during recursive enum: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                logger.error("Recursive enumeration failed for prefix \(folderPrefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
                notificationManager?.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
                return
            }
        } while continuationToken != nil

        logger.info("Recursive enumeration complete for prefix \(folderPrefix, privacy: .public): \(totalItemCount) items total")
        notificationManager?.sendDriveChangedNotificationWithDebounce(status: .idle, isFileOperation: false)
    }
}
