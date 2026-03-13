import Foundation

/// Information about a detected conflict, sent via IPC from extension to main app
public struct ConflictInfo: Codable, Sendable {
    /// The drive where the conflict occurred
    public let driveId: UUID
    /// The original filename (user-facing, without S3 path prefix)
    public let originalFilename: String
    /// The full S3 key of the conflict copy
    public let conflictKey: String

    public init(driveId: UUID, originalFilename: String, conflictKey: String) {
        self.driveId = driveId
        self.originalFilename = originalFilename
        self.conflictKey = conflictKey
    }
}
