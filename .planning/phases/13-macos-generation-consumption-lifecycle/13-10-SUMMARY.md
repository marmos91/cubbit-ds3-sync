---
phase: 13-macos-generation-consumption-lifecycle
plan: 10
subsystem: thumbnails-rollout-lifecycle
tags:
  - thumbnails
  - rollout
  - lifecycle
requires:
  - 11-01 # inspectThumbnailPrefix (Phase 11 D-15)
  - 12-08 # SharedData+thumbnailSettings (Phase 12 D-23..D-27)
  - 13-09 # BFS hook is the consumer of `enabled = true` (committed pre-13-10)
provides:
  - SharedData.hasThumbnailSettings(forDrive:) — once-per-drive guard with corrupt-JSON self-heal
  - ThumbnailSettingsStoring protocol — narrow facade for rollout's persistence dependency
  - ThumbnailRollout struct — silent launch-time once-per-drive rollout
  - FileProviderExtension.runThumbnailRolloutIfNeeded — macOS-gated lifecycle hook
affects:
  - DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift
  - DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift
  - DS3DriveProvider/ThumbnailRollout.swift
  - DS3DriveProvider/FileProviderExtension+Lifecycle.swift
  - DS3DriveProvider/FileProviderExtension.swift
  - DS3DriveProviderTests/ThumbnailRolloutTests.swift
  - DS3Drive.xcodeproj/project.pbxproj
tech-stack:
  added: []
  patterns:
    - "Narrow protocol facade (ThumbnailSettingsStoring) for testability without standing up SharedData"
    - "Internal static seam (SharedData.hasThumbnailSettings(forDrive:atURL:)) for SPM tests against temp files"
    - "Task.detached(priority: .background) lifecycle invocation — no self capture (Pitfall 1)"
key-files:
  created:
    - DS3DriveProvider/ThumbnailRollout.swift
    - DS3DriveProviderTests/ThumbnailRolloutTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift
    - DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift
    - DS3DriveProvider/FileProviderExtension+Lifecycle.swift
    - DS3DriveProvider/FileProviderExtension.swift
    - DS3Drive.xcodeproj/project.pbxproj
decisions:
  - "Narrow ThumbnailSettingsStoring facade (just hasThumbnailSettings + saveThumbnailSettings) over wider SharedData injection — keeps mock surface tiny, documents the rollout's exact persistence dependency."
  - "Internal static SharedData.hasThumbnailSettings(forDrive:atURL:) seam — SPM tests can't access App Group container; without this seam the corrupt-JSON self-heal contract (W3 fix, explicit acceptance criterion) would be untestable. Public API matches plan signature; static helper is internal/testability-only."
  - "Lifecycle hook lives on FileProviderExtension (extension instance scope), not main app — extension is what writes to S3 and reads thumbnail bytes. Main-app rollout would add nothing per Phase 13 'Integration Points' notes."
  - "iOS-gated #if os(iOS) { return } in runThumbnailRolloutIfNeeded — iOS extension lifetime is too short for inspect+persist round trip, and Phase 13 ships macOS thumbnails only (Phase 14 covers iOS via foreground driver)."
metrics:
  duration: "~12 min"
  completed: 2026-04-26
---

# Phase 13 Plan 10: Silent Launch-Time Thumbnail Rollout Summary

Wires the once-per-drive silent thumbnail rollout (THUMB-23, D-01, D-02, D-03):
on first v3.1 extension launch per drive, inspect the bucket's `.thumbnails/`
prefix and persist `ThumbnailSettings.enabled` based on the verdict; subsequent
launches read the persisted flag without re-checking. Fully silent — no UI
surface anywhere on the rollout path (D-03).

## What Shipped

### `SharedData.hasThumbnailSettings(forDrive:)`
- New public method returning `true` only when an entry for the drive exists in
  the `thumbnailSettings.json` JSON dict AND the file decodes successfully.
- **Corrupt-JSON self-heal (W3 fix, explicit acceptance criterion):** returns
  `false` on decode failure so a corrupt file does NOT lock the drive into the
  persisted-disabled state forever. The next rollout pass overwrites the bad
  file with a fresh, decodable JSON.
- Internal static seam `SharedData.hasThumbnailSettings(forDrive:atURL:)`
  exposes the missing/corrupt/no-entry/present cases for SPM tests against a
  temp file (App Group unavailable in the test runner).

### `ThumbnailSettingsStoring` protocol
- Narrow facade (`hasThumbnailSettings` + `saveThumbnailSettings`) over the
  rollout's exact persistence dependency. `SharedData` conforms; the in-memory
  `RolloutMockSettingsStore` provides the test seam.

### `ThumbnailRollout`
- Sendable struct, `runIfNeeded(forDrive:)` async function. Idempotent — safe
  to call on every launch.
- D-02: skips when `hasThumbnailSettings` returns true.
- D-01: dispatches on `inspectThumbnailPrefix` verdict —
  `.empty` / `.matchesOurs` → `enabled = true`; `.conflicting` →
  `enabled = false` (still persisted so subsequent launches skip the re-check).
- D-03: silent UX — no NSUserNotification, no toast, no banner. Errors from
  `inspectThumbnailPrefix` are logged + swallowed; no settings file written →
  next launch retries automatically.

### `FileProviderExtension.runThumbnailRolloutIfNeeded`
- macOS-only lifecycle hook (iOS path returns early — Phase 14 covers iOS).
- Spawns a `Task.detached(priority: .background)` that captures only Sendable
  locals (drive copy, rollout struct, S3 client, SharedData). **Never captures
  `self`** — keeps Swift 6 strict concurrency happy (Pitfall 1).
- Invoked from `init(domain:)` after `startPolling()` and before
  `warmCacheThenStartBFS()`.

## Tests Added (11 total)

### SharedDataThumbnailSettingsTests (+4 cases, 16 total)
- `testHasThumbnailSettingsFalseWhenNeverWritten` — common first-launch case.
- `testHasThumbnailSettingsTrueAfterSave` — once-per-drive guard arms.
- `testHasThumbnailSettingsIsolatedPerDrive` — drive A persisted ≠ drive B
  arbitrarily reachable.
- `testHasThumbnailSettingsFalseWhenFileCorrupt` — **W3 self-heal acceptance
  criterion**: garbage bytes on disk return `false`, NOT `true`, so the
  rollout re-runs and overwrites the bad file.

### ThumbnailRolloutTests (+7 cases, new file)
- `testFirstLaunchEnablesDriveOnEmptyPrefix` — `.empty` → `enabled = true`.
- `testFirstLaunchEnablesDriveOnMatchesOurs` — `.matchesOurs` → `enabled = true`.
- `testFirstLaunchDisablesDriveOnConflicting` — `.conflicting` →
  `enabled = false` AND file written (subsequent launches skip).
- `testSecondLaunchSkipsRecheckIfAlreadyPersisted` — pre-seeded settings →
  `inspectThumbnailPrefix` invocation count = 0.
- `testRolloutHandlesMultipleDrives` — three new drives → three inspects → three
  persisted entries.
- `testRolloutSwallowsInspectThumbnailPrefixError` — drive A throws → no
  settings written (retry next launch); drive B succeeds independently.
- `testRolloutRunsInBackgroundDoesNotBlockLaunch` — 500 ms inspect latency,
  lifecycle wrap-and-return path completes in < 50 ms.

## Verification

- `swift test --package-path DS3Lib --filter SharedDataThumbnailSettingsTests` —
  **16 / 16 GREEN** (12 Phase 12 + 4 new).
- `xcodebuild test -scheme DS3Drive -destination 'platform=macOS'
  -only-testing:DS3DriveProviderTests/ThumbnailRolloutTests` — **7 / 7 GREEN**.
- `xcodebuild build -scheme DS3Drive -destination 'platform=macOS'` — green.
- `xcodebuild build -scheme DS3DriveApp -destination 'generic/platform=iOS'` —
  green (iOS path early-returns from `runThumbnailRolloutIfNeeded`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Internal static seam for SPM testability.**
- **Found during:** Task 1 (writing tests 1–3, 3b in DS3LibTests).
- **Issue:** SPM tests cannot reach the App Group container, but the plan's
  acceptance criterion required `testHasThumbnailSettingsFalseWhenFileCorrupt`
  (W3 self-heal) to be a working unit test. Without a testability seam there
  was no way to drive corrupt-JSON bytes through the public method.
- **Fix:** Added an internal `static func hasThumbnailSettings(forDrive:atURL:)`
  alongside the public method. The public method delegates to it after computing
  the App Group URL. Tests exercise the static helper against a temp directory.
- **Acceptance-criteria impact:** Plan acceptance read
  `grep -c "func hasThumbnailSettings" ... == 1` — actual count is 2 (public +
  static). The plan's intent (single user-facing API surface, silent UX,
  self-heal contract) is preserved; the second `func` is internal-only and
  documented as the test seam.
- **Files modified:** `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift`.
- **Commit:** a6df0af.

**2. [Rule 3 — Blocking] SwiftLint `no_empty_block` violations on mock stubs.**
- **Found during:** Task 1 commit (pre-commit lint hook).
- **Issue:** `RolloutMockS3Client` had four no-op stub methods (`deleteObject`,
  `copyObject`, `abortMultipartUpload`, `shutdown`) with empty bodies. SwiftLint
  rejected them.
- **Fix:** Added explanatory `// No-op stub — rollout tests don't observe X`
  comments inside each body. Same pattern as `HookMockS3Client` in
  `UploadHookTests.swift`.
- **Files modified:** `DS3DriveProviderTests/ThumbnailRolloutTests.swift`.
- **Commit:** a6df0af.

### Authentication Gates

None.

## Deferred Issues

Two unrelated test failures in `DS3DriveProviderTests/S3ItemTests.swift`:
- `testDecorationCloudOnlyDefault` — expects `cloudOnly` decoration on
  unmaterialized item, observed `nil`.
- `testDecorationSynced` — expects `synced` decoration on synced item,
  observed `nil`.

**Verified pre-existing on the Plan 13-10 baseline** (stashed plan changes,
re-ran tests — failures persist). Unrelated to thumbnail rollout (decoration
identifier wiring on `S3Item`). Logged in
`.planning/phases/13-macos-generation-consumption-lifecycle/deferred-items.md`.
Out of scope per executor scope-boundary rules.

## Architecture Notes

### Per-extension-process drive scoping
Each `FileProviderExtension` instance owns exactly one `DS3Drive` (one process
per `NSFileProviderDomain`). The lifecycle hook iterates the `self.drive` of
this single instance — no need to enumerate domains here. The
"iterate drives" framing in the plan refers to the conceptual scope; in
practice each extension auto-runs its own rollout.

### Concurrency posture
- Rollout is a Sendable struct with let-bound fields; safe to capture in a
  detached Task.
- `runIfNeeded` is a regular `async` function; the lifecycle wraps it in
  `Task.detached(priority: .background)` so launch is never blocked.
- Captures only Sendable locals (`driveCopy`, `rollout`) — never `self`. This
  is the same pattern as `enqueueThumbnailUpload` from Plan 13-07 (Pitfall 1).

### Threat-model dispositions honored
- T-13-48 (DoS — re-check every cold start): mitigated by the
  `hasThumbnailSettings` once-per-drive guard.
- T-13-52 (spoofing — wrong drive enabled): mitigated by per-extension-process
  drive scoping (see above).
- T-13-53 (rollout blocks launch): mitigated by `Task.detached` —
  `testRolloutRunsInBackgroundDoesNotBlockLaunch` enforces.

## Self-Check: PASSED

- DS3DriveProvider/ThumbnailRollout.swift — FOUND
- DS3DriveProviderTests/ThumbnailRolloutTests.swift — FOUND
- .planning/phases/13-macos-generation-consumption-lifecycle/13-10-SUMMARY.md — FOUND
- a6df0af — FOUND
- 8df78d3 — FOUND
