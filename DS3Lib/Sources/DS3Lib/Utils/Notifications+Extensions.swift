import Foundation

/// The transfer direction
public enum TransferDirection: Codable, Sendable {
    case upload
    case download
}

/// Information about a current transfer
public struct DriveTransferStats: Codable, Sendable {
    /// The drive ID that is performing the transfer
    public let driveId: UUID

    /// The size of the file being transferred
    public let size: Int64

    /// The duration of the transfer so far
    public let duration: TimeInterval

    /// The transfer direction
    public let direction: TransferDirection

    /// The filename being transferred (optional for backward compatibility)
    public let filename: String?

    public init(driveId: UUID, size: Int64, duration: TimeInterval, direction: TransferDirection, filename: String? = nil) {
        self.driveId = driveId
        self.size = size
        self.duration = duration
        self.direction = direction
        self.filename = filename
    }
}

/// The drive status change
public struct DS3DriveStatusChange: Codable, Sendable {
    /// The drive ID that is changing status
    public let driveId: UUID

    /// The new drive status
    public let status: DS3DriveStatus

    public init(driveId: UUID, status: DS3DriveStatus) {
        self.driveId = driveId
        self.status = status
    }
}

public extension Notification.Name {
    /// Notifications sent from the extension to the app when a drive status changes
    static let driveStatusChanged  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveStatusChanged)
    
    /// Notification sent from the extension to the app while performing transfers
    static let driveTransferStats  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveTransferStats)

    /// Notification sent from the extension to the app when a conflict is detected
    static let conflictDetected = NSNotification.Name(rawValue: DefaultSettings.Notifications.conflictDetected)
}
