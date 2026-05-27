import Foundation

/// Utilities for normalizing and comparing S3 ETags.
///
/// S3 ETags may or may not be surrounded by double quotes depending on the SDK
/// and operation. This enum provides normalization and comparison that handles
/// both forms transparently.
public enum ETagUtils: Sendable {
    /// Strips surrounding double quotes from an ETag string, if present.
    ///
    /// - Parameter etag: The ETag string to normalize, or `nil`
    /// - Returns: The ETag without surrounding quotes, or `nil` if input was `nil`
    public static func normalize(_ etag: String?) -> String? {
        guard let etag else { return nil }
        if etag.hasPrefix("\""), etag.hasSuffix("\"") {
            return String(etag.dropFirst().dropLast())
        }
        return etag
    }

    /// Compares two ETags after normalization.
    ///
    /// Returns `false` if either ETag is `nil` -- both must exist for a valid comparison.
    ///
    /// - Parameters:
    ///   - lhs: First ETag (may be quoted or unquoted)
    ///   - rhs: Second ETag (may be quoted or unquoted)
    /// - Returns: `true` if both ETags are non-nil and equal after normalization
    public static func areEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let normalizedLhs = normalize(lhs),
              let normalizedRhs = normalize(rhs)
        else {
            return false
        }
        return normalizedLhs == normalizedRhs
    }
}
