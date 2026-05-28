# Phase 17: Windows Shell - Context

**Gathered:** 2026-05-28
**Status:** Ready for planning

<domain>
## Phase Boundary

Build a **native WinUI 3** shell + **cfapi Cloud Filter** sync engine in `windows/` so Windows users get the same DS3 Drive experience as macOS/iOS, backed by the same Rust core (`core/`) via **P/Invoke through `ds3_core.dll`** (csbindgen).

End-state: Windows user installs the MSI, signs in (email/password/tenant/2FA), runs the drive setup wizard (project → bucket → prefix), and sees the drive appear in **Windows Explorer's navigation sidebar** with a Cubbit icon. Files hydrate on demand, save uploads trigger via `NOTIFY_FILE_CLOSE_COMPLETION`, remote changes appear on the next polling cycle, the system tray icon + macOS-parity flyout reflects per-drive sync state. Up to 3 drives, conflict copies via ds3-sync, configurable coordinator URL, Explorer sync badges via shell overlay handler — **full feature parity with the shipped macOS app**, modulo platform-specific differences (cfapi vs FileProvider).

POL-01 (cross-FFI logging) is **pulled forward into Phase 17** at the user's request — ETW bridge from Rust `tracing` lands here, not Phase 18. POL-02 (NSFileProviderError mapping redesign) and POL-08 (ARM64 build) stay in Phase 18.

</domain>

<decisions>
## Implementation Decisions

### Cross-cutting principle
- **D-00: Feature parity with macOS is the P17 yardstick.** Every shipped macOS v1.0/v2.0 capability listed in `PROJECT.md` §Validated has a Windows analog in P17, unless explicitly deferred to P18 below. Parity means **behavior + UX flow** parity, not pixel parity — WinUI 3 idioms (Acrylic, Mica, XAML Islands hosting) are preferred over emulating SwiftUI chrome. When in doubt, mirror the macOS information architecture (tray menu items, wizard step order, Settings panel sections) verbatim.

### Solution layout
- **D-01: 3-project C# solution under `windows/`** (matches design spec §2):
  ```
  windows/
  ├── DS3Drive.sln
  ├── DS3Drive.App/        WinUI 3 exe (Pages, ViewModels, Tray, App.xaml)
  ├── DS3Drive.Sync/       Class lib — cfapi provider + C# SyncEngine + change observers
  └── DS3Drive.Core/       Class lib — csbindgen output + idiomatic facade (DS3Session : IDisposable)
  ```
  `DS3Drive.App` → references → `DS3Drive.Sync` → references → `DS3Drive.Core`. cfapi callbacks live in `DS3Drive.Sync` to keep the UI project free of native-callback threading concerns.
- **D-02: Target framework = `.NET 8 LTS`** (`net8.0-windows10.0.19041.0`). LTS through Nov 2026 spans the beta + initial release window. WinUI 3 via WindowsAppSDK ≥ 1.5.
- **D-03: WinUI 3 conventional folder layout** inside `DS3Drive.App/`:
  ```
  Pages/         .xaml + code-behind
  Controls/      UserControls
  ViewModels/    [ObservableProperty]/[RelayCommand] generated VMs
  Services/      ITrayService, INavigationService, ICredentialStore
  Tray/          NotifyIcon host + flyout
  Assets/        Cubbit branding (sidebar icon, tray icon variants, overlay badges)
  ```
- **D-04: MVVM = CommunityToolkit.Mvvm + Microsoft.Extensions.DependencyInjection.** Generated `[ObservableProperty]` / `[RelayCommand]` for all VMs. `Microsoft.Extensions.Hosting` `Host.CreateApplicationBuilder()` builds the DI container at app start. Honors D-05 (Phase 16): platform owns observable wrapper.

### P/Invoke wrapper (DS3Drive.Core)
- **D-05: Two-layer wrapper.**
  - **Internal:** `DS3Native.cs` — csbindgen-generated `[DllImport("ds3_core")]` statics, raw IntPtr/out-params. Not referenced outside `DS3Drive.Core`. Regenerated as part of CI when `ds3-ffi` changes.
  - **Public:** Hand-written idiomatic surface — `DS3Session : IDisposable`, `DS3Drive`, `DS3Project`, `DS3ApiKey` records mapped from C structs; methods throw typed C# exceptions (`DS3AuthenticationException`, `DS3S3Exception`, `DS3TransportException`) parallel to Apple's enum hierarchy (D-12 P16). ViewModels never see `IntPtr` or error codes.
- **D-06: `ds3_core.dll` ships in `DS3Drive.Core/runtimes/win-x64/native/` and `runtimes/win-arm64/native/`.** NuGet-style runtime folder so the dll resolves automatically post-publish. Build pipeline copies the cargo output from `core/target/{x86_64,aarch64}-pc-windows-msvc/$profile/ds3_core.dll`. ARM64 binary built in P17 (parity expectation) but ARM64 *installer* still P18 (POL-08) — researcher confirms acceptable split.
- **D-07: Cargo invoked on every build of `DS3Drive.Core` via MSBuild target** (mirrors D-08/D-09 P16). Debug → `cargo build`, Release → `cargo build --release`. Cargo incremental compile keeps overhead acceptable.

### Login + drive setup wizard (UI parity)
- **D-08: Native WinUI 3 login form** (resolves ROADMAP-vs-design-spec conflict; ROADMAP SC#1 wins). Inputs: email, password (`PasswordBox`), tenant, "Remember me". Calls `ds3_authenticate`. On `TfaRequired` error, navigates to 2FA page. WebView2 path is **not** pulled in for P17; reserved for future OAuth phase.
- **D-09: Wizard pages (all required for P17 — feature parity)**:
  | Step | Page | C ABI |
  |---|---|---|
  | 1 | Sign in | `ds3_authenticate` |
  | 2 (conditional) | **2FA / MFA** | `ds3_authenticate_2fa` |
  | 3 | Tutorial / first-launch onboarding | (local) |
  | 4 | **Project selection** | `ds3_get_projects` |
  | 5 | **Bucket selection** | `ds3_list_buckets` |
  | 6 | Prefix selection | `ds3_list_objects` (delimiter `/`) |
  | 7 | Drive name / confirm | (local) |
  | (post) | API-key reconcile | `ds3_load_api_keys` + `ds3_create_api_key` |
  Step order matches macOS `apple/DS3Drive` flow verbatim. Each page is a `NavigationView` child of `DriveSetupWizardPage`. Cancel returns to drives list.
- **D-10: API-key reconciliation = create-or-find with deterministic name pattern** (port the existing Apple algorithm to C# verbatim). After confirm, the wizard runs reconciliation, persists `DS3ApiKey` + `DS3Drive` rows into SQLite, then registers the cfapi sync root.

### Persistence (Microsoft best-practices for unpackaged WinUI 3)
- **D-11: `Microsoft.Data.Sqlite` at `%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db`** for all structured runtime data (drives, sync anchors, placeholder index, recent activity, account info). Official Microsoft recommendation for native Windows apps with queryable local state. Schema versioning via a `schema_version` PRAGMA + migration scripts in `DS3Drive.Sync/Migrations/`. Tables map 1:1 to `ds3-models` types.
- **D-12: Windows Credential Manager** (`CredWrite` / `CredRead` via `Advapi32.dll` P/Invoke) for `secretKey` + `refreshToken`. MS-recommended for **unpackaged** apps (`PasswordVault` requires MSIX, which WiX/MSI doesn't yield). User-scoped, OS-sealed, visible in Control Panel → Credential Manager for user transparency. Target name: `Cubbit DS3 Drive — <accountId>`.
- **D-13: `appsettings.json`** (Microsoft.Extensions.Configuration) only for **build-time / install-time defaults** (default coordinator URL, log level). User-mutable settings (custom coordinator URL, drive prefs) live in SQLite.
- **D-14: No JSON files for runtime data.** Apple JSON pattern (`SharedData`) stays Apple-side; Windows uses the MS-native stack. Domain types are the contract; storage layers differ per platform.

### Sync engine (DS3Drive.Sync)
- **D-15: C# `SyncEngine` runs in-process** (cfapi callbacks must execute in the process that registered the sync root). Worker-process IPC pattern rejected — pure overhead with no isolation win.
- **D-16: cfapi callback wiring** (per design spec §"cfapi Integration"):
  - `CF_CALLBACK_TYPE_FETCH_DATA` → C# delegates → `DS3Session.DownloadObject(...)` → streams to `CfExecute(TRANSFER_DATA)` in chunks. Streaming required to stay under cfapi's 30-second timeout.
  - `CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION` → enqueue upload to `SyncEngine`. **Do not** use `ReadDirectoryChangesW` for upload triggers — fires for hydration writes too.
  - `CF_CALLBACK_TYPE_NOTIFY_RENAME` / `NOTIFY_DELETE` → enqueue rename / delete.
  - Post-hydration: `CfSetInSyncState` is mandatory.
- **D-17: Sync engine consumes `ds3_compute_diff` in-process via P/Invoke.** Rust returns the diff actions; C# applies them — creates placeholders, hydrates, materializes conflict copies (`ds3_conflict_key` for naming).
- **D-18: Polling cadence** — periodic remote poll runs every **60 seconds per drive** by default (researcher may revise based on cfapi performance + tenant rate limits). Per-drive timer; pauses while drive is paused.
- **D-19: Sync state badges in Explorer = shell icon overlay handler.** Implement `IShellIconOverlayIdentifier` COM in-proc server inside `DS3Drive.Sync` (or split into a separate `DS3Drive.ShellExtension` class lib if COM registration requires it — researcher decides). Four states match Finder: synced, syncing, error, cloud-only. **Note for researcher:** Windows hard-caps the system to 15 overlay handlers; OneDrive, Dropbox, Google Drive already compete for slots. Document this risk in RESEARCH.md.

### Tray + drive surface
- **D-20: System tray = `H.NotifyIcon` (or equivalent WinUI 3-compatible NotifyIcon library)** — WinUI 3 has no built-in NotifyIcon. Researcher picks the library, prioritizing maintenance status + license compatibility.
- **D-21: Tray icon overlays** — Cubbit base + state badge (idle/syncing/error). Same icon family as Explorer overlays; assets shared.
- **D-22: macOS-parity flyout** (full activity center, not deferred to P18). Components:
  - Per-drive row: name, bucket/prefix, status pill, transfer speed, pause/resume toggle, "Open in Explorer" action
  - Recent files list (top 5, per drive)
  - "Add drive" button (until limit of 3 reached)
  - Settings, Help, Quit
  Layout mirrors macOS `TrayDriveRowView` IA.
- **D-23: Up to 3 drives.** Each drive registers an independent cfapi sync root, has its own row in the flyout, its own pause/resume state, its own polling timer. POL-03 (Phase 18) becomes refinement (e.g., per-drive bandwidth controls), not multi-drive bring-up.

### Settings, tutorial, lifecycle (full macOS parity)
- **D-24: Settings page** — sections: Account (display name, email, sign out), Coordinator URL (editable text input, defaults from `appsettings.json`), Drives (table → matches drives list, remove/reconfigure), Logging (verbosity slider + "Open log folder"). Mirrors macOS Preferences sections.
- **D-25: Tutorial / first-launch view** — single page with same step copy as macOS `TutorialView`, shown after first successful login. Skippable.
- **D-26: Auto-start at login** — WiX MSI writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` registry entry pointing to `DS3Drive.App.exe`. User can disable in Settings. Survives uninstall (key removed by WiX on uninstall).
- **D-27: Single-instance enforcement** — named `Mutex` on app start; subsequent launches focus the existing tray icon's flyout. Matches macOS menu bar app behavior.

### Installer (WIN-09)
- **D-28: WiX v4 MSI** (WiX v5 has wider-ranging breaking changes; v4 is stable + widely deployed for enterprise). Single MSI, x64 only in P17 (ARM64 MSI = POL-08, P18 — split per D-06). Silent install via `/qn`. Components: `DS3Drive.App` exe + dependencies, `ds3_core.dll`, COM registration for shell overlay handler, Start Menu shortcut, Run-at-login reg key, uninstaller.
- **D-29: Code signing** — Windows Authenticode cert (Cubbit's existing or to be procured). Required for SmartScreen and Credential Manager target name display. Researcher confirms cert procurement timeline; if unavailable for P17 beta, ship unsigned with documented SmartScreen warning. Signing infra = P18 polish if needed.

### Cross-FFI logging (POL-01 pulled into P17)
- **D-30: Rust `tracing` → ETW bridge implemented in P17.** Adds a Rust-side callback in `ds3-ffi` (`ds3_set_log_callback(fn(level, target, message))`) — backward-compatible Phase 15 surface extension. C# side wires it to `EventSource` with provider name `Cubbit-DS3Drive-Core`. **Researcher must confirm Phase 15 surface allows this addition or flag it as a `core/` workstream within P17.**
- **D-31: C# logging = `Microsoft.Extensions.Logging` → `EventSource`** with provider name `Cubbit-DS3Drive-App`. Single Event Viewer story: filter by `Cubbit-DS3Drive-*` provider. No file-log requirement for P17 (Settings → "Open log folder" exports a `wevtutil`-collected `.evtx` on demand).

### Manual testing
- **D-32: Primary dev / test environment = Windows 11 ARM64 VM on Apple Silicon** (Parallels / UTM). cfapi works inside the VM without nested virt. Slowest dev loop, but always available on the engineer's existing Mac. CI builds run in parallel on GitHub Actions `windows-latest` (x64).
- **D-33: Manual smoke checklist (parity with macOS APPLE-05 smoke test)** — every wizard step, hydrate-on-double-click, save → upload (verify no spurious re-upload after hydration), rename, move, delete, conflict copy, pause/resume, multi-drive setup (2 + 3 drives), Explorer badge states across all four states. Required before P17 ships.

### Claude's Discretion
- **C# version inside `net8.0-windows`:** Researcher picks (C# 12 default; C# 13 if a specific feature warrants).
- **NotifyIcon library:** Researcher picks (`H.NotifyIcon`, `WPF-Notifyicon`, custom) — criteria: maintenance, license, WinUI 3 compatibility.
- **Shell overlay handler housing:** Inside `DS3Drive.Sync` vs split `DS3Drive.ShellExtension` project. Driven by COM out-of-proc requirements + DLL surrogate behavior in Explorer.
- **Polling cadence default** (D-18): 60s is a starting point; researcher may revise.
- **cfapi placeholder index in SQLite** — schema design (one row per item vs. nested JSON in a column). Researcher decides based on query patterns and item counts.
- **Authenticode cert procurement timing** (D-29).
- **Cubbit branding asset preparation** — sidebar icon, tray icon variants (8 sizes × 4 states), overlay badge icons. Provided by design team or generated from existing macOS assets — confirm during planning.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture & Design
- `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md` §"Phase 3: Windows Shell" + §"cfapi Integration" + §"Cross-Cutting Concerns" — Master design spec. PRIMARY reference.
- `.planning/REQUIREMENTS.md` §WIN-01 through §WIN-09 — Phase 17 requirements with success criteria. Also §POL-01 (logging — pulled into P17), §POL-03/POL-04 (P18 polish for multi-drive + tray — bounded against P17 here), §POL-08 (ARM64 installer — P18).
- `.planning/ROADMAP.md` §"Phase 17: Windows Shell" — Goal, dependencies, success criteria.
- `.planning/phases/15-rust-core-ffi-foundation/15-CONTEXT.md` — Phase 15 decisions Phase 17 inherits (C ABI surface, csbindgen, cookie-jar HTTP, multipart, panic guards).
- `.planning/phases/16-apple-incremental-swap/16-CONTEXT.md` — Phase 16 decisions: D-05 cross-platform observable+credential pattern (Apple/Windows/Android table), D-15 2FA error mapping (same `TfaRequired` code), D-17 panic mapping, D-18 retry policy (Rust-side; Windows inherits).

### Rust Core (Phase 15 output — Windows targets these directly)
- `core/ds3-ffi/src/c_exports.rs` — **PRIMARY surface for Windows.** All P/Invoke calls target functions defined here (`ds3_authenticate`, `ds3_authenticate_2fa`, `ds3_get_projects`, `ds3_list_buckets`, `ds3_list_objects`, `ds3_download_object`, `ds3_upload_object`, `ds3_delete_object`, `ds3_copy_object`, `ds3_load_api_keys`, `ds3_create_api_key`, `ds3_session_destroy`, etc.). Confirm `ds3_compute_diff` + `ds3_conflict_key` are exposed on the C ABI (may currently be UniFFI-only — researcher verifies).
- `core/ds3-ffi/src/panic_guard.rs` — Panic catch wrapper applied to every C export. Windows inherits the same guarantee.
- `core/ds3-ffi/src/cancellation.rs` — Cancellation token (Phase 16 D-20). Windows wraps it as `CancellationToken` parallel to .NET's.
- `core/ds3-ffi/src/progress.rs` — `DS3ProgressCallback` C function pointer signature. Required for `CfReportProviderProgress` and tray transfer speed display.
- `core/ds3-models/src/error.rs` — `DS3Error` numeric codes (1001-1099 auth, 2001-2099 S3, 3001-3099 transport). `DS3Drive.Core` translates these to C# exception types parallel to Apple's enums.
- `core/scripts/` — Build scripts. P17 adds a `build-dll-windows.{ps1,sh}` analog to `build-xcframework.sh`.

### Apple Reference (for feature-parity porting)
- `apple/DS3Drive/` — macOS app source. UI flows, tray menu structure, Settings layout, Tutorial copy. Verbatim parity target for D-08 through D-27.
- `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` — auth flow + 2FA + tenant + remember-me logic. Port the lifecycle math to C#.
- `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` — projects + API-key reconciliation algorithm. Port deterministic key-name pattern verbatim.
- `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` — drive registration + lifecycle. C# `DriveManager` mirrors.
- `apple/DS3DriveProvider/` — FileProvider extension. Behavioral reference for cfapi mappings (D-16) — what events map where.

### Codebase Maps
- `.planning/codebase/ARCHITECTURE.md` — Apple MVVM, layer boundaries. Windows mirrors the layering.
- `.planning/codebase/INTEGRATIONS.md` — Cubbit IAM, Composer Hub, KeyVault, DS3 endpoints. Same endpoints, accessed via Rust.
- `.planning/codebase/STACK.md`, `STRUCTURE.md`, `TESTING.md` — Conventions Windows aligns to where applicable.

### Project Conventions
- `CLAUDE.md` (root) — Repo overview, debugging conventions. Windows app adds a `windows/` section after P17.
- `.claude/projects/-Users-marmos91-Projects-cubbit-ds3-drive/memory/MEMORY.md` — Project memory. The "DS3Lib must stay OS-agnostic" / platform-portability rules apply to the Rust core too — Windows code lives entirely in `windows/`.

### External / Microsoft Documentation (researcher MUST read)
- Microsoft Learn → **"Build Cloud Files API for Windows"** (cfapi placeholder lifecycle, `CF_CALLBACK_TYPE_*`, `CfRegisterSyncRoot`, in-sync state, hydration ranges).
- Microsoft Learn → **"WinUI 3 / Windows App SDK"** (XAML, dependency property model, deployment options for unpackaged apps).
- Microsoft Learn → **"Use a SQLite database in a Windows app"** + `Microsoft.Data.Sqlite` package docs.
- Microsoft Learn → **"Windows Credential Manager"** + `CredWrite` / `CredRead` Win32 API reference.
- Microsoft Learn → **"Shell Icon Overlay Identifiers"** + the 15-handler system cap.
- WiX Toolset v4 documentation (per-user MSI, `RegistryValue` for Run key, `Component` ordering for COM registration).
- csbindgen README + canonical examples (multi-target build, runtime folder convention).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets (from prior phases)
- **`core/ds3-ffi/src/c_exports.rs`** — ~20 C ABI functions already shipped in Phase 15. Phase 17 is largely a C# consumer of this surface. **Gap to investigate:** confirm `ds3_compute_diff`, `ds3_conflict_key`, and the cancellation token are reachable through the C ABI (not UniFFI-only). If gaps exist, treat the additions as in-scope `core/` workstreams for P17.
- **`core/ds3-models/src/`** — Domain types Windows maps 1:1 to C# DTOs.
- **`core/scripts/build-xcframework.sh`** — Pattern for the `build-dll-windows.{ps1,sh}` analog: target triples `x86_64-pc-windows-msvc` + `aarch64-pc-windows-msvc`, output to `core/out/windows/{x64,arm64}/ds3_core.dll`.
- **Apple-side observable + DPAPI pattern** (Phase 16 D-04/D-05) — Windows reimplements the same shell: `ObservableObject` (CommunityToolkit.Mvvm) for `AuthenticationViewModel`, Credential Manager for token storage, all internals delegate to `DS3Session`.
- **API-key reconciliation algorithm** in `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` — deterministic name pattern + create-or-find logic. Port verbatim to C#.
- **macOS tray IA + drive-row layout** (`apple/DS3Drive/TrayDriveRowView.swift`) — direct reference for WinUI 3 flyout. Information density, status pill, transfer-speed labels, gear menu items.
- **macOS Tutorial copy + step IA** (`apple/DS3Drive/TutorialView.swift`) — reuse copy.

### Established Patterns
- **Protocol-conformance / interface swap:** Apple uses `DS3S3ClientProtocol`; Windows uses C# `IDS3S3Client` interfaces around the P/Invoke layer for the same testability win.
- **Domain models = Rust source of truth.** Both Swift (UniFFI) and C# (csbindgen) generate platform DTOs from `ds3-models`. Schema drift caught at FFI codegen time.
- **OS-native secure storage:** Apple → App Group container; Windows → Credential Manager. Rust never owns persistence (Phase 16 D-06).
- **No custom error types over the platform boundary:** Apple FileProvider rejects custom error types (`NSFileProviderErrorDomain`/`NSCocoaErrorDomain` only); Windows cfapi expects `HRESULT`. Errors translate at the boundary in both.
- **OSLog `privacy: .public`** lesson on Apple side → Windows ETW: use structured event arguments, not string-interpolated PII. Event Viewer payload visibility is friendlier than os_log, but the discipline still applies.

### Integration Points
- `core/Cargo.toml` workspace — `ds3-ffi` crate already builds a `cdylib`. P17 adds Windows target triples + the build-dll script.
- `core/ds3-ffi/Cargo.toml` — may need `csbindgen` build-dep added if the header generation lives here (alternative: generate inside `windows/DS3Drive.Core` MSBuild target).
- `.github/workflows/` — add a `windows-build.yml` (or extend the existing matrix) for `windows-latest` builds + smoke. C# integration test from Phase 15 (D-08) lives here.
- `apple/` — **unchanged by P17**. Phases 16 (Apple swap) and 17 (Windows shell) are explicitly parallel-safe per ROADMAP execution order `15 → 16 + 17 (parallel) → 18`.
- `windows/` — **currently empty** (created by Phase 15 mono-repo restructure). P17 lights it up.

</code_context>

<specifics>
## Specific Ideas

- **Wizard step order matches macOS verbatim** (D-09 table). Researcher does not reorder; if a step is technically awkward on Windows, surface it as a planning-time question, don't silently rearrange.
- **Explorer sync badges are a P17 requirement.** Not optional. The 15-overlay-handler cap is a documented risk, not a reason to defer.
- **POL-01 (cross-FFI logging) is in P17 scope** per user direction. The Rust-side log-callback bridge is in-scope. If this expands the Phase 15 FFI surface meaningfully (estimated: ~2 small additions to `c_exports.rs`), treat it as a `core/` workstream inside P17, not a Phase 15 retroactive patch — preserves the "Phase 15 = stable C ABI surface" property going forward.
- **POL-08 (ARM64 Windows installer)** stays in Phase 18 per ROADMAP, BUT the **ARM64 `ds3_core.dll`** is built in P17 (parity expectation, low marginal cost — same cargo invocation with `--target aarch64-pc-windows-msvc`). Researcher confirms acceptable.
- **2FA path must stay byte-identical from a user's perspective** vs macOS. Phase 16 D-15 mapped `TfaRequired` → `.missing2FA` for Swift; Windows maps the same numeric code → `DS3AuthenticationException(reason: TwoFactorRequired)` for C#.
- **Manual smoke test required before P17 ships** (D-33) — parity with APPLE-05 / D-24 from Phase 16. Mirror the checklist.
- **Cubbit branding assets** (sidebar icon for Explorer nav pane, tray icon variants, four overlay badge states) — confirm source during planning. If macOS PDF/SVG masters exist, generate Windows ICO + PNG sets from them; if not, design team produces.

</specifics>

<deferred>
## Deferred Ideas

- **Multi-drive polish** (POL-03 Phase 18) — P17 ships up-to-3 drives functional; POL-03 covers per-drive bandwidth controls, advanced pause-schedule, drive-level coordinator-URL overrides.
- **NSFileProviderError / cfapi `HRESULT` mapping redesign** (POL-02 Phase 18) — P17 uses the obvious mapping (`DS3Error` numeric code → `HRESULT_FROM_WIN32` or custom `HRESULT` per category). Phase 18 may redesign once both platforms are running.
- **ARM64 Windows MSI installer** (POL-08 Phase 18) — `ds3_core.dll` arm64 build in P17, but MSI installer pipeline (Authenticode-signed ARM64 MSI) is Phase 18.
- **Auto-update mechanism** (POL-06 Phase 18) — Sparkle on Mac / Squirrel.Windows or WiX bootstrapper. P17 ships installer-replace-on-new-MSI flow; no in-app update prompt.
- **WebView2-based OAuth login** — Future phase when Google/MS OAuth lands. P17 stays native form only.
- **Italian / non-English localization** — Matches macOS deferred state; P17 ships English only.
- **Spotlight / Cortana integration** — Out of milestone scope per PROJECT.md §Out of Scope.
- **Push-based remote change detection** (Windows analog of PushKit) — Phase 17 uses periodic polling per D-18.

</deferred>

---

*Phase: 17-Windows Shell*
*Context gathered: 2026-05-28*
