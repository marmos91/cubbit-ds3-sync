import Foundation
import os.log

private let queueLogger = Logger(
    subsystem: LogSubsystem.app,
    category: LogCategory.thumbnail.rawValue
)

/// Represents one item in the iOS thumbnail render backlog.
/// The extension appends when it gets a cache miss (or after a new raster upload).
/// The main app drains by downloading the original, rendering a JPEG, and PUTting to S3.
public struct ThumbnailRenderQueueItem: Codable, Sendable, Equatable {
    public let driveID: UUID
    public let s3Key: String
    public let addedAt: Date
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
/// Actor serializes within-process; `.atomic` write makes cross-process writes safe
/// (extension appends while main app is in background; drain only runs in foreground
/// so the two processes don't write simultaneously).
///
/// Deduplication: `append` is a no-op if (driveID, s3Key) already exists.
/// Poison: items with `attempts >= maxAttempts` are excluded from `dequeue` results
/// but remain in the JSON file for inspection.
public actor ThumbnailRenderQueue {
    /// Maximum render attempts before an item is considered poison.
    public static let maxAttempts = 3

    /// Shared singleton backed by the App Group container.
    public static let shared = ThumbnailRenderQueue()

    private var items: [ThumbnailRenderQueueItem] = []
    private let fileURL: URL?
    private var loaded = false

    private init() {
        fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)?
            .appendingPathComponent(DefaultSettings.FileNames.thumbnailRenderQueueFileName)
    }

    /// For testing only: backed by the given URL instead of the App Group container.
    public init(testFileURL: URL) {
        fileURL = testFileURL
    }

    // MARK: - Queue Operations

    /// Appends an item if (driveID, s3Key) is not already present. No-op if duplicate.
    public func append(_ item: ThumbnailRenderQueueItem) {
        loadIfNeeded()
        guard !items.contains(where: { $0.driveID == item.driveID && $0.s3Key == item.s3Key }) else {
            return
        }
        items.append(item)
        persist()
    }

    /// Returns up to `maxItems` pending items (attempts < maxAttempts).
    /// Does NOT remove them — call `complete` or `fail` after processing.
    public func dequeue(maxItems: Int) -> [ThumbnailRenderQueueItem] {
        loadIfNeeded()
        return Array(items.filter { $0.attempts < Self.maxAttempts }.prefix(maxItems))
    }

    /// Removes a successfully processed item from the queue.
    public func complete(_ item: ThumbnailRenderQueueItem) {
        loadIfNeeded()
        items.removeAll { $0.driveID == item.driveID && $0.s3Key == item.s3Key }
        persist()
    }

    /// Bumps attempts. Items reaching `maxAttempts` are poisoned (excluded from future dequeues).
    public func fail(_ item: ThumbnailRenderQueueItem) {
        loadIfNeeded()
        if let idx = items.firstIndex(where: { $0.driveID == item.driveID && $0.s3Key == item.s3Key }) {
            items[idx].attempts += 1
        }
        persist()
    }

    /// Returns (pending, poison) counts for a specific drive.
    public func count(driveID: UUID) -> (pending: Int, poison: Int) {
        loadIfNeeded()
        let driveItems = items.filter { $0.driveID == driveID }
        let pending = driveItems.count(where: { $0.attempts < Self.maxAttempts })
        let poison = driveItems.count(where: { $0.attempts >= Self.maxAttempts })
        return (pending, poison)
    }

    /// Removes all items for a drive (Settings "Reset" and drive deletion).
    public func clearAll(driveID: UUID) {
        loadIfNeeded()
        items.removeAll { $0.driveID == driveID }
        persist()
    }

    /// Total pending items across all drives.
    public var pendingCount: Int {
        loadIfNeeded()
        return items.count(where: { $0.attempts < Self.maxAttempts })
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([ThumbnailRenderQueueItem].self, from: data)
        } catch {
            queueLogger.error(
                "ThumbnailRenderQueue: load failed (\(error.localizedDescription, privacy: .public)) — starting empty"
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
}
