import DS3Lib
import Foundation
import os.log

/// Render+PUT pipeline used by the upload-hook in `createItem` / `modifyItem`
/// (Plan 13-07 wiring). One caller, one local file URL, one fresh source ETag.
///
/// Per D-07 the type is a `Sendable struct` (NOT actor) — the caller already
/// provides isolation via `Task.detached`, so layering an actor here would only
/// add an unnecessary hop. The render call is whole-function macOS-gated (D-09);
/// the iOS extension does not link `ThumbnailRendering`, so the gate exists for
/// other macOS-only API surface (CoreGraphics/ImageIO) called from this module.
///
/// Failure semantics (D-06 fire-and-forget contract, Phase 13.2 D-05/D-08/D-19):
///   - Non-raster originalKey → log + return (caller pre-filters anyway).
///   - Renderer returns `.failure(reason)` → log the sub-reason and return.
///     No schema strike counter anymore (Schema V5 dropped `thumbnailFailCount`);
///     the consume-path fallback's `ThumbnailFallbackLimiter` owns the
///     in-memory 3-strike rule.
///   - PUT throws → log + RETHROW (caller's `try? await ...` swallows). No
///     schema strike counter write.
///
/// NOTE: This `ThumbnailRendering`-product helper is the legacy localURL-based
/// path (still used by call sites that haven't migrated). The eager-path
/// `runUploadHook` in DS3DriveProvider is the canonical post-#141
/// implementation and uses different error semantics (logs + swallows
/// PUT errors per D-06; does not rethrow). Don't unify their
/// behavior without revisiting the eager-path D-06 contract.
///
/// Phase 13.2 Plan 09 (D-08, D-23): all `thumbnailStatus` writes removed in
/// the same plan that ships Schema V6 — the field is gone from `SyncedItem`,
/// so writing to it would not compile. The `metadataStore` parameter is
/// retained for API stability (Plan 09 deliberately keeps the signature
/// compatible with existing call sites).
public struct ThumbnailUploader: Sendable {
    private let s3Client: any DS3S3ClientProtocol
    // Retained for API stability — callers pass a store but the uploader no
    // longer writes any thumbnail-specific fields against it (Phase 13.2 D-08).
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
            // same allow-list, but we re-check so that a regression upstream is logged
            // rather than burning a render attempt.
            //
            // Plan 13-01 shipped `S3PathUtils.isRasterExtension(_:)` — the canonical
            // helper that reads from `DefaultSettings.Thumbnail.rasterExtensions`. Use
            // it here so the upload-hook pre-filter (D-08) and the consume-path
            // pre-filter share one source of truth and one entry point.
            //
            // Phase 13.2 D-08: no longer marks `.notApplicable` — the field is gone
            // in Schema V6.
            let pathExtension = (originalKey as NSString).pathExtension
            guard S3PathUtils.isRasterExtension(pathExtension) else {
                logger.debug(
                    "Uploader: skipping non-raster originalKey \(originalKey, privacy: .public)"
                )
                return
            }

            // (b) Render — the renderer's allow-list (UTI-based, magic-byte sniffed) is
            // stricter than the extension allow-list, so this branch fires for files with
            // a raster extension whose bytes don't decode (corrupt JPEGs, unknown UTI).
            let renderResult = ThumbnailRenderer().renderJPEG(from: localURL)
            let data: Data
            switch renderResult {
            case let .success(bytes):
                data = bytes
            case let .failure(reason):
                logger.info(
                    "Uploader: render failed for \(originalKey, privacy: .public) — reason=\(reason.rawValue, privacy: .public)"
                )
                // Phase 13.2 D-05/D-19: no schema strike counter anymore. The
                // consume-path fallback's `ThumbnailFallbackLimiter` (in-memory)
                // owns the 3-strike rule. The consume-path fallback re-renders
                // from S3 on the next visit anyway.
                return
            }

            // (c) Compute the canonical thumbnail key — `<parent>/.thumbnails/<filename>.jpg`.
            let bucket = drive.syncAnchor.bucket.name
            let drivePrefix = drive.syncAnchor.prefix
            let thumbKey = S3PathUtils.thumbnailKey(
                forOriginalKey: originalKey, drivePrefix: drivePrefix
            )

            // (d) PUT. Errors rethrow to the caller's `try? await ...` (D-06 contract).
            // Phase 13.2 D-08: no `.failed` write — the field is gone in Schema V6.
            do {
                _ = try await s3Client.putThumbnail(
                    bucket: bucket,
                    key: thumbKey,
                    data: data,
                    sourceETag: sourceETag
                )
            } catch {
                logger.error(
                    "Uploader: PUT failed for \(thumbKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                )
                throw error
            }

            // Phase 13.2 D-08: no `.uploaded` write — the field is gone in
            // Schema V6. The "is the thumbnail uploaded?" question is now
            // answered by S3 itself via `getThumbnailBytes`.
        }
    #endif
}
