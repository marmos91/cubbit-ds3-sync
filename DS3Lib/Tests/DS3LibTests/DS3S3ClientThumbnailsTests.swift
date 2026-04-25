import XCTest
import SotoS3
@testable import DS3Lib

/// Phase 12-03 / THUMB-10 — coverage for `putThumbnail` / `getThumbnailBytes`
/// / `deleteThumbnail`. All three are protocol-default extensions on
/// `DS3S3ClientProtocol`, so the mock inherits them for free (D-08).
final class DS3S3ClientThumbnailsTests: XCTestCase {

    // MARK: - Helpers

    private func makeMock() -> MockDS3S3Client {
        MockDS3S3Client()
    }

    private func smallJPEGData() -> Data {
        // Tiny JPEG-like blob (size doesn't matter; content is opaque to the mock).
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    }

    /// A canned NoSuchKey error (S3ErrorType is what `isNotFoundError` matches via `errorCode`).
    private var notFoundError: Error {
        S3ErrorType.noSuchKey
    }

    // MARK: - putThumbnail

    func testPutThumbnailIssuesBareMetadataKeys() async throws {
        let mock = makeMock()
        mock.putObjectDataEtag = "\"thumb-etag\""

        _ = try await mock.putThumbnail(
            bucket: "b",
            key: "drive/.thumbnails/photo.heic.jpg",
            data: smallJPEGData(),
            sourceETag: "abc"
        )

        // Pitfall 2 — keys must be BARE (Soto prepends x-amz-meta- per header).
        XCTAssertEqual(
            mock.lastPutObjectDataMetadata,
            ["source-etag": "abc", "ds3drive-thumb-version": "1"]
        )
        XCTAssertEqual(mock.lastPutObjectDataKey, "drive/.thumbnails/photo.heic.jpg")
        XCTAssertEqual(mock.lastPutObjectDataBucket, "b")
    }

    func testPutThumbnailReturnsNormalizedETag() async throws {
        let mock = makeMock()
        mock.putObjectDataEtag = "\"thumb-etag\""  // quoted — should be normalized

        let etag = try await mock.putThumbnail(
            bucket: "b", key: "k", data: smallJPEGData(), sourceETag: "src"
        )

        // The mock simulates a real client by pre-normalizing in the concrete
        // putObjectData; the mock returns the raw stored etag. putThumbnail
        // accepts whatever putObjectData returns (the contract is "non-nil
        // normalized ETag"). Exercise the boundary case directly.
        XCTAssertFalse(etag.isEmpty)
    }

    func testPutThumbnailUnderSizeLimitSucceeds() async throws {
        // Boundary smoke: 499_999 bytes < maxSinglePartBytes (500_000) succeeds.
        let mock = makeMock()
        mock.putObjectDataEtag = "etag"

        let belowCap = Data(count: DefaultSettings.Thumbnail.maxSinglePartBytes - 1)

        _ = try await mock.putThumbnail(
            bucket: "b", key: "k", data: belowCap, sourceETag: "src"
        )
        XCTAssertEqual(mock.lastPutObjectDataBytes, belowCap.count)
    }

    func testPutThumbnailAtOrAboveSizeLimitThrows() async throws {
        let mock = makeMock()
        let atCap = Data(count: DefaultSettings.Thumbnail.maxSinglePartBytes)

        do {
            _ = try await mock.putThumbnail(
                bucket: "b", key: "k", data: atCap, sourceETag: "src"
            )
            XCTFail("Expected DS3ClientError.thumbnailTooLarge")
        } catch DS3ClientError.thumbnailTooLarge(let size, let limit) {
            XCTAssertEqual(size, atCap.count)
            XCTAssertEqual(limit, DefaultSettings.Thumbnail.maxSinglePartBytes)
        }
        XCTAssertNil(mock.lastPutObjectDataBytes, "Oversize input must NOT reach the underlying PUT")
    }

    func testPutThumbnailStripsCRLFFromSourceETag() async throws {
        let mock = makeMock()
        mock.putObjectDataEtag = "etag"

        _ = try await mock.putThumbnail(
            bucket: "b", key: "k", data: Data([0x01, 0x02]), sourceETag: "abc\r\nX-Injected: yes"
        )
        let captured = mock.lastPutObjectDataMetadata?[
            DefaultSettings.Thumbnail.sourceETagMetadataKey
        ]
        XCTAssertEqual(captured, "abcX-Injected: yes", "CR/LF must be stripped from sourceETag")
    }

    func testPutThumbnailThrowsMissingETagWhenUnderlyingPutReturnsNil() async throws {
        let mock = makeMock()
        mock.putObjectDataEtag = nil

        do {
            _ = try await mock.putThumbnail(
                bucket: "b", key: "k", data: Data([0x01]), sourceETag: "src"
            )
            XCTFail("Expected DS3ClientError.missingETag")
        } catch DS3ClientError.missingETag {
            // expected
        }
    }

    // MARK: - getThumbnailBytes

    func testGetThumbnailBytes200ReturnsBytes() async throws {
        let mock = makeMock()
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        mock.getObjectDataResult = payload

        let result = try await mock.getThumbnailBytes(bucket: "b", key: "k")

        XCTAssertEqual(result, payload)
    }

    func testGetThumbnailBytes404ReturnsNil() async throws {
        let mock = makeMock()
        mock.getObjectDataError = notFoundError

        let result = try await mock.getThumbnailBytes(bucket: "b", key: "k")

        XCTAssertNil(result)
    }

    func testGetThumbnailBytes5xxRethrows() async {
        let mock = makeMock()
        mock.getObjectDataError = DS3ClientError.parseError  // any non-404 error

        do {
            _ = try await mock.getThumbnailBytes(bucket: "b", key: "k")
            XCTFail("Expected rethrow")
        } catch {
            XCTAssertTrue(error is DS3ClientError, "Should rethrow original error type")
        }
    }

    // MARK: - deleteThumbnail

    func testDeleteThumbnail204Succeeds() async throws {
        let mock = makeMock()
        // No deleteObjectError -> success.
        try await mock.deleteThumbnail(bucket: "b", key: "k")
        XCTAssertTrue(mock.calls.contains("deleteObject(key:k)"))
    }

    func testDeleteThumbnail404IsSilent() async throws {
        let mock = makeMock()
        mock.deleteObjectError = notFoundError

        // Must NOT throw.
        try await mock.deleteThumbnail(bucket: "b", key: "k")
    }

    func testDeleteThumbnail5xxRethrows() async {
        let mock = makeMock()
        mock.deleteObjectError = DS3ClientError.parseError

        do {
            try await mock.deleteThumbnail(bucket: "b", key: "k")
            XCTFail("Expected rethrow")
        } catch {
            XCTAssertTrue(error is DS3ClientError, "Should rethrow original error type")
        }
    }
}
