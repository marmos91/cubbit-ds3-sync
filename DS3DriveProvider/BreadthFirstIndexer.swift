import Foundation
@preconcurrency import FileProvider
import os.log
import DS3Lib

/// Proactive breadth-first indexer that enumerates the S3 bucket level-by-level
/// using delimited (non-recursive) listings. This ensures shallow folders are
/// discovered before deep descendants, so Finder can serve them from the
/// MetadataStore cache almost instantly.
///
/// Lifecycle: created and started in `FileProviderExtension.init`, stopped in `invalidate()`.
final class BreadthFirstIndexer: @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: "BFS")

    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let metadataStore: MetadataStore?
    private let manager: NSFileProviderManager?
    private let notificationManager: NotificationManager?

    /// Actor that manages the BFS queue and priority bumping.
    private let queueManager = QueueManager()

    private var task: Task<Void, Never>?

    init(
        s3Lib: S3Lib,
        drive: DS3Drive,
        metadataStore: MetadataStore?,
        manager: NSFileProviderManager?,
        notificationManager: NotificationManager?
    ) {
        self.s3Lib = s3Lib
        self.drive = drive
        self.metadataStore = metadataStore
        self.manager = manager
        self.notificationManager = notificationManager
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }

        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }

        logger.info("BFS indexer started for drive \(self.drive.id, privacy: .public)")
    }

    func stop() {
        task?.cancel()
        task = nil
        logger.info("BFS indexer stopped for drive \(self.drive.id, privacy: .public)")
    }

    /// Bumps a prefix to the front of the BFS queue so it is enumerated next.
    /// Called when the user navigates to an uncached folder.
    func prioritize(prefix: String) {
        Task {
            await queueManager.prioritize(prefix)
            logger.debug("BFS prioritized prefix \(prefix, privacy: .public)")
        }
    }

    // MARK: - Run Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await runOneBFSPass()

            guard !Task.isCancelled else { return }

            // Wait between full cycles
            try? await Task.sleep(for: .seconds(DefaultSettings.S3.bfsCycleIntervalSeconds))
        }
    }

    /// Performs a single root-to-leaf BFS pass.
    private func runOneBFSPass() async {
        let rootPrefix = drive.syncAnchor.prefix ?? ""
        await queueManager.reset(rootPrefix: rootPrefix)

        logger.info("BFS pass starting from prefix \(rootPrefix, privacy: .public)")

        let semaphore = AsyncSemaphore(value: DefaultSettings.S3.bfsListConcurrency)
        let delimiter = String(DefaultSettings.S3.delimiter)
        let prefixSegmentCount = rootPrefix.split(separator: DefaultSettings.S3.delimiter).count

        while !Task.isCancelled {
            // Check pause state
            if let driveId = try? drive.id,
               (try? SharedData.default().isDrivePaused(driveId)) == true {
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            guard let prefix = await queueManager.dequeue() else {
                break // Queue empty — pass complete
            }

            await semaphore.wait()
            defer { Task { await semaphore.signal() } }

            do {
                var continuationToken: String?
                var discoveredSubfolders: [String] = []
                var upsertBatch: [MetadataStore.ItemUpsertData] = []

                // Paginate through all items at this level
                repeat {
                    guard !Task.isCancelled else { return }

                    let (items, nextToken) = try await s3Lib.listS3Items(
                        forDrive: drive,
                        withPrefix: prefix.isEmpty ? nil : prefix,
                        recursively: false,
                        withContinuationToken: continuationToken
                    )
                    continuationToken = nextToken

                    for item in items {
                        let key = item.itemIdentifier.rawValue
                        upsertBatch.append(MetadataStore.ItemUpsertData(from: item))

                        // Discover subfolder prefixes to enqueue
                        if key.hasSuffix(delimiter) && key != prefix {
                            discoveredSubfolders.append(key)
                        }
                    }

                    // Synthesize implicit parent folders between this prefix and any
                    // deep items returned (shouldn't happen with delimiter, but be safe)
                    synthesizeImplicitParents(
                        from: items,
                        delimiter: delimiter,
                        prefixSegmentCount: prefixSegmentCount,
                        into: &upsertBatch
                    )
                } while continuationToken != nil

                // Batch upsert all items from this prefix
                if let metadataStore, !upsertBatch.isEmpty {
                    try await metadataStore.batchUpsertItems(upsertBatch)
                }

                logger.debug("BFS indexed \(upsertBatch.count) items at prefix \(prefix.isEmpty ? "<root>" : prefix, privacy: .public)")

                // Enqueue discovered subfolders for next levels
                if !discoveredSubfolders.isEmpty {
                    await queueManager.enqueue(discoveredSubfolders)
                }

                // Signal the system so Finder picks up newly cached items
                do {
                    try await manager?.signalEnumerator(for: .workingSet)
                } catch {
                    logger.warning("BFS failed to signal working set: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                logger.error("BFS listing failed for prefix \(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Continue with next prefix rather than aborting the whole pass
            }

            // Small delay between prefixes to avoid starving user operations
            if !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(DefaultSettings.S3.bfsLevelDelayMs))
            }
        }

        logger.info("BFS pass complete for drive \(self.drive.id, privacy: .public)")
    }

    // MARK: - Helpers

    /// Synthesizes implicit parent folder entries for items whose parent folders
    /// were not explicitly returned by the S3 listing.
    private func synthesizeImplicitParents(
        from items: [S3Item],
        delimiter: String,
        prefixSegmentCount: Int,
        into batch: inout [MetadataStore.ItemUpsertData]
    ) {
        for item in items {
            let key = item.itemIdentifier.rawValue
            guard !key.hasSuffix(delimiter) else { continue }

            var segments = key.split(separator: DefaultSettings.S3.delimiter)
            segments.removeLast()

            while segments.count > prefixSegmentCount {
                let folderKey = segments.joined(separator: delimiter) + delimiter
                if batch.contains(where: { $0.s3Key == folderKey }) { break }

                let folderParentKey: String? = segments.count == prefixSegmentCount + 1
                    ? nil
                    : segments.dropLast().joined(separator: delimiter) + delimiter

                batch.append(MetadataStore.ItemUpsertData(
                    s3Key: folderKey,
                    driveId: drive.id,
                    syncStatus: .synced,
                    parentKey: folderParentKey,
                    size: 0
                ))
                segments.removeLast()
            }
        }
    }
}

// MARK: - Queue Manager

extension BreadthFirstIndexer {
    /// Thread-safe FIFO queue with priority bump support.
    actor QueueManager {
        private var queue: [String] = []

        /// Resets the queue with the root prefix for a new pass.
        func reset(rootPrefix: String) {
            queue = [rootPrefix]
        }

        /// Removes and returns the next prefix to enumerate, or nil if empty.
        func dequeue() -> String? {
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }

        /// Appends new prefixes to the back of the queue.
        func enqueue(_ prefixes: [String]) {
            queue.append(contentsOf: prefixes)
        }

        /// Moves a prefix to the front of the queue if present, or inserts it at the front.
        func prioritize(_ prefix: String) {
            if let idx = queue.firstIndex(of: prefix) {
                queue.remove(at: idx)
            }
            queue.insert(prefix, at: 0)
        }
    }
}
