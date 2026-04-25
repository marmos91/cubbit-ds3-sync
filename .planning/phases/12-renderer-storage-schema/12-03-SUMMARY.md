---
phase: 12-renderer-storage-schema
plan: 03
subsystem: api
tags: [s3, soto, thumbnails, mockable]

requires:
  - phase: 11-foundation-filtering
    provides: DS3S3Client+ThumbnailPrefix protocol-extension precedent; DS3S3ClientProtocol mockable seam
  - phase: 12-02
    provides: DefaultSettings.Thumbnail constants (sourceETagMetadataKey, formatVersionMetadataKey, formatVersion, maxSinglePartBytes)
provides:
  - putThumbnail / getThumbnailBytes / deleteThumbnail surface on DS3S3ClientProtocol
  - Metadata-aware putObjectData(bucket:key:data:metadata:) overload at the protocol layer
  - getObjectData(bucket:key:) read path on protocol + concrete + mock
  - 9 mock-driven tests covering every metadata header, 200/404/5xx branches, and delete semantics
affects: [phase 13 (consumer rewrite of fetchThumbnails), phase 13 (UploadThumbnailHook), phase 14 (iOS coordinator)]

tech-stack:
  added: []  # No new dependencies — Soto v6 already linked
  patterns:
    - "Protocol-default extension for new S3 surface (mirrors Phase 11 inspectThumbnailPrefix at DS3S3Client+ThumbnailPrefix.swift:20)"
    - "BARE x-amz-meta-* keys passed to Soto metadata dict (Soto auto-prepends prefix per Pitfall 2 / verified in S3_shapes.swift:1597-1600)"
    - "precondition() guards single-part PUT size at top of putThumbnail (D-12)"
    - "404 → nil return, 5xx → throw on getThumbnailBytes; 404 silent on deleteThumbnail (D-13/D-14)"

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift
    - DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift
    - DS3Lib/Tests/DS3LibTests/MockDS3S3ClientTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift
    - DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift
    - DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift

key-decisions:
  - "Protocol-default extension (Open Q2 RESOLVED) — putThumbnail/getThumbnailBytes/deleteThumbnail land on `public extension DS3S3ClientProtocol`, not on concrete DS3S3Client. MockDS3S3Client inherits the implementations for free."
  - "Required non-optional sourceETag parameter on putThumbnail (D-09) — staleness-blind uploads are unrepresentable at the call site."
  - "BARE metadata keys: pass `[\"source-etag\": ..., \"ds3drive-thumb-version\": ...]` to Soto. Soto's AWSMemberEncoding(label: \"metadata\", location: .headerPrefix(\"x-amz-meta-\")) auto-prepends the prefix per request — manual prefixing causes double-prefix (Pitfall 2)."
  - "putObjectData(metadata:) overload added to DS3S3ClientProtocol as the testable seam (Pitfall 8 / Open Q2 protocol-seam pattern). Default implementation uses Soto's single-shot S3.putObject directly — never the multipart-capable +Transfers path."
  - "DS3Lib stays below the FileProvider error boundary — errors are raw Soto/Swift, never NSFileProviderErrorDomain. Phase 13 wraps at the boundary."

patterns-established:
  - "DS3S3Client+Thumbnails.swift: extension-file precedent for cohesive S3 feature surfaces (joins +Presign, +Transfers, +ThumbnailPrefix)"
  - "Mock recording fields capture metadata dicts so tests assert exact header content, not just call count"

requirements-completed: [THUMB-10]

duration: ~50min
completed: 2026-04-25
---

# Phase 12-03: Thumbnail S3 Surface Summary

**Three thumbnail S3 methods (put/get/delete) on DS3S3ClientProtocol with bare-key metadata, single-part precondition, and 404-as-nil read semantics — Soto v6 metadata-encoding verified against source.**

## Performance

- **Duration:** ~50 minutes (TDD RED → GREEN × 2 tasks)
- **Tasks:** 2/2
- **Files created:** 3
- **Files modified:** 3
- **Tests added:** 9 (DS3S3ClientThumbnailsTests + MockDS3S3ClientTests)

## Accomplishments

- `putThumbnail(bucket:key:data:sourceETag:) async throws -> String` ships with both `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version` BARE-key headers on every PUT.
- `precondition(data.count < DefaultSettings.Thumbnail.maxSinglePartBytes)` traps oversized thumbnails at the call site — surfaces renderer misbehavior loudly in dev, never ships a corrupt thumbnail silently.
- `getThumbnailBytes(bucket:key:) async throws -> Data?` returns nil on `NoSuchKey`, throws on 5xx — Phase 13's cache-first `fetchThumbnails` rewrite gets the exact signal it needs to enqueue regeneration vs. surface a real error.
- `deleteThumbnail(bucket:key:) async throws` is silent on 404 — cascade and orphan-sweep callers (Phase 13) can issue deletes without try/catch boilerplate.
- New `putObjectData(bucket:key:data:metadata:)` overload on `DS3S3ClientProtocol` provides the mock seam — `MockDS3S3Client` records the exact metadata dict and tests assert BARE keys.
- New `getObjectData(bucket:key:)` read path on protocol + concrete + mock supports the in-memory thumbnail read.

## Task Commits

1. **Task 1 RED — failing test for putObjectData metadata overload** — `e12cc5e`
2. **Task 1 GREEN — feat: metadata-aware putObjectData overload on protocol** — `9c5bc74`
3. **Task 2 RED — failing tests for thumbnail S3 methods** — `7b62bc8`
4. **Task 2 GREEN — feat: thumbnail S3 surface (THUMB-10)** — `05068f1`

## Files Created/Modified

- `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` — putThumbnail / getThumbnailBytes / deleteThumbnail on `public extension DS3S3ClientProtocol`
- `DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` — added `putObjectData(metadata:)` and `getObjectData` requirements
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — concrete `putObjectData(metadata:)` + `getObjectData` using Soto single-shot
- `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift` — captures metadata dict; supports canned 200/404/5xx returns
- `DS3Lib/Tests/DS3LibTests/MockDS3S3ClientTests.swift` — covers Task 1 surface
- `DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift` — 9 tests cover Task 2 semantics

## Decisions Made

None beyond the locked decisions D-08..D-15. Plan executed exactly as written; the protocol-seam pattern for `putObjectData` was Open Q2 (RESOLVED in research) and applied verbatim.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- 1Password SSH signing agent began refusing operations after the third commit. Per the parallel-execution contract ("If GPG fails: STOP, write checkpoint, return — do NOT bypass signing silently"), the agent halted and surfaced a checkpoint. The user re-approved 1Password and the orchestrator drove the final two commits (Task 2 GREEN + this SUMMARY) on its retry path.

## Next Phase Readiness

- Phase 13 can call `putThumbnail` directly from its upload-path hook with the source ETag in hand.
- Phase 13's cache-first `fetchThumbnails` rewrite has `getThumbnailBytes` returning nil-on-404 as its cache-miss signal.
- Phase 13's cascade-on-delete and orphan-sweep paths use `deleteThumbnail` with no error wrapping.
- Phase 14 iOS uses the same protocol — the mock seam carries forward.

---
*Phase: 12-renderer-storage-schema*
*Completed: 2026-04-25*
