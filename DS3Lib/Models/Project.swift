import Foundation

/// A project in the Cubbit's DS3 ecosystem
@Observable class Project: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var description: String
    var email: String
    var createdAt: String
    var bannedAt: String?
    var imageUrl: String?
    var tenantId: String
    var rootAccountEmail: String?
    var users: [IAMUser]
    
    init(
        id: String,
        name: String,
        description: String,
        email: String,
        createdAt: String,
        bannedAt: String? = nil,
        imageUrl: String? = nil,
        tenantId: String,
        rootAccountEmail: String? = nil,
        users: [IAMUser]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.email = email
        self.createdAt = createdAt
        self.bannedAt = bannedAt
        self.imageUrl = imageUrl
        self.tenantId = tenantId
        self.rootAccountEmail = rootAccountEmail
        self.users = users
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "project_id"
        case name = "project_name"
        case description = "project_description"
        case email = "project_email"
        case createdAt = "project_created_at"
        case bannedAt = "project_banned_at"
        case imageUrl = "project_image_url"
        case tenantId = "project_tenant_id"
        case rootAccountEmail = "root_account_email"
        case users
    }
    
    func short() -> String {
        return String(self.name.prefix(2))
    }
    
    // MARK: - Equatable
    static func == (lhs: Project, rhs: Project) -> Bool {
        return lhs.id == rhs.id
    }
    
    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Codable
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        email = try container.decode(String.self, forKey: .email)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        bannedAt = try container.decodeIfPresent(String.self, forKey: .bannedAt)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        tenantId = try container.decode(String.self, forKey: .tenantId)
        rootAccountEmail = try container.decodeIfPresent(String.self, forKey: .rootAccountEmail)
        users = try container.decode([IAMUser].self, forKey: .users)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(email, forKey: .email)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(bannedAt, forKey: .bannedAt)
        try container.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try container.encode(tenantId, forKey: .tenantId)
        try container.encodeIfPresent(rootAccountEmail, forKey: .rootAccountEmail)
        try container.encode(users, forKey: .users)
    }
}
