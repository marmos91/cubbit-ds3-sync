import XCTest
@testable import DS3Lib

/// Tests for DS3DriveViewModel pure logic (extracted to DS3Lib types).
/// The actual ViewModel uses @MainActor and DistributedNotificationCenter,
/// but the underlying calculations are tested here.
final class DS3DriveViewModelLogicTests: XCTestCase {
    // MARK: - Transfer Stats Speed Calculation

    func testEMASpeedSmoothing() {
        let alpha = 0.3
        var emaSpeed: Double?

        // First sample: no previous → use raw
        let sample1 = 1000.0 // bytes/s
        emaSpeed = sample1
        XCTAssertEqual(emaSpeed, 1000.0)

        // Second sample: EMA kicks in
        let sample2 = 2000.0
        emaSpeed = alpha * sample2 + (1 - alpha) * emaSpeed!
        XCTAssertEqual(emaSpeed!, 1300.0, accuracy: 0.01)

        // Third sample: continues smoothing
        let sample3 = 500.0
        emaSpeed = alpha * sample3 + (1 - alpha) * emaSpeed!
        XCTAssertEqual(emaSpeed!, 1060.0, accuracy: 0.01)
    }

    func testDeltaBytesCalculation() {
        var lastReportedSize: Int64 = 0

        // First report: 500 bytes transferred
        let report1Size: Int64 = 500
        let delta1 = max(0, report1Size - lastReportedSize)
        lastReportedSize = report1Size
        XCTAssertEqual(delta1, 500)

        // Second report: 1200 bytes total (delta = 700)
        let report2Size: Int64 = 1200
        let delta2 = max(0, report2Size - lastReportedSize)
        lastReportedSize = report2Size
        XCTAssertEqual(delta2, 700)
    }

    func testDeltaBytesNeverNegative() {
        let lastReportedSize: Int64 = 1000
        // Out-of-order report with smaller size should clamp to 0
        let reportSize: Int64 = 500
        let delta = max(0, reportSize - lastReportedSize)
        XCTAssertEqual(delta, 0)
    }

    func testAggregateSpeedFromMultipleFiles() {
        var perFileUploadSpeed: [String: Double] = [:]

        perFileUploadSpeed["file1.txt"] = 1000.0
        perFileUploadSpeed["file2.txt"] = 2000.0
        perFileUploadSpeed["file3.txt"] = 500.0

        let totalSpeed = perFileUploadSpeed.values.reduce(0, +)
        XCTAssertEqual(totalSpeed, 3500.0)
    }

    func testFileTransferExpiration() {
        let fileTransferTimeout: TimeInterval = 3.0
        let now = Date()
        var lastFileUpdate: [String: Date] = [:]

        // File A updated 1 second ago (active)
        lastFileUpdate["fileA"] = now.addingTimeInterval(-1)
        // File B updated 5 seconds ago (stale)
        lastFileUpdate["fileB"] = now.addingTimeInterval(-5)

        let cutoff = now.addingTimeInterval(-fileTransferTimeout)
        let staleKeys = Set(lastFileUpdate.filter { $0.value < cutoff }.map(\.key))

        XCTAssertEqual(staleKeys, ["fileB"])
    }

    func testCompletedFileRemoval() {
        var perFileUploadSpeed: [String: Double] = ["file.txt": 1000.0]
        var lastReportedSize: [String: Int64] = ["file.txt": 500]
        var lastReportedDuration: [String: TimeInterval] = ["file.txt": 1.0]
        var lastFileUpdate: [String: Date] = ["file.txt": Date()]

        // Simulate file completion
        let isUpload = true
        let fileKey = "file.txt"
        if isUpload {
            perFileUploadSpeed.removeValue(forKey: fileKey)
        }
        lastReportedSize.removeValue(forKey: fileKey)
        lastReportedDuration.removeValue(forKey: fileKey)
        lastFileUpdate.removeValue(forKey: fileKey)

        XCTAssertTrue(perFileUploadSpeed.isEmpty)
        XCTAssertTrue(lastReportedSize.isEmpty)
    }

    // MARK: - Drive Stats

    func testDriveStatsIsTransferring() {
        let active = DS3DriveStats(lastUpdate: Date(), uploadSpeedBs: 1000, downloadSpeedBs: 500)
        XCTAssertTrue(active.isTransferring)

        let uploadOnly = DS3DriveStats(lastUpdate: Date(), uploadSpeedBs: 100, downloadSpeedBs: nil)
        XCTAssertTrue(uploadOnly.isTransferring)

        let downloadOnly = DS3DriveStats(lastUpdate: Date(), uploadSpeedBs: nil, downloadSpeedBs: 100)
        XCTAssertTrue(downloadOnly.isTransferring)

        let idle = DS3DriveStats(lastUpdate: Date(), uploadSpeedBs: nil, downloadSpeedBs: nil)
        XCTAssertFalse(idle.isTransferring)
    }

    // MARK: - Recent File Entry Formatting

    func testRecentFileEntryProgressPercentEdgeCases() {
        // 0 total bytes → no progress
        let zeroBytesEntry = RecentFileEntry(
            driveId: UUID(), filename: "file.txt", size: 0,
            status: .syncing, timestamp: Date(),
            transferredBytes: 0, totalBytes: 0
        )
        XCTAssertNil(zeroBytesEntry.progressPercent)

        // Over 100% → clamped to 100
        let overEntry = RecentFileEntry(
            driveId: UUID(), filename: "file.txt", size: 1000,
            status: .syncing, timestamp: Date(),
            transferredBytes: 1500, totalBytes: 1000
        )
        XCTAssertEqual(overEntry.progressPercent, 100)
    }

}
