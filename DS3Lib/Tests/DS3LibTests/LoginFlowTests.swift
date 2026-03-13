import XCTest
@testable import DS3Lib

/// Tests for the login flow data: coordinator URL + tenant name round-trip through
/// file persistence and CubbitAPIURLs construction.
/// Uses a temporary directory approach since the App Group container is not available in SPM test runner.
final class LoginFlowTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Coordinator URL -> CubbitAPIURLs round-trip

    func testCoordinatorURLPersistLoadConstructsCubbitAPIURLs() throws {
        let customURL = "https://custom-coordinator.example.com"
        let urlFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)

        // Persist
        try customURL.write(to: urlFile, atomically: true, encoding: .utf8)

        // Load
        let loaded = try String(contentsOf: urlFile, encoding: .utf8)

        // Construct CubbitAPIURLs and verify derived URLs
        let urls = CubbitAPIURLs(coordinatorURL: loaded)
        XCTAssertEqual(urls.coordinatorURL, customURL)
        XCTAssertEqual(urls.signinURL, "\(customURL)/iam/v1/auth/signin")
        XCTAssertEqual(urls.challengeURL, "\(customURL)/iam/v1/auth/signin/challenge")
    }

    // MARK: - Tenant name round-trip

    func testTenantNameRoundTrip() throws {
        let tenantName = "acme-corp"
        let tenantFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)

        // Persist tenant
        try tenantName.write(to: tenantFile, atomically: true, encoding: .utf8)

        // Load tenant
        let loadedTenant = try String(contentsOf: tenantFile, encoding: .utf8)
        XCTAssertEqual(loadedTenant, tenantName)
    }

    // MARK: - Combined: persist both tenant and coordinator URL, then load and construct URLs

    func testFullLoginFlowDataRoundTrip() throws {
        let tenantName = "enterprise-tenant"
        let coordinatorURL = "https://api.enterprise.example.com"

        let tenantFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        let urlFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)

        // Persist both
        try tenantName.write(to: tenantFile, atomically: true, encoding: .utf8)
        try coordinatorURL.write(to: urlFile, atomically: true, encoding: .utf8)

        // Load both
        let loadedTenant = try String(contentsOf: tenantFile, encoding: .utf8)
        let loadedURL = try String(contentsOf: urlFile, encoding: .utf8)

        // Construct CubbitAPIURLs
        let urls = CubbitAPIURLs(coordinatorURL: loadedURL)

        XCTAssertEqual(loadedTenant, tenantName)
        XCTAssertEqual(urls.coordinatorURL, coordinatorURL)
        XCTAssertEqual(urls.accountsMeURL, "\(coordinatorURL)/iam/v1/accounts/me")
    }
}
