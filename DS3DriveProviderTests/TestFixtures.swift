@testable import DS3Lib
import FileProvider
import Foundation

/// Shared test fixtures for DS3DriveProviderTests.
enum ProviderTestFixtures {
    static func makeDrive(prefix: String? = "prefix/") -> DS3Drive {
        let project = Project(
            id: "proj-1", name: "Test", description: "",
            email: "", createdAt: "", tenantId: "",
            users: [IAMUser(id: "u-1", username: "user", isRoot: true)]
        )
        return DS3Drive(
            id: UUID(), name: "TestDrive",
            syncAnchor: SyncAnchor(
                project: project,
                IAMUser: IAMUser(id: "u-1", username: "user", isRoot: true),
                bucket: Bucket(name: "test-bucket"),
                prefix: prefix
            )
        )
    }

    static func makeItem(
        key: String,
        drive: DS3Drive? = nil,
        etag: String? = nil,
        size: Int64 = 0,
        syncStatus: String? = nil
    ) -> S3Item {
        let resolvedDrive = drive ?? makeDrive()
        return S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: resolvedDrive,
            objectMetadata: S3Item.Metadata(
                etag: etag,
                size: NSNumber(value: size),
                syncStatus: syncStatus
            )
        )
    }
}
