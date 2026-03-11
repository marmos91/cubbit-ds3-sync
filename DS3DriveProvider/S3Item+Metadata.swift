import Foundation


extension S3Item {
    struct Metadata {
        var etag: String?
        var contentType: String?
        var lastModified: Date?
        var versionId: String?
        var size: NSNumber
        
       // TODO: More metadata?
    }
}
