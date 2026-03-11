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
}

/// The drive status change
public struct DS3DriveStatusChange: Codable, Sendable {
    /// The drive ID that is changing status
    public let driveId: UUID

    /// The new drive status
    public let status: DS3DriveStatus
}

public extension Notification.Name{
    /// Notifications sent from the extension to the app when a drive status changes
    static let driveStatusChanged  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveStatusChanged)
    
    /// Notification setn from the extension to the app while performing transfers
    static let driveTransferStats  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveTransferStats)
}
