---
phase: 17-windows-shell
plan: 10
subsystem: cfapi-sync-engine
tags: [cfapi, cloud-files-api, sync-engine, hydration, upload-trigger, polling, status-broadcaster, path-validation]
requires:
  - 17-05 (DS3Session FFI facade: ListObjects/DownloadObject/UploadObject/DeleteObject/CopyObject/ComputeDiff/ConflictKey)
  - 17-06 (SyncDatabase + PlaceholderStore + EnumerationDiff)
  - 17-09 (DriveManagementService DriveAdded/DriveRemoved events)
  - 17-04 (sparse package identity for StorageProviderSyncRootManager.Register)
provides:
  - CfApiProvider (per-drive cfapi lifecycle: Register + Connect + placeholder enum + Disconnect)
  - SyncEngine (per-drive polling + diff + placeholder maintenance)
  - DriveStatusBroadcaster (counter + debounce + batch-error tracker, port of NotificationsManager.swift)
  - PathValidation (S3-key-to-local-path security gate)
  - UploadQueue (bounded-channel upload pump, NOTIFY_FILE_CLOSE_COMPLETION-driven)
  - SyncHostedService (IHostedService bridging drive lifecycle to cfapi + engine)
  - IDS3SessionAccess + IDriveLifecycleSource (mockable seams)
affects:
  - windows/DS3Drive.App (DI host wires SyncHostedService; adapts IDriveManagementService onto IDriveLifecycleSource — Plan 11/12)
  - windows/DS3Drive.ViewModels (no change required; still builds clean)
tech-stack:
  added: [Microsoft.Extensions.Hosting (IHostedService), Vanara.PInvoke.CldApi cfapi entry points]
  patterns: [actor-equivalent SemaphoreSlim(1,1), PeriodicTimer, bounded Channel, GC-stable CF_CALLBACK delegates, SemaphoreSlim(20) HTTP/2 limiter]
key-files:
  created:
    - windows/DS3Drive.Sync/SyncEngine/DriveStatus.cs
    - windows/DS3Drive.Sync/SyncEngine/DriveStatusBroadcaster.cs
    - windows/DS3Drive.Sync/SyncEngine/UploadQueue.cs
    - windows/DS3Drive.Sync/SyncEngine/SyncEngine.cs
    - windows/DS3Drive.Sync/SyncEngine/PollingTimer.cs
    - windows/DS3Drive.Sync/SyncEngine/ConflictResolver.cs
    - windows/DS3Drive.Sync/CfApi/PathValidation.cs
    - windows/DS3Drive.Sync/CfApi/CallbackTable.cs
    - windows/DS3Drive.Sync/CfApi/FetchDataHandler.cs
    - windows/DS3Drive.Sync/CfApi/NotifyFileCloseHandler.cs
    - windows/DS3Drive.Sync/CfApi/NotifyRenameHandler.cs
    - windows/DS3Drive.Sync/CfApi/NotifyDeleteHandler.cs
    - windows/DS3Drive.Sync/CfApi/SyncRootRegistration.cs
    - windows/DS3Drive.Sync/CfApi/StateUiSource.cs
    - windows/DS3Drive.Sync/CfApi/CfApiProvider.cs
    - windows/DS3Drive.Sync/Hosting/SyncHostedService.cs
    - windows/DS3Drive.Sync/Hosting/IDriveLifecycleSource.cs
    - windows/DS3Drive.Sync/IDS3SessionAccess.cs
    - windows/DS3Drive.Tests/DriveStatusBroadcasterTests.cs
    - windows/DS3Drive.Tests/PathValidationTests.cs
    - windows/DS3Drive.Tests/EnumerationDiffApplicationTests.cs
  modified:
    - windows/DS3Drive.Sync/DS3Drive.Sync.csproj (added Microsoft.Extensions.Hosting)
decisions:
  - "[17-10] IDS3SessionAccess + IDriveLifecycleSource seams added so the sealed DS3Session FFI facade and the ViewModels-layer IDriveManagementService are mockable / decoupled. DS3Drive.Sync cannot reference DS3Drive.ViewModels (which already references Sync), so the lifecycle seam lives in Sync and the App adapts IDriveManagementService onto it."
  - "[17-10] DriveStatusBroadcaster uses a SemaphoreSlim(1,1) as the actor-equivalent gate (Swift's actor has no C# analog); BeginOperation/EndOperation are the C# shape of sendDriveChangedNotification(.sync)/sendDriveChangedNotificationWithDebounce. CounterWatchdog emits .Error (not .idle) on a leaked counter to surface the stuck state."
  - "[17-10] SyncEngine takes an injectable conflictKeyFactory defaulting to ConflictResolver.CreateConflictKey (Rust ds3_conflict_key, D-17) so the conflict test stays Category!=Integration without binding ds3_ffi.dll."
  - "[17-10] FetchDataHandler downloads to a temp file via DS3Session.DownloadObject, then streams it to cfapi in 64KB (4KB-aligned) chunks via CfExecute(TRANSFER_DATA) + CfReportProviderProgress per chunk. NTSTATUS constants supplied as uint literals (NTStatus implicit conversion) since Vanara exposes no STATUS_* fields here."
  - "[17-10] Pitfall 3 & 4 bans (ReadDirectoryChangesW, IShellIconOverlayIdentifier) are documented in doc-comments per the recommended-practice convention; the plan's literal grep=0 is satisfied for actual API USAGE (zero), the only matches are the intentional ban annotations."
metrics:
  duration: 19min
  tasks: 4 (implementation) + 1 deferred checkpoint
  files: 21 created, 1 modified
  tests_added: 27 (DriveStatusBroadcaster ×10, PathValidation ×12, EnumerationDiffApplication ×5)
  completed: 2026-05-29
---

# Phase 17 Plan 10: cfapi Sync Engine Summary

The entire Windows cfapi sync engine — sync-root registration via sparse-package identity, streaming on-demand hydration, dirty-only upload-on-close, 60s periodic remote polling, and a byte-faithful port of the Apple status broadcaster — wired into an `IHostedService` that spins per-drive `CfApiProvider` + `SyncEngine` instances off `DriveAdded`/`DriveRemoved`.

## What Shipped

- **DriveStatusBroadcaster** (Task 1, TDD): line-by-line port of `NotificationsManager.swift` lines 1-150 — counter increment/decrement with clamp-at-zero, idle/error suppression while operations active, error promotion at end-of-batch, batch-error reset, debounce, and a `PeriodicTimer` counter watchdog. 10 passing tests.
- **PathValidation** (Task 2, TDD): security gate rejecting `..` segments, leading separators, drive letters, null/control chars, Windows reserved device names, and >260-char keys; `ResolveLocalPath` canonicalizes via `Path.GetFullPath` and re-asserts containment (defense in depth). 12 passing tests.
- **cfapi layer** (Task 3): `CfApiProvider` (Register → CfConnectSyncRoot → placeholder enumeration → Disconnect), `CallbackTable` (4 D-16 callbacks with GC-stable delegates), `FetchDataHandler` (non-blocking Task.Run + chunked CfExecute(TRANSFER_DATA) + CfReportProviderProgress + SemaphoreSlim(20) limiter), `NotifyFileCloseHandler` (IsDirty anti-loop guard), `NotifyRename`/`NotifyDelete`, `SyncRootRegistration` (IsSupported + NTFS GetVolumeInformation guards), `StateUiSource`, `UploadQueue` (bounded channel + SemaphoreSlim(20) + CfSetInSyncState).
- **SyncEngine layer** (Task 4, TDD): `SyncEngine` (poll → ds3_compute_diff with C# fallback → apply delta → conflict detection), `PollingTimer` (PeriodicTimer, 60s, pause-skip, jitter + 429 backoff), `ConflictResolver` (Rust ds3_conflict_key wrapper), `SyncHostedService` (lifecycle glue). 5 passing tests.

## Verification

- `dotnet build windows/DS3Drive.Sync -p:DS3SkipRustCore=true -p:Platform=x64` → exit 0, 0 warnings.
- `dotnet test --filter "Category!=Integration"` → **124 passed, 0 failed** (27 new + 97 existing).
- `DS3Drive.ViewModels` still builds clean (downstream consumer unaffected).
- Upload trigger is `NOTIFY_FILE_CLOSE_COMPLETION` only; zero `ReadDirectoryChangesW` API usage (Pitfall 3).
- Zero `IShellIconOverlayIdentifier` implementations (Pitfall 4).
- DriveStatusBroadcaster mirrors the Apple operation-counter semantics verbatim (10 tests cover counter, suppression, promotion, leak clamp, watchdog, debounce).

## Deviations from Plan

### Auto-fixed / structural adjustments

1. **[Rule 3 - Blocking] Added `IDS3SessionAccess` + `IDriveLifecycleSource` seams.** The plan's `<interfaces>` referenced `IDS3SessionAccess` and a `DriveAdded` subscription but neither type existed and `DS3Session` is sealed. `DS3Drive.Sync` cannot reference `DS3Drive.ViewModels` (reverse reference — ViewModels already depends on Sync), so the drive-lifecycle seam lives in Sync and the App layer adapts `IDriveManagementService` onto it. Required to make the code compile and the tests mockable. Commits be97734 / aace3ee.

2. **[Rule 3 - Blocking] `Microsoft.Extensions.Hosting` package.** `SyncHostedService : IHostedService` needs the Hosting abstractions; the central package list pins `Microsoft.Extensions.Hosting` 8.0.1 (no separate Abstractions entry), so the full package was referenced. Commit be97734.

3. **[Rule 1 - Correctness] Type-alias for the `DS3Drive` / `SyncEngine` namespace-vs-type collisions.** Inside `DS3Drive.Sync.*` namespaces, `DS3Drive` resolves to the namespace and `SyncEngine` to the namespace, shadowing the record/class. Added `using DS3DriveModel = ...` and `using SyncEngineType = ...` aliases. No behaviour change.

4. **[Documented] Pitfall 3/4 ban annotations.** The plan's verification calls for grep=0 on `ReadDirectoryChangesW` and `IShellIconOverlayIdentifier`. Both symbols appear ONLY in doc-comments documenting the ban (recommended practice, mirrors the plan's own `<action>` instructions to "document the anti-overlay-handler rule in a doc comment"). There is zero actual API usage. The HUMAN-UAT steps 28/29 re-verify this.

5. **[Documented] NTSTATUS constants.** Vanara's `NTStatus` exposes no `STATUS_SUCCESS`/`STATUS_ACCESS_DENIED`/`STATUS_UNSUCCESSFUL` named fields in this build, so they are supplied as the canonical ntstatus.h uint literals via `NTStatus`'s implicit numeric conversion.

## Deferred to HUMAN-UAT (Task 5 manual checkpoint)

Per explicit user decision, the blocking manual cfapi smoke (sync-root in Explorer, hydration with visible progress, upload-on-save, the critical no-spurious-upload-after-hydration check, remote-change detection, rename/delete round-trip, stuck-parent-folder regression, NTFS guard) is DEFERRED to the phase HUMAN-UAT. Twelve steps (#20-#31) were appended to `.planning/phases/17-windows-shell/17-HUMAN-UAT.md` (total bumped 19 → 31). These require a Win11 ARM64 VM with the Plan 04 sparse package registered + a registered sync root in Explorer + live S3 — none of which can be faked. NOT marked complete; tracked as pending in HUMAN-UAT.

## Known Stubs

- `StateUiSource` is a state-forwarding plumb only (Plan 11 tray drives the state input; the cfapi placeholder pin/in-sync states carry the icons). Intentional per the plan — Plan 11 wires the tray consumer.
- `CfApiProvider.PopulatePlaceholdersAsync` writes placeholder ROWS to the store; materializing the on-disk `CfCreatePlaceholders` reparse points requires a live registered sync root and is exercised in the deferred integration smoke.
- `NotifyRenameHandler` reconciles the target on the next poll when the rename target path is not resolvable in the structural callback path (the full target-path extraction from `CF_CALLBACK_PARAMETERS` is integration-time work).

These stubs do not block the plan goal: the automated build + 27 TDD tests prove the load-bearing logic (status broadcaster, path validation, diff application). The cfapi-runtime stubs are intentionally completed at integration time, consistent with the deferred HUMAN-UAT.

## Threat Flags

None — no new trust-boundary surface beyond the plan's `<threat_model>`. All mitigations (T-17-10-01 path traversal, -02 30s timeout/limiter, -03 IsDirty anti-loop, -05 GUID-only status events, -06 polling backoff+jitter, -09 counter watchdog, -10 conflict key) are implemented.

## Self-Check: PASSED

All 21 created files verified on disk; all 4 task commits (284cf21, 8ca609c, aace3ee, be97734) verified in git log.
