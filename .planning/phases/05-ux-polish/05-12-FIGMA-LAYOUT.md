---
phase: 05-ux-polish
plan: 12
captured: 2026-04-07
status: reference
source: Sync Share 2.0 Figma — fallback design (Figma MCP tools not exposed at runtime)
figma_file: https://www.figma.com/design/E0QXd1ecdYVm9mDKjOntIK/Sync-Share-2.0
figma_file_key: E0QXd1ecdYVm9mDKjOntIK
figma_node_id: "106:1013"
---

# Sync Share 2.0 — Tray Layout Reference

This document captures the layout decisions for the Cubbit DS3 Drive tray
redesign (plan 05-12), based on the Sync Share 2.0 Figma node referenced
above and re-mapped onto the Cubbit brand tokens introduced in plan 05-11.

## Source

- **URL:** https://www.figma.com/design/E0QXd1ecdYVm9mDKjOntIK/Sync-Share-2.0?node-id=106-1013
- **File key:** `E0QXd1ecdYVm9mDKjOntIK`
- **Node id:** `106:1013` (URL-form: `106-1013`)

### Extraction method

Plan 05-12 instructed using `mcp__plugin_figma_figma__get_design_context`
and `mcp__plugin_figma_figma__get_screenshot`. The Figma MCP server is
declared in the project's MCP instructions but the tools were **not exposed
in the agent's runtime tool list** at execution time (same situation as
plan 05-11). The plan's `<figma_mcp_guidance>` block explicitly authorized
a fallback path: "design a card-style tray layout following the spirit of
the plan ... using `DS3Colors.brand*` tokens" and document the fallback in
the SUMMARY.

> **Action item:** when the Figma MCP tools become available, re-run
> `get_design_context` against this node and reconcile any drift in
> spacing, corner radii, or stripe treatments documented below.

## Layout Decisions

### Drive Row (TrayDriveRowView) — the headline change

Each drive row becomes a **card** instead of a flat list item:

| Property | Value | Token |
|---|---|---|
| Container shape | `RoundedRectangle(cornerRadius: 10)` | — |
| Background fill | adaptive surface | `DS3Colors.brandSurface` |
| Internal padding (horizontal) | 12pt | `DS3Spacing.md` |
| Internal padding (vertical) | 10pt | `DS3Spacing.sm` |
| External padding (horizontal, between row and tray edge) | 16pt | `DS3Spacing.lg` |
| Vertical spacing between cards | 6pt | `DS3Spacing.xs` |
| Hover overlay | `brandPrimary @ 8% opacity` over the card | `DS3Colors.brandPrimary.opacity(0.08)` |
| Leading **accent stripe** | 3pt-wide vertical bar inside the card on the leading edge, color = per-drive status | `DS3Colors.statusSynced/Syncing/Error/Paused` |

The card itself uses the existing inner column layout (drive icon + status
badge → name/anchor/metrics → gear menu) so the only structural change is
the card chrome. The accent stripe is the **visual hook** that ties each
card to its current sync state without needing a status word.

### Drive card typography hierarchy

Three lines, decreasing emphasis:

| Line | Content | Font | Color token |
|---|---|---|---|
| 1 (drive name) | `drive.name` | `DS3Typography.body.bold()` | `DS3Colors.brandTextPrimary` |
| 2 (anchor / project) | `syncAnchorString()` | `DS3Typography.caption` | `DS3Colors.brandTextSecondary` |
| 3 (metrics row) | speed / status / last update | `DS3Typography.footnote` | `DS3Colors.brandTextSecondary` (status icons keep their semantic color) |

The drive name is bold to anchor the eye. The metrics row stays
secondary-colored so it doesn't compete.

### Section separators (TrayMenuView)

Replace SwiftUI `Divider()` (system separator) with a softer brand
divider so the surface feels intentional:

```swift
Rectangle()
    .fill(DS3Colors.brandBorder.opacity(0.4))
    .frame(height: 1)
    .padding(.horizontal, DS3Spacing.lg)
```

`brandBorder` is already adaptive (light grey-200 / dark grey-700) so this
divider works in both appearances. The horizontal inset (16pt) makes the
separator feel "inside" the card stack rather than slicing the entire
window.

### Menu container background (TrayMenuView)

The root tray container uses `DS3Colors.brandBackground` (adaptive
grey-50 / grey-900) so the cards visually float above the surface. This
also gives the tray a clear edge in dark mode where the system menu
background can blend into the wallpaper.

### Quick-action menu items (TrayMenuItem)

The action rows (Add a new Drive, Preferences, Help, Sign Out, etc.) keep
their list-row structure but get a brand hover treatment:

| Property | Value | Token |
|---|---|---|
| Hover background shape | `RoundedRectangle(cornerRadius: 6)` | — |
| Hover background fill | `brandPrimary @ 12% opacity` | `DS3Colors.brandPrimary.opacity(0.12)` |
| Hover horizontal inset | 12pt (so the rounded chip floats inside the row) | `DS3Spacing.md` |
| Text color (enabled) | `brandTextPrimary` | `DS3Colors.brandTextPrimary` |
| Text color (disabled) | `brandTextSecondary` | `DS3Colors.brandTextSecondary` |
| Text color (accent / update available) | `brandPrimary` | `DS3Colors.brandPrimary` |

This replaces the previous `DS3Colors.hoverHighlight.opacity(0.15)` system
selection color with a brand-tinted hover that matches the card stack
above it.

### Footer (TrayMenuFooterView)

| Property | Value | Token |
|---|---|---|
| Background | `brandSurface @ 60% opacity` | `DS3Colors.brandSurface.opacity(0.6)` |
| Top border | 1pt rectangle | `DS3Colors.brandBorder.opacity(0.4)` |
| State icon | from existing `statusIcon` switch (Plan 05-10 Task 3) | semantic |
| Status text | `DS3Typography.footnote` | `DS3Colors.brandTextSecondary` |
| Version label | `DS3Typography.footnote` | `DS3Colors.brandTextSecondary` |
| Update-available label | `DS3Typography.footnote` | `DS3Colors.brandPrimary` |

Footer is intentionally subtle: a tinted strip with a thin top border
demarcates the chrome from the action list above without dominating it.

### Speed Summary (SpeedSummaryView)

Numerical values get the brand-primary treatment:

| Element | Color token |
|---|---|
| Upload / download numeric values | `DS3Colors.brandPrimary` |
| Arrow icons | `DS3Colors.brandPrimary` |
| Trailing labels ("All drives up to date", "Syncing files…") | `DS3Colors.brandTextSecondary` |

### Recent Files Panel (RecentFilesPanel)

The panel switches to the brand surface and gets card-style row hover:

| Property | Value | Token |
|---|---|---|
| Panel background | adaptive surface | `DS3Colors.brandSurface` |
| Panel padding | 12pt internal | `DS3Spacing.md` |
| Header title color | `brandTextSecondary` | `DS3Colors.brandTextSecondary` |
| Row hover background | `brandPrimary @ 8% opacity` | `DS3Colors.brandPrimary.opacity(0.08)` |
| Row filename | `brandTextPrimary` | `DS3Colors.brandTextPrimary` |
| Row subtitle | `brandTextSecondary` | `DS3Colors.brandTextSecondary` |
| Status icon | semantic (`statusSynced/Syncing/Error`) | unchanged |
| Empty-state icon | `brandTextSecondary` | `DS3Colors.brandTextSecondary` |

### Sync Share 2.0 → Cubbit token remap

| Sync Share 2.0 concept | Cubbit token used |
|---|---|
| Drive card surface | `DS3Colors.brandSurface` |
| Card border / separator | `DS3Colors.brandBorder` |
| Primary text | `DS3Colors.brandTextPrimary` |
| Secondary text | `DS3Colors.brandTextSecondary` |
| Accent stripe (synced) | `DS3Colors.statusSynced` |
| Accent stripe (syncing) | `DS3Colors.statusSyncing` |
| Accent stripe (error) | `DS3Colors.statusError` |
| Accent stripe (paused) | `DS3Colors.statusPaused` |
| Brand-tinted hover | `DS3Colors.brandPrimary @ 8-12% opacity` |
| Window background | `DS3Colors.brandBackground` |

The Sync Share 2.0 design uses its own grey/blue ramps that are similar
but **not identical** to the Cubbit palette. We deliberately do **not**
copy those hex values; the Cubbit brand tokens take precedence so the
tray matches the rest of the app (login, wizard, prefs, tutorial — all
landed in plan 05-11).

## SwiftUI Constraints / Divergences from Figma

These are intentional divergences where AppKit / SwiftUI menu plumbing
forces a different approach than the pure Figma layout:

1. **Fixed tray width.** `TrayMenuView` sets `.frame(width: 310)` so
   the floating-panel based tray doesn't reflow when content changes.
   Figma shows the layout at a wider canvas; we keep it at 310 to match
   the existing tray plumbing and avoid clipping the menu bar dropdown.
2. **Card spacing inside `VStack`.** Pure Figma uses CSS-grid-style gap;
   SwiftUI `VStack` with `spacing:` is the equivalent and we use 6pt
   between drive cards (DS3Spacing.xs) so adjacent cards don't merge
   visually but the list still feels dense.
3. **No drop shadow on cards.** Figma cards have a soft shadow, but
   inside an NSStatusItem floating panel a drop shadow would clash with
   the system window shadow. We use the brand surface against the
   slightly darker brand background to create the lift instead.
4. **Hover overlay instead of pressed state.** macOS menus don't have
   a "pressed" state in the same way; we use a stronger hover tint
   (12% on action rows, 8% on cards) as the only interaction signal.
5. **Separator inset.** Figma separators span edge-to-edge; we inset
   horizontally by `DS3Spacing.lg` so they read as "between sections"
   rather than "cuts the window in half" — this is closer to native
   macOS dropdown menus.
6. **Aggregate row stays plain.** The "All drives up to date" aggregate
   row at the top of the menu (only shown when `drives.count >= 2`)
   stays as a plain row without card chrome — it's a header, not a
   card, and adding chrome would compete with the cards below.

## Implementation Checklist for Task 2

- [ ] `TrayDriveRowView`: card chrome (`brandSurface` rounded rect),
      accent stripe, bold name, brandText* hierarchy
- [ ] `TrayMenuView`: `brandBackground` root, `brandBorder` divider
      replacement helper, preserved menu order
- [ ] `TrayMenuItem`: rounded brand-tinted hover, `brandText*` colors
- [ ] `TrayMenuFooterView`: tinted background, top border, brand text
- [ ] `SpeedSummaryView`: `brandPrimary` numerics, `brandTextSecondary`
      labels
- [ ] `RecentFilesPanel`: `brandSurface` panel, brand-tinted row hover,
      brand text colors
- [ ] `DS3Colors`: confirm `statusSynced/Syncing/Error/Paused` and
      `brandTextPrimary/Secondary` are exposed (they already are; no
      additions required)
- [ ] zero `darkWhite` / `darkMainStandard` references in tray files
      (already zero — verified)

## Inferred / Verify-against-Figma

When the Figma MCP tools become available, reconcile:

- Exact card corner radius (10pt is a sensible default; Figma may use 8 or 12)
- Accent stripe width (3pt vs 4pt) and inset
- Card vertical spacing
- Whether the divider inset matches the Figma intent
- Whether hover opacity should be 8% or 12% on cards
