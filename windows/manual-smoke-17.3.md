# Enumeration Performance & UX — Manual Smoke (Phase 17.3)

> **Phase 17.3 sign-off gate.** This checklist covers the cfapi/Explorer behaviour that is NOT
> unit-testable: incremental placeholder appearance at scale, no Explorer freeze, the on-disk ghost
> removal, the tray progress readout, and the sync-anchor "nothing changed → no work" path. Run it on
> the Windows 11 **ARM64** dev VM (or this x64 box) after the automated suite is green. It is the
> runtime companion to `manual-smoke-D-07.md` (17.1 first-run) and `manual-smoke-D-33.md` (whole shell).
>
> The pivotal new assertions vs. 17.1: **item 3** (a >2000-object prefix fills in *incrementally*,
> Explorer never freezes) and **item 6** (a remote delete removes the on-disk entry, not just the DB row).

---

## 1. Environment

| Property | Value |
|----------|-------|
| Host | Apple Silicon Mac (per CONTEXT D-32), or the local x64 dev box |
| Guest VM | Windows 11 ARM64 (Parallels/UTM) — cfapi works inside the VM; or run on x64 directly |
| Sync-root volume | **NTFS** — cfapi (`cldflt.sys`) supports NTFS only. Confirm `(Get-Volume <letter>).FileSystemType` == `NTFS` |
| Native DLL | `ds3_ffi.dll` for the target arch (release), containing the S3 client exports |
| Account | Cubbit DS3 **test** account (email / password / tenant / 2FA if enrolled) |
| Coordinator | Default `https://api.eu00wi.cubbit.services` unless a custom URL is exercised |

> **Seed data.** Items 3–4 need a bucket prefix with **>2000 objects** (crosses the 2000-key
> `LIST_BATCH_SIZE` page boundary). Seed one with the console/CLI, or point the drive at the same
> prefix the integration fixture seeds (`ds3drive-enum-itest/<guid>/bulk/`) after a
> `workflow_dispatch` integration run. A few hundred objects is enough to *see* streaming, but the
> D-01 no-prune guarantee is only exercised past 2000.

---

## 2. Pre-flight (run before each smoke pass)

| # | Step | Command / Action | Done |
|---|------|------------------|------|
| P1 | Uninstall any prior version | `msiexec /x DS3Drive.msi /qn` (or Settings → Apps) | [ ] |
| P2 | No leftover cfapi sync root | `Get-StorageProviderSyncRoots` returns no `Cubbit*` entries | [ ] |
| P3 | Remove stale sparse package | `Get-AppxPackage *DS3Drive*` → `Remove-AppxPackage <FullName>` if present | [ ] |
| P4 | Reset Credential Manager entries | `cmdkey /list` → delete any `Cubbit DS3 Drive — *` target | [ ] |
| P5 | Sync-root volume is **NTFS** | `(Get-Volume C).FileSystemType` → `NTFS` | [ ] |
| P6 | A >2000-object prefix exists to point the drive at | see "Seed data" note above | [ ] |
| P7 | Event Viewer filtered to `Cubbit-DS3Drive-*` providers | for live diagnosis (watch for `poll unchanged (anchor match)`, `fetch-placeholders`) | [ ] |

---

## 3. Smoke Matrix

> Each item: tick `[ ]` only when **Expected** is observed. Record anomalies in **Observation**.

| # | Item | Decision | Expected behaviour | Pass | Observation |
|---|------|----------|--------------------|------|-------------|
| 1 | **Drive registers + sidebar entry** — add a drive on a small prefix | — | Cubbit entry appears under "This PC"; folder browsable; children show as cloud-only placeholders | [ ] | |
| 2 | **Full pagination, no phantom prune** — open a **>2000-object** prefix, wait a poll cycle (≤60s) | **D-01** | ALL objects are present — none beyond the first 2000 vanish. Re-poll (or re-open): count stays complete, nothing is pruned then re-added (no flicker) | [ ] | |
| 3 | **Incremental appearance, no freeze** — first open of the >2000-object prefix | **D-02** | Children appear **progressively, page by page**, not in one late lump; Explorer stays responsive (scroll/select works during population); no multi-second freeze | [ ] | |
| 4 | **Idempotent re-enumeration** — close and re-open the prefix; force a re-poll | **D-02** | No duplicate entries; the set is identical; the placeholder index has one row per key (no growth) | [ ] | |
| 5 | **On-demand child folder population** — open a subfolder with many children | **D-02** | The subfolder populates lazily on open via FETCH_PLACEHOLDERS, streaming per page; parent stays fully populated (does not re-request forever) | [ ] | |
| 6 | **Ghost removal on remote delete** — delete an object via the web console, wait a poll | **D-03** | The entry **disappears from Explorer** (on-disk placeholder removed, not just the DB row); no ghost left behind | [ ] | |
| 7 | **Dirty local edit survives a remote delete** — edit a synced file (do NOT let it upload), then delete that object remotely, wait a poll | **D-03** | The locally-edited file is **preserved** (still on disk, still listed); your un-uploaded edits are intact | [ ] | |
| 8 | **Remote add appears** — add an object remotely, wait a poll | D-01/D-02 | The new placeholder appears within ≤ poll interval | [ ] | |
| 9 | **Tray progress readout** — watch the tray/flyout during the first big enumeration and during a hydration | **D-04** | An aggregate readout is observable ("Enumerating N items" / "Hydrating X MB"); it shows **counts/bytes only — never a file name or path**; monotonic, not flickering | [ ] | |
| 10 | **Anchor short-circuit (no-op poll)** — leave the drive idle across ≥2 poll cycles with no remote change | **D-06** | Event Viewer shows `poll unchanged (anchor match)`; no placeholder writes occur on the unchanged polls (steady CPU/IO, no churn) | [ ] | |
| 11 | **Bounded listing, no SlowDown** — open several large prefixes quickly / churn navigation | **D-05** | No S3 503 `SlowDown` in the logs; listings stay bounded (≤4 concurrent per bucket); enumeration still completes | [ ] | |
| 12 | **No use-after-free on drive stop** — pause/remove the drive mid-enumeration | — | Clean teardown; no crash, no AccessViolation in Event Viewer; re-adding re-enumerates cleanly | [ ] | |

---

## 4. Sign-off

| Field | Value |
|-------|-------|
| Build / DLL version | |
| Arch (x64 / ARM64) + Windows build | |
| Seed prefix + object count | |
| Date | |
| Result | ☐ PASS (all matrix items ticked) ☐ FAIL (see observations) |

**Engineer signature:** ______________________________  Date: ____________

> Pass/fail summary (note any deferred items and their tracking issue):
>
> _____________________________________________________________________________
