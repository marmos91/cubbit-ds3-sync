import Foundation
import SwiftData
import XCTest

@testable import DS3Lib

/// Tests for `ThumbnailUploader` — the Phase 13 / Plan 13-02 render+PUT pipeline
/// invoked by the upload-hook in `createItem`/`modifyItem` (Plan 13-07 wiring).
///
/// Phase 13.2 Plan 09 (D-05, D-08, D-23): Schema V6 dropped the
/// `thumbnailStatus` field, so the uploader no longer writes `.uploaded`,
/// `.notApplicable`, `.pending`, or `.failed` to it. The "is the thumbnail
/// uploaded?" question is now answered by S3 itself via `getThumbnailBytes`.
/// Tests therefore assert on the S3 PUT contract (key, bytes, metadata, error
/// rethrow) rather than on schema-level transitions.
///
/// Coverage matches Plan 13-02 `<behavior>`:
///   1. Raster fixture round-trip — render success + single PUT to canonical key.
///   2. Non-raster originalKey — defensive guard, no PUT.
///   3. Renderer returns nil (rejected fixture) — no PUT, no rethrow.
///   4. PUT throws — rethrow to caller.
///   5. PUT key matches `S3PathUtils.thumbnailKey(...)` (canonical key, no ad-hoc concat).
///
/// Per D-09 the `generateAndUpload` function is `#if os(macOS)`-gated, so the whole
/// test class is gated too. iOS test runs (DS3LibTests platform=iOS) compile this
/// file as an empty translation unit.
#if os(macOS)
    final class ThumbnailUploaderTests: XCTestCase {
        // MARK: - Fixtures

        private var container: ModelContainer!
        private var metadataStore: MetadataStore!
        private var mockS3: MockDS3S3Client!
        private var uploader: ThumbnailUploader!

        private let driveId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        private let drivePrefix: String? = nil // root-level drive — keeps thumbnailKey arithmetic simple

        override func setUp() async throws {
            // In-memory MetadataStore bound to V6 (Phase 13.2 Plan 09 dropped
            // `thumbnailStatus`). `SyncedItem` resolves to
            // `SyncedItemSchemaV6.SyncedItem`.
            let schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            metadataStore = MetadataStore(modelContainer: container)

            mockS3 = MockDS3S3Client()
            mockS3.putObjectDataEtag = "\"thumb-etag\""

            uploader = ThumbnailUploader(s3Client: mockS3, metadataStore: metadataStore)
        }

        override func tearDown() async throws {
            uploader = nil
            mockS3 = nil
            metadataStore = nil
            container = nil
        }

        // MARK: - Helpers

        private func fixtureURL(name: String, ext: String) throws -> URL {
            try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: ext),
                "fixture \(name).\(ext) missing — check DS3LibTests resources(.process(\"Fixtures\"))"
            )
        }

        private func makeDrive() -> DS3Drive {
            // Build a SyncAnchor with the test driveId → root prefix → "test-bucket".
            let bucket = Bucket(name: "test-bucket")
            let project = Project(
                id: "proj-id",
                name: "Test",
                description: "Test project",
                email: "test@cubbit.io",
                createdAt: "2026-01-01T00:00:00.000000Z",
                tenantId: "tenant-id",
                users: []
            )
            let user = IAMUser(id: "user-id", username: "test", isRoot: true)
            let anchor = SyncAnchor(
                project: project,
                IAMUser: user,
                bucket: bucket,
                prefix: drivePrefix
            )
            return DS3Drive(id: driveId, name: "Test Drive", syncAnchor: anchor)
        }

        /// Seeds a SyncedItem at `s3Key`. Phase 13.2 Plan 09: no thumbnail
        /// fields to seed — `SyncedItem` no longer carries any.
        private func seedItem(s3Key: String) async throws {
            try await metadataStore.upsertItem(
                s3Key: s3Key,
                driveId: driveId,
                etag: "\"original-etag\"",
                syncStatus: .synced,
                contentType: "image/jpeg",
                size: 1024
            )
        }

        // MARK: - Test 1: render success + PUT (no schema write)

        func testGenerateAndUploadOnRasterFixtureRendersAndPuts() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/exif6-portrait.jpg"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "\"original-etag\"",
                originalKey: originalKey
            )

            // One PUT call landed on the S3 client with non-empty data and the
            // sourceETag carried in metadata.
            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 1, "expected exactly one PUT for a raster fixture")
            XCTAssertEqual(mockS3.lastPutObjectDataBucket, "test-bucket")
            XCTAssertNotNil(mockS3.lastPutObjectDataBytes)
            XCTAssertGreaterThan(mockS3.lastPutObjectDataBytes ?? 0, 0)
            XCTAssertEqual(
                mockS3.lastPutObjectDataMetadata?[
                    DefaultSettings.Thumbnail.sourceETagMetadataKey
                ],
                "\"original-etag\""
            )

            // Phase 13.2 D-08: no `.uploaded` schema write — the field is gone.
            // Success is observable via the PUT call only.
        }

        // MARK: - Test 2: non-raster guard → no PUT, no schema write

        func testGenerateAndUploadOnNonRasterIsNoOp() async throws {
            // Caller forgot to pre-filter — pass a .pdf originalKey. Defensive guard
            // must short-circuit before render and before PUT. localURL is irrelevant
            // because we never attempt to read it.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ignored-\(UUID().uuidString).pdf")
            let drive = makeDrive()
            let originalKey = "docs/document.pdf"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "src-etag",
                originalKey: originalKey
            )

            // Zero PUT calls — early return.
            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 0, "non-raster originalKey must not trigger any PUT")

            // Phase 13.2 D-08: no `.notApplicable` schema write — the field is gone.
        }

        // MARK: - Test 3: renderer rejects fixture → log + return, no PUT, no rethrow

        func testGenerateAndUploadWhenRendererReturnsNilLogsAndReturns() async throws {
            // Write garbage bytes into a .jpg file so `isRasterExtension` passes
            // but `CGImageSourceCreateWithURL` (or UTI allow-list) rejects.
            let bogusURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bogus-\(UUID().uuidString).jpg")
            try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).write(to: bogusURL)
            defer { try? FileManager.default.removeItem(at: bogusURL) }

            let drive = makeDrive()
            let originalKey = "photos/corrupt.jpg"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: bogusURL,
                drive: drive,
                sourceETag: "src",
                originalKey: originalKey
            )

            let putCount = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCount, 0, "render-nil must not produce a PUT")

            // Phase 13.2 D-05/D-19: the consume-path fallback's
            // `ThumbnailFallbackLimiter` (in-memory) owns the 3-strike rule.
            // Repeated render-nil calls must not throw.
            try await uploader.generateAndUpload(
                localURL: bogusURL, drive: drive, sourceETag: "src", originalKey: originalKey
            )
            try await uploader.generateAndUpload(
                localURL: bogusURL, drive: drive, sourceETag: "src", originalKey: originalKey
            )

            let putCountAfterThree = mockS3.calls.filter { $0.hasPrefix("putObjectData(") }.count
            XCTAssertEqual(putCountAfterThree, 0, "render-nil must never PUT, no matter the call count")
        }

        // MARK: - Test 4: PUT throws → rethrow

        func testGenerateAndUploadOnPutFailureRethrows() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/will-fail.jpg"
            try await seedItem(s3Key: originalKey)

            // Force the underlying putObjectData to throw.
            mockS3.shouldThrow = DS3ClientError.parseError

            do {
                try await uploader.generateAndUpload(
                    localURL: url,
                    drive: drive,
                    sourceETag: "src",
                    originalKey: originalKey
                )
                XCTFail("expected generateAndUpload to rethrow on PUT failure")
            } catch {
                // Expected — error must be re-surfaced to the caller.
                XCTAssertTrue(
                    error is DS3ClientError,
                    "uploader must rethrow the underlying PUT error type"
                )
            }
        }

        // MARK: - Test 5: PUT key uses S3PathUtils.thumbnailKey (canonical)

        func testThumbnailKeyIsAppendedJpgOnExistingExtension() async throws {
            let url = try fixtureURL(name: "exif6-portrait", ext: "jpg")
            let drive = makeDrive()
            let originalKey = "photos/exif6-portrait.jpg"
            try await seedItem(s3Key: originalKey)

            try await uploader.generateAndUpload(
                localURL: url,
                drive: drive,
                sourceETag: "src",
                originalKey: originalKey
            )

            // Canonical thumbnail key — appends `.jpg` to the full filename, places
            // `.thumbnails/` in the same directory as the original. We assert the
            // PUT key matches `S3PathUtils.thumbnailKey(...)` rather than a hand-
            // computed string, so a future change to the canonical helper updates
            // both production code and this assertion together.
            let expected = S3PathUtils.thumbnailKey(
                forOriginalKey: originalKey, drivePrefix: drivePrefix
            )
            XCTAssertEqual(mockS3.lastPutObjectDataKey, expected)
            XCTAssertEqual(expected, "photos/.thumbnails/exif6-portrait.jpg.jpg")
        }
    }
#endif
