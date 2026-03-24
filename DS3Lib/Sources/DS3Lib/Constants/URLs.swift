import Foundation

/// Instance-based URL builder that derives all Cubbit API URLs from a coordinator base URL.
/// Replaces the former static enum to support custom coordinator URLs for multi-tenant deployments.
public final class CubbitAPIURLs: Sendable {
    /// The default Cubbit coordinator URL.
    public static let defaultCoordinatorURL = "https://api.eu00wi.cubbit.services"

    /// The coordinator base URL used to derive all service URLs.
    public let coordinatorURL: String

    /// Creates a new CubbitAPIURLs instance.
    /// - Parameter coordinatorURL: The coordinator base URL. Defaults to the standard Cubbit coordinator.
    public init(coordinatorURL: String = CubbitAPIURLs.defaultCoordinatorURL) {
        var url = coordinatorURL
        while url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        self.coordinatorURL = url
    }

    // MARK: - IAM URLs

    /// IAM service base URL
    public var iamBaseURL: String {
        "\(coordinatorURL)/iam/v1"
    }
    /// Auth base URL
    public var authBaseURL: String {
        "\(iamBaseURL)/auth"
    }
    /// Sign-in URL
    public var signinURL: String {
        "\(authBaseURL)/signin"
    }
    /// Challenge URL for authentication
    public var challengeURL: String {
        "\(signinURL)/challenge"
    }
    /// Token refresh URL
    public var tokenRefreshURL: String {
        "\(authBaseURL)/refresh/access"
    }
    /// Forge access JWT URL
    public var forgeAccessJWTURL: String {
        "\(authBaseURL)/forge/access"
    }
    /// Accounts "me" URL
    public var accountsMeURL: String {
        "\(iamBaseURL)/accounts/me"
    }

    // MARK: - Composer Hub URLs

    /// Composer Hub base URL
    public var composerHubBaseURL: String {
        "\(coordinatorURL)/composer-hub/v1"
    }
    /// Projects URL
    public var projectsURL: String {
        "\(composerHubBaseURL)/projects"
    }
    /// Tenants URL
    public var tenantsURL: String {
        "\(composerHubBaseURL)/tenants"
    }

    // MARK: - Keyvault URLs

    /// Keyvault base URL
    public var keyvaultBaseURL: String {
        "\(coordinatorURL)/keyvault/api/v3"
    }
    /// Keys URL (for create, get, delete operations)
    public var keysURL: String {
        "\(keyvaultBaseURL)/keys"
    }
}

/// Cubbit web console related URLs.
public enum ConsoleURLs {
    public static let baseURL = "https://console.cubbit.eu"
    public static let signupURL = "\(ConsoleURLs.baseURL)/signup"
    public static let recoveryURL = "\(ConsoleURLs.baseURL)/recovery"
    public static let workspaceURL = "\(ConsoleURLs.baseURL)/workspace"
    public static let projectsURL = "\(ConsoleURLs.workspaceURL)/projects"
    public static let profileURL = "\(ConsoleURLs.workspaceURL)/profile"
}

/// Cubbit docs related URLs.
public enum DocsURLs {
    public static let baseURL = "https://docs.cubbit.io"
}

/// Cubbit help center related URLs.
public enum HelpURLs {
    public static let baseURL = "https://help.cubbit.io"
}
