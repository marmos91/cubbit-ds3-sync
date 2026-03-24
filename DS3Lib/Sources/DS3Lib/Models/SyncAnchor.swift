import Foundation

/// A SyncAnchor is a struct that represents a synchronization anchor. It is used to keep track of the synchronization
/// state of a drive.
/// When you create a `DS3Drive` with a given sync anchor, the drive will synchronize the files in the drive with the
/// files in the bucket starting from the sync anchor.
public struct SyncAnchor: Codable, Sendable {
    /// The project of the sync anchor
    public var project: Project

    /// The IAM user that owns the sync anchor
    public var IAMUser: IAMUser

    /// The bucket of the sync anchor
    public var bucket: Bucket

    /// An optional prefix to filter the files in the bucket
    public var prefix: String?

    public init(project: Project, IAMUser: IAMUser, bucket: Bucket, prefix: String? = nil) {
        self.project = project
        self.IAMUser = IAMUser
        self.bucket = bucket
        self.prefix = prefix
    }
}
