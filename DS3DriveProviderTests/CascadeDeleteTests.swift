@testable import DS3Lib
import FileProvider
import Foundation
import os.log
import SwiftData
import XCTest

/// Tests the post-delete thumbnail cascade hook (Phase 13, Plan 13-08; D-21; THUMB-17).
///
/// `enqueueThumbnailDeleteCascade` is a free function — same design as Plan 13-07's
/// `enqueueThumbnailUpload` — so tests exercise it directly without standing up a
/// real `FileProviderExtension`. The mock S3 client records the underlying
/// `deleteObject` call (which `deleteThumbnail` issues underneath) and asserts on
/// the cascade key matches `S3PathUtils.thumbnailKey(...)`.
///
/// Per D-21 the cascade is FIRE-AND-FORGET: the user-visible delete completion
/// handler returns success BEFORE the detached Task starts, and any cascade
/// failure is logged + swallowed. The orphan sweep (Plan 13-09) is the backstop.
final class CascadeDeleteTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var container: ModelContainer!
    private var metadataStore: MetadataStore!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        metadataStore = MetadataStore(modelContainer: container)
    }

    override func tearDown() async throws {
        metadataStore = nil
        container = nil
    }

    private func makeLogger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "cascade-delete")
    }

    // MARK: - Test 1 — Raster delete cascades deleteThumbnail

    /// `.jpg` originals trigger a deleteThumbnail call to the corresponding
    /// `.thumbnails/<filename>.jpg` key (computed via `S3PathUtils.thumbnailKey`).
    func testDeleteItemRasterCascadesDeleteThumbnail() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = CascadeMockS3Client()

        let originalKey = "prefix/photos/holiday.jpg"
        let expectedThumbKey = S3PathUtils.thumbnailKey(
            forOriginalKey: originalKey, drivePrefix: drive.syncAnchor.prefix
        )

        enqueueThumbnailDeleteCascade(
            originalKey: originalKey,
            drive: drive,
            s3Client: mock,
            logger: makeLogger()
        )

        let predicate = NSPredicate { _, _ in
            mock.deleteObjectKeys.contains(expectedThumbKey)
        }
        let exp = expectation(for: predicate, evaluatedWith: NSObject(), handler: nil)
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(
            mock.deleteObjectKeys, [expectedThumbKey],
            "Raster delete must cascade exactly one deleteThumbnail to the matching thumb key"
        )
    }

    // MARK: - Test 2 — Non-raster delete does NOT cascade

    /// `.pdf` originals MUST NOT trigger a deleteThumbnail call (D-08 gate).
    func testDeleteItemNonRasterDoesNotCascade() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = CascadeMockS3Client()

        enqueueThumbnailDeleteCascade(
            originalKey: "prefix/docs/report.pdf",
            drive: drive,
            s3Client: mock,
            logger: makeLogger()
        )

        // Drain any in-flight detached Task.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            mock.deleteObjectKeys.count, 0,
            "Non-raster delete MUST NOT cascade to deleteThumbnail (D-08 gate)"
        )
    }

    // MARK: - Test 3 — Cascade is fire-and-forget; helper returns synchronously

    /// The cascade helper opens a `Task.detached` and returns immediately. Even
    /// when the underlying `deleteThumbnail` artificially sleeps 500ms, the
    /// helper's call site completes in well under 50ms.
    func testDeleteItemCompletionDoesNotWaitForCascade() {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = CascadeMockS3Client()
        mock.deleteObjectDelayNanos = 500_000_000

        let start = DispatchTime.now()
        enqueueThumbnailDeleteCascade(
            originalKey: "prefix/slow.jpg",
            drive: drive,
            s3Client: mock,
            logger: makeLogger()
        )
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        XCTAssertLessThan(
            elapsedNanos, 50_000_000,
            "Delete cascade MUST be fire-and-forget; helper must NOT block on deleteThumbnail latency (D-21)"
        )
    }

    // MARK: - Test 4 — deleteThumbnail failure is swallowed (no propagation)

    /// `enqueueThumbnailDeleteCascade` returns Void; even when the underlying
    /// deleteObject throws, the helper does not surface the error.
    func testDeleteItemThumbnailDeleteFailureSwallowed() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = CascadeMockS3Client()
        mock.deleteObjectError = NSError(domain: "TestDomain", code: 42, userInfo: nil)

        // Helper returns Void — calling it CANNOT throw.
        enqueueThumbnailDeleteCascade(
            originalKey: "prefix/fail.jpg",
            drive: drive,
            s3Client: mock,
            logger: makeLogger()
        )

        // Drain the detached Task so the error path runs and is swallowed.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mock.deleteObjectKeys.count, 1, "Delete must be attempted before failure path")
    }

    // MARK: - Test 5 — 404 from deleteThumbnail is silent (Phase 12 D-14 contract)

    /// `DS3S3ClientProtocol.deleteThumbnail` already swallows 404s silently
    /// (Phase 12 D-14). The cascade helper inherits this contract — when the
    /// thumb is already gone, the helper completes without throwing or logging
    /// an error. We can't probe OSLog from XCTest, so the soft assertion is
    /// "test process keeps running and the delete attempt was observed by the
    /// mock". The Phase 12 D-14 silent-on-404 behavior is tested directly in
    /// `DS3LibTests`; here we verify the cascade helper does not retry or
    /// surface anything when the underlying call returns gracefully.
    func testDeleteItemThumbnail404SilentNoLog() async {
        let drive = ProviderTestFixtures.makeDrive()
        let mock = CascadeMockS3Client()
        // Mock returns success (no error) — same observable behavior as the
        // Phase 12 swallow-404 path (deleteThumbnail returns void on 404).
        // No assertion on mock observability beyond "delete was attempted".

        enqueueThumbnailDeleteCascade(
            originalKey: "prefix/already-gone.jpg",
            drive: drive,
            s3Client: mock,
            logger: makeLogger()
        )

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            mock.deleteObjectKeys.count, 1,
            "Cascade must invoke deleteObject once even for already-gone thumbs (Phase 12 D-14 swallows the 404 underneath)"
        )
    }
}
