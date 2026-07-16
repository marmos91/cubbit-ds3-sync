---
gsd_state_version: 1.0
milestone: v2.0.0
milestone_name: Cross-Platform Rewrite
status: in-progress
stopped_at: Phase 17.1 UAT-verified (end-to-end sync + hydration working on native ARM64); roadmap extended with Windows productionization 17.2-17.6
last_updated: "2026-06-02T00:00:00.000Z"
last_activity: 2026-06-02
progress:
  total_phases: 5
  completed_phases: 3
  total_plans: 29
  completed_plans: 28
  percent: 60
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-26)

**Core value:** Files sync reliably and transparently between Mac, iPhone, iPad, Windows PC and Cubbit DS3, with zero friction on every platform.
**Current focus:** Phase 17.1 complete — Windows end-to-end sync + on-demand hydration UAT-verified on native ARM64. Next: Windows productionization (17.2-17.6).

**v2.0.0 phase shape:**

- Phase 15 -- Rust Core + FFI Foundation (Cargo workspace, 6 crates, UniFFI XCFramework, csbindgen C# bindings, integration tests). No app changes.
- Phase 16 -- Apple Incremental Swap (DS3S3Client + auth + SDK internals replaced with Rust via UniFFI; Soto/CryptoKit removed from DS3Lib). FileProvider untouched.
- Phase 17 -- Windows Shell (WinUI 3 tray app, cfapi Cloud Filter, Explorer sidebar, on-demand hydration, upload, remote sync, MSI installer).
- Phase 17.1 -- Windows S3-Client FFI Wiring + Sync Enablement (mint DS3S3Client across FFI, route cfapi engine through it; bidirectional sync working). **UAT-verified.**
- Phase 17.2 -- Windows Thumbnails (real Explorer thumbnails from the shared `.thumbnails/` prefix, no full-file hydration).
- Phase 17.3 -- Windows Enumeration Performance & UX (incremental paged enumeration at scale, idempotent placeholders, visible progress).
- Phase 17.4 -- Windows UI Polish across all windows (design-token consistency, theme/DPI correctness, empty/loading/error states).
- Phase 17.5 -- Windows Feature Completeness (drive stats, full settings, pause/resume, recent files, transfer speed, notifications — macOS parity).
- Phase 17.6 -- Windows Installer, Releases & CI (signed x64 + ARM64 installer, tag-triggered release pipeline, upgrade-preserving, auto-update).
- Phase 18 -- Polish + Beta Hardening (cross-FFI logging, error mapping, DPAPI, multi-drive, auto-update, ARM64 Windows, tray flyout, conflict resolution).

## Current Position

Phase: 17.3 Windows Enumeration Performance & UX — ALL 4 waves COMPLETE (Wave 1 D-01, Wave 2 D-02/D-03, Wave 3 D-04/D-05/D-06, Wave 4 integration tests + manual smoke + close-out docs). 5/5 plans. Phase completion pends live integration (CI workflow_dispatch) + manual cfapi/Explorer smoke sign-off, then /gsd:verify-work.
Plan: 17.3 CONTEXT + RESEARCH + 5 numbered plans written; scope signed off 2026-07-07. Wave 0 (local build) done. Waves 1–4 implemented + unit-verified.
Status: Wave 1 = full-pagination poll (ListLevel). Wave 2 = per-page streaming (EnumerateLevelPages primitive; MaterializeAsync creates per page; FetchPlaceholdersHandler multi-batch TRANSFER_PLACEHOLDERS, DISABLE_ON_DEMAND_POPULATION only on final batch) + D-03 on-disk ghost removal. Wave 3 = D-04 aggregate progress (DriveEnumerationProgress record + EnumerationPhase, no key/file-name per T-17-10-05; additive DriveStatusBroadcaster.ProgressChanged + ReportEnumerationProgress, gate-free; emitted per page from FetchPlaceholdersHandler/MaterializeAsync + one-shot from poll + throttled BytesHydrated from FetchDataHandler; TrayDriveRowViewModel.UpdateEnumerationProgress/EnumerationSummary — App forwarder+XAML deferred to 17.5), D-05 BucketListingLimiter (per-bucket SemaphoreSlim, maxConcurrent=4, macOS parity; gates the list call inside EnumerateLevelPages, permit not held across yield), D-06 sync anchor (SyncAnchorHash v1 SHA-256 port + migration 003 prefix_anchors + PrefixAnchorStore; PollOnceAsync short-circuits diff/apply when anchor unchanged, stores anchor only after reconcile; wired via SyncHostedService + DI). 173 non-Integration tests green, real Rust FFI diff. NOTE: native cfapi multi-batch + hydration progress verified only via injected seams — needs manual/app smoke. Next: Wave 4 (Plan 05, integration/idempotency tests + manual smoke + verification/docs).
Last activity: 2026-07-08
Resume from: .planning/phases/17.3-windows-enumeration-performance-ux/17.3-HANDOFF.md

```
Milestone v2.0.0: Phase 17.1 complete (sync + hydration working) — Windows productionization 17.2-17.6 queued
```

## Performance Metrics

**Velocity:**

- Total plans completed: 6
- Average duration: --
- Total execution time: --

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 17.1 | 3 | - | - |

## Accumulated Context

| Phase 17 P02 | 15min | 3 tasks | 12 files |
| Phase 17 P03 | 3min | 3 tasks | 5 files |
| Phase 17 P04 | 6min | 2 tasks | 4 files |
| Phase 17 P05 | 17min | 3 tasks | 17 files |
| Phase 17 P06 | 8min | 3 tasks | 9 files |
| Phase 17 P07 | 12min | 1 task | 4 files |
| Phase 17 P09 | 27min | 2 tasks | 31 files |
| Phase 17 P10 | 19min | 4 tasks | 22 files |
| Phase 17 P11 | continuation | 3 tasks | 28 files |
| Phase 17 P12 | 8min | 2 tasks | 12 files |
| Phase 17.1 P01 | 22min | 2 tasks | 5 files |
| Phase 17.1 P02 | 5min | 2 tasks | 4 files |
| Phase 17.1 P03 | 18min | 2 tasks | 10 files |

### Decisions

- [v2.0.0 Roadmap]: Rust core as shared library (ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi) consumed via UniFFI (Swift) and csbindgen (C#)
- [v2.0.0 Roadmap]: Phase 16 and 17 can execute in parallel after Phase 15 completes -- Apple swap and Windows shell are independent
- [v2.0.0 Roadmap]: FileProvider extension stays Swift forever -- only DS3Lib internals behind DS3S3ClientProtocol are swapped to Rust
- [v2.0.0 Roadmap]: cfapi upload trigger is NOTIFY_FILE_CLOSE_COMPLETION exclusively (never ReadDirectoryChangesW) to avoid spurious re-upload loops
- [Phase ?]: [17-02] H.NotifyIcon.WinUI pinned to 2.3.2 (not 2.4.1) — 2.4.1 is net10-only, incompatible with .NET 8 LTS TFM
- [Phase ?]: [17-02] Windows native DLL build requires MSVC C++ workload — blocked on dev machine, deferred to windows-latest CI (plan 03)
- [17-03]: windows-build.yml stages the script-built ds3_ffi.dll then builds with DS3SkipRustCore=true, so cargo runs exactly once per CI job (the DS3Drive.Core BuildRustCore MSBuild target would otherwise re-invoke it)
- [17-03]: Integration tests gated by [Trait("Category","Integration")] + RequiresCredentialsAttribute auto-skip; CI Category!=Integration filter keeps CUBBIT_TEST_* out of untrusted PR runs
- [Phase ?]: [17-04] Sparse identity package (Cubbit.DS3Drive) grants the unpackaged WinUI 3 exe package identity; MSI (Plan 12) packs build-sparse.ps1 output then Add-AppxPackage -ExternalLocation so cfapi StorageProviderSyncRootManager.Register (Plan 10) succeeds
- [Phase ?]: [17-04] Sparse manifest Publisher + Version are placeholders: Publisher must equal Authenticode cert subject byte-for-byte (RESEARCH Pitfall 1, CONTEXT D-29); Version (2.0.0.0) must bump every MSI release (Pitfall 7)
- [Phase ?]: [17-04] MakeAppx/SignTool absent locally (no Windows SDK, per 17-02 MSVC blocker); build-sparse.ps1 pack+sign deferred to CI/install-time. Manifests validated as well-formed XML, script as parseable PowerShell
- [17-05]: DS3Native.cs is a hand-mirror of the committed Phase 15 csbindgen output (core/ds3-ffi/out/NativeMethods.g.cs); opaque handles surfaced as IntPtr for managed lifetime via Interlocked guards. Regeneration deferred to CI (MSVC linker blocker)
- [17-05]: CredentialStore target name format is 'Cubbit DS3 Drive — <accountId> — <credentialKey>' (em-dash U+2014, per-key suffix) so refreshToken/secretKey per account don't collide — supersedes CONTEXT D-12's shorter account-only form
- [17-05]: Managed P/Invoke compiles + unit-tests without ds3_ffi.dll (DllImport binds at runtime); live native-calling tests gated Category=Integration, deferred to windows-latest CI
- [17-06]: schema_version table is created by migration 001 itself; SchemaMigrator must NOT pre-create it (would conflict with the 001 CREATE TABLE) — applied versions read defensively via a sqlite_master probe
- [17-06]: sync.db uses private cache + WAL (not shared cache); WAL alone gives the concurrent cfapi-reader/engine-writer behaviour D-11 needs for a file-backed store
- [17-06]: PlaceholderStore is fully parameterized (SqliteParameter, STRIDE T-17-06-01); EnumerationDiff.cs is the unit-testable reference while production uses Rust ds3_compute_diff (D-17)
- [17-07]: ds3_set_log_callback ABI is a C# function pointer (delegate* unmanaged[Cdecl]), not a marshaled delegate — RustLogBridge uses an [UnmanagedCallersOnly] static target (&OnNativeCallback, GC-stable, no pinning); Shutdown clears via ds3_clear_log_callback (function-ptr ABI can't pass managed null) — supersedes RESEARCH §POL-01 marshaled-delegate sketch
- [17-07]: POL-01 log dispatch is non-blocking — Rust callback decodes + TryWrite onto bounded Channel(1024, DropOldest); dedicated drainer Task is the only EventSource writer (Pitfall 5 re-entrancy ban enforced by Test 7). RustLogBridge.CallbackRegistrar seam keeps all 7 tests Category!=Integration; real native round-trip deferred to windows-latest CI (17-02 MSVC blocker)
- [17-09]: DriveSetupViewModel + DS3SdkService + DriveManagementService + repositories live in DS3Drive.ViewModels (WinUI-free), not DS3Drive.App — referencing the WinUI App exe into the headless xUnit host crashes it (same root cause as 17-08 split). XAML pages + WizardStepIndicator stay in DS3Drive.App
- [17-09]: IDS3SessionGateway seam wraps the sealed DS3Session so the API-key reconcile tests can mock remote calls; AuthenticationService (the single session owner) implements it and is registered as the same singleton for both IAuthenticationService + IDS3SessionGateway
- [17-09]: InstallationId (Apple appUUID analog for the deterministic API-key name) persisted in a new singleton_state SQLite table (migration 002), lazily GUID-generated on first read — threat T-17-09-04
- [17-09]: DriveManagementService persistence triple (mutate → SQLite UPSERT → DriveAdded event) is byte-aligned with DS3DriveManager.swift:244-248; remove does the inverse (unregister event → DELETE → drop). 3-drive cap (D-23) enforced at the service + UI. Manual end-to-end smoke deferred to phase HUMAN-UAT (entries 10-19)
- [17-10]: IDS3SessionAccess + IDriveLifecycleSource seams added in DS3Drive.Sync — DS3Session is sealed and DS3Drive.Sync cannot reverse-reference DS3Drive.ViewModels (which already depends on Sync), so the lifecycle seam lives in Sync and the App adapts IDriveManagementService onto it
- [17-10]: DriveStatusBroadcaster ports NotificationsManager.swift verbatim using SemaphoreSlim(1,1) as the actor-equivalent gate + PeriodicTimer counter watchdog (emits .Error on leak); upload trigger is NOTIFY_FILE_CLOSE_COMPLETION-only with an IsDirty anti-loop guard (Pitfall 3); SemaphoreSlim(20) bounds both fetch + upload concurrency (HTTP/2, PATTERNS §3.5)
- [17-10]: SyncEngine.ApplyDeltaAsync takes an injectable conflictKeyFactory (default = Rust ds3_conflict_key, D-17) so the conflict test stays Category!=Integration; cfapi/Explorer/live-S3 smoke (12 steps #20-31) deferred to phase HUMAN-UAT
- [17-11]: WinUI 3 forbids {x:Bind} on a <Window> root (Window is not a FrameworkElement → CS1503 in generated Bindings). TrayFlyoutWindow is a thin Window (Acrylic backdrop + chrome removal + 360×540 AppWindow.Resize) hosting a FrameworkElement-rooted TrayFlyoutView UserControl that owns all x:Bind via a ViewModel DP — the standard WinUI 3 flyout pattern (same as TrayDriveRow/StatusPill)
- [17-11]: TrayViewModel/SettingsViewModel/RecentFilesService live in DS3Drive.ViewModels (WinUI-free) for headless xUnit testability (Plan 09/10 split); aggregate precedence Error>Syncing>Paused>Idle is the WinUI-free reducer. Recent files = global top-5 (not per-drive) for flyout compactness. Tray + Settings manual smoke deferred to phase HUMAN-UAT (#32-43)
- [Phase ?]: [17-12] MSI ProductVersion (Variables.wxi) and sparse manifest <Identity Version> synced byte-for-byte by build-msi.ps1 at build time so Add-AppxPackage never hits a same-version collision 0x80073CF9 (RESEARCH Pitfall 7)
- [Phase ?]: [17-12] WiX toolset absent on dev machine (same MSVC/SDK blocker as 17-02/17-04); WiX sources + build-msi.ps1 + windows-release.yml authored and validated (well-formed XML, parseable PS, structured YAML). Actual MSI build/sign deferred to windows-release.yml on tag; D-33 live smoke deferred to HUMAN-UAT #44-#53
- [Phase 17.1]: [17.1-01] ds3_s3_client_new omits runtime().block_on — DS3S3Client::new is synchronous (builds aws-sdk-s3 config, no I/O); only fallible step is UTF-8 decode. region via ffi_opt_str (null/0 => us-east-1, macOS parity)
- [Phase 17.1]: [17.1-01] Wave 0 integration test resolves the plan-02 DS3DriveS3Client facade by reflection (Assembly.GetType) and no-ops until it lands, so the harness compiles before the consumer (Nyquist). D-06 tests BOTH error branches: bad access key => code 3003 => DS3TransportException, not DS3S3Exception
- [Phase ?]: [17.1-02] DS3DriveS3Client : IDisposable owns one DS3S3Client handle (Create=>ds3_s3_client_new, Dispose=>Interlocked+ds3_s3_client_destroy); the 7 S3 ops re-homed off DS3Session onto this facade — structural fix for the S3 AccessViolationException (D-02). DS3Session is now auth/session-only.
- [Phase ?]: [17.1-02] DS3AccountInfo.EndpointGateway un-ignored (maps endpoint_gateway wire key); inserted as 3rd positional record param — safe since no positional new DS3AccountInfo(...) call sites exist (deser is name-based). Unblocks Plan 03 S3-client construction.
- [Phase ?]: [17.1-03] cfapi sync S3 routes through a host-built per-drive DriveS3SessionAccess wrapping one DS3DriveS3Client (creds from API-key flow + endpoint_gateway, not the session token); built at StartDriveAsync, rebuilt on credential/endpoint change, disposed LAST in StopActiveAsync (Pitfall 4)
- [Phase ?]: [17.1-03] Per-drive S3 creds via new IDriveS3CredentialProvider seam (Sync-defined, App-implemented), not by widening the 6-op IDS3SessionAccess; IDS3SessionGateway dropped ListBuckets/ListObjects + gained EndpointGateway; wizard browse re-pointed onto a per-project cached DS3DriveS3Client
- [Phase 17.1 UAT]: Hydration "corrupted/unsupported" had TWO root causes, both fixed (not network/SDK — proven: native curl 0.7s, isolated repro cold/warm/idle all <2s). (1) download throughput was coupled to the cross-FFI progress callback — `download_object` called it per ~4KB S3 frame (~1000×), so each `CfReportProviderProgress` cost serialized the transfer → ~120s + watchdog cancels. Fix: throttle progress to ≤1/100ms in `ds3-s3/transfer.rs`. (2) `FetchDataHandler` served the WHOLE file `[0,fileLen)` on every FETCH_DATA callback → concurrent overlapping transfers superseded each other (Win32 398) → partial/corrupt file. Fix: serve only the requested `RequiredFileOffset/Length` range from the shared (deduped) temp file (CloudMirror/Nextcloud model); 4KB-aligned except EOF. Once a range is acked it is marked on-disk and never re-requested, which stops the FETCH_DATA storm.

### Blockers

yet.

- [17-02] ~~Dev machine lacks MSVC C++ build tools workload — cargo cannot link *-windows-msvc targets.~~ **RESOLVED 2026-07-07** (Phase 17.3 Wave 0): installed VS 2026 `Microsoft.VisualStudio.Workload.NativeDesktop` (MSVC `link.exe`) + Rust `stable-x86_64-pc-windows-msvc`. Verified `cargo build -p ds3-ffi` links `ds3_ffi.dll` locally (5m34s, exit 0). This is an x64 (AMD64) box; the ARM64 dev VM remains for cfapi runtime smoke.

## Session Continuity

Last session: 2026-07-08
Stopped at: ALL 4 waves complete on branch gsd/phase-17.3-windows-enumeration. Wave 4 (Plan 05): EnumerationIntegrationTests (D-01 pagination / D-02 idempotency / D-03 ghost+dirty / D-06 anchor against live Cubbit, >2000-key seed) + EnumerationIntegrationFixture (Category=Integration, RequiresCredentials, self-skip); windows/manual-smoke-17.3.md (12-item cfapi/Explorer checklist); 17.3-VALIDATION.md + 17.3-05-SUMMARY.md; ROADMAP 17.3 → 5/5 In Progress. 173 non-Integration green; 7 integration tests self-skip without creds. PENDING: live integration via CI workflow_dispatch (CUBBIT_TEST_* secrets) + manual smoke sign-off (native cfapi streaming/hydration progress + App→tray forwarder/XAML, latter deferred to 17.5), then /gsd:verify-work. Waves 1–4 committed: fc8bb62 (docs), 28dbce4 (D-01), f7511fe (D-02/D-03), bbdaeb2 (D-04/D-05/D-06); Wave 4 commit pending.
Resume file: .planning/phases/17.3-windows-enumeration-performance-ux/17.3-HANDOFF.md
