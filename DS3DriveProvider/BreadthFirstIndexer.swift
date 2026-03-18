import Foundation
@preconcurrency import FileProvider
import os.log
import DS3Lib

#if os(macOS)

/// Proactive breadth-first indexer that enumerates the S3 bucket level-by-level
/// using delimited (non-recursive) listings. Shallow folders are discovered before
/// deep descendants, so Finder can serve them from the MetadataStore cache quickly.
final class BreadthFirstIndexer: @unchecked Sendable {
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: "BFS")

    private let s3Lib: S3Lib
    private let drive: DS3Drive
    private let metadataStore: MetadataStore?
    private let manager: NSFileProviderManager?
    private let queueManager = QueueManager()
    private var task: Task<Void, Never>?

    init(
        s3Lib: S3Lib,
        drive: DS3Drive,
        metadataStore: MetadataStore?,
        manager: NSFileProviderManager?
    ) {
        self.s3Lib = s3Lib
        self.drive = drive
        self.metadataStore = metadataStore
        self.manager = manager
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
            try? await Task.sleep(for: .seconds(DefaultSettings.S3.bfsCycleIntervalSeconds))
        }
    }

    private func runOneBFSPass() async {
        let rootPrefix = drive.syncAnchor.prefix ?? ""
        await queueManager.reset(rootPrefix: rootPrefix)

        logger.info("BFS pass starting from prefix \(rootPrefix, privacy: .public)")

        let delimiter = String(DefaultSettings.S3.delimiter)

        while !Task.isCancelled {
            if (try? SharedData.default().isDrivePaused(drive.id)) == true {
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            guard let prefix = await queueManager.dequeue() else { break }

            do {
                var continuationToken: String?
                var discoveredSubfolders: [String] = []
                var upsertBatch: [MetadataStore.ItemUpsertData] = []

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

                        if key.hasSuffix(delimiter) && key != prefix {
                            discoveredSubfolders.append(key)
                        }
                    }

                } while continuationToken != nil

                if let metadataStore, !upsertBatch.isEmpty {
                    try await metadataStore.batchUpsertItems(upsertBatch)
                }

                logger.debug("BFS indexed \(upsertBatch.count) items at prefix \(prefix.isEmpty ? "<root>" : prefix, privacy: .public)")

                if !discoveredSubfolders.isEmpty {
                    await queueManager.enqueue(discoveredSubfolders)
                }

                do {
                    try await manager?.signalEnumerator(for: .workingSet)
                } catch {
                    logger.warning("BFS failed to signal working set: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                logger.error("BFS listing failed for prefix \(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            if !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(DefaultSettings.S3.bfsLevelDelayMs))
            }
        }

        logger.info("BFS pass complete for drive \(self.drive.id, privacy: .public)")
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

#endif
