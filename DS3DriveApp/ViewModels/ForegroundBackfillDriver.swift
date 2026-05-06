#if os(iOS)
    import DS3Lib
    @preconcurrency import FileProvider
    import Foundation
    import os.log
    import SwiftUI
    import ThumbnailQueue
    import ThumbnailRendering

    /// Drains the iOS thumbnail render queue while the app is in the foreground.
    ///
    /// Lifecycle: instantiated once at app launch and held in @State. When the app
    /// becomes active, starts a drain loop. When it moves to background/inactive, the
    /// loop is cancelled after the current in-flight item finishes. Darwin notifications
    /// from the extension wake the driver if it is idle.
    @Observable
    @MainActor
    final class ForegroundBackfillDriver {
        /// Count of items still waiting to be rendered, across all drives.
        var pendingCount: Int = 0
        /// True while the drain loop is running.
        var isRunning: Bool = false

        private let driveManager: DS3DriveManager
        private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.thumbnail.rawValue)
        private var drainTask: Task<Void, Never>?
        private var darwinObservation: DarwinNotificationObservation?

        /// One DS3Client per drive UUID. Reusing the client avoids spawning new NIO event loops
        /// and HTTP client threads for every thumbnail render when the backlog is large.
        /// Call `invalidateS3Client(for:)` when a drive is disconnected to release the event loop.
        private var ds3ClientCache: [UUID: DS3Client] = [:]

        /// MetadataStore handle, used by `renderOne` to stamp
        /// `thumbnailReadyAt` on the row after each sidecar PUT (issue #153).
        /// Set asynchronously by `setupMetadataStore()` after init returns —
        /// `ModelContainer` creation/migration touches disk, so we keep it
        /// off the main thread at app launch. Until setup completes (or if
        /// it fails), `markThumbnailReady` no-ops; backfill still completes
        /// and the Files.app cache invalidation degrades to "wait until next
        /// etag drift / user tap".
        ///
        /// `@ObservationIgnored` because this is private state never consumed
        /// by SwiftUI views; skipping accessor synthesis avoids spurious
        /// re-renders on the main app's drives list every time backfill writes.
        @ObservationIgnored private var metadataStore: MetadataStore?

        init(driveManager: DS3DriveManager) {
            self.driveManager = driveManager
            darwinObservation = DarwinNotificationCenter.shared.addObserver(
                name: DarwinNotificationCenter.thumbnailRenderRequest
            ) { [weak self] in
                Task { @MainActor in self?.wakeIfIdle() }
            }
            // Build the SwiftData container off the main thread — schema
            // migration and disk I/O can block on cold launch. The store is
            // optional, so until this completes `markThumbnailReady` no-ops
            // (the call site already tolerates a nil store).
            Task.detached(priority: .utility) { [weak self] in
                let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.thumbnail.rawValue)
                do {
                    let container = try MetadataStore.createContainer()
                    let store = MetadataStore(modelContainer: container)
                    await self?.assignMetadataStore(store)
                } catch {
                    logger.warning(
                        // swiftlint:disable:next line_length
                        "Backfill: MetadataStore unavailable, thumbnailReadyAt signalling disabled: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        private func assignMetadataStore(_ store: MetadataStore) {
            metadataStore = store
        }

        /// Call from scenePhase onChange in the app root.
        func handleScenePhase(_ phase: ScenePhase) {
            logger.info("Backfill: scenePhase=\(String(describing: phase), privacy: .public)")
            if phase == .active {
                startDrain()
            } else {
                stopDrain()
            }
        }

        // MARK: - Private

        private func startDrain() {
            guard drainTask == nil else {
                logger.info("Backfill: startDrain skipped — already running")
                return
            }
            logger.info("Backfill: starting drain loop")
            isRunning = true
            drainTask = Task { @MainActor [weak self] in
                await self?.drainLoop()
            }
        }

        private func stopDrain() {
            logger.info("Backfill: stopping drain loop")
            drainTask?.cancel()
            drainTask = nil
            isRunning = false
        }

        private func wakeIfIdle() {
            logger.info("Backfill: Darwin wake — drainTask=\(self.drainTask == nil ? "nil" : "live", privacy: .public)")
            guard drainTask == nil || drainTask?.isCancelled == true else { return }
            startDrain()
        }

        /// Returns a cached DS3Client for the given drive, creating one if needed.
        ///
        /// Reusing a single client per drive avoids spawning fresh NIO event loops and
        /// HTTP connection pools for every thumbnail in a large backfill batch.
        private func cachedDS3Client(for drive: DS3Drive) throws -> DS3Client {
            if let cached = ds3ClientCache[drive.id] {
                return cached
            }
            let client = try DS3Client(drive: drive)
            ds3ClientCache[drive.id] = client
            return client
        }

        /// Shuts down and removes the cached DS3Client for the given drive.
        ///
        /// Call this when a drive is disconnected (e.g., from `DriveDetailView.disconnectDrive`)
        /// so the underlying NIO event loop is released promptly.
        func invalidateS3Client(for driveId: UUID) {
            if let client = ds3ClientCache.removeValue(forKey: driveId) {
                client.shutdown()
            }
        }

        private func drainLoop() async {
            while !Task.isCancelled {
                let processed = await drainBatch(maxItems: Int.max)
                if processed == 0 {
                    try? await Task.sleep(for: .seconds(2))
                    pendingCount = await ThumbnailRenderQueue.shared.pendingCount
                }
            }

            isRunning = false
            drainTask = nil
        }

        /// Processes up to `maxItems` pending thumbnail items. Returns the number actually processed.
        ///
        /// Called by both the foreground drain loop and the background processing task handler
        /// (`BGProcessingTask`). Passing `Int.max` from the drain loop is equivalent to the
        /// original unbounded behaviour.
        func drainBatch(maxItems: Int) async -> Int {
            let queue = ThumbnailRenderQueue.shared
            var processed = 0

            // Cellular gate: check once per drain. If blocked, return 0 so the
            // outer loop sleeps instead of spinning on dequeue → renderOne →
            // skip → dequeue (renderOne returns early without completing the
            // item, so the same key would be redelivered forever).
            guard ThumbnailNetworkPolicy.shared.isAllowed() else {
                logger.info("Backfill: drainBatch blocked by cellular gate")
                return 0
            }

            let initial = await queue.pendingCount
            if initial > 0 {
                logger.info("Backfill: drainBatch starting — pending=\(initial, privacy: .public)")
            }

            while processed < maxItems {
                let batch = await queue.dequeue(maxItems: 1)
                guard let item = batch.first else { break }
                await renderOne(item)
                processed += 1
                pendingCount = await queue.pendingCount
            }

            return processed
        }

        /// Signals an enumerator on `manager` and logs warnings on failure.
        /// The label is used purely for log output (the parent key, or
        /// `"workingSet"`).
        private func signalEnumerator(
            _ manager: NSFileProviderManager?,
            container: NSFileProviderItemIdentifier,
            label: String
        ) async {
            do {
                try await manager?.signalEnumerator(for: container)
            } catch {
                logger.warning(
                    "Backfill: signalEnumerator(\(label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // swiftlint:disable:next function_body_length
        private func renderOne(_ item: ThumbnailRenderQueueItem) async {
            let queue = ThumbnailRenderQueue.shared

            // Cellular gate is checked once per drainBatch — the network state
            // does not flip between dequeue and renderOne, so re-checking here
            // would only duplicate the path-monitor lookup. (1)

            // 2. Drive lookup
            guard let drive = driveManager.driveWithID(item.driveID) else {
                logger.warning("Backfill: drive \(item.driveID, privacy: .public) not found — dropping item")
                await queue.complete(item)
                return
            }

            // 3. S3 client — reuse the cached DS3Client for this drive to avoid spawning new
            //    NIO event loops and HTTP connection pools on every render iteration.
            let s3Client: DS3S3Client
            do {
                let ds3Client = try cachedDS3Client(for: drive)
                guard let client = ds3Client.driveS3Client else {
                    logger.error("Backfill: no S3 client for \(item.s3Key, privacy: .public)")
                    await queue.fail(item)
                    return
                }
                s3Client = client
            } catch {
                logger.error(
                    "Backfill: S3 init failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await queue.fail(item)
                return
            }

            // 4. Download original to temp file (stream directly to disk — no 2× memory peak)
            let ext = (item.s3Key as NSString).pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
            // defer MUST be registered before any early return so the temp file is always cleaned up.
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let bucket = drive.syncAnchor.bucket.name
            // Create an empty file so FileHandle(forWritingTo:) can open it.
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                logger.error("Backfill: could not create temp file for \(item.s3Key, privacy: .public)")
                await queue.fail(item)
                return
            }
            do {
                _ = try await s3Client.getObject(bucket: bucket, key: item.s3Key, toFile: tempURL)
            } catch is CancellationError {
                // Drain task cancelled (scenePhase → background). Don't burn an
                // attempt — the item should retry on next foreground tick.
                logger.info("Backfill: download cancelled for \(item.s3Key, privacy: .public) — leaving in queue")
                return
            } catch {
                logger.error(
                    "Backfill: download failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await queue.fail(item)
                return
            }

            // 5. Render JPEG off main thread — CPU-intensive
            let renderResult = await Task.detached(priority: .utility) {
                autoreleasepool { ThumbnailRenderer().renderJPEG(from: tempURL) }
            }.value

            let jpegBytes: Data
            switch renderResult {
            case let .success(bytes):
                jpegBytes = bytes
            case let .failure(reason):
                logger.info(
                    "Backfill: render failed for \(item.s3Key, privacy: .public) — \(reason.rawValue, privacy: .public)"
                )
                await queue.fail(item)
                return
            }

            // 6. PUT thumbnail
            let thumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: item.s3Key,
                drivePrefix: drive.syncAnchor.prefix
            )
            // Backfill has no fresh source ETag (the original was uploaded long
            // before this driver ran). Pass nil so `putThumbnail` omits the
            // `x-amz-meta-source-etag` field entirely — absence signals
            // "unknown source" (Issue #155) instead of writing an empty string
            // that defeats stale-thumbnail detection.
            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket, key: thumbKey, data: jpegBytes, sourceETag: nil
                )
            } catch is CancellationError {
                logger.info("Backfill: PUT cancelled for \(thumbKey, privacy: .public) — leaving in queue")
                return
            } catch {
                logger.error(
                    "Backfill: PUT failed for \(thumbKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await queue.fail(item)
                return
            }

            // 6.5. Stamp `thumbnailReadyAt` on the MetadataStore row so
            //      `WorkingSetEnumerator.enumerateChanges` re-emits the item
            //      and Files.app invalidates its per-item thumbnail cache
            //      (issue #153). Errors logged + swallowed: the working-set
            //      signal below is still useful as a fallback for items
            //      whose row was purged between enqueue and PUT.
            if let metadataStore {
                do {
                    try await metadataStore.markThumbnailReady(s3Key: item.s3Key, driveId: drive.id)
                } catch {
                    logger.warning(
                        // swiftlint:disable:next line_length
                        "Backfill: markThumbnailReady failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            // 7. Signal File Provider so iOS Files re-fetches thumbnails for this drive.
            //    Working-set signal alone is not enough — Files.app caches per-container
            //    thumbnail responses, so the parent container must also be invalidated.
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                displayName: drive.name
            )
            let manager = NSFileProviderManager(for: domain)
            let parentKey = (item.s3Key as NSString).deletingLastPathComponent
            let parentId: NSFileProviderItemIdentifier = parentKey.isEmpty
                ? .rootContainer
                : NSFileProviderItemIdentifier(rawValue: parentKey + "/")
            await signalEnumerator(manager, container: .workingSet, label: "workingSet")
            await signalEnumerator(manager, container: parentId, label: parentKey)

            // 8. Mark complete
            await queue.complete(item)
            logger.info("Backfill: done for \(item.s3Key, privacy: .public) → \(thumbKey, privacy: .public)")
        }
    }
#endif
