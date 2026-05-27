import XCTest
@testable import DS3Lib

/// Integration tests for DS3SDK against the real Cubbit API.
/// Tests project listing, IAM token forging, and API key management.
final class DS3SDKIntegrationTests: DS3IntegrationTestCase {
    private var sdk: DS3SDK!

    override func setUp() async throws {
        try await super.setUp()
        sdk = DS3SDK(withAuthentication: authentication, urls: urls)
    }

    override func tearDown() async throws {
        sdk = nil
        try await super.tearDown()
    }

    // MARK: - Projects

    func testGetRemoteProjects() async throws {
        let projects = try await sdk.getRemoteProjects()
        try XCTSkipIf(projects.isEmpty, "Test account has no projects — create one in the Cubbit console first")

        let project = projects.first!
        XCTAssertFalse(project.id.isEmpty)
        XCTAssertFalse(project.name.isEmpty)
        XCTAssertFalse(project.users.isEmpty, "Project should have at least one IAM user")
    }

    // MARK: - IAM Token

    func testForgeIAMToken() async throws {
        let projects = try await sdk.getRemoteProjects()
        guard let user = projects.first?.users.first else {
            throw XCTSkip("No IAM user found in test account")
        }

        let token = try await authentication.forgeIAMToken(forIAMUser: user)
        XCTAssertFalse(token.token.isEmpty)
        XCTAssertTrue(token.expDate > Date(), "Token should not be expired")
    }

    // MARK: - API Keys

    func testGetRemoteApiKeys() async throws {
        let projects = try await sdk.getRemoteProjects()
        guard let user = projects.first?.users.first else {
            throw XCTSkip("No IAM user found in test account")
        }

        let apiKeys = try await sdk.getRemoteApiKeys(forIAMUser: user)
        // Empty array is valid — just verify it doesn't throw
        XCTAssertNotNil(apiKeys)
    }

    func testLoadOrCreateDS3APIKeys() async throws {
        let projects = try await sdk.getRemoteProjects()
        guard let project = projects.first, let user = project.users.first else {
            throw XCTSkip("No project/user found in test account")
        }

        let apiKey = try await sdk.loadOrCreateDS3APIKeys(
            forIAMUser: user,
            ds3ProjectName: project.name
        )

        XCTAssertFalse(apiKey.name.isEmpty)
        XCTAssertFalse(apiKey.apiKey.isEmpty)
    }

    // MARK: - API Key Name

    func testApiKeyNameIsDeterministic() async throws {
        let projects = try await sdk.getRemoteProjects()
        guard let project = projects.first, let user = project.users.first else {
            throw XCTSkip("No project/user found in test account")
        }

        let name1 = DS3SDK.apiKeyName(forUser: user, projectName: project.name)
        let name2 = DS3SDK.apiKeyName(forUser: user, projectName: project.name)
        XCTAssertEqual(name1, name2)
        XCTAssertTrue(name1.hasPrefix(DefaultSettings.apiKeyNamePrefix))
    }
}
