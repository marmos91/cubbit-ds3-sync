---
phase: 13-macos-generation-consumption-lifecycle
plan: 06
subsystem: thumbnails
tags: [thumbnails, file-provider, swift6, ns-file-provider-error, limiter]

requires:
  - phase: 12-renderer-storage-schema
    provides: DS3S3Client+Thumbnails.getThumbnailBytes (silent on 404, throws on 5xx)
  - phase: 13-04
    provides: MetadataStore.setThumbnailStatus (mark .pending on miss)
provides:
  - actor ThumbnailFetchLimiter (4 slots on macOS, FIFO via append/removeFirst, deinit-safe)
  - free function consumeThumbnail (cache-first pipeline; nil on hit/miss/non-raster, NSError on auth/transient)
  - mapThumbnailFetchError (single chokepoint mapping every below-the-seam error to one of three NSFileProviderError codes)
  - cache-first fetchThumbnails rewrite in FileProviderExtension+Thumbnails.swift
affects: [phase 13-09 (BFS hook reads .pending items the consume path now writes), phase 13-10 (rollout enables consume path), phase 13-11 (integration smoke)]

tech-stack:
  added: []
  patterns:
    - "Free function consumeThumbnail (not method on FileProviderExtension) — testable without instantiating the extension subclass"
    - "Sendable shim around the non-Sendable Foundation completion handler via UncheckedBox + closure forwarding"
    - "Single chokepoint mapThumbnailFetchError — every error path tested via testNoCustomErrorDomainEverEscapes (Test 13)"
    - "Helper extraction (spawnCacheFirstThumbnailTask) keeps fetchThumbnails under SwiftLint function-body length limit"

key-files:
  created:
    - DS3DriveProvider/ThumbnailFetchLimiter.swift
    - DS3DriveProvider/FileProviderExtension+ThumbnailConsume.swift
    - DS3DriveProviderTests/ThumbnailFetchLimiterTests.swift
    - DS3DriveProviderTests/FetchThumbnailsTests.swift
    - DS3DriveProviderTests/FetchThumbnailsErrorMappingTests.swift
  modified:
    - DS3DriveProvider/FileProviderExtension+Thumbnails.swift (cache-first rewrite, helper extraction)
    - DS3DriveProvider/FileProviderExtension.swift (limiter property)
    - DS3Drive.xcodeproj/project.pbxproj (file references)

key-decisions:
  - "S3Lib+Thumbnails.swift KEPT (not deleted)" — 6 active callers via S3Lib.isUserVisible (FileProviderExtension+Lifecycle, S3LibListingAdapter, BreadthFirstIndexer, S3Enumerator x3) — file remains the choke-point per Phase 11 D-12. 13-11 audit already confirmed this is the canonical decision.
  - "ThumbnailFetchLimiter actor lives in DS3DriveProvider (not DS3Lib) per D-36 — it's a UI-pacing concern tied to extension lifetime."
  - "consumeThumbnail is a free function — testable without instantiating FileProviderExtension; per-item handler is a typealias-Sendable closure."
  - "Single mapThumbnailFetchError chokepoint maps to {.noSuchItem, .serverUnreachable, .cannotSynchronize, .notAuthenticated} only. Test 13 sweeps 16 error fixtures and asserts no custom domain escapes."
  - "Per-item completion handler crosses Task boundaries via UncheckedBox + Sendable shim closure — the Foundation API isn't @Sendable so we wrap rather than annotate."

verification:
  - "xcodebuild build -scheme DS3Drive -destination 'platform=macOS' → BUILD SUCCEEDED"
  - "xcodebuild test -only-testing:DS3DriveProviderTests/ThumbnailFetchLimiterTests -only-testing:DS3DriveProviderTests/FetchThumbnailsTests -only-testing:DS3DriveProviderTests/FetchThumbnailsErrorMappingTests → 17/17 pass (0.756s total)"
  - "ThumbnailFetchLimiterTests: 4 tests (acquireBelowMaxDoesNotBlock, acquireAtMaxBlocksUntilRelease, fiveOnFour, FIFO-8-contenders)"
  - "FetchThumbnailsTests: 6 tests (raster hit, raster miss, non-raster, folder/root, limiter cap, no-render-on-consume)"
  - "FetchThumbnailsErrorMappingTests: 7 tests (404, 5xx, SlowDown, URLError, auth, unknown, no-custom-domain-sweep)"
  - "Test 13 (testNoCustomErrorDomainEverEscapes) sweeps 16 error fixtures across S3 / URL / NSError / generic — every mapped error stays in {NSFileProviderErrorDomain, NSCocoaErrorDomain}."

requirements_addressed:
  - THUMB-11 (cache-first consume — bytes from `.thumbnails/` prefix, no full-file download)
  - THUMB-12 (badges coexist — consume path doesn't touch badges)
  - THUMB-13 (graceful fallback — nil/.noSuchItem on miss, default UTType icon shown by Finder)
  - THUMB-14 (concurrency cap — 4 slots, FIFO, tested across 8 contenders)
  - THUMB-23 (no full-file download on consume — testFetchThumbnailsDoesNotInvokeRendererOnConsumePath asserts)

deferred_to_next_plan:
  - "Pause-aware backfill check (already present in original fetchThumbnails — preserved)"
  - "BFS hook to drive coordinator — Plan 13-09"
  - "Rollout enable flag wiring — Plan 13-10"

commits:
  - "(prior context-revision iteration) — RED tests already had errata fixed in iteration 1"
  - "test(13-06): add failing tests for ThumbnailFetchLimiter, cache-first fetchThumbnails, and error mapping (RED)"
  - "feat(13-06): cache-first fetchThumbnails + ThumbnailFetchLimiter + NSFileProviderError mapping (GREEN)"

deviations:
  - "Type rename inside spawnCacheFirstThumbnailTask: outer `perThumbnailCompletionHandler` parameter shadows inner `perItemCb` Sendable shim — same logic as original draft, just renamed to avoid shadowing under SwiftLint helper-extraction refactor."
  - "Manual takeover: original 13-06 executor agent stalled mid-execution; orchestrator (this session) took over to fix Sendable-conversion error at the perThumbnailCompletionHandler boundary, plus three SwiftLint violations (NSFileProviderError.code → .code.rawValue in tests, single-letter `i` → `idx`, empty closure body annotation), and to extract spawnCacheFirstThumbnailTask helper to satisfy function-body length budget."

execution_time: ~25 min (counting fix-up iterations and SwiftLint cycles)
---

# Plan 13-06 — Cache-first fetchThumbnails + ThumbnailFetchLimiter

## Outcome

The File Provider extension's `fetchThumbnails` is rewritten from "download original + render inline" to "read `.thumbnails/<key>.jpg` from S3" — Phase 13 D-11 cache-first contract. The new pipeline:

1. Limiter acquires a slot (4 max on macOS, FIFO).
2. `getThumbnailBytes` issues a single S3 GET against `<drivePrefix>.thumbnails/<original-key>.jpg`.
3. **Hit:** bytes returned via per-item handler. Finder draws the actual image.
4. **Miss (404):** mark item `.pending` (BFS picks up next pass), return `.noSuchItem`. Finder falls back to default UTType icon and retries on next browse.
5. **Throw (5xx / SlowDown / URLError / auth):** route through `mapThumbnailFetchError`, return one of `{.noSuchItem, .serverUnreachable, .cannotSynchronize}`. **Never** a custom error domain.

The previous render-from-original fallback at lines 157-249 of `FileProviderExtension+Thumbnails.swift` is gone — Phase 13 honors THUMB-23 (no full-file downloads on the consume path).

## Architecture

```
fetchThumbnails (entry)
    │
    ├── iOS branch (skip — existing memory-budget gate)
    │
    └── macOS branch
         ├── enabled / drive / paused gates  (early exit)
         └── spawnCacheFirstThumbnailTask (helper to keep parent under length limit)
              ├── ThumbnailFetchLimiter actor (4 slots, FIFO, append/removeFirst)
              ├── ThumbnailByteFetcher closure (s3Client.getThumbnailBytes)
              ├── ThumbnailPendingMarker closure (metadataStore.setThumbnailStatus)
              └── Task { TaskGroup { for id in identifiers { consumeThumbnail(...) } } }
                   │
                   └── consumeThumbnail (FileProviderExtension+ThumbnailConsume.swift)
                        ├── Folder / root container → (nil, nil) — no S3 call
                        ├── Non-raster extension → (nil, nil) — no S3 call
                        ├── Bytes → (data, nil)
                        ├── nil → markPending + (nil, .noSuchItem)
                        └── throw → mapThumbnailFetchError → (nil, mapped-NSError)
```

## Tests (17 total)

### ThumbnailFetchLimiterTests (4)
- `testAcquireBelowMaxDoesNotBlock` — single acquire under cap returns immediately
- `testAcquireAtMaxBlocksUntilRelease` — 5th acquire blocks until first release
- `testFiveConcurrentAcquiresOnFourSlotsSerializesOneWaiter` — exactly one waiter
- `testFIFOOrderingAcrossEightContenders` — release order matches enqueue order

### FetchThumbnailsTests (6)
- `testFetchThumbnailsRasterHitReturnsBytes` — payload bytes returned, no pending mark
- `testFetchThumbnailsRasterMissReturnsNoSuchItemAndMarksPending` — `.noSuchItem` + `.pending` write
- `testFetchThumbnailsNonRasterReturnsNilNoError` — `.pdf` skipped, no S3 call
- `testFetchThumbnailsFolderIdentifierReturnsNilNoError` — root + folder identifiers skipped
- `testFetchThumbnailsBoundedByLimiter` — 8 concurrent through 4-slot limiter, max-in-flight ≤ 4
- `testFetchThumbnailsDoesNotInvokeRendererOnConsumePath` — pins THUMB-23 (no render, no original download)

### FetchThumbnailsErrorMappingTests (7)
- `test404MapsToNoSuchItem` — verified via consume path (404 = silent nil)
- `test5xxMapsToServerUnreachable` — InternalError → `.serverUnreachable`
- `testSlowDownMapsToServerUnreachable` — SlowDown → `.serverUnreachable` (no inline retry per D-14)
- `testNetworkErrorMapsToServerUnreachable` — URLError.notConnectedToInternet → `.serverUnreachable`
- `testAuthErrorMapsToCannotSynchronize` — InvalidAccessKeyId → `.cannotSynchronize`
- `testUnknownErrorMapsToCannotSynchronize` — fallback for unknown errors
- `testNoCustomErrorDomainEverEscapes` — sweeps 16 error fixtures across S3 / URL / NSError / generic; every mapped error stays in `{NSFileProviderErrorDomain, NSCocoaErrorDomain}`

## Tasks completed

| Task | Description | Commit |
|------|-------------|--------|
| 1 (RED) | ThumbnailFetchLimiterTests + FetchThumbnailsTests + FetchThumbnailsErrorMappingTests | (commit pending in next push) |
| 2 (GREEN) | ThumbnailFetchLimiter actor + consumeThumbnail + mapThumbnailFetchError + cache-first fetchThumbnails rewrite | (commit pending in next push) |

(Commits land before Wave 3 spawns — see git log for canonical hashes.)

---

*Plan: 13-06*
*Completed: 2026-04-25*
