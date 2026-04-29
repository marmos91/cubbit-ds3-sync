import XCTest
import SwiftData
@testable import DS3Lib

/// Tests that the MetadataStore working-set flag (`isMaterialized`) follows
/// additive semantics: it can only be set, never cleared by upsert. Required
/// for working-set drift detection — visited-folder children flagged by
/// S3Enumerator must not be cleared just because Apple's
/// `enumeratorForMaterializedItems` reports only on-disk blobs.
final class MetadataStoreMaterializationTests: XCTestCase {
    private var container: ModelContainer!
    private var store: MetadataStore!
    private let driveId = UUID()

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = MetadataStore(modelContainer: container)
    }

    /// Returns the working-set keys for a drive — only rows where
    /// `isMaterialized == true`. Sendable-safe (returns `[String]`).
    private func materializedKeys() async throws -> Set<String> {
        let members = try await store.fetchWorkingSetMembers(driveId: driveId)
        return Set(members.map(\.s3Key))
    }

    func testUpsertSetsIsMaterializedWhenTrue() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: true)
        ])
        let keys = try await materializedKeys()
        XCTAssertTrue(keys.contains("a.txt"))
    }

    func testUpsertIsAdditiveAndDoesNotClearTrueRow() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: true)
        ])
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: false)
        ])
        let keys = try await materializedKeys()
        XCTAssertTrue(
            keys.contains("a.txt"),
            "applyUpsert must be additive — never downgrade isMaterialized true → false"
        )
    }

    func testMarkMaterializedAddsKeysWithoutClearingOthers() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: true),
            .init(s3Key: "b.txt", driveId: driveId, isMaterialized: false),
            .init(s3Key: "c.txt", driveId: driveId, isMaterialized: false)
        ])
        try await store.markMaterialized(["b.txt"], driveId: driveId)

        let keys = try await materializedKeys()
        XCTAssertTrue(keys.contains("a.txt"), "must not clobber previously-materialised rows")
        XCTAssertTrue(keys.contains("b.txt"), "supplied key must be marked")
        XCTAssertFalse(keys.contains("c.txt"), "rows not in the set must remain false")
    }
}
