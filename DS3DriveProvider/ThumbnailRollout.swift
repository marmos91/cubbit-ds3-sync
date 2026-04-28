import DS3Lib
import Foundation
import os.log

// MARK: - ThumbnailSettingsStoring (test-injection seam)

/// Minimal facade over the `SharedData` thumbnail-settings methods that
/// `ThumbnailRollout` consumes. Production injects the live `SharedData`
/// singleton; tests inject an in-memory mock so the rollout can be exercised
/// without an App Group container.
///
/// We bound the seam to just `has` + `save` because that's all the rollout
/// touches — narrow protocols keep the mock surface small and document the
/// rollout's exact dependency on persistence.
protocol ThumbnailSettingsStoring: Sendable {
    func hasThumbnailSettings(forDrive driveId: UUID) -> Bool
    func saveThumbnailSettings(forDrive driveId: UUID, settings: ThumbnailSettings) throws
}

extension SharedData: ThumbnailSettingsStoring {}

// MARK: - ThumbnailRollout

/// Once-per-drive silent launch-time rollout (Phase 13 D-01, D-02, D-03; THUMB-23;
/// Plan 13-10).
///
/// On extension launch, the lifecycle hook spawns a detached Task that calls
/// `runIfNeeded(forDrive:)`:
///   • If `hasThumbnailSettings` returns true → no-op (D-02 once-per-drive guard).
///   • Otherwise inspect the bucket's `.thumbnails/` prefix:
///       - `.empty` / `.matchesOurs` → persist `enabled = true`
///       - `.conflicting` → persist `enabled = false`
///   • Errors during inspect are logged + swallowed (D-03 silent UX); no settings
///     file is written, so the next launch retries automatically.
///
/// **Silent UX (D-03):** No NSUserNotification, no toast, no banner. The only
/// observable side effects are one ListObjectsV2 per drive on first launch and
/// one SharedData JSON write per drive.
///
/// **Concurrency:** `runIfNeeded` is a regular async function. The lifecycle
/// caller wraps the invocation in `Task.detached` so launch is not blocked
/// (verified by `testRolloutRunsInBackgroundDoesNotBlockLaunch`).
struct ThumbnailRollout {
    let s3Client: any DS3S3ClientProtocol
    let settingsStore: any ThumbnailSettingsStoring
    let logger: os.Logger

    /// For a single drive, run the rollout if it has never been persisted.
    /// Idempotent — safe to call on every launch.
    func runIfNeeded(forDrive drive: DS3Drive) async {
        // D-02: skip if already persisted (also returns true on a fresh-saved entry,
        // and false on missing/corrupt — see `SharedData.hasThumbnailSettings` for
        // the corrupt-JSON self-heal contract).
        if settingsStore.hasThumbnailSettings(forDrive: drive.id) {
            return
        }

        let driveId = drive.id
        let bucket = drive.syncAnchor.bucket.name
        let prefix = drive.syncAnchor.prefix

        do {
            let state = try await s3Client.inspectThumbnailPrefix(bucket: bucket, prefix: prefix)
            let enabled = switch state {
            case .empty, .matchesOurs:
                true
            case .conflicting:
                false
            }
            try settingsStore.saveThumbnailSettings(
                forDrive: driveId,
                settings: ThumbnailSettings(enabled: enabled)
            )
            logger.info(
                "ThumbnailRollout: drive \(driveId.uuidString, privacy: .public) settings persisted enabled=\(enabled, privacy: .public)"
            )
        } catch {
            // D-03: silent — log + swallow. No settings file is written, so the
            // next launch retries (the once-per-drive guard returns false).
            logger.warning(
                "ThumbnailRollout: drive \(driveId.uuidString, privacy: .public) skipped due to error: \(DS3S3Client.describeSotoError(error), privacy: .public)"
            )
        }
    }
}
