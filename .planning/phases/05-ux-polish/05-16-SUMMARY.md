---
phase: 05-ux-polish
plan: 16
subsystem: file-provider
tags: [s3, throttling, resilience, enumerator, file-provider]

# Dependency graph
requires:
  - phase: 05-ux-polish
    provides: "MetadataStore-backed enumeration fallback pattern"
provides:
  - "Per-bucket concurrency limiter for ListObjectsV2"
  - "Exponential backoff + jitter retry on S3 SlowDown/503"
  - "Throttle-aware enumerator error surfacing (no silent partial enumerations)"
  - "Delayed re-enumeration scheduling after throttle exhaustion"
affects: [05-08]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "BucketListingLimiter actor (per-bucket FIFO semaphore, max 4)"
    - "listWithRetries: retry SlowDown/ServiceUnavailable/RequestTimeout/InternalError"
    - "AWSErrorType.isThrottling extension for throttle-aware fallback branching"

key-files:
  created:
    - "DS3DriveProvider/BucketListingLimiter.swift"
  modified:
    - "DS3DriveProvider/S3Lib.swift"
    - "DS3DriveProvider/S3Enumerator.swift"
    - "DS3DriveProvider/FileProviderExtension+Errors.swift"
    - "DS3Drive.xcodeproj/project.pbxproj"

key-decisions:
  - "Single chokepoint fix: all provider listings funnel through S3Lib.listS3Items, so retries + limiter live there — not scattered across 4 call sites as the plan initially envisioned"
  - "On throttle exhaustion, skip MetadataStore fallback to avoid serving stale/partial enumerations (Gap 28 root cause)"
  - "30s delayed re-enumeration via signalEnumerator nudges Finder to retry sooner than the system's default backoff"

patterns-established:
  - "Per-bucket concurrency caps for list-heavy S3 operations"
  - "Throttle error classification via AWSErrorType.isThrottling"

requirements-completed: [SYNC-01, SYNC-04]

# Metrics
duration: ~25min
completed: 2026-04-07
---

# Phase 05 Plan 16: S3 SlowDown Hardening Summary

**Retry + per-bucket concurrency cap for ListObjectsV2; surface throttle errors instead of silently masking with empty MetadataStore fallback (closes Gap 28).**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-04-07T13:51:00Z (approx)
- **Completed:** 2026-04-07T14:16:00Z (approx)
- **Tasks:** 2
- **Files created:** 1
- **Files modified:** 4 (incl. project.pbxproj)
- **Commits:** 2

## Accomplishments

- Added `BucketListingLimiter` actor: per-bucket FIFO semaphore, default `maxConcurrent = 4`. Fair handoff — releasing hands the slot to the next waiter without dropping `inFlight` counts, preventing wake storms.
- Added `S3Lib.listWithRetries` helper: exponential backoff (0.5 * 2^attempt) + 0..0.5s jitter, up to 5 attempts, classifying SlowDown / ServiceUnavailable / RequestTimeout / InternalError as transient.
- All provider listings now route through the single chokepoint: `S3Lib.listS3Items` → `listWithRetries` → `BucketListingLimiter` → `DS3S3Client.listObjects`. `grep -rn "listObjectsV2" DS3DriveProvider/` returns zero direct calls.
- `S3Enumerator` no longer falls back to MetadataStore on throttle exhaustion — it surfaces the AWS error via `toFileProviderError()` (maps SlowDown → `.serverUnreachable` so the system retries with backoff) and schedules a 30s delayed `signalEnumerator` nudge.
- Added `AWSErrorType.isThrottling` extension for reuse-friendly throttle classification.
- Improved success log line to `.info` level with object/prefix counts so future debug sessions can distinguish "empty bucket" from "partial enumeration".
- Registered `BucketListingLimiter.swift` in both DS3DriveProvider build phases (macOS + iOS targets).

## Task Commits

| # | Task | Hash | Type |
|---|------|------|------|
| 1 | BucketListingLimiter actor + listWithRetries helper + pbxproj registration | `457dabb` | feat |
| 2 | Throttle-aware fallback in S3Enumerator + AWSErrorType.isThrottling | `7aff85e` | fix |

## Files Created/Modified

- **Created:** `DS3DriveProvider/BucketListingLimiter.swift` — Actor-based per-bucket FIFO semaphore. Direct slot handoff to waiters on release.
- **Modified:** `DS3DriveProvider/S3Lib.swift` — Added `ListRequest` parameter bundle, `maxListRetries = 5`, `listWithRetries` static helper, success log upgrade to `.info` with count breakdown.
- **Modified:** `DS3DriveProvider/S3Enumerator.swift` — Both enumerate paths (recursive + delimited) now bypass MetadataStore fallback on throttle errors and call `scheduleDelayedReEnumeration` to nudge a retry in 30s.
- **Modified:** `DS3DriveProvider/FileProviderExtension+Errors.swift` — Added `AWSErrorType.isThrottling` extension.
- **Modified:** `DS3Drive.xcodeproj/project.pbxproj` — Registered new file in both DS3DriveProvider Sources build phases + group children.

## Decisions Made

- **Single chokepoint vs. 4 wrapped call sites.** The plan envisioned wrapping direct `s3.listObjectsV2(input)` calls in S3Enumerator, BreadthFirstIndexer, and TrashS3Enumerator. Reality: the codebase only has ONE direct call in `DS3S3Client.listObjects` (DS3Lib), and every provider listing (enumerator, indexer, trash, sync-engine adapter, lifecycle handlers, deleteFolder, copyFolder, emptyTrash) goes through `S3Lib.listS3Items`. Placing retries + limiter at the `listS3Items` chokepoint automatically covers all paths with one implementation.
- **Skip cache fallback on throttle exhaustion.** Gap 28 root cause was the `catch` block swallowing SlowDown and serving an empty MetadataStore. Now the enumerator surfaces the error so macOS File Provider maps SlowDown → `.serverUnreachable` and retries with exponential backoff.
- **FIFO waiter handoff.** `BucketListingLimiter.release()` hands the slot directly to the next waiter rather than decrementing `inFlight`, avoiding a classic wake-many-yet-one-runs race.
- **Throttle classification includes ServiceUnavailable/RequestTimeout/InternalError.** Not just SlowDown — Soto may surface 503/504-class responses under these codes and they're all transient.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Architectural] Plan assumed 4 direct `listObjectsV2` call sites; reality is a single chokepoint**

- **Found during:** Task 1 (reading S3Lib.swift and provider grep)
- **Issue:** Plan's Task 2 prescribed wrapping `s3.listObjectsV2(input)` calls in S3Enumerator, BreadthFirstIndexer, and TrashS3Enumerator. That code pattern doesn't exist in the provider — all three already go through `S3Lib.listS3Items` → `DS3S3Client.listObjects`. Only one direct call exists, in DS3Lib.
- **Fix:** Added retries + limiter at the `listS3Items` chokepoint. One change, identical correctness properties, zero duplication.
- **Files modified:** `DS3DriveProvider/S3Lib.swift`
- **Verification:** `grep -rn "listObjectsV2" DS3DriveProvider/` returns zero matches (non-test, non-worktree).
- **Committed in:** 457dabb

**2. [Rule 1 - Bug] Plan's example `listWithRetries` signature would trip SwiftLint `function_parameter_count` (7 > 6)**

- **Found during:** Task 1 commit (pre-commit SwiftLint check)
- **Issue:** Plan's signature took 7 parameters (bucket, prefix, delimiter, maxKeys, continuationToken, client, logger). Repo SwiftLint limit is 6.
- **Fix:** Bundled the listing parameters into a nested `S3Lib.ListRequest` struct; function signature is now 4 params `(request, client, logger, maxAttempts)`.
- **Committed in:** 457dabb

**3. [Rule 2 - Missing critical] Plan's example uses `AWSResponseError.statusCode` which is not exposed on Soto v6 `AWSErrorType`**

- **Found during:** Task 1 implementation
- **Issue:** `AWSErrorType` protocol only exposes `errorCode: String`, not `statusCode: Int`. The plan's `error.statusCode == 503` check wouldn't compile.
- **Fix:** Match on error codes only: `SlowDown`, `ServiceUnavailable`, `RequestTimeout`, `InternalError`. These collectively cover all transient S3 conditions the plan was trying to catch by matching 503.
- **Committed in:** 457dabb

**4. [Rule 2 - Missing critical] BucketListingLimiter.swift not auto-registered in Xcode project**

- **Found during:** Task 1 build verification
- **Issue:** Build error `cannot find 'BucketListingLimiter' in scope`. Xcode projects require explicit PBXFileReference + PBXBuildFile + group membership + Sources phase entries for new files.
- **Fix:** Added 5 entries in `project.pbxproj` (file reference, 2 build files for macOS + iOS targets, group children entry, 2 Sources build phase entries).
- **Committed in:** 457dabb

---

**Total deviations:** 4 auto-fixed (1 architectural, 1 bug, 2 missing critical)
**Impact on plan:** Deviation #1 simplified the fix substantially without loss of correctness. #2-#4 were mechanical adaptations to repo tooling realities.

## Issues Encountered

- Transient build.db lock from the parallel 05-15 executor — resolved by retry after a short wait.
- Initial build failure reported errors only in `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` (Plan 05-15's territory). My scope files compiled clean throughout. Final full build after 05-15 resolved its errors: `** BUILD SUCCEEDED **`.

## Known Stubs

None.

## Threat Flags

None — this plan hardens an existing network surface, does not add new endpoints, auth paths, or trust boundaries.

## Verification

- **Build:** `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination "platform=macOS" build` → `** BUILD SUCCEEDED **`
- **Grep audit:** `rg "listObjectsV2|\.listObjectsV2\(" DS3DriveProvider/` → zero hits. Every provider listing funnels through `S3Lib.listS3Items` → `listWithRetries` → `BucketListingLimiter` → `DS3S3Client.listObjects`.
- **Pre-commit hooks:** SwiftFormat + SwiftLint passed on both commits.
- **Runtime verification (manual, deferred to next test mount):** Clear caches per CLAUDE.md extension recovery sequence, mount `personal-moschet` bucket fresh, confirm all 3 top-level folders (Automatic upload, Cubbit, Personal) visible in Finder and extension logs show `S3 SlowDown on prefix <root>, retry N/5 after XXs` followed by successful `Listed N items` — not hard failures.

## Gap 28 — Closure

- **Root cause:** Concurrent initial-mount listings (BFS + per-folder enumerator + trash enumerator) hit bucket root, S3 returned 503 SlowDown, empty MetadataStore fallback masked the missing folder.
- **Fix pillar 1:** `BucketListingLimiter` caps concurrent listings at 4 per bucket. Prevents initial mount burst from triggering SlowDown in the first place.
- **Fix pillar 2:** `listWithRetries` retries SlowDown up to 5 times with exponential backoff + jitter (1.0-1.5s, 2.0-2.5s, 4.0-4.5s, 8.0-8.5s, 16.0-16.5s). Tolerates bursts even if the limiter momentarily lets through a congested request.
- **Fix pillar 3:** On exhausted retries, enumerator skips the MetadataStore fallback and surfaces a `serverUnreachable` error. macOS File Provider system then retries with its own backoff, and a 30s `signalEnumerator` nudge accelerates recovery.
- **Status:** Code-complete. Runtime reproduction pending user test.

## Self-Check: PASSED

- [x] `DS3DriveProvider/BucketListingLimiter.swift` exists
- [x] `S3Lib.listWithRetries` exists (grep: `git grep -n "listWithRetries" DS3DriveProvider/S3Lib.swift` → 2 hits)
- [x] `BucketListingLimiter` referenced from listWithRetries (1 hit)
- [x] `AWSErrorType.isThrottling` extension exists
- [x] Commit `457dabb` exists in git log
- [x] Commit `7aff85e` exists in git log
- [x] Zero direct `listObjectsV2` calls in DS3DriveProvider/
- [x] Build green: `** BUILD SUCCEEDED **`

---
*Phase: 05-ux-polish*
*Completed: 2026-04-07*
