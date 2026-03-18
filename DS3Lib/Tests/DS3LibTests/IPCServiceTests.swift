import XCTest
@testable import DS3Lib

// MARK: - MockIPCService

/// A mock implementation of ``IPCService`` that proves the protocol is implementable
/// and allows controlled testing of stream yield/consume cycles.
final class MockIPCService: IPCService, @unchecked Sendable {

    let statusUpdates: AsyncStream<DS3DriveStatusChange>
    let transferSpeeds: AsyncStream<DriveTransferStats>
    let commands: AsyncStream<IPCCommand>
    let conflicts: AsyncStream<ConflictInfo>
    let authFailures: AsyncStream<IPCAuthFailure>
    let extensionInitFailures: AsyncStream<IPCExtensionInitFailure>

    private let statusContinuation: AsyncStream<DS3DriveStatusChange>.Continuation
    private let transferContinuation: AsyncStream<DriveTransferStats>.Continuation
    private let commandContinuation: AsyncStream<IPCCommand>.Continuation
    private let conflictContinuation: AsyncStream<ConflictInfo>.Continuation
    private let authFailureContinuation: AsyncStream<IPCAuthFailure>.Continuation
    private let extInitContinuation: AsyncStream<IPCExtensionInitFailure>.Continuation

    init() {
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: DS3DriveStatusChange.self)
        (transferSpeeds, transferContinuation) = AsyncStream.makeStream(of: DriveTransferStats.self)
        (commands, commandContinuation) = AsyncStream.makeStream(of: IPCCommand.self)
        (conflicts, conflictContinuation) = AsyncStream.makeStream(of: ConflictInfo.self)
        (authFailures, authFailureContinuation) = AsyncStream.makeStream(of: IPCAuthFailure.self)
        (extensionInitFailures, extInitContinuation) = AsyncStream.makeStream(of: IPCExtensionInitFailure.self)
    }

    func postStatusChange(_ change: DS3DriveStatusChange) async {
        statusContinuation.yield(change)
    }

    func postTransferStats(_ stats: DriveTransferStats) async {
        transferContinuation.yield(stats)
    }

    func postCommand(_ command: IPCCommand) async {
        commandContinuation.yield(command)
    }

    func postConflict(_ info: ConflictInfo) async {
        conflictContinuation.yield(info)
    }

    func postAuthFailure(domainId: String, reason: String) async {
        authFailureContinuation.yield(IPCAuthFailure(domainId: domainId, reason: reason))
    }

    func postExtensionInitFailure(domainId: String, reason: String) async {
        extInitContinuation.yield(IPCExtensionInitFailure(domainId: domainId, reason: reason))
    }

    func startListening() async {}

    func stopListening() async {
        statusContinuation.finish()
        transferContinuation.finish()
        commandContinuation.finish()
        conflictContinuation.finish()
        authFailureContinuation.finish()
        extInitContinuation.finish()
    }
}

// MARK: - IPCServiceTests

final class IPCServiceTests: XCTestCase {

    // MARK: - Test 1: MockIPCService can be created and yields status updates

    func testMockIPCServiceYieldsStatusUpdates() async {
        let mock = MockIPCService()
        let driveId = UUID()
        let expected = DS3DriveStatusChange(driveId: driveId, status: .sync)

        await mock.postStatusChange(expected)

        var iterator = mock.statusUpdates.makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.driveId, driveId)
        XCTAssertEqual(received?.status, .sync)
    }

    // MARK: - Test 2: MockIPCService postStatusChange round-trip

    func testMockIPCServicePostStatusChangeRoundTrip() async {
        let mock = MockIPCService()
        let driveId = UUID()
        let change = DS3DriveStatusChange(driveId: driveId, status: .idle)

        // Post then consume
        await mock.postStatusChange(change)

        var iterator = mock.statusUpdates.makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received?.driveId, change.driveId)
        XCTAssertEqual(received?.status, change.status)
    }

    // MARK: - Test 3: MacOSIPCService init creates non-nil stream properties

    #if os(macOS)
    func testMacOSIPCServiceInitCreatesStreams() {
        let service = MacOSIPCService()

        // Verify streams are non-nil by checking they can create iterators
        _ = service.statusUpdates.makeAsyncIterator()
        _ = service.transferSpeeds.makeAsyncIterator()
        _ = service.commands.makeAsyncIterator()
        _ = service.conflicts.makeAsyncIterator()
        _ = service.authFailures.makeAsyncIterator()
        _ = service.extensionInitFailures.makeAsyncIterator()
    }
    #endif

    // MARK: - Test 4: MacOSIPCService postStatusChange -> statusUpdates round-trip

    #if os(macOS)
    func testMacOSIPCServiceStatusRoundTrip() async throws {
        let service = MacOSIPCService()
        await service.startListening()

        let driveId = UUID()
        let expected = DS3DriveStatusChange(driveId: driveId, status: .sync)

        // Consume in a task with timeout
        let task = Task<DS3DriveStatusChange?, Never> {
            var iterator = service.statusUpdates.makeAsyncIterator()
            return await iterator.next()
        }

        // Give the listener time to register
        try await Task.sleep(for: .milliseconds(100))

        await service.postStatusChange(expected)

        // Wait with timeout
        let result = await withTaskGroup(of: DS3DriveStatusChange?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.driveId, driveId)
        XCTAssertEqual(result?.status, .sync)

        await service.stopListening()
    }
    #endif

    // MARK: - Test 5: MacOSIPCService postTransferStats -> transferSpeeds round-trip

    #if os(macOS)
    func testMacOSIPCServiceTransferStatsRoundTrip() async throws {
        let service = MacOSIPCService()
        await service.startListening()

        let driveId = UUID()
        let expected = DriveTransferStats(
            driveId: driveId,
            size: 1024,
            duration: 1.5,
            direction: .upload,
            filename: "test.txt",
            totalSize: 4096
        )

        let task = Task<DriveTransferStats?, Never> {
            var iterator = service.transferSpeeds.makeAsyncIterator()
            return await iterator.next()
        }

        try await Task.sleep(for: .milliseconds(100))
        await service.postTransferStats(expected)

        let result = await withTaskGroup(of: DriveTransferStats?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.driveId, driveId)
        XCTAssertEqual(result?.size, 1024)
        XCTAssertEqual(result?.direction, .upload)

        await service.stopListening()
    }
    #endif

    // MARK: - Test 6: MacOSIPCService stopListening finishes streams

    #if os(macOS)
    func testMacOSIPCServiceStopListeningFinishesStreams() async throws {
        let service = MacOSIPCService()
        await service.startListening()

        // The for-await loop should terminate after stopListening
        let task = Task<Bool, Never> {
            for await _ in service.statusUpdates {
                // Should not receive anything -- just wait for termination
            }
            return true // Loop terminated = stream finished
        }

        try await Task.sleep(for: .milliseconds(100))
        await service.stopListening()

        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(result, "Stream should have terminated after stopListening")
    }
    #endif

    // MARK: - Test 7: IPCCommand encodes and decodes correctly (all cases)

    func testIPCCommandCodableRoundTrip() throws {
        let id = UUID()

        let cases: [IPCCommand] = [
            .pauseDrive(driveId: id),
            .resumeDrive(driveId: id),
            .refreshEnumeration(driveId: id),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for command in cases {
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(IPCCommand.self, from: data)
            XCTAssertEqual(decoded, command)
        }
    }
}
