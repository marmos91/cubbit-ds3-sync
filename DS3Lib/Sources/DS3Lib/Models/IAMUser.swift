import Foundation

/// A IAM User in the Cubbit DS3 ecosystem
@Observable class IAMUser: Codable, Identifiable, Hashable, Equatable {
    /// The IAM user ID
    var id: String
    
    /// The IAM username
    var username: String
    
    /// Whether the user is a root user
    var isRoot: Bool
    
    private enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case username = "user_name"
        case isRoot = "is_root"
    }
    
    init(id: String, username: String, isRoot: Bool) {
        self.id = id
        self.username = username
        self.isRoot = isRoot
    }
    
    // MARK: - Equatable
    static func == (lhs: IAMUser, rhs: IAMUser) -> Bool {
        return lhs.id == rhs.id
    }
    
    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Codable
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.username = try container.decode(String.self, forKey: .username)
        self.isRoot = try container.decode(Bool.self, forKey: .isRoot)
    }
    
    func encode(to encoder: Encoder) throws {
         var container = encoder.container(keyedBy: CodingKeys.self)
         try container.encode(id, forKey: .id)
         try container.encode(username, forKey: .username)
         try container.encode(isRoot, forKey: .isRoot)
     }
}
