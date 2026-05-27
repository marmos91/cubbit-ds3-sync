# Research Summary: v2.0.0 Cross-Platform Rewrite (Rust Core + Windows Shell)

**Milestone:** v2.0.0 Cross-Platform
**Synthesized:** 2026-05-26
**Sources:** STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md
**Overall confidence:** HIGH (Rust core + UniFFI + cfapi all verified against official docs and production post-mortems)

---

## Executive Summary

DS3 Drive v2.0.0 introduces a Rust workspace (`core/`) that replaces Swift-only DS3Lib internals for S3 operations and authentication, while simultaneously shipping a new Windows sync client built on WinUI 3 and the Cloud Filter API (cfapi). The Rust core is consumed by existing Apple apps via UniFFI-generated Swift bindings and by the new Windows shell via `csbindgen`-generated C# P/Invoke. The FileProvider extension on Apple stays entirely untouched — only the main-app-facing DS3Lib internals are swapped. This is a deliberate incremental strategy: replace the concrete type behind `DS3S3ClientProtocol`, not the protocol or the extension.

The technology bets are well-validated. `aws-sdk-s3 v1` is the GA official Rust SDK with first-class S3-compatible endpoint support that Cubbit's per-tenant gateways require. UniFFI 0.29.5 (not 0.31) is the correct pin because `uniffi-bindgen-cs` targets 0.29.4 and using a newer version creates checksum mismatches. `csbindgen` is chosen over hand-written P/Invoke and over `uniffi-bindgen-cs` because it auto-generates correct C# marshalling including UTF-8 strings and function pointer types for progress callbacks — eliminating an entire class of production crash bugs. WinUI 3 with WindowsAppSDK 1.8 (not the 2.0 preview) paired with cfapi provides deep Windows shell integration that FUSE, Electron, and Avalonia cannot match. WiX v7 MSI covers enterprise deployment requirements.

The principal risk is the FFI boundary itself, not the feature set. Six of the ten critical pitfalls are FFI-specific: nested tokio runtimes, panics crossing the ABI, UniFFI Swift 6 isolation failures, session handle leaks, string marshalling corruption, and CRT heap mismatch on Windows. All are preventable with established patterns that must be established in Phase 1 before any feature code is written. cfapi is 2-3x more complex than Apple's FileProvider — the placeholder state machine has more states, more edge cases, and shorter timeouts — but its complexity is well-documented and the three most dangerous failure modes (missing `CfSetInSyncState`, FETCH_DATA timeout, and spurious upload loop) all have deterministic preventions.

---

## 1. Stack Decisions

### Rust Core (`core/` Cargo workspace)

| Technology | Version | Rationale |
|------------|---------|-----------|
| `aws-sdk-s3` | 1 (1.132.0) | Official GA SDK; first-class `force_path_style` + `endpoint_url` for Cubbit per-tenant gateways. |
| `aws-config` | 1 (1.8.16) | Required companion for `SdkConfig` builder. |
| `ed25519-dalek` | 2.2 | Pure Rust, audited, 57M+ downloads. Direct replacement for CryptoKit `Curve25519.Signing`. |
| `jsonwebtoken` | 10 (10.3.0) | Pluggable crypto backend (`rust_crypto` feature) avoids pulling `aws-lc-rs` in twice. |
| `reqwest` | 0.13 | Non-S3 HTTP: auth endpoints, project listing, API key management. Shares tokio + rustls. |
| `tokio` | 1 (pin LTS 1.51) | One runtime per `DS3Session` — never global static, never nested `block_on`. |
| `serde` + `serde_json` | 1 | Reads existing `drives.json` / `credentials.json` schemas unchanged. |
| `thiserror` | 2 | `#[derive(Error)]` across all crates. |
| `tracing` + `tracing-oslog` | 0.1 / 0.3.0 | Bridges to `os_log` on Apple; preserves `log show` subsystem/category filtering. |
| `rusqlite` (bundled) | 0.38 | Windows-only sync anchor persistence. `cfg(target_os)` excludes from Apple targets. |
| `uniffi` | 0.29.5 | Pin exactly. 0.30+ breaks uniffi-bindgen-cs checksum compatibility. |
| `csbindgen` | 1.9.3 | Auto-generates C# P/Invoke from `extern "C" fn`. Eliminates string marshalling and CRT ownership pitfalls. Preferred over `cbindgen` alone or `uniffi-bindgen-cs`. |

**MSRV:** 1.85.0 (required by reqwest 0.13). **Rust edition:** 2024.

**Binary size concern:** `aws-sdk-s3` + `aws-lc-rs` adds ~20 MB before stripping. Apply `strip = true`, `lto = true`, `codegen-units = 1`, `opt-level = "z"` in release profile. Evaluate `reqwest + aws-sigv4` as a lighter alternative if the iOS extension's ~50 MB app thinning limit is threatened.

### UniFFI (Swift path)

Pin to 0.29.5. Use proc-macros (`#[uniffi::export]`, `#[derive(uniffi::Object)]`), not UDL files. Set `default_isolation = "nonisolated"` in `uniffi.toml` to prevent Swift 6 strict concurrency build failures. XCFramework assembly orchestrated via `cargo xtask xcframework`.

### csbindgen (C# path)

Reads `extern "C" fn` declarations from `ffi_exports.rs`, outputs `NativeMethods.g.cs` with correct `[DllImport]` wrappers, UTF-8 string marshalling, calling conventions, and function pointer types for progress callbacks. Runs from `ds3-ffi/build.rs` automatically during `cargo build`. Output committed to `windows/DS3Drive.Core.Interop/`.

### Windows Shell

| Technology | Version | Rationale |
|------------|---------|-----------|
| WindowsAppSDK | 1.8.8 | Current stable WinUI 3. Do NOT use 2.0 preview (requires .NET 10). |
| .NET | 8.0 LTS | Stable until Nov 2026. WinUI 3 1.8 supports it. |
| CsWinRT | 2.2.0 | WinRT projections for cfapi `StorageProviderSyncRootManager`. Do NOT use 3.0 preview. |
| AdysTech.CredentialManager | 3.1.0 | DPAPI-encrypted credential storage. Never plaintext config files. |
| H.NotifyIcon.WinUI | latest | System tray icon (WinUI 3 has no native tray API). Evaluate at implementation time. |
| WiX Toolset | 7.0.0 | MSI installer; per-machine install; silent install (`/qn`) for enterprise. |

**cfapi access:** WinRT (`StorageProviderSyncRootManager`) for sync root registration. Win32 P/Invoke to `cldapi.dll` for callback-heavy placeholder lifecycle. Same dual-surface pattern as Microsoft's Cloud Mirror sample.

---

## 2. Feature Priorities

### Table Stakes for Windows (required for first beta, ordered by dependency)

1. Rust core FFI working from C# — nothing else functions without this
2. Login flow: WinUI 3 native form (not WebView2) → Rust `authenticate` + `verify_2fa` + DPAPI credential storage
3. Drive setup wizard: project / bucket / prefix selection via Rust FFI
4. cfapi sync root registration: Explorer sidebar entry with Cubbit icon (automatic from registration)
5. Placeholder creation + hydration: `FETCH_DATA` → Rust `download_object` (streaming chunks) → `CfExecute(TRANSFER_DATA)` → `CfSetInSyncState`
6. Upload on local change: `NOTIFY_FILE_CLOSE_COMPLETION` (not `ReadDirectoryChangesW`) → Rust `upload_object`
7. Remote polling + diff: periodic `list_objects` → `compute_diff` → update placeholders
8. System tray icon: idle / syncing / error states
9. Hydration progress: `CfReportProviderProgress` per chunk
10. MSI installer: silent install capable, auto-start registry entry

### What Comes Free from cfapi (no implementation cost)

- Navigation pane sidebar entry (automatic from registration)
- Status column icons: blue cloud, green check, solid green circle (automatic from correct placeholder management; no overlay handler, no 15-slot limit problem)
- Context menu verbs: "Always keep on this device" / "Free up space" (automatic)
- Storage Sense auto-dehydration (automatic from correct placeholder management)

### Phase 2 — Required for Public Release

Tray flyout with activity center, pause/resume sync, settings panel, conflict resolution (conflict copies via `ds3-sync`), multi-drive support (up to 3 sync roots), uninstaller cleanup, error handling + toast notifications.

### Defer to Post-GA

Custom cfapi state icons, ETW structured logging, OAuth login (backend not ready), auto-update (Squirrel.Windows or WiX burn), bandwidth throttling, copy hook handler, share handler (presigned URL), cloud file search handler (Windows 11 24H2 only).

### Anti-Features (do not build)

In-app file browser, custom minifilter driver, real-time file locking, legacy icon overlay handlers, FUSE/WinFsp, always-sync-everything full local mirror, Linux support in this milestone, MSIX-only distribution, interactive merge dialog.

---

## 3. Architecture Highlights

### Mono-Repo Layout

```
DS3Drive/
+-- core/       Cargo workspace (ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi, xtask)
+-- apple/      Existing Xcode project (moved from repo root)
+-- windows/    .NET 8 solution (DS3Drive.App, DS3Drive.Sync, DS3Drive.Core, DS3Drive.Core.Interop)
```

### Rust Crate Responsibilities

| Crate | Responsibility |
|-------|---------------|
| `ds3-models` | Shared types: `Drive`, `SyncAnchor`, `Project`, `IAMUser`, `DS3ApiKey`, `Account`, `Token`, `Challenge` |
| `ds3-http` | reqwest client + cookie jar + retry (shared by auth and S3) |
| `ds3-auth` | Cubbit IAM challenge-response (ed25519-dalek + JWT) → opaque `DS3Session` |
| `ds3-s3` | All S3 operations: list, get, put, multipart, delete, copy, presign |
| `ds3-sync` | Pure diff engine (`EnumerationDiff` port) + conflict key generation — no I/O |
| `ds3-ffi` | FFI surface: UniFFI proc-macros (Swift) + `extern "C"` exports (C#) |
| `xtask` | XCFramework assembly, csbindgen output copy, CI helpers |

`ds3-ffi` produces both `staticlib` (Apple XCFramework) and `cdylib` (`ds3_core.dll` for Windows) from the same crate via `crate-type = ["staticlib", "cdylib"]`.

### Dual FFI Pattern

`ds3-ffi` contains two parallel export modules calling the same underlying crate functions:

1. **`uniffi_exports.rs`** — `#[uniffi::export]` proc-macros on `DS3Session`. Async methods. UniFFI bridges Swift `async/await` to Rust futures. No `block_on` needed.
2. **`ffi_exports.rs`** — `#[no_mangle] extern "C" fn` declarations. Synchronous; each calls `session.block_on(async { ... })`. `csbindgen` reads this file to generate `NativeMethods.g.cs`.

### Swap Seam on Apple

`DS3S3ClientProtocol` is the existing abstraction seam. The FileProvider extension calls through this protocol and is never aware of what is behind it. The swap replaces the concrete conforming type with a Rust-backed implementation. The FileProvider extension is not touched.

**Changes to DS3Lib:** `DS3S3Client` internals, `DS3Authentication.signChallenge/getChallenge/refreshIfNeeded`, `DS3SDK.getRemoteProjects/loadOrCreateDS3APIKeys` — all become UniFFI calls. Soto removed from DS3Lib (stays in FileProvider extension). CryptoKit removed from DS3Lib.

**Stays Swift forever:** `DS3DriveManager` (`NSFileProviderDomain`), `MetadataStore` (SwiftData), `SharedData` (App Group IPC), all FileProvider extension files, all SwiftUI views, `DS3Thumbnails`.

### cfapi Integration Points

- `HydrationPolicy = FULL`: fetch entire file on access (matches FileProvider behavior, simplest)
- `PopulationPolicy = FULL`: populate all placeholders immediately on connect (best Explorer UX)
- File identity = S3 key (1:1 with Apple's `NSFileProviderItemIdentifier.rawValue` pattern)
- Upload trigger = `NOTIFY_FILE_CLOSE_COMPLETION` only (not `ReadDirectoryChangesW`)
- Sync anchor = `rusqlite` in Rust (`ds3-sync` crate) for future Android portability

### Tokio Runtime per Session

`DS3Session` owns one `tokio::runtime::Runtime` (4 worker threads). Created at `authenticate()`. Destroyed on session drop. All FFI functions call `session.block_on()`. Never a global static runtime (blocks clean logout/re-login). Never nested `block_on` (tokio panics → process abort via UB).

### Build Pipeline Sequence

1. `cargo build -p ds3-ffi --release` for each Apple target triple
2. `lipo` fat libraries (macOS universal, iOS simulator)
3. `uniffi-bindgen generate` → Swift source + module map
4. `xcodebuild -create-xcframework` → `DS3CoreFFI.xcframework`
5. **`codesign` the XCFramework** — mandatory; Xcode 15+ rejects unsigned XCFrameworks
6. `cargo build --target x86_64-pc-windows-msvc` → `ds3_core.dll` (csbindgen runs in `build.rs`)

All orchestrated via `cargo xtask xcframework` / `cargo xtask windows`.

---

## 4. Critical Pitfalls

### Pitfall 1: Nested tokio runtime → process abort (Phase 1, Critical)

`Runtime::new().block_on()` inside a function already in a tokio context panics. In `extern "C"` ABI, a Rust panic is undefined behavior — in practice a silent process abort on the caller side. Prevention: one `Runtime` per `DS3Session`, created once at `authenticate()`. Internal crate functions are `async fn` all the way down; only the FFI boundary calls `block_on`. Establish this in the first function — retrofitting 35 functions is expensive.

### Pitfall 2: Rust panics crossing the FFI boundary (Phase 1, Critical)

UniFFI catches panics automatically on the Swift path. The csbindgen/C# path does not. Every `extern "C" fn` must wrap its body in `std::panic::catch_unwind(AssertUnwindSafe(|| { ... }))` and return a numeric error code on panic. Add `#[deny(clippy::unwrap_used)]` to the FFI crate. Set `panic = "abort"` in the release profile as a backstop.

### Pitfall 3: UniFFI + Swift 6 strict concurrency (Phase 1/2, Critical)

Xcode 26 with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` causes generated UniFFI declarations to inherit `@MainActor` isolation, breaking `deinit` calls and `Sendable` conformances. Prevention: `[bindings.swift] default_isolation = "nonisolated"` in `uniffi.toml`. Test generated bindings under strict concurrency in CI before any Xcode upgrade.

### Pitfall 4: Missing `CfSetInSyncState` → infinite re-download loop (Phase 3, Critical)

cfapi does not implicitly mark a placeholder as synced after `CfExecute(TRANSFER_DATA)`. Without the explicit `CfSetInSyncState(CF_IN_SYNC_STATE_IN_SYNC)` call, every subsequent access (antivirus, indexer, thumbnail) triggers a new `FETCH_DATA`. Prevention: `HydrationTransaction` C# class with `finally` block guaranteeing the call even on error. Diagnostic: log every `FETCH_DATA`; same file twice in 60 seconds = in-sync state missing.

### Pitfall 5: cfapi FETCH_DATA 30-second hard timeout (Phase 3, Critical)

No API to extend. Prevention: stream data in chunks (4 MB), calling `CfExecute(TRANSFER_DATA)` per chunk — each call resets the timer. The Rust `download_object` FFI must support streaming (data callback per chunk), not buffer-entire-body-then-return. Design the streaming FFI signature in Phase 1 before the C# layer is built against it.

### Pitfall 6: Spurious upload loop from `ReadDirectoryChangesW` (Phase 3, Critical)

cfapi hydration writes trigger `ReadDirectoryChangesW FILE_ACTION_MODIFIED`. If RDCW is the upload trigger, every hydration causes a spurious re-upload → bandwidth waste → S3 `SlowDown` throttling. Prevention: use `NOTIFY_FILE_CLOSE_COMPLETION` exclusively as the upload trigger. RDCW is acceptable only as a secondary trigger for new-file creation, filtered against a "currently hydrating" path set.

### Top Moderate Pitfalls (summary)

| Pitfall | Phase | Prevention |
|---------|-------|------------|
| Session handle leak | 1 | `SafeHandle` subclass calling `ds3_session_destroy` in `ReleaseHandle()` |
| String marshalling mismatch (UTF-8 vs ANSI) | 1 | `Marshal.PtrToStringUTF8()`; `csbindgen` generates this correctly |
| CRT heap mismatch on Windows | 1 | Never cross CRT boundary; `ds3_*_free()` for every Rust-allocated value |
| `CfUpdatePlaceholder` not atomic | 3 | Verify post-conditions with `CfGetPlaceholderState` after failure |
| File attribute clobbering | 3 | `GetFileAttributes()` first, OR with new bits; never set `FILE_ATTRIBUTE_NORMAL` |
| XCFramework not signed | 1 | `codesign` in build script + `--verify --deep --strict` in CI |
| Binary size bloat (~20 MB) | 1 | `cargo-bloat` audit; LTO + strip; evaluate reqwest+sigv4 vs full SDK |

---

## 5. Phase Implications

### Phase 1: Rust Core + FFI Proof of Concept

**Scope:** Cargo workspace, all 6 crates, UniFFI XCFramework build, csbindgen C# generation, integration tests against real Cubbit S3. No Apple or Windows app changes.

**Rationale:** Every subsequent phase depends on a working FFI layer. FFI patterns (runtime per session, panic guards, string contract, handle lifecycle, progress callback pinning, XCFramework signing) cannot be retrofitted cheaply after 35 functions exist.

**Delivers:** Signed `DS3CoreFFI.xcframework`; Swift test harness calls `DS3Session.authenticate()` + `listObjects()`. `ds3_core.dll` on Windows; C# console app calls `ds3_authenticate()` + `ds3_list_objects()`.

**Pitfalls to address in this phase:** #1, #2, #3, #4 (session), #7 (strings), #8 (CRT), #10 (signing), #11 (callbacks), #14 (binary size), #16 (cross-compilation CI).

**Research flag: NEEDS RESEARCH** — Cubbit IAM challenge-response wire protocol for Rust port. The Swift `DS3Authentication.signChallenge()` implementation is the only reference. No external documentation found. Must read Swift source and port byte-identically.

---

### Phase 2: Apple Incremental Swap

**Scope:** Add `DS3CoreFFI` Swift package. Create `RustBackedS3Client` conforming to `DS3S3ClientProtocol`. Swap `DS3S3Client`, `DS3Authentication`, `DS3SDK` internals to UniFFI calls. Full test suite must pass with identical FileProvider behavior.

**Rationale:** Incremental swap is safer than full DS3Lib rewrite. The protocol seam already exists. FileProvider behavior is fragile and regressions are hard to debug — limit blast radius by changing one conformance at a time.

**Delivers:** Existing macOS and iOS apps function identically, now calling Rust for S3 and auth. Soto and CryptoKit removed from DS3Lib.

**Pitfalls to address:** #3 (Swift 6 under strict concurrency in CI), #10 (notarization dry-run in CI).

**Research flag: STANDARD PATTERNS** — No additional research phase needed. Swap is mechanical once Phase 1 FFI is proven.

---

### Phase 3: Windows Shell

**Scope:** .NET 8 WinUI 3 solution: login flow, drive setup wizard, cfapi sync engine (all required callbacks), system tray, hydration progress, MSI installer.

**Rationale:** cfapi complexity warrants a dedicated phase after the FFI foundation is solid. It is the highest-complexity new code surface — more callback types, shorter timeouts, more edge cases than FileProvider.

**Delivers:** Full Windows beta: Explorer sidebar entry, placeholder files, on-demand hydration, upload on local change, periodic remote sync, system tray, silent-install MSI.

**Pitfalls to address:** #5 (CfSetInSyncState), #6 (FETCH_DATA streaming), #9 (RDCW vs. NOTIFY), #12 (CfUpdatePlaceholder), #13 (handle invalidation), #15 (duplicate DELETE), #17 (file attributes), #19 (stuck icons), #21 (pinned dehydration).

**Research flag: NEEDS TARGETED RESEARCH** — Safe patterns for `GCHandle` lifetime management under concurrent cfapi callbacks. The 60-second callback timeout + multi-threaded delivery creates non-obvious ordering constraints when pinning managed C# objects across concurrent `FETCH_DATA` invocations.

---

### Phase 4: Polish + Beta Hardening

**Scope:** Multi-drive support (3 cfapi sync roots), tray flyout activity center, pause/resume, settings panel, conflict resolution, error handling + toasts, uninstaller cleanup, ETW structured logging, binary size audit, ARM64 Windows target.

**Rationale:** All functional requirements land in Phase 3. Phase 4 converts beta-quality to release-quality.

**Research flag: STANDARD PATTERNS** for most of Phase 4. ETW bridge from Rust `tracing` may need targeted research (`tracing-etw` crate ecosystem is less mature than `tracing-oslog`).

---

## 6. Open Questions

From STACK.md:
- `aws-sdk-s3` vs. `reqwest + aws-sigv4`: empirical binary size measurement needed against the iOS extension's ~50 MB thinning limit before committing to the full SDK.
- WiX Open Source Maintenance Fee: verify Cubbit's compliance for commercial use of WiX v7.
- Tray icon library: confirm `H.NotifyIcon.WinUI` vs. direct Win32 `Shell_NotifyIcon` via CsWin32 at Phase 3 start.

From FEATURES.md:
- Tenant/coordinator URL field in wizard: confirm whether Windows auth flow needs a multi-tenant endpoint selector at launch or can default to a single Composer Hub URL.
- WebView2 OAuth login: confirm no backend timeline before Phase 3 begins.

From ARCHITECTURE.md:
- `EnumerationDiff` / `ConflictNaming` porting: port to Rust `ds3-sync` for Windows correctness; keep Swift implementations in DS3Lib during Phase 2 transition, remove after validation.
- Multi-drive account model: 3 drives with same account = 1 `DS3Session` + 3 cfapi roots, or 3 sessions? Confirm before Phase 3 session pooling design.
- `aarch64-pc-windows-msvc` (ARM64 Windows): add to cross-compilation matrix in Phase 4 (Snapdragon X laptops are a growing segment).

From PITFALLS.md:
- Cubbit IAM challenge-response wire protocol: no external documentation; Swift source is the only reference. Rust port must be byte-identical.
- AV implicit hydration under `CF_HYDRATION_POLICY_FULL`: no complete solution. Document for users; evaluate `CF_HYDRATION_POLICY_MODIFIER_ALLOW_FULL_RESTART_HYDRATION` during Phase 4 testing.
- `tracing-etw` maturity: evaluate at Phase 4; defer ETW if the crate is not production-ready.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Rust core stack | HIGH | All crates verified against crates.io, official docs, production usage |
| UniFFI Swift bindings | HIGH | Mozilla production-proven; version pin and Swift 6 workaround documented |
| csbindgen C# bindings | HIGH | Cysharp production-proven; used in Unity and .NET projects |
| cfapi integration | HIGH | Official Microsoft docs + Nextcloud + Mountain Duck production post-mortems |
| WinUI 3 tray + settings | MEDIUM | Tray library selection unresolved; WinUI 3 tray support actively evolving |
| Apple swap correctness | HIGH | Protocol seam (`DS3S3ClientProtocol`) already exists; swap is mechanical |
| Binary size (iOS extension) | MEDIUM | Empirical measurement needed before committing to full aws-sdk-s3 |
| IAM wire protocol Rust port | MEDIUM | No external documentation; Swift source is the only reference |
| ETW logging bridge | LOW | `tracing-etw` ecosystem less mature; defer to Phase 4 with explicit research |

---

## Sources (aggregated)

**Official documentation:** aws-sdk-s3 (crates.io), UniFFI user guide + changelog, csbindgen (Cysharp GitHub), CfRegisterSyncRoot / CfConnectSyncRoot / CfSetInSyncState / CfExecute / CfUpdatePlaceholder (Microsoft Learn), Cloud Filter API FAQ (Microsoft Q&A), Build a Cloud File Sync Engine (Microsoft), WindowsAppSDK 1.8 release notes, CsWinRT 2.2.0, WiX v7, H.NotifyIcon.WinUI (NuGet), AdysTech.CredentialManager (NuGet).

**Production post-mortems:** Dropbox Djinni deprecation ("The not-so-hidden cost of sharing code between iOS and Android"), Mozilla UniFFI in Firefox Hacks post, Nextcloud `cldapi.dll` crash fix (PR #3461), Ferrostar XCFramework build pipeline (Stadia Maps), Mozilla application-services `build-xcframework.sh`.

**Issue trackers:** uniffi-rs#2818 (Swift 6 nonisolated fix), uniffi-rs#2274 (async Sendable), tokio#3857 (nested runtime panic), aws/aws-lc-rs#745 (binary size), Corrosion common issues (CRT mismatch), CfUpdatePlaceholder partial update (Microsoft Q&A #847358).
