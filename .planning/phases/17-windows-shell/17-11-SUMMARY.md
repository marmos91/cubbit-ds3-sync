---
phase: 17-windows-shell
plan: 11
subsystem: windows-tray
tags: [winui3, system-tray, h-notify-icon, flyout, settings, custom-controls]
requires:
  - 17-08 (App shell, DI host, NavigationService, brand tokens)
  - 17-09 (DriveManagementService, DrivesRepository, DS3SdkService)
  - 17-10 (DriveStatusBroadcaster, sync engine status events)
provides:
  - TaskbarIcon tray host with state-based icon (idle/syncing/paused/error)
  - Acrylic 360x540 tray flyout (drives + recent files + actions)
  - StatusPill / TransferSpeedLabel / TrayDriveRow reusable controls (Plan 09 can adopt)
  - SettingsPage 4 sections (Account / Coordinator URL / Drives / Logging)
  - ITrayService / IRecentFilesService contracts
affects:
  - windows/DS3Drive.App (App.xaml DI, NavigationService, App.xaml.cs OnLaunched)
tech-stack:
  added:
    - H.NotifyIcon.WinUI (TaskbarIcon — pinned 2.3.2, verified Plan 02)
  patterns:
    - "WinUI 3: {x:Bind} surface must live in a FrameworkElement-rooted UserControl, never on a <Window> root"
    - "Aggregate status precedence reducer (Error > Syncing > Paused > Idle) in WinUI-free ViewModels assembly for headless testability"
key-files:
  created:
    - windows/DS3Drive.App/Tray/TrayHost.cs
    - windows/DS3Drive.App/Tray/TrayFlyoutWindow.xaml(.cs)
    - windows/DS3Drive.App/Tray/TrayFlyoutView.xaml(.cs)
    - windows/DS3Drive.App/Services/ITrayService.cs
    - windows/DS3Drive.App/Services/TrayService.cs
    - windows/DS3Drive.App/Pages/SettingsPage.xaml(.cs)
    - windows/DS3Drive.App/Controls/BrandDestructiveButton.xaml
    - windows/DS3Drive.App/Assets/TrayIcons/{icon-idle,icon-syncing,icon-paused,icon-error}.ico + README.md
    - windows/DS3Drive.ViewModels/Services/IRecentFilesService.cs
    - windows/DS3Drive.ViewModels/Services/RecentFilesService.cs
    - windows/DS3Drive.ViewModels/ViewModels/TrayViewModel.cs
    - windows/DS3Drive.ViewModels/ViewModels/SettingsViewModel.cs
    - windows/DS3Drive.ViewModels/ViewModels/TrayDriveRowViewModel.cs (Task 1)
    - windows/DS3Drive.App/Controls/{StatusPill,TransferSpeedLabel,TrayDriveRow}.xaml(.cs) (Task 1)
    - windows/DS3Drive.App/Converters/{SpeedFormatConverter,RelativeTimeConverter}.cs (Task 1)
    - windows/DS3Drive.Tests/{SpeedFormatConverterTests,TrayViewModelTests}.cs
  modified:
    - windows/DS3Drive.App/App.xaml (BrandDestructiveButton dictionary)
    - windows/DS3Drive.App/App.xaml.cs (tray DI registrations + Initialize wiring)
    - windows/DS3Drive.App/Services/NavigationService.cs (PageKey.Settings mapping)
    - windows/DS3Drive.App/DS3Drive.App.csproj (TrayIcons content include)
    - windows/DS3Drive.ViewModels/Navigation/PageKey.cs (Settings key)
decisions:
  - "ViewModels + services placed in DS3Drive.ViewModels (WinUI-free) for headless xUnit testability — same split as Plan 09/10"
  - "TrayFlyoutWindow split into thin Window + TrayFlyoutView UserControl (WinUI 3 x:Bind-on-Window restriction; Rule-3 deviation)"
  - "Recent files resolved to a GLOBAL top-5 (not per-drive) for flyout compactness, per UI-SPEC Component Inventory note"
metrics:
  duration: "continuation (Task 1 prior; Tasks 2-3 finalized this session)"
  completed: 2026-05-29
  tasks_completed: 3
  tasks_total: 4
  files_touched: 28
---

# Phase 17 Plan 11: System Tray Summary

Windows system tray lit up — an H.NotifyIcon TaskbarIcon with four state icons, a single-click Acrylic 360×540 flyout (per-drive rows with StatusPill + TransferSpeedLabel + gear menu, recent activity, footer actions), a right-click compact quick-action menu, and a 4-section SettingsPage (Account / Coordinator URL / Drives / Logging) — matching the macOS menu-bar tray IA per CONTEXT D-22 + UI-SPEC.

## What Was Built

- **Task 1 (prior commit `e0363c9`):** SpeedFormatConverter + RelativeTimeConverter (TDD, 6 tests), StatusPill (5 variants), TransferSpeedLabel (tabular numerals), TrayDriveRow custom control with the load-bearing `IsHitTestVisible="False"` hover-tint discipline, TrayDriveRowViewModel.
- **Task 2 (commit `3fa9fb5`):** TrayHost (H.NotifyIcon TaskbarIcon + right-click MenuFlyout), TrayFlyoutWindow/TrayFlyoutView (Acrylic flyout), ITrayService/TrayService, IRecentFilesService/RecentFilesService (in-memory ring buffer, no persistence — T-17-11-01), TrayViewModel (aggregate precedence + tooltip variants), 4 placeholder ICOs + README, TrayViewModelTests (8 tests). DI + Initialize wired in App.xaml.cs.
- **Task 3 (commit `3fa9fb5`):** SettingsPage (NavigationView, 4 sections, Type.H2 headings), SettingsViewModel (Account/Coordinator/Drives/Logging + destructive confirm hooks), BrandDestructiveButton style, PageKey.Settings navigation mapping. Destructive dialogs carry UI-SPEC §Destructive copy verbatim ("Sign out of Cubbit?" / "Stay signed in"; "Remove this drive?").
- **Task 4 (checkpoint):** Manual UI smoke DEFERRED to phase HUMAN-UAT (entries #32–43 appended to `17-HUMAN-UAT.md`) per user decision — requires a Windows 11 ARM64 VM with the live Rust DLL + 2 drives.

## Verification

- Full solution builds clean: `dotnet build DS3Drive.sln -p:DS3SkipRustCore=true -p:Platform=x64` → 0 Warnings / 0 Errors.
- `dotnet test DS3Drive.Tests --filter "Category!=Integration" -p:DS3SkipRustCore=true -p:Platform=x64` → 140 passed / 0 failed.
- TrayViewModelTests: 8 passed (≥7 required — precedence Error>Syncing>Paused>Idle, tooltip variants, 3-drive cap).
- SpeedFormatConverterTests: 6 passed.
- Acceptance greps (TaskbarIcon, DesktopAcrylicBackdrop, 360×540, precedence, 4 nav sections, "Stay signed in", Type.H2, no Type.H3, BrandDestructiveButton, IsHitTestVisible) all satisfied.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking build error] WinUI 3 forbids {x:Bind} on a `<Window>` root**
- **Found during:** Finalizing Tasks 2-3 (known build error handed off in the continuation brief).
- **Issue:** `TrayFlyoutWindow.xaml` had a `<Window>` root using `{x:Bind ViewModel...}` compiled bindings. WinUI 3's binding code-gen targets `FrameworkElement`; `Window` is not one, so `TrayFlyoutWindow.g.cs` failed with `CS1503: cannot convert from 'TrayFlyoutWindow' to 'Microsoft.UI.Xaml.FrameworkElement'`.
- **Fix:** Split per the standard WinUI 3 pattern — moved the entire bound Grid (header, drives ListView, recent activity, footer, all x:Bind + StatusPill sync + entrance animation) into a new FrameworkElement-rooted `Tray/TrayFlyoutView.xaml(.cs)` UserControl with a `ViewModel` dependency property as the x:Bind source (same pattern as TrayDriveRow/StatusPill). `TrayFlyoutWindow` is now a thin `<Window>` (no x:Bind) that applies the DesktopAcrylicBackdrop + chrome removal, sizes the AppWindow to 360×540, and hosts the view as its content. All behavior, bindings, Acrylic backdrop, chrome removal, and reduced-motion handling preserved.
- **Files modified:** `windows/DS3Drive.App/Tray/TrayFlyoutWindow.xaml`, `TrayFlyoutWindow.xaml.cs`; added `TrayFlyoutView.xaml`, `TrayFlyoutView.xaml.cs`.
- **Commit:** `3fa9fb5`

**2. [Rule 3 - Missing dependency for Task 3] SettingsPage + BrandDestructiveButton did not exist**
- **Found during:** Wiring `PageKey.Settings`.
- **Issue:** The prior executor created `SettingsViewModel.cs` but neither `SettingsPage.xaml(.cs)` nor the `BrandDestructiveButton` style (acceptance criteria require both); `PageKey.Settings` had no NavigationService mapping.
- **Fix:** Created `SettingsPage.xaml(.cs)` (NavigationView 4 sections, destructive ContentDialogs with verbatim copy), `Controls/BrandDestructiveButton.xaml` (registered in App.xaml), added `PageKey.Settings => typeof(SettingsPage)` to NavigationService, and added the `SignOutCancelLabel = "Stay signed in"` copy contract const to SettingsViewModel.
- **Commit:** `3fa9fb5`

### File-location note (not a deviation from intent)

The PLAN listed `TrayViewModel`/`SettingsViewModel`/`RecentFilesService` under `DS3Drive.App/...`, but they were (correctly) placed under `DS3Drive.ViewModels/...` to keep them WinUI-free and headless-testable — the established split from Plans 09/10. Recorded as a decision above.

## Known Stubs

- **Tray ICOs** (`Assets/TrayIcons/*.ico`): monochrome placeholders; final art ships in Phase 18 (documented in `Assets/TrayIcons/README.md`). Functional — H.NotifyIcon resolves them via `ms-appx:///`.
- **Logging "Open log folder"** (SettingsViewModel.OpenLogFolder): P17 placeholder — surfaces a "Log export coming in Phase 18" TeachingTip rather than opening the wevtutil-exported .evtx folder (deferred per PLAN Task 3).
- Both are intentional and documented in the plan; neither blocks the WIN-07 goal (tray shows idle/syncing/error states).

## Deferred Items

- **Manual UI smoke (Task 4 checkpoint):** appended as entries #32–43 in `.planning/phases/17-windows-shell/17-HUMAN-UAT.md` (total bumped 31 → 43). Requires Windows 11 ARM64 VM + live Rust DLL + 2 drives; cannot run in this headless build environment.

## Self-Check: PASSED

- Created files verified present: TrayHost.cs, TrayFlyoutWindow.xaml(.cs), TrayFlyoutView.xaml(.cs), TrayService.cs, ITrayService.cs, SettingsPage.xaml(.cs), BrandDestructiveButton.xaml, TrayViewModel.cs, SettingsViewModel.cs, RecentFilesService.cs, IRecentFilesService.cs, 4 ICOs + README, TrayViewModelTests.cs.
- Commits verified: `e0363c9` (Task 1), `3fa9fb5` (Tasks 2-3) present in `git log`.
- Build 0/0; 140 tests pass.
