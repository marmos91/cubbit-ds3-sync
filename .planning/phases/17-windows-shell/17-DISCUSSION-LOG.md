# Phase 17: Windows Shell - Discussion Log

**Date:** 2026-05-28
**Mode:** default (interactive)

---

## Areas Selected

User selected all four proposed gray areas + added a fifth ("Code structure and design. How to manual test"):

1. Solution structure
2. Login UI conflict
3. Sync state persistence
4. Tray + drive scope for P17
5. Code structure & manual testing

---

## Q&A

### Area 1 — Solution structure

**Q1: C# solution layout under `windows/` — how many projects?**
Options: 3-project split (App + Sync + Core) / 2-project split / single project.
**Selected: 3-project split.**

**Q2: .NET / C# version?**
Options: .NET 8 LTS / .NET 9.
**Selected: .NET 8 LTS.**

**Q3: `DS3Drive.Core` P/Invoke wrapper shape — csbindgen + facade / raw csbindgen / hand-written?**
**User answer:** "Help me choose. Choose most stable and cleanest solution."
**Claude's pick (locked):** csbindgen + thin idiomatic facade. Two-layer split: internal `DS3Native.cs` (generated, raw `[DllImport]`), public `DS3Session : IDisposable` (hand-written, typed C# exceptions). No drift on Phase-15 FFI changes; no `IntPtr` leakage into ViewModels.

**Q4: How does `DS3Drive.Sync` invoke `ds3-sync` — in-process or worker-process IPC?**
**User answer:** "Help me choose, I want the cleanest solution."
**Claude's pick (locked):** In-process P/Invoke. cfapi callbacks must run in the registered process anyway; IPC adds rerouting overhead with no isolation benefit at this stage.

### Area 2 — Login UI conflict

**Q5: ROADMAP says native WinUI 3 form; design spec says WebView2. Pick one.**
Options: Native form (recommended) / WebView2 / Native now + WebView2 reserved.
**Selected: Native WinUI 3 form.** ROADMAP SC#1 wins. WebView2 reserved for future OAuth phase.

### Area 3 — Persistence

**Q6: Where does Windows sync state live?**
Options: JSON files mirroring Apple / SQLite via rusqlite (Rust) / SQLite via Microsoft.Data.Sqlite (C#).
**First selection: JSON files mirroring Apple.**
**User mid-area correction:** "For persistence choose Microsoft best practices for native applications."
**Revised selection (locked):** `Microsoft.Data.Sqlite` at `%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db` for all structured runtime data. `appsettings.json` only for build-time defaults. No JSON files for runtime state. Domain models from Rust `ds3-models`; storage layer differs per platform.

**Q7: Credential storage — DPAPI-sealed JSON or Windows Credential Manager?**
First answer: DPAPI-sealed JSON.
**Revised to honor MS-best-practices direction:** Windows Credential Manager (`CredWrite` / `CredRead` via Advapi32 P/Invoke). MS-recommended for unpackaged apps (PasswordVault requires MSIX, which WiX/MSI doesn't deliver). User-visible in Control Panel → Credential Manager.

### Area 4 — Tray + drive scope

**Q8: Drive count for P17 — single drive or up to 3?**
Options: Single drive / Up to 3 (parity with macOS).
**Selected: Up to 3 drives.** POL-03 (Phase 18) becomes refinement only.

**Q9: Tray scope — status icon + minimal menu / status icon only / macOS-parity flyout?**
**Selected: macOS-parity flyout** (drive rows, status, speed, recents, pause/resume, settings, quit). POL-04 (Phase 18) becomes refinement only.

**Mid-area user input:** "The UI should match the one of Macos."
**Captured as cross-cutting D-00:** Feature + UX-flow parity with macOS is the P17 yardstick; WinUI 3 idioms preferred over emulating SwiftUI chrome, but information architecture mirrors macOS verbatim.

### Area 5 — Code structure & manual testing

**Q10: How to manually test cfapi (no macOS dev environment runs cfapi)?**
Options: Windows 11 VM on Apple Silicon / Dedicated Windows box / GH Actions + tester team.
**Selected: Windows 11 VM on Apple Silicon (Parallels / UTM).** CI on `windows-latest` for x64 build.

**Q11: MVVM library + DI container?**
Options: CommunityToolkit.Mvvm + MS-DI (recommended) / plain INotifyPropertyChanged.
**Selected: CommunityToolkit.Mvvm + Microsoft.Extensions.DependencyInjection.** Honors Phase 16 D-05.

**Q12: Code organization — mirror Apple folder layout / WinUI 3 conventional / feature-folders?**
**Selected: WinUI 3 conventional** (`Pages/`, `Controls/`, `ViewModels/`, `Services/`).

**Q13: Logging — minimum P17 (C# EventLog) / full cross-FFI bridge now / Serilog?**
**Selected: Full cross-FFI bridge now (Rust `tracing` → ETW + C# `ILogger` → ETW).** Pulls POL-01 into P17. Single Event Viewer story from day one. Expands Phase 15 FFI surface (new `ds3_set_log_callback`) — researcher confirms approach.

### User additions mid-discussion (parity scope)

**"Add also windows views to do mfa, project and bucket selections to create drives"**
Captured in D-09: drive setup wizard requires all macOS-parity views — Login → 2FA / MFA → Tutorial → Project → Bucket → Prefix → Confirm. Mapped to C ABI calls (`ds3_authenticate`, `ds3_authenticate_2fa`, `ds3_get_projects`, `ds3_list_buckets`, `ds3_list_objects`).

**"Feature parity with macos"**
Captured as D-00 (cross-cutting principle). Pulled-in items beyond ROADMAP SC#1-5: Explorer sync badges (shell overlay handler), Settings page (account / coordinator URL / drives / logging), Tutorial first-launch view, auto-start at login (WiX writes Run reg key), conflict copies via ds3-sync + C# materialization, configurable coordinator URL, single-instance enforcement. Localization scoped to English only (matches macOS deferred state).

---

## Claude's Discretion Items (delegated to researcher)

- C# language version inside `net8.0-windows` target.
- NotifyIcon library pick (D-20).
- Shell overlay handler housing — in `DS3Drive.Sync` vs split `DS3Drive.ShellExtension` (D-19).
- Polling cadence default (D-18 says 60s starting point).
- SQLite placeholder index schema design (one row per item vs nested JSON column).
- Authenticode cert procurement timing (D-29).
- Cubbit branding asset preparation pipeline.

---

## Deferred Ideas (captured for Phase 18 / future)

- POL-03 multi-drive polish (per-drive bandwidth, advanced pause-schedule).
- POL-02 NSFileProviderError / cfapi `HRESULT` mapping redesign.
- POL-08 ARM64 MSI installer (ARM64 `ds3_core.dll` built in P17).
- POL-06 auto-update mechanism.
- WebView2-based OAuth login.
- Italian / non-English localization.
- Push-based remote change detection.

---

*End of discussion log.*
