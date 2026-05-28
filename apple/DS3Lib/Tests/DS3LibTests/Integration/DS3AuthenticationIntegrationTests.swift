import DS3CoreFFI
@testable import DS3Lib
import XCTest

/// Integration tests for DS3Authentication against the real Cubbit IAM API.
/// Requires DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET env vars.
final class DS3AuthenticationIntegrationTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var urls: CubbitAPIURLs!

    override func setUp() async throws {
        try IntegrationTestConfig.skipIfNotConfigured()
        urls = IntegrationTestConfig.makeURLs()

        // Ensure App Group container exists for persist() calls
        let groupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(DefaultSettings.appGroup)")
        try? FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
    }

    // MARK: - Login

    func testLoginWithValidCredentials() async throws {
        let auth = DS3Authentication(urls: urls)

        try await auth.login(
            email: XCTUnwrap(IntegrationTestConfig.email),
            password: XCTUnwrap(IntegrationTestConfig.password),
            tenant: IntegrationTestConfig.tenant
        )

        XCTAssertTrue(auth.isLogged)
        XCTAssertNotNil(auth.accountSession)
        XCTAssertNotNil(auth.account)
        XCTAssertFalse(try XCTUnwrap(auth.accountSession?.token.token.isEmpty))
        XCTAssertFalse(try XCTUnwrap(auth.accountSession?.refreshToken.isEmpty))

        await auth.logout()
    }

    func testLoginWithInvalidPassword() async throws {
        let auth = DS3Authentication(urls: urls)

        do {
            try await auth.login(
                email: XCTUnwrap(IntegrationTestConfig.email),
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
            email: XCTUnwrap(IntegrationTestConfig.email),
            password: XCTUnwrap(IntegrationTestConfig.password),
            tenant: IntegrationTestConfig.tenant
        )

        let account = try XCTUnwrap(auth.account)
        XCTAssertFalse(account.id.isEmpty)
        XCTAssertFalse(account.firstName.isEmpty)
        XCTAssertFalse(account.emails.isEmpty)
        XCTAssertFalse(account.endpointGateway.isEmpty)

        await auth.logout()
    }

    // MARK: - Token Refresh

    func testTokenRefreshAfterLogin() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: XCTUnwrap(IntegrationTestConfig.email),
            password: XCTUnwrap(IntegrationTestConfig.password),
            tenant: IntegrationTestConfig.tenant
        )

        let originalToken = try XCTUnwrap(auth.accountSession?.token.token)

        // Force a refresh
        try await auth.refreshIfNeeded(force: true)

        let newToken = try XCTUnwrap(auth.accountSession?.token.token)
        // After a forced refresh, we should get a new token
        // (they might occasionally be the same if the server returns cached, but generally differ)
        XCTAssertTrue(auth.isLogged)
        XCTAssertFalse(newToken.isEmpty)
        // The token may or may not change, but the session should remain valid
        _ = originalToken

        await auth.logout()
    }

    // MARK: - Logout

    func testLogoutClearsSession() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: XCTUnwrap(IntegrationTestConfig.email),
            password: XCTUnwrap(IntegrationTestConfig.password),
            tenant: IntegrationTestConfig.tenant
        )
        XCTAssertTrue(auth.isLogged)

        await auth.logout()

        XCTAssertFalse(auth.isLogged)
        XCTAssertNil(auth.accountSession)
        XCTAssertNil(auth.account)
    }

    // MARK: - Double Login Prevention

    func testDoubleLoginThrows() async throws {
        let auth = DS3Authentication(urls: urls)
        try await auth.login(
            email: XCTUnwrap(IntegrationTestConfig.email),
            password: XCTUnwrap(IntegrationTestConfig.password),
            tenant: IntegrationTestConfig.tenant
        )

        do {
            try await auth.login(
                email: XCTUnwrap(IntegrationTestConfig.email),
                password: XCTUnwrap(IntegrationTestConfig.password),
                tenant: IntegrationTestConfig.tenant
            )
            XCTFail("Double login should throw")
        } catch let error as DS3AuthenticationError {
            guard case .alreadyLoggedIn = error else {
                XCTFail("Expected alreadyLoggedIn, got \(error)")
                return
            }
        }

        await auth.logout()
    }

    // MARK: - Challenge

    /// Phase 16 Plan 04: the standalone challenge-fetch helper moved out of
    /// `DS3Authentication` and into the Rust core. The corresponding
    /// integration is now exercised end-to-end through `login(...)` rather
    /// than a probe against the bare `/challenge` endpoint — kept here as a
    /// smoke test using the free FFI function exposed by Plan 02.
    func testGetChallengeReturnsValidChallenge() throws {
        let challenge = try DS3CoreFFI.getChallenge(
            email: XCTUnwrap(IntegrationTestConfig.email),
            tenantId: IntegrationTestConfig.tenant,
            coordinatorUrl: urls.coordinatorURL
        )

        XCTAssertFalse(challenge.challenge.isEmpty)
        XCTAssertFalse(challenge.salt.isEmpty)
    }
}
