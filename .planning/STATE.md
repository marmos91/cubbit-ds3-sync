---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: macOS App
status: executing
stopped_at: Completed 17-05-PLAN.md
last_updated: "2026-05-29T14:24:10.032Z"
last_activity: 2026-05-29
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 26
  completed_plans: 19
  percent: 25
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-26)

**Core value:** Files sync reliably and transparently between Mac, iPhone, iPad, Windows PC and Cubbit DS3, with zero friction on every platform.
**Current focus:** Phase 17 — windows-shell

**v2.0.0 phase shape:**

- Phase 15 -- Rust Core + FFI Foundation (Cargo workspace, 6 crates, UniFFI XCFramework, csbindgen C# bindings, integration tests). No app changes.
- Phase 16 -- Apple Incremental Swap (DS3S3Client + auth + SDK internals replaced with Rust via UniFFI; Soto/CryptoKit removed from DS3Lib). FileProvider untouched.
- Phase 17 -- Windows Shell (WinUI 3 tray app, cfapi Cloud Filter, Explorer sidebar, on-demand hydration, upload, remote sync, MSI installer).
- Phase 18 -- Polish + Beta Hardening (cross-FFI logging, error mapping, DPAPI, multi-drive, auto-update, ARM64 Windows, tray flyout, conflict resolution).

## Current Position

Phase: 17 (windows-shell) — EXECUTING
Plan: 7 of 12
Status: Ready to execute
Last activity: 2026-05-29

```
Milestone v2.0.0: [█░░░░░░░░░] 0/4 phases complete (Phase 17: 6/12 plans)
```

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: --
- Total execution time: --

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

## Accumulated Context

| Phase 17 P02 | 15min | 3 tasks | 12 files |
| Phase 17 P03 | 3min | 3 tasks | 5 files |
| Phase 17 P04 | 6min | 2 tasks | 4 files |
| Phase 17 P05 | 17min | 3 tasks | 17 files |
| Phase 17 P06 | 8min | 3 tasks | 9 files |

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

### Blockers

yet.

- [17-02] Dev machine lacks MSVC C++ build tools workload — cargo cannot link *-windows-msvc targets (Git's GNU link.exe shadows MSVC linker). Native ds3_ffi.dll build blocked locally; managed scaffold builds clean. Install 'Desktop development with C++' workload to unblock; CI (windows-latest) unaffected.

## Session Continuity

Last session: 2026-05-29T14:24:10.023Z
Stopped at: Completed 17-05-PLAN.md
Resume file: None
