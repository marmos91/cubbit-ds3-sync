import Foundation
import os.log

public actor ThumbnailBackfillCoordinator {
    private let metadataStore: MetadataStore
    private let s3Client: any DS3S3ClientProtocol
    private let drive: DS3Drive
    private let logger = Logger(
        subsystem: LogSubsystem.app,
        category: LogCategory.thumbnail.rawValue
    )

    public init(
        metadataStore: MetadataStore,
        s3Client: any DS3S3ClientProtocol,
        drive: DS3Drive
    ) {
        self.metadataStore = metadataStore
        self.s3Client = s3Client
        self.drive = drive
    }

    public struct BatchResult: Sendable {
        public let processed: Int
        public let succeeded: Int
        public let skipped: Int
        public let failed: Int
        public let totalPending: Int
    }

    public func runBatch(maxItems: Int) async throws -> BatchResult {
        #if !os(macOS)
            // Phase 12 ships zero iOS callers; Phase 14 replaces this branch.
            return BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0)
        #else
            // fetchPendingThumbnails reclassifies non-raster items to .notApplicable
            // as a side effect, so non-raster rows can't dominate future fetches.
            let pending = try await metadataStore.fetchPendingThumbnails(
                driveId: drive.id, limit: maxItems
            )
            let totalPending = try await metadataStore.countPendingRasterThumbnails(driveId: drive.id)

            guard !pending.isEmpty else {
                return BatchResult(
                    processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: totalPending
                )
            }

            var succeeded = 0
            var skipped = 0
            var failed = 0

            let bucket = drive.syncAnchor.bucket.name
            let drivePrefix = drive.syncAnchor.prefix

            for item in pending {
                let outcome = await processItem(
                    item, bucket: bucket, drivePrefix: drivePrefix
                )
                switch outcome {
                case .succeeded: succeeded += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                }
            }

            return BatchResult(
                processed: pending.count,
                succeeded: succeeded,
                skipped: skipped,
                failed: failed,
                totalPending: totalPending
            )
        #endif
    }

    #if os(macOS)
        private enum Outcome {
            case succeeded
            case skipped
            case failed
        }

        private func transition(
            _ item: MetadataStore.PendingThumbnail, to status: ThumbnailStatus
        ) async {
            do {
                try await metadataStore.setThumbnailStatus(
                    s3Key: item.s3Key, driveId: drive.id, status: status
                )
            } catch {
                logger.error(
                    "Backfill: failed to persist \(status.rawValue, privacy: .public) for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        private func markFailed(_ item: MetadataStore.PendingThumbnail) async -> Outcome {
            await transition(item, to: .failed)
            return .failed
        }

        private func processItem(
            _ item: MetadataStore.PendingThumbnail,
            bucket: String,
            drivePrefix: String?
        ) async -> Outcome {
            let tempURL: URL
            do {
                tempURL = try temporaryFileURL(
                    withTemporaryFolder: FileManager.default.temporaryDirectory
                )
            } catch {
                logger.error(
                    "Backfill: temp file alloc failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return await markFailed(item)
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                _ = try await s3Client.getObject(
                    bucket: bucket, key: item.s3Key, toFile: tempURL, onProgress: nil
                )
            } catch {
                logger.error(
                    "Backfill: download failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return await markFailed(item)
            }

            guard let thumbnailData = ThumbnailRenderer().renderJPEG(from: tempURL) else {
                logger.info(
                    "Backfill: render returned nil for \(item.s3Key, privacy: .public) — marking failed"
                )
                return await markFailed(item)
            }

            let thumbnailKey = S3PathUtils.thumbnailKey(
                forOriginalKey: item.s3Key, drivePrefix: drivePrefix
            )

            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket,
                    key: thumbnailKey,
                    data: thumbnailData,
                    sourceETag: item.etag ?? ""
                )
            } catch {
                logger.error(
                    "Backfill: PUT failed for \(thumbnailKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return await markFailed(item)
            }

            await transition(item, to: .uploaded)
            return .succeeded
        }
    #endif
}
