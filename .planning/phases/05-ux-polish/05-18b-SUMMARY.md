---
phase: 05-ux-polish
plan: 18b
subsystem: tray-and-preferences
tags: [tray, preferences, brand, gap-closure, animation]
status: awaiting-human-verification
requirements: [UX-01]
dependency-graph:
  requires:
    - 05-17-SUMMARY.md
    - 05-18a-SUMMARY.md
  provides:
    - EmptyDrivesHint (tray empty-state component)
    - AggregateStatusRowIcon (rotation-animated header icon)
    - Brand backdrop applied to Preferences scene
  affects:
    - 05-18c-PLAN (tutorial + branding sweep)
tech-stack:
  added:
    - "AggregateStatusRowIcon (private subview owning rotation @State)"
  patterns:
    - "rotationEffect + linear repeatForever animation as replacement for SF Symbol .pulse effect"
    - "preferredColorScheme(.dark) on Settings/Window scene to lock brand chrome"
key-files:
  created:
    - DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift
  modified:
    - DS3Drive/Views/Tray/Views/TrayMenuView.swift
    - DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift
    - DS3Drive/Views/Preferences/Views/PreferencesView.swift
    - DS3Drive/DS3DriveApp.swift
    - DS3Drive.xcodeproj/project.pbxproj
    - DS3Drive/Assets/Localizable.xcstrings
decisions:
  - "Replace .symbolEffect(.pulse) with rotationEffect + linear repeatForever — pulse reads as a vague breathing glow, rotation reads as actual sync motion. Pattern owns @State in a dedicated subview so the animation survives parent body recomputation"
  - "Empty-drives hint REPLACES SpeedSummaryView for the zero-drives case (not added alongside) — SpeedSummaryView has nothing to summarise when drives.isEmpty so showing it next to the hint would be visually noisy"
  - "preferredColorScheme(.dark) is forced on the Preferences Window scene — without it the macOS chrome behind the SwiftUI content can leak the system appearance through tab bar regions"
  - "Per-tab .brandCard() wrapping is deferred — would require touching 5+ tab bodies (General/Account/Sync/Connection/Trash) and risks regressing layout. Tracked as a Gap 24 follow-up"
  - "Signed-out tray styling NOT touched in this plan — TrayMenuView already routes through TrayMenuItem which carries the brand hover chip + brandTextPrimary, and the loggedOutMenu already inherits the brandBackground applied to the root Group at TrayMenuView body. The footer also already uses the brand surface. No additional work was needed beyond what Plan 05-12 + 05-17 already shipped"
metrics:
  duration: "~20m"
  completed: 2026-04-07
---

# Phase 05 Plan 18b: Round 2 Gap Closure — Tray + Preferences Brand Sweep Summary

Closes Gaps 18, 23, 24, 30. Second of three split agents from 05-18.

## What changed

### Task 1 — Tray empty-drives hint + rotation sync icon (Gaps 23, 30)

**`DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift` (NEW):**

- Vertical stack with `tray` SF Symbol, "No drives yet" headline, and a
  caption prompting the user to click "Add a new Drive".
- Uses brand tokens: `brandTextPrimary`, `brandTextSecondary`,
  `DS3Spacing.md`/`.lg`/`.sm`, `DS3Typography.bodyMedium`/`.caption`.
- Localized via NSLocalizedString keys `tray.empty.title` and
  `tray.empty.subtitle`.
- Registered in `DS3Drive.xcodeproj/project.pbxproj` (PBXBuildFile +
  PBXFileReference + group entry + Sources build phase entry).

**`DS3Drive/Views/Tray/Views/TrayMenuView.swift`:**

- `loggedInMenu`: when `ds3DriveManager.drives.isEmpty`, render
  `EmptyDrivesHint()` + `brandDivider` instead of `SpeedSummaryView`. The
  empty-state branch is gated as `if/else` so SpeedSummaryView is never
  asked to render with zero drives.
- Replaced `.symbolEffect(.pulse, options: .repeating, isActive:)` on
  `aggregateStatusRow`'s leading icon with a new `AggregateStatusRowIcon`
  private subview that owns `@State private var isRotating` and applies
  `rotationEffect(.degrees(isRotating ? 360 : 0))` with
  `.linear(duration: 1.5).repeatForever(autoreverses: false)`.
- Subview pattern matters because `aggregateStatusRow` is a computed
  property — moving the @State up into TrayMenuView would have re-set
  the animation on every body recomputation.

**`DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift`:**

- Same swap: `.symbolEffect(.pulse)` → `rotationEffect` + linear
  repeatForever animation. Owns `@State private var isRotating` directly
  (the footer is a struct, not a computed property).
- Added `.onChange(of: statusIcon.animated)` to start/stop the rotation
  when the aggregate status flips between syncing and non-syncing while
  the tray remains visible.

### Task 2 — Preferences brand background (Gap 24)

**`DS3Drive/Views/Preferences/Views/PreferencesView.swift`:**

- Existing `.background(DS3Colors.brandBackground)` was extended to
  `.background(DS3Colors.brandBackground.ignoresSafeArea())` so the
  brand color reaches into any title bar safe-area.
- Added `.preferredColorScheme(.dark)` so Form/List/TabView controls
  inside the tab bodies inherit dark appearance.

**`DS3Drive/DS3DriveApp.swift`:**

- Wrapped the `Window("Preferences", ...)` content in a `Group { ... }`
  and applied `.background(DS3Colors.brandBackground.ignoresSafeArea())`
  + `.preferredColorScheme(.dark)` at the scene level so the macOS
  Window host paints brand-dark behind any chrome the SwiftUI Window
  doesn't cover.
- Loading-state text restyled from `DS3Colors.secondaryText` (legacy)
  to `DS3Colors.brandTextSecondary` (current brand token).

## Verification

| Gap | Description                              | Status                                                                         |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------ |
| 18  | Signed-out tray uses brand surface       | Already shipped via Plan 05-12 (TrayMenuItem) + 05-17 (root background). No additional work needed. |
| 23  | Empty-drives state has actionable hint   | Done — EmptyDrivesHint shown when `drives.isEmpty`                             |
| 24  | Preferences window uses brand backdrop   | Done — brandBackground applied at both PreferencesView and Settings scene root |
| 30  | Sync icons use rotation, not pulse       | Done — both `TrayMenuView:245` and `TrayMenuFooterView:19` swapped              |

## Build verification

```
xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination "platform=macOS" build
** BUILD SUCCEEDED **
```

`grep "symbolEffect.*pulse" DS3Drive/Views/Tray` returns only doc-comment
references in code; no functional `.symbolEffect(.pulse(...))` invocations
remain.

## Out of scope (deferred)

- **Per-tab `.brandCard()` wrapping** for General/Account/Sync/Connection/Trash
  — would touch 5+ tab body files, risks layout regressions, and is too
  much for a single plan. Capture as a Gap 24 follow-up plan if the visual
  diff after this plan still feels insufficient.
- **Signed-out tray restyling** — verified at runtime via Plan 05-12 +
  05-17 to already use brand chrome (via TrayMenuItem + the root
  `.background(DS3Colors.brandBackground)` on TrayMenuView body). No
  additional changes needed in this plan.

## Deviations from Plan

None — plan executed as written. The plan's "verify the loggedOutMenu
might need brand chrome" hedge was checked and found unnecessary; documented
above under Out of scope.

## Commits

- `c22522e` feat(05-18b): tray empty-drives hint and rotation sync icon
- `2176bb2` feat(05-18b): apply brand background to Preferences scene

## Checkpoint

This plan has a visual checkpoint. The user must build & run from Xcode and
verify:

1. Sign in with no drives configured → tray should show the "No drives yet"
   hint with the tray icon and the "Click 'Add a new Drive' below to get
   started" subtitle, NOT a blank gap and NOT "All drives up to date".
2. Trigger a sync (drag a file into a synced drive) → the footer status
   icon and the aggregate header icon should ROTATE smoothly, not pulse.
3. Open Preferences from the tray → the window background should be
   near-black (`#0E0E15`), not the default macOS dark gray.

## Self-Check: PASSED

- FOUND: DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift
- FOUND: c22522e in git log
- FOUND: 2176bb2 in git log
- BUILD SUCCEEDED on DS3Drive scheme (macOS)
