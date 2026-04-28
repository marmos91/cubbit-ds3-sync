import DS3Lib
import Foundation
import os.log

// MARK: - OrphanSweeper (Phase 13 D-25, D-26, D-27, D-28; THUMB-19)

/// Computes orphan thumbnail keys (thumbnails whose original key is no longer
/// present in the BFS-enumerated key set) and bulk-deletes them, capped at
/// `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass` (50) per BFS pass.
///
/// Per Phase 13:
/// - **D-25:** Tied to BFS pass tail. Piggybacks on `enumeratedKeys` (the BFS-
///   built `Set<String>` of user-visible original keys) as the source of truth
///   for "does this original exist". No HEAD round-trip per item (D-28).
/// - **D-26:** Hard cap at 50 deletes per sweep. Re-enable storms or freshly-
///   corrupted states get cleaned up across multiple BFS passes — natural
///   cadence handles the long tail without ever issuing a thousand-delete
///   burst in a single pass.
/// - **D-27:** Caller MUST gate on `ThumbnailSettings.enabled == true` —
///   disabled drives never sweep (D-04: leave thumbnails in place when
///   disabled so re-enable can reuse them for free).
///
/// **Listing strategy:** Phase 11's `S3PathUtils.thumbnailKey(...)` places
/// `.thumbnails/` per-folder (e.g. `prefix/photos/.thumbnails/foo.jpg`), NOT
/// at the drive root. A literal `<drivePrefix>.thumbnails/` listing would
/// only catch root-level thumbs. Instead we issue a paginated recursive list
/// of the drive prefix, then filter via `S3PathUtils.isThumbnailKey`. We stop
/// pagination once the post-filter thumbnail-key count reaches
/// `2 * DefaultSettings.Thumbnail.maxOrphanDeletesPerPass` (= 100), which
/// gives the sweep enough orphan candidates to fill its delete budget
/// without traversing the whole bucket on every pass. On smaller buckets the
/// loop terminates naturally when `isTruncated == false`. Without pagination
/// the sweeper would only ever see the first 1000 keys, leaving orphans in
/// later-sorting subfolders permanently un-reclaimed on large drives.
///
/// **Defensive skips:**
/// - Folder marker keys (trailing `/`) are skipped — never delete a folder.
/// - Keys that don't parse via `S3PathUtils.originalKey(fromThumbnailKey:)` —
///   skipped, never deleted (some hostile / future thumb naming we don't
///   recognise should not be reclaimed by us).
///
/// **Error containment:**
/// - List failure → log warning, return 0 (next BFS pass will retry).
/// - Per-item delete failure → log warning, continue with the next orphan
///   (never abort a sweep on one bad delete).
struct OrphanSweeper {
    let s3Client: any DS3S3ClientProtocol
    let logger: os.Logger

    /// Lists thumbnail keys under `drivePrefix`, computes the set diff against
    /// `enumeratedKeys`, and deletes any thumbnail whose implied original is
    /// NOT in `enumeratedKeys`. Capped at
    /// `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass`.
    /// - Returns: Number of deletes actually issued (for logging / metrics).
    func sweep(
        bucket: String,
        drivePrefix: String?,
        enumeratedKeys: Set<String>
    ) async -> Int {
        let cap = DefaultSettings.Thumbnail.maxOrphanDeletesPerPass

        let allKeys: [String]
        do {
            allKeys = try await listAllKeys(bucket: bucket, drivePrefix: drivePrefix)
        } catch {
            logger.warning(
                "Orphan sweep listing failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        var deleted = 0
        for key in allKeys {
            if deleted >= cap { break }
            // Folder markers — never delete.
            if key.hasSuffix("/") { continue }
            // Filter to thumbnail keys only (BFS lists everything under prefix).
            guard S3PathUtils.isThumbnailKey(key, drivePrefix: drivePrefix) else { continue }

            // Defensive: skip if we can't parse the implied original.
            // S3PathUtils.originalKey(fromThumbnailKey:) returns the input
            // unchanged when there's no `.thumbnails/` segment — which can't
            // happen here (we just filtered by isThumbnailKey), but treat
            // an unchanged value as "unparseable" defensively.
            let originalKey = S3PathUtils.originalKey(
                fromThumbnailKey: key, drivePrefix: drivePrefix
            )
            if originalKey == key { continue }

            // Implied original still exists in the BFS-enumerated set → keep.
            if enumeratedKeys.contains(originalKey) { continue }

            // Orphan — delete.
            do {
                try await s3Client.deleteThumbnail(bucket: bucket, key: key)
                deleted += 1
            } catch {
                logger.warning(
                    """
                    Orphan sweep delete failed for \(key, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }

        if deleted > 0 {
            logger.info("Orphan sweep deleted \(deleted) orphan thumbnails (cap=\(cap))")
        }
        return deleted
    }

    // MARK: - Private helpers

    /// Recursive list of `drivePrefix`. Continues paginating until either:
    ///   • the listing is no longer truncated (full coverage of the prefix), OR
    ///   • the post-filter thumbnail-key count reaches `2 *
    ///     DefaultSettings.Thumbnail.maxOrphanDeletesPerPass` (= 100), giving
    ///     the sweep enough candidates to fill its per-pass delete budget
    ///     without traversing the whole bucket on every pass.
    ///
    /// Without pagination the sweeper would only ever see the first 1000 keys
    /// of the prefix; orphan thumbnails living in later-sorting subfolders
    /// would never be reclaimed on large drives.
    private func listAllKeys(
        bucket: String, drivePrefix: String?
    ) async throws -> [String] {
        let thumbKeyBudget = DefaultSettings.Thumbnail.maxOrphanDeletesPerPass * 2
        var collected: [String] = []
        var thumbKeyCount = 0
        var continuationToken: String?

        repeat {
            let result = try await s3Client.listObjects(
                bucket: bucket,
                prefix: drivePrefix,
                delimiter: nil, // recursive
                maxKeys: 1000,
                continuationToken: continuationToken
            )

            for object in result.objects {
                collected.append(object.key)
                if S3PathUtils.isThumbnailKey(object.key, drivePrefix: drivePrefix) {
                    thumbKeyCount += 1
                }
            }

            if !result.isTruncated { break }
            if thumbKeyCount >= thumbKeyBudget { break }
            continuationToken = result.nextContinuationToken
        } while continuationToken != nil

        return collected
    }
}

// MARK: - OrphanSweeping conformance (same-file Sendable conformance)

/// Same-file conformance to the test-injection seam declared in
/// `BFSThumbnailHookRunner.swift`. Swift 6 strict concurrency requires
/// Sendable conformances to live in the same file as the type.
extension OrphanSweeper: OrphanSweeping {}
