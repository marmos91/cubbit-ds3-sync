import XCTest
@testable import DS3Lib

/// Tests for tenant name and coordinator URL persistence.
/// Since SharedData uses the App Group container which is not available in SPM test runner,
/// these tests validate the encode/decode logic using a temporary directory.
final class SharedDataTenantTests: XCTestCase {
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

    // MARK: - Tenant name persistence

    func testPersistAndLoadTenantName() throws {
        let tenantFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        let tenantName = "neonswarm"

        try tenantName.write(to: tenantFile, atomically: true, encoding: .utf8)

        let loaded = try String(contentsOf: tenantFile, encoding: .utf8)
        XCTAssertEqual(loaded, tenantName)
    }

    func testPersistAndLoadEmptyTenantName() throws {
        let tenantFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        let tenantName = ""

        try tenantName.write(to: tenantFile, atomically: true, encoding: .utf8)

        let loaded = try String(contentsOf: tenantFile, encoding: .utf8)
        XCTAssertEqual(loaded, tenantName)
    }

    func testDeleteTenantNameCausesSubsequentLoadToFail() throws {
        let tenantFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        try "test-tenant".write(to: tenantFile, atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(at: tenantFile)

        XCTAssertThrowsError(try String(contentsOf: tenantFile, encoding: .utf8))
    }

    // MARK: - Coordinator URL persistence

    func testPersistAndLoadCoordinatorURL() throws {
        let urlFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        let coordinatorURL = "https://custom.example.com"

        try coordinatorURL.write(to: urlFile, atomically: true, encoding: .utf8)

        let loaded = try String(contentsOf: urlFile, encoding: .utf8)
        XCTAssertEqual(loaded, coordinatorURL)
    }

    func testDeleteCoordinatorURLCausesSubsequentLoadToFail() throws {
        let urlFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        try "https://custom.example.com".write(to: urlFile, atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(at: urlFile)

        XCTAssertThrowsError(try String(contentsOf: urlFile, encoding: .utf8))
    }

    // MARK: - File name constants

    func testTenantFileNameConstant() {
        XCTAssertEqual(DefaultSettings.FileNames.tenantFileName, "tenant.txt")
    }

    func testCoordinatorURLFileNameConstant() {
        XCTAssertEqual(DefaultSettings.FileNames.coordinatorURLFileName, "coordinatorURL.txt")
    }

    // MARK: - UserDefaults keys constants

    func testLastTenantKeyConstant() {
        XCTAssertEqual(DefaultSettings.UserDefaultsKeys.lastTenant, "io.cubbit.DS3Drive.userDefaults.lastTenant")
    }

    func testLastCoordinatorURLKeyConstant() {
        XCTAssertEqual(DefaultSettings.UserDefaultsKeys.lastCoordinatorURL, "io.cubbit.DS3Drive.userDefaults.lastCoordinatorURL")
    }

    // MARK: - Notification constants

    func testAuthFailureNotificationConstant() {
        XCTAssertEqual(DefaultSettings.Notifications.authFailure, "io.cubbit.DS3Drive.notifications.authFailure")
    }
}
