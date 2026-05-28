import Foundation
import XCTest
@testable import DS3Lib

/// Configuration for integration tests that hit the real Cubbit DS3 API.
/// Reads credentials from environment variables. Tests are skipped when env vars are missing.
///
/// Required env vars:
///   DS3_TEST_EMAIL       — Cubbit account email
///   DS3_TEST_PASSWORD    — Cubbit account password
///   DS3_TEST_BUCKET      — S3 bucket to use for test operations
///
/// Optional env vars:
///   DS3_TEST_COORDINATOR_URL — Coordinator URL (defaults to production)
///   DS3_TEST_TENANT          — Tenant name for multi-tenant deployments
///   DS3_TEST_PREFIX          — S3 prefix to isolate test data (defaults to "ds3-drive-tests/")
enum IntegrationTestConfig {
    static var email: String? { ProcessInfo.processInfo.environment["DS3_TEST_EMAIL"] }
    static var password: String? { ProcessInfo.processInfo.environment["DS3_TEST_PASSWORD"] }
    static var bucket: String? { ProcessInfo.processInfo.environment["DS3_TEST_BUCKET"] }
    static var coordinatorURL: String {
        ProcessInfo.processInfo.environment["DS3_TEST_COORDINATOR_URL"]
            ?? CubbitAPIURLs.defaultCoordinatorURL
    }
    static var tenant: String? { ProcessInfo.processInfo.environment["DS3_TEST_TENANT"] }
    static var prefix: String {
        ProcessInfo.processInfo.environment["DS3_TEST_PREFIX"] ?? "ds3-drive-tests/"
    }

    /// Returns true if all required env vars are set.
    static var isConfigured: Bool {
        email != nil && password != nil && bucket != nil
    }

    /// Skips the current test if integration tests are not configured.
    static func skipIfNotConfigured(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(isConfigured, "Integration tests require DS3_TEST_EMAIL, DS3_TEST_PASSWORD, and DS3_TEST_BUCKET env vars")
    }

    /// Creates CubbitAPIURLs from the configured coordinator URL.
    static func makeURLs() -> CubbitAPIURLs {
        CubbitAPIURLs(coordinatorURL: coordinatorURL)
    }

    /// Returns a unique test prefix to isolate concurrent test runs.
    /// Format: "ds3-drive-tests/<UUID>/"
    static func uniqueTestPrefix() -> String {
        prefix + UUID().uuidString.prefix(8).lowercased() + "/"
    }
}

/// Base class for integration tests that need an authenticated DS3 session.
class DS3IntegrationTestCase: XCTestCase {
    var authentication: DS3Authentication!
    var urls: CubbitAPIURLs!
    var tempContainerURL: URL?

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()

        tempContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempContainerURL!, withIntermediateDirectories: true)

        urls = IntegrationTestConfig.makeURLs()
        let sharedData = SharedData(testContainerURL: tempContainerURL!)
        authentication = DS3Authentication(urls: urls, sharedData: sharedData)

        try await authentication.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )
    }

    override func tearDown() async throws {
        await authentication?.logout()
        authentication = nil
        urls = nil
        if let tempContainerURL {
            try? FileManager.default.removeItem(at: tempContainerURL)
        }
        tempContainerURL = nil
    }
}

/// Base class for integration tests that need an authenticated S3 client.
class DS3S3IntegrationTestCase: DS3IntegrationTestCase {
    var s3Client: DS3S3Client!
    var bucket: String!
    /// Unique prefix for this test run — all objects are created under this path.
    var testPrefix: String!
    /// Ephemeral key created per-run, deleted in tearDown to avoid IAM bloat.
    private var ephemeralApiKey: DS3ApiKey?
    private var ephemeralIamToken: Token?
    private var ephemeralIAMUser: IAMUser?

    override func setUp() async throws {
        try await super.setUp()

        bucket = IntegrationTestConfig.bucket!
        testPrefix = IntegrationTestConfig.uniqueTestPrefix()

        // Get API keys and create S3 client.
        // Uses the SDK API directly instead of loadOrCreateDS3APIKeys()
        // to avoid creating a runtime dependency on drive-management state in S3 tests.
        let sharedData = SharedData(testContainerURL: tempContainerURL!)
        let sdk = DS3SDK(withAuthentication: authentication, urls: urls, sharedData: sharedData)
        let projects = try await sdk.getRemoteProjects()
        guard let project = projects.first else {
            throw XCTSkip("No projects found for test account — create one in the Cubbit console first")
        }
        guard let user = project.users.first else {
            throw XCTSkip("No IAM users found in project — create one in the Cubbit console first")
        }

        // Create a fresh ephemeral API key for each test run. The deterministic
        // name from `DS3SDK.apiKeyName` collides on repeated runs because Cubbit
        // IAM returns existing keys without their secret_key (D-22), so we can't
        // reuse them. Use a per-run UUID-suffixed name instead. The created key
        // is deleted in tearDown.
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        let apiKeyName = "ds3-swift-it-\(UUID().uuidString)"
        let apiKey = try await sdk.generateDS3APIKey(
            forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName
        )
        ephemeralApiKey = apiKey
        ephemeralIamToken = iamToken
        ephemeralIAMUser = user

        guard let secretKey = apiKey.secretKey else {
            throw XCTSkip("Cubbit IAM did not return secret_key on creation")
        }

        s3Client = try DS3S3Client(
            accessKeyId: apiKey.apiKey,
            secretAccessKey: secretKey,
            endpoint: authentication.account?.endpointGateway
        )
    }

    override func tearDown() async throws {
        // Clean up: delete all objects under the test prefix
        if let s3Client, let bucket, let testPrefix {
            do {
                try await cleanupTestPrefix(client: s3Client, bucket: bucket, prefix: testPrefix)
            } catch {
                print("WARNING: Failed to clean up test prefix \(testPrefix): \(error)")
            }
            try? s3Client.shutdown()
        }

        // Delete the ephemeral API key we created in setUp.
        if let key = ephemeralApiKey, let user = ephemeralIAMUser, let tempContainerURL {
            let sdk = DS3SDK(
                withAuthentication: authentication,
                urls: urls,
                sharedData: SharedData(testContainerURL: tempContainerURL)
            )
            do {
                try await sdk.deleteApiKey(key, forIAMUser: user)
            } catch {
                print("WARNING: Failed to delete ephemeral API key \(key.name): \(error)")
            }
        }

        s3Client = nil
        bucket = nil
        testPrefix = nil
        ephemeralApiKey = nil
        ephemeralIamToken = nil
        ephemeralIAMUser = nil
        try await super.tearDown()
    }

    /// Deletes all objects under the given prefix.
    private func cleanupTestPrefix(client: DS3S3Client, bucket: String, prefix: String) async throws {
        var continuationToken: String?
        repeat {
            let result = try await client.listObjects(
                bucket: bucket,
                prefix: prefix,
                maxKeys: 1000,
                continuationToken: continuationToken
            )
            continuationToken = result.isTruncated ? result.nextContinuationToken : nil

            let keys = result.objects.map(\.key)
            if !keys.isEmpty {
                _ = try await client.deleteObjects(bucket: bucket, keys: keys)
            }
        } while continuationToken != nil
    }
}
