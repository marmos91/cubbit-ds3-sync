import XCTest
@testable import DS3Lib

final class CoordinatorURLIntegrationTests: XCTestCase {
    // MARK: - Default coordinator URL

    func testDefaultCoordinatorURLProducesCorrectIAMBaseURL() {
        let urls = CubbitAPIURLs()
        XCTAssertTrue(urls.iamBaseURL.hasPrefix(CubbitAPIURLs.defaultCoordinatorURL))
    }

    func testDefaultCoordinatorURLProducesCorrectKeyvaultURL() {
        let urls = CubbitAPIURLs()
        XCTAssertTrue(urls.keyvaultBaseURL.hasPrefix(CubbitAPIURLs.defaultCoordinatorURL))
    }

    func testDefaultCoordinatorURLProducesCorrectComposerHubURL() {
        let urls = CubbitAPIURLs()
        XCTAssertTrue(urls.composerHubBaseURL.hasPrefix(CubbitAPIURLs.defaultCoordinatorURL))
    }

    // MARK: - Custom coordinator URL

    func testCustomCoordinatorURLProducesCorrectIAMBaseURL() {
        let customURL = "https://api.custom-tenant.example.com"
        let urls = CubbitAPIURLs(coordinatorURL: customURL)
        XCTAssertTrue(urls.iamBaseURL.hasPrefix(customURL))
        XCTAssertEqual(urls.iamBaseURL, "\(customURL)/iam/v1")
    }

    func testCustomCoordinatorURLProducesCorrectKeyvaultURL() {
        let customURL = "https://api.custom-tenant.example.com"
        let urls = CubbitAPIURLs(coordinatorURL: customURL)
        XCTAssertTrue(urls.keyvaultBaseURL.hasPrefix(customURL))
        XCTAssertEqual(urls.keyvaultBaseURL, "\(customURL)/keyvault/api/v3")
    }

    func testCustomCoordinatorURLProducesCorrectComposerHubURL() {
        let customURL = "https://api.custom-tenant.example.com"
        let urls = CubbitAPIURLs(coordinatorURL: customURL)
        XCTAssertTrue(urls.composerHubBaseURL.hasPrefix(customURL))
        XCTAssertEqual(urls.composerHubBaseURL, "\(customURL)/composer-hub/v1")
    }

    func testCustomCoordinatorURLProducesCorrectTokenRefreshURL() {
        let customURL = "https://api.custom-tenant.example.com"
        let urls = CubbitAPIURLs(coordinatorURL: customURL)
        XCTAssertTrue(urls.tokenRefreshURL.hasPrefix(customURL))
    }
}
