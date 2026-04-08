# Phase 5: UX Polish - Context

**Gathered:** 2026-03-13 (updated 2026-04-03)
**Status:** Ready for planning (plan 05 update)

<domain>
## Phase Boundary

Users have full visibility into sync state and control over their drives through Finder badges, a rich menu bar experience, and a streamlined setup wizard. All windows share a unified design language: system font (SF Pro), macOS light/dark mode support, Cubbit brand accent color, consistent spacing and padding. Copy is audited for clarity and branding, with Italian localization added. The app icon is polished and the menu bar icon is status-aware with animation.

**Update (2026-04-03):** Plans 01-04 are executed. Plan 05 scope expanded to include: bug sweep (macOS + iOS), Swift 6 concurrency warning cleanup (both targets), full visual audit, and human verification on both platforms.

</domain>

<decisions>
## Implementation Decisions

### Finder Sync Badges
- Five badge states using SF Symbols with standard sync client colors:
  - Synced: green checkmark (checkmark.circle)
  - Syncing: blue arrows (arrow.triangle.2.circlepath)
  - Error: red X (xmark.circle)
  - Cloud-only: gray cloud (cloud)
  - Conflict: orange/yellow warning (exclamationmark.triangle) -- distinct from error
- Badges use NSFileProviderItemDecoration (S3Item.decorationPrefix already defined)
- Standard color convention: green=synced, blue=syncing, red=error, orange/yellow=conflict, gray=cloud-only
- Folders show aggregate badge reflecting children's status (syncing if any child syncing, error if any child error, synced only when all synced)
- No root drive badge in Finder sidebar (matches Dropbox/Google Drive behavior)
- No badge animation -- instant state transition
- Real-time badge updates via signalEnumerator when syncStatus changes in MetadataStore
- Bottom-left corner overlay position (macOS default for File Provider decorations)
- No pause badge on files -- pause is drive-level, files keep last badge state

### Menu Bar Tray Icon
- Status-aware: swap entire icon for different states (idle, syncing, error)
- Syncing state: animated rotating/pulsing arrows icon (like Dropbox)
- Keep current icon design, ensure it works in both light and dark menu bar themes (template image)
- Icon variants needed: idle, syncing (animated), error, paused

### Menu Bar Tray Menu
- Per-drive colored dot indicators: green=synced, blue=syncing, red=error, yellow/orange=paused
- Drive rows show all four metrics (matching Figma): file count, total size, current speed, sync time
- Global speed summary at top of tray: aggregate upload/download speed across all drives
- Per-drive speed inline on each drive row
- Right-click context menu on drive rows (same actions as gear menu)
- "Signed in as user@email.com" kept in main tray
- Connection Info moved to separate side panel (out of main tray body)
- Footer: keep status text + version
- Visual refresh: system font (SF Pro), follow macOS light/dark mode, Cubbit brand accent color, improved spacing/padding/visual hierarchy

### Side Panels (Tray Menu Expansion)
- Two separate side panels, one at a time:
  1. Per-drive recent files panel (triggered by clicking a drive row)
  2. Connection Info panel (triggered by clicking "Connection Info" row at bottom of tray)
- Side panels same width as main tray (~310pt), appear to the left
- Recent files: sorted by progress first, then errors, then completed (synced)
- Show last 10 files per drive
- Each file row: status dot + filename + size + time
- Click a recent file to reveal in Finder (NSWorkspace.shared.activateFileViewerSelecting)
- Connection Info panel shows: coordinator URL, S3 endpoint, tenant, console URL (same fields as before, click-to-copy)

### Pause Sync
- Per-drive pause/resume (not global)
- Pause button in drive gear menu (and right-click context menu)
- Pause behavior: finish current transfer, stop new transfers
- Paused drive shows yellow/orange dot indicator + existing paused drive icon
- Pause state persists across app restarts (stored in SharedData)

### Quick Actions
- Drive gear menu (and right-click): Disconnect, View in Finder, View in Console, Manage, Refresh, Pause/Resume, Copy S3 Path (new)
- Finder right-click on files (via NSFileProviderUserInteractions): "Copy S3 Key" and "View in Web Console"

### Drive Setup Wizard
- Merge from 3 steps to 2 steps:
  - Step 1: Tree view with Project > Bucket > folder prefix navigation (based on current SyncAnchorSelectionView sidebar + content layout)
  - Step 2: Name + confirm with summary of selected path
- Tree view shows names only (minimal metadata, no extra API calls)
- Drive name auto-suggested from bucket/prefix selection, editable
- Existing bucket selection only (no inline bucket creation)
- Window size: keep 800x480
- Skeleton/shimmer loading states (replaces current flashing behavior)
- Refactor data loading to avoid UI flashing (pre-load before showing, keep previous data visible until new arrives)
- Step 2 shows read-only summary of project/bucket/prefix above the name field

### Login Window
- Redesigned: centered card, minimal style (like 1Password/Notion)
- DS3 Drive logo at top, fields below, Advanced as collapsible section
- Compact window: 400x500
- Always persist session (no "Remember me" checkbox)
- Keep existing tutorial after first login, polished to match new design

### Preferences Window
- Redesigned: macOS Settings-style tabbed sections (sidebar tabs)
- Three tabs: General (start at login, notification preferences), Account (name, email, 2FA status, edit on console, disconnect), Sync (badge visibility toggle, auto-pause settings)
- Fixed size: 800x600
- Same unified design language as all other windows

### Visual Design System
- System font (SF Pro) everywhere -- remove all Nunito references
- Follow macOS system appearance (light/dark mode) -- remove hardcoded dark colors (.darkWhite, .darkMainStandard, .background)
- Use SwiftUI semantic colors (.primary, .secondary) + macOS system colors for structural elements
- Cubbit brand blue as accent color (buttons, toggles, selection highlights, progress bars)
- Cubbit brand color palette for identity elements
- Consistent spacing, padding, button styles across all windows (login, preferences, wizard, tray, side panels)
- Polish existing app icon (better resolution, cleaner lines, macOS icon guidelines)

### Copy & Localization
- **D-LOC-01:** Italian localization only for v1.0 — verify existing 83 entries are complete and correct. No other languages.
- Audit all user-facing strings for "DS3 Drive" branding (fix remaining "Cubbit DS3 Sync" references)
- Review and improve all copy for clarity and consistency
- System language auto-detection (standard Apple localization)
- NSLocalizedString infrastructure already in place

### CI / Swift 6 Concurrency (NEW — 2026-04-03)
- **D-CI-01:** Fix ALL Swift 6 concurrency warnings across the entire codebase — not just blocking errors
- **D-CI-02:** Both macOS and iOS targets must be clean
- **D-CI-03:** Xcode 26.4 RC is the CI runner — stricter sendability enforcement (e.g., LoginViewModel @MainActor fix already applied)

### Bug Sweep (NEW — 2026-04-03)
- **D-BUG-01:** Bug sweep before final polish — find and fix issues on both macOS and iOS
- **D-BUG-02:** Includes runtime bugs, not just build issues
- **D-BUG-03:** Known issue: "parent folder stuck in progress when child file fails" — investigate and fix if feasible

### Human Verification (NEW — 2026-04-03)
- **D-VER-01:** All 7 macOS UX requirements must pass (badges, tray, speed, recent files, quick actions, wizard, drive limit)
- **D-VER-02:** Full iOS UX verification too — test on a real device
- **D-VER-03:** Both platforms must pass before milestone completion

### UI/Brand Polish (NEW — 2026-04-03)
- **D-UI-01:** App icon refinement — better resolution, cleaner lines, macOS icon guidelines
- **D-UI-02:** Color/spacing audit — all views consistent with design system in both light and dark mode
- **D-UI-03:** Tutorial flow polish — first-run tutorial matches new design language and branding
- **D-UI-04:** Full visual audit: icon, colors, spacing, tutorial — everything looks cohesive

### Claude's Discretion
- Exact SF Symbol names for each badge state (may vary by availability)
- Skeleton/shimmer animation implementation details
- Tray icon animation technique (NSStatusBarButton image swapping interval)
- Tree view expand/collapse animation and interaction details
- Exact Cubbit brand color hex values (from existing asset catalog or brand guidelines)
- Side panel animation (slide in/out direction and timing)
- Tab layout in preferences (icon choice, tab ordering details)
- How to implement Finder right-click actions (NSFileProviderUserInteractions or FileProviderUI)
- Recent files storage mechanism (in-memory ring buffer vs persisted)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design Reference
- Figma design: https://www.figma.com/design/E0QXd1ecdYVm9mDKjOntIK/Sync-Share-2.0

### Prior Phase Work
- `.planning/phases/05-ux-polish/05-01-SUMMARY.md` — Design system tokens + Finder sync badges
- `.planning/phases/05-ux-polish/05-02-SUMMARY.md` — Pause state + recent files tracker
- `.planning/phases/05-ux-polish/05-03-SUMMARY.md` — Wizard, login, preferences redesign
- `.planning/phases/05-ux-polish/05-04-SUMMARY.md` — Tray menu overhaul with side panels

### Key Implementation Files
- `DS3DriveProvider/S3Item.swift` — Badge decorations, item metadata
- `DS3Drive/Views/Common/DesignSystem/` — DS3Colors, DS3Typography, DS3Spacing, ShimmerModifier
- `DS3Drive/Assets/Localizable.xcstrings` — String catalog with Italian translations
- `DS3Drive/Views/Login/ViewModels/LoginViewModel.swift` — Recently fixed for @MainActor (Swift 6)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `S3Item.decorationPrefix` (DS3DriveProvider/S3Item.swift): Already defined, needs decoration implementation
- `DS3DriveViewModel` (DS3Drive/Views/Tray/ViewModels/): Already computes transfer speed via DistributedNotificationCenter -- extend for recent files tracking
- `TrayMenuView` / `TrayDriveRowView` / `TrayMenuFooterView`: Existing tray structure to evolve
- `SyncAnchorSelectionView` with `BucketSelectionSidebarView` + `SyncAnchorSelectorView`: Base for tree view wizard
- `AppStatus` enum: idle/syncing/error/offline/info -- extend with paused state
- `DS3DriveStatus`: Per-drive status -- add paused state
- Paused drive icon asset already exists
- `DefaultSettings.maxDrives`: Drive limit already enforced (UX-07 is done)
- `NSLocalizedString` used throughout -- localization infrastructure ready
- `ConnectionInfoRow`: Click-to-copy pattern for Connection Info -- reuse in side panel
- `DS3Colors`, `DS3Typography`, `DS3Spacing`: Design system tokens already created in plan 01

### Current State (2026-04-03)
- No Nunito font references remain (only in comments documenting replacements)
- No "Cubbit DS3 Sync" branding references remain
- No hardcoded dark colors (darkWhite, darkMainStandard) in common components
- Italian localization has 83 entries in .xcstrings
- CI uses Xcode 26.4 RC — stricter Swift 6 concurrency enforcement
- LoginViewModel already fixed with @MainActor

### Established Patterns
- `@Observable` for view model state management
- `DistributedNotificationCenter` for extension-to-app IPC (drive status, transfer stats)
- Guard-let chain init in extension methods
- Structured OSLog with subsystem/category
- `withRetries()` for operation retry
- SwiftUI `@Environment` for dependency injection

### Integration Points
- `S3Item`: Add NSFileProviderItemDecoration support for badges
- `FileProviderExtension`: Signal enumerator on syncStatus changes for real-time badges
- `MetadataStore`: Query syncStatus for badge computation and folder aggregation
- `TrayMenuView`: Complete restructure for new layout (drive dots, side panels, speed summary)
- `DS3DriveViewModel`: Extend with recent files tracking and pause state
- `SharedData`: Add pause state persistence per drive
- `SetupSyncView`: Replace 3-step flow with 2-step tree view + confirm
- `LoginView`: Redesign to centered card layout
- `PreferencesView`: Redesign to tabbed sections
- Asset catalog: Add badge images, status icon variants, update colors for light/dark

</code_context>

<specifics>
## Specific Ideas

- Figma reference (https://www.figma.com/design/E0QXd1ecdYVm9mDKjOntIK/Sync-Share-2.0) shows the target layout -- drive rows with file count, size, speed, time + left side panel for recent files
- Recent files ordered: in-progress (syncing) first, then errors, then completed -- most actionable items on top
- Connection Info data moves to its own side panel (not inline in tray body) -- keeps main tray clean
- Current SyncAnchorSelectionView sidebar+content pattern is a good base for the tree view wizard
- All windows should feel like the same application -- unified design language is critical
- Follow Cubbit's color palette as closely as possible for brand elements
- Current UI flashes when data loads in wizard -- must fix with pre-loading and smooth transitions
- "Start Cubbit DS3 sync at login" and similar old branding strings must be updated
- Bug sweep on BOTH macOS and iOS before final verification — runtime issues, not just build
- Swift 6 cleanup across entire codebase — all warnings, both targets

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope. All topics (badges, tray, wizard, login, preferences, dark mode, icon, localization, bug sweep, Swift 6 cleanup, iOS verification) are appropriate final-phase work.

</deferred>

---

*Phase: 05-ux-polish*
*Context gathered: 2026-03-13 (updated 2026-04-03)*
