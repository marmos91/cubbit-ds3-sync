#if os(iOS)
    import DS3Lib
    @preconcurrency import FileProvider
    import Foundation
    import os.log
    import SwiftUI

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

        init(driveManager: DS3DriveManager) {
            self.driveManager = driveManager
            darwinObservation = DarwinNotificationCenter.shared.addObserver(
                name: DarwinNotificationCenter.thumbnailRenderRequest
            ) { [weak self] in
                Task { @MainActor in self?.wakeIfIdle() }
            }
        }

        /// Call from scenePhase onChange in the app root.
        func handleScenePhase(_ phase: ScenePhase) {
            if phase == .active {
                startDrain()
            } else {
                stopDrain()
            }
        }

        // MARK: - Private

        private func startDrain() {
            guard drainTask == nil else { return }
            isRunning = true
            drainTask = Task { @MainActor [weak self] in
                await self?.drainLoop()
            }
        }

        private func stopDrain() {
            drainTask?.cancel()
            drainTask = nil
            isRunning = false
        }

        private func wakeIfIdle() {
            guard drainTask == nil || drainTask?.isCancelled == true else { return }
            startDrain()
        }

        private func drainLoop() async {
            let queue = ThumbnailRenderQueue.shared

            while !Task.isCancelled {
                let batch = await queue.dequeue(maxItems: 1)

                if batch.isEmpty {
                    try? await Task.sleep(for: .seconds(2))
                    pendingCount = await queue.pendingCount
                    continue
                }

                await renderOne(batch[0])
                pendingCount = await queue.pendingCount
            }

            isRunning = false
            drainTask = nil
        }

        // swiftlint:disable:next function_body_length
        private func renderOne(_ item: ThumbnailRenderQueueItem) async {
            let queue = ThumbnailRenderQueue.shared

            // 1. Cellular gate
            guard ThumbnailNetworkPolicy.shared.isAllowed() else {
                logger.info("Backfill: skipping \(item.s3Key, privacy: .public) — cellular blocked")
                return
            }

            // 2. Drive lookup
            guard let drive = driveManager.driveWithID(item.driveID) else {
                logger.warning("Backfill: drive \(item.driveID, privacy: .public) not found — dropping item")
                await queue.complete(item)
                return
            }

            // 3. S3 client
            let s3Client: DS3S3Client
            do {
                let ds3Client = try DS3Client(drive: drive)
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

            // 4. Download original to temp file
            let ext = (item.s3Key as NSString).pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))

            let bucket = drive.syncAnchor.bucket.name
            do {
                let data = try await s3Client.getObjectData(bucket: bucket, key: item.s3Key)
                try data.write(to: tempURL)
            } catch {
                logger.error(
                    "Backfill: download failed for \(item.s3Key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await queue.fail(item)
                return
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }

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
            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket, key: thumbKey, data: jpegBytes, sourceETag: ""
                )
            } catch {
                logger.error(
                    "Backfill: PUT failed for \(thumbKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await queue.fail(item)
                return
            }

            // 7. Signal File Provider so iOS Files re-fetches thumbnails for this drive
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                displayName: drive.name
            )
            do {
                try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            } catch {
                logger.warning(
                    "Backfill: signalEnumerator failed for \(drive.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            // 8. Mark complete
            await queue.complete(item)
            logger.info("Backfill: done for \(item.s3Key, privacy: .public) → \(thumbKey, privacy: .public)")
        }
    }
#endif
