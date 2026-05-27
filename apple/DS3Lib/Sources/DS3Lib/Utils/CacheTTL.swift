import Foundation

/// Determines whether a cached value is still fresh based on its timestamp and a TTL.
/// Returns `true` if the value should be refreshed (stale or no previous timestamp).
public func isCacheStale(lastEnumerated: Date?, ttl: TimeInterval, now: Date = Date()) -> Bool {
    guard let last = lastEnumerated else { return true }
    return now.timeIntervalSince(last) >= ttl
}
