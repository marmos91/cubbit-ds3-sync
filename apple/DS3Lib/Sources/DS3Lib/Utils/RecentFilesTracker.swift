import Foundation

/// Tracks recently transferred files using a dictionary keyed by a stable
/// identifier (typically `driveId/filename` or the full S3 key when known).
///
/// Thread-safe via `NSLock` for cross-thread access. Replaces the previous
/// array-backed ring buffer that allowed duplicate entries when the same file
/// went through multiple lifecycle events.
public final class RecentFilesTracker: @unchecked Sendable {
    /// Maximum number of entries stored per drive.
    public static let maxEntriesPerDrive = 10

    /// Default stuck-transfer threshold (5 minutes). Entries that have stayed
    /// in `.syncing` for longer than this without an update are auto-failed.
    public static let stuckTransferThresholdSeconds: TimeInterval = 300

    private var entriesByKey: [String: RecentFileEntry] = [:]
    private let lock = NSLock()

    public init() {
        // Default initializer
    }

    // MARK: - Upsert

    /// Upserts an entry by its stable `identifier`. If an entry with the same
    /// identifier already exists, it is merged in place via
    /// `RecentFileEntry.merging(with:)`.
    public func upsert(_ entry: RecentFileEntry) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = entriesByKey[entry.identifier] {
            entriesByKey[entry.identifier] = existing.merging(with: entry)
        } else {
            entriesByKey[entry.identifier] = entry
        }

        enforceLimitLocked(forDrive: entry.driveId)
    }

    /// Backwards-compatible API used by `DS3DriveViewModel`. Routes to
    /// `upsert(_:)` so dedupe-by-identifier semantics apply.
    public func add(_ entry: RecentFileEntry) {
        upsert(entry)
    }

    // MARK: - Mutators

    /// Updates the status of an existing entry by filename + drive ID.
    /// Kept for backwards compatibility — new code should prefer `upsert(_:)`.
    public func update(filename: String, driveId: UUID, status: TransferStatus) {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(driveId.uuidString)/\(filename)"
        guard var existing = entriesByKey[key] else { return }
        existing.status = status
        existing.updatedAt = Date()
        entriesByKey[key] = existing
    }

    /// Removes an entry by its UUID.
    public func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if let key = entriesByKey.first(where: { $0.value.id == id })?.key {
            entriesByKey.removeValue(forKey: key)
        }
    }

    /// Clears all entries across all drives.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        entriesByKey.removeAll()
    }

    /// Removes all entries belonging to a specific drive.
    public func clearAll(forDrive driveId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        entriesByKey = entriesByKey.filter { $0.value.driveId != driveId }
    }

    // MARK: - Watchdog

    /// Transitions any `.syncing` entry whose `updatedAt` is older than
    /// `seconds` to `.error` with a `"timeout"` message. Should be called
    /// periodically (e.g., every 60s) by the consumer.
    public func sweepStuckTransfers(olderThan seconds: TimeInterval = stuckTransferThresholdSeconds) {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-seconds)
        for (key, entry) in entriesByKey where entry.status == .syncing && entry.updatedAt < cutoff {
            var updated = entry
            updated.status = .error
            updated.errorMessage = "timeout"
            updated.updatedAt = Date()
            entriesByKey[key] = updated
        }
    }

    /// Called once at extension/app startup to mark any `.syncing` entries
    /// from a previous session as failed (`"interrupted"`). Without this,
    /// stuck rows would persist across restarts.
    public func purgeOnStartup() {
        lock.lock()
        defer { lock.unlock() }

        for (key, entry) in entriesByKey where entry.status == .syncing {
            var updated = entry
            updated.status = .error
            updated.errorMessage = "interrupted"
            updated.updatedAt = Date()
            entriesByKey[key] = updated
        }
    }

    // MARK: - Read

    /// All entries sorted newest-first by `updatedAt`.
    public var recentEntries: [RecentFileEntry] {
        lock.lock()
        defer { lock.unlock() }

        return entriesByKey.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Returns entries for a specific drive, sorted by status priority
    /// (syncing < error < completed) then by `updatedAt` descending.
    public func entries(forDrive driveId: UUID) -> [RecentFileEntry] {
        lock.lock()
        defer { lock.unlock() }

        return entriesByKey.values
            .filter { $0.driveId == driveId }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status < rhs.status
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// Returns all entries sorted by status priority then `updatedAt` descending.
    public func allEntries() -> [RecentFileEntry] {
        lock.lock()
        defer { lock.unlock() }

        return entriesByKey.values.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    // MARK: - Internal

    /// Enforces the per-drive entry cap. Caller must hold `lock`.
    private func enforceLimitLocked(forDrive driveId: UUID) {
        let driveEntries = entriesByKey.values.filter { $0.driveId == driveId }
        guard driveEntries.count > Self.maxEntriesPerDrive else { return }

        // Prefer evicting the oldest .completed entry first; fall back to the
        // oldest entry of any status if no completed entries exist.
        if let oldestCompleted = driveEntries
            .filter({ $0.status == .completed })
            .min(by: { $0.updatedAt < $1.updatedAt }) {
            entriesByKey.removeValue(forKey: oldestCompleted.identifier)
            return
        }

        if let oldest = driveEntries.min(by: { $0.updatedAt < $1.updatedAt }) {
            entriesByKey.removeValue(forKey: oldest.identifier)
        }
    }
}
