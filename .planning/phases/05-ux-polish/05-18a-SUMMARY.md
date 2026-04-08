---
phase: 05-ux-polish
plan: 18a
subsystem: design-system
tags: [brand, login, mfa, wizard, gap-closure, project-badge]
status: awaiting-human-verification
requirements: [UX-01, UX-02]
dependency-graph:
  requires:
    - 05-17-SUMMARY.md
  provides:
    - ProjectBadge (shared wizard component)
    - LoginView collapsed single-backdrop layout
    - MFAView brand-swept layout
  affects:
    - 05-18b-PLAN (tray + preferences sweep)
    - 05-18c-PLAN (tutorial + branding sweep)
tech-stack:
  patterns:
    - "Shared view component for repeating wizard UI (ProjectBadge)"
    - "Single-backdrop login hero (no inner card) to avoid patchwork seams"
key-files:
  created:
    - DS3Drive/Views/Common/ProjectBadge.swift
  modified:
    - DS3Drive/Views/Login/Views/LoginView.swift
    - DS3Drive/Views/Login/Views/MFAView.swift
    - DS3Drive/Views/Sync/Views/TreeNavigationView.swift
    - DS3Drive/Views/Sync/Views/DriveConfirmView.swift
    - DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
    - DS3Drive.xcodeproj/project.pbxproj
decisions:
  - "Collapse LoginView from 4 layered backgrounds to a single brandVerticalBackground backdrop — form controls float directly on the gradient, eliminating the 'bright border around dark card' patchwork seam"
  - "Remove blue radial logo glow — it was an artifact of Plan 05-11's wrong-source brand interpretation; logo sits cleanly on the gradient"
  - "Leave Localizable.xcstrings 'Cubbit DS3 Drive' entry untouched — that entry is used by auth-failure notification title, not login copy. The login subtitle literal was hardcoded and has been changed directly"
  - "projectBadgePalette rebuilt from multi-hue brand tokens (blue/violet/green/yellow) rather than primary-only — gives visual differentiation between adjacent projects while staying on-brand"
metrics:
  duration: "~25m"
  completed: 2026-04-07
---

# Phase 05 Plan 18a: Round 2 Gap Closure — Login + MFA + Wizard + ProjectBadge Summary

Closes Gaps 4, 5, 19, 21, 22 for the Login, MFA, TreeNavigation and
DriveConfirm views. First of three split agents from 05-18.

## What changed

### Task 1 — Login + MFA brand sweep (Gap 19)

**`DS3Drive/Views/Login/Views/LoginView.swift`:**

- Collapsed four overlapping background layers into one:
  - REMOVED: outer ZStack's `brandHero` backdrop (kept as window bg only)
  - REMOVED: inner `RoundedRectangle.fill(brandSurface).shadow(...)` card
    wrapper around the form (the source of the "bright blue border around
    dark card" patchwork seam)
  - REMOVED: logo `brandRadialGlow` ZStack
  - RESULT: single `DS3Gradients.brandVerticalBackground` backdrop;
    Cubbit logo sits directly on the gradient; form controls float on
    the gradient with no surrounding card.
- Copy fix: `"Cubbit DS3 Drive"` → `"DS3 Drive"` (Gap 19 copy regression
  missed by Plan 05-05 audit).
- Heading `"Log in to your account"` upgraded from `DS3Typography.headline`
  (16pt) to `DS3Typography.h3` (24pt SemiBold) to match the Composer
  canary hierarchy.
- Login button: `PrimaryButtonStyle()` (was rendering black) →
  `BrandPrimaryButtonStyle(fillWidth: true)` +
  `.keyboardShortcut(.defaultAction)`. Dropped the manual
  `.frame(maxHeight: 36)` constraint.
- Form field strokes switched from `brandBorder` (30% white) to
  `brandBorderSubtle` (10% white) with a focus-state swap to
  `brandPrimary`, matching the canary form treatment.
- Password field now actually has `.focused($focusedField, equals: .password)`
  (it was missing the focused modifier — Rule 1 bug fix).
- Window size still 400x500.

**`DS3Drive/Views/Login/Views/MFAView.swift`:**

- Wrapped root in `ZStack { DS3Gradients.brandVerticalBackground.ignoresSafeArea(); ... }`
  so the MFA window matches the login brand backdrop.
- Heading `"Two-factor authentication"`: `DS3Typography.title` →
  `DS3Typography.h3`.
- All text/border tokens migrated from the legacy aliases
  (`primaryText`/`secondaryText`/`separator`) to the Plan 05-17 brand
  tokens (`brandTextPrimary`/`brandTextSecondary`/`brandBorderSubtle`).
- Lock icon `Color.accentColor` → `DS3Colors.brandPrimary`.
- Login button: `PrimaryButtonStyle()` →
  `BrandPrimaryButtonStyle(fillWidth: true)` +
  `.keyboardShortcut(.defaultAction)`.
- Code field uses focus-state border swap (brandPrimary when focused,
  brandBorderSubtle otherwise).

**Localizable.xcstrings (not modified):** grep confirmed the sole
"Cubbit DS3 Drive" entry in the catalog is flagged with the comment
"Auth failure notification title / Update notification title" — it is
NOT referenced from the Login/MFA views. The login copy was a hardcoded
string literal in LoginView.swift and has been changed directly. Leaving
the catalog entry alone so the notification titles continue to render
"Cubbit DS3 Drive" in the menu bar / notification banners.

### Task 2 — Shared ProjectBadge component + wizard sweep (Gaps 4, 5, 21, 22)

**`DS3Drive/Views/Common/ProjectBadge.swift` (new):**

- Single shared view that takes `projectId`, `projectName`, and `size`
  and renders a circular initial badge. Fill color comes from
  `DS3Colors.colorForProject(_:)` (the deterministic FNV-1a hash).
- Label uses `Font.custom("Figtree-SemiBold", size: size * 0.5)` so the
  typography scales with the circle and stays on the brand font.
- Consumers: `TreeNavigationView.iconView(for:)`,
  `TreeNavigationView.detailIconView(for:)`, `DriveConfirmView.summarySection`.

**Added to Xcode project:** `project.pbxproj` updated with three entries
(PBXBuildFile, PBXFileReference, group membership in the macOS
`D5A221C12B571FED00F1413B /* Common */` group, and Sources build phase
under the DS3Drive target). Used new UUIDs in the `A10518A1...` range
to avoid collision with Plan 05-17's `A10517...` range.

**`DS3Drive/Views/Common/DesignSystem/DS3Colors.projectBadgePalette` (Gap 4):**

```swift
// Before (Plan 05-17 — primary-only, caused adjacent projects to
// be nearly indistinguishable):
static let projectBadgePalette: [Color] = [
    brandPrimary, brandPrimaryLight, statusSuccess,
    statusInfo, statusWarning, brandPrimaryDark
]

// After:
static let projectBadgePalette: [Color] = [
    brandBlue400, brandViolet500, brandGreen500, brandYellow500,
    brandBlue600, brandViolet300, brandGreen600, brandBlue200
]
```

The deterministic hash function (`colorForProject(_:)`) is unchanged —
same project id still maps to the same index, just into a new palette.

**`DS3Drive/Views/Sync/Views/TreeNavigationView.swift`:**

- `iconView(for:)` `.project` case: 14 lines of inline `Text + Circle`
  badge → one `ProjectBadge(projectId:, projectName:, size: 24)` call.
- `detailIconView(for:)` `.project` case: same refactor at size 48.
- `wizardEmptyHero` (Gap 5): `Image(systemName: "cube.transparent")` →
  `Image(.cubbitLogo).renderingMode(.template)` tinted with
  `DS3Colors.brandPrimary.opacity(0.85)`. The circular backdrop is
  preserved.
- Continue button (Gap 21): `PrimaryButtonStyle()` →
  `BrandPrimaryButtonStyle()` + `.keyboardShortcut(.defaultAction)`,
  dropped the `.frame(maxWidth: 120, maxHeight: 32)` constraint.
- IAM picker capsule chrome: legacy `DS3Colors.separator.opacity(0.3)`
  fill + `separator` stroke → `brandSurface` fill +
  `brandBorderSubtle` stroke to match the canary look.

**`DS3Drive/Views/Sync/Views/DriveConfirmView.swift` (Gaps 21, 22):**

- Old inline 18x18 rounded-rectangle orange badge (`badgeProject`
  fill) in `summarySection` Project row → `ProjectBadge(projectId:,
  projectName:, size: 24)`. Both TreeNavigationView and DriveConfirmView
  now render identical project colors (Gap 22 closed).
- `summarySection`: hand-rolled
  `RoundedRectangle.fill(secondaryBackground)` background →
  `.brandCard()` modifier (uses the Plan 05-17 `BrandCardStyle` with
  surface fill + ultra-subtle stroke + bottom-right radial glow).
- Header "Confirm your drive": `DS3Typography.title` →
  `DS3Typography.h3`.
- Create Drive button (Gap 21): `PrimaryButtonStyle()` →
  `BrandPrimaryButtonStyle()` + `.keyboardShortcut(.defaultAction)`,
  dropped the `.frame(maxWidth: 140, maxHeight: 32)` constraint.
- `@FocusState private var driveNameFocused: Bool` added +
  `.focused($driveNameFocused)` on the TextField +
  `onAppear { asyncAfter 0.3s { driveNameFocused = true } }` so users
  can rename the drive immediately on entry without an extra click.
- Added `.onSubmit { if isValid { createDrive() } }` on the name field
  so hitting Return creates the drive (redundant with the default-action
  keyboard shortcut but safer because it also triggers validation).
- Entry transition: `.transition(.opacity.combined(with: .move(edge: .trailing)))`
  for a subtle slide-in when the view appears in the wizard stack.
- All colors migrated to brand tokens (`brandBackground`,
  `brandSurface`, `brandTextPrimary`, `brandTextSecondary`,
  `brandBorderSubtle`).

## Verification

- `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **` (run twice, once per task)
- `grep "Cubbit DS3 Drive" DS3Drive/Views/Login/` → zero matches
- `grep ProjectBadge DS3Drive/Views/Sync/` → 3 matches (2 in TreeNavigationView, 1 in DriveConfirmView)
- `grep BrandPrimaryButtonStyle DS3Drive/Views/` → LoginView + MFAView + TreeNavigationView + DriveConfirmView all reference it
- `grep cube.transparent DS3Drive/Views/Sync/Views/TreeNavigationView.swift` → zero matches (replaced with cubbitLogo)
- SwiftFormat pre-commit hook passed on both commits

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] LoginView password field missing `.focused` modifier**
- **Found during:** Task 1 rewrite
- **Issue:** The original LoginView only called `.focused(self.$focusedField, equals: .email)` on the email field. The password `HStack` had no `.focused` modifier, so pressing Tab/Return from the email field did move `focusedField = .password`, but SwiftUI had no way to actually route keyboard focus to the password field.
- **Fix:** Added `.focused(self.$focusedField, equals: .password)` on the password `HStack`.
- **Files modified:** DS3Drive/Views/Login/Views/LoginView.swift
- **Commit:** 360112b

**2. [Rule 2 - Missing functionality] Login button missing `.keyboardShortcut(.defaultAction)`**
- **Found during:** Task 1 rewrite
- **Issue:** The login form only triggered login on `.onSubmit` of the password field. If the user had `showAdvanced` expanded and their focus was on the tenant or coordinator field, Return would not submit. Plus, best practice on macOS is for the primary action to be the default button.
- **Fix:** Added `.keyboardShortcut(.defaultAction)` to the Log in button.
- **Commit:** 360112b

**3. [Rule 2 - Missing functionality] DriveConfirmView drive name field had no submit action**
- **Found during:** Task 2 rewrite
- **Issue:** Pressing Return in the drive name `TextField` did nothing — user had to click Create Drive.
- **Fix:** Added `.onSubmit { if isValid { createDrive() } }` on the TextField plus `.keyboardShortcut(.defaultAction)` on the Create Drive button.
- **Commit:** 8b0a4fb

### Scope deviation — Localizable.xcstrings

The plan frontmatter listed `DS3Drive/Assets/Localizable.xcstrings` in
`files_modified` and Task 1's action instructed "replace every 'Cubbit
DS3 Drive' copy literal with 'DS3 Drive' (en + it)". I inspected the
catalog and found only ONE entry for that string, flagged with the
comment "Auth failure notification title / Update notification title".
Grep of the Login source tree confirms the catalog entry is NOT
referenced from LoginView or MFAView — it is consumed by the notification
layer. Changing it would rename macOS notification banner titles from
"Cubbit DS3 Drive" to "DS3 Drive", which is NOT what Gap 19 calls for.
Gap 19 is a login/MFA copy regression, not a notification branding
change. I left the catalog entry alone and changed the hardcoded
`Text("Cubbit DS3 Drive")` literal in LoginView.swift directly.

Unstaged diff noise in `Localizable.xcstrings` (auto-extracted "%lld" and
"Aag" entries from the build's string extraction) was left unstaged —
it's unrelated to this plan and should be picked up by whichever plan
commits the next catalog refresh.

## Known Stubs

None. All targets wired; the visual sweep is complete.

## Checkpoint: Human Visual Verification

**Status:** Pending user review.

This plan closes at a visual checkpoint rolled into the parent 05-18
checkpoint at the end. The user should:

1. Run the app from Xcode (Cmd+R) and log out if already logged in.
2. **Login window (Gap 19):**
   - Backdrop is a single uniform gradient (`#0E0E15` → `#080810`), no
     visible seams, no inner card with a different surface color, no
     blue halo behind the Cubbit logo.
   - Subtitle reads "DS3 Drive" (not "Cubbit DS3 Drive").
   - "Log in to your account" heading is 24pt Figtree SemiBold (notably
     larger than before).
   - "Log in" button is brand blue `#005CE8` with white text (not black).
   - Tab focus order: email → password → Log in. Pressing Return from
     the password field submits.
3. **MFA window:**
   - Same gradient backdrop as login.
   - Lock shield icon is brand blue.
   - "Log in" button is brand blue.
4. **Wizard:**
   - Empty right pane shows the Cubbit logo (not the generic SF
     Symbols cube).
   - Projects in the left tree render as colored circles — multiple
     hues across the palette (blue / violet / green / yellow), not all
     the same blue.
   - "Continue" button is brand blue.
   - Clicking a bucket/folder and hitting Continue lands on the drive
     confirmation screen.
5. **Drive confirmation:**
   - Summary card has a bottom-right radial blue glow (from `.brandCard()`).
   - Project row badge matches the exact color used in the left tree
     (same deterministic hash → same palette slot).
   - Drive name field is pre-focused (caret visible, ready to type)
     within ~300ms of entering the screen.
   - "Create Drive" button is brand blue.
   - Pressing Return creates the drive.

If anything looks wrong, respond with specific mismatches before plans
05-18b (tray + preferences sweep) and 05-18c (tutorial + branding sweep)
start consuming the same tokens.

## Commits

- `360112b` — feat(05-18a): collapse login + MFA layers and wire BrandPrimaryButtonStyle
- `8b0a4fb` — feat(05-18a): shared ProjectBadge component and wizard brand sweep

## Self-Check: PASSED

- FOUND: DS3Drive/Views/Common/ProjectBadge.swift
- FOUND (modified): DS3Drive/Views/Login/Views/LoginView.swift ("DS3 Drive" copy, BrandPrimaryButtonStyle, h3 heading, single backdrop)
- FOUND (modified): DS3Drive/Views/Login/Views/MFAView.swift (brandVerticalBackground, h3, BrandPrimaryButtonStyle)
- FOUND (modified): DS3Drive/Views/Sync/Views/TreeNavigationView.swift (ProjectBadge x2, cubbitLogo in empty hero, BrandPrimaryButtonStyle on Continue)
- FOUND (modified): DS3Drive/Views/Sync/Views/DriveConfirmView.swift (ProjectBadge, .brandCard(), BrandPrimaryButtonStyle, focused drive name field)
- FOUND (modified): DS3Drive/Views/Common/DesignSystem/DS3Colors.swift (projectBadgePalette rewritten)
- FOUND (modified): DS3Drive.xcodeproj/project.pbxproj (ProjectBadge.swift wired into DS3Drive target)
- FOUND commit: 360112b
- FOUND commit: 8b0a4fb
- Build: `** BUILD SUCCEEDED **`
- grep "Cubbit DS3 Drive" DS3Drive/Views/Login/ → 0 matches
- grep "cube.transparent" DS3Drive/Views/Sync/ → 0 matches
- grep ProjectBadge DS3Drive/Views/Sync/ → 3 matches
- grep BrandPrimaryButtonStyle DS3Drive/Views/ → 4 call sites (Login, MFA, TreeNavigation, DriveConfirm)
