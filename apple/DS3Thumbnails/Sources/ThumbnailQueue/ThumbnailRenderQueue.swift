import Darwin
import DS3Lib
import Foundation
import os.log

private let queueLogger = Logger(
    subsystem: LogSubsystem.app,
    category: LogCategory.thumbnail.rawValue
)

/// One item in the thumbnail render backlog used by the iOS extension/main-app handoff.
/// The extension appends when it gets a cache miss (or after a new raster upload).
/// The main app drains by downloading the original, rendering a JPEG, and PUTting to S3.
public struct ThumbnailRenderQueueItem: Codable, Sendable, Equatable {
    public let driveID: UUID
    public let s3Key: String
    public var addedAt: Date
    public var attempts: Int

    public init(driveID: UUID, s3Key: String, addedAt: Date = Date(), attempts: Int = 0) {
        self.driveID = driveID
        self.s3Key = s3Key
        self.addedAt = addedAt
        self.attempts = attempts
    }
}

/// JSON-backed persistent queue for iOS thumbnail render requests.
///
/// Extension writes via `append`; main app drains via `dequeue`/`complete`/`fail`.
/// Actor serializes within-process; a sidecar `flock(LOCK_EX)` lockfile serializes
/// across processes so the extension cannot revive a completed item by writing its
/// stale in-memory snapshot over the main app's just-persisted state.
///
/// Deduplication: `append` is a no-op if (driveID, s3Key) already exists.
/// Poison: items with `attempts >= maxAttempts` are excluded from `dequeue` results
/// but remain in the JSON file for inspection.
public actor ThumbnailRenderQueue {
    /// Maximum render attempts before an item is considered poison.
    public static let maxAttempts = 3

    /// Minimum age before a poisoned item can be revived by a new `append` call.
    /// Prevents thrashing when an item keeps failing for a real reason: each
    /// burst of cache-misses from Files.app would otherwise reset attempts and
    /// drain it again, paying the download+render cost on every browse.
    public static let revivalCooldownSeconds: TimeInterval = 3600

    /// Shared singleton backed by the App Group container.
    public static let shared = ThumbnailRenderQueue()

    private var items: [ThumbnailRenderQueueItem] = []
    private let fileURL: URL?
    private let lockURL: URL?

    private init() {
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)?
            .appendingPathComponent(DefaultSettings.FileNames.thumbnailRenderQueueFileName)
        fileURL = url
        lockURL = url?.appendingPathExtension("lock")
    }

    /// For testing only: backed by the given URL instead of the App Group container.
    public init(testFileURL: URL) {
        fileURL = testFileURL
        lockURL = testFileURL.appendingPathExtension("lock")
    }

    // MARK: - Queue Operations

    /// Appends an item if (driveID, s3Key) is not already present. If a duplicate
    /// exists with `attempts >= maxAttempts` (poisoned) AND was added more than
    /// `revivalCooldownSeconds` ago, its attempts are reset and `addedAt` is
    /// stamped now — caller asked for it again and enough time has passed that
    /// transient conditions may have changed. Within cooldown, the duplicate is
    /// a no-op so a busy folder browse does not thrash known-failing items.
    public func append(_ item: ThumbnailRenderQueueItem) {
        withWriteLock {
            loadIfNeeded()
            if let idx = items.firstIndex(where: { $0.driveID == item.driveID && $0.s3Key == item.s3Key }) {
                let existing = items[idx]
                let age = Date().timeIntervalSince(existing.addedAt)
                if existing.attempts >= Self.maxAttempts, age >= Self.revivalCooldownSeconds {
                    items[idx].attempts = 0
                    items[idx].addedAt = Date()
                    persist()
                    queueLogger.info(
                        "Queue.append: revived poisoned \(item.s3Key, privacy: .public) — attempts reset"
                    )
                } else {
                    queueLogger.info("Queue.append: duplicate \(item.s3Key, privacy: .public) — skip")
                }
                return
            }
            items.append(item)
            persist()
            queueLogger.info(
                "Queue.append: \(item.s3Key, privacy: .public) → total=\(self.items.count, privacy: .public) file=\(self.fileURL?.path ?? "nil", privacy: .public)"
            )
        }
    }

    /// Returns up to `maxItems` pending items (attempts < maxAttempts).
    /// Does NOT remove them — call `complete` or `fail` after processing.
    public func dequeue(maxItems: Int) -> [ThumbnailRenderQueueItem] {
        withReadLock {
            loadIfNeeded()
            return Array(items.filter { $0.attempts < Self.maxAttempts }.prefix(maxItems))
        }
    }

    /// Removes a successfully processed item from the queue.
    public func complete(_ item: ThumbnailRenderQueueItem) {
        withWriteLock {
            loadIfNeeded()
            items.removeAll { $0.driveID == item.driveID && $0.s3Key == item.s3Key }
            persist()
        }
    }

    /// Bumps attempts. Items reaching `maxAttempts` are poisoned (excluded from future dequeues).
    public func fail(_ item: ThumbnailRenderQueueItem) {
        withWriteLock {
            loadIfNeeded()
            if let idx = items.firstIndex(where: { $0.driveID == item.driveID && $0.s3Key == item.s3Key }) {
                items[idx].attempts += 1
            }
            persist()
        }
    }

    /// Returns (pending, poison) counts for a specific drive.
    public func count(driveID: UUID) -> (pending: Int, poison: Int) {
        withReadLock {
            loadIfNeeded()
            let driveItems = items.filter { $0.driveID == driveID }
            let pending = driveItems.count(where: { $0.attempts < Self.maxAttempts })
            let poison = driveItems.count(where: { $0.attempts >= Self.maxAttempts })
            return (pending, poison)
        }
    }

    /// Removes all items for a drive (Settings "Reset" and drive deletion).
    public func clearAll(driveID: UUID) {
        withWriteLock {
            loadIfNeeded()
            items.removeAll { $0.driveID == driveID }
            persist()
        }
    }

    /// Total pending items across all drives.
    public var pendingCount: Int {
        withReadLock {
            loadIfNeeded()
            return items.count(where: { $0.attempts < Self.maxAttempts })
        }
    }

    // MARK: - Private

    /// Always reads the latest state from disk before each operation.
    /// Cross-process consistency: extension appends and main app drains touch
    /// the same App Group file. A one-shot load flag would let one process
    /// silently overwrite the other's writes.
    private func loadIfNeeded() {
        guard let url = fileURL else {
            queueLogger.error("Queue.load: no fileURL (no App Group container?)")
            items = []
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            items = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([ThumbnailRenderQueueItem].self, from: data)
        } catch {
            queueLogger.error(
                "Queue.load failed (\(error.localizedDescription, privacy: .public)) — file=\(url.path, privacy: .public)"
            )
            items = []
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch {
            queueLogger.error(
                "ThumbnailRenderQueue: persist failed (\(error.localizedDescription, privacy: .public))"
            )
        }
    }

    /// Cross-process exclusion for mutating ops. The lockfile is created lazily
    /// next to the queue JSON. Without the lock, the extension's append could
    /// load `[A,B]`, the main app could load+complete A and write `[B]`, then
    /// the extension persists its stale `[A,B,C]` — silently reviving the
    /// completed item.
    ///
    /// Fail-closed: if the lockfile cannot be opened or `flock` fails, the body
    /// is **not** executed. Dropping a write is preferable to corrupting the
    /// on-disk state by running unlocked.
    private func withWriteLock(_ body: () -> Void) {
        guard let lockFD = acquireExclusiveLock() else { return }
        defer { releaseLock(lockFD) }
        body()
    }

    /// Read variant. On lock failure the body still runs unlocked — readers can
    /// tolerate a slightly stale snapshot, and `.atomic` writes guarantee they
    /// never see a half-written file. The lock just keeps readers from observing
    /// state that a concurrent writer is about to overwrite anyway.
    private func withReadLock<T>(_ body: () -> T) -> T {
        guard let lockFD = acquireExclusiveLock() else { return body() }
        defer { releaseLock(lockFD) }
        return body()
    }

    /// Opens the sidecar lockfile with `O_CLOEXEC` (so the fd does not leak into
    /// any child process across `exec`) and calls `flock(LOCK_EX)`. Returns the
    /// fd on success, or `nil` on any failure (caller decides whether that means
    /// skip-the-write or run-unlocked).
    private func acquireExclusiveLock() -> Int32? {
        guard let lockURL else { return nil }
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else {
            queueLogger.error(
                "Queue.lock: open failed errno=\(errno, privacy: .public) path=\(lockURL.path, privacy: .public)"
            )
            return nil
        }
        if flock(lockFD, LOCK_EX) != 0 {
            queueLogger.error("Queue.lock: flock(LOCK_EX) failed errno=\(errno, privacy: .public)")
            close(lockFD)
            return nil
        }
        return lockFD
    }

    private func releaseLock(_ lockFD: Int32) {
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
    }
}
