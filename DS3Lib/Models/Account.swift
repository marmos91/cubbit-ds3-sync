/// Account email model
struct AccountEmail: Codable {
    var id: String
    var email: String
    
    /// Whether this is the default email for the account
    var isDefault: Bool
    
    var createdAt: String
    var isVerified: Bool
    var tenantId: String
    
    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case isDefault = "default"
        case createdAt = "created_at"
        case isVerified = "verified"
        case tenantId = "tenant_id"
    }
}

/// An account in the Cubbit's DS3 ecosystem
struct Account: Codable {
    var id: String
    var firstName: String
    var lastName: String
    var isInternal: Bool
    var isBanned: Bool
    var createdAt: String
    var deletedAt: String?
    var bannedAt: String?
    var maxAllowedProjects: Int32
    var emails: [AccountEmail]
    var isTwoFactorEnabled: Bool
    var tenantId: String
    var endpointGateway: String
    var authProvider: String
    
    private enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case isInternal = "internal"
        case isBanned = "banned"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case bannedAt = "banned_at"
        case maxAllowedProjects = "max_allowed_projects"
        case emails
        case isTwoFactorEnabled = "two_factor_enabled"
        case tenantId = "tenant_id"
        case endpointGateway = "endpoint_gateway"
        case authProvider = "auth_provider"
    }
}
