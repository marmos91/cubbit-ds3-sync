import Foundation

/// Commands the main app sends to the File Provider extension via IPC.
public enum IPCCommand: Codable, Sendable, Equatable {
    /// Pause syncing for a specific drive
    case pauseDrive(driveId: UUID)

    /// Resume syncing for a specific drive
    case resumeDrive(driveId: UUID)

    /// Request the extension to re-enumerate a specific drive
    case refreshEnumeration(driveId: UUID)
}
