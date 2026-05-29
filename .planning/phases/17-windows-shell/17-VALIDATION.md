---
phase: 17
slug: windows-shell
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-28
---

# Phase 17 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution. Sourced from `17-RESEARCH.md` § Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | xUnit 2.9.x + Microsoft.NET.Test.Sdk 17.10+ (C#) ; existing `cargo test` (Rust) |
| **Config file** | `windows/DS3Drive.Tests/xunit.runner.json` (Wave 0 creates) |
| **Quick run command** | `dotnet test windows/DS3Drive.Tests --filter "Category!=Integration" --nologo` |
| **Full suite command** | `dotnet test windows/DS3Drive.Tests --nologo` (integration; requires Cubbit creds) + `cargo test --workspace --tests` |
| **Estimated runtime** | ~30s quick ; ~3–5 min full (integration) |

---

## Sampling Rate

- **After every task commit:** `dotnet test windows/DS3Drive.Tests --filter "Category!=Integration" --nologo` (Rust-only commits → `cargo test -p <crate>`)
- **After every plan wave:** `dotnet test windows/DS3Drive.Tests --nologo` + `cargo test --workspace --tests`
- **Before `/gsd:verify-work`:** Full suite green AND `windows/manual-smoke-D-33.md` checklist completed on Windows 11 ARM64 VM
- **Max feedback latency:** 30s (quick) ; 5 min (wave)

---

## Per-Task Verification Map

> Authoritative requirement-to-test map. Plans/tasks reference this; each `Task ID` is filled in as plans land in step 8.

| Req ID | Behavior | Test Type | Automated Command | File Exists | Status |
|--------|----------|-----------|-------------------|-------------|--------|
| WIN-01 | Login via WinUI 3 form; tokens sealed via Credential Manager | unit + integration | `dotnet test --filter LoginViewModelTests` ; `dotnet test --filter CredentialStoreTests` | ❌ W0 | ⬜ pending |
| WIN-01 | Credential Manager round-trip (DPAPI-sealed) | unit | `dotnet test --filter CredentialStoreTests` | ❌ W0 | ⬜ pending |
| WIN-02 | Drive setup wizard navigation (project → bucket → prefix) | unit (VM) + manual UX smoke | `dotnet test --filter DriveSetupViewModelTests` | ❌ W0 | ⬜ pending |
| WIN-03 | Sync root registers via `StorageProviderSyncRootManager.Register` and appears in Explorer sidebar | manual (cfapi runtime) | manual smoke checklist item #2 | ❌ smoke | ⬜ pending |
| WIN-04 | Hydration via `CF_CALLBACK_TYPE_FETCH_DATA` streams in 4KB-aligned chunks; respects 30s timeout via `CfReportProviderProgress` | manual + Rust integration | manual smoke item #2 ; `cargo test --test s3_integration` | partial (Rust exists) | ⬜ pending |
| WIN-05 | `NOTIFY_FILE_CLOSE_COMPLETION` triggers upload; zero PUTs on open-then-close after hydration | manual | smoke items #3 (save) + #5 (no-spurious-PUT) | ❌ smoke | ⬜ pending |
| WIN-06 | Periodic poll surfaces remote changes; tray status reflects state | unit (SyncEngine tick) + manual | `dotnet test --filter SyncEngineTests` ; smoke item #6 | ❌ W0 | ⬜ pending |
| WIN-07 | Tray icon shows idle/syncing/error states | manual UX smoke | smoke item #4 | ❌ smoke | ⬜ pending |
| WIN-08 | Hydration progress visible in Explorer status column | manual UX smoke | smoke item #2 (≥100MB file, watch progress) | ❌ smoke | ⬜ pending |
| WIN-09 | MSI installs silently; sparse package registers; auto-start works | manual + CI smoke | `msiexec /i DS3Drive.msi /qn` then `Get-AppxPackage` returns sparse pkg + Run key exists | ❌ W0 CI | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

> **Note:** `Task ID`, `Plan`, `Wave`, `Threat Ref`, `Secure Behavior` columns will be populated by the planner in step 8 as plans are produced.

---

## Wave 0 Requirements

- [ ] `windows/DS3Drive.sln` + skeleton projects (`DS3Drive.App`, `DS3Drive.Sync`, `DS3Drive.Core`, `DS3Drive.Tests`)
- [ ] `windows/DS3Drive.Tests/DS3Drive.Tests.csproj` — xUnit + Microsoft.NET.Test.Sdk + Moq or NSubstitute
- [ ] `windows/DS3Drive.Tests/xunit.runner.json` — `parallelizeAssembly=false` (cfapi tests serialize)
- [ ] `windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs` — env-var-backed integration fixture
- [ ] `windows/manual-smoke-D-33.md` — checklist document (mirrors Apple's APPLE-05 / D-24)
- [ ] CI matrix entry: `.github/workflows/windows-build.yml` (Phase 15 may already have placeholder; verify and extend)
- [ ] Rust C ABI gaps closed in `core/ds3-ffi/src/c_exports.rs` (per RESEARCH § Key Finding #3)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Sync root appears in Explorer sidebar after registration | WIN-03 | cfapi runtime + shell namespace integration not unit-testable | Launch app, complete drive setup wizard, open Explorer → verify sidebar entry under "This PC" with Cubbit icon |
| Hydration of ≥100 MB cloud-only file with visible progress | WIN-04, WIN-08 | Requires cfapi + Explorer status column rendering | Right-click placeholder → Open ; watch Explorer status column for progress percentage ; file opens after hydration |
| Save in synced folder uploads to S3 (single PUT) | WIN-05 | Requires `NOTIFY_FILE_CLOSE_COMPLETION` wiring and S3 round-trip | Create/edit file in sync folder, Save ; tail tray log for single PUT ; verify S3 object via web console |
| No spurious PUT on open-then-close after hydration | WIN-05 | Confirms `NOTIFY_FILE_CLOSE_COMPLETION` triggers (not `ReadDirectoryChangesW`) | Hydrate a file, open in Notepad, close without edits ; expect ZERO PUT requests in log |
| Tray icon transitions across idle/syncing/error | WIN-07 | NotifyIcon state visible only at runtime | Trigger sync (drag file) → expect syncing ; trigger network failure → expect error ; observe icon transitions |
| Remote change reflected within one polling cycle | WIN-06 | Requires multi-device coordination | Modify object via web console ; wait ≤ poll interval ; verify placeholder updates in Explorer |
| MSI silent install + sparse package registration + auto-start | WIN-09 | OS-level install/uninstall behavior | `msiexec /i DS3Drive.msi /qn` ; `Get-AppxPackage *DS3Drive*` ; reboot → app auto-launches |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependency reference
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all ❌ MISSING references
- [ ] No watch-mode flags (`--watch`, `-w`) in commands
- [ ] Feedback latency < 30s (quick) / < 5 min (wave)
- [ ] `nyquist_compliant: true` set in frontmatter after planner produces plans + per-task automated mapping

**Approval:** pending
