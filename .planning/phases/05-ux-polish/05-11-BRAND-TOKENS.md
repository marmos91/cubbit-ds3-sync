---
phase: 05-ux-polish
plan: 11
captured: 2026-04-07
status: superseded
superseded_by: 05-17
source: cubbit.io shipped CSS (Webflow design tokens) — Figma MCP fallback
figma_file: https://www.figma.com/design/esjch8fneVvEwGd4dCLafW/Cubbit-%7C-Design-File
figma_file_key: esjch8fneVvEwGd4dCLafW
figma_node_id: "0:1"
---

> **STATUS: SUPERSEDED by Plan 05-17 (2026-04-07).**
>
> The values in this document were extracted from the **cubbit.io marketing
> CSS**. A follow-up audit (Gap 31 in `05-08-GAPS.md`) confirmed they do not
> match the actual **product** palette shipped on
> `https://composer-canary.cubbit.eu/en/dashboard`. The product uses a much
> darker backdrop (`#0E0E15`, not `#252B30`), a deeper primary blue
> (`#005CE8`, not `#3384FF`), white-alpha borders (not solid greys), and the
> **Figtree** font (not the system font).
>
> The Plan 05-17 corrected tokens are authoritative and live in
> `DS3Drive/Views/Common/DesignSystem/DS3Colors.swift`,
> `DS3Typography.swift`, and `DS3Gradients.swift` (with the same mirrors in
> `DS3Lib/Sources/DS3Lib/DesignSystem/`). See the **"Corrected tokens
> (Composer canary, Plan 05-17)"** section at the bottom of this file.
>
> Do NOT use the values in the sections below for new work — they are kept
> only so the Plan 05-11 execution history remains readable.

# Cubbit Brand Tokens — Figma -> Swift Mapping Reference (SUPERSEDED)

This document captures the Cubbit brand palette extracted for plan 05-11 and
how each value maps onto the Swift design tokens in
`DS3Drive/Views/Common/DesignSystem/DS3Colors.swift` and `DS3Gradients.swift`.

## Source

The canonical source of truth is the Cubbit Figma brand file:

- **URL:** https://www.figma.com/design/esjch8fneVvEwGd4dCLafW/Cubbit-%7C-Design-File?node-id=0-1
- **File key:** `esjch8fneVvEwGd4dCLafW`
- **Node id:** `0:1`

### Extraction method

The Figma MCP server (`mcp__plugin_figma_figma__get_variable_defs`) was the
intended extraction path. At execution time the Figma MCP tools were not
exposed in the agent's tool list, so the **fallback path** was used: the
shipping Cubbit website (`https://www.cubbit.io`) loads its tokens from
`cdn.prod.website-files.com/.../css/cubbit-new.shared.bf45a9d72.min.css` as
CSS custom properties under `:root`. These properties carry the same names
as the Figma color variables (`--color--blue--blue-400`, etc.) because the
Webflow design system was generated from the same brand source. The hex
values below were copied verbatim from that CSS.

> **Action item for the design team:** when the Figma MCP becomes available,
> re-run `get_variable_defs` against the file/node above and reconcile any
> drift. Tokens marked **inferred** below should be the first to verify.

## Palette

### Blues (primary brand spectrum)

| Figma Variable | Hex | Swift Token | Usage |
|---|---|---|---|
| `color/blue/blue-50`  | `#e6f0ff` | `DS3Colors.brandBlue50`  | Subtle hover/selected background tints |
| `color/blue/blue-100` | `#b0cfff` | `DS3Colors.brandBlue100` | Light tints |
| `color/blue/blue-200` | `#8ab8ff` | `DS3Colors.brandBlue200` | — |
| `color/blue/blue-300` | `#5498ff` | `DS3Colors.brandBlue300` | Hover-state of primary in dark mode |
| `color/blue/blue-400` | `#3384ff` | `DS3Colors.brandPrimary` (also `brandBlue400`) | Primary brand color (links, primary buttons, focus rings) |
| `color/blue/blue-500` | `#0065ff` | `DS3Colors.brandBlue500` | Pressed/active state of brand primary |
| `color/blue/blue-600` | `#005ce8` | `DS3Colors.brandBlue600` | Gradient mid-stop |
| `color/blue/blue-700` | `#0048b5` | `DS3Colors.brandBlue700` | Deep gradient stop |
| `color/blue/blue-800` | `#00388c` | `DS3Colors.brandBlue800` | Hero gradient deep stop |
| `color/blue/blue-900` | `#002a6b` | `DS3Colors.brandGradientEnd` (also `brandBlue900`) | Gradient end (deepest brand blue) |

### Violets (secondary brand spectrum)

| Figma Variable | Hex | Swift Token | Usage |
|---|---|---|---|
| `color/violet/violet-300` | `#af7acb` | `DS3Colors.brandViolet300` | — |
| `color/violet/violet-500` | `#8739b1` | `DS3Colors.brandSecondary` (also `brandViolet500`) | Secondary brand accent (badges, decorative) |
| `color/violet/violet-700` | `#60287e` | `DS3Colors.brandViolet700` | Deep secondary |

### Accent (yellow)

| Figma Variable | Hex | Swift Token | Usage |
|---|---|---|---|
| `color/yellow/yellow-500` | `#f3b356` | `DS3Colors.brandAccent` | Highlights, warnings, decorative accents |

### Greens (status — synced/healthy)

| Figma Variable | Hex | Swift Token | Usage |
|---|---|---|---|
| `color/green/green-500` | `#27b681` | `DS3Colors.brandGreen500` | — |
| `color/green/green-600` | `#23a675` | `DS3Colors.brandGreen600` | Reuses for `statusSynced` brand variant |

### Greys (surface + text)

| Figma Variable | Hex | Swift Token | Usage |
|---|---|---|---|
| `color/grey/grey-50`   | `#dee4ea` | `DS3Colors.brandBackgroundLight` | Light-mode window background |
| `color/grey/grey-100`  | `#ccd0d4` | `DS3Colors.brandSurfaceLight` | Light-mode card surface |
| `color/grey/grey-200`  | `#b3b9bf` | `DS3Colors.brandBorderLight` | Light-mode borders |
| `color/grey/grey-500`  | `#596773` | `DS3Colors.brandTextSecondaryLight` | Light-mode secondary text |
| `color/grey/grey-700`  | `#3f4952` | `DS3Colors.brandSurfaceDark` | Dark-mode card surface (inferred — Figma uses grey-700/grey-800 for surfaces in the dark theme) |
| `color/grey/grey-800`  | `#31393f` | `DS3Colors.brandTextPrimaryLight` (text on light) / dark-mode `brandSurfaceElevatedDark` | Primary text on light surfaces; elevated surface in dark mode |
| `color/grey/grey-900`  | `#252b30` | `DS3Colors.brandBackgroundDark` | Dark-mode window background |
| `color/grey/grey-1000` | `#1c1c1c` | `DS3Colors.brandBackgroundDarkDeep` | Dark-mode deepest surface |
| `color/bg/dark`        | `#040404` | `DS3Colors.brandBlack` | Pure brand black |

### Adaptive (light/dark) tokens

These tokens compose the values above into NSColor dynamic providers so
SwiftUI views automatically pick the right value per system appearance.

| Swift Token | Light value | Dark value | Usage |
|---|---|---|---|
| `DS3Colors.brandBackground` | `#dee4ea` (grey-50) | `#252b30` (grey-900) | Window background for login/wizard/preferences/tutorial |
| `DS3Colors.brandSurface`    | `#ffffff` | `#31393f` (grey-800) | Card / panel surfaces |
| `DS3Colors.brandTextPrimary`   | `#31393f` (grey-800) | `#dee4ea` (grey-50) | Primary text |
| `DS3Colors.brandTextSecondary` | `#596773` (grey-500) | `#9099a1` (grey-300) | Secondary / caption text |
| `DS3Colors.brandBorder`     | `#b3b9bf` (grey-200) | `#3f4952` (grey-700) | Borders & dividers |

### Gradient

| Swift Token | Stops | Direction | Usage |
|---|---|---|---|
| `DS3Colors.brandGradientStart` | `#3384ff` (blue-400) | — | Gradient start |
| `DS3Colors.brandGradientEnd`   | `#002a6b` (blue-900) | — | Gradient end |
| `DS3Gradients.brandHero`       | start -> end | top-leading -> bottom-trailing | Hero areas (login background, wizard splash) |
| `DS3Gradients.brandHeroSubtle` | start@30% -> end@70% | top-leading -> bottom-trailing | Subtle background overlay |
| `DS3Gradients.brandRadialGlow` | start@40% -> clear | radial center | Logo glow on login |

## Inferred / verify-against-Figma

The following values are **inferred** from Webflow CSS rather than directly
read from Figma variables and should be reconciled when the Figma MCP comes
back online:

- Adaptive dark-mode surface mapping (`grey-700` vs `grey-800`) — Webflow
  uses both for elevated surfaces depending on context; the mapping above
  picks `grey-800` for default surface and `grey-700` for elevated.
- Whether `#ffffff` is the canonical light-mode surface or whether Figma
  ships a slightly off-white variant.
- Gradient direction & stops — `brandHero` uses an opinionated diagonal
  gradient using blue-400 -> blue-900. Figma may specify exact angle/stops.

## Swift token quick reference

Required by plan 05-11 acceptance criteria:

```swift
DS3Colors.brandPrimary        // #3384ff
DS3Colors.brandSecondary      // #8739b1
DS3Colors.brandAccent         // #f3b356
DS3Colors.brandBackground     // adaptive grey-50/grey-900
DS3Colors.brandSurface        // adaptive white/grey-800
DS3Colors.brandTextPrimary    // adaptive grey-800/grey-50
DS3Colors.brandTextSecondary  // adaptive grey-500/grey-300
DS3Colors.brandGradientStart  // #3384ff
DS3Colors.brandGradientEnd    // #002a6b

DS3Gradients.brandHero        // start -> end (diagonal)
```

## Migration plan

- **Plan 05-11 (this plan)** introduces the brand tokens *additively*.
  Existing `DS3Colors.background`, `DS3Colors.secondaryBackground`, etc. are
  kept so unrelated views keep compiling.
- **Plan 05-12** (tray redesign) replaces tray surface tokens with `brand*`.
- **Plan 05-13** (iOS parity) ports the same tokens into the iOS target.
- **Plan 05-14** (tutorial refresh) reshoots screenshots with brand chrome.
- A future cleanup plan will delete the legacy tokens once all call sites
  have been migrated.

---

## Corrected tokens (Composer canary, Plan 05-17)

**Source:** https://composer-canary.cubbit.eu/en/dashboard (extracted via
WebFetch of the live Material-UI CSS custom properties on 2026-04-07 during
execution of Plan 05-17 / closure of Gap 31).

**Extraction method:** The CSS custom properties below were captured from the
`style` attribute on `<body>` and the Emotion-generated style blocks in
`<head>` on the live Composer canary dashboard. Values that could not be
captured from a public endpoint (because the dashboard requires
authentication) were cross-checked against the documented Material-UI theme
shipped by the Composer product (see Gap 31 in `05-08-GAPS.md` for the
full CSS dump).

### Color palette

```
--primary-main:       #005CE8   rgb(  0,  92, 232)
--primary-dark:       #0048B5   rgb(  0,  72, 181)
--primary-light:      #337CEC   rgb( 51, 124, 236)
--primary-contrast:   #FFFFFF

--info-main:          #5498FF
--success-main:       #26AB75
--warning-main:       #FFB74D
--error-main:         #E56363
--error-dark:         #DC2D20

--bg-default:         #0E0E15   rgb( 14,  14,  21)   ← window background
--bg-paper:           #121212   (dark mode)
--bg-paper-light:     #FFFFFF   (light mode)

--text-primary:       #FFFFFF
--text-secondary:     #FFFFFF99  (60% alpha white)
--text-tertiary:      #FFFFFF73  (45% alpha white)
--text-disabled:      #FFFFFF4D  (30% alpha white)

--border-primary:     #FFFFFF4D  (30% alpha white — prominent)
--border-secondary:   #FFFFFF1A  (10% alpha white — subtle)
--border-tertiary:    #FFFFFF0A  (4%  alpha white — ultra-subtle card edges)
--divider:            rgba(255, 255, 255, 0.12)

--radius-base:        4px
--radius-component:   8px  (0.5rem — cards, buttons)
```

### Typography

```
--font-family:        Figtree, 'Figtree Fallback'
--heading-h1:         600 2.5rem/2.75rem    (40px SemiBold, 44px leading)
--heading-h3:         600 1.5rem/1.8rem     (24px SemiBold, 28.8px leading)
--body-md:            400 1rem/1.3rem       (16px Regular,  20.8px leading)
--body-sm:            400 0.875rem/1.1375rem (14px Regular, 18.2px leading)
```

Figtree is served from Google Fonts (Apache 2.0 license):
https://fonts.google.com/specimen/Figtree

### Swift mapping (DS3Colors.swift after Plan 05-17)

| Token (CSS)          | Hex         | Swift (DS3Colors)                    |
| -------------------- | ----------- | ------------------------------------ |
| `--primary-main`     | `#005CE8`   | `brandPrimary`                       |
| `--primary-dark`     | `#0048B5`   | `brandPrimaryDark`                   |
| `--primary-light`    | `#337CEC`   | `brandPrimaryLight`                  |
| `--bg-default`       | `#0E0E15`   | `brandBg900` / `brandBackground` dark |
| `--bg-paper`         | `#121212`   | `brandBg800` / `brandSurface` dark   |
| `--success-main`     | `#26AB75`   | `statusSuccess` / `statusSynced`     |
| `--error-main`       | `#E56363`   | `statusErrorMain` / `statusError`    |
| `--error-dark`       | `#DC2D20`   | `statusErrorDark`                    |
| `--warning-main`     | `#FFB74D`   | `statusWarning` / `brandAccent`      |
| `--info-main`        | `#5498FF`   | `statusInfo`                         |
| `--text-primary`     | `#FFFFFF`   | `textPrimary`                        |
| `--text-secondary`   | `#FFFFFF99` | `textSecondary` (white @ 60%)        |
| `--text-tertiary`    | `#FFFFFF73` | `textTertiary` (white @ 45%)         |
| `--text-disabled`    | `#FFFFFF4D` | `textDisabled` (white @ 30%)         |
| `--border-primary`   | `#FFFFFF4D` | `brandBorderStrong`                  |
| `--border-secondary` | `#FFFFFF1A` | `brandBorderSubtle`                  |
| `--border-tertiary`  | `#FFFFFF0A` | `brandBorderUltraSubtle`             |
| `--divider`          | `#FFFFFF1F` | `brandDivider`                       |

### Swift mapping (DS3Typography.swift after Plan 05-17)

| Token (CSS)    | Swift                                    |
| -------------- | ---------------------------------------- |
| `--heading-h1` | `h1` — `Font.custom("Figtree-SemiBold", size: 40)` |
| (h2, derived)  | `h2` — 32pt SemiBold                     |
| `--heading-h3` | `h3` — `Font.custom("Figtree-SemiBold", size: 24)` |
| `--body-md`    | `bodyLarge` — 16pt Regular               |
| `--body-sm`    | `body` — 14pt Regular                    |
| `--body-sm 500`| `bodyMedium` — 14pt Medium               |
| (button CTA)   | `button` — 14pt SemiBold                 |
| legacy alias   | `title` → 18pt SemiBold                  |
| legacy alias   | `title2` → 22pt SemiBold                 |
| legacy alias   | `headline` → 16pt SemiBold               |
| legacy alias   | `caption` → 12pt Regular                 |
| legacy alias   | `footnote` → 11pt Regular                |

All Figtree sizes fall back to the system font automatically via
`Font.custom(_, size:)`.

### Delta vs Gap 31 spec

None — the hex values above match Gap 31 exactly. No delta observed during
Plan 05-17 execution.

