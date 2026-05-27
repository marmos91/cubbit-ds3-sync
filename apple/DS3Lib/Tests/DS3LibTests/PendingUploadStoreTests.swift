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

    // MARK: - isCompleting flag

    func test_legacyDecode_missingIsCompleting_decodesAsFalse() async throws {
        // JSON without `isCompleting` field — must decode to false.
        let driveId = testDriveId
        let legacyJSON = """
        {"uploads":{"k8/file.jpg":{"uploadId":"u8","bucket":"b","key":"k8/file.jpg","driveId":"\(driveId.uuidString)","completedPartETags":{},"expectedPartCount":2}},"partRecords":{}}
        """.data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try legacyJSON.write(to: tempURL)
        let storeFromDisk = PendingUploadStore(fileURL: tempURL)
        let upload = await storeFromDisk.pendingUpload(forKey: "k8/file.jpg")
        XCTAssertNotNil(upload)
        XCTAssertEqual(upload?.isCompleting, false, "Missing isCompleting must default to false")
    }

    func test_markCompleting_isIdempotent_andPersisted() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = PendingUploadStore(fileURL: tempURL)
        await store.register(
            uploadId: "u9", bucket: "b", key: "k9/file.jpg",
            driveId: testDriveId, expectedPartCount: 1
        )

        // First call sets the flag → returns true.
        let first = await store.markCompleting(forKey: "k9/file.jpg")
        XCTAssertTrue(first, "First markCompleting must return true")

        // Second call sees flag already set → returns false (idempotent).
        let second = await store.markCompleting(forKey: "k9/file.jpg")
        XCTAssertFalse(second, "Second markCompleting must return false")

        // Persisted: a fresh store loaded from the same URL must see isCompleting=true.
        let reloaded = PendingUploadStore(fileURL: tempURL)
        let upload = await reloaded.pendingUpload(forKey: "k9/file.jpg")
        XCTAssertEqual(upload?.isCompleting, true, "isCompleting must be persisted to disk")

        // clearCompleting flips it back and is also persisted.
        await store.clearCompleting(forKey: "k9/file.jpg")
        let reloaded2 = PendingUploadStore(fileURL: tempURL)
        let upload2 = await reloaded2.pendingUpload(forKey: "k9/file.jpg")
        XCTAssertEqual(upload2?.isCompleting, false, "clearCompleting must be persisted")
    }

    // MARK: - markPartFailed

    func test_markPartFailed_removesRecord_andDeletesTempFile() async throws {
        // Create a real temp file backing the part record.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try Data("payload".utf8).write(to: tempFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        await store.register(
            uploadId: "u10", bucket: "b", key: "k10/file.jpg",
            driveId: testDriveId, expectedPartCount: 2
        )
        await store.recordPartTask(
            forKey: "k10/file.jpg", partNumber: 1,
            taskIdentifier: 1000, tempFileURL: tempFile
        )

        // Sanity: record present.
        let before = await store.partRecord(forTaskIdentifier: 1000)
        XCTAssertNotNil(before)

        await store.markPartFailed(taskIdentifier: 1000)

        // Record gone, temp file deleted.
        let after = await store.partRecord(forTaskIdentifier: 1000)
        XCTAssertNil(after, "Part record must be removed after markPartFailed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempFile.path),
            "Temp chunk file must be deleted"
        )

        // markPartFailed for an unknown taskId is a no-op (must not crash).
        await store.markPartFailed(taskIdentifier: 9999)
    }

    // MARK: - partRecords(forKey:)

    func test_partRecordsForKey_returnsOnlyMatchingKey() async throws {
        await store.register(
            uploadId: "u11a", bucket: "b", key: "k11a",
            driveId: testDriveId, expectedPartCount: 2
        )
        await store.register(
            uploadId: "u11b", bucket: "b", key: "k11b",
            driveId: testDriveId, expectedPartCount: 1
        )
        await store.recordPartTask(
            forKey: "k11a", partNumber: 1, taskIdentifier: 1101,
            tempFileURL: URL(fileURLWithPath: "/tmp/a1.bin")
        )
        await store.recordPartTask(
            forKey: "k11a", partNumber: 2, taskIdentifier: 1102,
            tempFileURL: URL(fileURLWithPath: "/tmp/a2.bin")
        )
        await store.recordPartTask(
            forKey: "k11b", partNumber: 1, taskIdentifier: 1103,
            tempFileURL: URL(fileURLWithPath: "/tmp/b1.bin")
        )

        let aRecords = await store.partRecords(forKey: "k11a")
        XCTAssertEqual(aRecords.count, 2)
        XCTAssertEqual(Set(aRecords.map(\.taskIdentifier)), Set([1101, 1102]))

        let bRecords = await store.partRecords(forKey: "k11b")
        XCTAssertEqual(bRecords.count, 1)
        XCTAssertEqual(bRecords.first?.taskIdentifier, 1103)
    }
}
