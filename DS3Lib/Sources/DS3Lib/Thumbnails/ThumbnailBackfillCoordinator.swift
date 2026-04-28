import Foundation
import os.log

/// Sequential, per-drive thumbnail backfill engine.
///
/// **Lifecycle (Phase 12 D-30 / D-31):** one instance per drive, owned by the
/// BFS indexer. The actor keeps no per-batch state across `runBatch` calls
/// other than `currentTask` (used to plumb `cancelInFlight()` to the running
/// loop, see below).
///
/// **Phase 13-05 contracts:**
///   - **Thermal gate (D-19):** `runBatch` reads
///     `ProcessInfo.processInfo.thermalState` once at entry; on `.serious` /
///     `.critical` returns a zero `BatchResult` without touching S3.
///     `thermalStateProvider` is the closure used to read the thermal state;
///     production wires it to `ProcessInfo.processInfo.thermalState`, tests
///     inject a fixed value.
///   - **Pause gate (D-20):** `runBatch` checks `pauseProvider(drive.id)` at
///     function entry AND at the head of every item iteration. Production
///     wires `pauseProvider` to `SharedData.default().isDrivePaused(_:)`; tests
///     inject a closure. On pause observed mid-batch the loop exits cleanly
///     (no strike-count side effect on the unprocessed tail).
///   - **3-strike integration (D-29 / Plan 13-04):** render-nil and PUT-throw
///     failure paths route through `MetadataStore.setThumbnailFailure`. The
///     helper increments `thumbnailFailCount` and transitions
///     `thumbnailStatus` to `.failed` only on the third consecutive failure
///     (Pitfall 10 — `count >= 3`). The terminal `.failed` rows are excluded
///     from `fetchPendingThumbnails`, draining the query naturally.
///   - **Cancellation:** `Task.checkCancellation()` is called BEFORE
///     `getObject` and BEFORE `putThumbnail`, never DURING (D-20: in-flight
///     PUT must complete to avoid uploading a partial thumbnail). Cancellation
///     observed at an iteration boundary is NOT a failure — it does NOT route
///     through the strike helper.
///   - **Cancellation API:** callers cancel via Swift Concurrency's structured
///     propagation — `Task { try? await coordinator.runBatch(...) }` then
///     `task.cancel()`. The iteration-boundary `Task.checkCancellation()`
///     observes the cancellation and exits the loop cleanly. There is no
///     coordinator-level cancel flag — the structured cancellation signal is
///     authoritative.
public actor ThumbnailBackfillCoordinator {
    private let metadataStore: MetadataStore
    private let s3Client: any DS3S3ClientProtocol
    private let drive: DS3Drive
    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState
    private let pauseProvider: @Sendable (UUID) -> Bool
    private let logger = Logger(
        subsystem: LogSubsystem.app,
        category: LogCategory.thumbnail.rawValue
    )

    public init(
        metadataStore: MetadataStore,
        s3Client: any DS3S3ClientProtocol,
        drive: DS3Drive,
        thermalStateProvider: @Sendable @escaping () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        pauseProvider: @Sendable @escaping (UUID) -> Bool = { driveId in
            (try? SharedData.default().isDrivePaused(driveId)) ?? false
        }
    ) {
        self.metadataStore = metadataStore
        self.s3Client = s3Client
        self.drive = drive
        self.thermalStateProvider = thermalStateProvider
        self.pauseProvider = pauseProvider
    }

    public struct BatchResult: Sendable {
        public let processed: Int
        public let succeeded: Int
        public let skipped: Int
        public let failed: Int
        public let totalPending: Int
    }

    public func runBatch(maxItems: Int) async throws -> BatchResult {
        try await performBatch(maxItems: maxItems)
    }

    // MARK: - Batch core

    private func performBatch(maxItems: Int) async throws -> BatchResult {
        // (a) Thermal gate (D-19) — single read at function entry. Pitfall 7:
        // do NOT poll `thermalState` per item; the value rarely flips within a
        // 5-item batch and per-item reads are wasteful.
        let thermal = thermalStateProvider()
        if thermal == .serious || thermal == .critical {
            logger.info(
                "Backfill: skipping batch — thermalState=\(String(describing: thermal), privacy: .public)"
            )
            return BatchResult(
                processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0
            )
        }

        // (b) Pause gate at entry (D-20). Skip without touching S3 or the
        // metadata store — paused drives should be invisible to backfill.
        if pauseProvider(drive.id) {
            logger.info(
                "Backfill: skipping batch — drive \(self.drive.id.uuidString, privacy: .public) is paused"
            )
            return BatchResult(
                processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0
            )
        }

        #if !os(macOS)
            // Phase 12 ships zero iOS callers; Phase 14 replaces this branch.
            return BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0)
        #else
            return try await runBatchMacOS(maxItems: maxItems)
        #endif
    }

    #if os(macOS)
        private func runBatchMacOS(maxItems: Int) async throws -> BatchResult {
            // fetchPendingThumbnails reclassifies non-raster items to .notApplicable
            // as a side effect, so non-raster rows can't dominate future fetches.
            let pending = try await metadataStore.fetchPendingThumbnails(
                driveId: drive.id, limit: maxItems
            )

            guard !pending.isEmpty else {
                return BatchResult(
                    processed: 0, succeeded: 0, skipped: 0, failed: 0, totalPending: 0
                )
            }

            var succeeded = 0
            var skipped = 0
            var failed = 0
            var processed = 0

            let bucket = drive.syncAnchor.bucket.name
            let drivePrefix = drive.syncAnchor.prefix

            for item in pending {
                // (b') Per-iteration pause check (D-20). Pause flipped after
                // entry — break cleanly without counting the unprocessed tail.
                if pauseProvider(drive.id) {
                    logger.info(
                        "Backfill: pausing mid-batch at item \(item.s3Key, privacy: .public)"
                    )
                    break
                }

                // Outer-Task cancellation check (Swift Concurrency
                // structured propagation). CancellationError is NOT a
                // failure — exit the loop without touching the strike helper.
                do {
                    try Task.checkCancellation()
                } catch is CancellationError {
                    logger.info("Backfill: outer-Task cancellation observed at iteration boundary")
                    break
                } catch {
                    throw error
                }

                let outcome = await processItem(
                    item, bucket: bucket, drivePrefix: drivePrefix
                )
                processed += 1
                switch outcome {
                case .succeeded: succeeded += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                case .cancelled:
                    // The processItem boundary observed a CancellationError.
                    // Decrement processed (the item was not really attempted)
                    // and break the loop.
                    processed -= 1
                }
                if outcome == .cancelled { break }
            }

            return BatchResult(
                processed: processed,
                succeeded: succeeded,
                skipped: skipped,
                failed: failed,
                totalPending: 0
            )
        }

        private enum Outcome {
            case succeeded
            case skipped
            case failed
            case cancelled
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

        /// 3-strike-aware failure routing (D-29 / Plan 13-04). Increments the
        /// row's `thumbnailFailCount`; transitions to `.failed` only on the
        /// third consecutive failure.
        private func recordFailure(_ item: MetadataStore.PendingThumbnail) async -> Outcome {
            do {
                _ = try await metadataStore.setThumbnailFailure(
                    s3Key: item.s3Key, driveId: drive.id
                )
            } catch {
                logger.error(
                    "Backfill: setThumbnailFailure threw for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
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
                    "Backfill: temp file alloc failed for \(item.s3Key, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                return await recordFailure(item)
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }

            // Cancellation BEFORE the download — D-20: never check during
            // network I/O. Soto's getObject(toFile:) is a single await whose
            // cancellation cooperation is best-effort; the pre-network check
            // is the reliable boundary.
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                return .cancelled
            } catch {
                logger.error(
                    "Backfill: unexpected cancellation-check error for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return .cancelled
            }

            do {
                _ = try await s3Client.getObject(
                    bucket: bucket, key: item.s3Key, toFile: tempURL, onProgress: nil
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                logger.error(
                    "Backfill: download failed for \(item.s3Key, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                return await recordFailure(item)
            }

            guard let thumbnailData = ThumbnailRenderer().renderJPEG(from: tempURL) else {
                logger.info(
                    "Backfill: render returned nil for \(item.s3Key, privacy: .public) — incrementing strike"
                )
                return await recordFailure(item)
            }

            // No source ETag means staleness detection is impossible; route
            // through the strike helper rather than uploading a thumbnail
            // with empty source metadata.
            guard let sourceETag = item.etag, !sourceETag.isEmpty else {
                logger.info(
                    "Backfill: missing source ETag for \(item.s3Key, privacy: .public) — incrementing strike"
                )
                return await recordFailure(item)
            }

            let thumbnailKey = S3PathUtils.thumbnailKey(
                forOriginalKey: item.s3Key, drivePrefix: drivePrefix
            )

            // Cancellation BEFORE the PUT — D-20: once the PUT is in flight,
            // let it complete to avoid uploading a partial thumbnail.
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                return .cancelled
            } catch {
                logger.error(
                    "Backfill: unexpected cancellation-check error for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return .cancelled
            }

            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket,
                    key: thumbnailKey,
                    data: thumbnailData,
                    sourceETag: sourceETag
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                logger.error(
                    "Backfill: PUT failed for \(thumbnailKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                return await recordFailure(item)
            }

            await transition(item, to: .uploaded)
            return .succeeded
        }
    #endif
}
