# Windows Shell — Manual Smoke Checklist (CONTEXT D-33)

> **Phase 17 sign-off gate.** This checklist is the Windows analog of the macOS
> APPLE-05 / D-24 smoke test. It MUST be completed (all items pass) on the Windows 11
> ARM64 dev VM before `/gsd:verify-work`. Mirror the macOS checklist structure so
> Apple ↔ Windows smoke results can be diffed side-by-side by future maintainers.
>
> Each row carries a **Requirement IDs** column so `/gsd:verify-work` can correlate
> a checklist pass directly to WIN-01 … WIN-09, and a **RESEARCH ref** column pointing
> at the relevant `17-RESEARCH.md` pitfall so a failure has an immediate diagnosis path.

---

## 1. Environment

| Property | Value |
|----------|-------|
| Host | Apple Silicon Mac (per CONTEXT D-32) |
| Guest VM | **Windows 11 ARM64** (Parallels or UTM); cfapi works inside the VM without nested virtualization |
| Sync-root volume | **NTFS** — cfapi (`cldflt.sys`) supports NTFS only (Pitfall 8). Confirm `(Get-Volume <letter>).FileSystemType` returns `NTFS` before starting |
| Build under test | Release MSI produced by `windows/DS3Drive.Installer` (x64 on CI; ARM64 build local per D-06) |
| Account | Cubbit DS3 **test** account (email / password / tenant / 2FA enrolled) |
| Coordinator | Default `https://api.eu00wi.cubbit.services` unless a custom URL is being exercised |

> **Note:** CI (`windows-build.yml`, `windows-latest`) covers x64 build + non-integration
> tests only. cfapi runtime behaviour is **not** CI-testable and is verified exclusively
> here on the ARM64 VM.

---

## 2. Pre-flight (run before each smoke pass)

| # | Step | Command / Action | Done |
|---|------|------------------|------|
| P1 | Uninstall any prior version | `msiexec /x DS3Drive.msi /qn` (or Settings → Apps) | [ ] |
| P2 | Confirm no leftover cfapi sync root | PowerShell: `Get-StorageProviderSyncRoots` returns no `Cubbit*` entries | [ ] |
| P3 | Remove stale sparse package | `Get-AppxPackage *DS3Drive*` → if present `Remove-AppxPackage <FullName>` (Pitfall 7 version collision) | [ ] |
| P4 | Reset Credential Manager entries | `cmdkey /list` → delete any `Cubbit DS3 Drive — *` target | [ ] |
| P5 | Verify sync-root volume is **NTFS** | `(Get-Volume C).FileSystemType` → `NTFS` (Pitfall 8) | [ ] |
| P6 | Open Event Viewer filtered to `Cubbit-DS3Drive-*` providers | for live diagnosis during the run | [ ] |

---

## 3. Smoke Matrix

> Each item: tick `[ ]` only when **Expected** is observed. Record anomalies in **Observation**.

| # | Item | Requirement IDs | RESEARCH ref | Expected behaviour | Pass | Observation |
|---|------|-----------------|--------------|--------------------|------|-------------|
| 1 | **Install + first launch** — `msiexec /i DS3Drive.msi /qn`, then launch | WIN-09 | Pitfall 1, Pitfall 7 | Silent install; sparse package registered (`Get-AppxPackage *DS3Drive*` non-empty); `HKCU\...\Run` key present; tray icon appears | [ ] | |
| 2 | **Sign in (happy path)** — email + password + tenant, "Remember me" on | WIN-01 | — | Login succeeds; token sealed in Credential Manager (`cmdkey /list` shows `Cubbit DS3 Drive — <accountId>`); no password/token in Event Viewer payloads | [ ] | |
| 3 | **2FA path** — account with 2FA enrolled | WIN-01 | — | After password step the **2FA page** appears; valid code completes login; byte-identical UX to macOS 2FA flow | [ ] | |
| 4 | **Drive setup wizard** — walk Project → Bucket → Prefix → Name/Confirm | WIN-02 | — | Each step lists live data from the core (`ds3_get_projects` / `ds3_list_buckets` / `ds3_list_objects`); step order matches macOS verbatim; Cancel returns to drives list | [ ] | |
| 5 | **Sync root in Explorer sidebar** — finish wizard | WIN-03 | Pitfall 1, Pitfall 8 | Cubbit entry appears under "This PC" in the Explorer nav pane with the Cubbit icon; folder browsable | [ ] | |
| 6 | **Cloud-only placeholders + state icons** — browse synced folder without opening files | WIN-03, WIN-07 | Pitfall 4 | Files show as cloud-only placeholders with the platform cloud icon (via cfapi pin states, **not** a custom overlay handler — confirm no `ShellIconOverlayIdentifiers` registry key was added) | [ ] | |
| 7 | **Hydrate on double-click (≥100 MB)** — open a large cloud-only file | WIN-04, WIN-08 | Pitfall 2 | Explorer status column shows **progress %**; file opens after hydration; placeholder transitions to synced; no 30s timeout hang | [ ] | |
| 8 | **No spurious PUT after hydration (open-then-close)** — open the hydrated file in Notepad, close **without editing** | WIN-05 | Pitfall 3 | **Zero PUT** requests in the tray/Event Viewer log — confirms upload is driven by `NOTIFY_FILE_CLOSE_COMPLETION` on a real write, not by hydration / `ReadDirectoryChangesW` | [ ] | |
| 9 | **Save → upload (single PUT)** — create/edit a file in the synced folder and Save | WIN-05 | Pitfall 3 | Exactly **one** S3 PUT; object visible in the Cubbit web console; placeholder shows synced | [ ] | |
| 10 | **Rename** — rename a synced file in Explorer | WIN-05 | — | Rename reflected in S3 (copy-to-new-key + delete-old or server rename); Explorer shows the new name as synced | [ ] | |
| 11 | **Move** — move a synced file into a subfolder | WIN-05 | — | Object key updated in S3; no data re-upload of unchanged content; state returns to synced | [ ] | |
| 12 | **Delete** — delete a synced file | WIN-05 | — | Object removed from S3; placeholder disappears | [ ] | |
| 13 | **Conflict copy** — edit the same object locally and via web console, then let sync run | WIN-05, WIN-06 | — | A conflict copy is materialized using the `ds3_conflict_key` naming; both versions present locally; no data loss | [ ] | |
| 14 | **Remote change reflected within one poll cycle** — modify/add an object via web console | WIN-06 | — | Within ≤ poll interval (default 60s) the new/changed placeholder appears in Explorer; tray status reflects the sync activity | [ ] | |
| 15 | **Tray icon state transitions** — drag a file to trigger sync, then induce a network failure | WIN-06, WIN-07 | — | Tray icon transitions idle → syncing on activity, and → error on network failure; recovers to idle when restored | [ ] | |
| 16 | **Pause / resume** — toggle pause on a drive from the flyout, then resume | WIN-06, WIN-07 | — | While paused the per-drive polling timer halts (no PUT/GET); resuming reconciles pending changes | [ ] | |
| 17 | **Multi-drive: add a 2nd drive** — run the wizard again for a different bucket/prefix | WIN-02, WIN-03 | Pitfall 1 | Second independent cfapi sync root registers and appears in Explorer; second row in the flyout with its own status/pause state | [ ] | |
| 18 | **Multi-drive: add a 3rd drive** — repeat to reach the 3-drive cap | WIN-02, WIN-03 | — | Third sync root registers; "Add drive" disabled at the limit of 3; all three poll independently | [ ] | |
| 19 | **Uninstall cleanup** — `msiexec /x DS3Drive.msi /qn` | WIN-09 | Pitfall 7 | Sparse package removed; `Run` key removed; sync roots unregistered; Credential Manager entries cleared | [ ] | |

---

## 4. Sign-off

| Field | Value |
|-------|-------|
| Build / MSI version | |
| VM (Windows 11 ARM64 build) | |
| Date | |
| Result | ☐ PASS (all matrix items ticked) ☐ FAIL (see observations) |

**Engineer signature:** ______________________________  Date: ____________

**Second-reviewer signature:** ______________________________  Date: ____________

> Pass/fail summary (note any deferred items and their tracking issue):
>
> _____________________________________________________________________________
