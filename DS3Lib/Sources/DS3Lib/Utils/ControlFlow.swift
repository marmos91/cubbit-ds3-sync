import Foundation
import os.log

/// Errors for the retry control flow utility
public enum ControlFlowError: Error {
    case maxRetriesReached
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
    var retries = retries
    
    if retries == 0 {
        throw ControlFlowError.maxRetriesReached
    }
    
    while retries > 0 {
        do {
            return try await block()
        } catch {
            retries -= 1
            
            if retries == 0 {
                throw error
            }
        }
    }
    
    // Should never reach this
    throw ControlFlowError.maxRetriesReached
}
