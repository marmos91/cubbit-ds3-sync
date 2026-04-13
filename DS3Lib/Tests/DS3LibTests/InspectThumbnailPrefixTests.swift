import XCTest
@testable import DS3Lib

final class InspectThumbnailPrefixTests: XCTestCase {

    // MARK: - Helpers

    private func makeMock(objects: [S3ObjectSummary] = []) -> MockDS3S3Client {
        let mock = MockDS3S3Client()
        mock.listObjectsResult = S3ListingResult(
            objects: objects,
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )
        return mock
    }

    private func makeObject(key: String) -> S3ObjectSummary {
        S3ObjectSummary(key: key, etag: nil, lastModified: nil, size: 0)
    }

    // MARK: - Tests

    func testInspectThumbnailPrefixEmpty() async throws {
        let mock = makeMock(objects: [])
        let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(result, .empty)
    }

    func testInspectThumbnailPrefixMatchesOurs() async throws {
        let objects = [
            makeObject(key: "drive/.thumbnails/a.heic.jpg"),
            makeObject(key: "drive/.thumbnails/b.png.jpg"),
            makeObject(key: "drive/.thumbnails/c.jpeg.jpg"),
            makeObject(key: "drive/.thumbnails/d.webp.jpg"),
            makeObject(key: "drive/.thumbnails/e.gif.jpg"),
        ]
        let mock = makeMock(objects: objects)
        let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(result, .matchesOurs)
    }

    func testInspectThumbnailPrefixConflictingNonJpgSuffix() async throws {
        let objects = [
            makeObject(key: "drive/.thumbnails/a.heic.png"),
        ]
        let mock = makeMock(objects: objects)
        let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(result, .conflicting(sampleKey: "drive/.thumbnails/a.heic.png"))
    }

    func testInspectThumbnailPrefixConflictingNonRasterOriginal() async throws {
        let objects = [
            makeObject(key: "drive/.thumbnails/document.pdf.jpg"),
        ]
        let mock = makeMock(objects: objects)
        let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(result, .conflicting(sampleKey: "drive/.thumbnails/document.pdf.jpg"))
    }

    func testInspectThumbnailPrefixMixedValidAndInvalid() async throws {
        var objects: [S3ObjectSummary] = (1...9).map { i in
            makeObject(key: "drive/.thumbnails/photo\(i).png.jpg")
        }
        objects.append(makeObject(key: "drive/.thumbnails/readme.txt.jpg"))
        let mock = makeMock(objects: objects)
        let result = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(result, .conflicting(sampleKey: "drive/.thumbnails/readme.txt.jpg"))
    }

    func testInspectThumbnailPrefixUsesMaxKeys10() async throws {
        let mock = makeMock(objects: [])
        _ = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(mock.lastListObjectsMaxKeys, 10)
    }

    func testInspectThumbnailPrefixPassesCorrectPrefix() async throws {
        let mock = makeMock(objects: [])
        _ = try await mock.inspectThumbnailPrefix(bucket: "test", prefix: "drive/")
        XCTAssertEqual(mock.lastListObjectsPrefix, "drive/.thumbnails/")
    }
}
