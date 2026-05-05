import CryptoKit
import Foundation

/// Produces the deterministic per-container sync anchor used to detect
/// "did anything change in this folder?" without persisting state.
///
/// Format: `"v1:" + sha256(sorted "<key>\t<etag>" pairs joined by "\n")`,
/// returned as UTF-8 bytes. The system stores these bytes as
/// `NSFileProviderSyncAnchor` data and hands them back on
/// `enumerateChanges(from:)`.
///
/// The `v1:` prefix is an explicit forward-compatibility hatch. If we ever
/// need to include S3 `versionId` (when the bucket has versioning enabled)
/// or change the algorithm, we bump to `v2:`. Stored anchors with the old
/// prefix are then treated as a mismatch and the system re-enumerates from
/// scratch — the correct behaviour, no migration code required.
///
/// Deliberate non-choices:
/// - `lastModified` is excluded — S3 mutates it on storage-class changes
///   and CopyObject metadata writes, producing false positives.
/// - `versionId` is excluded for v1 — on non-versioned buckets it's the
///   literal string `"null"` for every object, adding noise without signal.
public enum SyncAnchorHash {
    public static let formatPrefix = "v1:"

    /// Computes the anchor over a snapshot of children for a single container.
    /// Pass any sequence of `(key, etag)` tuples; ordering is normalised inside.
    public static func compute(over entries: [(key: String, etag: String?)]) -> Data {
        let sorted = entries
            .map { "\($0.key)\t\($0.etag ?? "")" }
            .sorted()
        let joined = sorted.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Data((formatPrefix + hex).utf8)
    }

    /// Sendable input record for the working-set anchor variant.
    /// Carries the per-row data folded into the hash: S3 key, etag, and the
    /// `thumbnailReadyAt` one-shot stamp (issue #153).
    public struct WorkingSetEntry: Sendable {
        public let key: String
        public let etag: String?
        public let thumbnailReadyAt: Date?

        public init(key: String, etag: String?, thumbnailReadyAt: Date?) {
            self.key = key
            self.etag = etag
            self.thumbnailReadyAt = thumbnailReadyAt
        }
    }

    /// Variant that also folds an optional `thumbnailReadyAt` timestamp into
    /// the hash. Used by `WorkingSetEnumerator` (issue #153): when the iOS
    /// backfill driver stamps `thumbnailReadyAt` on a row after its sidecar
    /// PUT lands, the working-set anchor changes — Apple then calls
    /// `enumerateChanges`, which re-emits those rows as `didUpdate` so
    /// Files.app invalidates its per-item thumbnail cache.
    ///
    /// Folder-level (`S3Enumerator`) anchors continue to use the 2-tuple
    /// form: per-folder thumbnail signalling is handled by the explicit
    /// `signalEnumerator(for: parentId)` call in the backfill driver, not
    /// by anchor drift.
    public static func compute(over entries: [WorkingSetEntry]) -> Data {
        let sorted = entries
            .map { entry in
                let stamp = entry.thumbnailReadyAt.map { String($0.timeIntervalSince1970) } ?? ""
                return "\(entry.key)\t\(entry.etag ?? "")\t\(stamp)"
            }
            .sorted()
        let joined = sorted.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Data((formatPrefix + hex).utf8)
    }
}
