import Foundation

/// Commands the main app sends to the File Provider extension via IPC.
public enum IPCCommand: Codable, Sendable, Equatable {
    /// Request the extension to re-enumerate a specific drive.
    /// - Parameters:
    ///   - driveId: The drive whose enumeration should be refreshed.
    ///   - parentKey: Optional S3 key of the folder to signal (e.g. "Photos/"). When provided,
    ///     the extension signals only that folder's container so Files.app refreshes immediately.
    ///     `nil` triggers a full-drive enumeration (legacy behaviour, default).
    case refreshEnumeration(driveId: UUID, parentKey: String? = nil)

    /// Empty the trash for a specific drive
    case emptyTrash(driveId: UUID)
}
