---
phase: 17-windows-shell
plan: "03"
subsystem: windows-ci-test-harness
tags: [ci, test-harness, fixtures, smoke-test]
requires:
  - "core/scripts/build-dll-windows.ps1 (Plan 01)"
  - "windows/DS3Drive.sln + DS3Drive.Tests.csproj (Plan 02)"
  - "windows/DS3Drive.Core/runtimes layout (Plan 02)"
provides:
  - ".github/workflows/windows-build.yml — Windows CI pipeline (x64 build + non-integration tests)"
  - "windows/DS3Drive.Tests/xunit.runner.json — serialized test execution config"
  - "windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs — env-var integration fixture + RequiresCredentials gate"
  - "windows/manual-smoke-D-33.md — phase sign-off smoke checklist"
affects:
  - "All subsequent Phase 17 plans whose <verify> blocks run dotnet test"
tech-stack:
  added: []
  patterns:
    - "GitHub Actions windows-latest x64-only CI; ARM64 reserved for manual smoke (D-32)"
    - "xUnit Category=Integration trait + RequiresCredentialsAttribute auto-skip when creds absent"
    - "Build DLL via script then DS3SkipRustCore=true to keep cargo single-invocation in CI"
key-files:
  created:
    - ".github/workflows/windows-build.yml"
    - "windows/DS3Drive.Tests/xunit.runner.json"
    - "windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs"
    - "windows/manual-smoke-D-33.md"
  modified:
    - "windows/DS3Drive.Tests/DS3Drive.Tests.csproj"
decisions:
  - "CI stages the script-built DLL into DS3Drive.Core/runtimes and builds with DS3SkipRustCore=true so cargo runs exactly once per job (the MSBuild BuildRustCore target would otherwise re-invoke it)."
  - "windows-build.yml triggers on push to gsd/phase-17-windows-shell + main and PRs to main, scoped to windows/**, core/**, and the workflow itself."
metrics:
  duration: 3min
  completed: 2026-05-29
---

# Phase 17 Plan 03: Windows CI + Test Harness + Smoke Checklist Summary

Stood up the Windows shell's testing scaffolds: a `windows-build.yml` CI pipeline that builds the Rust `ds3_ffi.dll` (x64) + the .NET solution and runs non-integration tests; an xUnit runner config that serializes test execution for cfapi safety; an env-var-backed `CubbitCredentials` fixture with an auto-skipping `RequiresCredentials` attribute; and the D-33 manual smoke checklist that gates phase sign-off.

## What Was Built

### Task 1 — `windows-build.yml` CI pipeline (commit 6e670ba)
- Triggers: push to `gsd/phase-17-windows-shell` + `main`, PRs to `main`, scoped to `windows/**`, `core/**`, and the workflow file.
- Single `build` job on `windows-latest`: checkout (LFS), setup-dotnet 8.0.x, rust-toolchain with `x86_64-pc-windows-msvc`, cargo cache, run `build-dll-windows.ps1 -BuildProfile release`, stage the DLL into `DS3Drive.Core/runtimes/win-x64/native`, restore, `dotnet build` Release with `DS3SkipRustCore=true`, `dotnet test --filter "Category!=Integration"`, upload `TestResults` on failure.
- `concurrency` group cancels superseded runs; `permissions: contents: read` (least privilege). Header comment cites D-32 (ARM64 VM is for manual smoke; CI is x64 only).

### Task 2 — xUnit runner config + CubbitCredentials fixture (commit 5a416de)
- `xunit.runner.json`: `parallelizeAssembly=false`, `parallelizeTestCollections=false`, `maxParallelThreads=1`, `longRunningTestSeconds=60` — cfapi-style tests cannot interleave (VALIDATION Wave 0).
- Wired `xunit.runner.json` into `DS3Drive.Tests.csproj` with `CopyToOutputDirectory=PreserveNewest` (was not previously referenced) — verified it lands in `bin/`.
- `CubbitCredentials.cs`: matches the `<interfaces>` contract (`Email`, `Password`, `Tenant?`, `CoordinatorUrl`, `IsAvailable`, `FromEnvironment()`). Reads `CUBBIT_TEST_EMAIL/PASSWORD/TENANT/COORDINATOR_URL`; coordinator defaults to `https://api.eu00wi.cubbit.services`; `IsAvailable` true iff email+password non-empty. Adds `[CollectionDefinition("Integration")]` and `RequiresCredentialsAttribute : FactAttribute` that sets `Skip` when creds are absent. Never logs credential values (T-17-03-01).

### Task 3 — `manual-smoke-D-33.md` checklist (commit 9e61b44)
- Sections: Environment (Windows 11 ARM64 VM, NTFS), Pre-flight (6 steps incl. NTFS check, sparse-package + Credential Manager reset), Smoke Matrix (19 numbered items), Sign-off (engineer + second reviewer).
- Every requirement WIN-01 … WIN-09 appears with a Requirement-IDs column; cross-references RESEARCH pitfalls 1–8 (notably Pitfall 3 hydration loop for the open-then-close zero-PUT check). Mirrors the macOS APPLE-05 / D-24 structure.

## Verification

| Task | Verify | Result |
|------|--------|--------|
| 1 | grep windows-latest / x86_64-pc-windows-msvc / build-dll-windows.ps1 / dotnet test / Category!=Integration / lfs / concurrency | all ≥ required |
| 2 | both files exist; parallelizeAssembly+parallelizeTestCollections false; 7 env-var hits; class+attr present; default coordinator present; **Tests project builds clean (managed-only)**; runner.json copied to bin | PASS |
| 3 | 9 distinct WIN-0X ids; 26 `[ ]`; NTFS; 11 Pitfall refs; ARM64; hydration check; sign-off | PASS |

The `DS3Drive.Tests` project was compiled locally (`dotnet build -p:DS3SkipRustCore=true`) → Build succeeded, 0 warnings/errors — confirms `CubbitCredentials.cs` and the csproj edit are valid C#.

## Deviations from Plan

### Auto-fixed / adjusted

**1. [Rule 3 - Blocking] DLL artifact name + build-script parameter corrected**
- **Found during:** Task 1.
- **Issue:** The plan's `<interfaces>` referenced `ds3_core.dll` and `build-dll-windows.ps1 -profile release`. The actual Plan-01 artifact is **`ds3_ffi.dll`** (RESEARCH Pitfall 6) and the script parameter is **`-BuildProfile`** (it deliberately avoids `-Profile` to not shadow PowerShell's `$PROFILE`).
- **Fix:** Workflow invokes `-BuildProfile release` and copies `ds3_ffi.dll` from the script's output (`core/out/windows/runtimes/win-x64/native/`) into `DS3Drive.Core/runtimes/win-x64/native/`.

**2. [Rule 3 - Blocking] Single cargo invocation per CI job**
- **Found during:** Task 1.
- **Issue:** `DS3Drive.Core` has an MSBuild `BuildRustCore` target (`BeforeTargets="BeforeBuild"`) that re-invokes cargo on every build. Running the build script *and* a plain `dotnet build` would build the Rust core twice (and the second invocation could fail differently).
- **Fix:** `dotnet build` is passed `/p:DS3SkipRustCore=true` (the target's documented escape hatch) so the staged script-built DLL is used and cargo runs exactly once.

**3. [Rule 2 - Robustness] xunit.runner.json wired into csproj**
- The plan said to add the `<None Update>` copy entry "or verify 17-02 already covered it." It did **not** — the Tests csproj had no reference. Added the `CopyToOutputDirectory=PreserveNewest` entry so the runner config is actually honored.

## Deferred to CI

- **YAML lint of `windows-build.yml`** — the plan's acceptance step `python3 -c "import yaml; ..."` could not run: this Windows-on-ARM64 box has no Python/Ruby/`powershell-yaml` available (only the Microsoft Store python stub). Structural checks passed (no tabs; correct top-level keys `name/on/concurrency/permissions/jobs`; mirrors the proven `build.yml`). Full YAML validation occurs on the first push to GitHub Actions.
- **Actual CI run (Rust DLL build + dotnet test on windows-latest)** — local native build is blocked by the missing MSVC C++ Build Tools workload (recorded blocker from Plan 17-02). The pipeline targets `windows-latest`, which has MSVC; it will execute on the next push. Not fabricated as locally green.

## Known Stubs

None. All four artifacts are complete and final for their purpose; no placeholder data or unwired surfaces.

## Self-Check: PASSED
- FOUND: .github/workflows/windows-build.yml
- FOUND: windows/DS3Drive.Tests/xunit.runner.json
- FOUND: windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs
- FOUND: windows/manual-smoke-D-33.md
- FOUND commit: 6e670ba
- FOUND commit: 5a416de
- FOUND commit: 9e61b44
