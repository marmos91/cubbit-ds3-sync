---
phase: 17-windows-shell
plan: 08
subsystem: windows-app-shell
tags: [winui3, di-host, mica, navigation, single-instance, login, 2fa, tutorial, brand-tokens]
requires: [17-05, 17-07]
provides:
  - DS3Drive.App WinUI 3 shell (DI host, Mica MainWindow, design tokens, navigation)
  - DS3Drive.ViewModels library (LoginViewModel, TwoFactorViewModel, TutorialViewModel, INavigator, IAuthenticationService, ISingleInstanceService/SingleInstanceService)
  - Login + 2FA + Tutorial pages (UI-SPEC-compliant)
  - AuthenticationService (DS3Session-backed), single-instance Mutex guard, Open-at-login HKCU Run-key write
affects:
  - windows/DS3Drive.App (Plan 09 drive-setup wizard takes over after successful login)
tech-stack:
  added:
    - Microsoft.WindowsAppSDK (WinUI 3, Mica backdrop)
    - CommunityToolkit.Mvvm (view-models) [as declared in plan]
  patterns:
    - "View-models extracted to a non-WinUI DS3Drive.ViewModels library so a headless xUnit host can load them (referencing the WinUI App exe crashes the test host on the Windows App Runtime bootstrap)"
    - "WinUI-free INavigator/PageKey abstraction; App.NavigationService maps PageKey->Type"
    - "1007 -> Need2FA routing byte-identical to Apple LoginViewModel.swift (D-15)"
    - "Single-instance Mutex name suffixed with user SID (D-27)"
key-files:
  created:
    - windows/DS3Drive.App/App.xaml
    - windows/DS3Drive.App/App.xaml.cs
    - windows/DS3Drive.App/MainWindow.xaml
    - windows/DS3Drive.App/Themes/Tokens.xaml
    - windows/DS3Drive.App/Themes/Brushes.xaml
    - windows/DS3Drive.App/Controls/BrandPrimaryButton.xaml
    - windows/DS3Drive.App/Services/NavigationService.cs
    - windows/DS3Drive.App/Services/AuthenticationService.cs
    - windows/DS3Drive.App/Pages/LoginPage.xaml
    - windows/DS3Drive.App/Pages/TwoFactorPage.xaml
    - windows/DS3Drive.App/Pages/TutorialPage.xaml
    - windows/DS3Drive.ViewModels/LoginViewModel.cs
    - windows/DS3Drive.ViewModels/TwoFactorViewModel.cs
    - windows/DS3Drive.ViewModels/TutorialViewModel.cs
    - windows/DS3Drive.ViewModels/SingleInstanceService.cs
    - windows/DS3Drive.Tests/LoginViewModelTests.cs
    - windows/DS3Drive.Tests/TwoFactor... (TwoFactor/SingleInstance/Tutorial tests)
    - windows/global.json
  modified:
    - windows/DS3Drive.sln
decisions:
  - "[17-08] Extracted view-models, IAuthenticationService, ISingleInstanceService/SingleInstanceService, and a WinUI-free INavigator/PageKey nav abstraction into a new non-WinUI DS3Drive.ViewModels class library — the plan placed them in DS3Drive.App, but referencing the WinUI exe (WinExe + UseWinUI) into a headless xUnit host crashes the test host on the Windows App Runtime bootstrap, making the required view-model unit tests impossible. App.NavigationService implements INavigator. All behavior preserved; view-models now unit-testable."
  - "[17-08] Added windows/global.json pinning SDK 8.0.421 (a stray 9.0.314 auto-install disrupted the build)."
  - "[17-08] Fixed mc:Ignorable=\"d\" namespace-ordering that silently crashed the XAML compiler."
manual_verification_deferred:
  - "Task 4 blocking human-verify (manual UI smoke, 12 steps) DEFERRED to phase HUMAN-UAT per user decision 2026-05-29 — requires running app + display + 2FA test account + native ds3_ffi.dll. Code complete; visual/live-auth smoke pending."
metrics:
  duration: ~45min
  tasks: 3 of 4 (Task 4 manual smoke deferred to HUMAN-UAT)
  files: ~20
  tests: 74 passing (Category!=Integration), full solution build 0/0
  completed: 2026-05-29
---

# Phase 17 Plan 08: WinUI 3 App Shell + Login/2FA/Tutorial Summary

The "user can sign in" milestone (WIN-01). Delivered the WinUI 3 application shell (DI host, design tokens per UI-SPEC, Mica `MainWindow`, navigation service, single-instance Mutex guard) and the Login → 2FA → Tutorial flow with view-models and `AuthenticationService`.

## Commits
- `7f5d15c` feat(17-08): app shell — DI host, tokens, Mica, MainWindow, services
- `5bbe8cf` feat(17-08): Login + 2FA pages, view-models, 2FA-routing TDD
- `fec0ec3` feat(17-08): Tutorial page + view-model + Open-at-login registry write

## Verification (automated, headless — all green)
- `dotnet build windows/DS3Drive.sln -p:DS3SkipRustCore=true -p:Platform=x64` → 0 warnings / 0 errors (WinUI XAML compiler runs and compiles all three pages).
- `dotnet test windows/DS3Drive.Tests --filter "Category!=Integration" -p:DS3SkipRustCore=true -p:Platform=x64` → **74/74 passing** (incl. 1007→Need2FA routing, single-instance, registry-write on/off).
- UI-SPEC enforcement greps clean: no `Type.H3`, no `Medium` weight, no `Figtree-Medium.ttf`, all 6 spacing Thickness tokens present, "Sign in" copy, 2FA `NumericPin`/`MaxLength=6`, D-15 traceability comments.

## Deferred — Task 4 Manual UI Smoke (blocking human-verify)
Per user decision (2026-05-29), the 12-step manual UI smoke is deferred into the phase HUMAN-UAT and will be performed once the local x64 `ds3_ffi.dll`, Windows App SDK runtime, and a 2FA test account are available (ideally bundled with the 17-11 tray-app smoke). Checklist preserved in `17-HUMAN-UAT.md`. The code for Tasks 1-3 is complete and committed.

## Self-Check: PASSED (automated scope); manual UI smoke DEFERRED to HUMAN-UAT
