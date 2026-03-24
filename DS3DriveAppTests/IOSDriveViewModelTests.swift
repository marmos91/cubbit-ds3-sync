#if os(iOS)
    @testable import DS3DriveApp
    @testable import DS3Lib
    import XCTest

    // MARK: - Lightweight mock IPC service for tests (avoids App Group access)

    private final class StubIPCService: IPCService, @unchecked Sendable {
        let statusUpdates: AsyncStream<DS3DriveStatusChange>
        let transferSpeeds: AsyncStream<DriveTransferStats>
        let commands: AsyncStream<IPCCommand>
        let conflicts: AsyncStream<ConflictInfo>
        let authFailures: AsyncStream<IPCAuthFailure>
        let extensionInitFailures: AsyncStream<IPCExtensionInitFailure>

        init() {
            (statusUpdates, _) = AsyncStream.makeStream(of: DS3DriveStatusChange.self)
            (transferSpeeds, _) = AsyncStream.makeStream(of: DriveTransferStats.self)
            (commands, _) = AsyncStream.makeStream(of: IPCCommand.self)
            (conflicts, _) = AsyncStream.makeStream(of: ConflictInfo.self)
            (authFailures, _) = AsyncStream.makeStream(of: IPCAuthFailure.self)
            (extensionInitFailures, _) = AsyncStream.makeStream(of: IPCExtensionInitFailure.self)
        }

        func postStatusChange(_: DS3DriveStatusChange) async { /* stub */ }
        func postTransferStats(_: DriveTransferStats) async { /* stub */ }
        func postCommand(_: IPCCommand) async { /* stub */ }
        func postConflict(_: ConflictInfo) async { /* stub */ }
        func postAuthFailure(domainId _: String, reason _: String) async { /* stub */ }
        func postExtensionInitFailure(domainId _: String, reason _: String) async { /* stub */ }
        func startListening() async { /* stub */ }
        func stopListening() async { /* stub */ }
    }

    // MARK: - IOSDriveViewModel Tests

    @MainActor
    final class IOSDriveViewModelTests: XCTestCase {
        private func makeViewModel() -> IOSDriveViewModel {
            IOSDriveViewModel(ipcService: StubIPCService())
        }

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

            XCTAssertNotEqual(idle, error)
            XCTAssertNotEqual(idle, paused)
            XCTAssertNotEqual(error, paused)

            let sync = IOSDriveViewModel.statusColor(for: .sync)
            let indexing = IOSDriveViewModel.statusColor(for: .indexing)
            XCTAssertEqual(sync, indexing)
        }

        // MARK: - Status Accessor

        func testStatusDefaultsToIdle() {
            let vm = makeViewModel()
            XCTAssertEqual(vm.status(for: UUID()), .idle)
        }

        func testStatusReturnsStoredValue() {
            let vm = makeViewModel()
            let driveId = UUID()
            vm.driveStatuses[driveId] = .error
            XCTAssertEqual(vm.status(for: driveId), .error)
        }

        // MARK: - Speed Accessor

        func testSpeedReturnsNilForUnknownDrive() {
            let vm = makeViewModel()
            XCTAssertNil(vm.speed(for: UUID()))
        }

        func testSpeedReturnsStoredValue() {
            let vm = makeViewModel()
            let driveId = UUID()
            vm.driveTransferSpeeds[driveId] = 1234.5
            XCTAssertEqual(vm.speed(for: driveId), 1234.5)
        }

        // MARK: - Toggle Pause

        func testTogglePauseSetsAndUnsets() {
            let vm = makeViewModel()
            let driveId = UUID()

            XCTAssertEqual(vm.status(for: driveId), .idle)

            vm.togglePause(for: driveId)
            XCTAssertEqual(vm.status(for: driveId), .paused)

            vm.togglePause(for: driveId)
            XCTAssertEqual(vm.status(for: driveId), .idle)
        }
    }

    // MARK: - Cache Manager

    final class CacheManagerTests: XCTestCase {
        func testFormatSizeSmall() {
            let result = CacheManager.formatSize(500)
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
