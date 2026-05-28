@testable import DS3Lib
import XCTest

/// Phase 13-03 / THUMB-18 — coverage for `copyThumbnail`.
///
/// `copyThumbnail` is a protocol-default extension on `DS3S3ClientProtocol`
/// (mirrors the put/get/delete pattern from Phase 12-03), so the mock
/// inherits it for free. The contract under test:
///
/// 1. Issues exactly ONE underlying `copyObject` call (single-API server-side
///    copy — no client-side GET+PUT).
/// 2. Passes `metadata: nil` so Soto omits `x-amz-metadata-directive` and
///    AWS S3's default behavior is COPY (preserves `x-amz-meta-source-etag`
///    and `x-amz-meta-ds3drive-thumb-version` written by Phase 12).
/// 3. Rethrows on `NoSuchKey` (caller — Plan 13-08 rename cascade — maps to
///    "mark new key .pending, let backfill regenerate").
/// 4. Rethrows on 5xx / generic server errors (caller maps to same fallback).
/// 5. `fromKey` and `toKey` reach `copyObject` byte-for-byte as `sourceKey`
///    and `destinationKey` (no munging — percent-encoding is `copyObject`'s
///    responsibility, per Pitfall 6 in 13-RESEARCH.md).
final class CopyThumbnailTests: XCTestCase {
    // MARK: - Helpers

    private func makeMock() -> MockDS3S3Client {
        MockDS3S3Client()
    }

    /// A canned NoSuchKey error matching the precedent set by Phase 12's
    /// `DS3S3ClientThumbnailsTests` (DS3S3Error.noSuchKey is what `isNotFoundError`
    /// matches via the new DS3S3Error category flags).
    private var notFoundError: Error {
        DS3S3Error.noSuchKey
    }

    // MARK: - Test 1: single-call delegation

    func testCopyThumbnailIssuesSingleCopyObject() async throws {
        let mock = makeMock()

        try await mock.copyThumbnail(
            bucket: "b",
            fromKey: "src/.thumbnails/a.jpg.jpg",
            toKey: "src/.thumbnails/b.jpg.jpg"
        )

        // Exactly ONE copyObject; no putObject / getObject leaked through.
        XCTAssertEqual(mock.copyObjectCallCount, 1, "Expected exactly 1 copyObject call")
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("putObject") }),
            "copyThumbnail must not issue any putObject — server-side copy only"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObject") }),
            "copyThumbnail must not issue any getObject — server-side copy only"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("putObjectData") }),
            "copyThumbnail must not issue any putObjectData — server-side copy only"
        )
        XCTAssertFalse(
            mock.calls.contains(where: { $0.hasPrefix("getObjectData") }),
            "copyThumbnail must not issue any getObjectData — server-side copy only"
        )

        // The four args reach copyObject.
        XCTAssertEqual(mock.lastCopyObjectBucket, "b")
        XCTAssertEqual(mock.lastCopyObjectSourceKey, "src/.thumbnails/a.jpg.jpg")
        XCTAssertEqual(mock.lastCopyObjectDestinationKey, "src/.thumbnails/b.jpg.jpg")
    }

    // MARK: - Test 2: metadata-nil contract (preserves source metadata)

    func testCopyThumbnailPassesNilMetadataForDirectiveCopy() async throws {
        let mock = makeMock()

        try await mock.copyThumbnail(
            bucket: "b",
            fromKey: "p/.thumbnails/x.jpg",
            toKey: "p/.thumbnails/y.jpg"
        )

        XCTAssertTrue(
            mock.lastCopyObjectMetadataWasSet,
            "copyObject must have been invoked"
        )
        // Threat T-13-12 pin: any future drift to non-nil metadata flips this red.
        // metadata: nil → Soto omits x-amz-metadata-directive → AWS default = COPY
        // → preserves x-amz-meta-source-etag and x-amz-meta-ds3drive-thumb-version.
        XCTAssertNil(
            mock.lastCopyObjectMetadata,
            "copyThumbnail must pass metadata: nil to preserve source metadata via AWS default COPY directive"
        )
    }

    // MARK: - Test 3: NoSuchKey rethrow

    func testCopyThumbnailRethrowsNoSuchKey() async {
        let mock = makeMock()
        mock.copyObjectError = notFoundError

        do {
            try await mock.copyThumbnail(
                bucket: "b",
                fromKey: "src/.thumbnails/missing.jpg",
                toKey: "src/.thumbnails/dest.jpg"
            )
            XCTFail("Expected copyThumbnail to rethrow NoSuchKey")
        } catch {
            // Caller (Plan 13-08 rename cascade) inspects the error and maps to
            // .pending fallback. copyThumbnail's contract: rethrow as-is.
            XCTAssertTrue(
                DS3S3Client.isNotFoundError(error),
                "Expected the rethrown error to be detectable as 'not found' for caller fallback"
            )
        }
    }

    // MARK: - Test 4: 5xx / server-error rethrow

    func testCopyThumbnailRethrowsServerError() async {
        let mock = makeMock()
        // Any non-404 error simulates a 5xx / transient server failure path.
        mock.copyObjectError = DS3ClientError.parseError

        do {
            try await mock.copyThumbnail(
                bucket: "b",
                fromKey: "src/.thumbnails/x.jpg",
                toKey: "src/.thumbnails/y.jpg"
            )
            XCTFail("Expected copyThumbnail to rethrow server error")
        } catch {
            XCTAssertTrue(
                error is DS3ClientError,
                "Should rethrow original error type so caller can branch"
            )
        }
    }

    // MARK: - Test 5: keys passthrough byte-for-byte

    func testCopyThumbnailKeyArgsArePassedThrough() async throws {
        let mock = makeMock()

        // Keys that exercise spaces and special chars — the suffix `.jpg.jpg`
        // matches Phase 12's <originalKey>.jpg convention. Percent-encoding is
        // copyObject's responsibility (Pitfall 6); copyThumbnail must NOT munge.
        let from = "drive 1/.thumbnails/folder a/photo+v2.heic.jpg"
        let to = "drive 1/.thumbnails/folder b/photo+v2.heic.jpg"

        try await mock.copyThumbnail(bucket: "bkt", fromKey: from, toKey: to)

        XCTAssertEqual(
            mock.lastCopyObjectSourceKey, from,
            "fromKey must reach copyObject as sourceKey byte-for-byte"
        )
        XCTAssertEqual(
            mock.lastCopyObjectDestinationKey, to,
            "toKey must reach copyObject as destinationKey byte-for-byte"
        )
        XCTAssertEqual(mock.lastCopyObjectBucket, "bkt")
    }
}
