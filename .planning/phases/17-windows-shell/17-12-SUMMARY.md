---
phase: 17-windows-shell
plan: 12
subsystem: infra
tags: [wix, msi, installer, sparse-package, add-appxpackage, run-key, auto-start, ntfs, github-actions, authenticode]

# Dependency graph
requires:
  - phase: 17-04
    provides: Sparse identity package (Cubbit.DS3Drive) + build-sparse.ps1 emitting DS3Drive.Identity.msix
  - phase: 17-10
    provides: cfapi StorageProviderSyncRootManager registration that consumes SyncRoot.ico + the registered sparse identity
  - phase: 17-11
    provides: Tray app exe (DS3Drive.App.exe) the Run key + Start Menu shortcut target
provides:
  - WiX v4 MSI sources (Product.wxs, Components.wxs, Variables.wxi, UI.wxs, DS3Drive.Installer.wixproj)
  - Sparse-package register/unregister custom actions (Add-AppxPackage -ExternalLocation / Remove-AppxPackage)
  - HKCU Run-key auto-start (D-26) + Start Menu shortcut + SyncRoot icon staging
  - NTFS prerequisite guard (VerifyNtfs custom action, Pitfall 8)
  - build-msi.ps1 (cargo -> dotnet publish -> sparse msix -> wix build -> optional SignTool)
  - .github/workflows/windows-release.yml (tag-triggered MSI build + sign + GitHub Release attach)
affects: [phase-18-polish, POL-05-authenticode, POL-06-auto-update, POL-08-arm64-installer]

# Tech tracking
tech-stack:
  added: [WixToolset.Sdk 4.0.5, WixToolset.UI.wixext, wix CLI dotnet tool, softprops/action-gh-release v2]
  patterns:
    - "MSI harvest via WiX v4 <Files> auto-harvest from a dotnet publish bindpath"
    - "Sparse-package identity granted at install time via deferred+impersonated PowerShell custom action"
    - "build-msi.ps1 syncs Variables.wxi ProductVersion AND sparse manifest <Identity Version> in lock-step (Pitfall 7)"
    - "Tag-triggered release workflow mirrors the existing windows-build.yml conventions"

key-files:
  created:
    - windows/DS3Drive.Installer/Product.wxs
    - windows/DS3Drive.Installer/Components.wxs
    - windows/DS3Drive.Installer/Variables.wxi
    - windows/DS3Drive.Installer/UI.wxs
    - windows/DS3Drive.Installer/DS3Drive.Installer.wixproj
    - windows/DS3Drive.Installer/build-msi.ps1
    - windows/DS3Drive.Installer/LICENSE.rtf
    - windows/DS3Drive.Installer/SyncRootIcon.ico
    - windows/DS3Drive.Installer/banner.bmp
    - windows/DS3Drive.Installer/dialog.bmp
    - .github/workflows/windows-release.yml
  modified:
    - windows/DS3Drive.sln
    - .planning/phases/17-windows-shell/17-HUMAN-UAT.md

key-decisions:
  - "MSI ProductVersion + sparse manifest <Identity Version> kept byte-for-byte equal; build-msi.ps1 regex-syncs both at build time (Pitfall 7)"
  - "WixUI_Minimal chosen — smallest dialog set that still supports the primary /qn silent-install path (D-28)"
  - "Sparse msix owned by a dedicated SparsePackageFiles component and Excluded from the AppFiles auto-harvest to avoid double-install"
  - "VerifyNtfs uses double-quoted PowerShell string literals (&quot;) so the single-quoted PS command survives XML escaping cleanly"
  - "MSI build + D-33 live smoke deferred to CI / HUMAN-UAT (WiX toolset not installed on the dev machine; same MSVC/SDK blocker as 17-02/17-04)"

patterns-established:
  - "Pattern: WiX v4 SDK-style .wixproj with ProjectReference (DoNotHarvest) for build ordering + publish-bindpath harvest for payload"
  - "Pattern: deferred+impersonated PowerShell custom action for Add-AppxPackage -ExternalLocation (runs as installing user, not SYSTEM — T-17-12-01)"

requirements-completed: [WIN-09]

# Metrics
duration: 8min
completed: 2026-05-29
---

# Phase 17 Plan 12: WiX MSI Installer (WIN-09) Summary

**WiX v4 MSI sources + build-msi.ps1 + tag-triggered windows-release.yml that install Cubbit DS3 Drive to %ProgramFiles%, register the sparse identity package via Add-AppxPackage -ExternalLocation, write the HKCU Run key for auto-start, and guard against non-NTFS volumes — MSI build + D-33 live smoke deferred to CI/HUMAN-UAT.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-05-29T18:05:10Z
- **Completed:** 2026-05-29T18:13:08Z
- **Tasks:** 2 of 4 implementation tasks (Tasks 3 + 4 are blocking-human checkpoints deferred to HUMAN-UAT per user decision)
- **Files modified:** 12

## Accomplishments

- Authored the complete WiX v4 MSI source set: `Product.wxs` (perMachine package, `MajorUpgrade`, install layout `%ProgramFiles%\Cubbit\DS3 Drive`, feature/component graph), `Components.wxs` (`AppFiles` auto-harvest from the publish bindpath), `Variables.wxi` (version/upgrade-code/manufacturer with a fresh upgrade GUID), and `UI.wxs` (`WixUI_Minimal`).
- Wired the **sparse-package register custom action** verbatim from RESEARCH §Code Examples — `RegisterSparsePackage` runs `Add-AppxPackage -Path [INSTALLFOLDER]Identity\DS3Drive.Identity.msix -ExternalLocation [INSTALLFOLDER]` deferred + impersonated, `After="InstallFiles"`, condition `NOT REMOVE` (Pitfall 1, the load-bearing cfapi-identity link to Plan 04/10).
- Wired the **unregister custom action** (`Remove-AppxPackage` on `Cubbit.DS3Drive` full name) `Before="RemoveFiles"` on `REMOVE="ALL"` plus `MajorUpgrade` so version-replay collisions can't occur (Pitfall 7).
- Wired **auto-start** (`RunKeyComponent` → `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Cubbit DS3 Drive`, D-26), a Start Menu shortcut, the `Identity\DS3Drive.Identity.msix` payload, and `Assets\SyncRoot.ico` (consumed by Plan 10).
- Added the **NTFS prerequisite guard** (`VerifyNtfs` PowerShell custom action, `Before="LaunchConditions"`) that aborts with 1603 on a non-NTFS target (Pitfall 8 / T-17-12-06).
- Authored `build-msi.ps1` — strict-mode pipeline chaining `build-dll-windows.ps1` (ds3_ffi.dll) → `dotnet publish` → `build-sparse.ps1` → ProductVersion/manifest version sync → `wix build` → optional `signtool` Authenticode (RFC-3161 timestamp), reporting sha256 + size.
- Authored `.github/workflows/windows-release.yml` — `on: push tags v*`, `contents: write`, `windows-latest`, installs the WiX v4 CLI, conditionally decodes `AUTHENTICODE_PFX_BASE64` (else `-SkipSign`), and attaches the MSI to the matching GitHub Release.
- Added `DS3Drive.Installer` to `DS3Drive.sln` with x64 mappings (ARM64 mapped to x64 since the installer is x64-only in P17 per D-06).
- Appended MSI-install / packaging / phase-sign-off items (#44–#53) to `17-HUMAN-UAT.md` (continuing from #43; total bumped 43 → 53).

## Task Commits

1. **Task 1: WiX v4 project + Product.wxs + Components.wxs + sparse-package custom actions** - `a2c58b8` (feat)
2. **Task 2: build-msi.ps1 + windows-release.yml CI tag-triggered workflow** - `35b3c10` (feat)

Tasks 3 (build + silent-install smoke) and 4 (full D-33 phase sign-off) are `checkpoint:human-action` / `checkpoint:human-verify` gates with `gate="blocking-human"`. Per the explicit user decision recorded for this execution, the live MSI build + install/uninstall/reboot/NTFS-guard smoke and the full D-33 WIN-01..WIN-09 sign-off are **deferred to the phase HUMAN-UAT** (entries #44–#53) rather than blocking this executor.

**Plan metadata:** see final docs commit.

## Files Created/Modified

- `windows/DS3Drive.Installer/Product.wxs` - MSI product: package metadata, MajorUpgrade, NTFS guard, sparse register/unregister custom actions, Run key, Start Menu shortcut, sparse + icon components, feature graph, WixUI ref
- `windows/DS3Drive.Installer/Components.wxs` - `AppFiles` ComponentGroup auto-harvesting the dotnet publish output (excludes the sparse msix, owned by its dedicated component)
- `windows/DS3Drive.Installer/Variables.wxi` - ProductVersion 2.0.0.0, ProductUpgradeCode (fresh GUID), manufacturer, install folder name
- `windows/DS3Drive.Installer/UI.wxs` - WixUI text override fragment (dialog set referenced once in Product.wxs)
- `windows/DS3Drive.Installer/DS3Drive.Installer.wixproj` - WiX v4 SDK project, x64, WixToolset.UI.wixext, ProjectReference for build ordering
- `windows/DS3Drive.Installer/build-msi.ps1` - end-to-end MSI build wrapper (cargo → publish → sparse → wix → sign)
- `windows/DS3Drive.Installer/LICENSE.rtf` - placeholder EULA pointing at https://cubbit.io/terms (D-29 beta)
- `windows/DS3Drive.Installer/SyncRootIcon.ico` - placeholder Cubbit glyph (installed as Assets\SyncRoot.ico + ARP icon)
- `windows/DS3Drive.Installer/banner.bmp` (493×58) / `dialog.bmp` (493×312) - placeholder WixUI branding
- `.github/workflows/windows-release.yml` - tag-triggered release pipeline
- `windows/DS3Drive.sln` - added the installer project
- `.planning/phases/17-windows-shell/17-HUMAN-UAT.md` - appended MSI-install + D-33 sign-off items #44–#53

## Decisions Made

- **Version lock-step (Pitfall 7):** `build-msi.ps1` regex-syncs both `Variables.wxi` ProductVersion and the sparse manifest `<Identity Version>` to the `-Version` argument so `Add-AppxPackage` never hits a same-version collision (0x80073CF9).
- **Dedicated sparse component + harvest exclusion:** the sparse msix is owned by `SparsePackageFiles` and `<Exclude>`d from the auto-harvest, so the `Add-AppxPackage` custom-action target is a single deterministic component, not double-installed.
- **PowerShell-string escaping inside XML attributes:** `VerifyNtfs` and `UnregisterSparsePackage` use double-quoted PS literals (via `&quot;`) instead of doubled single-quotes, because a single-quoted XML attribute cannot contain a literal `'` without `&apos;`. This keeps the .wxs strictly well-formed (a strict XML parser rejected the doubled-single-quote form).
- **Installer x64-only (D-06):** ARM64 solution configs map to x64; the ARM64 MSI is Phase 18 POL-08.

## Deviations from Plan

None - plan executed exactly as written for the two implementation tasks. Tasks 3 and 4 (blocking-human checkpoints) were not executed by the executor by explicit user decision (deferred to HUMAN-UAT); this is the agreed checkpoint handling for this phase-closing plan, not a deviation in the work product.

## Issues Encountered

- **Initial XML well-formedness failure:** the first draft of `Product.wxs` used PowerShell's doubled-single-quote escaping (`''NTFS''`) inside single-quote-delimited XML attributes, which a strict XML parser rejected at the literal apostrophe. Resolved by switching those two custom actions to double-quoted PS literals encoded as `&quot;`. All four .wxs/.wxi files now parse as well-formed XML.
- **`head -15 ErrorActionPreference` heuristic vs. PowerShell semantics:** `param()` must be the first statement in a script, so `Set-StrictMode`/`$ErrorActionPreference` cannot precede it. Restructured to a compact 2-line comment header + 11-line param block so the strict-mode lines still land within the first 15 lines while keeping the script parseable (verified via `[Parser]::ParseFile`).

## Local Validation Performed (toolchain-limited environment)

WiX v4 toolset is not installed on this Windows-on-ARM64 dev machine (same MSVC/Windows-SDK blocker noted in 17-02/17-04), so the MSI was **not** built or installed here. Validated what the environment allows:

- All four WiX sources (`Product.wxs`, `Components.wxs`, `UI.wxs`, `Variables.wxi`) parse as **well-formed XML** (`[xml]` load via PowerShell).
- `build-msi.ps1` parses with **zero errors** (`System.Management.Automation.Language.Parser.ParseFile`).
- `windows-release.yml` read cleanly with no tab characters; structure mirrors the known-valid `windows-build.yml` (no standalone YAML parser available locally — `python3`/`powershell-yaml` absent).
- All plan acceptance greps pass: `MajorUpgrade`≥1, Run key present, `Add-AppxPackage`/`Remove-AppxPackage` present, `DS3Drive.Identity.msix` referenced, NTFS guard present, Pitfall doc refs present, **`ds3_core` count = 0** in all installer artifacts, `wix build`/`signtool`/`build-sparse.ps1` present in build-msi.ps1, tag trigger + windows-latest + action-gh-release present in the workflow, `DS3Drive.Installer` added to the solution.

**Deferred to CI / HUMAN-UAT (no fabricated results):**
- Actual `wix build` producing `DS3Drive-2.0.0.0-x64.msi` → windows-release.yml on tag, or local build on the ARM64 VM with the WiX CLI installed.
- Authenticode signing → blocked on cert procurement (D-29 / Phase 18 POL-05); MSI ships unsigned for the P17 beta.
- Silent install/uninstall, sparse-package registration, Run-key auto-start after reboot, NTFS-guard negative test → HUMAN-UAT #44–#52.
- Full D-33 WIN-01..WIN-09 phase sign-off → HUMAN-UAT #53 + `windows/manual-smoke-D-33.md`.

## User Setup Required

None for the source artifacts. To produce a real MSI a maintainer must install the WiX v4 CLI (`dotnet tool install --global wix --version 4.*`) on a Windows machine (or push a `v*` tag to trigger `windows-release.yml`). Authenticode signing requires the `AUTHENTICODE_PFX_BASE64` + `AUTHENTICODE_PFX_PASSWORD` repo secrets (Phase 18 POL-05).

## Next Phase Readiness

- WIN-09 installer artifacts are complete and committed; Phase 17 is feature-complete on the implementation side.
- Phase 17 **closes only after** the D-33 HUMAN-UAT (#1–#53) passes on the Windows 11 ARM64 VM with an MSI-installed build — this is the gating manual smoke, deferred by user decision, not waived.
- Phase 18 carryovers explicitly referenced in the installer artifacts: POL-05 (Authenticode cert), POL-06 (auto-update — currently MSI-replace via MajorUpgrade), POL-08 (ARM64 MSI).

## Self-Check: PASSED

All 12 created files verified present on disk; both task commits (`a2c58b8`, `35b3c10`) verified in git history.

---
*Phase: 17-windows-shell*
*Completed: 2026-05-29*
