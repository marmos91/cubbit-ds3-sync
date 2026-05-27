import Foundation

/// The transfer status of a recent file entry.
public enum TransferStatus: String, Codable, Sendable, Comparable {
    /// The file is currently being transferred.
    case syncing

    /// The file transfer encountered an error.
    case error

    /// The file transfer completed successfully.
    case completed

    // MARK: - Comparable

    /// Sort order: syncing (0) < error (1) < completed (2)
    /// This ensures syncing items appear first in sorted lists.
    private var sortOrder: Int {
        switch self {
        case .syncing: 0
        case .error: 1
        case .completed: 2
        }
    }

    public static func < (lhs: TransferStatus, rhs: TransferStatus) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// A model representing a recently transferred file.
public struct RecentFileEntry: Identifiable, Sendable {
    /// Unique identifier for this entry.
    public let id: UUID

    /// Stable identifier used for dedupe — typically `driveId/filename` (or the
    /// full S3 key when known). Two entries with the same `identifier` represent
    /// the same logical transfer and must be merged in place rather than
    /// duplicated in the tracker.
    public let identifier: String

    /// The drive this file belongs to.
    public let driveId: UUID

    /// The filename (last path component) of the transferred file.
    public let filename: String

    /// The file size in bytes.
    public var size: Int64

    /// The current transfer status.
    public var status: TransferStatus

    /// When this transfer was first seen (immutable across merges).
    public var timestamp: Date

    /// Last time this entry was updated. Used by sort order and the stuck-transfer
    /// watchdog to detect entries that never reached a terminal state.
    public var updatedAt: Date

    /// Bytes transferred so far (cumulative). Used for progress percentage during syncing.
    public var transferredBytes: Int64

    /// Total file size in bytes (when known). Used for progress percentage calculation.
    public var totalBytes: Int64?

    /// Current transfer speed in bytes per second.
    public var speed: Double?

    /// Optional error message if `status == .error`.
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        identifier: String? = nil,
        driveId: UUID,
        filename: String,
        size: Int64,
        status: TransferStatus,
        timestamp: Date,
        updatedAt: Date? = nil,
        transferredBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        speed: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.identifier = identifier ?? "\(driveId.uuidString)/\(filename)"
        self.driveId = driveId
        self.filename = filename
        self.size = size
        self.status = status
        self.timestamp = timestamp
        self.updatedAt = updatedAt ?? timestamp
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.errorMessage = errorMessage
    }

    /// Returns a new entry resulting from merging `self` with `other`.
    /// Preserves the earliest `timestamp` (when the transfer started), takes the
    /// latest `status` and `updatedAt`, the maximum `transferredBytes`, and the
    /// most recent error message if any.
    public func merging(with other: RecentFileEntry) -> RecentFileEntry {
        RecentFileEntry(
            id: id,
            identifier: identifier,
            driveId: driveId,
            filename: other.filename,
            size: max(size, other.size),
            status: other.status,
            timestamp: min(timestamp, other.timestamp),
            updatedAt: max(updatedAt, other.updatedAt),
            transferredBytes: max(transferredBytes, other.transferredBytes),
            totalBytes: other.totalBytes ?? totalBytes,
            speed: other.speed ?? speed,
            errorMessage: other.errorMessage ?? errorMessage
        )
    }

    /// Human-readable file size (e.g., "2.0 KB", "5.0 MB").
    public var displaySize: String {
        Self.formatBytes(size)
    }

    /// Progress percentage (0–100) when totalBytes is known and currently syncing.
    public var progressPercent: Int? {
        guard let totalBytes, totalBytes > 0, status == .syncing else { return nil }
        return min(100, Int((Double(transferredBytes) / Double(totalBytes)) * 100))
    }

    /// Human-readable transfer speed (e.g., "1.2 MB/s").
    public var displaySpeed: String? {
        guard let speed, speed > 0, status == .syncing else { return nil }
        return "\(Self.formatBytes(Int64(speed)))/s"
    }

    /// Formats a byte count into a human-readable string.
    private static func formatBytes(_ bytes: Int64) -> String {
        let kilobyte: Double = 1024
        let megabyte: Double = kilobyte * kilobyte
        let value = Double(bytes)

        if value >= megabyte {
            return String(format: "%.1f MB", value / megabyte)
        }
        return String(format: "%.1f KB", value / kilobyte)
    }
}
