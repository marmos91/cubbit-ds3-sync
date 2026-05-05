import XCTest
@testable import DS3Lib

final class PendingUploadStoreBackgroundTests: XCTestCase {
    var store: PendingUploadStore!
    let testDriveId = UUID()

    override func setUp() async throws {
        // Use a temp URL so tests don't pollute App Group storage
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        store = PendingUploadStore(fileURL: tempURL)
    }

    func test_recordPartTask_andRetrieveByTaskId() async throws {
        await store.register(
            uploadId: "u1", bucket: "b", key: "k/file.jpg",
            driveId: testDriveId, expectedPartCount: 2
        )
        await store.recordPartTask(
            forKey: "k/file.jpg", partNumber: 1,
            taskIdentifier: 42, tempFileURL: URL(fileURLWithPath: "/tmp/p1.bin")
        )
        let record = await store.partRecord(forTaskIdentifier: 42)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.partNumber, 1)
        XCTAssertEqual(record?.uploadId, "u1")
    }

    func test_markPartCompleted_persistsETag() async throws {
        await store.register(
            uploadId: "u2", bucket: "b", key: "k2/file.jpg",
            driveId: testDriveId, expectedPartCount: 1
        )
        await store.recordPartTask(
            forKey: "k2/file.jpg", partNumber: 1,
            taskIdentifier: 100, tempFileURL: URL(fileURLWithPath: "/tmp/p1.bin")
        )
        await store.markPartCompleted(taskIdentifier: 100, etag: "abc-123")
        let upload = await store.pendingUpload(forKey: "k2/file.jpg")
        XCTAssertEqual(upload?.completedPartETags[1], "abc-123")
    }

    func test_allPartsComplete_trueWhenAllReceived() async throws {
        await store.register(
            uploadId: "u3", bucket: "b", key: "k3/file.jpg",
            driveId: testDriveId, expectedPartCount: 3
        )
        for i in 1...3 {
            await store.recordPartTask(
                forKey: "k3/file.jpg", partNumber: i,
                taskIdentifier: i + 200, tempFileURL: URL(fileURLWithPath: "/tmp/\(i).bin")
            )
        }
        let before = await store.allPartsComplete(forKey: "k3/file.jpg")
        XCTAssertFalse(before)
        for i in 1...3 {
            await store.markPartCompleted(taskIdentifier: i + 200, etag: "etag-\(i)")
        }
        let after = await store.allPartsComplete(forKey: "k3/file.jpg")
        XCTAssertTrue(after)
    }

    func test_legacyDecode_missingExpectedPartCount_decodesCleanly() async throws {
        // Simulates a PendingUpload JSON from before expectedPartCount was added
        // It should decode with expectedPartCount == 0 or similar sentinel
        let driveId = testDriveId
        let legacyJSON = """
        {"uploads":{"k4/file.jpg":{"uploadId":"u4","bucket":"b","key":"k4/file.jpg","driveId":"\(driveId.uuidString)","completedPartETags":{}}},"partRecords":{}}
        """.data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try legacyJSON.write(to: tempURL)
        let storeFromDisk = PendingUploadStore(fileURL: tempURL)
        let upload = await storeFromDisk.pendingUpload(forKey: "k4/file.jpg")
        XCTAssertNotNil(upload, "Legacy upload should decode without error")
        XCTAssertEqual(upload?.uploadId, "u4")
    }

    func test_legacyFlatFormat_decodes() async throws {
        // The pre-wrapper on-disk format was a flat [String: PendingUpload] dict.
        // Existing on-disk state must still be readable.
        let driveId = testDriveId
        let legacyFlatJSON = """
        {"k5/file.jpg":{"uploadId":"u5","bucket":"b","key":"k5/file.jpg","driveId":"\(driveId.uuidString)","completedPartETags":{},"createdAt":700000000}}
        """.data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try legacyFlatJSON.write(to: tempURL)
        let storeFromDisk = PendingUploadStore(fileURL: tempURL)
        let upload = await storeFromDisk.pendingUpload(forKey: "k5/file.jpg")
        XCTAssertNotNil(upload, "Pre-wrapper flat format must still decode")
        XCTAssertEqual(upload?.uploadId, "u5")
        XCTAssertEqual(upload?.expectedPartCount, 0, "Missing field defaults to 0")
    }

    func test_allPendingPartRecords_returnsAll() async throws {
        await store.register(
            uploadId: "u6", bucket: "b", key: "k6/file.jpg",
            driveId: testDriveId, expectedPartCount: 2
        )
        await store.recordPartTask(
            forKey: "k6/file.jpg", partNumber: 1,
            taskIdentifier: 600, tempFileURL: URL(fileURLWithPath: "/tmp/p1.bin")
        )
        await store.recordPartTask(
            forKey: "k6/file.jpg", partNumber: 2,
            taskIdentifier: 601, tempFileURL: URL(fileURLWithPath: "/tmp/p2.bin")
        )
        let all = await store.allPendingPartRecords()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map { $0.taskIdentifier }), Set([600, 601]))
    }

    func test_allKnownUploadIds_returnsAll() async throws {
        await store.register(
            uploadId: "u7a", bucket: "b", key: "k7a", driveId: testDriveId, expectedPartCount: 1
        )
        await store.register(
            uploadId: "u7b", bucket: "b", key: "k7b", driveId: testDriveId, expectedPartCount: 1
        )
        let ids = await store.allKnownUploadIds()
        XCTAssertEqual(ids, Set(["u7a", "u7b"]))
    }
}
