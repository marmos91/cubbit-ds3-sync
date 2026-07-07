# S3-Client FFI Wiring — ARM64 First-Run Manual Smoke (D-07)

> **Phase 17.1 sign-off gate (criterion #5).** This checklist is the ARM64
> marshalling-parity + cfapi runtime gate for the S3-client FFI wiring. It MUST be
> completed (all items pass) on the Windows 11 **ARM64** dev VM before
> `/gsd:verify-work`. It is the focused companion to Phase 17's full
> `windows/manual-smoke-D-33.md`: where D-33 covers the whole shell, D-07 proves
> that the newly-wired `DS3DriveS3Client` handle (`ds3_s3_client_new` /
> `ds3_s3_client_destroy`, plan 17.1-01) survives a real end-to-end run on native
> ARM64 — the one path headless CI cannot exercise (cfapi + ARM64 `nuint`/`usize`
> marshalling, RESEARCH Pitfall 6).
>
> Mirror the D-33 structure so Apple ↔ Windows ↔ 17.1 smoke results diff
> side-by-side. The pivotal new assertion vs. Phase 17 is item 4: **the bucket list
> loads without an AccessViolationException** (the AVE was the root symptom the FFI
> wiring fixes).

---

## 1. Environment

| Property | Value |
|----------|-------|
| Host | Apple Silicon Mac (per CONTEXT D-32) |
| Guest VM | **Windows 11 ARM64** (Parallels or UTM); cfapi works inside the VM without nested virtualization |
| Sync-root volume | **NTFS** — cfapi (`cldflt.sys`) supports NTFS only (Pitfall 8). Confirm `(Get-Volume <letter>).FileSystemType` returns `NTFS` before starting |
| Native DLL | `ds3_ffi.dll` built for **win-arm64** (release) — contains `ds3_s3_client_new` + `ds3_s3_client_destroy` (plan 17.1-01); CI builds x64, the ARM64 DLL is built on the VM/locally per D-06 |
| Account | Cubbit DS3 **test** account (email / password / tenant / 2FA enrolled) |
| Coordinator | Default `https://api.eu00wi.cubbit.services` unless a custom URL is being exercised |

> **Note:** CI (`windows-build.yml`, `windows-latest`) covers x64 build + non-integration
> tests only, and a credentials-gated `workflow_dispatch` run exercises the integration
> suite against x64. The cfapi runtime behaviour AND the ARM64 marshalling parity are
> **not** CI-testable and are verified exclusively here on the ARM64 VM.

---

## 2. Pre-flight (run before each smoke pass)

| # | Step | Command / Action | Done |
|---|------|------------------|------|
| P1 | Uninstall any prior version | `msiexec /x DS3Drive.msi /qn` (or Settings → Apps) | [ ] |
| P2 | Confirm no leftover cfapi sync root | PowerShell: `Get-StorageProviderSyncRoots` returns no `Cubbit*` entries | [ ] |
| P3 | Remove stale sparse package | `Get-AppxPackage *DS3Drive*` → if present `Remove-AppxPackage <FullName>` | [ ] |
| P4 | Reset Credential Manager entries | `cmdkey /list` → delete any `Cubbit DS3 Drive — *` target | [ ] |
| P5 | Verify sync-root volume is **NTFS** | `(Get-Volume C).FileSystemType` → `NTFS` (Pitfall 8) | [ ] |
| P6 | Confirm the ARM64 native DLL is staged | `(Get-Item .\ds3_ffi.dll).VersionInfo` resolves; the app is the **ARM64** build (Task Manager → Details → "Architecture" column = ARM64) | [ ] |
| P7 | Open Event Viewer filtered to `Cubbit-DS3Drive-*` providers | for live diagnosis during the run | [ ] |

---

## 3. Smoke Matrix

> Each item: tick `[ ]` only when **Expected** is observed. Record anomalies in **Observation**.

| # | Item | Requirement IDs | Expected behaviour | Pass | Observation |
|---|------|-----------------|--------------------|------|-------------|
| 1 | **Sign in (happy path)** — email + password + tenant | WIN-01 | Login succeeds; token sealed in Credential Manager (`cmdkey /list` shows `Cubbit DS3 Drive — <accountId>`); no password/token in Event Viewer payloads | [ ] | |
| 2 | **2FA path** — account with 2FA enrolled | WIN-01 | After the password step the **2FA page** appears; valid code completes login; byte-identical UX to macOS 2FA flow | [ ] | |
| 3 | **Wizard — project step** — open the drive-setup wizard | WIN-03 | Projects list populates from the core (`ds3_get_projects`); no crash | [ ] | |
| 4 | **Wizard — buckets list WITHOUT AccessViolation** — select a project | **WIN-03** | The bucket list loads through the newly-minted `DS3DriveS3Client` handle (`ds3_list_buckets` on a real `*const DS3S3Client`, **not** the session handle). **No `AccessViolationException`**, no app crash, no silent hang. On a forbidden/bad-key project an inline error appears with a working **Retry** (D-06), and the wizard stays on the Bucket step | [ ] | |
| 5 | **Wizard — prefix step** — pick a prefix (or root) | WIN-03 | Child prefixes list via `ds3_list_objects` through the same handle; "root" is selectable; advances to Confirm | [ ] | |
| 6 | **Wizard — confirm + create drive** — name and finish | WIN-02, WIN-03 | API key reconciled; drive persists; wizard dismisses to the drives list | [ ] | |
| 7 | **Sync root in Explorer sidebar** | WIN-03 | Cubbit entry appears under "This PC" in the Explorer nav pane with the Cubbit icon; folder is browsable; files show as cloud-only placeholders | [ ] | |
| 8 | **Cloud-only file hydrates on open** — double-click a placeholder | WIN-04, WIN-08 | Explorer status column shows progress; file content downloads via `DownloadObject` on the S3 handle and opens; placeholder → synced; no 30s timeout hang | [ ] | |
| 9 | **Local edit uploads (single PUT)** — edit a synced file and Save | WIN-05 | Exactly **one** S3 PUT via `UploadObject` on the S3 handle (NOTIFY_FILE_CLOSE_COMPLETION-driven, not hydration); object visible in the Cubbit web console; placeholder shows synced | [ ] | |
| 10 | **Remote change appears** — add/modify an object via the web console | WIN-06 | Within ≤ poll interval (default 60s) the new/changed placeholder appears in Explorer via `ListObjects` on the S3 handle; tray status reflects the sync activity | [ ] | |
| 11 | **No use-after-free on drive stop** — pause/remove the drive while idle | WIN-04, WIN-05 | The `DS3DriveS3Client` is disposed AFTER the engine + provider stop (dispose-last, Pitfall 4); no crash, no AVE in Event Viewer; re-adding the drive mints a fresh handle cleanly | [ ] | |

---

## 4. Sign-off

| Field | Value |
|-------|-------|
| Build / DLL version (ARM64) | |
| VM (Windows 11 ARM64 build) | |
| Date | |
| Result | ☐ PASS (all matrix items ticked) ☐ FAIL (see observations) |

**Engineer signature:** ______________________________  Date: ____________

**Second-reviewer signature:** ______________________________  Date: ____________

> Pass/fail summary (note any deferred items and their tracking issue):
>
> _____________________________________________________________________________
