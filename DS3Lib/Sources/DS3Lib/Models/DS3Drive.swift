import Foundation
import Observation

/// The current status of a DS3 drive
public enum DS3DriveStatus: String, Codable, Hashable, Sendable {
    /// The drive is synchronizing (uploading or downloading)
    case sync

    /// The drive is indexing (scanning/listing files)
    case indexing

    /// The drive is idle. It is not performing any operation.
    case idle

    /// The drive is in an error state. The user should perform an action to fix the error.
    case error

    /// The drive is paused. No new transfers will be started.
    case paused
}

/// Statistics about a DS3 drive's transfer activity
public struct DS3DriveStats: Codable, Sendable {
    /// When the drive was last updated
    public var lastUpdate: Date

    /// Current upload speed in bytes per second (nil when no uploads active)
    public var uploadSpeedBs: Double?

    /// Current download speed in bytes per second (nil when no downloads active)
    public var downloadSpeedBs: Double?

    /// Whether any transfer is active
    public var isTransferring: Bool {
        (uploadSpeedBs ?? 0) > 0 || (downloadSpeedBs ?? 0) > 0
    }

    public init(lastUpdate: Date, uploadSpeedBs: Double? = nil, downloadSpeedBs: Double? = nil) {
        self.lastUpdate = lastUpdate
        self.uploadSpeedBs = uploadSpeedBs
        self.downloadSpeedBs = downloadSpeedBs
    }
}

/// A class representing a DS3Drive in the app. It is used to keep track of the synchronization state of a drive.
@Observable
public final class DS3Drive: Codable, Identifiable, Hashable, @unchecked Sendable {
    /// An unique identifier for the drive
    public let id: UUID

    /// The `SyncAnchor` of the drive.
    public let syncAnchor: SyncAnchor

    /// The name of the drive. This name is displayed in the finder's sidebar (**only if more than one drive is
    /// created**).
    /// Drives' names should be unique.
    public var name: String

    public init(
        id: UUID,
        name: String,
        syncAnchor: SyncAnchor
    ) {
        self.id = id
        self.name = name
        self.syncAnchor = syncAnchor
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case syncAnchor
        case status
    }

    // MARK: - Equatable

    public static func == (lhs: DS3Drive, rhs: DS3Drive) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Codable

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.syncAnchor = try container.decode(SyncAnchor.self, forKey: .syncAnchor)
        self.name = try container.decode(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.syncAnchor, forKey: .syncAnchor)
        try container.encode(self.name, forKey: .name)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
    }
}
