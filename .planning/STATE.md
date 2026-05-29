---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: macOS App
status: executing
stopped_at: Completed 17-03-PLAN.md
last_updated: "2026-05-29T13:35:14.446Z"
last_activity: 2026-05-29
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 26
  completed_plans: 16
  percent: 62
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
Plan: 4 of 12
Status: Ready to execute
Last activity: 2026-05-29

```
Milestone v2.0.0: [█░░░░░░░░░] 0/4 phases complete (Phase 17: 3/12 plans)
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

### Decisions

- [v2.0.0 Roadmap]: Rust core as shared library (ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi) consumed via UniFFI (Swift) and csbindgen (C#)
- [v2.0.0 Roadmap]: Phase 16 and 17 can execute in parallel after Phase 15 completes -- Apple swap and Windows shell are independent
- [v2.0.0 Roadmap]: FileProvider extension stays Swift forever -- only DS3Lib internals behind DS3S3ClientProtocol are swapped to Rust
- [v2.0.0 Roadmap]: cfapi upload trigger is NOTIFY_FILE_CLOSE_COMPLETION exclusively (never ReadDirectoryChangesW) to avoid spurious re-upload loops
- [Phase ?]: [17-02] H.NotifyIcon.WinUI pinned to 2.3.2 (not 2.4.1) — 2.4.1 is net10-only, incompatible with .NET 8 LTS TFM
- [Phase ?]: [17-02] Windows native DLL build requires MSVC C++ workload — blocked on dev machine, deferred to windows-latest CI (plan 03)
- [17-03]: windows-build.yml stages the script-built ds3_ffi.dll then builds with DS3SkipRustCore=true, so cargo runs exactly once per CI job (the DS3Drive.Core BuildRustCore MSBuild target would otherwise re-invoke it)
- [17-03]: Integration tests gated by [Trait("Category","Integration")] + RequiresCredentialsAttribute auto-skip; CI Category!=Integration filter keeps CUBBIT_TEST_* out of untrusted PR runs

### Blockers

yet.

- [17-02] Dev machine lacks MSVC C++ build tools workload — cargo cannot link *-windows-msvc targets (Git's GNU link.exe shadows MSVC linker). Native ds3_ffi.dll build blocked locally; managed scaffold builds clean. Install 'Desktop development with C++' workload to unblock; CI (windows-latest) unaffected.

## Session Continuity

Last session: 2026-05-29T13:35:07.005Z
Stopped at: Completed 17-03-PLAN.md
Resume file: None
