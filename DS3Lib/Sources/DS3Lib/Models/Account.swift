/// Account email model
public struct AccountEmail: Codable, Sendable {
    /// The email record identifier
    public var id: String

    /// The email address
    public var email: String

    /// Whether this is the default email for the account
    public var isDefault: Bool

    /// When the email was created
    public var createdAt: String

    /// Whether the email has been verified
    public var isVerified: Bool

    /// The tenant identifier
    public var tenantId: String
    
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
public struct Account: Codable, Sendable {
    /// The account unique identifier
    public var id: String

    /// The user's first name
    public var firstName: String

    /// The user's last name
    public var lastName: String

    /// Whether the account is internal
    public var isInternal: Bool

    /// Whether the account is banned
    public var isBanned: Bool

    /// When the account was created
    public var createdAt: String

    /// When the account was deleted, if applicable
    public var deletedAt: String?

    /// When the account was banned, if applicable
    public var bannedAt: String?

    /// Maximum number of projects allowed
    public var maxAllowedProjects: Int32

    /// The account's email addresses
    public var emails: [AccountEmail]

    /// Whether two-factor authentication is enabled
    public var isTwoFactorEnabled: Bool

    /// The tenant identifier
    public var tenantId: String

    /// The S3 endpoint gateway URL
    public var endpointGateway: String

    /// The authentication provider
    public var authProvider: String
    
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
