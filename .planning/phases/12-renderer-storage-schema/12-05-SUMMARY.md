---
phase: 12-renderer-storage-schema
plan: 05
subsystem: imaging
tags: [actor, swiftdata, soto, thumbnails, dslib, scaffold]

requires:
  - phase: 12-01
    provides: MetadataStore.fetchPendingThumbnails / setThumbnailStatus / PendingThumbnail DTO
  - phase: 12-03
    provides: putThumbnail / getThumbnailBytes / deleteThumbnail on DS3S3ClientProtocol
  - phase: 12-04
    provides: public struct ThumbnailRenderer (macOS-only) with renderJPEG(from:)
provides:
  - public actor ThumbnailBackfillCoordinator at DS3Lib/Sources/DS3Lib/Thumbnails/
  - BatchResult struct with processed/succeeded/skipped/failed counters
  - runBatch(maxItems:) async throws -> BatchResult — runnable end-to-end but no production caller
  - Smoke tests covering empty-store short-circuit (zero counts + no S3 calls)
affects: [phase 13 (BFS backfill hook calls runBatch), phase 14 (iOS overnight loop calls runBatch)]

tech-stack:
  added: []  # No new dependencies — composes existing DS3Lib surfaces
  patterns:
    - "Cross-platform actor shell with #if os(macOS) only on the render branch (D-29)"
    - "Protocol-seam init: s3Client: any DS3S3ClientProtocol (Open Q2 RESOLVED)"
    - "Outcome enum + per-item processing + sequential loop (Open Q4 — no TaskGroup in scaffold)"
    - "Pitfall 9 — defer-based temp-file cleanup, robust to render and PUT failures"

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift

key-decisions:
  - "Cross-platform shell: actor compiles on iOS + macOS; only the render step is `#if os(macOS)` (D-29). Phase 14 extends the iOS branch with a real render path."
  - "iOS branch in Phase 12 marks items `.failed` as a deliberate placeholder. Phase 12 ships zero iOS callers, so reaching the iOS render code is itself an error condition Phase 14 will redesign."
  - "Sequential render in Phase 12 scaffold (Open Q4 RESOLVED) — Phase 13/14 add parallelism (TaskGroup, semaphore) when concrete callers need it."
  - "BatchResult field names processed/succeeded/skipped/failed (Open Q1 RESOLVED — kept `.succeeded`, NOT `.uploaded`)."
  - "Init takes `any DS3S3ClientProtocol` (Open Q2 RESOLVED) — protocol seam gives MockDS3S3Client a clean construction path; concrete `DS3S3Client` in D-30 was illustrative."
  - "Coordinator uses `s3Client.getObject(bucket:key:toFile:onProgress:)` to download the original to a temp URL. The renderer requires a file URL because `CGImageSourceCreateWithURL` is the memory-safe path; in-memory data would be wasteful at 5-30 MB originals."
  - "Per D-39 — scaffold-only smoke tests: empty-store short-circuit returns zero counts and makes no S3 calls. End-to-end flow tests belong to Phase 13 when a real BFS caller wires this up."

patterns-established:
  - "ThumbnailBackfillCoordinator: composition of MetadataStore (actor) + DS3S3ClientProtocol (protocol) + Renderer (struct) — pure orchestration, no business logic in the coordinator beyond the per-item state machine"
  - "Scope guard: Phase 12 ships zero production callers of the coordinator (verified via grep on DS3DriveProvider/, DS3Drive/, DS3DriveApp/, DS3DriveShareExtension/). The coordinator is dormant until Phase 13."

requirements-completed: []  # Scaffolding plan — no new requirements; composes 12-01/12-03/12-04 deliverables

duration: ~30min
completed: 2026-04-25
---

# Phase 12-05: ThumbnailBackfillCoordinator Scaffold Summary

**Public actor that wires fetch-pending → download original → render JPEG → PUT thumbnail → mark uploaded into a single `runBatch(maxItems:)` API — runnable end-to-end against the artifacts from 12-01/12-03/12-04 but invoked by no production caller in Phase 12.**

## Performance

- **Duration:** ~30 minutes (RED → GREEN smoke test + full suite verification)
- **Tasks:** 1/1
- **Files created:** 2
- **Tests added:** 2 (smoke-only per D-39)

## Accomplishments

- **`public actor ThumbnailBackfillCoordinator`** at `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift`. Init takes `(metadataStore: MetadataStore, s3Client: any DS3S3ClientProtocol, drive: DS3Drive)` — one coordinator per drive. Cross-platform shell so Phase 14's iOS main app can reuse the actor verbatim.
- **`runBatch(maxItems:) async throws -> BatchResult`** — the single entry point Phase 13's BFS hook will call with `maxItems: 5` and Phase 14's iOS overnight task will loop until `BGProcessingTask` expiration.
- **End-to-end happy path wired**: `metadataStore.fetchPendingThumbnails(driveId:limit:)` → for each `PendingThumbnail`, download original via `s3Client.getObject(toFile:)` → render JPEG via `ThumbnailRenderer().renderJPEG(from:)` (macOS only) → PUT via `s3Client.putThumbnail(bucket:key:data:sourceETag:)` → `setThumbnailStatus(.uploaded)`. Failures at any step (download, render, PUT) transition the item to `.failed` and continue with the next.
- **Pitfall 9 — `defer { try? FileManager.default.removeItem(at: tempURL) }`** ensures temp files are always cleaned, even on render or PUT failure mid-batch.
- **iOS placeholder branch**: the `#else` arm of `renderAndUpload` marks items `.failed` with a comment explaining Phase 14's redesign responsibility. Phase 12 ships zero iOS callers.
- **`BatchResult`** carries the four counters Phase 13's tray progress UI (THUMB-24) and Phase 14's iOS settings progress UI (THUMB-26) will consume. `processed = succeeded + skipped + failed` is invariant.
- **Smoke tests** (`ThumbnailBackfillCoordinatorTests`):
  - Empty MetadataStore + `runBatch(maxItems: 1)` returns `BatchResult(processed: 0, succeeded: 0, skipped: 0, failed: 0)`.
  - Empty MetadataStore + `runBatch(maxItems: 1)` makes no S3 calls (`getObject(...)` and `putObjectData(...)` neither appear in `MockDS3S3Client.calls`).
- **Full DS3Lib regression**: 500 tests pass, 31 skipped, 0 failures (no Phase 12 work has regressed any prior test).

## Task Commits

1. **Task 1 RED — failing smoke tests** — staged but not committed in the executor agent's run (1Password signing refused mid-stream); orchestrator's continuation pass committed alongside GREEN.
2. **Task 1 GREEN — feat: ThumbnailBackfillCoordinator scaffold** — `e5a1ff6` (combined RED+GREEN commit on continuation per the same signing-refusal recovery pattern as 12-03 and 12-04).

## Files Created/Modified

- `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` (NEW, ~205 lines)
  - public actor with logger, three stored deps, `BatchResult` struct, `Outcome` private enum, `processItem` per-item driver, `renderAndUpload(...)` helper with `#if os(macOS) / #else` arms.
- `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` (NEW, ~92 lines)
  - In-memory V3 MetadataStore helper, synthetic DS3Drive fixture, two smoke tests.

## Decisions Made

None beyond the locked decisions D-28..D-33 + D-39 and the four RESOLVED open questions in 12-RESEARCH.md (`.succeeded` naming, protocol seam, no parallelism in scaffold, V3 init backward compat — the last not directly relevant to 12-05 but ties the schema work together).

## Deviations from Plan

None — plan executed exactly as written, with the protocol-seam pattern locked at the planning revision step (Open Q2) applied to the init signature.

## Issues Encountered

- The 1Password SSH signing agent refused operations mid-execution (third occurrence in this phase, after 12-03 and 12-04). The executor agent halted at the staged RED test per the parallel-execution checkpoint contract; the orchestrator's continuation pass implemented the GREEN file inline, ran the full test suite, and committed both RED + GREEN together as `e5a1ff6` once the user re-approved 1Password.
- Initial draft used `s3Client.getObjectToFile(...)` which doesn't exist; corrected to the actual `s3Client.getObject(bucket:key:toFile:onProgress:)` signature on `DS3S3ClientProtocol`. The download path requires the destination file to exist as an empty file before invocation per the API contract at `DS3S3Client+Transfers.swift:14` — added an explicit `FileManager.default.createFile(atPath:contents:)` before the download.

## Next Phase Readiness

- Phase 13's BFS backfill hook can construct `ThumbnailBackfillCoordinator(metadataStore:, s3Client:, drive:)` once per drive on extension launch and call `runBatch(maxItems: 5)` per BFS pass.
- Phase 13's tray progress UI (THUMB-24) consumes `BatchResult.processed / succeeded / skipped / failed` directly. If Phase 13 needs `countPending(driveId:)` for "N of M" display, that's a one-line addition to `MetadataStore+Queries.swift` per D-22's deferred surface.
- Phase 14's iOS main app constructs the same coordinator and loops `runBatch` from `ForegroundBackfillDriver` and `BGProcessingTask`. Phase 14 also rewrites the iOS render branch to do real work.
- The full DS3Lib test suite is green at 500 tests — Phase 12's scaffold has zero regression impact.
- Phase 12's deferred-idea ledger remains intact: no `headThumbnail`, no `countPending`, no parallel renders, no cascade hooks, no orphan sweep, no upload-path hook leaked into Phase 12 plans.

---
*Phase: 12-renderer-storage-schema*
*Completed: 2026-04-25*
