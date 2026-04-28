---
phase: 13-macos-generation-consumption-lifecycle
plan: 02
subsystem: thumbnails
tags: [thumbnails, dslib, swift6, macos-gate, upload-hook]

requires:
  - phase: 12-renderer-storage-schema
    provides: ThumbnailRenderer (macOS-gated), DS3S3Client+Thumbnails.putThumbnail with required sourceETag, MetadataStore.setThumbnailStatus, ThumbnailStatus enum
  - phase: 11-foundation-filtering
    provides: S3PathUtils.thumbnailKey(forOriginalKey:drivePrefix:)
provides:
  - public struct ThumbnailUploader: Sendable in DS3Lib/Sources/DS3Lib/Thumbnails/ — pure pipeline struct (not actor)
  - generateAndUpload(localURL:drive:sourceETag:originalKey:) macOS-gated function — render → PUT → mark .uploaded; failure → mark .failed (strike count handled in Plan 13-04 retrofit)
  - ThumbnailUploaderTests in DS3LibTests with 5 tests using mocked DS3S3ClientProtocol
affects: [phase 13-04 (uploader retrofit for strike-count integration), phase 13-07 (createItem/modifyItem post-PUT integration)]

tech-stack:
  added: []
  patterns:
    - "Whole-function `#if os(macOS)` gate on generateAndUpload (D-09) — type stays cross-platform Sendable so iOS Phase 14 can hold a reference; render path is macOS-only"
    - "Pure pipeline struct (not actor) — render+put+persist is a fire-once sequence with no shared state; no actor isolation needed"
    - "Required non-optional sourceETag parameter — staleness-blind uploads unrepresentable at the call site (matches Phase 12 D-09 putThumbnail contract)"

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailUploaderTests.swift
  modified: []

key-decisions:
  - "ThumbnailUploader is a separate type from ThumbnailBackfillCoordinator (D-07) — inline-upload has the local file URL + fresh ETag in hand; no need for fetch-pending / batching / status reconciliation that the coordinator does"
  - "Required sourceETag (D-07 via Phase 12 D-09) — caller must supply the original-PUT response ETag; the function cannot ship a thumbnail without metadata"
  - "Failure path marks SyncedItem .failed at the DS3Lib layer (no error propagation upward) — matches the THUMB-06 fire-and-forget contract; strike-count increment is wired in Plan 13-04"

verification:
  - "swift test --package-path DS3Lib --filter ThumbnailUploaderTests → 5/5 pass (0.038s)"
  - "swift build --package-path DS3Lib → clean"
  - "grep -c 'public struct ThumbnailUploader: Sendable' ThumbnailUploader.swift → 1"
  - "grep -c '#if os(macOS)' ThumbnailUploader.swift → 1"
  - "grep -c 'S3PathUtils.thumbnailKey' ThumbnailUploader.swift → 1"
  - "grep -c 'putThumbnail' ThumbnailUploader.swift → 1"
  - "OSLog dynamic strings carry privacy: .public (≥ 2 occurrences)"
  - "File length 104 lines (< 200)"

requirements_addressed:
  - THUMB-06 (foundational — Phase 13-07 wires it into createItem/modifyItem)

deferred_to_next_plan:
  - "Strike-count integration (thumbnailFailCount increment on failure) — Plan 13-04 retrofits ThumbnailUploader once Schema V4 lands"
  - "Upload-hook call sites (createItem post-PUT, modifyItem content-change post-PUT) — Plan 13-07"

commits:
  - "2898f32 test(13-02): add failing tests for ThumbnailUploader render+PUT pipeline (RED)"
  - "60942bc feat(13-02): ThumbnailUploader render+PUT pipeline (macOS-gated) (GREEN)"

deviations: none

execution_time: ~12 min (RED + GREEN + verification + docs)
---

# Plan 13-02 — ThumbnailUploader

## Outcome

DS3Lib gains a small, focused type for the upload-time thumbnail generation lane. `ThumbnailUploader.generateAndUpload(localURL:drive:sourceETag:originalKey:)` reads the local file (via `ThumbnailRenderer`), single-part-PUTs the JPEG to `.thumbnails/<key>.jpg` with the required `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version` metadata, and marks the SyncedItem `.uploaded` on success or `.failed` on any error.

The function is whole-`#if os(macOS)`-gated so that iOS-target builds compile without a render path (Phase 14 will fill that in via `ForegroundBackfillDriver`). The struct itself stays cross-platform `Sendable` so the iOS main app can still hold a reference.

## How it's used (Phase 13-07)

```swift
Task.detached { [s3Client, metadataStore, drive, originalKey, response] in
    let uploader = ThumbnailUploader(s3Client: s3Client, metadataStore: metadataStore)
    try? await uploader.generateAndUpload(
        localURL: localFileURL,
        drive: drive,
        sourceETag: response.eTag,
        originalKey: originalKey
    )
}
```

Errors are silently swallowed by the caller — the upload contract (THUMB-06) is never blocked by thumbnail work. Inside the function, errors translate to `.failed` status writes at the MetadataStore layer.

## What lands in Plan 13-04 (retrofit)

- `thumbnailFailCount` increment on failure path
- `>= 3` strikes → terminal `.failed` (excluded from `fetchPendingThumbnails`)
- ETag-reset hook on the upsert path

## Tests

5 unit tests with mocked `DS3S3ClientProtocol`:

1. `testGenerateAndUploadHappyPath` — render succeeds → put issued with sourceETag → status .uploaded
2. `testGenerateAndUploadRenderFailureMarksFailed` — render returns nil → status .failed, no put issued
3. `testGenerateAndUploadPutFailurePropagates` — render OK but put throws → status .failed
4. `testGenerateAndUploadPreservesSourceETagInMetadata` — captured PutObjectRequest carries `x-amz-meta-source-etag: <provided>` and `x-amz-meta-ds3drive-thumb-version: 1`
5. `testGenerateAndUploadKeyMappingViaS3PathUtils` — captured key matches `S3PathUtils.thumbnailKey(forOriginalKey:drivePrefix:)`

All 5 pass in 0.038s.

---

*Plan: 13-02*
*Completed: 2026-04-25*
