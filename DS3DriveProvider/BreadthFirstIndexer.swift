import DS3Lib
import FileProvider
import Foundation
import os.log

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
                let trashPrefix = S3Lib.fullTrashPrefix(forDrive: drive)

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

                        if key.hasPrefix(trashPrefix) { continue }

                        upsertBatch.append(MetadataStore.ItemUpsertData(from: item))

                        if key.hasSuffix(delimiter) && key != prefix {
                            discoveredSubfolders.append(key)
                        }
                    }
                } while continuationToken != nil

                if let metadataStore {
                    if !upsertBatch.isEmpty {
                        try await metadataStore.batchUpsertItems(upsertBatch)
                    }

                    // Prune cached items no longer in S3 for this folder.
                    // Runs even when upsertBatch is empty (folder fully emptied on S3).
                    let keepKeys = Set(upsertBatch.map(\.s3Key))
                    let drivePrefix = drive.syncAnchor.prefix ?? ""
                    let parentKey: String? = (prefix == drivePrefix) ? nil : prefix
                    try await metadataStore.pruneChildren(
                        parentKey: parentKey,
                        driveId: drive.id,
                        keepKeys: keepKeys
                    )
                }

                logger.debug("BFS indexed \(upsertBatch.count) items at prefix \(prefix.isEmpty ? "<root>" : prefix, privacy: .public)")

                if !discoveredSubfolders.isEmpty {
                    await queueManager.enqueue(discoveredSubfolders)
                }

                // Signal the specific folder container so Finder picks up new items.
                // On iOS, skip signaling entirely — it triggers re-enumeration that
                // overwrites items and causes folder/file icons to disappear in Files.
                // The MetadataStore cache is updated above; per-folder enumeration
                // will serve it on next navigation.
                #if os(macOS)
                let container: NSFileProviderItemIdentifier = prefix.isEmpty
                    ? .rootContainer
                    : NSFileProviderItemIdentifier(rawValue: prefix)
                try? await manager?.signalEnumerator(for: container)
                #endif
            } catch {
                logger.error("BFS listing failed for prefix \(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            if !Task.isCancelled {
                #if os(iOS)
                // iOS has a limited networking grace period — use 2x delay to reduce
                // network pressure and extend the budget for user-initiated S3 requests.
                try? await Task.sleep(for: .milliseconds(DefaultSettings.S3.bfsLevelDelayMs * 2))
                #else
                try? await Task.sleep(for: .milliseconds(DefaultSettings.S3.bfsLevelDelayMs))
                #endif
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
