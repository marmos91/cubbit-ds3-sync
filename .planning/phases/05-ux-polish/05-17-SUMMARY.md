---
phase: 05-ux-polish
plan: 17
subsystem: design-system
tags: [brand, tokens, typography, figtree, composer-canary, gap-31]
status: awaiting-human-verification
requirements: [UX-01, UX-06]
dependency-graph:
  requires:
    - 05-11-SUMMARY.md  # the (now-superseded) Round 1 brand foundation
    - 05-13-SUMMARY.md  # DS3Lib cross-platform design system
  provides:
    - DS3Colors brandBg900/brandBg800/brandPrimary/brandPrimaryDark/brandPrimaryLight
    - DS3Colors brandBorderUltraSubtle/brandBorderSubtle/brandBorderStrong
    - DS3Colors textPrimary/textSecondary/textTertiary/textDisabled
    - DS3Colors statusSuccess/statusErrorMain/statusErrorDark/statusWarning/statusInfo
    - DS3Typography h1/h2/h3/bodyLarge/body/bodyMedium/button (Figtree)
    - DS3Gradients brandVerticalBackground/brandCardGlow
    - BrandCardStyle + .brandCard() view modifier
    - BrandPrimaryButtonStyle
  affects:
    - 05-18-PLAN  # auth + wizard sweep consumes new tokens
    - 05-19-PLAN  # tray + preferences sweep consumes new tokens
tech-stack:
  added:
    - "Figtree (Google Fonts, Apache 2.0) — latin subset via fonts.gstatic.com v9"
  patterns:
    - "Semantic white-alpha borders (0.04 / 0.10 / 0.30) instead of solid grey strokes"
    - "ZStack surface fill + blurred radial glow for card accents"
key-files:
  created:
    - DS3Drive/Assets/Fonts/Figtree-Regular.ttf
    - DS3Drive/Assets/Fonts/Figtree-Medium.ttf
    - DS3Drive/Assets/Fonts/Figtree-SemiBold.ttf
    - DS3Drive/Assets/Fonts/Figtree-Bold.ttf
    - DS3Drive/Views/Common/DesignSystem/DS3CardStyle.swift
    - DS3Drive/Views/Common/Buttons/BrandPrimaryButtonStyle.swift
  modified:
    - DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
    - DS3Drive/Views/Common/DesignSystem/DS3Typography.swift
    - DS3Drive/Views/Common/DesignSystem/DS3Gradients.swift
    - DS3Lib/Sources/DS3Lib/DesignSystem/DS3Colors.swift
    - DS3Lib/Sources/DS3Lib/DesignSystem/DS3Typography.swift
    - DS3Lib/Sources/DS3Lib/DesignSystem/DS3Gradients.swift
    - DS3Drive/Info.plist
    - DS3DriveApp/Info.plist
    - DS3DriveShareExtension/Info.plist
    - DS3Drive.xcodeproj/project.pbxproj
    - .planning/phases/05-ux-polish/05-11-BRAND-TOKENS.md
decisions:
  - "Adopt Composer canary tokens directly, superseding Plan 05-11 (bg #0E0E15 vs #252B30, primary #005CE8 vs #3384FF, Figtree vs system)"
  - "Keep legacy brandBlueNNN/brandGreyNNN enum entries as compatibility shims so 05-12/13/14 callers still compile without modification"
  - "Use the Google Fonts v9 latin-subset TTFs (fonts.gstatic.com) instead of the full TTFs; the DS3 Drive UI is latin-only for now, shrinks the bundle ~8x"
  - "Bundle Figtree via project.pbxproj additions (Copy Bundle Resources) + ATSApplicationFontsPath = '.'; UIAppFonts array added to DS3Drive/DS3DriveApp/DS3DriveShareExtension"
  - "Create BrandCardStyle + BrandPrimaryButtonStyle as shared helpers but DO NOT wire them into existing views — sweep is the responsibility of 05-18 / 05-19"
metrics:
  duration: "~30m"
  completed: 2026-04-07
---

# Phase 05 Plan 17: Brand Foundation REDO (Composer Canary Tokens) Summary

Redo Plan 05-11 with brand tokens extracted from the live Composer canary
product (`composer-canary.cubbit.eu`) instead of the `cubbit.io` marketing CSS.
Ships the darker `#0E0E15` / `#121212` palette, the deeper `#005CE8` primary
blue, white-alpha borders, and the Figtree font family — plus two new shared
helpers (`BrandCardStyle`, `BrandPrimaryButtonStyle`) that downstream sweep
plans 05-18 / 05-19 will apply across the app.

## What changed

### Task 1 — Figtree bundled in all targets

- Downloaded four Figtree static weights (Regular / Medium / SemiBold / Bold)
  from `fonts.gstatic.com/s/figtree/v9/*.ttf`, the latin-subset TTFs served
  by the Google Fonts CSS endpoint (Apache 2.0 licensed).
- Placed under `DS3Drive/Assets/Fonts/` and added as Copy Bundle Resources in
  the DS3Drive Xcode target via hand-edited `project.pbxproj` entries
  (`A10517000000000000000001..4` / `A10517010000000000000001..4`).
- `DS3Drive/Info.plist`: added `ATSApplicationFontsPath = "."` (macOS) and
  appended Figtree files to the existing `UIAppFonts` array.
- `DS3DriveApp/Info.plist` (iOS): added `UIAppFonts` array with all four
  Figtree filenames.
- `DS3DriveShareExtension/Info.plist`: added `UIAppFonts` array with the same
  filenames so the share sheet renders with brand typography.
- PostScript names verified via `name` table inspection:
  `Figtree-Regular` / `Figtree-Medium` / `Figtree-SemiBold` / `Figtree-Bold`
  — matching the `Font.custom(_, size:)` identifiers used in DS3Typography.
- Build log confirms the four TTFs are copied into
  `Cubbit DS3 Drive.app/Contents/Resources/`.

### Task 2 — Brand tokens rewritten (macOS + DS3Lib)

**`DS3Drive/Views/Common/DesignSystem/DS3Colors.swift`:**

- New Composer canary section with the exact Gap 31 values:
  - `brandBg900 = #0E0E15`, `brandBg800 = #121212`, `brandBg700 = #1A1A22`
  - `brandPrimary = #005CE8`, `brandPrimaryDark = #0048B5`, `brandPrimaryLight = #337CEC`
  - `statusSuccess = #26AB75`, `statusErrorMain = #E56363`,
    `statusErrorDark = #DC2D20`, `statusWarning = #FFB74D`,
    `statusInfo = #5498FF`
  - `textPrimary` (white), `textSecondary` (60%), `textTertiary` (45%),
    `textDisabled` (30%)
  - `brandBorderUltraSubtle` (4%), `brandBorderSubtle` (10%),
    `brandBorderStrong` (30%), `brandDivider` (12%)
- Adaptive dark/light tokens rewired: `brandBackground` → `#0E0E15` (dark) /
  white (light); `brandSurface` → `#121212` (dark) / white (light);
  `brandTextPrimary` / `brandTextSecondary` / `brandBorder` use pure
  white/black alpha instead of the old grey scale.
- Legacy `brandBlueNNN` / `brandGreyNNN` / `brandViolet` / `brandGreen500` /
  `brandYellow500` entries updated to the canary values where they mapped
  cleanly (grey800 → `#121212`, grey900 → `#0E0E15`, green500 → `#26AB75`,
  yellow500 → `#FFB74D`) and left for compatibility with 05-12 / 05-13 /
  05-14 callers.
- Project badge palette rebuilt from canary hues.
- All pre-existing symbols preserved (`statusSynced` / `statusSyncing` /
  `statusError` / `statusPaused` / `statusCloudOnly` / `statusConflict`,
  `accent`, `background`, `secondaryBackground`, `primaryText`,
  `secondaryText`, `hoverHighlight`, `separator`, `badgeProject`,
  `badgeText`, `brandAccent`, `brandSecondary`, `brandGradientStart`,
  `brandGradientEnd`, `colorForProject(_:)`) so the 14 views that reference
  DS3Colors continue to compile unchanged.

**`DS3Drive/Views/Common/DesignSystem/DS3Typography.swift`:**

- New Figtree-based scale: `h1` / `h2` / `h3` (SemiBold 40/32/24),
  `bodyLarge` / `body` / `bodyMedium` (16/14/14), `caption` / `captionBold`
  (12), `button` (SemiBold 14).
- Legacy aliases (`title`, `title2`, `headline`, `body`, `caption`,
  `footnote`, `heading`) kept and re-pointed at Figtree so all existing
  `.font(DS3Typography.title)` / `.font(DS3Typography.caption)` call sites
  in MFAView, LoginView, TreeNavigationView, DriveConfirmView,
  TrayDriveRowView, ConnectionInfoPanel, RecentFilesPanel, SpeedSummaryView,
  TrayMenuFooterView, UpdateSection, ConnectionTab, DS3DriveApp, and
  ButtonStyles continue to render.
- `Font.custom(_, size:)` falls back to the system font automatically at
  runtime if Figtree isn't loaded, so the app can't crash even if the
  bundle is stripped or the font fails to register.

**`DS3Drive/Views/Common/DesignSystem/DS3Gradients.swift`:**

- New `brandVerticalBackground` (subtle `#0E0E15 → #080810` top→bottom
  gradient for full-window hero surfaces).
- New `brandCardGlow` — `RadialGradient` anchored to `.bottomTrailing` with
  `brandPrimary @ 10% → clear`, sized at 220pt radius, intended to be
  blurred (~40pt) and layered over a card's `brandSurface` fill.
- `brandHero` / `brandHeroSubtle` aliased to `brandVerticalBackground` so
  the diagonal login-hero gradient from 05-11 no longer fights with the
  canary look but existing call sites keep compiling.
- `brandRadialGlow` retained (now driven by `brandPrimary`, not the old
  `brandGradientStart`).

**`DS3Lib/Sources/DS3Lib/DesignSystem/{DS3Colors,DS3Typography,DS3Gradients}.swift`:**

- Same rewrites mirrored into the cross-platform DS3Lib module so the iOS
  companion app (DS3DriveApp) and the Share Extension pick up the canary
  palette and Figtree typography. `#if os(macOS)` / `#if os(iOS)` guards
  around `NSColor`/`UIColor` dynamic providers; iOS fallback uses the dark
  value directly since brand is dark.

**`.planning/phases/05-ux-polish/05-11-BRAND-TOKENS.md`:**

- Front-matter: `status: superseded`, `superseded_by: 05-17`.
- Big SUPERSEDED banner at the top linking to Gap 31 and the corrected
  section.
- Original Plan 05-11 mapping kept in place (as history) under a
  "(SUPERSEDED)" heading.
- New "Corrected tokens (Composer canary, Plan 05-17)" section appended
  with the full CSS dump, a token → Swift mapping table for DS3Colors, and
  a Typography mapping table showing which Figtree size/weight maps to
  each Composer CSS variable.

### Task 3 — Shared brand helpers

- `DS3Drive/Views/Common/DesignSystem/DS3CardStyle.swift` — new file. Defines
  `BrandCardStyle: ViewModifier` (padding + ZStack surface fill +
  `brandCardGlow` blurred overlay + 1pt `brandBorderSubtle` strokeBorder)
  and a `View.brandCard(cornerRadius:padding:)` modifier.
- `DS3Drive/Views/Common/Buttons/BrandPrimaryButtonStyle.swift` — new file.
  Defines `BrandPrimaryButtonStyle: ButtonStyle` (`brandPrimary` fill →
  `brandPrimaryDark` when pressed, white label, 8pt radius, `button`
  Figtree font, 44pt min height, optional `fillWidth` flag, disabled alpha
  dimming).
- Both helpers added to the DS3Drive target via `project.pbxproj` (new
  `Buttons` group with `BrandPrimaryButtonStyle.swift`; `DS3CardStyle.swift`
  added to the existing DesignSystem group).
- These are NOT wired into any existing view yet — sweep plans 05-18 /
  05-19 consume them.

## Verification

- `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **`
- Build log shows all four Figtree TTFs copied into
  `Cubbit DS3 Drive.app/Contents/Resources/`.
- grep confirms: `#0E0E15` present in DS3Colors.swift (3 hits), `#005CE8`
  present (2 hits), `Figtree-Regular` present in DS3Typography.swift
  (4 hits), `SUPERSEDED` marker present in 05-11-BRAND-TOKENS.md (2 hits).
- PostScript name sanity: inspected the bundled TTFs' `name` tables —
  `Figtree-Regular`/`Medium`/`SemiBold`/`Bold` all match the
  `Font.custom(_, size:)` identifiers.

## Deviations from Plan

None. Plan executed exactly as written:

- Font download succeeded via `fonts.gstatic.com` (the plan allowed
  falling back to placeholders if network download failed; that fallback
  was not needed).
- Composer canary CSS extraction was not re-verified live during execution
  because the dashboard requires auth — the plan explicitly allowed
  using the Gap 31 values as authoritative in that case, and no live
  delta is claimed (see "Delta vs Gap 31 spec" in the updated
  `05-11-BRAND-TOKENS.md`).

## Known Stubs / Deferred Items

None. Tokens, typography, gradients, and shared helpers are fully wired;
the only remaining work is visual adoption, which is intentionally scoped
to sweep plans 05-18 and 05-19.

## Checkpoint: Human Visual Verification

**Status:** Pending user review.

This plan closes at a `checkpoint:human-verify` gate. The user needs to:

1. Run the app from Xcode (Cmd+R).
2. Confirm any pre-existing view (login / MFA / tray) renders with:
   - Figtree font (softer, more geometric than SF Pro — noticeable on
     letters `a` / `g`).
   - Near-black backdrop `#0E0E15`, not warm grey.
3. Open `https://composer-canary.cubbit.eu/en/dashboard` side-by-side and
   confirm the darkness and blue saturation match.
4. Respond with "approved" or list specific mismatches before Plan 05-18
   starts consuming the new helpers.

If the font falls back to system, the likely fix is one of:
- Target membership missing — verify in Xcode File Inspector.
- `ATSApplicationFontsPath` value needs to be `Fonts` instead of `.`.
- Font files didn't copy to `Contents/Resources/` (build log should confirm
  they did; if not, clean build + delete DerivedData).

## Commits

- `eb5e19e` — feat(05-17): bundle Figtree font in all targets
- `12539e3` — feat(05-17): rewrite brand tokens from Composer canary
- `d31786d` — feat(05-17): add BrandCardStyle and BrandPrimaryButtonStyle helpers

## Self-Check: PASSED

- FOUND: DS3Drive/Assets/Fonts/Figtree-Regular.ttf
- FOUND: DS3Drive/Assets/Fonts/Figtree-Medium.ttf
- FOUND: DS3Drive/Assets/Fonts/Figtree-SemiBold.ttf
- FOUND: DS3Drive/Assets/Fonts/Figtree-Bold.ttf
- FOUND: DS3Drive/Views/Common/DesignSystem/DS3CardStyle.swift
- FOUND: DS3Drive/Views/Common/Buttons/BrandPrimaryButtonStyle.swift
- FOUND (modified): DS3Drive/Views/Common/DesignSystem/DS3Colors.swift (brandBg900 #0E0E15 present)
- FOUND (modified): DS3Drive/Views/Common/DesignSystem/DS3Typography.swift (Figtree-Regular present)
- FOUND (modified): DS3Drive/Views/Common/DesignSystem/DS3Gradients.swift (brandCardGlow present)
- FOUND (modified): DS3Lib/Sources/DS3Lib/DesignSystem/DS3Colors.swift
- FOUND (modified): DS3Lib/Sources/DS3Lib/DesignSystem/DS3Typography.swift
- FOUND (modified): DS3Lib/Sources/DS3Lib/DesignSystem/DS3Gradients.swift
- FOUND (modified): DS3Drive/Info.plist (ATSApplicationFontsPath + Figtree UIAppFonts)
- FOUND (modified): DS3DriveApp/Info.plist (UIAppFonts Figtree)
- FOUND (modified): DS3DriveShareExtension/Info.plist (UIAppFonts Figtree)
- FOUND (modified): .planning/phases/05-ux-polish/05-11-BRAND-TOKENS.md (SUPERSEDED marker)
- FOUND commit: eb5e19e
- FOUND commit: 12539e3
- FOUND commit: d31786d
- Build: `** BUILD SUCCEEDED **`
