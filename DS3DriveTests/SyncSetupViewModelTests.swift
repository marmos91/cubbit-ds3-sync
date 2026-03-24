@testable import Cubbit_DS3_Drive
@testable import DS3Lib
import XCTest

final class SyncSetupViewModelTests: XCTestCase {
    // MARK: - Helpers

    private func makeProject() -> Project {
        Project(
            id: "proj-1", name: "TestProject", description: "desc",
            email: "e@c.io", createdAt: "2023-01-01", tenantId: "t-1",
            users: [IAMUser(id: "u-1", username: "admin", isRoot: true)]
        )
    }

    private func makeSyncAnchor(prefix: String? = "docs/") -> SyncAnchor {
        SyncAnchor(
            project: makeProject(),
            IAMUser: IAMUser(id: "u-1", username: "admin", isRoot: true),
            bucket: Bucket(name: "my-bucket"),
            prefix: prefix
        )
    }

    // MARK: - Initial State

    func testInitialState() {
        let vm = SyncSetupViewModel()
        XCTAssertNil(vm.selectedProject)
        XCTAssertNil(vm.selectedSyncAnchor)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertNil(vm.selectedPrefix)
        XCTAssertEqual(vm.setupStep, .treeNavigation)
    }

    // MARK: - Project Selection

    func testSelectProject() {
        let vm = SyncSetupViewModel()
        let project = makeProject()

        vm.selectProject(project: project)

        XCTAssertEqual(vm.selectedProject?.id, "proj-1")
    }

    // MARK: - Sync Anchor Selection

    func testSelectSyncAnchorSetsAllProperties() {
        let vm = SyncSetupViewModel()
        let anchor = makeSyncAnchor(prefix: "photos/")

        vm.selectSyncAnchor(anchor: anchor)

        XCTAssertNotNil(vm.selectedSyncAnchor)
        XCTAssertEqual(vm.selectedBucket?.name, "my-bucket")
        XCTAssertEqual(vm.selectedPrefix, "photos/")
        XCTAssertEqual(vm.setupStep, .driveConfirm)
    }

    func testSelectSyncAnchorNilPrefix() {
        let vm = SyncSetupViewModel()
        let anchor = makeSyncAnchor(prefix: nil)

        vm.selectSyncAnchor(anchor: anchor)

        XCTAssertNil(vm.selectedPrefix)
        XCTAssertEqual(vm.setupStep, .driveConfirm)
    }

    // MARK: - Suggested Drive Name

    func testSuggestedDriveNameBucketOnly() {
        let vm = SyncSetupViewModel()
        vm.selectedBucket = Bucket(name: "data-bucket")

        XCTAssertEqual(vm.suggestedDriveName, "data-bucket")
    }

    func testSuggestedDriveNameWithPrefix() {
        let vm = SyncSetupViewModel()
        vm.selectedBucket = Bucket(name: "data-bucket")
        vm.selectedPrefix = "exports/daily/"

        XCTAssertEqual(vm.suggestedDriveName, "data-bucket/daily")
    }

    func testSuggestedDriveNameEmptyPrefix() {
        let vm = SyncSetupViewModel()
        vm.selectedBucket = Bucket(name: "bucket")
        vm.selectedPrefix = ""

        XCTAssertEqual(vm.suggestedDriveName, "bucket")
    }

    func testSuggestedDriveNameNoBucket() {
        let vm = SyncSetupViewModel()
        XCTAssertEqual(vm.suggestedDriveName, "")
    }

    // MARK: - Step Navigation

    func testGoBackReturnsToTreeNavigation() {
        let vm = SyncSetupViewModel()
        vm.selectSyncAnchor(anchor: makeSyncAnchor())

        XCTAssertEqual(vm.setupStep, .driveConfirm)

        vm.goBack()

        XCTAssertEqual(vm.setupStep, .treeNavigation)
    }

    func testSelectSyncSetupStep() {
        let vm = SyncSetupViewModel()

        vm.selectSyncSetupStep(.driveConfirm)
        XCTAssertEqual(vm.setupStep, .driveConfirm)

        vm.selectSyncSetupStep(.treeNavigation)
        XCTAssertEqual(vm.setupStep, .treeNavigation)
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        let vm = SyncSetupViewModel()
        vm.selectProject(project: makeProject())
        vm.selectSyncAnchor(anchor: makeSyncAnchor())

        XCTAssertNotNil(vm.selectedProject)
        XCTAssertNotNil(vm.selectedBucket)
        XCTAssertEqual(vm.setupStep, .driveConfirm)

        vm.reset()

        XCTAssertNil(vm.selectedProject)
        XCTAssertNil(vm.selectedSyncAnchor)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertNil(vm.selectedPrefix)
        XCTAssertEqual(vm.setupStep, .treeNavigation)
    }
}
