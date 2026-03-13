import XCTest
@testable import DS3Lib

final class CubbitAPIURLsTests: XCTestCase {
    // MARK: - Default coordinator URL

    func testDefaultCoordinatorURLConstant() {
        XCTAssertEqual(CubbitAPIURLs.defaultCoordinatorURL, "https://api.eu00wi.cubbit.services")
    }

    func testDefaultIAMBaseURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.iamBaseURL, "https://api.eu00wi.cubbit.services/iam/v1")
    }

    func testDefaultAuthBaseURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.authBaseURL, "https://api.eu00wi.cubbit.services/iam/v1/auth")
    }

    func testDefaultSigninURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.signinURL, "https://api.eu00wi.cubbit.services/iam/v1/auth/signin")
    }

    func testDefaultChallengeURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.challengeURL, "https://api.eu00wi.cubbit.services/iam/v1/auth/signin/challenge")
    }

    func testDefaultTokenRefreshURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.tokenRefreshURL, "https://api.eu00wi.cubbit.services/iam/v1/auth/refresh/access")
    }

    func testDefaultForgeAccessJWTURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.forgeAccessJWTURL, "https://api.eu00wi.cubbit.services/iam/v1/auth/forge/access")
    }

    func testDefaultAccountsMeURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.accountsMeURL, "https://api.eu00wi.cubbit.services/iam/v1/accounts/me")
    }

    func testDefaultComposerHubBaseURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.composerHubBaseURL, "https://api.eu00wi.cubbit.services/composer-hub/v1")
    }

    func testDefaultProjectsURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.projectsURL, "https://api.eu00wi.cubbit.services/composer-hub/v1/projects")
    }

    func testDefaultTenantsURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.tenantsURL, "https://api.eu00wi.cubbit.services/composer-hub/v1/tenants")
    }

    func testDefaultKeyvaultBaseURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.keyvaultBaseURL, "https://api.eu00wi.cubbit.services/keyvault/api/v3")
    }

    func testDefaultKeysURL() {
        let urls = CubbitAPIURLs()
        XCTAssertEqual(urls.keysURL, "https://api.eu00wi.cubbit.services/keyvault/api/v3/keys")
    }

    // MARK: - Custom coordinator URL

    func testCustomIAMBaseURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.iamBaseURL, "https://custom.example.com/iam/v1")
    }

    func testCustomChallengeURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.challengeURL, "https://custom.example.com/iam/v1/auth/signin/challenge")
    }

    func testCustomSigninURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.signinURL, "https://custom.example.com/iam/v1/auth/signin")
    }

    func testCustomAccountsMeURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.accountsMeURL, "https://custom.example.com/iam/v1/accounts/me")
    }

    func testCustomTenantsURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.tenantsURL, "https://custom.example.com/composer-hub/v1/tenants")
    }

    func testCustomTokenRefreshURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.tokenRefreshURL, "https://custom.example.com/iam/v1/auth/refresh/access")
    }

    func testCustomForgeAccessJWTURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.forgeAccessJWTURL, "https://custom.example.com/iam/v1/auth/forge/access")
    }

    func testCustomComposerHubBaseURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.composerHubBaseURL, "https://custom.example.com/composer-hub/v1")
    }

    func testCustomProjectsURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.projectsURL, "https://custom.example.com/composer-hub/v1/projects")
    }

    func testCustomKeyvaultBaseURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.keyvaultBaseURL, "https://custom.example.com/keyvault/api/v3")
    }

    func testCustomKeysURL() {
        let urls = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(urls.keysURL, "https://custom.example.com/keyvault/api/v3/keys")
    }

    // MARK: - Trailing slash handling

    func testTrailingSlashStripped() {
        let withSlash = CubbitAPIURLs(coordinatorURL: "https://custom.example.com/")
        let withoutSlash = CubbitAPIURLs(coordinatorURL: "https://custom.example.com")
        XCTAssertEqual(withSlash.iamBaseURL, withoutSlash.iamBaseURL)
        XCTAssertEqual(withSlash.challengeURL, withoutSlash.challengeURL)
        XCTAssertEqual(withSlash.composerHubBaseURL, withoutSlash.composerHubBaseURL)
        XCTAssertEqual(withSlash.keyvaultBaseURL, withoutSlash.keyvaultBaseURL)
    }
}
