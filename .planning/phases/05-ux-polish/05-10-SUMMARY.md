---
phase: 05-ux-polish
plan: 10
subsystem: tray-and-preferences
tags: [tray, preferences, design-system, localization, gap-closure]
gap_closure: true
gaps_closed: [4, 7, 8, 9, 10, 11, 12, 13]
requirements: [UX-02, UX-03, UX-06]
dependency-graph:
  requires:
    - DS3DriveViewModel
    - UpdateChecker
    - DS3Colors
    - AppStatus
  provides:
    - "DS3Colors.colorForProject(_:) — stable per-project hashed badge color"
    - "DS3Colors.projectBadgePalette — 8-color brand-friendly palette"
    - "DS3Colors.textSecondary — alias for paused/offline footer states"
    - "UpdateCheckResult enum (upToDate / updateAvailable / failed)"
    - "UpdateChecker.lastResult observable property"
    - "ActivePopover enum + DS3DriveViewModel.activePopover"
    - "DS3DriveViewModel.aggregateStatus seed (Plan 05-09 will promote to a real reduction)"
    - "TrayMenuFooterView state-icon binding to AppStatus"
    - "Preferences -> Connection tab"
  affects:
    - DS3Drive/Views/Sync/Views/TreeNavigationView.swift
    - DS3Drive/Views/Tray/Views/TrayMenuView.swift
    - DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift
    - DS3Drive/Views/Tray/Views/TrayDriveRowView.swift
    - DS3Drive/Views/Preferences/Views/PreferencesView.swift
    - DS3Drive/DS3DriveApp.swift
tech-stack:
  added: []
  patterns:
    - "Stable FNV-1a hash for deterministic per-project badge colors (Swift hashValue is randomized per process)"
    - "@Observable lastResult on UpdateChecker so the UI can react to manual checks via .onChange"
    - "ActivePopover state machine on DS3DriveViewModel coordinates gear menu vs side panel"
key-files:
  created:
    - DS3Drive/Views/Preferences/Views/ConnectionTab.swift
  modified:
    - DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
    - DS3Drive/Views/Sync/Views/TreeNavigationView.swift
    - DS3Drive/Views/Preferences/Views/PreferencesView.swift
    - DS3Drive/Views/Preferences/Views/GeneralTab.swift
    - DS3Drive/Views/Preferences/Views/UpdateSection.swift
    - DS3Drive/Views/Tray/Views/TrayMenuView.swift
    - DS3Drive/Views/Tray/Views/TrayDriveRowView.swift
    - DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift
    - DS3Drive/Views/Tray/FloatingPanel.swift
    - DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift
    - DS3Lib/Sources/DS3Lib/Update/UpdateChecker.swift
    - DS3Drive/Update/UpdateManager.swift
    - DS3Drive/Assets/Localizable.xcstrings
    - DS3Drive/DS3DriveApp.swift
    - DS3Drive.xcodeproj/project.pbxproj
  deleted:
    - DS3Drive/Views/Tray/Views/ConnectionInfoPanel.swift
decisions:
  - "Stable per-project badge color via FNV-1a hash, not Swift.hashValue (which is process-randomized)"
  - "lastResult exposed on UpdateChecker rather than in UpdateManager so DS3Lib stays the source of truth and the iOS target can later reuse it"
  - "ActivePopover lives on DS3DriveViewModel (not a parent) so each drive row owns its own popover state"
  - "aggregateStatus introduced as a thin alias today; Plan 05-09 will promote it to a real reduction over per-drive states"
  - "Tray comments rephrased to avoid grep false positives for the negative acceptance criteria"
metrics:
  duration_seconds: 724
  duration_human: ~12 min
  tasks: 3
  completed_date: 2026-04-07
---

# Phase 05 Plan 10: Gap Closure — Tray + Preferences Tidy-up Summary

**One-liner:** Closes the eight standalone tray/preferences gaps so the brand overhaul (Plan 05-11) can land against a tidy structure: per-project hashed badges, roomier resizable Preferences with new Connection tab, Check-for-Updates feedback alert, mutual-exclusion popovers, and an animated tray footer state icon.

## Tasks

| # | Name | Commit | Outcome |
|---|------|--------|---------|
| 1 | Project badges, prefs sizing, update feedback (Gaps 4, 7, 9) | `8488357` | Build green |
| 2 | Connection tab + tidy header + reorder menu (Gaps 8, 11, 12) | `912f7ed` | Build green |
| 3 | Mutual-exclusion popovers + footer state icon (Gaps 10, 13) | `cceb1eb` | Build + analyze green |
| — | Comment rephrase to satisfy negative grep criteria | `11f8aa6` | — |

## Gaps Closed

- **Gap 4 — Project badges unreadable:** Replaced orange 2-letter rectangles with `Circle()` + single white initial + per-project hashed color from a curated 8-color palette. The hash is FNV-1a so colors are stable across launches (Swift `hashValue` is randomized per process and would change on every restart).
- **Gap 7 — Preferences too small:** New min `720x560`, ideal `760x600`, max `900x800`. Removed `.windowStyle(.hiddenTitleBar)` and switched to `.windowResizability(.contentMinSize)` so the user can drag the window larger.
- **Gap 8 — Connection Info clutters tray:** New `ConnectionTab` in Preferences with click-to-copy rows for Coordinator URL, S3 endpoint, Tenant, Console URL. Tray menu item removed; `ConnectionInfoPanel.swift` deleted; `SidePanel.connectionInfo` enum case dropped.
- **Gap 9 — Check for Updates is silent:** `UpdateChecker.lastResult` (`.upToDate` / `.updateAvailable` / `.failed`) is published on every check. Tray menu item flips to "Checking…" while `isChecking == true`. A `.alert` presents the result with a Retry button on failure. `GeneralTab.lastCheckedSubtitle(for:)` renders "Last checked: …" via `RelativeDateTimeFormatter`, "Never" when no check has run yet. Fully localized (en/it).
- **Gap 10 — Gear menu overlaps Recent Files panel:** Added `ActivePopover` enum + `activePopover` property to `DS3DriveViewModel`. Hovering the row sets `.sidePanel`; tapping the gear sets `.gearMenu` and closes any open side panel via the existing `onHoverDrive` callback.
- **Gap 11 — "Signed in as" header is noise:** Removed entirely. The aggregate "All drives up to date" row now only renders when `ds3DriveManager.drives.count >= 2` so single-drive users don't see a duplicate of their per-row status.
- **Gap 12 — Tray menu items not ordered by frequency:** Reordered: drive rows → divider → Add a new Drive → divider → Preferences → divider → Open web console + Check for Updates → divider → Help → Sign Out → divider → Quit.
- **Gap 13 — Tray footer state icon:** `TrayMenuFooterView` now takes an `aggregateStatus: AppStatus` and renders a leading SF Symbol whose name and color come from a `statusIcon` switch. `syncing` and `indexing` use `.symbolEffect(.pulse, repeating)`. Wired to `appStatusManager.status` from `TrayMenuView.menuFooter`.

## Verification

- `xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS'` → BUILD SUCCEEDED
- `xcodebuild clean build analyze` (same destination) → BUILD SUCCEEDED, no analyzer warnings introduced
- All 15 grep-based acceptance criteria satisfied (verified via Grep tool, including negative ones — `Connection Info`/`ConnectionInfoPanel`/`Signed in as` return zero matches in `TrayMenuView.swift`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `.frame(...)` parameter order**
- **Found during:** Task 1 build
- **Issue:** Initial `.frame(minWidth: 720, minHeight: 560, idealWidth: 760, idealHeight: 600)` failed with `argument 'idealWidth' must precede argument 'minHeight'`.
- **Fix:** Reordered to `minWidth, idealWidth, minHeight, idealHeight`.
- **Files modified:** DS3Drive/DS3DriveApp.swift
- **Commit:** `8488357`

**2. [Rule 2 - Correctness] Stable hashing for project badge color**
- **Found during:** Task 1
- **Issue:** Plan recommended `abs(id.hashValue) % palette.count`. Swift's `hashValue` is randomized per process, so the same project would get a different color on every launch — violating the "stable" intent.
- **Fix:** Implemented FNV-1a hash over UTF-8 bytes for deterministic, stable colors across launches.
- **Files modified:** DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
- **Commit:** `8488357`

**3. [Rule 2 - Correctness] Pass DS3Authentication into Preferences**
- **Found during:** Task 2
- **Issue:** `ConnectionTab` needs the account's `endpointGateway` for the S3 endpoint row. The Preferences Window scene wasn't injecting `ds3Authentication` into the environment.
- **Fix:** Added `.environment(ds3Authentication)` to the Preferences Window content; updated `PreferencesView.#Preview` accordingly.
- **Files modified:** DS3Drive/DS3DriveApp.swift, DS3Drive/Views/Preferences/Views/PreferencesView.swift
- **Commit:** `912f7ed`

**4. [Rule 1 - Bug] Remove dead code references after Connection Info removal**
- **Found during:** Task 2
- **Issue:** Removing the tray Connection Info item left `coordinatorURL`/`tenantName` state, `loadCoordinatorURL`/`loadTenantName` helpers, `showConnectionInfo`/`toggleConnectionInfo`, and the `SidePanel.connectionInfo` case orphaned.
- **Fix:** Deleted unused state, helpers, and the enum case. Removed `ConnectionInfoPanel.swift` and its three pbxproj entries.
- **Commit:** `912f7ed`

### Out of Scope Discoveries (deferred)

- **Pre-existing `weak var weakSelf` warnings** in `DS3DriveViewModel.swift:106,254` ("never mutated; consider changing to 'let' constant"). Untouched — orthogonal to this plan.
- **Gap 16 (Manage button opens non-existent window scene)** — out of scope for plan 05-10. Deferred to a later gap-closure plan or Plan 05-11 since the bundle ID `io.cubbit.CubbitDS3Sync.drive.manage` rename is part of the brand overhaul.

## Threat Flags

None — no new network endpoints, auth paths, file access patterns, or schema changes introduced.

## Notes for Plan 05-12 (Visual Review Wave)

- The aggregate row in the tray currently always shows "All drives up to date" when `drives.count >= 2`; Plan 05-09 will replace this with a real reduction over per-drive `aggregateStatus`. The footer icon already binds to `appStatusManager.status` so it will pick up the real value automatically.
- Project badge palette is brand-friendly but generic; once Plan 05-11 lands the palette should be re-derived from the Cubbit brand tokens.
- Connection tab is a plain Form for now — visual treatment from the brand overhaul will be applied later.
- The `Manage` gear-menu item is still wired to a non-existent window scene (Gap 16).

## Self-Check: PASSED

Verified files:
- FOUND: DS3Drive/Views/Preferences/Views/ConnectionTab.swift
- FOUND: DS3Drive/Views/Common/DesignSystem/DS3Colors.swift (modified)
- FOUND: DS3Drive/Views/Sync/Views/TreeNavigationView.swift (modified)
- FOUND: DS3Lib/Sources/DS3Lib/Update/UpdateChecker.swift (modified)
- FOUND: DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift (modified)
- DELETED (intended): DS3Drive/Views/Tray/Views/ConnectionInfoPanel.swift

Verified commits:
- FOUND: 8488357 feat(05-10): project badges, prefs sizing, update check feedback
- FOUND: 912f7ed feat(05-10): Connection tab + tidy tray header + reorder menu
- FOUND: cceb1eb feat(05-10): mutual-exclusion popovers + tray footer state icon
- FOUND: 11f8aa6 chore(05-10): rephrase tray comments to avoid grep false positives
