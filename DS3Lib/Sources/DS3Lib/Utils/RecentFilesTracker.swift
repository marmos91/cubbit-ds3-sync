import Foundation

/// Tracks recently transferred files per drive using a ring buffer.
/// Thread-safe via NSLock for cross-thread access.
public final class RecentFilesTracker: @unchecked Sendable {
    /// Maximum number of entries stored per drive.
    public static let maxEntriesPerDrive = 10

    private var entries: [RecentFileEntry] = []
    private let lock = NSLock()

    public init() {}

    /// Add a new entry to the tracker.
    /// If the per-drive limit is exceeded, the oldest completed entry for that drive is evicted.
    public func add(_ entry: RecentFileEntry) {
        lock.lock()
        defer { lock.unlock() }

        entries.append(entry)

        // Check if per-drive limit is exceeded
        let driveEntries = entries.filter { $0.driveId == entry.driveId }
        if driveEntries.count > Self.maxEntriesPerDrive {
            // Find the oldest completed entry for this drive and remove it
            if let oldestCompletedIndex = entries.firstIndex(where: {
                $0.driveId == entry.driveId && $0.status == .completed
            }) {
                entries.remove(at: oldestCompletedIndex)
            } else {
                // If no completed entries, remove the oldest entry for this drive
                if let oldestIndex = entries.firstIndex(where: { $0.driveId == entry.driveId }) {
                    entries.remove(at: oldestIndex)
                }
            }
        }
    }

    /// Update the status of an existing entry identified by filename and drive ID.
    public func update(filename: String, driveId: UUID, status: TransferStatus) {
        lock.lock()
        defer { lock.unlock() }

        if let index = entries.firstIndex(where: {
            $0.filename == filename && $0.driveId == driveId
        }) {
            entries[index].status = status
        }
    }

    /// Returns entries for a specific drive, sorted by status priority then by timestamp (newest first).
    public func entries(forDrive driveId: UUID) -> [RecentFileEntry] {
        lock.lock()
        defer { lock.unlock() }

        return entries
            .filter { $0.driveId == driveId }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status < rhs.status
                }
                return lhs.timestamp > rhs.timestamp
            }
    }

    /// Returns all entries sorted by status priority then by timestamp (newest first).
    public func allEntries() -> [RecentFileEntry] {
        lock.lock()
        defer { lock.unlock() }

        return entries.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
            }
            return lhs.timestamp > rhs.timestamp
        }
    }
}
