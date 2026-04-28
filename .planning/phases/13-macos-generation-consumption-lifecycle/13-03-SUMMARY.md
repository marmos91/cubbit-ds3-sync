---
phase: 13-macos-generation-consumption-lifecycle
plan: 03
subsystem: thumbnails

tags: [thumbnails, s3, soto, copyobject, rename-cascade, server-side-copy]

# Dependency graph
requires:
  - phase: 12-renderer-storage-schema
    provides: "DS3S3Client.copyObject(metadata:) primitive (lines 326-342); DS3S3ClientProtocol with putThumbnail/getThumbnailBytes/deleteThumbnail extension pattern; MockDS3S3Client recording infrastructure; isNotFoundError helper for NoSuchKey detection"
provides:
  - "DS3S3ClientProtocol.copyThumbnail(bucket:fromKey:toKey:) protocol-default extension method"
  - "Server-side single-call S3 copy preserving x-amz-meta-source-etag and x-amz-meta-ds3drive-thumb-version"
  - "TDD pin (Test 2 — XCTAssertNil(metadata)) protecting the metadata-preservation contract from regression (T-13-12 mitigation)"
  - "MockDS3S3Client copyObject call observers (lastCopyObjectBucket/SourceKey/DestinationKey/Metadata + copyObjectCallCount) reusable by future plans"
affects:
  - 13-08-rename-cascade
  - rename-move-thumbnail-cascade

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Protocol-default extension pattern (continued from Phase 12) for thumbnail S3 ops — all conformers gain copyThumbnail for free"
    - "metadata: nil contract for AWS default COPY directive (preserves source metadata server-side)"

key-files:
  created:
    - DS3Lib/Tests/DS3LibTests/CopyThumbnailTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift
    - DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift

key-decisions:
  - "copyThumbnail lives on the public extension of DS3S3ClientProtocol (not added as a required protocol method) — forwarding to copyObject (which IS a required protocol method) keeps the protocol surface small and gives all conformers + mocks the method automatically."
  - "Implementation is a single-line forward to copyObject(metadata: nil); per AWS S3 spec, omitting x-amz-metadata-directive defaults to COPY which preserves source user-metadata. No per-key percent-encoding here — that responsibility lives in DS3S3Client.copyObject (Pitfall 6 already mitigated upstream)."
  - "Test 2 (XCTAssertNil(metadata)) is the regression pin for threat T-13-12 — any future drift to non-nil metadata flips the test red and prevents silent loss of staleness markers."

patterns-established:
  - "Phase 13 S3 thumbnail extensions co-located in DS3S3Client+Thumbnails.swift — file remains under SwiftLint limits (88 lines)"
  - "MockDS3S3Client gains per-method observation hooks (lastXxxBucket/Key/...) following the Phase 12 lastPutObjectDataMetadata precedent"

requirements-completed:
  - THUMB-18

# Metrics
duration: 3min
completed: 2026-04-25
---

# Phase 13 Plan 03: copyThumbnail Server-Side Copy Summary

**Server-side S3 thumbnail copy via single CopyObject call, preserving Phase-12-written staleness metadata (source-etag + format-version) for the Plan 13-08 rename/move cascade.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-25T16:15:39Z
- **Completed:** 2026-04-25T16:18:39Z
- **Tasks:** 2 (TDD: RED + GREEN; no REFACTOR needed for a 4-line forwarding wrapper)
- **Files modified:** 3 (1 created, 2 modified)

## Accomplishments

- `DS3S3ClientProtocol.copyThumbnail(bucket:fromKey:toKey:)` — protocol-default extension method shipping in `DS3S3Client+Thumbnails.swift`
- Single-call server-side copy via existing `copyObject(metadata: nil)`, preserving `x-amz-meta-source-etag` and `x-amz-meta-ds3drive-thumb-version`
- Five TDD tests (`CopyThumbnailTests`) pinning: single-CopyObject delegation, metadata-nil contract (T-13-12 regression guard), NoSuchKey rethrow, 5xx rethrow, key passthrough byte-for-byte
- `MockDS3S3Client` extended with copyObject call observers — reusable across future plans

## Task Commits

Each task was committed atomically (TDD: RED → GREEN):

1. **Task 1: Write failing CopyThumbnailTests** — `d4bb04e` (test) — RED gate
2. **Task 2: Implement copyThumbnail on DS3S3ClientProtocol extension** — `6887fcb` (feat) — GREEN gate

(REFACTOR phase intentionally omitted — implementation is a 4-line forward; no cleanup warranted.)

## Files Created/Modified

- `DS3Lib/Tests/DS3LibTests/CopyThumbnailTests.swift` (created) — 5 TDD tests covering CopyObject delegation, metadata-preservation, NoSuchKey + 5xx rethrow, key passthrough
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` (modified) — appended `copyThumbnail` to the existing `public extension DS3S3ClientProtocol` block (file now 88 lines, well under SwiftLint limit)
- `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift` (modified) — added `lastCopyObjectBucket / SourceKey / DestinationKey / Metadata`, `lastCopyObjectMetadataWasSet`, and `copyObjectCallCount` observers; updated `copyObject(...)` to record args

## Decisions Made

- **D-13-03-A: Extension method, not required protocol method.** copyThumbnail forwards to copyObject (a required protocol method), so adding it to the protocol's required surface would be redundant. Extension placement keeps DS3S3ClientProtocol minimal and gives every conformer (real client + mocks) the new method for free.
- **D-13-03-B: metadata: nil over explicit metadataDirective parameter.** Soto's CopyObjectRequest already maps `metadata: nil` to omitting the `x-amz-metadata-directive` header (verified at DS3S3Client.swift:339 — the existing copyObject sets `metadataDirective: (metadata?.isEmpty == false) ? .replace : nil`). Forwarding `metadata: nil` is the cleanest expression of "preserve source metadata via AWS default COPY".
- **D-13-03-C: Test 2 metadata-nil pin is the T-13-12 regression guard.** Plan 13-08 will commit cascade logic that depends on staleness metadata surviving the copy; if a future refactor changes copyThumbnail to pass non-nil metadata, the AWS server treats it as REPLACE and silently strips x-amz-meta-source-etag and x-amz-meta-ds3drive-thumb-version. The XCTAssertNil pin is the cheapest way to prevent that.

## Deviations from Plan

None — plan executed exactly as written. Both tasks landed verbatim against the action spec; the only "additions" were the MockDS3S3Client observers, which the plan explicitly anticipated ("extend the mock to record copyObject invocations if it doesn't already — likely it doesn't").

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required. Pure DS3Lib internal change.

## Threat Model Outcomes

| Threat ID | Disposition | Outcome |
|-----------|-------------|---------|
| T-13-09 (cross-drive key tampering) | mitigate | Disposition unchanged — caller (Plan 13-08) responsibility; copyThumbnail does not introduce a new attack surface here. |
| T-13-10 (copy-source URL info disclosure) | accept | Disposition unchanged — copyThumbnail uses the same upstream copyObject as every other CopyObject in the codebase; no new exposure. |
| T-13-11 (rename-storm DoS) | mitigate | Cascade rate limiting is Plan 13-08's concern; copyThumbnail is single-call (no multipart amplification). |
| T-13-12 (silent metadata reset) | mitigate | **Pinned by Test 2** (`testCopyThumbnailPassesNilMetadataForDirectiveCopy`) — XCTAssertNil(lastCopyObjectMetadata) prevents future regression to non-nil metadata. |

## Next Phase Readiness

- Plan 13-08 (rename/move cascade) can now build on `copyThumbnail` for server-side thumbnail relocation.
- All success criteria met: function exists, delegates to copyObject with metadata: nil, all 5 TDD tests green, swift build clean, no SwiftLint overflow.

## TDD Gate Compliance

- RED gate (`d4bb04e`, type `test`) — confirmed compile failure: "value of type 'MockDS3S3Client' has no member 'copyThumbnail'" before implementation landed.
- GREEN gate (`6887fcb`, type `feat`) — all 5 tests pass after implementation.
- REFACTOR gate — intentionally omitted (4-line forwarding wrapper has nothing to refactor); not required by the gate-compliance check.

## Self-Check: PASSED

- File `DS3Lib/Tests/DS3LibTests/CopyThumbnailTests.swift` exists.
- File `DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift` exists (modified).
- File `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift` exists (modified).
- File `.planning/phases/13-macos-generation-consumption-lifecycle/13-03-SUMMARY.md` exists.
- Commit `d4bb04e` (test) found in history.
- Commit `6887fcb` (feat) found in history.

---
*Phase: 13-macos-generation-consumption-lifecycle*
*Plan: 03*
*Completed: 2026-04-25*
