import Foundation
import os.log

/// Errors for the retry control flow utility
public enum ControlFlowError: Error {
    case maxRetriesReached
}

/// Actor-based async semaphore for limiting concurrency without blocking threads.
/// Use `wait()` / `signal()` around the critical section.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.permits = value
    }

    /// Waits until a permit is available, then acquires one.
    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a permit, unblocking the next waiter if any.
    public func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }
}

/// Retries a block of code a given number of times before throwing an error
/// - Parameters:
///   - retries: the number of retries
///   - logger: optional logger
///   - block: the block of code to retry
/// - Throws: the error thrown by the block of code
/// - Returns: the result of the block of code
public func withRetries<T>(
    retries: Int,
    withLogger logger: Logger? = nil,
    block: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard retries > 0 else {
        throw ControlFlowError.maxRetriesReached
    }

    var lastError: Error = ControlFlowError.maxRetriesReached
    for _ in 0..<retries {
        do {
            return try await block()
        } catch {
            lastError = error
        }
    }

    throw lastError
}

/// Retries a block with exponential backoff and jitter.
/// - Parameters:
///   - maxRetries: Maximum number of retry attempts (default 3)
///   - baseDelay: Initial delay in seconds (default 1.0)
///   - maxDelay: Cap on delay in seconds (default 60.0)
///   - multiplier: Delay multiplier per attempt (default 2.0)
///   - logger: Optional logger for retry messages
///   - block: The async throwing closure to retry
/// - Returns: The result of the block
/// - Throws: The last error if all retries exhausted
public func withExponentialBackoff<T>(
    maxRetries: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 60.0,
    multiplier: Double = 2.0,
    logger: Logger? = nil,
    block: @escaping @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await block()
        } catch {
            attempt += 1
            if attempt >= maxRetries { throw error }
            let delay = min(baseDelay * pow(multiplier, Double(attempt - 1)), maxDelay)
            let jitter = delay * Double.random(in: 0.75...1.25)
            logger?.debug("Retry \(attempt)/\(maxRetries) after \(String(format: "%.1f", jitter))s")
            try await Task.sleep(for: .seconds(jitter))
        }
    }
}
