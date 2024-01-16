import Foundation

struct SyncAnchor: Codable {
    var project: Project
    var IAMUser: IAMUser
    var bucket: Bucket
    var prefix: String?
}
