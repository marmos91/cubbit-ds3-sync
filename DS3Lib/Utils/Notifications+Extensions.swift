import Foundation

/// The transfer direction
enum TransferDirection: Codable {
    case upload
    case download
}

/// Information about a current transfer
struct DriveTransferStats: Codable {
    /// The drive ID that is performing the transfer
    let driveId: UUID
    
    /// The size of the file being transferred
    let size: Int64
    
    /// The duration of the transfer so far
    let duration: TimeInterval
    
    /// The transfer direction
    let direction: TransferDirection
}

/// The drive status change
struct DS3DriveStatusChange: Codable {
    /// The drive ID that is changing status
    let driveId: UUID
    
    /// The new drive status
    let status: DS3DriveStatus
}

public extension Notification.Name{
    /// Notifications sent from the extension to the app when a drive status changes
    static let driveStatusChanged  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveStatusChanged)
    
    /// Notification setn from the extension to the app while performing transfers
    static let driveTransferStats  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveTransferStats)
}
