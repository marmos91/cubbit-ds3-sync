import Foundation
import SwiftUI

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

    /// The current speed (in bytes per seconds) of the transfers performed by the drive. This is an average speed calculated over a period of time.
    public var currentSpeedBs: Double? // Bytes per second

    public init(lastUpdate: Date, currentSpeedBs: Double? = nil) {
        self.lastUpdate = lastUpdate
        self.currentSpeedBs = currentSpeedBs
    }

    /// Converts the stats into a human readable string. If the drive is currently performing transfers, it will display the current speed. Otherwise, it will display the time since the last update.
    public func toString() -> String {
        if let currentSpeedBs = self.currentSpeedBs {
            let kilobyte = 1024.0
            let megabyte = kilobyte * kilobyte

            if currentSpeedBs >= megabyte {
                // Format speed in MB/s
                return String(format: "%.2f MB/s", currentSpeedBs / megabyte)
            } else {
                // Format speed in KB/s
                return String(format: "%.2f KB/s", currentSpeedBs / kilobyte)
            }
        } else {
            // Calculate time difference
            let timeDifference = Calendar.current.dateComponents([.minute, .hour], from: self.lastUpdate, to: Date())

            if let minutes = timeDifference.minute, minutes > 0 {
                // Display time in minutes ago
                return "Updated \(minutes) minute\(minutes == 1 ? "" : "s") ago"
            } else if let hours = timeDifference.hour, hours > 0 {
                // Display time in hours ago
                return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago"
            } else {
                // If less than a minute, consider it as "just updated"
                return "Just Updated"
            }
        }
    }
}

/// A class representing a DS3Drive in the app. It is used to keep track of the synchronization state of a drive.
@Observable public final class DS3Drive: Codable, Identifiable, Hashable, @unchecked Sendable {
    /// An unique identifier for the drive
    public let id: UUID

    /// The `SyncAnchor` of the drive.
    public let syncAnchor: SyncAnchor

    /// The name of the drive. This name is displayed in the finder's sidebar (**only if more than one drive is created**).
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
