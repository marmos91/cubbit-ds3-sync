---
phase: 13-macos-generation-consumption-lifecycle
plan: 05
subsystem: thumbnails
tags:
  - thumbnails
  - backfill
  - actor
  - macos
  - cancellation
  - thermal
requirements:
  - THUMB-15
  - THUMB-20
  - THUMB-21
  - THUMB-23
dependency-graph:
  requires:
    - 13-01  # DefaultSettings.Thumbnail constants (maxFailStrikes)
    - 13-04  # MetadataStore.setThumbnailFailure (3-strike rule)
    - 12-05  # ThumbnailBackfillCoordinator scaffold (Phase 12)
  provides:
    - ThumbnailBackfillCoordinator thermal gating (D-19)
    - ThumbnailBackfillCoordinator pause-aware cancellation (D-20)
    - ThumbnailBackfillCoordinator.cancelInFlight() API (D-20)
    - ThumbnailBackfillCoordinator strike-rule retrofit (D-29 / Plan 13-04)
  affects:
    - 13-09  # BFS hook will wire coordinator.runBatch() and cancelInFlight()
tech-stack:
  added:
    - "ProcessInfo.thermalState (read in coordinator entry)"
  patterns:
    - "@Sendable closure injection for testability (thermalStateProvider, pauseProvider)"
    - "Two-channel cancellation (outer-Task structured + cancelInFlight() flag)"
    - "Pre-phase Task.checkCancellation() boundaries; never during PUT (D-20)"
key-files:
  created: []
  modified:
    - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift
    - DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift
decisions:
  - "Inject thermalStateProvider closure rather than reading ProcessInfo directly so unit tests can simulate .serious / .critical without real thermal pressure."
  - "Inject pauseProvider closure rather than calling SharedData.default().isDrivePaused() directly — App Group container is unavailable in unit-test sandbox."
  - "Use a Bool flag (`externalCancellationRequested`) for cancelInFlight() instead of wrapping runBatch in a child Task. The earlier child-Task design dropped outer-Task cancellation propagation because Task {} creates a new top-level cancellation context. The flag observed at every iteration boundary alongside `Task.checkCancellation()` cleanly handles both cancellation paths."
  - "Cancellation is NOT a failure: the loop breaks before invoking the strike helper, so `thumbnailFailCount` stays untouched on cancelled items. This was explicitly verified via `testCancelInFlightDoesNotIncrementStrike`."
  - "PUT is never cancelled mid-flight (D-20): cancellation checks fire BEFORE `getObject` and BEFORE `putThumbnail`. Once a PUT has started, the coordinator lets it complete to avoid uploading a partial thumbnail."
metrics:
  duration: ~7 minutes
  completed: 2026-04-25
  tasks-completed: 2
  files-modified: 3
  tests-added: 8
  tests-total-passing: 10
---

# Phase 13 Plan 05: ThumbnailBackfillCoordinator Lifecycle (Thermal + Pause + Cancel + Strike) Summary

Extended the Phase 12 `ThumbnailBackfillCoordinator` actor scaffold with the four
Phase 13 lifecycle behaviors — thermal gating (`ProcessInfo.thermalState >= .serious`
short-circuits the batch), pause-aware skipping (entry + per-iteration check
through an injectable `pauseProvider`), external-Task cancellation cooperation
(`Task.checkCancellation()` between phases plus a `cancelInFlight()` flag-based API),
and strike-rule integration (render-nil and PUT-throw failures route through
`MetadataStore.setThumbnailFailure` so the 3-strike terminal `.failed` transition
fires per Plan 13-04 D-29). All 10 unit tests (2 Phase 12 baseline + 8 Phase 13-05
extensions) pass; iOS and macOS builds remain green; full DS3Lib suite (543 tests)
shows zero regressions.

## Tasks Completed

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | RED: extend coordinator tests for thermal / pause / cancel / strike | `46c18f5` | DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift |
| 2 | GREEN: coordinator thermal-gate + pause-aware cancellation + strike integration | `660c07b` | DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift, DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift, DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift |

## Implementation Highlights

### Injection Points (added to `init`)

```swift
public init(
    metadataStore: MetadataStore,
    s3Client: any DS3S3ClientProtocol,
    drive: DS3Drive,
    thermalStateProvider: @Sendable @escaping () -> ProcessInfo.ThermalState = {
        ProcessInfo.processInfo.thermalState
    },
    pauseProvider: @Sendable @escaping (UUID) -> Bool = { driveId in
        (try? SharedData.default().isDrivePaused(driveId)) ?? false
    }
)
```

- Defaults preserve the Phase 12 3-arg call sites — no caller changes.
- Tests pass simple closures returning fixed thermal / pause states.

### Thermal Gate (D-19)

Single read at function entry; `.serious` and `.critical` both short-circuit
with a zero `BatchResult` — no S3 calls, no metadata writes.

### Pause Gate (D-20)

Two checkpoints:
1. **At `runBatch` entry** — same posture as the thermal gate.
2. **At the head of every item iteration** — observable mid-batch pause flips.
   Exits cleanly via `break`, no strike-count side effect on the unprocessed tail.

### Cancellation Lanes (D-20)

Two ways for an external caller to stop the in-flight batch:

1. **Outer-Task cancellation (Swift Concurrency native).** Caller wraps `runBatch`
   in `Task { try? await coordinator.runBatch(...) }` and calls `task.cancel()`.
   The coordinator's `Task.checkCancellation()` calls inside the loop and
   `processItem` throw a `CancellationError`, which is caught and translated to
   a clean break.
2. **`cancelInFlight()` API.** External code (BFS hook in Plan 13-09) calls
   `await coordinator.cancelInFlight()`, which sets `externalCancellationRequested`.
   The flag is observed at the iteration boundary AND at each phase boundary
   inside `processItem`.

`Task.checkCancellation()` is called BEFORE `getObject` and BEFORE `putThumbnail`,
**never DURING** — D-20 mandates that an in-flight PUT must complete to avoid
uploading a partial thumbnail.

Cancellation is NOT a failure: the strike helper is never invoked when the
short-circuit fires from cancellation. Verified by
`testCancelInFlightDoesNotIncrementStrike` — after cancel, every seeded row's
`thumbnailFailCount == 0`.

### Strike-Rule Integration (D-29 / Plan 13-04)

Replaced the Phase 12 placeholder `.failed` direct-write with the 3-strike-aware
`recordFailure(_:)` helper that calls `metadataStore.setThumbnailFailure(...)`.
Failure paths covered:

- Temp file alloc failure
- `getObject` throw (non-cancellation)
- `ThumbnailRenderer.renderJPEG` returns nil
- Missing source ETag
- `putThumbnail` throw (non-cancellation)

All five paths now go through `setThumbnailFailure`, increasing
`thumbnailFailCount`. Below threshold (`< 3`) the row stays `.pending` so
subsequent BFS passes retry. At the boundary (`>= 3`) the row flips to terminal
`.failed`, draining out of `fetchPendingThumbnails` per D-30.

Verified by `testRunBatchOnRendererNilIncrementsStrike` (count: 0 → 1; status
stays `.pending`) and `testRunBatchAfterThreeFailuresMarksFailed` (count: 2 → 3;
status flips to `.failed`; subsequent runBatch makes ZERO S3 calls because the
row no longer satisfies the `fetchPendingThumbnails` predicate).

## Tests

**File:** `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift`
**Total tests:** 10 (2 Phase 12 baseline preserved + 8 Phase 13-05 added)
**Status:** all green (`swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinatorTests` → `Executed 10 tests, with 0 failures`)

| # | Test | Phase 13-05 Behavior Covered |
|---|------|------------------------------|
| 1 | `testRunBatchOnEmptyStoreReturnsZeroCounts` | Phase 12 baseline (preserved) |
| 2 | `testRunBatchOnEmptyStoreMakesNoS3Calls` | Phase 12 baseline (preserved) |
| 3 | `testRunBatchOnRendererNilIncrementsStrike` | D-29 strike-helper integration on render-nil |
| 4 | `testRunBatchAfterThreeFailuresMarksFailed` | D-29 boundary at count == 3 + D-30 terminal exclusion |
| 5 | `testRunBatchOnPausedDriveReturnsZero` | D-20 pause gate at entry |
| 6 | `testRunBatchOnNormalThermalProcessesItems` | D-19 happy-path under `.nominal` thermal |
| 7 | `testRunBatchOnSeriousThermalReturnsZero` | D-19 thermal bail at `.serious` |
| 8 | `testRunBatchOnCriticalThermalReturnsZero` | D-19 thermal bail at `.critical` |
| 9 | `testCancelInFlightDoesNotIncrementStrike` | D-20 outer-Task cancellation + cancellation-is-not-a-failure |
| 10 | `testCancelInFlightAPIStopsBatch` | D-20 `cancelInFlight()` API + post-cancel reusability |

### Test Infrastructure Addition

Added `getObjectDelayNanos: UInt64` to `MockDS3S3Client` so cancellation tests
have a deterministic mid-batch window:

```swift
mock.getObjectDelayNanos = 200_000_000  // 200 ms per download
let task = Task { try? await coordinator.runBatch(maxItems: 5) }
try await Task.sleep(for: .milliseconds(50))
task.cancel()
_ = await task.value
```

5 items × 200 ms = 1 s of inflated runtime, leaving ample window for `task.cancel()`
to land before the loop completes. The delay is opt-in (default 0) so the existing
mock callers are unaffected.

## Verification

| Check | Result |
|-------|--------|
| `swift test --package-path DS3Lib --filter ThumbnailBackfillCoordinatorTests` | 10/10 pass |
| `swift test --package-path DS3Lib --filter "ThumbnailBackfillCoordinatorTests\|ThumbnailStrikeRuleTests\|ThumbnailUploaderTests"` | 22/22 pass |
| `swift test --package-path DS3Lib` (full suite) | 543/543 pass, 31 skipped, 0 failures |
| `xcodebuild build -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator'` | green |
| `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` | green (only destination disambiguation warnings) |
| `grep -c "thermalState" ...Coordinator.swift` | 10 (≥ 2 required) |
| `grep -c "pauseProvider(drive.id)" ...Coordinator.swift` | 3 (≥ 2 required: entry + per-iteration) |
| `grep -c "Task.checkCancellation" ...Coordinator.swift` | 6 (≥ 2 required: download + PUT boundaries) |
| `grep -c "setThumbnailFailure" ...Coordinator.swift` | 3 (≥ 1 required) |
| `grep -c "func test" ...CoordinatorTests.swift` | 10 (≥ 8 required) |
| Coordinator file length | 353 lines (SwiftLint warning at 600) |

## Acceptance Criteria

- [x] `runBatch` skips on `thermalState >= .serious` (single read at entry)
- [x] `runBatch` skips at entry + breaks loop iteration when paused
- [x] `Task.checkCancellation()` BEFORE download, BEFORE PUT (never during)
- [x] Render-nil + PUT-throw failure paths route through `setThumbnailFailure`
- [x] External Task cancellation cleanly stops coordinator at iteration boundary
- [x] Phase 12 baseline tests (2) + Plan 13-05 tests (8) all green; total = 10
- [x] iOS branch unchanged; iOS build green
- [x] No new Swift 6 strict-concurrency warnings

## Deviations from Plan

### Auto-fixed: Cancellation design (Rule 1 / Rule 2)

**Found during:** Task 2 GREEN — initial implementation wrapped `runBatch` body
in a child Task and stored the Task handle for `cancelInFlight()`. This worked
for the `cancelInFlight()` API test but broke outer-Task cancellation: a `Task {}`
inside an actor method creates a new top-level cancellation context that does
NOT inherit cancellation from the enclosing Task. So `task.cancel()` on the
caller's outer Task left the inner work running to completion.

**Fix:** Replaced the child-Task design with a `Bool` flag
(`externalCancellationRequested`) checked at every iteration / phase boundary
alongside `Task.checkCancellation()`. The flag handles `cancelInFlight()`;
`Task.checkCancellation()` handles outer-Task cancellation. Both paths converge
on the same `return .cancelled` / `break` shortcut.

**Files modified:** `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift`
**Commit:** `660c07b` (single Task 2 commit incorporating the design correction)

### Auto-added: `MockDS3S3Client.getObjectDelayNanos` knob (Rule 2)

**Found during:** Task 2 GREEN — initial cancellation tests used a 50 ms
`Task.sleep` to provide a window for `task.cancel()` to land, but the mock's
`getObject` returns instantly so all 5 items finished processing before the
50 ms sleep elapsed.

**Fix:** Added an opt-in `getObjectDelayNanos: UInt64 = 0` field to
`MockDS3S3Client`; `getObject(toFile:)` calls `Task.sleep(nanoseconds:)` when
non-zero. Tests set it to 200 ms so 5 items × 200 ms = 1 s of inflated runtime,
giving the cancel call a deterministic landing window.

**Files modified:** `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift`
**Commit:** `660c07b`

### Plan deviation: `pauseProvider` injection (vs. plan's `drive.status` reference)

The plan referenced `drive.status == .paused` extensively, but `DS3Drive` has no
`status` field (verified by reading `DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift`).
Production code reads pause state via
`SharedData.default().isDrivePaused(_:)`. The plan's "discretion" section
acknowledged that the test pattern is "tester's discretion" — I chose closure
injection (`pauseProvider: @Sendable (UUID) -> Bool`) for symmetry with
`thermalStateProvider` and to avoid pulling the App Group container sandbox
into unit tests. Production callers get the SharedData behavior via the default
argument.

**Files modified:** `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift`

## Threat Flags

None — no new security-relevant surface introduced. The coordinator's new
external-cancellation API stays inside the actor isolation boundary.

## Known Stubs

None. All four Phase 13 coordinator behaviors are wired to production code paths.
The iOS branch (`#if !os(macOS)`) remains a Phase 14 placeholder, as documented
in the file's Phase-12-inherited comment.

## Self-Check: PASSED

- File `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailBackfillCoordinator.swift` exists
- File `DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift` exists
- File `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift` exists
- Commit `46c18f5` (test 13-05) exists in `git log --oneline`
- Commit `660c07b` (feat 13-05) exists in `git log --oneline`
- All claimed grep counts verified above

## Next Steps for Plan 13-09 (BFS Hook)

The coordinator now has every contract Plan 13-09 needs:

```swift
// In BreadthFirstIndexer at runOneBFSPass tail:
if thumbnailSettings.enabled,
   (try? SharedData.default().isDrivePaused(drive.id)) != true {
    _ = try? await thumbnailCoordinator.runBatch(
        maxItems: DefaultSettings.Thumbnail.backfillBatchSize  // 5
    )
}

// On pause-flip notification:
await thumbnailCoordinator.cancelInFlight()
```

The thermal gate fires automatically inside `runBatch`, so the BFS hook needs
no thermal-aware logic of its own.
