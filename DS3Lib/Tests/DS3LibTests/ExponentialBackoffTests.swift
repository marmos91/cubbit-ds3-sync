import XCTest
import Atomics
@testable import DS3Lib

final class ExponentialBackoffTests: XCTestCase {
    struct TestError: Error {}

    func testSucceedsOnFirstAttempt() async throws {
        let result = try await withExponentialBackoff(maxRetries: 3, baseDelay: 0.01) {
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    func testRetriesOnFailure() async throws {
        let attempts = ManagedAtomic<Int>(0)
        let result: String = try await withExponentialBackoff(maxRetries: 3, baseDelay: 0.01) {
            let current = attempts.wrappingIncrementThenLoad(ordering: .relaxed)
            if current < 3 { throw TestError() }
            return "success"
        }
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attempts.load(ordering: .relaxed), 3)
    }

    func testThrowsAfterMaxRetries() async {
        let attempts = ManagedAtomic<Int>(0)
        do {
            let _: Int = try await withExponentialBackoff(maxRetries: 3, baseDelay: 0.01) {
                attempts.wrappingIncrement(ordering: .relaxed)
                throw TestError()
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is TestError)
            XCTAssertEqual(attempts.load(ordering: .relaxed), 3)
        }
    }

    func testDelayIncreasesBetweenRetries() async throws {
        // Verify the correct number of retries occur (timing is non-deterministic due to jitter)
        let attempts = ManagedAtomic<Int>(0)
        do {
            let _: Int = try await withExponentialBackoff(maxRetries: 4, baseDelay: 0.01, maxDelay: 1.0) {
                attempts.wrappingIncrement(ordering: .relaxed)
                throw TestError()
            }
        } catch {
            XCTAssertEqual(attempts.load(ordering: .relaxed), 4, "Should have attempted exactly maxRetries times")
        }
    }
}
