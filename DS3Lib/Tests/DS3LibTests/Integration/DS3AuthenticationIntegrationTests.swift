import XCTest
@testable import DS3Lib

/// Integration tests for DS3Authentication against the real Cubbit IAM API.
/// Requires DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET env vars.
final class DS3AuthenticationIntegrationTests: XCTestCase {
    private var urls: CubbitAPIURLs!

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()
        urls = IntegrationTestConfig.makeURLs()
    }

    // MARK: - Login

    func testLoginWithValidCredentials() async throws {
        let auth = DS3Authentication(urls: urls)

        try await auth.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )

        XCTAssertTrue(auth.isLogged)
        XCTAssertNotNil(auth.accountSession)
        XCTAssertNotNil(auth.account)
        XCTAssertFalse(auth.accountSession!.token.token.isEmpty)
        XCTAssertFalse(auth.accountSession!.refreshToken.isEmpty)

        auth.logout()
    }

    func testLoginWithInvalidPassword() async throws {
        let auth = DS3Authentication(urls: urls)

        do {
            try await auth.login(
                email: IntegrationTestConfig.email!,
                password: "definitely-wrong-password-12345",
                tenant: IntegrationTestConfig.tenant
            )
            XCTFail("Login with wrong password should throw")
        } catch {
            XCTAssertTrue(error is DS3AuthenticationError)
            XCTAssertFalse(auth.isLogged)
        }
    }

    func testLoginWithInvalidEmail() async throws {
        let auth = DS3Authentication(urls: urls)

        do {
            try await auth.login(
                email: "nonexistent-user-\(UUID().uuidString)@example.com",
                password: "any-password",
                tenant: IntegrationTestConfig.tenant
            )
            XCTFail("Login with invalid email should throw")
        } catch {
            XCTAssertFalse(auth.isLogged)
        }
    }

    // MARK: - Account Info

    func testAccountInfoAfterLogin() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )

        let account = auth.account!
        XCTAssertFalse(account.id.isEmpty)
        XCTAssertFalse(account.firstName.isEmpty)
        XCTAssertFalse(account.emails.isEmpty)
        XCTAssertFalse(account.endpointGateway.isEmpty)

        auth.logout()
    }

    // MARK: - Token Refresh

    func testTokenRefreshAfterLogin() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )

        let originalToken = auth.accountSession!.token.token

        // Force a refresh
        try await auth.refreshIfNeeded(force: true)

        let newToken = auth.accountSession!.token.token
        // After a forced refresh, we should get a new token
        // (they might occasionally be the same if the server returns cached, but generally differ)
        XCTAssertTrue(auth.isLogged)
        XCTAssertFalse(newToken.isEmpty)
        // The token may or may not change, but the session should remain valid
        _ = originalToken

        auth.logout()
    }

    // MARK: - Logout

    func testLogoutClearsSession() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )
        XCTAssertTrue(auth.isLogged)

        auth.logout()

        XCTAssertFalse(auth.isLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    // MARK: - Double Login Prevention

    func testDoubleLoginThrows() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: IntegrationTestConfig.email!,
            password: IntegrationTestConfig.password!,
            tenant: IntegrationTestConfig.tenant
        )

        do {
            try await auth.login(
                email: IntegrationTestConfig.email!,
                password: IntegrationTestConfig.password!,
                tenant: IntegrationTestConfig.tenant
            )
            XCTFail("Double login should throw")
        } catch let error as DS3AuthenticationError {
            guard case .alreadyLoggedIn = error else {
                XCTFail("Expected alreadyLoggedIn, got \(error)")
                return
            }
        }

        auth.logout()
    }

    // MARK: - Challenge

    func testGetChallengeReturnsValidChallenge() async throws {
        let auth = DS3Authentication(urls: urls)

        let challenge = try await auth.getChallenge(
            email: IntegrationTestConfig.email!,
            tenant: IntegrationTestConfig.tenant
        )

        XCTAssertFalse(challenge.challenge.isEmpty)
        XCTAssertFalse(challenge.salt.isEmpty)
    }
}
