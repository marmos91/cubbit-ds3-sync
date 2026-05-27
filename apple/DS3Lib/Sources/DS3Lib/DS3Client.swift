import Foundation
import os.log

/// Errors specific to DS3Client operations.
public enum DS3ClientSetupError: Error, LocalizedError {
    case notConfigured
    case missingSecret
    case missingAccount

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            NSLocalizedString("DS3Client is not configured for this operation.", comment: "")
        case .missingSecret:
            NSLocalizedString("API key has no secret key.", comment: "")
        case .missingAccount:
            NSLocalizedString("Account not available.", comment: "")
        }
    }
}

/// Unified client that composes DS3SDK (platform API) and DS3S3Client (S3 operations)
/// behind a single entry point. Internalizes the credential flow so callers don't need
/// to manually orchestrate API key loading and S3 client construction.
///
/// Two initialization paths:
/// - `init(authentication:)` — for the main app (live tokens, lazy S3 client per project)
/// - `init(drive:)` — for extensions (loads persisted credentials, immediate S3 client)
public final class DS3Client: @unchecked Sendable {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    private let authentication: DS3Authentication?
    private let sdk: DS3SDK?
    private var s3Clients: [String: DS3S3Client] = [:]

    /// Pre-built S3 client for the drive-based init path (extensions).
    public private(set) var driveS3Client: DS3S3Client?

    /// The endpoint used by this client (for extensions that need it).
    public private(set) var endpoint: String?

    /// The API keys used by the drive-based init path.
    public private(set) var apiKeys: DS3ApiKey?

    // MARK: - Initialization

    /// Creates a DS3Client for main app callers with live authentication.
    /// S3 clients are created lazily via `s3Client(forProject:iamUser:)`.
    public init(authentication: DS3Authentication) {
        self.authentication = authentication
        self.sdk = DS3SDK(withAuthentication: authentication)
    }

    /// Creates a DS3Client for extension callers using persisted credentials.
    /// Loads account + API key from SharedData and constructs a DS3S3Client immediately.
    public init(drive: DS3Drive) throws {
        self.authentication = nil
        self.sdk = nil

        let sharedData = SharedData.default()
        let account = try sharedData.loadAccountFromPersistence()
        self.endpoint = account.endpointGateway

        let keys = try sharedData.loadDS3APIKeyFromPersistence(
            forUser: drive.syncAnchor.IAMUser,
            projectName: drive.syncAnchor.project.name
        )
        self.apiKeys = keys

        guard let secretKey = keys.secretKey else {
            throw DS3ClientSetupError.missingSecret
        }

        self.driveS3Client = DS3S3Client(
            accessKeyId: keys.apiKey,
            secretAccessKey: secretKey,
            endpoint: account.endpointGateway
        )
    }

    // MARK: - Platform Operations (DS3SDK)

    /// Retrieves all projects for the current user.
    public func getRemoteProjects() async throws -> [Project] {
        guard let sdk else { throw DS3ClientSetupError.notConfigured }
        return try await sdk.getRemoteProjects()
    }

    /// Loads or creates API keys for the given IAM user and project.
    public func loadOrCreateDS3APIKeys(
        forIAMUser user: IAMUser,
        ds3ProjectName: String
    ) async throws -> DS3ApiKey {
        guard let sdk else { throw DS3ClientSetupError.notConfigured }
        return try await sdk.loadOrCreateDS3APIKeys(
            forIAMUser: user,
            ds3ProjectName: ds3ProjectName
        )
    }

    // MARK: - S3 Client Access

    /// Returns an S3 client for the given project + IAM user combination.
    /// Lazily creates the client by loading/creating API keys and reading the account endpoint.
    /// Caches per project+user combination.
    public func s3Client(
        forProject project: Project,
        iamUser user: IAMUser
    ) async throws -> DS3S3Client {
        let cacheKey = "\(project.id)_\(user.id)"
        if let existing = s3Clients[cacheKey] { return existing }

        guard let sdk, let account = authentication?.account else {
            throw DS3ClientSetupError.notConfigured
        }

        let apiKey = try await sdk.loadOrCreateDS3APIKeys(
            forIAMUser: user,
            ds3ProjectName: project.name
        )

        guard let secretKey = apiKey.secretKey else {
            throw DS3ClientSetupError.missingSecret
        }

        let client = DS3S3Client(
            accessKeyId: apiKey.apiKey,
            secretAccessKey: secretKey,
            endpoint: account.endpointGateway
        )

        s3Clients[cacheKey] = client
        return client
    }

    // MARK: - Credential Reload (Extensions)

    /// Reloads credentials from SharedData for the drive-based init path.
    /// Returns `true` if credentials changed and the S3 client was rebuilt.
    @discardableResult
    public func reloadDriveCredentials(drive: DS3Drive) throws -> Bool {
        let sharedData = SharedData.default()
        let account = try sharedData.loadAccountFromPersistence()
        let newKeys = try sharedData.loadDS3APIKeyFromPersistence(
            forUser: drive.syncAnchor.IAMUser,
            projectName: drive.syncAnchor.project.name
        )

        let endpointChanged = account.endpointGateway != self.endpoint
        let keyChanged = newKeys.apiKey != self.apiKeys?.apiKey
            || newKeys.secretKey != self.apiKeys?.secretKey

        guard endpointChanged || keyChanged else { return false }

        guard let secretKey = newKeys.secretKey else {
            throw DS3ClientSetupError.missingSecret
        }

        logger.info("Credentials changed for drive \(drive.id), rebuilding S3 client")

        self.endpoint = account.endpointGateway
        self.apiKeys = newKeys
        self.driveS3Client = DS3S3Client(
            accessKeyId: newKeys.apiKey,
            secretAccessKey: secretKey,
            endpoint: account.endpointGateway
        )

        return true
    }

    // MARK: - Lifecycle

    /// Shuts down all cached S3 clients.
    public func shutdown() {
        for (_, client) in s3Clients {
            try? client.shutdown()
        }
        s3Clients.removeAll()

        if let driveClient = driveS3Client {
            try? driveClient.shutdown()
            driveS3Client = nil
        }
    }
}
