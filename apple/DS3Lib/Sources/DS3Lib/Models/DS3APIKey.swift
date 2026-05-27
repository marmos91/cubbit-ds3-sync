import Foundation

/// A struct used to represent an API key in the CubbitDS3 ecosystem
public struct DS3ApiKey: Codable, Equatable, Sendable {
    /// The name of the API key
    public var name: String

    /// The S3 api key (this is the public key)
    public var apiKey: String

    /// The S3 secret key (this is the private key)
    public var secretKey: String?

    /// When the API key was created
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case name
        case apiKey = "api_key"
        case secretKey = "secret_key"
        case createdAt = "created_at"
    }

    public static func == (lhs: DS3ApiKey, rhs: DS3ApiKey) -> Bool {
        lhs.name == rhs.name &&
            lhs.apiKey == rhs.apiKey
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        secretKey = try? container.decode(String.self, forKey: .secretKey)

        let createdAtDateString = try container.decode(String.self, forKey: .createdAt)

        if let createdAtDate = DateFormatter.iso8601.date(from: createdAtDateString) {
            self.createdAt = createdAtDate
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "Invalid date format"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(apiKey, forKey: .apiKey)

        if let secretKey {
            try container.encode(secretKey, forKey: .secretKey)
        }

        let createdAtDateString = DateFormatter.iso8601.string(from: createdAt)
        try container.encode(createdAtDateString, forKey: .createdAt)
    }
}
