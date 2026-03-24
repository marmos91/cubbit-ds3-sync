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

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()

        urls = IntegrationTestConfig.makeURLs()
        authentication = DS3Authentication(urls: urls)

        try await authentication.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )
    }

    override func tearDown() async throws {
        authentication?.logout()
        authentication = nil
        urls = nil
    }
}

/// Base class for integration tests that need an authenticated S3 client.
class DS3S3IntegrationTestCase: DS3IntegrationTestCase {
    var s3Client: DS3S3Client!
    var bucket: String!
    /// Unique prefix for this test run — all objects are created under this path.
    var testPrefix: String!

    override func setUp() async throws {
        try await super.setUp()

        bucket = IntegrationTestConfig.bucket!
        testPrefix = IntegrationTestConfig.uniqueTestPrefix()

        // Get API keys and create S3 client.
        // Bypasses SharedData persistence (not available in CI's SPM test runner)
        // by using the SDK API directly instead of loadOrCreateDS3APIKeys().
        let sdk = DS3SDK(withAuthentication: authentication, urls: urls)
        let projects = try await sdk.getRemoteProjects()
        guard let project = projects.first else {
            throw XCTSkip("No projects found for test account — create one in the Cubbit console first")
        }
        guard let user = project.users.first else {
            throw XCTSkip("No IAM users found in project — create one in the Cubbit console first")
        }

        // Try to find an existing API key, or generate a new one
        let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
        let remoteKeys = try await sdk.getRemoteApiKeys(forIAMUser: user)
        let apiKeyName = DS3SDK.apiKeyName(forUser: user, projectName: project.name)

        let apiKey: DS3ApiKey
        if let existing = remoteKeys.first(where: { $0.name == apiKeyName }), existing.secretKey != nil {
            apiKey = existing
        } else {
            // Generate a fresh key (secret is only available at creation time)
            apiKey = try await sdk.generateDS3APIKey(
                forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName
            )
        }

        guard let secretKey = apiKey.secretKey else {
            throw XCTSkip("API key has no secret key — delete '\(apiKeyName)' in the Cubbit console and re-run")
        }

        s3Client = DS3S3Client(
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

        s3Client = nil
        bucket = nil
        testPrefix = nil
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
