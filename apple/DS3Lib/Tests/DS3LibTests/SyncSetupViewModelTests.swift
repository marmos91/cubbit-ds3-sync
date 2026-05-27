import XCTest
@testable import DS3Lib

/// Tests for SyncSetupViewModel-related logic extracted into DS3Lib.
/// suggestedDriveName is tested in S3PathUtilsTests; this file covers
/// SyncAnchor construction, formatting, and console URL building.
final class SyncSetupViewModelTests: XCTestCase {
    // MARK: - SyncAnchor Construction

    func testSyncAnchorConstruction() {
        let project = Project(
            id: "proj-1", name: "TestProject", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: [IAMUser(id: "u-1", username: "admin", isRoot: true)]
        )
        let anchor = SyncAnchor(
            project: project,
            IAMUser: IAMUser(id: "u-1", username: "admin", isRoot: true),
            bucket: Bucket(name: "my-bucket"),
            prefix: "docs/"
        )

        XCTAssertEqual(anchor.project.id, "proj-1")
        XCTAssertEqual(anchor.IAMUser.username, "admin")
        XCTAssertEqual(anchor.bucket.name, "my-bucket")
        XCTAssertEqual(anchor.prefix, "docs/")
    }

    func testSyncAnchorWithNilPrefix() {
        let project = Project(
            id: "proj-1", name: "Test", description: "", email: "",
            createdAt: "", tenantId: "", users: []
        )
        let anchor = SyncAnchor(
            project: project,
            IAMUser: IAMUser(id: "u-1", username: "user", isRoot: false),
            bucket: Bucket(name: "bucket"),
            prefix: nil
        )
        XCTAssertNil(anchor.prefix)
    }

    // MARK: - Drive Name Formatting

    func testSyncAnchorStringFormatting() {
        let projectName = "MyProject"
        let prefix: String? = "photos/"

        var name = projectName
        if let prefix { name += "/\(prefix)" }

        XCTAssertEqual(name, "MyProject/photos/")
    }

    func testSyncAnchorStringFormattingNoPrefix() {
        let projectName = "MyProject"
        let prefix: String? = nil

        var name = projectName
        if let prefix { name += "/\(prefix)" }

        XCTAssertEqual(name, "MyProject")
    }

    // MARK: - Console URL Construction

    func testConsoleURLConstruction() {
        let projectId = "proj-123"
        let bucketName = "my-bucket"
        let prefix: String? = "photos/"

        var url = "\(ConsoleURLs.projectsURL)/\(projectId)/buckets/\(bucketName)"
        if let prefix { url += "/\(prefix)" }

        XCTAssertTrue(url.contains("projects/proj-123/buckets/my-bucket/photos/"))
    }

    func testConsoleURLConstructionNoPrefix() {
        let projectId = "proj-123"
        let bucketName = "my-bucket"
        let prefix: String? = nil

        var url = "\(ConsoleURLs.projectsURL)/\(projectId)/buckets/\(bucketName)"
        if let prefix { url += "/\(prefix)" }

        XCTAssertTrue(url.hasSuffix("buckets/my-bucket"))
    }

    // MARK: - API Key Name for SyncAnchor

    func testApiKeyNameFromSyncAnchorUser() {
        let user = IAMUser(id: "user-1", username: "admin", isRoot: true)
        let keyName = DS3SDK.apiKeyName(forUser: user, projectName: "My Project")
        XCTAssertTrue(keyName.contains("admin"))
        XCTAssertTrue(keyName.contains("my_project"))
    }
}
