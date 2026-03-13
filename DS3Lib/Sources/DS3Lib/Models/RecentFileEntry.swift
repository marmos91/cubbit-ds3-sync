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
        case .syncing: return 0
        case .error: return 1
        case .completed: return 2
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

    /// The drive this file belongs to.
    public let driveId: UUID

    /// The filename (last path component) of the transferred file.
    public let filename: String

    /// The file size in bytes.
    public var size: Int64

    /// The current transfer status.
    public var status: TransferStatus

    /// When this transfer was recorded.
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        driveId: UUID,
        filename: String,
        size: Int64,
        status: TransferStatus,
        timestamp: Date
    ) {
        self.id = id
        self.driveId = driveId
        self.filename = filename
        self.size = size
        self.status = status
        self.timestamp = timestamp
    }

    /// Human-readable file size (e.g., "2.0 KB", "5.0 MB").
    public var displaySize: String {
        let kilobyte: Double = 1024
        let megabyte: Double = kilobyte * kilobyte
        let doubleSize = Double(size)

        if doubleSize >= megabyte {
            return String(format: "%.1f MB", doubleSize / megabyte)
        } else {
            return String(format: "%.1f KB", doubleSize / kilobyte)
        }
    }
}
