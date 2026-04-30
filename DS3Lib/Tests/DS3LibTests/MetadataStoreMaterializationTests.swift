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

    func testUpsertUpgradesFalseToTrue() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: false)
        ])
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: true)
        ])
        let keys = try await materializedKeys()
        XCTAssertTrue(
            keys.contains("a.txt"),
            "batchUpsertItems must upgrade isMaterialized false → true"
        )
    }

    func testMarkMaterializedEmptySetIsNoop() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: false)
        ])
        try await store.markMaterialized([], driveId: driveId)
        let keys = try await materializedKeys()
        XCTAssertFalse(keys.contains("a.txt"), "empty set must be a no-op")
    }

    func testMarkMaterializedUnknownKeyIsSilentNoop() async throws {
        try await store.batchUpsertItems([
            .init(s3Key: "a.txt", driveId: driveId, isMaterialized: false)
        ])
        try await store.markMaterialized(["nonexistent.txt"], driveId: driveId)
        let keys = try await materializedKeys()
        XCTAssertFalse(
            keys.contains("a.txt"),
            "unmodified row must remain non-materialised"
        )
        XCTAssertFalse(
            keys.contains("nonexistent.txt"),
            "unknown key must not synthesise a row"
        )
    }

    func testPruneChildrenPreservesWorkingSetRows() async throws {
        let parentKey = "Personal/Images/"
        // Two children of the same folder, both synced. Only `b.txt` is in
        // the working set (visited-folder member). After a fresh listing
        // returns only `a.txt`, the prune must preserve `b.txt` so
        // WorkingSetEnumerator can HEAD it and surface the deletion.
        try await store.batchUpsertItems([
            .init(
                s3Key: parentKey + "a.txt", driveId: driveId,
                syncStatus: .synced, parentKey: parentKey, isMaterialized: true
            ),
            .init(
                s3Key: parentKey + "b.txt", driveId: driveId,
                syncStatus: .synced, parentKey: parentKey, isMaterialized: true
            ),
            .init(
                s3Key: parentKey + "c.txt", driveId: driveId,
                syncStatus: .synced, parentKey: parentKey, isMaterialized: false
            )
        ])

        // Fresh S3 listing returns only `a.txt` — both `b.txt` (working-set
        // member) and `c.txt` (not materialised) are stale.
        try await store.pruneChildren(
            parentKey: parentKey, driveId: driveId,
            keepKeys: [parentKey + "a.txt"]
        )

        let workingSet = try await materializedKeys()
        XCTAssertTrue(workingSet.contains(parentKey + "a.txt"),
                      "row in keepKeys must remain")
        XCTAssertTrue(workingSet.contains(parentKey + "b.txt"),
                      "working-set member must be preserved across pruneChildren")
        // c.txt was not in the working set; it should be pruned.
        let remainingChildren = try await store.fetchChildren(parentKey: parentKey, driveId: driveId)
        let remainingKeys = Set(remainingChildren.map(\.s3Key))
        XCTAssertFalse(remainingKeys.contains(parentKey + "c.txt"),
                       "non-materialised stale row must be pruned")
    }
}
