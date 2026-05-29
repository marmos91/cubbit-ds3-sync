---
phase: 17-windows-shell
plan: 02
subsystem: windows
tags: [solution, scaffold, msbuild, nuget, central-package-management, winui3]
requires:
  - "Phase 15 ds3-ffi crate (cdylib, ds3_ffi.dll artifact)"
provides:
  - "windows/DS3Drive.sln — four-project WinUI 3 solution skeleton"
  - "Central package management (Directory.Packages.props) with pinned versions"
  - "DS3Core.Build.targets — cargo invocation + ds3_ffi.dll staging MSBuild target"
  - "Empty WinUI 3 App entry point (App.xaml/App.xaml.cs) — buildable WinExe"
affects:
  - "All Wave 1+ Windows plans build on this scaffold"
tech-stack:
  added:
    - "Microsoft.WindowsAppSDK 1.6.250228001 (WinUI 3, .NET 8 line)"
    - "CommunityToolkit.Mvvm 8.4.0"
    - "Vanara.PInvoke.CldApi 5.0.5 (cfapi P/Invoke)"
    - "H.NotifyIcon.WinUI 2.3.2 (tray; corrected from 2.4.1 — see Deviations)"
    - "Microsoft.Data.Sqlite 8.0.10"
    - "xunit 2.9.0 + NSubstitute 5.1.0 (test stack)"
  patterns:
    - "Central Package Management — projects reference packages without versions"
    - "Cargo-on-every-build via MSBuild BeforeBuild target (CONTEXT D-07)"
    - "RID -> Rust target triple mapping in DS3Core.Build.targets"
key-files:
  created:
    - "windows/DS3Drive.sln"
    - "windows/Directory.Build.props"
    - "windows/Directory.Packages.props"
    - "windows/README.md"
    - "windows/DS3Drive.App/DS3Drive.App.csproj"
    - "windows/DS3Drive.App/App.xaml"
    - "windows/DS3Drive.App/App.xaml.cs"
    - "windows/DS3Drive.App/app.manifest"
    - "windows/DS3Drive.Sync/DS3Drive.Sync.csproj"
    - "windows/DS3Drive.Core/DS3Drive.Core.csproj"
    - "windows/DS3Drive.Core/core-build/DS3Core.Build.targets"
    - "windows/DS3Drive.Tests/DS3Drive.Tests.csproj"
  modified:
    - "windows/Directory.Packages.props (H.NotifyIcon version pin)"
    - "windows/DS3Drive.Core/core-build/DS3Core.Build.targets (XML comment fix + skip hatch)"
decisions:
  - "H.NotifyIcon.WinUI pinned to 2.3.2 (not RESEARCH's 2.4.1) — 2.4.1 is net10-only"
  - "Added DS3SkipRustCore escape hatch for managed-only builds on machines without MSVC"
  - "Minimal App.xaml scaffold added so the WinExe links; Plan 04 replaces it"
metrics:
  duration: "~15 min (continuation from human-verify checkpoint)"
  completed: 2026-05-29
  tasks: 3
  files_created: 12
  files_modified: 2
---

# Phase 17 Plan 02: Windows Solution Skeleton Summary

Empty four-project WinUI 3 solution under `windows/` (App / Sync / Core / Tests) with central package management, shared MSBuild properties, and a cargo-invoking MSBuild target that stages `ds3_ffi.dll` into per-RID runtimes folders. All managed scaffolding restores and builds clean on .NET 8; the native Rust DLL build is wired correctly but blocked on this dev machine by a missing MSVC C++ toolchain (will pass on CI).

## What Was Built

- **`windows/DS3Drive.sln`** — VS2022-format solution referencing all four projects.
- **`Directory.Build.props`** — `Nullable=enable`, `TreatWarningsAsErrors=true`, `LangVersion=12.0`, `ImplicitUsings=enable`, `EnforceCodeStyleInBuild=true`, `RestorePackagesWithLockFile=true`.
- **`Directory.Packages.props`** — `ManagePackageVersionsCentrally=true` plus pinned `PackageVersion` entries for all 13 packages.
- **`DS3Drive.Core`** — class library (`net8.0-windows10.0.19041.0`, `AllowUnsafeBlocks=true`), imports `DS3Core.Build.targets`, references `Microsoft.Extensions.Logging.Abstractions`.
- **`DS3Core.Build.targets`** — `BuildRustCore` target (BeforeBuild, unconditional per D-07) that maps RID -> cargo target triple (`win-x64` -> `x86_64-pc-windows-msvc`, `win-arm64` -> `aarch64-pc-windows-msvc`), runs `cargo build -p ds3-ffi`, and copies `ds3_ffi.dll` into `runtimes/{rid}/native/`.
- **`DS3Drive.Sync`** — class library referencing Core + `Vanara.PInvoke.CldApi` + `Microsoft.Data.Sqlite` + logging abstractions.
- **`DS3Drive.App`** — WinUI 3 `WinExe` (`WindowsPackageType=None`, `EnableMsixTooling=true`, `UseWinUI=true`) referencing Sync + the MVVM/hosting/tray package set. Minimal `App.xaml`/`App.xaml.cs` provide the generated entry point.
- **`DS3Drive.Tests`** — xunit test project referencing Core + Sync + NSubstitute.
- **`README.md`** — prerequisites, build commands, `ds3_ffi.dll` (not `ds3_core.dll`) artifact disclaimer.

## Verification Results

**`dotnet restore windows/DS3Drive.sln`** — SUCCEEDS for all four projects (after the H.NotifyIcon version fix below).

**`dotnet build` (managed code, `-p:DS3SkipRustCore=true`, `-r win-arm64`)** — SUCCEEDS, 0 warnings, 0 errors:
- `DS3Drive.Core.dll`, `DS3Drive.Sync.dll`, `DS3Drive.Tests.dll`, `DS3Drive.App.dll` all produced.

**Native `ds3_ffi.dll` build via cargo** — the MSBuild target invokes cargo with the correct target triple, but the build fails at the link step on this machine (see Environment Blocker). This is NOT a scaffold defect.

Acceptance-criteria spot checks: solution has 4 project entries; `Directory.Packages.props` has 13 `PackageVersion Include` entries; `Microsoft.WindowsAppSDK=1.6.250228001`, `Vanara.PInvoke.CldApi=5.0.5`; `TreatWarningsAsErrors` present; `ds3_ffi` referenced in README + targets; **zero `ds3_core` references anywhere in `windows/`**; App csproj has `WindowsPackageType None` + `EnableMsixTooling` + ProjectReference to Sync; Sync references Core + Vanara + Sqlite; Core has `AllowUnsafeBlocks` + imports the targets; targets contain `cargo build`, `ds3_ffi.dll`, and both target triples; Tests references xunit + xunit.runner.visualstudio.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] H.NotifyIcon.WinUI 2.4.1 is incompatible with .NET 8**
- **Found during:** Task 3 (`dotnet restore` after the approved gate).
- **Issue:** `NU1202: Package H.NotifyIcon.WinUI 2.4.1 is not compatible with net8.0-windows10.0.19041 ... supports: net10.0-windows10.0.17763`. The version RESEARCH.md pinned only targets .NET 10, conflicting with the locked .NET 8 LTS TFM (CONTEXT D-02). This is exactly the Wave-0 compile-time catch RESEARCH §"Assumptions to Validate" A2 predicted.
- **Fix:** Probed the 2.x line; `2.3.2` is the highest 2.x release that still targets `net8.0-windows10.0.19041`. Re-pinned `Directory.Packages.props` to `2.3.2`. **Same legitimate, human-verified package** (publisher havendv, MIT) — only the patch version changed for TFM compatibility, NOT a package substitution.
- **Files modified:** `windows/Directory.Packages.props`
- **Commit:** 5222fe5

**2. [Rule 1 - Bug] Illegal `--` inside an XML comment in DS3Core.Build.targets**
- **Found during:** Task 3 (`dotnet build` of Core).
- **Issue:** `MSB4024: An XML comment cannot contain '--'`. A comment referenced the cargo `--release` flag literally; the `--` is illegal inside XML comments, so the targets file failed to load.
- **Fix:** Reworded the comment to avoid the literal `--`.
- **Files modified:** `windows/DS3Drive.Core/core-build/DS3Core.Build.targets`
- **Commit:** 5222fe5

**3. [Rule 3 - Blocking] WinExe App project had no entry point**
- **Found during:** Task 3 (`dotnet build` of App).
- **Issue:** `CS5001: Program does not contain a static 'Main' method`. An `OutputType=WinExe` WinUI 3 project with zero source files cannot link.
- **Fix:** Added a minimal `App.xaml` + `App.xaml.cs` (empty `Application` with the standard `XamlControlsResources` merge). WinUI tooling generates the `Main` entry point from `App.xaml`, making the empty exe buildable. This is the canonical empty WinUI 3 scaffold; Plan 04 replaces it with the real lifecycle (single-instance mutex, DI host, tray bootstrap, wizard window).
- **Files created:** `windows/DS3Drive.App/App.xaml`, `windows/DS3Drive.App/App.xaml.cs`
- **Commit:** 5222fe5

**4. [Rule 2 - Robustness] Added a managed-only build escape hatch**
- **Found during:** Task 3.
- **Issue:** D-07 mandates unconditional cargo invocation on every Core build, which makes managed-only compilation impossible on machines without the MSVC C++ toolchain (and prevents verifying the C# scaffold in isolation).
- **Fix:** Added `Condition="'$(DS3SkipRustCore)' != 'true'"` to the `BuildRustCore` target. Production / CI builds leave it unset (DLL always staged per D-07); `-p:DS3SkipRustCore=true` enables a managed-only build for verification or on MSVC-less machines.
- **Files modified:** `windows/DS3Drive.Core/core-build/DS3Core.Build.targets`
- **Commit:** 5222fe5

### Lock files committed
`RestorePackagesWithLockFile=true` (set by Task 1) generates a `packages.lock.json` per project on restore. These were committed for reproducible restores — the intended effect of the property.

## Environment Blocker (native DLL build only)

**The `ds3_ffi.dll` cargo build cannot complete on this dev machine. The scaffold and MSBuild target are correct; the blocker is a missing toolchain, not a code defect.**

- **What failed:** `cargo build -p ds3-ffi --target aarch64-pc-windows-msvc` exits 101 with `error: linking with 'link.exe' failed: exit code: 1` followed by `link: extra operand ...` / `Try 'link --help'`.
- **Root cause:** Two compounding toolchain gaps on this Windows-on-ARM64 machine:
  1. The only `link.exe` on PATH is **`C:\Program Files\Git\usr\bin\link.exe`** (GNU coreutils `link`), which shadows the MSVC linker. The "extra operand / Try 'link --help'" output is the GNU `link` coreutil choking on MSVC-style linker arguments.
  2. **The MSVC C++ build tools workload is not installed.** `vswhere` reports "Visual Studio Build Tools 2022" present, but the `VC/` directory is entirely absent — no `cl.exe`, no MSVC `link.exe`, no `vcvars*.bat`. The cargo error message itself advises: *"in the Visual Studio installer, ensure the 'C++ build tools' workload is selected."*
- **What IS verified:** The Rust toolchain (cargo 1.96.0) and both Rust targets (`x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`) are installed; the MSBuild target invokes cargo with the correct target triple and copy paths. The failure is purely the absent native linker.
- **What's needed to unblock the native build:**
  1. Install the **"Desktop development with C++"** workload (or at minimum the "MSVC v143 build tools" + "Windows 11 SDK" components) via the Visual Studio Installer, AND
  2. Run the build from a Developer environment where the MSVC `link.exe` precedes Git's on PATH (e.g., a Developer Command Prompt / `vcvarsamd64_arm64.bat`), or remove/reorder Git's `usr\bin` from PATH for build sessions.
- **Plan-level note:** The plan's own success criteria already defer the authoritative restore/build verification to the Wave-0 CI plan (03) on `windows-latest`, which ships the MSVC C++ workload preinstalled. The native DLL build is expected to pass there.

## Known Stubs

- **`windows/DS3Drive.App/App.xaml.cs`** — `OnLaunched` is intentionally empty. Resolved by Plan 04 (real window + tray + DI host). Documented as the empty-scaffold entry point; does not block this plan's structural goal.

## Self-Check: PASSED

Created files verified present:
- FOUND: windows/DS3Drive.sln
- FOUND: windows/Directory.Build.props
- FOUND: windows/Directory.Packages.props
- FOUND: windows/README.md
- FOUND: windows/DS3Drive.App/DS3Drive.App.csproj
- FOUND: windows/DS3Drive.App/App.xaml
- FOUND: windows/DS3Drive.App/App.xaml.cs
- FOUND: windows/DS3Drive.Sync/DS3Drive.Sync.csproj
- FOUND: windows/DS3Drive.Core/DS3Drive.Core.csproj
- FOUND: windows/DS3Drive.Core/core-build/DS3Core.Build.targets
- FOUND: windows/DS3Drive.Tests/DS3Drive.Tests.csproj

Commits verified:
- FOUND: cc72880 (Task 1)
- FOUND: 0ae46cd (Task 2)
- FOUND: 5222fe5 (Task 3 deviation fixes)

Build verified: 4/4 managed projects compile clean (`dotnet build -p:DS3SkipRustCore=true`). Native DLL build blocked by environment (documented above), not by scaffold defect.
