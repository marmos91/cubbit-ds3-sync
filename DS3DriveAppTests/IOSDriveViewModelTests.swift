#if os(iOS)
    @testable import DS3DriveApp
    @testable import DS3Lib
    import XCTest

    @MainActor
    final class IOSDriveViewModelTests: XCTestCase {
        // MARK: - Format Speed

        func testFormatSpeedBytes() {
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(0), "0 B/s")
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(512), "512 B/s")
        }

        func testFormatSpeedKilobytes() {
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(1024), "1.0 KB/s")
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(1536), "1.5 KB/s")
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(10240), "10.0 KB/s")
        }

        func testFormatSpeedMegabytes() {
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(1_048_576), "1.0 MB/s")
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(5_242_880), "5.0 MB/s")
            XCTAssertEqual(IOSDriveViewModel.formatSpeed(10_485_760), "10.0 MB/s")
        }

        // MARK: - Status Label

        func testStatusLabels() {
            XCTAssertEqual(IOSDriveViewModel.statusLabel(for: .idle), "Synced")
            XCTAssertEqual(IOSDriveViewModel.statusLabel(for: .sync), "Syncing")
            XCTAssertEqual(IOSDriveViewModel.statusLabel(for: .indexing), "Indexing")
            XCTAssertEqual(IOSDriveViewModel.statusLabel(for: .error), "Error")
            XCTAssertEqual(IOSDriveViewModel.statusLabel(for: .paused), "Paused")
        }

        // MARK: - Status Color

        func testStatusColorsAreDistinct() {
            let idle = IOSDriveViewModel.statusColor(for: .idle)
            let error = IOSDriveViewModel.statusColor(for: .error)
            let paused = IOSDriveViewModel.statusColor(for: .paused)

            // Idle, error, and paused should have distinct colors
            XCTAssertNotEqual(idle, error)
            XCTAssertNotEqual(idle, paused)
            XCTAssertNotEqual(error, paused)

            // Sync and indexing share the same color
            let sync = IOSDriveViewModel.statusColor(for: .sync)
            let indexing = IOSDriveViewModel.statusColor(for: .indexing)
            XCTAssertEqual(sync, indexing)
        }

        // MARK: - Status Accessor

        func testStatusDefaultsToIdle() {
            let vm = IOSDriveViewModel(ipcService: makeDefaultIPCService())
            let unknownId = UUID()
            XCTAssertEqual(vm.status(for: unknownId), .idle)
        }

        func testStatusReturnsStoredValue() {
            let vm = IOSDriveViewModel(ipcService: makeDefaultIPCService())
            let driveId = UUID()
            vm.driveStatuses[driveId] = .error
            XCTAssertEqual(vm.status(for: driveId), .error)
        }

        // MARK: - Speed Accessor

        func testSpeedReturnsNilForUnknownDrive() {
            let vm = IOSDriveViewModel(ipcService: makeDefaultIPCService())
            XCTAssertNil(vm.speed(for: UUID()))
        }

        func testSpeedReturnsStoredValue() {
            let vm = IOSDriveViewModel(ipcService: makeDefaultIPCService())
            let driveId = UUID()
            vm.driveTransferSpeeds[driveId] = 1234.5
            XCTAssertEqual(vm.speed(for: driveId), 1234.5)
        }

        // MARK: - Toggle Pause

        func testTogglePauseSetsAndUnsets() {
            let vm = IOSDriveViewModel(ipcService: makeDefaultIPCService())
            let driveId = UUID()

            // Initially idle
            XCTAssertEqual(vm.status(for: driveId), .idle)

            // Toggle to paused
            vm.togglePause(for: driveId)
            XCTAssertEqual(vm.status(for: driveId), .paused)

            // Toggle back to idle
            vm.togglePause(for: driveId)
            XCTAssertEqual(vm.status(for: driveId), .idle)
        }
    }

    // MARK: - Cache Manager

    final class CacheManagerTests: XCTestCase {
        func testFormatSizeSmall() {
            let result = CacheManager.formatSize(500)
            // ByteCountFormatter with .useKB minimum rounds up
            XCTAssertFalse(result.isEmpty)
        }

        func testFormatSizeKilobytes() {
            let result = CacheManager.formatSize(10240)
            XCTAssertTrue(result.contains("KB"), "10 KB should format as KB, got: \(result)")
        }

        func testFormatSizeMegabytes() {
            let result = CacheManager.formatSize(5_242_880)
            XCTAssertTrue(result.contains("MB"), "5 MB should format as MB, got: \(result)")
        }

        func testFormatSizeGigabytes() {
            let result = CacheManager.formatSize(2_147_483_648)
            XCTAssertTrue(result.contains("GB"), "2 GB should format as GB, got: \(result)")
        }

        func testFormatSizeZero() {
            let result = CacheManager.formatSize(0)
            XCTAssertFalse(result.isEmpty)
        }
    }
#endif
