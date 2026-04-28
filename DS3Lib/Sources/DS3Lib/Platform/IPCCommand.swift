import Foundation

/// Commands the main app sends to the File Provider extension via IPC.
public enum IPCCommand: Codable, Sendable, Equatable {
    /// Request the extension to re-enumerate a specific drive
    case refreshEnumeration(driveId: UUID)

    /// Empty the trash for a specific drive
    case emptyTrash(driveId: UUID)
}
