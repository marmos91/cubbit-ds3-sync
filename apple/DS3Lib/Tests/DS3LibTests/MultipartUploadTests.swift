import XCTest
@testable import DS3Lib

/// Tests for multipart upload logic: part splitting, boundary conditions, and edge cases.
final class MultipartUploadTests: XCTestCase {
    // MARK: - Part Splitting

    func testPartSplittingSmallFile() {
        // A file smaller than the part size should produce 1 part
        let fileSize = 1024 // 1 KB
        let partSize = DefaultSettings.S3.multipartUploadPartSize // 5 MB

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].partNumber, 1)
        XCTAssertEqual(parts[0].offset, 0)
        XCTAssertEqual(parts[0].length, 1024)
    }

    func testPartSplittingExactly5MB() {
        // File exactly at the multipart threshold
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = partSize // exactly 5 MB

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].length, partSize)
    }

    func testPartSplitting5MBPlus1Byte() {
        // File just over the threshold — should produce 2 parts
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = partSize + 1

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].length, partSize)
        XCTAssertEqual(parts[1].partNumber, 2)
        XCTAssertEqual(parts[1].offset, partSize)
        XCTAssertEqual(parts[1].length, 1)
    }

    func testPartSplittingExactMultiple() {
        // File exactly 3 * part size
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = partSize * 3

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        XCTAssertEqual(parts.count, 3)
        for (i, part) in parts.enumerated() {
            XCTAssertEqual(part.partNumber, i + 1)
            XCTAssertEqual(part.offset, i * partSize)
            XCTAssertEqual(part.length, partSize)
        }
    }

    func testPartSplittingLargeFile() {
        // 27 MB file (5 full parts + 2 MB remainder)
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = 27 * 1024 * 1024

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        XCTAssertEqual(parts.count, 6)
        // First 5 parts are full size
        for i in 0 ..< 5 {
            XCTAssertEqual(parts[i].length, partSize)
        }
        // Last part is remainder
        XCTAssertEqual(parts[5].length, 2 * 1024 * 1024)
    }

    // MARK: - Part Numbering

    func testPartNumbersAreSequential() {
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = partSize * 10 + 100

        let parts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        for (i, part) in parts.enumerated() {
            XCTAssertEqual(part.partNumber, i + 1, "Part numbers should be 1-indexed and sequential")
        }
    }

    // MARK: - Completed Parts

    func testCompletedPartResult() {
        let part = CompletedPartResult(partNumber: 3, etag: "\"abc123\"")
        XCTAssertEqual(part.partNumber, 3)
        XCTAssertEqual(part.etag, "\"abc123\"")
    }

    func testMultipartCompleteResult() {
        let result = MultipartCompleteResult(etag: "\"finaletag\"")
        XCTAssertEqual(result.etag, "\"finaletag\"")
    }

    // MARK: - Multipart Context

    func testMultipartUploadContext() {
        let context = MultipartUploadContext(
            bucket: "test-bucket",
            key: "large-file.zip",
            uploadId: "upload-123",
            totalSize: 50 * 1024 * 1024
        )
        XCTAssertEqual(context.bucket, "test-bucket")
        XCTAssertEqual(context.key, "large-file.zip")
        XCTAssertEqual(context.uploadId, "upload-123")
        XCTAssertEqual(context.totalSize, 52_428_800)
    }

    // MARK: - Filtering Already Completed Parts

    func testFilteringCompletedParts() {
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileSize = partSize * 5

        let allParts = stride(from: 0, to: fileSize, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSize - offset))
        }

        // Simulate parts 1 and 3 already completed
        let completedPartNumbers: Set<Int> = [1, 3]
        let remainingParts = allParts.filter { !completedPartNumbers.contains($0.partNumber) }

        XCTAssertEqual(remainingParts.count, 3)
        XCTAssertEqual(remainingParts.map(\.partNumber), [2, 4, 5])
    }

    // MARK: - Constants

    func testMultipartConstants() {
        XCTAssertEqual(DefaultSettings.S3.multipartUploadPartSize, 5 * 1024 * 1024)
        XCTAssertEqual(DefaultSettings.S3.multipartThreshold, 5 * 1024 * 1024)
        XCTAssertEqual(DefaultSettings.S3.multipartUploadConcurrency, 4)
    }

    // MARK: - DS3ClientError

    func testDS3ClientErrors() {
        let errors: [DS3ClientError] = [
            .missingUploadId, .emptyFileData, .missingETag, .parseError, .unableToOpenFile
        ]
        for error in errors {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - ReadFilePart

    func testReadFilePartFromValidFile() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).bin")
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try DS3S3Client.readFilePart(at: tempFile, offset: 0, length: 512)
        XCTAssertEqual(chunk.count, 512)
        XCTAssertTrue(chunk.allSatisfy { $0 == 0xAB })
    }

    func testReadFilePartWithOffset() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).bin")
        var data = Data(repeating: 0x00, count: 512)
        data.append(Data(repeating: 0xFF, count: 512))
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let chunk = try DS3S3Client.readFilePart(at: tempFile, offset: 512, length: 256)
        XCTAssertEqual(chunk.count, 256)
        XCTAssertTrue(chunk.allSatisfy { $0 == 0xFF })
    }

    // MARK: - S3 Key Decoding

    func testDecodeS3KeyWithSpaces() throws {
        let encoded = "folder/my+file+name.txt"
        let decoded = try DS3S3Client.decodeS3Key(encoded)
        XCTAssertEqual(decoded, "folder/my file name.txt")
    }

    func testDecodeS3KeyWithPercentEncoding() throws {
        let encoded = "folder/my%20file%20name.txt"
        let decoded = try DS3S3Client.decodeS3Key(encoded)
        XCTAssertEqual(decoded, "folder/my file name.txt")
    }

    func testDecodeS3KeyWithLiteralPlus() throws {
        // A literal + in S3 is returned as %2B when URL encoding is on
        let encoded = "folder/a%2Bb.txt"
        let decoded = try DS3S3Client.decodeS3Key(encoded)
        XCTAssertEqual(decoded, "folder/a+b.txt")
    }

    func testDecodeS3KeyPlainKey() throws {
        let encoded = "folder/simple.txt"
        let decoded = try DS3S3Client.decodeS3Key(encoded)
        XCTAssertEqual(decoded, "folder/simple.txt")
    }
}
