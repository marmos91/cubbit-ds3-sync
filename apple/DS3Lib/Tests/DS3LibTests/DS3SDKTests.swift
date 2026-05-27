import XCTest
@testable import DS3Lib

/// Tests for DS3SDK utility methods (no network calls).
final class DS3SDKTests: XCTestCase {
    // MARK: - API Key Name Generation

    func testApiKeyNameFormat() {
        let user = IAMUser(id: "user-1", username: "admin", isRoot: true)
        let projectName = "My Project"

        let name = DS3SDK.apiKeyName(forUser: user, projectName: projectName)

        XCTAssertTrue(name.hasPrefix("DS3Drive-for-macOS"))
        XCTAssertTrue(name.contains("admin"))
        XCTAssertTrue(name.contains("my_project"))
        XCTAssertTrue(name.contains(DefaultSettings.appUUID))
    }

    func testApiKeyNameLowercasesProject() {
        let user = IAMUser(id: "user-1", username: "testuser", isRoot: false)
        let name = DS3SDK.apiKeyName(forUser: user, projectName: "MyBigProject")

        XCTAssertTrue(name.contains("mybigproject"))
    }

    func testApiKeyNameReplacesSpaces() {
        let user = IAMUser(id: "user-1", username: "admin", isRoot: true)
        let name = DS3SDK.apiKeyName(forUser: user, projectName: "Project With Spaces")

        XCTAssertFalse(name.contains(" "), "Spaces should be replaced with underscores")
        XCTAssertTrue(name.contains("project_with_spaces"))
    }

    func testApiKeyNameDeterministic() {
        let user = IAMUser(id: "user-1", username: "admin", isRoot: true)
        let name1 = DS3SDK.apiKeyName(forUser: user, projectName: "TestProject")
        let name2 = DS3SDK.apiKeyName(forUser: user, projectName: "TestProject")

        XCTAssertEqual(name1, name2, "API key names should be deterministic")
    }

    func testApiKeyNameDiffersForDifferentUsers() {
        let user1 = IAMUser(id: "user-1", username: "alice", isRoot: true)
        let user2 = IAMUser(id: "user-2", username: "bob", isRoot: false)

        let name1 = DS3SDK.apiKeyName(forUser: user1, projectName: "Project")
        let name2 = DS3SDK.apiKeyName(forUser: user2, projectName: "Project")

        XCTAssertNotEqual(name1, name2)
    }

    func testApiKeyNameDiffersForDifferentProjects() {
        let user = IAMUser(id: "user-1", username: "admin", isRoot: true)

        let name1 = DS3SDK.apiKeyName(forUser: user, projectName: "ProjectA")
        let name2 = DS3SDK.apiKeyName(forUser: user, projectName: "ProjectB")

        XCTAssertNotEqual(name1, name2)
    }

    // MARK: - SDK Error Descriptions

    func testDS3SDKErrorDescriptions() {
        XCTAssertNotNil(DS3SDKError.invalidURL(url: "test").errorDescription)
        XCTAssertNotNil(DS3SDKError.serverError.errorDescription)
        XCTAssertNotNil(DS3SDKError.jsonConversion.errorDescription)
        XCTAssertNotNil(DS3SDKError.encodingError.errorDescription)
    }

    // MARK: - SharedData Injection

    func testSDKWithInjectedSharedDataWritesAPIKeysToGivenDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sharedData = SharedData(testContainerURL: tempDir)

        let json = """
        [{"name":"DS3Drive-for-macOS-user-project","api_key":"access-key-1","secret_key":"secret-1","created_at":"2024-01-01T00:00:00.000+00:00"}]
        """
        let keys = try JSONDecoder().decode([DS3ApiKey].self, from: Data(json.utf8))
        try sharedData.persistDS3APIKeys(keys)

        let loaded = try sharedData.loadDS3APIKeysFromPersistence()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].apiKey, "access-key-1")

        let credentialsFile = tempDir.appendingPathComponent(DefaultSettings.FileNames.credentialsFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: credentialsFile.path))
    }

    // MARK: - Authentication Error Descriptions

    func testDS3AuthenticationErrorDescriptions() {
        let errors: [DS3AuthenticationError] = [
            .invalidURL(url: "https://example.com"),
            .invalidURL(url: nil),
            .timeConversion,
            .cookies,
            .encoding,
            .serverError,
            .jsonConversion,
            .loggedOut,
            .alreadyLoggedIn,
            .alreadyLoggedOut,
            .tokenExpired,
            .missing2FA
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
        }
    }
}
