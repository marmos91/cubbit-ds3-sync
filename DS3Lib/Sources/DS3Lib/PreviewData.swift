#if DEBUG
import Foundation

/// Shared preview fixtures for SwiftUI previews across all targets.
/// Provides consistent, realistic test data without hardcoded inline values.
public enum PreviewData {

    // MARK: - IAM Users

    public static let rootUser = IAMUser(
        id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
        username: "ROOT",
        isRoot: true
    )

    public static let regularUser = IAMUser(
        id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        username: "developer",
        isRoot: false
    )

    // MARK: - Projects

    public static let project = Project(
        id: "63611af7-0db6-465a-b2f8-2791200b69de",
        name: "Personal",
        description: "Personal project",
        email: "Personal@cubbit.io",
        createdAt: "2023-01-27T15:01:02.904417Z",
        tenantId: "00000000-0000-0000-0000-000000000000",
        users: [rootUser]
    )

    public static let secondProject = Project(
        id: "b4c5d6e7-f8a9-0b1c-2d3e-4f5a6b7c8d9e",
        name: "Team",
        description: "Team project",
        email: "Team@cubbit.io",
        createdAt: "2023-06-15T10:00:00.000000Z",
        tenantId: "00000000-0000-0000-0000-000000000000",
        users: [rootUser, regularUser]
    )

    // MARK: - Buckets

    public static let bucket = Bucket(name: "my-bucket")
    public static let secondBucket = Bucket(name: "backups")

    // MARK: - Sync Anchor

    public static let syncAnchor = SyncAnchor(
        project: project,
        IAMUser: rootUser,
        bucket: bucket,
        prefix: "Documents"
    )

    // MARK: - Drives

    public static let drive = DS3Drive(
        id: UUID(uuidString: "e1f2a3b4-c5d6-7890-abcd-ef1234567890")!,
        name: "Personal Drive",
        syncAnchor: syncAnchor
    )

    // MARK: - Account

    public static let accountEmail = AccountEmail(
        id: "email-001",
        email: "user@cubbit.io",
        isDefault: true,
        createdAt: "2023-01-27T15:01:02.904417Z",
        isVerified: true,
        tenantId: "tenant-001"
    )

    public static let account = Account(
        id: "account-001",
        firstName: "Marco",
        lastName: "Moschettini",
        isInternal: false,
        isBanned: false,
        createdAt: "2023-01-27T15:01:02.904417Z",
        maxAllowedProjects: 3,
        emails: [accountEmail],
        isTwoFactorEnabled: true,
        tenantId: "tenant-001",
        endpointGateway: "https://s3.cubbit.eu",
        authProvider: "cubbit"
    )
}
#endif
