import Foundation

/// A SyncAnchor is a struct that represents a synchronization anchor. It is used to keep track of the synchronization state of a drive.
/// When you create a `DS3Drive` with a given sync anchor, the drive will synchronize the files in the drive with the files in the bucket starting from the sync anchor.
struct SyncAnchor: Codable {
    /// The project of the sync anchor
    var project: Project
    
    /// The IAM user that owns the sync anchor
    var IAMUser: IAMUser
    
    /// The bucket of the sync anchor
    var bucket: Bucket
    
    /// An optional prefix to filter the files in the bucket
    var prefix: String?
}
