import Foundation


extension S3Item {
    struct Metadata {
        public struct ExtendedAttributes: Codable {
            public let values: [String: Data]

            public init(values: [String: Data]) {
                self.values = values
            }
        }
        
        var etag: String?
        var contentType: String?
        var lastModified: Date?
        var versionId: String?
        var extendedAttributes: ExtendedAttributes?
        var size: NSNumber
        
        
    }
}
