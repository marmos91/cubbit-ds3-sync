---
phase: 05-ux-polish
plan: 15
subsystem: tray, drive-view-model, update-manager, ds3lib-models
tags: [gap-closure, round-2, aggregate-status, recent-files, gear-menu, update-notification, swift6-concurrency]
gap_closure: true
gaps_closed: [14, 15, 16, 25, 26, 27, 32]

# Dependency graph
requires:
  - phase: 05-ux-polish
    provides: "RecentFilesTracker (05-09), ActivePopover + UpdateCheckResult (05-10), AggregateStatus seed (05-10/05-09)"
provides:
  - "AggregateStatus enum with exhaustive reducer — the ONE source of truth for tray state"
  - "DS3DriveManager.aggregateStatus: AggregateStatus (+ aggregateAppStatus bridge to AppStatus)"
  - "Tray header row driven by AggregateStatus switch — no more three-way disagreement"
  - "Terminal-state upsert in processTransferStats — rows transition to .completed when size >= totalBytes"
  - "Startup purge of leftover .syncing entries on DS3DriveViewModel.init"
  - "UpdateManager.checkForUpdatesAndNotify() posting UNUserNotification result"
  - "Swift Concurrency Task-based debouncers replacing Timer + weakSelf + MainActor.assumeIsolated"
affects: []

tech-stack:
  added: []
  patterns:
    - "Enum-based reducer for tray aggregate state (AggregateStatus.from(statuses:))"
    - "Task<Void, Never> with Task.sleep replacing Timer.scheduledTimer for @MainActor debounce"
    - "UNUserNotification side channel for Check-for-Updates result (survives tray dismissal)"

key-files:
  created:
    - "DS3Lib/Sources/DS3Lib/Models/AggregateStatus.swift"
    - "DS3Lib/Tests/DS3LibTests/AggregateStatusTests.swift"
  modified:
    - "DS3Lib/Sources/DS3Lib/DS3DriveManager.swift"
    - "DS3Drive/Views/Tray/Views/TrayMenuView.swift"
    - "DS3Drive/Views/Tray/Views/TrayDriveRowView.swift"
    - "DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift"
    - "DS3Drive/DS3DriveApp.swift"
    - "DS3Drive/Update/UpdateManager.swift"

key-decisions:
  - "Introduce a dedicated AggregateStatus enum distinct from AppStatus — the reducer can express .noDrives, .mixed, and .error(count:) which AppStatus cannot"
  - "Keep aggregateAppStatus as a thin bridge to AppStatus so the menu-bar icon and footer don't need a massive refactor"
  - "Gear menu mutual exclusion moves from .simultaneousGesture to .onHover on the label — gestures ate taps before Menu could present (Gap 25 root cause)"
  - "Update check result delivered via BOTH the in-tray alert AND a UNUserNotification — the notification survives tray closure, which the alert does not"
  - "Task + Task.sleep over Timer for @MainActor debouncers — no weakSelf, no assumeIsolated, Swift 6 clean"
  - "Terminal-state upsert in processTransferStats when size >= totalBytes — the actual root cause of 'stuck transferring' Round 1 missed: the entry was never transitioned to .completed, it waited for the 5s reset timer which the user beat to the tray"

requirements-completed: [UX-02, UX-03, UX-05]

metrics:
  duration_human: ~15 min
  tasks: 3 commits (Task 1+4 combined, Task 2, Task 3)
  completed_date: 2026-04-07
---

# Phase 05 Plan 15: Gap Closure Round 2 Summary

**One-liner:** Re-fixes Gaps 14, 15, 16, 25, 26, 27, 32 that Round 1 shipped code for but did not actually resolve at runtime, plus the Swift 6 weakSelf data-race errors that surfaced after Round 1's changes.

## The Round 1 Post-Mortem

Round 1 (Plans 05-09, 05-10) created or touched every file this plan modifies but passed verification by grep-matching acceptance text and confirming `xcodebuild` succeeded. The actual runtime behavior was never reproduced. This plan is the "look at the screen and click things" follow-up.

### Gap 14 — Recent Files duplicates / stuck transferring

**Round 1 diagnosis:** Said the tracker array could contain duplicates, rewrote tracker to dictionary-keyed upsert.

**Actual root cause:** The tracker rewrite was correct but `DS3DriveViewModel.processTransferStats` only ever upserted entries with `status: .syncing`. There was NO code path that upserted the SAME entry with `.completed` when the transfer finished — it relied on either (a) the 5s `transferStatsResetTimer` sweeping all remaining `.syncing` entries to `.completed` or (b) the idle-debounced `driveStatusChanged` path doing the same. Both fire AFTER the user closes the tray, so the user sees a "stuck transferring" row.

**Fix:** `processTransferStats` now checks `if size >= totalBytes` and upserts with `status: .completed` on that update directly. Terminal transition happens in the same cycle as the final progress update. Also added `recentFilesTracker.purgeOnStartup()` in `DS3DriveViewModel.init` so leftover rows from a previous session (app killed mid-transfer) are failed to `.error("interrupted")` on relaunch.

### Gaps 15 + 27 — Three-way state disagreement

**Round 1 diagnosis:** Added `DS3DriveManager.aggregateStatus: AppStatus` as a reduction over per-drive states.

**Actual root cause:** Three distinct bugs compounded:

1. **Tray header row was hardcoded.** `TrayMenuView.aggregateStatusRow` rendered a static "All drives up to date" string regardless of drive state. It never consumed `aggregateStatus`.
2. **Duplicate aggregateStatus alias on DS3DriveViewModel.** Plan 05-10 added a per-VM `aggregateStatus` that just returned `driveStatus`. This gave callers an alternate reading that could disagree with the manager.
3. **AppStatus enum can't represent .noDrives, .mixed, .error(count:).** The reducer had to paper over these with best-effort fallbacks.

**Fix:**
- New `AggregateStatus` enum with exhaustive cases (`noDrives`, `allIdle`, `syncing`, `indexing`, `error(count:)`, `allPaused`, `mixed`).
- `AggregateStatus.from(statuses:)` pure reducer with documented priority order.
- `DS3DriveManager.aggregateStatus` now returns `AggregateStatus`; legacy `aggregateAppStatus` bridges to `AppStatus` for the menu-bar icon and footer.
- `TrayMenuView.aggregateStatusRow` switches on the new enum with a `HeaderDescriptor` struct mapping each case to SF Symbol + color + localized text.
- Deleted the per-VM alias in `DS3DriveViewModel` with a comment explaining why.
- `AggregateStatusTests` has 19 exhaustive cases (empty, idle, sync wins over indexing, mixed error+idle, all-error with count, all-paused, paused+sync is syncing, noDrives hides header, etc.).

### Gap 16 — Manage button opens non-existent scene

**Round 1:** Said it was fixed. Actually was fixed — verified zero `CubbitDS3Sync` or `drive.manage` references in `DS3Drive/**/*.swift`. Kept intact.

### Gap 25 — Gear icon does nothing

**Round 1 diagnosis:** Plan 05-09 added `ActivePopover` mutual exclusion with a `.simultaneousGesture(TapGesture())` on the gear Menu to dismiss the Recent Files side panel on tap.

**Actual root cause:** `.simultaneousGesture` intercepts the tap BEFORE SwiftUI's native `Menu` can present its popover. The Menu never opens.

**Fix:** Removed `.simultaneousGesture`. Moved the side-panel dismiss logic to `.onHover` on the gear label — hovering implies the user is about to tap, which is a perfectly good moment to dismiss the overlapping side panel, and `onHover` doesn't interfere with tap routing. The Menu is now unconditionally present in the tree with its native tap handling intact.

### Gap 26 — Check for Updates silent

**Round 1 diagnosis:** Plan 05-10 added `UpdateCheckResult.lastResult` and bound it to an in-tray `.alert`.

**Actual root cause:** The in-tray alert requires the tray to still be open when the network check returns (can take seconds). Users click "Check for Updates" and immediately move focus elsewhere, so the tray closes and the alert never presents.

**Fix:** `UpdateManager.checkForUpdatesAndNotify()` posts a `UNUserNotification` with three variants (up-to-date / update-available / failed). System notifications survive tray closure. The in-tray alert still works when the user keeps the tray open — the two channels are complementary.

### Gap 32 — Swift 6 weakSelf data race

**Round 1:** Did not address. Pre-existing `nonisolated(unsafe) weak let weakSelf = self` workaround in `DS3DriveViewModel` was flagged by Swift 6 strict concurrency after Round 1 tweaks made it visible. Build failed on `sending 'weakSelf' risks causing data races` on lines 131 and 276.

**Root cause:** `Timer.scheduledTimer` closures run on the main run loop but the closure type is `nonisolated @Sendable (Timer) -> Void`. Capturing `self` (a `@MainActor` instance) is unsafe; the previous code used `MainActor.assumeIsolated` to paper over it.

**Fix (Option B from Gap 32):** Replaced both `Timer.scheduledTimer` sites with `Task { [weak self] in try? await Task.sleep(for: ...); guard !Task.isCancelled, let self else { return }; ... }`. A `Task` started inside a `@MainActor`-isolated class inherits MainActor isolation, so the body runs on the main actor with no unsafe capture dance. `weakSelf` variable deleted. `Timer.scheduledTimer`, `MainActor.assumeIsolated`, `nonisolated(unsafe)` all grep to zero in DS3DriveViewModel.swift.

## Task Commits

| # | Task | Commit | Notes |
|---|------|--------|-------|
| 1+4 | AggregateStatus enum + Swift 6 weakSelf fix | `457dabb` | **Attribution caveat:** committed to git under plan 05-16's author because the parallel 05-16 agent staged and committed my staged files alongside its own work in the same `git commit` call. The actual content (AggregateStatus.swift, AggregateStatusTests.swift, DS3DriveManager.swift aggregateStatus refactor, TrayMenuView header switch, DS3DriveApp menu-bar binding, DS3DriveViewModel Timer→Task replacement) is entirely this plan's work. See "Deviations" below. |
| 2 | Recent Files terminal state + startup purge | `63d2472` | |
| 3 | Gear menu restored + update check notification | `4a7f8ed` | |

## Verification

### Unit tests

```
swift test --filter "AggregateStatusTests|RecentFilesTrackerTests"
Test Suite 'Selected tests' passed
  Executed 35 tests, with 0 failures (0 unexpected) in 0.010 seconds
```

- AggregateStatusTests: 19 cases (noDrives, allIdle×2, sync wins over indexing×2, indexing×2, error with count×2, mixed error+idle/sync/paused ×3, allPaused×2, paused+sync is syncing, paused+idle is allIdle, appStatus bridge for 7 cases, header visibility ×2)
- RecentFilesTrackerTests: 16 cases (ring buffer, sort order, dedupe by identifier, earliest-startedAt merge, stuck-transfer watchdog, startup purge, clearAll, recentEntries sort, concurrent upserts serialized)

### Build

- `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination "platform=macOS" build` → **BUILD SUCCEEDED**
- `xcodebuild ... build SWIFT_STRICT_CONCURRENCY=complete` → **BUILD SUCCEEDED** (zero weakSelf warnings/errors)

### Grep acceptance

| Criterion | File | Result |
|-----------|------|--------|
| `weakSelf` (code, not comments) | DS3DriveViewModel.swift | 0 — only 4 references remain, all in doc comments explaining the Task replacement |
| `Timer.scheduledTimer` | DS3DriveViewModel.swift | 0 — only in comments |
| `MainActor.assumeIsolated` | DS3DriveViewModel.swift | 0 — only in comments |
| `nonisolated(unsafe)` | DS3DriveViewModel.swift | 0 |
| `transferStatsResetTask` | DS3DriveViewModel.swift | 3 (property, cancel in cleanup, assign in stats handler) |
| `idleDebounceTask` | DS3DriveViewModel.swift | 4 (property, cancel×2, assign in driveStatusChanged) |
| `CubbitDS3Sync` | DS3Drive/**/*.swift | 0 |
| `drive.manage` | DS3Drive/**/*.swift | 0 |
| `AggregateStatus.from` | DS3Lib/**/*.swift | 1 (DS3DriveManager.aggregateStatus computed property) |

### Runtime verification (manual walkthrough required by user)

The following steps are NOT automated — they are the entire point of this plan being "Round 2". The user MUST perform them:

1. **Gear menu opens.** Launch app, open tray, click the gear icon on any drive row → native macOS Menu appears with Disconnect / View in Finder / Refresh / Reset Sync / Empty Trash / Pause / Copy S3 Path. Previously the click did nothing.
2. **Aggregate state agrees.** Pause a drive via the gear menu → tray header, drive row, footer, and menu-bar icon all reflect the paused state. Resume → all four return to idle / syncing. No three-way disagreement.
3. **Recent Files single entry.** Drag a small file into a synced Finder folder. Hover the drive row → Recent Files side panel opens. Exactly ONE row appears for the file, transitioning from syncing → completed within seconds. No duplicate.
4. **Startup purge.** While a file is transferring, Quit the app (Cmd+Q). Relaunch. Open Recent Files → the row that was syncing now shows as `.error("interrupted")`, not stuck as `.syncing`.
5. **Update check notification.** Tray → Check for Updates → immediately move focus elsewhere (close the tray). Within a few seconds, a macOS system notification appears with "DS3 Drive is up to date" (or similar variant).
6. **No console errors.** Console.app, filter by `io.cubbit.DS3Drive` → no `No Scene with id ...drive.manage` runtime errors when opening the gear menu.
7. **Debounce preserved.** Drag a small file in Finder, watch the menu-bar icon → no flashing between sync and idle during the transfer.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Task 1 build blocked by pre-existing Gap 32 weakSelf errors**
- **Found during:** Task 1 build verification
- **Issue:** The first `xcodebuild` after Task 1 edits failed with `sending 'weakSelf' risks causing data races` on DS3DriveViewModel.swift:131 and :276. These are the same errors that this plan's Task 4 addresses, but Task 4 was scheduled last — which meant Task 1 couldn't verify its build until Task 4 was applied.
- **Fix:** Promoted Task 4 (weakSelf replacement) to run inline with Task 1. Both were committed together as the combined commit.
- **Files modified:** DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift
- **Impact:** None — both tasks are in the same logical unit of work.

**2. [Deviation - Attribution] Parallel plan 05-16 committed Task 1+4 files under its own commit**
- **Found during:** Task 1+4 commit
- **Issue:** This plan runs in parallel with plan 05-16 in the same repo (no worktree isolation, file sets declared disjoint). While I was reviewing the linter's changes to my staged files, the parallel 05-16 agent executed its own `git commit` which swept up my staged files into its commit `457dabb` (message: `feat(05-16): add BucketListingLimiter and listWithRetries for S3 throttle hardening`). The commit's file list shows both 05-16 files (BucketListingLimiter.swift, S3Lib.swift) AND my 05-15 files (AggregateStatus.swift, AggregateStatusTests.swift, DS3DriveManager.swift, TrayMenuView.swift, DS3DriveApp.swift, DS3DriveViewModel.swift).
- **Fix:** None applied. Reverting the commit would have lost 05-16's work; splitting would have required rewriting git history. The files are intact and correct; the attribution is just wrong. Documented here for traceability.
- **Impact:** Commit history is blurred between 05-15 and 05-16 for Task 1+4. My remaining commits (`63d2472` Task 2, `4a7f8ed` Task 3) are properly attributed to 05-15.

**3. [Rule 1 - Bug] Mutual exclusion moved from simultaneousGesture to onHover**
- **Found during:** Task 3 gear menu fix
- **Issue:** The plan suggested using `.onTapGesture` on the Menu to dismiss the side panel before the Menu opens. But `.onTapGesture` exhibits the exact same behavior as `.simultaneousGesture` — it intercepts the tap and the Menu never presents. This is the SwiftUI platform behavior: you cannot attach any tap handler to a `Menu` label without breaking its native presentation.
- **Fix:** Moved the dismiss to `.onHover` on the gear label inside the Menu's label. `onHover` does not affect tap routing, and hovering the gear is a good proxy for "user is about to click" — the side panel dismisses before the tap even lands.
- **Files modified:** DS3Drive/Views/Tray/Views/TrayDriveRowView.swift
- **Commit:** `4a7f8ed`

## Threat Flags

None — no new network endpoints, auth paths, file access, or schema changes.

## Known Stubs

None.

## Self-Check: PASSED

**Files verified on disk:**
- FOUND: DS3Lib/Sources/DS3Lib/Models/AggregateStatus.swift
- FOUND: DS3Lib/Tests/DS3LibTests/AggregateStatusTests.swift
- FOUND: DS3Lib/Sources/DS3Lib/DS3DriveManager.swift (modified)
- FOUND: DS3Drive/Views/Tray/Views/TrayMenuView.swift (modified)
- FOUND: DS3Drive/Views/Tray/Views/TrayDriveRowView.swift (modified)
- FOUND: DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift (modified)
- FOUND: DS3Drive/DS3DriveApp.swift (modified)
- FOUND: DS3Drive/Update/UpdateManager.swift (modified)

**Commits verified in git log:**
- FOUND: `457dabb` — Task 1+4 (co-committed under plan 05-16 due to parallel execution race; see Deviation 2)
- FOUND: `63d2472` — fix(05-15): Recent Files terminal state + startup purge (Gap 14)
- FOUND: `4a7f8ed` — fix(05-15): gear menu restored + update check system notification (Gaps 25, 26)

---
*Phase: 05-ux-polish*
*Completed: 2026-04-07*
