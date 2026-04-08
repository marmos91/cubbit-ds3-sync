---
phase: 05-ux-polish
plan: 19
subsystem: ios, design-system, brand
tags: [brand, ios, share-extension, gap-17, gap-19-mirror, figtree]
status: awaiting-human-verification
gap_closure: true
gaps_closed: [17]
requirements: [UX-01]
dependency-graph:
  requires:
    - 05-13-SUMMARY.md  # iOS DS3Lib re-export wiring
    - 05-17-SUMMARY.md  # Composer canary tokens + Figtree
  provides:
    - "iOS app + Share Extension consume Composer canary tokens"
    - "Figtree bundled in DS3DriveApp + DS3DriveShareExtension targets"
    - "IOSTypography aliases now point at DS3Lib.DS3Typography (Figtree)"
    - "ShareTypography aliases now point at DS3Lib.DS3Typography (Figtree)"
    - "iOS Login layered-background bug (Gap 19 mirror) fixed"
  affects:
    - DS3DriveApp/Views/**
    - DS3DriveShareExtension/**
tech-stack:
  added: []
  patterns:
    - "iOS targets bundle Figtree by referencing the existing DS3Drive/Assets/Fonts/*.ttf via target-membership only — no file duplication"
    - "Single ZStack hero gradient backdrop replaces double-background card pattern on the iOS login flow"
    - "Hashed Color.orange project emblem replaced with brandPrimary fill + white label across iOS"
key-files:
  created:
    - .planning/phases/05-ux-polish/05-19-IOS-GAPS.md
  modified:
    - DS3Drive.xcodeproj/project.pbxproj
    - DS3DriveApp/Views/Common/IOSDesignSystem.swift
    - DS3DriveApp/Views/App/IOSAppRootView.swift
    - DS3DriveApp/Views/Login/IOSLoginView.swift
    - DS3DriveApp/Views/Login/IOSMFAView.swift
    - DS3DriveApp/Views/Dashboard/DriveListView.swift
    - DS3DriveApp/Views/Dashboard/DriveDetailView.swift
    - DS3DriveApp/Views/Dashboard/EmptyDrivesView.swift
    - DS3DriveApp/Views/Setup/ProjectListView.swift
    - DS3DriveApp/Views/Setup/DriveConfirmView.swift
    - DS3DriveApp/Views/Settings/IOSSettingsView.swift
    - DS3DriveShareExtension/ShareExtensionView.swift
decisions:
  - "Add Figtree to iOS targets via target-membership only (existing TTFs in DS3Drive/Assets/Fonts/) — no file duplication"
  - "Single ZStack brand gradient backdrop on the iOS login (drop iPad double-card pattern that was the iOS mirror of Gap 19)"
  - "Project emblems on iOS use IOSColors.brandPrimary fill + white text instead of hardcoded Color.orange + black; DS3Lib has no colorForProject helper so a single brand emblem is consistent with the canary palette"
  - "Rewire IOSTypography + ShareTypography aliases at the design-system layer rather than per-view edits — every iOS view inherits Figtree automatically"
metrics:
  duration: "~75m"
  completed: 2026-04-07
---

# Phase 05 Plan 19: iOS Brand Sweep (Gap 17 closure)

iOS DS3DriveApp + DS3DriveShareExtension brand sweep against the
corrected Composer canary tokens that landed in Plan 05-17. Plan 05-13
shipped the cross-platform `DS3Lib` re-export wiring but used
Plan 05-11 (now-superseded) values; this plan finishes the work.

## Tasks

| # | Name | Commit | Outcome |
|---|------|--------|---------|
| 1 | Investigation + Figtree iOS bundling + IOSColors/IOSTypography expansion | `ff450d0` | macOS build green; gap matrix written |
| 2 | iOS view sweep (login hero, dashboard, wizard, settings, project emblems) | `9a3a38f` | macOS build green |
| 3 | Share Extension typography rewire to Figtree | `085780f` | macOS build green |
| 3a | Duplicate-warning token fix (Color.orange -> statusWarning) | `c293e03` | macOS build green |
| 4 | Visual checkpoint on iOS simulator/device | (pending human) | awaiting-human-verification |

## What Shipped

### Investigation (Task 1)

A full per-file iOS gap matrix is at
`.planning/phases/05-ux-polish/05-19-IOS-GAPS.md`.

Headline findings:

- **Figtree was registered in Info.plist by Plan 05-17 but the .ttf
  files were NOT in the iOS app or Share Extension Copy Bundle Resources
  phase.** iOS would have silently fallen back to system font even with
  the UIAppFonts entry. Fixed by adding the existing
  `DS3Drive/Assets/Fonts/Figtree-*.ttf` file references to both iOS
  Resources phases via new `PBXBuildFile` entries
  (`A10519010000000000000001..4` for the iOS app,
  `A10519020000000000000001..4` for the Share Extension). No file
  duplication; Xcode copies from the same source path into multiple
  bundles.
- **`IOSTypography` was using `Font.title2.bold()` / `Font.headline` /
  `Font.body` / `Font.caption` (San Francisco)** rather than DS3Lib's
  Figtree tokens. Plan 05-13 had only wired colors. Same situation for
  `ShareTypography` in the Share Extension target.
- **`IOSColors` was missing every Composer canary token** added in
  Plan 05-17 (`brandPrimaryDark`, `brandPrimaryLight`, the
  `brandBorderUltraSubtle/Subtle/Strong` ramp, `statusInfo`,
  `statusSuccess`, `statusErrorMain`, `statusWarning`, `textTertiary`).
  iOS code that wanted those tokens had to import `DS3Lib` directly,
  bypassing the re-export pattern.
- **iOS Login had the iOS mirror of Gap 19** — the iPad branch wrapped
  `loginContent` in a `ZStack { IOSColors.background; loginContent
  .background(IOSColors.secondaryBackground) }`, producing a thin
  background border around the card.
- **iOS Project emblems hardcoded `Color.orange` + black label**
  (`ProjectListView`, `DriveDetailView`, `DriveConfirmView`) — a
  pre-Plan 05-13 pattern that survived the previous brand sweep.

### Task 1: Figtree iOS bundling + IOSColors/Typography expansion

- Added 8 new `PBXBuildFile` entries in `project.pbxproj`
  (`A10519010000000000000001..4` for DS3DriveApp,
  `A10519020000000000000001..4` for DS3DriveShareExtension), each
  pointing at the existing `A1051700000000000000000N` file references
  for the four Figtree TTFs.
- Added the new build files to the DS3DriveApp Resources phase
  (`43FD101A93E86DAE71CA8882`) and the DS3DriveShareExtension Resources
  phase (`D5FB2DE42F6BF36700D25CE6`).
- `IOSColors` extended to expose: `brandPrimaryDark`, `brandPrimaryLight`,
  `brandBorderUltraSubtle`, `brandBorderSubtle`, `brandBorderStrong`,
  `brandDivider`, `statusSuccess`, `statusErrorMain`, `statusWarning`,
  `statusInfo`, `textTertiary`. Status legacy aliases
  (`statusSynced/Syncing/Error/Paused/CloudOnly/Conflict`) re-routed to
  the canary palette.
- `IOSTypography` rewired: every alias (`title`, `title2`, `headline`,
  `body`, `caption`, `footnote`) now points at the corresponding
  `DS3Lib.DS3Typography.*` Figtree token. Added `button` alias.

### Task 2: iOS view sweep

- **`IOSLoginView`** — replaced split iPhone/iPad layout with a single
  `ZStack { IOSGradients.brandVerticalBackground.ignoresSafeArea();
  loginContent }`. iPad max-width wrapper retained but the second
  background fill (the source of the "blue border around dark card"
  bug) is dropped. "DS3 Drive" title now uses `IOSTypography.title2`
  (Figtree SemiBold 22) with explicit `IOSColors.primaryText`.
- **`IOSMFAView`** — wrapped content in `ZStack {
  IOSGradients.brandVerticalBackground.ignoresSafeArea(); ... }` so the
  2FA sheet renders on the brand backdrop. Title font upgraded to
  `IOSTypography.title2`. Shield icon recolored to
  `IOSColors.brandPrimary`.
- **`IOSAppRootView`** — wrapped the login/main routing in a
  `ZStack { IOSColors.background.ignoresSafeArea(); ... }` so the brand
  backdrop is visible during login → main transitions.
- **`DriveListView` / `DriveDetailView` / `IOSSettingsView`** — added
  `.scrollContentBackground(.hidden).background(IOSColors.background)`
  to the `List` so the system grouped background no longer leaks
  through.
- **`EmptyDrivesView`** — wrapped in
  `ZStack { IOSColors.background.ignoresSafeArea(); ... }`; title
  upgraded to `IOSTypography.title2`; icon recolored to
  `IOSColors.brandPrimary`.
- **Project emblems** (`DriveDetailView`, `ProjectListView`,
  `DriveConfirmView`) — replaced `Color.orange` fill + black label with
  `IOSColors.brandPrimary` fill + white label, using
  `IOSTypography.captionBold` / `IOSTypography.caption`.

### Task 3: Share Extension typography rewire

- `ShareTypography` aliases now point at `DS3Lib.DS3Typography.*`
  (Figtree). Added `captionBold` and `button` aliases. Every
  `Share*View.swift` automatically inherits Figtree typography with
  zero per-file edits — they all reference `ShareTypography.body` /
  `headline` / `caption` etc.

### Task 3a: Duplicate-warning token fix

`DriveConfirmView.duplicateWarning` was using `Color.orange` for the
icon, text, and background. Replaced with `IOSColors.statusWarning`
(canary `#FFB74D`) for consistency with the brand status palette.

## Verification

### macOS

`xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive
-destination 'platform=macOS'` after each task → **BUILD SUCCEEDED**.
The macOS build proves DS3Lib changes consumed by the iOS targets
remain source-compatible (no API drift).

### iOS

`xcodebuild` with `generic/platform=iOS` is rejected in this
environment with `iOS 26.4 is not installed` (same situation as the
Plan 05-13 / 05-17 SDK gap). CI runs the iOS build job and is the
gate for compile-time verification.

### Source-grep matrix

| Criterion | Path | Result |
|---|---|---|
| `Figtree-Regular.ttf` references in Resources phase 43FD101A | `project.pbxproj` | 1 (DS3DriveApp) |
| `Figtree-Regular.ttf` references in Resources phase D5FB2DE4 | `project.pbxproj` | 1 (DS3DriveShareExtension) |
| `DS3Lib.DS3Typography` in iOS code | `DS3DriveApp/Views/Common/IOSDesignSystem.swift` | 7 hits |
| `DS3Lib.DS3Typography` in Share Extension code | `DS3DriveShareExtension/ShareExtensionView.swift` | 6 hits |
| `Color.orange` (raw) | `DS3DriveApp/Views/`, `DS3DriveShareExtension/` | 0 hits |
| `Color.black` (raw) | `DS3DriveApp/Views/`, `DS3DriveShareExtension/` | 0 hits |
| `brandVerticalBackground` | `DS3DriveApp/Views/Login/` | 2 hits (login + MFA) |

### iOS gap matrix

See `.planning/phases/05-ux-polish/05-19-IOS-GAPS.md` for the full
investigation document — every iOS view + Share Extension view audited.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Figtree TTFs missing from iOS Copy Bundle Resources
phases**

- **Found during:** Task 1 investigation.
- **Issue:** Plan 05-17 SUMMARY claimed Figtree was bundled in all
  targets, but the actual `project.pbxproj` only added `Figtree-*.ttf`
  to the DS3Drive (macOS) Resources phase. iOS app and Share Extension
  Resources phases had `Figtree-Regular.ttf` listed in their
  `UIAppFonts` Info.plist key, but no actual file in the bundle —
  iOS would silently fall back to the system font.
- **Fix:** Created 8 new `PBXBuildFile` entries
  (`A10519010000000000000001..4`,
  `A10519020000000000000001..4`) re-using the existing file references,
  and added them to the iOS app + Share Extension Resources phases.
- **Files modified:** `DS3Drive.xcodeproj/project.pbxproj`.
- **Commit:** `ff450d0`.

**2. [Rule 2 — Critical functionality] `IOSColors` missing canary
tokens**

- **Found during:** Task 1 investigation.
- **Issue:** Plan 05-17 added a new canary palette to
  `DS3Lib.DS3Colors` (`brandPrimaryDark`, `brandPrimaryLight`,
  `brandBorderUltraSubtle/Subtle/Strong`, `statusSuccess/ErrorMain
  /Warning/Info`, `textTertiary`) but `IOSColors` only re-exported the
  Plan 05-13 set. iOS views that needed canary tokens had to bypass
  the re-export pattern by importing `DS3Lib` directly.
- **Fix:** Extended `IOSColors` with re-exports for all canary tokens.
- **Commit:** `ff450d0`.

**3. [Rule 1 — Bug] iOS Login layered-background anti-pattern (Gap 19
mirror)**

- **Found during:** Task 2 sweep.
- **Issue:** iPad branch of `IOSLoginView.body` was
  `ZStack { IOSColors.background; loginContent
  .background(IOSColors.secondaryBackground).clipShape(...) }`. The
  outer fill produced a visible border around the inner card — the
  iOS mirror of Gap 19 (which Plan 05-18 fixed for macOS).
- **Fix:** Single `ZStack` with the brand gradient as the only
  backdrop; iPad max-width wrapper retained but the second background
  fill is removed.
- **Commit:** `9a3a38f`.

**4. [Rule 2 — Critical functionality] Hardcoded `Color.orange` project
emblems**

- **Found during:** Task 2 sweep.
- **Issue:** `ProjectListView`, `DriveDetailView`, `DriveConfirmView`
  hardcoded `Color.orange` fill + black text for project emblems —
  pre-Plan 05-13 pattern.
- **Fix:** Replaced with `IOSColors.brandPrimary` fill + white label.
- **Commit:** `9a3a38f`.

**5. [Rule 1 — Bug] `Color.orange` in duplicate-drive warning chrome**

- **Found during:** post-Task 3 grep verification.
- **Issue:** `DriveConfirmView.duplicateWarning` used `Color.orange`
  for icon, text, and background — should use the canary status
  warning token.
- **Fix:** Replaced with `IOSColors.statusWarning`.
- **Commit:** `c293e03`.

### Out of scope discoveries

- **iOS state machine consumes `AggregateStatus`?** —
  `IOSDriveViewModel` has its own per-drive status machine (Plan 05-15
  added `AggregateStatus` only on macOS). Whether iOS needs the same
  treatment requires runtime verification on iOS — out of scope for a
  brand sweep, tracked as potential 05-20 followup.
- **iOS app icon parity with macOS Plan 05-08** — single 1024
  universal asset; whether it matches the polished macOS icon needs
  visual verification on a device.
- **`DS3Lib.colorForProject(_:)`** — does not exist in DS3Lib (only in
  the local macOS `DS3Colors` enum). A future cleanup plan could move
  it to DS3Lib so iOS gets hashed per-project emblem colors instead of
  a single brand color.

## Issues Encountered

- **iOS SDK unavailable** — agent's local Xcode lacks `iOS 26.4`
  platform; iOS build verification deferred to CI. Same situation as
  Plan 05-13 / 05-17.
- **GPG signing not raised** — pre-commit hooks ran SwiftFormat without
  GPG agent issues this session.

## Known Stubs

None — every iOS view and Share Extension view now consumes brand
tokens via `IOSColors` / `IOSTypography` / `ShareColors` /
`ShareTypography`. No placeholder data, no hardcoded fallback values.

## Threat Flags

None — pure design-system / UI polish change. No new endpoints, auth
paths, file access patterns, or schema changes.

## Checkpoint: Human Visual Verification

**Status:** Pending user review.

This plan closes at a `checkpoint:human-verify` gate. The user needs to:

1. Open the project in Xcode, select an iOS Simulator (or a connected
   device), Run.
2. Walk through Login → Drive List (empty + populated) → Setup Wizard
   (project → bucket → prefix → confirm) → Drive Detail → Settings.
3. Open Photos, share an image via the Share Extension → walk through
   drive picker → folder picker → upload progress.
4. For each surface confirm:
   - Backdrop is brand dark `#0E0E15` (via the vertical gradient).
   - Typography is Figtree (visible on letters `a` / `g`).
   - Primary CTAs are brand blue `#005CE8`.
   - No hardcoded orange project emblems remain.
   - iOS Login is hero gradient + form (no blue border wrapping a dark
     card on iPad).
5. Compare side-by-side with macOS — both platforms should feel like
   the same product after Plan 05-18 lands.
6. Respond with "approved" or list specific iOS mismatches.

## Commits

- `ff450d0` — feat(05-19): bundle Figtree in iOS targets and expand IOSColors/IOSTypography
- `9a3a38f` — feat(05-19): sweep iOS views with corrected brand tokens
- `085780f` — feat(05-19): rewire ShareTypography to Figtree via DS3Lib
- `c293e03` — fix(05-19): use statusWarning token for duplicate-drive warning

## Self-Check: PASSED

- FOUND: `.planning/phases/05-ux-polish/05-19-IOS-GAPS.md`
- FOUND (modified): `DS3Drive.xcodeproj/project.pbxproj` (8 new PBXBuildFile entries `A10519...`, both iOS Resources phases populated)
- FOUND (modified): `DS3DriveApp/Views/Common/IOSDesignSystem.swift` (canary tokens + Figtree)
- FOUND (modified): `DS3DriveApp/Views/App/IOSAppRootView.swift` (brand background ZStack)
- FOUND (modified): `DS3DriveApp/Views/Login/IOSLoginView.swift` (single hero ZStack)
- FOUND (modified): `DS3DriveApp/Views/Login/IOSMFAView.swift` (brand backdrop)
- FOUND (modified): `DS3DriveApp/Views/Dashboard/DriveListView.swift` (scrollContentBackground hidden)
- FOUND (modified): `DS3DriveApp/Views/Dashboard/DriveDetailView.swift` (scrollContentBackground hidden + emblem)
- FOUND (modified): `DS3DriveApp/Views/Dashboard/EmptyDrivesView.swift` (brand backdrop)
- FOUND (modified): `DS3DriveApp/Views/Setup/ProjectListView.swift` (emblem)
- FOUND (modified): `DS3DriveApp/Views/Setup/DriveConfirmView.swift` (emblem + statusWarning)
- FOUND (modified): `DS3DriveApp/Views/Settings/IOSSettingsView.swift` (scrollContentBackground hidden)
- FOUND (modified): `DS3DriveShareExtension/ShareExtensionView.swift` (Figtree)
- FOUND commit: `ff450d0`
- FOUND commit: `9a3a38f`
- FOUND commit: `085780f`
- FOUND commit: `c293e03`
- macOS Build (after each task): `** BUILD SUCCEEDED **`

---
*Phase: 05-ux-polish*
*Completed (code-complete, awaiting visual checkpoint): 2026-04-07*
