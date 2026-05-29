---
phase: 17-windows-shell
plan: 04
subsystem: infra
tags: [sparse-package, msix, windows-appsdk, cfapi, identity, makeappx, signtool, authenticode]

# Dependency graph
requires:
  - phase: 17-windows-shell (Plan 02)
    provides: DS3Drive.App WinUI 3 unpackaged exe scaffold (WindowsPackageType=None, EnableMsixTooling, app.manifest)
provides:
  - Sparse identity package manifest (Cubbit.DS3Drive) granting the unpackaged exe package identity
  - App-side Package.appxmanifest mirroring the sparse Identity block
  - app.manifest updated to reference the Cubbit.DS3Drive sparse identity (longPathAware, asInvoker, PerMonitorV2)
  - build-sparse.ps1 MakeAppx + SignTool wrapper emitting DS3Drive.Identity.msix
affects: [17-windows-shell Plan 10 (cfapi sync engine), 17-windows-shell Plan 12 (WiX MSI)]

# Tech tracking
tech-stack:
  added: [MSIX sparse identity package, MakeAppx, SignTool]
  patterns: ["Sparse identity package grants unpackaged WinUI 3 exe a package identity for cfapi registration", "Identity Name/Version kept in lockstep across sparse manifest, app manifest, and Win32 app.manifest"]

key-files:
  created:
    - windows/DS3Drive.Installer/SparsePackage/Package.appxmanifest
    - windows/DS3Drive.App/Package.appxmanifest
    - windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1
  modified:
    - windows/DS3Drive.App/app.manifest

key-decisions:
  - "Sparse manifest Publisher (CN=Cubbit Srl, ...) is a placeholder pending Authenticode cert procurement (CONTEXT D-29); must match cert subject byte-for-byte (RESEARCH Pitfall 1)"
  - "Version pinned at 2.0.0.0 across all three manifests; must be bumped on every MSI release (RESEARCH Pitfall 7)"
  - "build-sparse.ps1 supports unsigned output (-SkipSign / no -CertPath) for the P17 beta on dev-mode machines; CI signs with the cert"
  - "cfapi extension declares placeholder all-zero CLSIDs for context-menu/state/thumbnail/property/banner handlers; real CLSIDs land when the shell extension is built (later P17 plan)"

patterns-established:
  - "Sparse identity package linchpin: MSI (Plan 12) packs build-sparse.ps1 output then Add-AppxPackage -ExternalLocation; running exe gains identity so StorageProviderSyncRootManager.Register (Plan 10) succeeds"
  - "SecureString cert password marshalled to plaintext only at the SignTool call site, then zeroed (threat T-17-04-03)"

requirements-completed: [WIN-03, WIN-09]

# Metrics
duration: 6min
completed: 2026-05-29
---

# Phase 17 Plan 04: Sparse Identity Package Manifest Summary

**Sparse MSIX identity package (Cubbit.DS3Drive) with AllowExternalContent + runFullTrust + cfapi cloudFiles extension, plus a MakeAppx/SignTool build wrapper, granting the unpackaged WinUI 3 exe the package identity cfapi's StorageProviderSyncRootManager.Register requires.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-05-29T13:35:14Z
- **Completed:** 2026-05-29T13:41:11Z
- **Tasks:** 2
- **Files modified:** 4 (3 created, 1 modified)

## Accomplishments
- Authored the sparse identity manifest declaring `Cubbit.DS3Drive` (x64) with `uap10:AllowExternalContent=true`, `rescap:Capability runFullTrust`, the `windows.cloudFiles` cfapi extension, the 10.0.19041.0 AllowExternalContent floor, and load-bearing Pitfall 1/7 warning comments.
- Created the app-side `Package.appxmanifest` mirroring the Identity block byte-for-byte so the running exe resolves to the sparse package identity.
- Updated `app.manifest` so the Win32 `assemblyIdentity` references `Cubbit.DS3Drive` `2.0.0.0`, adds `longPathAware`, `asInvoker` trustInfo, and keeps `PerMonitorV2`.
- Wrote `build-sparse.ps1` (strict mode, SDK tool resolution, `MakeAppx pack /m /nv`, optional `SignTool sign /fd SHA256`, sha256/version/size report) ready for the WiX MSI custom action in Plan 12.

## Task Commits

Each task was committed atomically:

1. **Task 1: Author sparse identity package manifest** - `1dfd694` (feat)
2. **Task 2: Author build-sparse.ps1 (MakeAppx + SignTool wrapper)** - `1f7f271` (feat)

**Plan metadata:** committed with this SUMMARY + STATE + ROADMAP (docs).

## Files Created/Modified
- `windows/DS3Drive.Installer/SparsePackage/Package.appxmanifest` - Sparse identity manifest consumed by `Add-AppxPackage -ExternalLocation`
- `windows/DS3Drive.App/Package.appxmanifest` - App-side mirror of the sparse Identity block (links exe to identity at activation)
- `windows/DS3Drive.App/app.manifest` - Win32 SxS manifest now referencing the Cubbit.DS3Drive sparse identity; longPathAware + asInvoker trustInfo added
- `windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1` - MakeAppx + SignTool wrapper emitting DS3Drive.Identity.msix

## Decisions Made
- **Publisher subject is a placeholder** (`CN=Cubbit Srl, O=Cubbit Srl, L=Bologna, S=BO, C=IT`) pending Authenticode cert procurement (CONTEXT D-29). Documented in leading comments on all three manifests that it MUST equal the cert subject byte-for-byte (RESEARCH Pitfall 1).
- **Version pinned at 2.0.0.0** across all three manifests with explicit Pitfall 7 version-bump-per-release warnings.
- **cfapi handler CLSIDs are placeholder all-zero GUIDs** — the real COM CLSIDs are assigned when the shell/state handler is implemented in a later P17 plan; the extension declaration shape is in place now so the manifest is complete and well-formed.
- **app.manifest assemblyIdentity name changed** from `Cubbit.DS3Drive.App` (1.0.0.0) to `Cubbit.DS3Drive` (2.0.0.0) to match the sparse package identity exactly, as the plan requires for activation-time linkage.

## Deviations from Plan

None - plan executed exactly as written. (The plan stated `app.manifest` would be created; it already existed from Plan 02 with a non-matching identity, so it was updated rather than created — same end state required by Task 1.)

## Issues Encountered
- **MakeAppx/SignTool not installed on this box.** The Windows 10/11 SDK is not present (`C:\Program Files (x86)\Windows Kits\` is empty), consistent with the standing Plan 17-02 blocker (MSVC C++ Build Tools workload not installed). The `build-sparse.ps1` pack + sign step therefore could **not** be executed locally and is **deferred to CI / install-time**, exactly as the plan and threat register anticipate (this plan delivers the manifests + script the MSI consumes, not a built MSIX).
  - **Local verification performed instead:** all three manifests validated as well-formed XML via PowerShell `[xml]` parsing; `build-sparse.ps1` validated as parseable PowerShell via `System.Management.Automation.Language.Parser.ParseFile` (PARSE-OK, zero errors). All grep/structural acceptance criteria pass.
- **Python unavailable** on this box (the `ET.parse` acceptance check could not run as written). Substituted PowerShell `[xml]` well-formedness validation, which is equivalent for the "well-formed XML" criterion.

## Deferred / CI-only steps
- `build-sparse.ps1` actual `MakeAppx pack` + `SignTool sign` execution → runs on `windows-latest` CI (Windows SDK present) and/or at MSI build time. Not runnable locally on this ARM64 box without the Windows SDK.
- Authenticode signing → cert procurement pending (CONTEXT D-29); P17 beta ships unsigned with the documented dev-mode requirement.

## User Setup Required
None - no external service configuration required for this plan. (Authenticode cert procurement is tracked separately under CONTEXT D-29 and is not a blocker for the manifests/script delivered here.)

## Next Phase Readiness
- Plan 12 (WiX MSI) can invoke `build-sparse.ps1` to produce `DS3Drive.Identity.msix` and register it via `Add-AppxPackage -ExternalLocation`.
- Plan 10 (cfapi sync engine) can call `StorageProviderSyncRootManager.Register` once the sparse package is installed (the running exe will have package identity).
- **Open item for the shell-extension plan:** replace placeholder all-zero CLSIDs in the cfapi `<CloudFiles>` extension with the real COM handler CLSIDs.
- **Open item for release:** procure Authenticode cert (D-29), set Publisher subject byte-for-byte, and bump the manifest Version per release (Pitfall 7).

## Self-Check: PASSED

Files verified present:
- FOUND: windows/DS3Drive.Installer/SparsePackage/Package.appxmanifest
- FOUND: windows/DS3Drive.App/Package.appxmanifest
- FOUND: windows/DS3Drive.App/app.manifest
- FOUND: windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1

Commits verified present:
- FOUND: 1dfd694 (Task 1)
- FOUND: 1f7f271 (Task 2)

---
*Phase: 17-windows-shell*
*Completed: 2026-05-29*
