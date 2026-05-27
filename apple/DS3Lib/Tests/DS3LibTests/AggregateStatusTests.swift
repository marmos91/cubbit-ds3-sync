import XCTest
@testable import DS3Lib

/// Exhaustive tests for the tray aggregate status reducer (Gaps 15 + 27).
///
/// These tests are the regression net that proves the header, footer, drive
/// rows, and menu bar icon are driven by a single deterministic function —
/// any future change to `AggregateStatus.from(statuses:)` must keep them
/// green.
final class AggregateStatusTests: XCTestCase {
    // MARK: - Empty set

    func testEmptyDrivesYieldsNoDrives() {
        XCTAssertEqual(AggregateStatus.from(statuses: []), .noDrives)
    }

    // MARK: - All idle

    func testAllIdleSingleDrive() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.idle]), .allIdle)
    }

    func testAllIdleMultipleDrives() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.idle, .idle, .idle]), .allIdle)
    }

    // MARK: - Syncing

    func testSyncingWinsOverIdle() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.idle, .sync]), .syncing)
    }

    // MARK: - Error

    func testAllErrorIncludesCount() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.error, .error]), .error(count: 2))
    }

    func testSingleError() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.error]), .error(count: 1))
    }

    /// Mixed error + healthy state → `.mixed` (error coexists with running
    /// drive). The footer should still surface the error, but the value is
    /// distinct so the UI can render "1 drive error, 1 syncing" if needed.
    func testErrorPlusIdleIsMixed() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.idle, .error]), .mixed)
    }

    func testErrorPlusSyncIsMixed() {
        XCTAssertEqual(AggregateStatus.from(statuses: [.sync, .error]), .mixed)
    }

    // MARK: - AppStatus bridge (legacy tray bindings)

    func testAppStatusBridgeMapsAllCases() {
        XCTAssertEqual(AggregateStatus.noDrives.appStatus, .idle)
        XCTAssertEqual(AggregateStatus.allIdle.appStatus, .idle)
        XCTAssertEqual(AggregateStatus.syncing.appStatus, .syncing)
        XCTAssertEqual(AggregateStatus.error(count: 3).appStatus, .error)
        XCTAssertEqual(AggregateStatus.mixed.appStatus, .error)
    }

    // MARK: - Header visibility

    func testNoDrivesHidesHeader() {
        XCTAssertFalse(AggregateStatus.noDrives.shouldShowInTrayHeader)
    }

    func testNonEmptyShowsHeader() {
        XCTAssertTrue(AggregateStatus.allIdle.shouldShowInTrayHeader)
        XCTAssertTrue(AggregateStatus.syncing.shouldShowInTrayHeader)
        XCTAssertTrue(AggregateStatus.error(count: 1).shouldShowInTrayHeader)
        XCTAssertTrue(AggregateStatus.mixed.shouldShowInTrayHeader)
    }
}
