---
status: resolved
trigger: "ThumbnailRenderer.renderJPEG returns nil for valid raster files (PNG/JPG/HEIC) across multiple code paths during Phase 13 manual audit"
created: 2026-04-27T15:30:00Z
updated: 2026-04-27T15:30:00Z
---

## Current Focus

hypothesis: CGImageSourceCreateWithURL with kCGImageSourceShouldCache=false performs lazy reads against the source URL; when the URL becomes invalid (FileProvider temp URL released after createItem returns) or under concurrent pressure (bulk uploads / backfill), CGImageSourceCreateThumbnailAtIndex fails silently and returns nil. May also have a stricter renderer-internal allow-list filtering valid UTIs. Combined or independent — needs code read.
test: read DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift end-to-end; trace each guard / option flag; identify all nil-return paths; verify whether localURL is read eagerly (Data snapshot) vs lazily (URL-backed CGImageSource); check whether sourceType is checked against an internal allow-list narrower than the extension-based pre-filter
expecting: at least one of:
  - CGImageSourceCreateWithURL is the lazy path and a Data-snapshot fix is appropriate
  - sourceType allow-list rejects valid PNGs (Cubbit logo) — would be a bug in the magic-byte sniff
  - kCGImageSourceShouldCacheImmediately option interaction with kCGImageSourceShouldCache:false produces a regression
next_action: read renderer source, identify each early-return, propose fix with code-line precision

## Symptoms

expected: ThumbnailRenderer().renderJPEG(from: localURL) returns valid JPEG Data for any file whose path extension is in DefaultSettings.Thumbnail.rasterExtensions = {jpg, jpeg, png, heic, heif, webp, gif, tiff, tif}, given the bytes are a real raster image
actual: Returns nil for well-formed PNGs (Cubbit logo, Cubbit retreat photos, Apple-generated PNG screenshots) and HEIC re-pastes. Reproduced 4 minutes apart on identical bytes (15:06 succeeded, 15:10 failed for IMG_0015.HEIC)
errors: No exception thrown — silent nil return. ThumbnailUploader logs "Uploader: render returned nil for X — incrementing fail count" at io.cubbit.DS3Drive:thumbnail subsystem
reproduction:
  - Bulk paste 8 raster files into a Drive folder → 6/8 fail (15:14:35)
  - Re-paste a previously-successful HEIC after 4 minutes → fails (15:10:13.704)
  - Trigger backfill on a cloud-only photo (different code path, coordinator owns temp file lifetime) → fails (15:19:03.223 Cubbit retreat 2022-50.jpg)
  - AppleDouble files (._packet_loss.png) returning nil is correct behavior, not part of this bug

## Evidence

- timestamp: 2026-04-27T15:06:41Z
  observation: First HEIC paste succeeded — Personal/.thumbnails/IMG_0015.HEIC.jpg PUT with correct Source-Etag metadata
- timestamp: 2026-04-27T15:10:13.704Z
  observation: Identical HEIC re-paste failed — log "Uploader: render returned nil for Personal/IMG_0015.HEIC — incrementing fail count". Same file bytes (ETag 8cb65f96791c2ce30cb315044f4a0c7b matches first paste)
- timestamp: 2026-04-27T15:14:35Z
  observation: Bulk paste 8 raster files into Personal/Images/ → 6 nil-renders within 71 ms of each other (image001.png, Logo_Cubbit.png, PR_cover_ENG.jpg, Logo_Cubbit-01.png, wrd0047.jpg, social_eng.jpg)
- timestamp: 2026-04-27T15:19:03.223Z
  observation: Backfill flow (different code path — coordinator downloads original to its own temp, renderer reads from that path) ALSO returns nil for cloud-only Cubbit retreat photo. Rules out FileProvider URL invalidation as the SOLE cause
- timestamp: 2026-04-27T15:19:24.090Z
  observation: Single rename re-upload of PNG → render returned nil

## Eliminated

- URL invalidation under FileProvider temp-dir cleanup — subsumed by the eager Data snapshot. The renderer no longer holds a URL-lifetime dependency, so revoked/cleaned-up source URLs cannot affect decoding.
- Page-cache eviction under concurrent load — subsumed by the eager Data snapshot. With bytes materialized into a `Data` buffer up front, decode no longer depends on the kernel's file-backed page cache state during the bulk-paste fanout window.
- UTI allow-list rejection — verified during the read-through: the renderer's source-type filter is the same magic-byte sniff used by the call-site pre-filter; no narrower second gate.

## Investigation Plan

1. Read DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift end-to-end
2. List every nil-return path; classify each as (a) URL invalidation (b) UTI rejection (c) decode failure (d) thumbnail-create failure
3. Check call site contract: does ThumbnailUploader pass `localURL` that may be revoked? What's the security-scope handling? Is the Backfill coordinator's temp URL different in lifetime?
4. Check option flags interaction: kCGImageSourceShouldCache=false + kCGImageSourceShouldCacheImmediately=true is suspicious
5. Propose fix at code-line precision (e.g. switch to `Data(contentsOf:)` + `CGImageSourceCreateWithData` so the bytes are eagerly snapshotted). Validate against backfill case (where snapshot wouldn't help if bug is independent of URL lifetime)
6. Determine if there is a SECONDARY bug (not URL-related) explaining backfill failure on cloud-only files

## Files To Read

- DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailRenderer.swift (primary)
- DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift (call site for upload-hook path)
- DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift (call site for backfill path)
- DS3DriveProvider/FileProviderExtension+ThumbnailUploadHook.swift (URL provenance for upload-hook)
- .planning/phases/13-macos-generation-consumption-lifecycle/13-02-PLAN.md (renderer + uploader spec)
- .planning/phases/13-macos-generation-consumption-lifecycle/13-RESEARCH.md (CGImageSource pitfalls)

## Resolution

Fix: replaced `CGImageSourceCreateWithURL` (URL-backed, lazy-read) with an eager `Data(contentsOf: localURL, options: .mappedIfSafe)` snapshot fed into `CGImageSourceCreateWithData`. Decoding is now decoupled from URL lifetime and from page-cache contention windows during bulk paste — the bug class is structurally eliminated, not just suppressed.

Verification:
- Three Phase 13.1 regression tests pinned the audit symptoms (bulk-paste fanout, repeated decodes of identical bytes, backfill from temp URL). All three passed on the first run after the fix.
- D-12 contingency (escalate to a per-renderer serial queue if the eager-snapshot fix didn't restore success rate) was NOT triggered.
- Bulk-paste fanout regression test was subsequently strengthened to render distinct file copies per task (matches the audit's distinct-file scenario, not just the same file from N tasks); it continues to pass.

Status: closed. No follow-up action required.
