---
phase: 17-windows-shell
plan: 09
subsystem: windows-shell
tags: [winui3, wizard, drive-setup, api-key-reconciliation, drives-list]
requires:
  - "17-05: DS3Session (GetProjects/ListBuckets/ListObjects/ForgeIamToken/LoadApiKeys/CreateApiKey/DeleteApiKey), ConfigStore, CredentialStore"
  - "17-06: SyncDatabase (drives + api_keys tables), SchemaMigrator"
  - "17-08: DS3Drive.ViewModels testable-VM split, INavigator/PageKey nav abstraction, AuthenticationService"
provides:
  - "DriveSetupViewModel: 4-step wizard state machine (Project→Bucket→Prefix→Confirm)"
  - "IDS3SdkService/DS3SdkService: API-key reconciliation port of DS3SDK.swift:163-249"
  - "IDriveManagementService/DriveManagementService: drive-list owner + persistence triple + DriveAdded/DriveRemoved events + AggregateStatus"
  - "DrivesListPage: post-tutorial landing page (Plan 08 TODO resolved)"
  - "WizardStepIndicator control + 4 wizard step pages + DriveSetupWizardPage shell"
affects:
  - "17-10 (cfapi): subscribes to IDriveManagementService.DriveAdded/DriveRemoved to register/unregister the sync root"
  - "17-11 (tray): reads IDriveManagementService.Drives + AggregateStatus; promotes inline drive row to reusable DriveRow"
tech-stack:
  added: []
  patterns:
    - "IDS3SessionGateway seam over sealed DS3Session for mockable remote calls"
    - "Persistence triple (mutate → SQLite → event) with SemaphoreSlim serialization"
key-files:
  created:
    - windows/DS3Drive.ViewModels/Services/DS3DriveStatus.cs
    - windows/DS3Drive.ViewModels/Services/IDS3SessionGateway.cs
    - windows/DS3Drive.ViewModels/Services/IInstallationIdProvider.cs
    - windows/DS3Drive.ViewModels/Services/SqliteInstallationIdProvider.cs
    - windows/DS3Drive.ViewModels/Services/IDS3SdkService.cs
    - windows/DS3Drive.ViewModels/Services/DS3SdkService.cs
    - windows/DS3Drive.ViewModels/Services/IDriveManagementService.cs
    - windows/DS3Drive.ViewModels/Services/DriveManagementService.cs
    - windows/DS3Drive.ViewModels/Services/DrivesRepository.cs
    - windows/DS3Drive.ViewModels/ViewModels/DriveSetupViewModel.cs
    - windows/DS3Drive.ViewModels/ViewModels/DrivesListViewModel.cs
    - windows/DS3Drive.Sync/Migrations/002_singleton_state.sql
    - windows/DS3Drive.App/Controls/WizardStepIndicator.xaml(.cs)
    - windows/DS3Drive.App/Pages/DriveSetupWizardPage.xaml(.cs)
    - windows/DS3Drive.App/Pages/ProjectSelectionPage.xaml(.cs)
    - windows/DS3Drive.App/Pages/BucketSelectionPage.xaml(.cs)
    - windows/DS3Drive.App/Pages/PrefixSelectionPage.xaml(.cs)
    - windows/DS3Drive.App/Pages/DriveConfirmPage.xaml(.cs)
    - windows/DS3Drive.App/Pages/DrivesListPage.xaml(.cs)
    - windows/DS3Drive.Tests/DriveSetupViewModelTests.cs
    - windows/DS3Drive.Tests/ApiKeyReconciliationTests.cs
    - windows/DS3Drive.Tests/DriveManagementServiceTests.cs
  modified:
    - windows/DS3Drive.ViewModels/DS3Drive.ViewModels.csproj (added DS3Drive.Sync + Microsoft.Data.Sqlite refs)
    - windows/DS3Drive.Sync/DS3Drive.Sync.csproj (embedded migration 002)
    - windows/DS3Drive.ViewModels/Navigation/PageKey.cs (added DriveSetupWizard)
    - windows/DS3Drive.ViewModels/ViewModels/TutorialViewModel.cs (Finish → DrivesList)
    - windows/DS3Drive.App/App.xaml.cs (DI + SyncDatabase open + DrivesListPage routing)
    - windows/DS3Drive.App/Services/AuthenticationService.cs (implements IDS3SessionGateway)
    - windows/DS3Drive.App/Services/NavigationService.cs (DrivesList/DriveSetupWizard page map)
    - windows/DS3Drive.Tests/SyncDatabaseTests.cs (migration count 1 → 2)
decisions:
  - "Testable view-models + services placed in DS3Drive.ViewModels (WinUI-free), not DS3Drive.App as the plan listed — referencing the WinUI App exe into the headless xUnit host crashes it (same root cause as the 17-08 split)"
  - "IDS3SessionGateway seam introduced so the sealed DS3Session is mockable; AuthenticationService (the session owner) implements it"
  - "InstallationId stored in a new singleton_state SQLite table (migration 002) — Apple's appUUID analog, threat T-17-09-04"
metrics:
  duration_min: 27
  completed: 2026-05-29
  tasks_completed: 2
  tasks_total: 3
  files_created: 31
  files_modified: 8
---

# Phase 17 Plan 09: Drive Setup Wizard + Drives List Summary

JWT-style API-key reconciliation byte-ported from `DS3SDK.swift:163-249` plus a 4-step WinUI 3 drive-setup wizard (Project → Bucket → Prefix → Confirm, D-09) and the post-tutorial DrivesListPage, all backed by a `DriveManagementService` whose persistence triple (mutate → SQLite → cfapi event) matches Apple's `DS3DriveManager`.

## What shipped

- **DriveSetupViewModel** — the Windows expansion of Apple's collapsed 2-step `SyncSetupViewModel` (PATTERNS §2.5) into the 4-step `WizardStep` machine mandated by D-09. Back navigation preserves picker state (UI-SPEC Open Q #4: yes). `CreateDriveAsync` ports `SetupSyncView.swift:67-83`: reconcile key → build `DS3Drive` → `AddAsync` → raise `WizardCompleted`.
- **DS3SdkService** — byte-for-byte port of the API-key reconciliation algorithm (D-10, PATTERNS §2.6) including the deterministic name pattern `{prefix}({username}_{project_lc_underscored}_{installationId})`. All four reconcile branches (matching pair, remote-only, local-only, both-differ) reproduced from `DS3SDK.swift:178-194`.
- **DriveManagementService** — drive-list owner with the PATTERNS §3.3 persistence triple (and the symmetric inverse on remove: unregister-before-delete), the D-23 3-drive hard cap, drive-name validation (T-17-09-01 regex), `SemaphoreSlim` serialization (T-17-09-03), `DriveAdded`/`DriveRemoved` events for Plan 10, and the `AggregateStatus` reducer for Plan 11.
- **UI** — `WizardStepIndicator` numbered-circle rail, the four step pages (ListView pickers + lazy TreeView prefix + summary card), the wizard shell with Back/Cancel/Continue/Create-drive bar, and `DrivesListPage` with empty state + cap-aware "Add drive" CTA. App routes authenticated launch and tutorial-finish to DrivesListPage (Plan 08 TODO resolved).

## Tests

- `DriveSetupViewModelTests` — 11 cases (state machine).
- `ApiKeyReconciliationTests` — 7 cases (A1 name format byte-for-byte + A2-A6 reconcile branches + A7 determinism).
- `DriveManagementServiceTests` — 5 cases (triple ordering, D-23 cap, name validation, remove ordering, AggregateStatus precedence) — added (Rule 2) so the load-bearing persistence ordering + security cap are covered automatically, not only in the manual smoke.
- Full suite: **97 passed, 0 failed** (`--filter "Category!=Integration"`). Solution builds clean (`-p:DS3SkipRustCore=true -p:Platform=x64`, 0 warnings with TreatWarningsAsErrors).

## Deviations from Plan

### Deviations (architecture / file placement)

**1. [Rule 3 - Blocking] Testable view-models + services moved to DS3Drive.ViewModels**
- **Issue:** The plan lists `DriveSetupViewModel`, `DS3SdkService`, `DriveManagementService`, `DrivesRepository`, `DrivesListViewModel` under `windows/DS3Drive.App/...`. The App is a WinUI 3 `WinExe`; referencing it into the headless xUnit host crashes on the Windows App Runtime bootstrap (the documented 17-08 root cause).
- **Fix:** Placed all unit-tested logic in `DS3Drive.ViewModels` (WinUI-free) and added a `ProjectReference` to `DS3Drive.Sync` (also WinUI-free) + `Microsoft.Data.Sqlite`. Only the XAML pages + `WizardStepIndicator` stay in `DS3Drive.App`.
- **Acceptance-criteria paths:** the grep targets resolve against the relocated files; all criteria still pass.

**2. [Rule 3 - Blocking] IDS3SessionGateway seam for a mockable session**
- **Issue:** Reconcile tests A2-A6 require mocking `DS3Session`, which is `sealed` with concrete FFI methods.
- **Fix:** Introduced `IDS3SessionGateway` (1:1 with the session methods the SDK needs); `AuthenticationService` (the single session owner) implements it and is registered for both `IAuthenticationService` and `IDS3SessionGateway` as the same singleton.

**3. [Rule 2 - Missing critical] InstallationId persistence (migration 002)**
- **Issue:** `ApiKeyName` needs Apple's `appUUID` analog (a stable per-install id). Plan 05 `ConfigStore` does not expose one, and `ConfigStore` has no SQLite access.
- **Fix:** Added `IInstallationIdProvider` + `SqliteInstallationIdProvider` backed by a new `singleton_state` table (migration `002_singleton_state.sql`), lazily generating + persisting a GUID (threat T-17-09-04).

**4. [Rule 1 - Bug] SyncDatabaseTests migration-count regression**
- **Issue:** Migration 002 made `schema_version` hold 2 rows; three pre-existing `SyncDatabaseTests` asserted exactly 1.
- **Fix:** Updated the three assertions to a `MigrationCount = 2` constant with a clarifying comment. (In scope: directly caused by this plan's migration.)

**5. [Rule 3 - Blocking] ListChildPrefixesAsync added to IDS3SdkService**
- **Issue:** The PrefixSelectionPage TreeView needs an S3 prefix-listing data source not present on the interface.
- **Fix:** Added `ListChildPrefixesAsync` (delegates to `DS3Session.ListObjects` with delimiter "/").

### Out of scope (not touched)

- `core/ds3-ffi/out/NativeMethods.g.cs` shows as modified in the working tree (pre-existing, unrelated generated file) — left untouched per scope boundary.

## Authentication gates

None — all work was offline (mocked gateway + temp-file SQLite). The live-session smoke is part of the deferred manual UAT.

## Manual smoke (Task 3) — DEFERRED to HUMAN-UAT

Per explicit user decision, the blocking manual human-verify checkpoint (run the wizard end-to-end against a live Cubbit account, confirm the API key in the console, verify the 3-drive cap and SQLite rows) is **deferred to the phase HUMAN-UAT**. The 10 verification steps were appended to `.planning/phases/17-windows-shell/17-HUMAN-UAT.md` (entries 10-19, continuing after the 17-08 smoke). No live-SDK/visual results were fabricated.

## Known Stubs

- **PrefixSelectionPage** renders a real lazy TreeView, but the breadcrumb and node selection are minimal; Plan 11 may refine. Not blocking — "Use root" always works and the prefix flows to `SelectPrefix`.
- **DriveManagementService.RepairCredentialsAsync** keys reconcile on the anchor's `IamUserId`/bucket because the anchor stores only ids (no username/project name); the SDK resolves the rest. Full username enrichment lands with Plan 11 account context.
- **Drive `local_root_path`** defaults to `%USERPROFILE%\Cubbit\<name>` in DrivesRepository; the cfapi local root is finalized by Plan 10.

These are intentional and documented for the follow-on plans; none prevents the plan's goal (a drive is created end-to-end into SQLite + Credential Manager + remote API key).

## Self-Check: PASSED

All listed created files exist on disk; both per-task commits (ea6a5ec, 6e08f99) are present in git history.
