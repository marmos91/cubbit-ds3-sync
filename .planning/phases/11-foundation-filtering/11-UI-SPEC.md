---
phase: 11
slug: foundation-filtering
status: draft
shadcn_initialized: false
preset: not applicable
created: 2026-04-11
---

# Phase 11 — UI Design Contract

> Visual and interaction contract for the thumbnail prefix collision warning screen in the drive-setup wizard. This is the sole user-visible UI surface in Phase 11.

---

## Design System

| Property | Value |
|----------|-------|
| Tool | Native SwiftUI (no web tooling) |
| Preset | Not applicable |
| Component library | Apple system controls + existing DS3 design tokens |
| Icon library | SF Symbols (system) |
| Font | Figtree (bundled TTF, falls back to system font) |
| Platform targets | macOS 14+ (SetupSyncView), iOS 17+ (IOSSetupWizardView) |

---

## Spacing Scale

Existing `DS3Spacing` tokens from `DS3Lib/Sources/DS3Lib/DesignSystem/DS3Spacing.swift`:

| Token | Value | Usage in this phase |
|-------|-------|---------------------|
| `DS3Spacing.xs` | 4pt | Not used |
| `DS3Spacing.sm` | 8pt | Icon-to-text gap in warning banner |
| `DS3Spacing.md` | 12pt | Internal padding within banner body |
| `DS3Spacing.lg` | 16pt | Vertical spacing between warning elements |
| `DS3Spacing.xl` | 24pt | Section spacing (icon area to copy, copy to CTAs) |
| `DS3Spacing.xxl` | 32pt | Horizontal page margin (macOS), top padding from icon |
| `DS3Spacing.xxxl` | 48pt | Not used |

Exceptions: iOS uses `20pt` horizontal padding per existing `DriveConfirmView` convention (not a DS3Spacing token, but established iOS wizard pattern).

---

## Typography

Existing `DS3Typography` tokens used in this phase:

| Role | Token | Size | Weight | Font | Usage |
|------|-------|------|--------|------|-------|
| Warning title | `DS3Typography.h3` (macOS) / `Figtree-SemiBold 26pt` (iOS) | 24pt / 26pt | SemiBold (600) | Figtree-SemiBold | Warning screen heading |
| Warning body | `DS3Typography.bodyLarge` (macOS) / `Figtree-Regular 16pt` (iOS) | 16pt | Regular (400) | Figtree-Regular | Warning explanation paragraph |
| Primary CTA label | `DS3Typography.button` (macOS) / `Figtree-SemiBold 17pt` (iOS) | 14pt / 17pt | SemiBold (600) | Figtree-SemiBold | "Choose a different prefix" button |
| Secondary CTA label | `DS3Typography.caption` (macOS) / `Figtree-Regular 14pt` (iOS) | 12pt / 14pt | Regular (400) | Figtree-Regular | "Use anyway" text button |

Line height: SwiftUI default (approximately 1.2 for headings, 1.4 for body). Consistent with all existing wizard views.

**Platform split rationale:** iOS `DriveConfirmView` uses direct `Font.custom("Figtree-*", size:)` calls at iOS-specific sizes (17pt body, 26pt title). macOS uses `DS3Typography` tokens. This phase follows the same per-platform convention.

---

## Color

This phase uses the existing Cubbit brand color system. No new colors introduced.

| Role | Token | Value | Usage in this phase |
|------|-------|-------|---------------------|
| Warning icon + tint | `DS3Colors.statusWarning` / `IOSColors.statusWarning` | `#FFB74D` (amber) | Warning triangle icon, banner background tint at 10% opacity, banner border at 30% opacity |
| Warning text | `DS3Colors.brandTextPrimary` / `IOSColors.brandTextPrimary` | Adaptive (white dark / near-black light) | Title and body copy |
| Primary CTA background | `DS3Colors.brandPrimary` / `IOSColors.brandPrimary` | `#005CE8` | "Choose a different prefix" button fill |
| Primary CTA text | `.white` | `#FFFFFF` | Button label |
| Secondary CTA text | `DS3Colors.brandTextSecondary` / `IOSColors.brandTextSecondary` | Adaptive white@60% / black@60% | "Use anyway" text button |
| Page background | `DS3Colors.brandBackground` / `IOSGradients.brandVerticalBackground` | Adaptive `#0E0E15` dark / white light (macOS); gradient (iOS) | Full-screen background behind warning |
| Banner background | `statusWarning.opacity(0.1)` | Amber at 10% | Warning banner card fill |
| Banner border | `statusWarning.opacity(0.3)` | Amber at 30% | Warning banner card stroke (1pt) |

**Pattern source:** Existing `duplicateWarning` in `DS3DriveApp/Views/Setup/DriveConfirmView.swift:279-300` uses this exact amber banner pattern. The collision warning reuses it.

---

## Component Specification: `ThumbnailConflictWarningView`

A shared SwiftUI view in `DS3Lib` (or at minimum, identical implementations in both platform wizard targets) that renders the blocking warning when `inspectThumbnailPrefix` returns `.conflicting`.

### Layout (macOS — within `SetupSyncView` 800x480 window)

```
+--------------------------------------------------------------+
|                                                              |
|                    [Warning Icon - 48pt]                     |
|                  exclamationmark.triangle.fill                |
|                   statusWarning color                         |
|                                                              |
|              Thumbnail prefix conflict detected               |
|                    (h3 / SemiBold 24pt)                      |
|                                                              |
|  +----------------------------------------------------------+|
|  | [!] This bucket already contains a ".thumbnails/" folder  ||
|  |     with content that wasn't created by DS3 Drive.        ||
|  |     Thumbnails may not work correctly for this drive.     ||
|  +----------------------------------------------------------+|
|                                                              |
|           [ Choose a different prefix ]  (primary)           |
|                                                              |
|                  Use anyway  (text button)                    |
|                                                              |
+--------------------------------------------------------------+
```

### Layout (iOS — full-screen within NavigationStack)

```
+-------------------------------+
|  < Back              [X]      |
|-------------------------------|
|                               |
|     [Warning Icon - 64pt]     |
|   exclamationmark.triangle    |
|     .fill, statusWarning      |
|                               |
|  Thumbnail prefix conflict    |
|       detected                |
|   (SemiBold 26pt, centered)   |
|                               |
| +---------------------------+ |
| | [!] This bucket already   | |
| | contains a ".thumbnails/" | |
| | folder with content that  | |
| | wasn't created by DS3     | |
| | Drive. Thumbnails may not | |
| | work correctly for this   | |
| | drive.                    | |
| +---------------------------+ |
|                               |
|                               |
|-------------------------------|
| [  Choose a different prefix ]|  <- pinned bottom CTA
|        Use anyway             |  <- text button below CTA
+-------------------------------+
```

### Visual Specifications

**Warning icon (both platforms):**
- SF Symbol: `exclamationmark.triangle.fill`
- Rendering mode: `.hierarchical`
- Color: `statusWarning` (`#FFB74D`)
- macOS size: 48pt (`.font(.system(size: 48))`)
- iOS size: 64pt (`.font(.system(size: 64))`) within a `Circle().fill(statusWarning.opacity(0.12)).frame(width: 112, height: 112)` — mirrors the iOS `DriveConfirmView` hero pattern

**Warning banner (both platforms):**
- Corner radius: 12pt (`.continuous`)
- Fill: `statusWarning.opacity(0.1)`
- Stroke: `statusWarning.opacity(0.3)`, 1pt line width
- Internal padding: `DS3Spacing.md` (12pt)
- Icon: `exclamationmark.triangle.fill` at 14pt, `statusWarning` color
- Text: warning body copy at `Figtree-Regular 13pt` (iOS) / `DS3Typography.caption` 12pt (macOS), `statusWarning` color
- Matches existing `duplicateWarning` component in `DriveConfirmView.swift:279-300`

**Primary CTA ("Choose a different prefix"):**
- macOS: `DS3Typography.button` (14pt SemiBold), white text, `brandPrimary` background, rounded rectangle 8pt corner radius, 36pt height, max width 280pt
- iOS: `Figtree-SemiBold 17pt`, white text, `brandPrimary` background, rounded rectangle 14pt corner radius, 54pt height (pinned to bottom safe area), full width with 20pt horizontal margins — matches existing `pinnedCTA` pattern

**Secondary CTA ("Use anyway"):**
- macOS: `DS3Typography.caption` (12pt Regular), `brandTextSecondary` color, plain text button (no background), underlined on hover
- iOS: `Figtree-Regular 14pt`, `brandTextSecondary` color, plain text button centered below the primary CTA, 8pt top spacing

### Interaction Contract

| Trigger | Action |
|---------|--------|
| User taps "Create Drive" on confirm step | `inspectThumbnailPrefix(bucket:prefix:)` is called. If `.conflicting`, navigate to warning screen instead of creating drive. |
| Loading state during inspection | Show `ProgressView` on the "Create Drive" button (same pattern as existing `isCreating` state) |
| Inspection fails (network error) | Proceed silently — do NOT block drive creation on a failed check. Log the error. |
| User taps "Choose a different prefix" | Pop back to prefix selection step (macOS: `syncSetupViewModel.goBack()` to `.treeNavigation`; iOS: `navigationPath.removeLast(n)` to prefix list) |
| User taps "Use anyway" | Create the drive normally — call the same `DS3DriveManager.add(drive:)` path as the happy case |
| VoiceOver on warning icon | accessibilityLabel: "Warning" |
| VoiceOver on primary CTA | accessibilityLabel: "Choose a different prefix" + accessibilityHint: "Returns to prefix selection" |
| VoiceOver on secondary CTA | accessibilityLabel: "Use anyway" + accessibilityHint: "Creates the drive despite the conflict" |

### Accessibility

- Warning icon: decorative when banner text is present (`.accessibilityHidden(true)` on icon, label on banner `HStack`)
- Banner HStack: `accessibilityElement(children: .combine)` so VoiceOver reads icon + text as one unit
- Primary CTA: `.accessibilityAddTraits(.isButton)`
- Secondary CTA: `.accessibilityAddTraits(.isButton)`
- Dynamic Type: all text uses Figtree font which scales with SwiftUI's dynamic type system. Banner text uses `.fixedSize(horizontal: false, vertical: true)` to prevent truncation.
- Minimum touch target: iOS CTAs meet 44pt minimum via 54pt button height. macOS CTA at 36pt is acceptable for pointer-based interaction.

---

## Copywriting Contract

### Localization Keys (Localizable.xcstrings)

4 keys, EN + IT translations:

| Key | EN | IT |
|-----|----|----|
| `thumbnail_conflict_title` | Thumbnail prefix conflict detected | Rilevato conflitto nel prefisso thumbnails |
| `thumbnail_conflict_body` | This bucket already contains a ".thumbnails/" folder with content that was not created by DS3 Drive. Thumbnails may not work correctly for this drive. | Questo bucket contiene gia una cartella ".thumbnails/" con contenuti non creati da DS3 Drive. Le anteprime potrebbero non funzionare correttamente per questa unita. |
| `thumbnail_conflict_change_prefix` | Choose a different prefix | Scegli un prefisso diverso |
| `thumbnail_conflict_use_anyway` | Use anyway | Usa comunque |

**Copy rationale:**
- Title uses "conflict detected" — factual, not alarming. Avoids "error" or "danger" language because the user can proceed safely.
- Body explains WHAT is wrong ("contains content not created by DS3 Drive") and WHAT the consequence is ("thumbnails may not work correctly"). Does not prescribe the fix in the body — the CTAs do that.
- Primary CTA is an action verb ("Choose") + object ("a different prefix") — tells the user exactly what will happen.
- Secondary CTA is minimal ("Use anyway") — power-user escape, deliberately understated.
- IT translations use formal register consistent with existing Italian localizations in the app.

### Empty State

Not applicable — this phase has no data-driven views. The warning screen is shown only on `.conflicting` state.

### Error State

| Scenario | Behavior |
|----------|----------|
| `inspectThumbnailPrefix` throws (network error, timeout) | Proceed silently. Log error at `.error` level. Do NOT show the warning screen. User sees normal drive creation flow. |
| `inspectThumbnailPrefix` returns `.empty` or `.matchesOurs` | Proceed silently. No UI shown. |

### Destructive Actions

None in this phase. "Use anyway" is a permissive action, not destructive — the drive is created normally and can be removed/re-added later.

---

## Registry Safety

Not applicable. This is a native SwiftUI app with no package registry (no shadcn, no npm, no third-party UI component registries).

---

## Platform Parity Matrix

| Aspect | macOS | iOS |
|--------|-------|-----|
| Warning screen container | Replaces `DriveConfirmView` content in 800x480 window | Full-screen view pushed onto NavigationStack |
| Icon size | 48pt | 64pt in 112pt circle (hero pattern) |
| Title size | 24pt (DS3Typography.h3) | 26pt (iOS convention) |
| Primary CTA | Centered button, 280pt max width, 36pt height | Pinned bottom CTA, full width, 54pt height |
| Secondary CTA | Text button below primary, centered | Text button below pinned CTA |
| Back navigation | "Choose a different prefix" returns to `.treeNavigation` step | "Choose a different prefix" pops NavigationPath back to prefix list |
| Background | `DS3Colors.brandBackground` (adaptive) | `IOSGradients.brandVerticalBackground` |
| Warning banner pattern | Same as macOS `nameError` inline pattern (adapted to amber) | Matches existing `duplicateWarning` in iOS `DriveConfirmView` |

---

## Checker Sign-Off

- [ ] Dimension 1 Copywriting: PASS
- [ ] Dimension 2 Visuals: PASS
- [ ] Dimension 3 Color: PASS
- [ ] Dimension 4 Typography: PASS
- [ ] Dimension 5 Spacing: PASS
- [ ] Dimension 6 Registry Safety: PASS (not applicable — native app)

**Approval:** pending
