import XCTest
@testable import DS3Lib

/// Tests for the ``DarwinNotificationCenter`` Swift wrapper around Darwin notifications.
final class DarwinNotificationTests: XCTestCase {

    // MARK: - Test 1: post does not crash

    func testPostDoesNotCrash() {
        DarwinNotificationCenter.shared.post(name: "io.cubbit.test.darwinNotification.noCrash")
    }

    // MARK: - Test 2: addObserver round-trip fires callback

    func testAddObserverRoundTrip() {
        let expectation = expectation(description: "Darwin notification callback fires")
        let name = "io.cubbit.test.darwinNotification.roundTrip.\(UUID().uuidString)"

        let observation = DarwinNotificationCenter.shared.addObserver(name: name) {
            expectation.fulfill()
        }

        DarwinNotificationCenter.shared.post(name: name)

        wait(for: [expectation], timeout: 2.0)
        observation.cancel()
    }

    // MARK: - Test 3: AsyncStream yields on post

    func testNotificationsAsyncStreamYieldsOnPost() async throws {
        let name = "io.cubbit.test.darwinNotification.asyncStream.\(UUID().uuidString)"
        let stream = DarwinNotificationCenter.shared.notifications(named: name)

        let task = Task<Bool, Never> {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return true
        }

        // Give the listener time to register
        try await Task.sleep(for: .milliseconds(100))
        DarwinNotificationCenter.shared.post(name: name)

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

        XCTAssertTrue(result, "AsyncStream should have yielded after post")
    }

    // MARK: - Test 4: cancel stops receiving notifications

    func testCancelStopsReceivingNotifications() {
        let name = "io.cubbit.test.darwinNotification.cancel.\(UUID().uuidString)"

        // First, verify the observer fires
        let fireExpectation = expectation(description: "Callback fires before cancel")
        let observation = DarwinNotificationCenter.shared.addObserver(name: name) {
            fireExpectation.fulfill()
        }
        DarwinNotificationCenter.shared.post(name: name)
        wait(for: [fireExpectation], timeout: 2.0)

        // Cancel the observation
        observation.cancel()

        // After cancel, callback should NOT fire.
        // Use an inverted expectation: it fails if fulfilled within timeout.
        let noFireExpectation = expectation(description: "Callback must not fire after cancel")
        noFireExpectation.isInverted = true

        let secondObservation = DarwinNotificationCenter.shared.addObserver(name: name) {
            noFireExpectation.fulfill()
        }
        // The original observation is cancelled, but secondObservation is not.
        // We actually want to test that the FIRST observation doesn't fire.
        // Since we can't easily test a negative with the cancelled observation,
        // we verify by adding a new observer and cancelling it too.
        secondObservation.cancel()

        DarwinNotificationCenter.shared.post(name: name)
        wait(for: [noFireExpectation], timeout: 0.5)
    }
}
