---
phase: 13-macos-generation-consumption-lifecycle
plan: 09
subsystem: thumbnails
tags: [thumbnails, bfs, backfill, orphan-sweep, fire-and-forget, swift6, sendable]

# Dependency graph
requires:
  - phase: 13
    provides: "DefaultSettings.Thumbnail.backfillBatchSize=5 + maxOrphanDeletesPerPass=50 (13-01), ThumbnailBackfillCoordinator with thermal/pause/cancel/strike (13-05), DS3S3Client+Thumbnails deleteThumbnail (Phase 12 silent-on-404), S3PathUtils.thumbnailKey/originalKey/isThumbnailKey (Phase 11), SharedData.loadThumbnailSettings + isDrivePaused"
provides:
  - "OrphanSweeper struct (Sendable) — recursive-list <drivePrefix>, filter via isThumbnailKey, set-diff against BFS-enumerated keys, bulk-delete capped at maxOrphanDeletesPerPass (50)"
  - "BFSThumbnailHookRunner — per-drive runner that owns the in-flight backfill Task handle and spawns coordinator.runBatch + sweeper.sweep as fire-and-forget Tasks"
  - "ThumbnailBackfillRunning + OrphanSweeping protocols — test-injection seams; production conformances live alongside the concrete types (same-file Sendable conformance for Swift 6 compliance)"
  - "BreadthFirstIndexer pass-tail integration — runThumbnailPassTailHooks invoked after synthesizeVirtualFoldersFromKeys; gated by ThumbnailSettings.enabled && !isDrivePaused; pause-flip detection cancels in-flight backfill"
  - "BreadthFirstIndexer.init now takes optional s3Client (DS3S3ClientProtocol) so the coordinator + sweeper can issue S3 ops without hopping through S3Lib's actor isolation"
affects:
  - "Phase 13 user-visible payoff — turns the silent Phase 11/12 substrate into an active backfill engine for existing content (Plan 13-07's upload hook handles new uploads; this plan handles the long tail)"
  - "Phase 14 (iOS generation) — iOS path gated out via #if os(macOS) on the pass-tail hook; iOS will replace BFS-driven backfill with BGProcessingTask + ForegroundBackfillDriver"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Per-drive runner with in-flight Task handle — BFSThumbnailHookRunner stores the most-recent backfill Task so a subsequent pause-flip can cancel it. NSLock guards the handle; cancellation is idempotent."
    - "Test-injection protocols + same-file Sendable conformance — ThumbnailBackfillRunning + OrphanSweeping declared in BFSThumbnailHookRunner.swift; conformances live in ThumbnailBackfillCoordinator.swift / OrphanSweeper.swift respectively (Swift 6 strict concurrency mandates same-file declaration for Sendable conformances; the conformance for the actor coordinator works because the actor-conformance declaration is in the runner file and the type is from another module — the OrphanSweeper case requires same-file because both are in the same module)"
    - "Recursive list + filter strategy — Phase 11 places .thumbnails/ per-folder (not at drive root), so the sweeper recursively lists drivePrefix capped at 1000 keys then filters via S3PathUtils.isThumbnailKey. Bounded per-pass work; BFS cadence handles long-tail cleanup"
    - "Pause-flip detection in the BFS loop — wasPaused bool tracks the previous pass's pause state; transition false→true triggers cancelInFlightBackfill. The poll-based design defers to the existing 5s pause-poll cadence rather than introducing a new observer"

key-files:
  created:
    - "DS3DriveProvider/OrphanSweeper.swift — struct OrphanSweeper: Sendable; sweep(bucket:drivePrefix:enumeratedKeys:); recursive list + isThumbnailKey filter + set-diff + bulk delete (50-cap); defensive skips for folder markers and unparseable keys; list/delete failures logged + swallowed"
    - "DS3DriveProvider/BFSThumbnailHookRunner.swift — final class @unchecked Sendable; runHooks(coordinator:sweeper:bucket:drivePrefix:enumeratedKeys:); cancelInFlightBackfill(); ThumbnailBackfillRunning + OrphanSweeping protocols; LastSpawnedTasks introspection for tests"
    - "DS3DriveProviderTests/OrphanSweepTests.swift — 7 tests (set-diff correctness, 50-cap, no-op when all originals exist, empty listing, non-thumbnail key skip, folder marker skip, list failure graceful) + OrphanSweepMockS3Client recording listObjects/deleteObject"
    - "DS3DriveProviderTests/BFSThumbnailHookTests.swift — 7 tests (pass-tail invocation against constant, pause skip via gate, disabled skip via gate, sweeper invocation w/ keys, sweep disabled-skip, fire-and-forget non-blocking, pause-flip cancellation) + private MockBackfillCoordinator + MockOrphanSweeper"
  modified:
    - "DS3DriveProvider/BreadthFirstIndexer.swift — added s3Client (optional) init param, lazy thumbnailCoordinator/orphanSweeper/thumbnailHookRunner, runThumbnailPassTailHooks(enumeratedKeys:) invoked at runOneBFSPass tail, pause-flip detection (wasPaused). Extracted processPrefix helper to keep runOneBFSPass within SwiftLint function-body length"
    - "DS3DriveProvider/FileProviderExtension+Lifecycle.swift — startBFSIndexer now passes self.s3Client into BreadthFirstIndexer init"
    - "DS3DriveProvider/OrphanSweeper.swift — added `: Sendable` to struct + same-file `extension OrphanSweeper: OrphanSweeping {}` conformance"
    - "DS3Drive.xcodeproj/project.pbxproj — added file refs for OrphanSweeper.swift, OrphanSweepTests.swift, BFSThumbnailHookRunner.swift, BFSThumbnailHookTests.swift; group entries (DS3DriveProvider + DS3DriveProviderTests groups); Sources-phase entries for both DS3DriveProvider Sources phases (main + tests-combined) and the DS3DriveProviderTests target. ID prefix `A130609...` per plan 09 naming convention"

key-decisions:
  - "Pass-tail hooks live in a separate runner type (BFSThumbnailHookRunner), not inline in BreadthFirstIndexer. Reason: lets the hook logic be unit-tested without standing up a real BFS pass. Tests inject MockBackfillCoordinator + MockOrphanSweeper conforming to the test-injection protocols; the indexer wires the production coordinator + sweeper. This trades 163 lines of runner overhead for 7 reliable tests with mock-asserted call counts."
  - "Pause-flip detection lives in BreadthFirstIndexer (the policy site that already polls SharedData.isDrivePaused), not in BFSThumbnailHookRunner. Reason: the runner is policy-agnostic (it spawns whatever the caller asks for); the indexer owns 'do we run hooks this pass?' policy. wasPaused: Bool field tracks the previous pass's verdict; false→true transition calls cancelInFlightBackfill before the gate skip-check. This is the BFS-side counterpart to Plan 13-05's coordinator-side iteration-boundary cancellation."
  - "OrphanSweeper does a RECURSIVE listing of drivePrefix (delimiter: nil) capped at 1000 keys, then filters via S3PathUtils.isThumbnailKey — NOT a literal `<drivePrefix>.thumbnails/` listing as the plan's prose suggested. Reason: Phase 11's S3PathUtils.thumbnailKey places .thumbnails/ PER-FOLDER (e.g. `prefix/photos/.thumbnails/foo.jpg`), not at drive root. A literal root-level `.thumbnails/` listing would miss every per-folder thumbnail. The 1000-key cap is intentionally permissive; the 50-delete cap is the hard rate-limit. (Deviation Rule 1 — see below.)"
  - "BreadthFirstIndexer.init takes an OPTIONAL s3Client. Reason: the existing call site in +Lifecycle.swift always passes self.s3Client, but making the parameter required would break the BFSThumbnailHookTests test harness which never instantiates a real BFS indexer. Default = nil; lazy thumbnailCoordinator/orphanSweeper guard `let s3Client else { return nil }`. When nil, runThumbnailPassTailHooks logs and skips."
  - "Same-file Sendable conformance: protocol OrphanSweeping declared in BFSThumbnailHookRunner.swift, conformance `extension OrphanSweeper: OrphanSweeping {}` declared in OrphanSweeper.swift. Reason: Swift 6 strict concurrency rejects cross-file Sendable conformances for non-final types unless the type is in a different module. Same-file declaration is the cleanest fix; alternative was @unchecked Sendable retroactive conformance, which loses Sendable-checking at the conformance site. Same pattern applies to ThumbnailBackfillCoordinator: ThumbnailBackfillRunning {} stays in BFSThumbnailHookRunner.swift because the coordinator is in a different module (DS3Lib) so cross-file conformance is allowed."
  - "Extracted processPrefix(_:allPassKeys:) helper from runOneBFSPass to satisfy SwiftLint's function_body_length (≤80 lines). The pass-tail hook callout added ~10 lines which pushed the outer function over the limit. The helper carves out the inner do-catch block (lists, upserts, prunes, signals); the outer loop now coordinates pause-poll, dequeue, and per-iteration sleep only. No behavior change."
  - "Test 1 asserts `XCTAssertEqual(captured.maxItems, DefaultSettings.Thumbnail.backfillBatchSize)` against the CONSTANT (not literal 5). Per the plan's must-haves: a future Plan 13-01 retune of backfillBatchSize must NOT silently break this test — assertion against the constant guarantees the wiring stays correct regardless of the constant's value."
  - "Tests 2/3/5 (pause skip, disabled skip, sweep disabled-skip) assert via a gate-policy helper `shouldRunPassTailHooks(thumbnailEnabled:isPaused:) -> Bool` rather than calling runHooks. Reason: the runner is a one-shot fire-and-forget mechanism; once you call runHooks the work happens unconditionally. The gate is an INVERSE contract — `the indexer DOESN'T call runHooks when paused/disabled` — and the cleanest way to test that contract without a real indexer is to test the gate-policy function the indexer uses. The function is identical to the gate inside BreadthFirstIndexer.runThumbnailPassTailHooks, so the test pins the policy."

patterns-established:
  - "Pattern: per-drive runner type owning lifetime-scoped state (in-flight Task handle) + test-injection protocols, with same-file Sendable conformance for the production conformer. Reusable for any future BFS-tail-hook expansion (Phase 14 may add iOS-specific hooks via a parallel runner)"
  - "Pattern: recursive-list-then-filter for namespace cleanup. When the namespace is per-folder (.thumbnails/, .trash/, etc.) and a literal-prefix listing would miss most of it, recursive list under drivePrefix + S3PathUtils filter is the correct shape. The 1000-key cap keeps per-pass work bounded; the rate-limit cap (50 deletes) is independent"
  - "Pattern: gate-policy helper function for testing inverse contracts. When the production code is `if gate { spawn() }`, you can test 'doesn't spawn when gated' by directly testing the gate function rather than fighting the spawn mechanism's fire-and-forget nature"

requirements-completed: [THUMB-15, THUMB-19, THUMB-21, THUMB-23]

# Metrics
duration: 60min
completed: 2026-04-26
---

# Phase 13 Plan 09: BFS-Driven Backfill + Orphan Sweep — Summary

**Wires the Phase 13 backfill engine to the BFS pass tail. Each successful BreadthFirstIndexer pass fires two fire-and-forget Tasks: one drives the per-drive ThumbnailBackfillCoordinator (maxItems = backfillBatchSize), the other runs an OrphanSweeper that set-diffs thumbnail keys against the BFS-enumerated original keys and bulk-deletes orphans capped at maxOrphanDeletesPerPass. Both gated by ThumbnailSettings.enabled + !isDrivePaused. Pause flips cancel any in-flight backfill Task. Together with Plan 13-07's upload hook, this is the difference between 'thumbnails appear for new uploads' and 'thumbnails progressively populate for existing content'.**

## Performance

- **Duration:** ~60 min
- **Started:** 2026-04-26
- **Completed:** 2026-04-26
- **Tasks:** 2 (Task 1: OrphanSweeper + tests in TDD-RED-then-GREEN; Task 2: BFSThumbnailHookRunner + indexer wiring + tests)
- **Files created:** 4 (OrphanSweeper, BFSThumbnailHookRunner, OrphanSweepTests, BFSThumbnailHookTests)
- **Files modified:** 3 (BreadthFirstIndexer, FileProviderExtension+Lifecycle, project.pbxproj — plus the same-file Sendable touch-up to OrphanSweeper.swift)
- **Tests added:** 14 (7 OrphanSweepTests + 7 BFSThumbnailHookTests)

## Accomplishments

- `OrphanSweeper` ships in DS3DriveProvider as a `Sendable` struct. `sweep(bucket:drivePrefix:enumeratedKeys:)` recursively lists drivePrefix (1000-key cap), filters via `S3PathUtils.isThumbnailKey`, computes set-difference against `enumeratedKeys`, and deletes orphans capped at `DefaultSettings.Thumbnail.maxOrphanDeletesPerPass` (50). Defensive skips for folder markers and unparseable keys; list and per-item delete failures are logged and never abort the sweep.
- `BFSThumbnailHookRunner` (per-drive) owns the in-flight backfill Task handle and spawns coordinator + sweeper as fire-and-forget Tasks. `cancelInFlightBackfill()` is called by the BFS indexer on pause-flip. `ThumbnailBackfillRunning` + `OrphanSweeping` protocols give tests an injection seam without touching the real coordinator/sweeper.
- `BreadthFirstIndexer` now lazily builds a `ThumbnailBackfillCoordinator` + `OrphanSweeper` per drive (D-16) and invokes `runThumbnailPassTailHooks(enumeratedKeys:)` at the tail of `runOneBFSPass` after virtual-folder synthesis. The hook is gated by `ThumbnailSettings.enabled == true && !isDrivePaused`. Pause-flip detection between passes (`wasPaused` bool tracking the previous poll) cancels any in-flight backfill before the next gate check.
- `BreadthFirstIndexer.init` accepts an optional `s3Client: any DS3S3ClientProtocol`; `FileProviderExtension+Lifecycle.startBFSIndexer` wires `self.s3Client`. The optional default keeps the indexer constructable in test contexts that don't need backfill.
- `runOneBFSPass` was refactored to extract `processPrefix(_:allPassKeys:)` (the inner per-prefix do-catch block). The outer loop now coordinates pause-poll, dequeue, per-iteration sleep, and pass-tail hooks. SwiftLint function_body_length compliant; behavior unchanged.
- 14 new tests passing. All 49 prior thumbnail tests still passing (BFSThumbnailHookTests + OrphanSweepTests + UploadHookTests + CascadeDeleteTests + CascadeRenameTests + FetchThumbnailsTests + FetchThumbnailsErrorMappingTests + ThumbnailFetchLimiterTests).
- macOS build clean. iOS build clean (the pass-tail hook is wrapped in `#if os(macOS)`).
- No Swift 6 strict-concurrency warnings.

## Architecture

```
runOneBFSPass tail
       │
       ├── synthesizeVirtualFoldersFromKeys(allPassKeys)
       │
       └── runThumbnailPassTailHooks(enumeratedKeys: allPassKeys)        [#if os(macOS)]
                │
                ├── pauseFlipDetect: if !wasPaused && isPaused now → cancelInFlightBackfill
                │
                ├── gate: thumbnailSettings.enabled && !isPaused → if false, return
                │
                └── BFSThumbnailHookRunner.runHooks(coordinator, sweeper, ...)
                         ├── Task { try? await coordinator.runBatch(maxItems: backfillBatchSize) }   ── stored in inFlightBackfillTask
                         └── Task { _ = await sweeper.sweep(bucket, drivePrefix, enumeratedKeys) }
```

Both Tasks return immediately to the BFS pass tail — pass duration is not extended (D-17). The coordinator iterates its own pending-thumbnail batch sequentially with thermal/pause/cancellation gates (Plan 13-05). The sweeper does ONE recursive S3 list + up to 50 deleteThumbnail calls in this pass; remaining orphans wait for the next pass.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug in plan] Sweeper listing strategy: per-folder thumbnails, not root-level**

- **Found during:** Task 1 design — reading the plan's `<action>` step A vs. Phase 11's `S3PathUtils.thumbnailKey` implementation.
- **Issue:** The plan's prose said "list `<drivePrefix>.thumbnails/` (max 1000)". This assumes a single root-level `.thumbnails/` namespace. But Phase 11's `thumbnailKey` places `.thumbnails/` **per-folder** (e.g. `prefix/photos/.thumbnails/foo.jpg`, not `prefix/.thumbnails/photos/foo.jpg`). A literal `<drivePrefix>.thumbnails/` listing would miss every per-folder thumbnail and only catch root-level ones — which would defeat the whole orphan sweep.
- **Fix:** OrphanSweeper recursively lists `<drivePrefix>` (delimiter: nil) capped at 1000 keys, then filters returned keys via `S3PathUtils.isThumbnailKey`. Bounded per-pass work; correct coverage of per-folder thumbnails. The 50-delete cap is the hard rate-limit and is unchanged from the plan.
- **Files modified:** `DS3DriveProvider/OrphanSweeper.swift`
- **Commit:** `f84bd6c`

**2. [Rule 3 - Blocking issue] BreadthFirstIndexer needs direct s3Client (not just s3Lib actor)**

- **Found during:** Task 2 — `ThumbnailBackfillCoordinator.init` requires `s3Client: any DS3S3ClientProtocol`. The indexer only had access to `s3Lib: S3Lib` (an actor). Reaching `s3Lib.client` requires `await` and would force every coordinator/sweep call through the actor isolation domain.
- **Fix:** Added `s3Client: (any DS3S3ClientProtocol)? = nil` to `BreadthFirstIndexer.init`. `FileProviderExtension+Lifecycle.startBFSIndexer` passes `self.s3Client`. Optional + default-nil keeps backward compatibility and allows a coordinator-less indexer in test contexts.
- **Files modified:** `DS3DriveProvider/BreadthFirstIndexer.swift`, `DS3DriveProvider/FileProviderExtension+Lifecycle.swift`
- **Commit:** `69acc01`

**3. [Rule 1 - Bug] Same-file Sendable conformance for OrphanSweeping**

- **Found during:** Task 2 build — Swift 6 strict concurrency rejected `extension OrphanSweeper: OrphanSweeping {}` declared in `BFSThumbnailHookRunner.swift`. Error: "conformance to 'Sendable' must occur in the same source file as struct 'OrphanSweeper'".
- **Fix:** Moved the `extension OrphanSweeper: OrphanSweeping {}` declaration into `OrphanSweeper.swift` (same file as the struct). The protocol declaration stays in `BFSThumbnailHookRunner.swift`. Same-module visibility lets the conformance see the protocol. The `ThumbnailBackfillCoordinator: ThumbnailBackfillRunning` conformance does NOT need this fix — it lives in a different module (DS3Lib), where cross-file conformance is allowed.
- **Files modified:** `DS3DriveProvider/OrphanSweeper.swift`, `DS3DriveProvider/BFSThumbnailHookRunner.swift`
- **Commit:** `69acc01`

**4. [Rule 3 - SwiftLint] runOneBFSPass body length over limit**

- **Found during:** Task 2 commit — SwiftLint function_body_length warning: 83 lines > 80 limit. The pass-tail hook callout added ~10 lines.
- **Fix:** Extracted the inner per-prefix do-catch block (~70 lines) into `processPrefix(_:allPassKeys:)`. The outer `runOneBFSPass` now coordinates pause-poll, dequeue, per-iteration sleep, virtual-folder synthesis, and pass-tail hooks only. Behavior unchanged.
- **Files modified:** `DS3DriveProvider/BreadthFirstIndexer.swift`
- **Commit:** `69acc01`

### Authentication Gates

None.

### Out-of-Scope Discoveries

- **`DS3DriveProviderTests/S3ItemTests` has 2 PRE-EXISTING failures** (`testDecorationCloudOnlyDefault` and `testDecorationSynced`). Verified pre-Plan-13-09 by `git stash`-ing changes and re-running — same 2 tests fail at HEAD before this plan. Out of scope; not touched. To be tracked separately.

## Threat Mitigations

| Threat ID | Disposition | How addressed |
|-----------|-------------|---------------|
| T-13-41 (false-positive orphan delete) | mitigate | Set-diff requires enumeratedKeys to be a fully-built BFS pass snapshot (collected before the pass-tail hook runs); 50-cap bounds blast radius if a bug ships; recursive-list-+-filter strategy uses Phase 11's canonical `isThumbnailKey` predicate as the only "this is a thumb" decision point. |
| T-13-42 (re-enable storm slow cleanup) | accept | Documented in plan D-26. Natural BFS cadence (~60s/pass × 50 deletes/pass) handles long tail. |
| T-13-43 (listObjectsV2 exposes filenames in S3 access logs) | accept | Already exposed by existing BFS enumerations; no new surface. |
| T-13-44 (wrong drive's keys passed to sweeper) | mitigate | Per-drive indexer instance owns per-drive runner, coordinator, and sweeper. bucket + prefix come from the same `drive.syncAnchor` reference held by the indexer init. No cross-drive data flow possible. |
| T-13-45 (pause-flip too late, in-flight PUT corrupts) | accept | Plan 13-05 design: in-flight PUT completes; cancellation is at iteration boundaries. Pitfall 7. |
| T-13-46 (coordinator runs unbounded across drives) | mitigate | One coordinator per drive (D-16); one in-flight Task per runner; pause cancels. No cross-drive amplification. |
| T-13-47 (BreadthFirstIndexer hits SwiftLint file-length limit) | mitigate | Pre-change 273 lines, post-change 380 lines. Limit is 600 (warning) / 1000 (error). 220 lines of headroom remaining. |

## Self-Check: PASSED

Created files:
- FOUND: `/Users/marmos91/Projects/cubbit-ds3-drive/DS3DriveProvider/OrphanSweeper.swift`
- FOUND: `/Users/marmos91/Projects/cubbit-ds3-drive/DS3DriveProvider/BFSThumbnailHookRunner.swift`
- FOUND: `/Users/marmos91/Projects/cubbit-ds3-drive/DS3DriveProviderTests/OrphanSweepTests.swift`
- FOUND: `/Users/marmos91/Projects/cubbit-ds3-drive/DS3DriveProviderTests/BFSThumbnailHookTests.swift`

Commits:
- FOUND: `f84bd6c` (Task 1: OrphanSweeper type + tests)
- FOUND: `69acc01` (Task 2: BFS pass-tail coordinator hook + orphan sweep)

Acceptance criteria (per plan):
- `grep -c ThumbnailBackfillCoordinator BreadthFirstIndexer.swift` = 2 ≥ 2 ✓
- `grep -c OrphanSweeper BreadthFirstIndexer.swift` = 2 ≥ 2 ✓
- `grep -c DefaultSettings.Thumbnail.backfillBatchSize` (BFSThumbnailHookRunner.swift) = 1 ≥ 1 ✓
- `grep -c loadThumbnailSettings BreadthFirstIndexer.swift` = 2 ≥ 1 ✓
- `grep -c isDrivePaused BreadthFirstIndexer.swift` = 3 ≥ 1 ✓
- `grep -c inFlightBackfillTask\|cancelInFlightBackfill BFSThumbnailHookRunner.swift` = 9 ≥ 2 ✓
- `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` exits 0 ✓
- `xcodebuild test -only-testing:DS3DriveProviderTests/OrphanSweepTests` exits 0 (7/7 pass) ✓
- `xcodebuild test -only-testing:DS3DriveProviderTests/BFSThumbnailHookTests` exits 0 (7/7 pass) ✓
- All prior thumbnail tests still green: 49/49 PASS (S3ItemTests pre-existing failures are unrelated) ✓
