import Foundation
import os.log

/// Render+PUT pipeline used by the upload-hook in `createItem` / `modifyItem`
/// (Plan 13-07 wiring). One caller, one local file URL, one fresh source ETag.
///
/// Per D-07 the type is a `Sendable struct` (NOT actor) — the caller already
/// provides isolation via `Task.detached`, so layering an actor here would only
/// add an unnecessary hop. The render call is whole-function macOS-gated
/// (D-09); the type itself is cross-platform Sendable so iOS extension targets
/// can hold a reference but compile out the body.
///
/// Failure semantics (D-06 fire-and-forget contract):
///   - Non-raster originalKey → silently mark `.notApplicable` and return.
///   - Renderer returns nil → log + record a strike via `setThumbnailFailure`
///     (`.pending` → `.pending` until the 3rd strike, then terminal `.failed`).
///   - PUT throws → log + record a strike via `setThumbnailFailure` + RETHROW
///     (caller's `try? await ...` swallows; this rethrow lets the caller observe
///     the failure if it ever wants to in the future).
///
/// Strike semantics (Plan 13-04 D-29..D-32): each render/PUT failure increments
/// `thumbnailFailCount`. Items reach terminal `.failed` only after 3 strikes;
/// an ETag change on the original (observed during BFS upsert) resets both
/// the count and the status to `.pending` so the file is retried fresh.
public struct ThumbnailUploader: Sendable {
    private let s3Client: any DS3S3ClientProtocol
    private let metadataStore: MetadataStore
    private let logger = Logger(
        subsystem: LogSubsystem.app,
        category: LogCategory.thumbnail.rawValue
    )

    public init(s3Client: any DS3S3ClientProtocol, metadataStore: MetadataStore) {
        self.s3Client = s3Client
        self.metadataStore = metadataStore
    }

    #if os(macOS)
        public func generateAndUpload(
            localURL: URL,
            drive: DS3Drive,
            sourceETag: String,
            originalKey: String
        ) async throws {
            // (a) Defensive raster pre-filter — caller is expected to pre-filter via the
            // same allow-list, but we re-check so that a regression upstream marks the
            // SyncedItem `.notApplicable` rather than burning a render attempt.
            //
            // Plan 13-01 shipped `S3PathUtils.isRasterExtension(_:)` — the canonical
            // helper that reads from `DefaultSettings.Thumbnail.rasterExtensions`. Use
            // it here so the upload-hook pre-filter (D-08) and the consume-path
            // pre-filter share one source of truth and one entry point.
            let pathExtension = (originalKey as NSString).pathExtension
            guard S3PathUtils.isRasterExtension(pathExtension) else {
                try? await metadataStore.setThumbnailStatus(
                    s3Key: originalKey, driveId: drive.id, status: .notApplicable
                )
                return
            }

            // (b) Render — the renderer's allow-list (UTI-based, magic-byte sniffed) is
            // stricter than the extension allow-list, so this branch fires for files with
            // a raster extension whose bytes don't decode (corrupt JPEGs, unknown UTI).
            guard let data = ThumbnailRenderer().renderJPEG(from: localURL) else {
                logger.info(
                    "Uploader: render returned nil for \(originalKey, privacy: .public) — incrementing fail count"
                )
                // Plan 13-04 retrofit: 3-strike-aware. Below threshold the row stays
                // .pending so subsequent BFS passes retry; at >= maxFailStrikes (3) the
                // row flips to terminal .failed.
                try? await metadataStore.setThumbnailFailure(
                    s3Key: originalKey, driveId: drive.id
                )
                return
            }

            // (c) Compute the canonical thumbnail key — `<parent>/.thumbnails/<filename>.jpg`.
            let bucket = drive.syncAnchor.bucket.name
            let drivePrefix = drive.syncAnchor.prefix
            let thumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: originalKey, drivePrefix: drivePrefix
            )

            // (d) PUT. On throw: mark `.failed` and rethrow. The double-write here is
            // intentional — the persisted `.failed` survives the rethrow in case the
            // caller doesn't catch (which it shouldn't, per D-06).
            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket,
                    key: thumbKey,
                    data: data,
                    sourceETag: sourceETag
                )
            } catch {
                logger.error(
                    "Uploader: PUT failed for \(thumbKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                // Plan 13-04 retrofit: 3-strike-aware. PUT failure increments the
                // strike count; only the third consecutive failure flips terminal.
                try? await metadataStore.setThumbnailFailure(
                    s3Key: originalKey, driveId: drive.id
                )
                throw error
            }

            // (e) Persist `.uploaded` — the row is now in steady state until the next
            // BFS pass observes an ETag change (Plan 13-04 reset condition).
            try? await metadataStore.setThumbnailStatus(
                s3Key: originalKey, driveId: drive.id, status: .uploaded
            )
        }
    #endif
}
