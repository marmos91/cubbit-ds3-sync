import Foundation

/// An IAM User in the Cubbit DS3 ecosystem
@Observable
public final class IAMUser: Codable, Identifiable, Hashable, Equatable, @unchecked Sendable {
    /// The IAM user ID
    public var id: String

    /// The IAM username
    public var username: String

    /// Whether the user is a root user
    public var isRoot: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case username = "user_name"
        case isRoot = "is_root"
    }

    public init(id: String, username: String, isRoot: Bool) {
        self.id = id
        self.username = username
        self.isRoot = isRoot
    }

    // MARK: - Equatable

    public static func == (lhs: IAMUser, rhs: IAMUser) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Codable

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.username = try container.decode(String.self, forKey: .username)
        self.isRoot = try container.decode(Bool.self, forKey: .isRoot)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(isRoot, forKey: .isRoot)
    }
}
