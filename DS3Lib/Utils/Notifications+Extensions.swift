import Foundation

enum TransferDirection: Codable {
    case upload
    case download
}

struct DriveTransferStats: Codable {
    let driveId: UUID
    let size: Int64
    let duration: TimeInterval
    let direction: TransferDirection
}

struct DS3DriveStatusChange: Codable {
    let driveId: UUID
    let status: DS3DriveStatus
}

public extension Notification.Name{
    static let driveStatusChanged  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveStatusChanged)
    static let driveTransferStats  = NSNotification.Name(rawValue: DefaultSettings.Notifications.driveTransferStats)
}
