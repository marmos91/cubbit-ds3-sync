import Foundation

/// Struct that represents an S3 bucket
public struct Bucket: Codable, Hashable, Identifiable, Sendable {
    /// The bucket name serves as the unique identifier
    public var id: String {
        name
    }

    /// The bucket name
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
