import Foundation

/// Struct that represents an S3 bucket
public struct Bucket: Codable, Equatable, Sendable {
    /// The bucket name
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
