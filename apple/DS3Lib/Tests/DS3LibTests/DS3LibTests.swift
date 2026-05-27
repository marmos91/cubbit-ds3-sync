import XCTest
@testable import DS3Lib

final class DS3LibTests: XCTestCase {
    func testAppStatusToString() {
        XCTAssertEqual(AppStatus.idle.toString(), "Idle")
        XCTAssertEqual(AppStatus.syncing.toString(), "Synchronizing")
        XCTAssertEqual(AppStatus.error.toString(), "Error")
        XCTAssertEqual(AppStatus.offline.toString(), "Offline")
        XCTAssertEqual(AppStatus.info.toString(), "Info")
    }

    func testSyncStatusRawValues() {
        XCTAssertEqual(SyncStatus.pending.rawValue, "pending")
        XCTAssertEqual(SyncStatus.syncing.rawValue, "syncing")
        XCTAssertEqual(SyncStatus.synced.rawValue, "synced")
        XCTAssertEqual(SyncStatus.error.rawValue, "error")
        XCTAssertEqual(SyncStatus.conflict.rawValue, "conflict")
    }

    func testSyncStatusFromRawValue() {
        XCTAssertEqual(SyncStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(SyncStatus(rawValue: "synced"), .synced)
        XCTAssertNil(SyncStatus(rawValue: "invalid"))
    }
}
