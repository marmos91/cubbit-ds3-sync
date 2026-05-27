import XCTest
import NIOCore
import os.log
@testable import DS3Lib

/// Tests for streaming I/O patterns used in S3Lib (IEXT-03).
/// Verifies zero-copy ByteBuffer writes, chunked FileHandle reads,
/// and MemoryLogger smoke test.
final class StreamingIOTests: XCTestCase {

    func testByteBufferZeroCopyWrite() throws {
        // Create a ByteBuffer with known data
        let testData = Data(repeating: 0xAB, count: 1024)
        var buffer = ByteBuffer(bytes: testData)

        // Write using zero-copy pattern (same as S3Lib fix)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
        }

        buffer.withUnsafeReadableBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                count: bufferPointer.count,
                deallocator: .none
            )
            fileHandle.write(data)
        }

        try fileHandle.close()

        // Verify
        let written = try Data(contentsOf: tempURL)
        XCTAssertEqual(written, testData)
        XCTAssertEqual(written.count, 1024)
    }

    func testFileHandleChunkedRead() throws {
        // Create a file with known content larger than one chunk
        let size = 200_000 // ~200KB, requires multiple 64KB chunks
        let testData = Data((0..<size).map { UInt8($0 % 256) })

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let chunkSize = 65_536
        var reassembled = Data()

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            reassembled.append(chunk)
        }

        XCTAssertEqual(reassembled, testData)
        XCTAssertEqual(reassembled.count, size)
    }

    func testMemoryLoggerDoesNotCrash() {
        // Smoke test: logMemoryUsage should complete without crashing
        let logger = Logger(subsystem: "test", category: "memory")
        logMemoryUsage(label: "test-checkpoint", logger: logger)
        // If we reach here, it didn't crash
    }
}
