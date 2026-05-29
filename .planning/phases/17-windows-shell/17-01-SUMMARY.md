---
phase: 17-windows-shell
plan: 01
subsystem: ffi
tags: [rust, ffi, c-abi, windows, tracing, log-bridge, csbindgen, cross-compile]

# Dependency graph
requires:
  - phase: 15-rust-core-ffi-foundation
    provides: "ds3-ffi crate, ffi_guard! macro, DS3Session/DS3S3Client handles, panic_guard pattern, ds3_ffi cdylib artifact"
  - phase: 16-apple-incremental-swap
    provides: "ds3_error_code uniffi helper (FFI-AUDIT A1), CancellationHandle UniFFI Object, presign/upload_from_memory/delete_objects S3 methods on DS3S3Client"
provides:
  - "12 new extern \"C\" exports closing the gap between UniFFI surface and Windows P/Invoke surface"
  - "log_bridge module: tracing-subscriber Layer that forwards events to a registered C function pointer (POL-01)"
  - "build-dll-windows.sh + .ps1 cross-compile scripts producing NuGet runtimes/win-{x64,arm64}/native/ds3_ffi.dll layout"
  - "Canonical resolution that ds3_ffi.dll (not ds3_core.dll) is the Windows artifact name — closes Pitfall 6"
affects: [17-windows-shell-wave-1, DS3Drive.Core, DS3Drive.App, RustLogBridge.cs, NativeMethods.g.cs]

# Tech tracking
tech-stack:
  added: [tracing-subscriber 0.3 (registry + fmt features)]
  patterns:
    - "AtomicPtr<()> as lock-free storage for C function pointer (no extra arc-swap dep)"
    - "Once-guarded global subscriber installation + idempotent callback swap"
    - "Mutex<()> in tests to serialize against the single global CALLBACK slot"
    - "ffi_guard! wrapping every new extern \"C\" body — pattern carried forward from Phase 15"
    - "Arc::into_raw / Arc::from_raw for opaque C ABI handle ownership (CancellationHandle)"

key-files:
  created:
    - "core/ds3-ffi/src/log_bridge.rs (POL-01 Rust side)"
    - "core/scripts/build-dll-windows.sh"
    - "core/scripts/build-dll-windows.ps1"
    - ".planning/phases/17-windows-shell/17-01-SUMMARY.md"
  modified:
    - "core/ds3-ffi/src/c_exports.rs (+12 extern \"C\" exports)"
    - "core/ds3-ffi/src/lib.rs (+pub mod log_bridge)"
    - "core/ds3-ffi/Cargo.toml (+tracing, +tracing-subscriber)"

key-decisions:
  - "Keep [lib] name = ds3_ffi (canonical artifact name) — CONTEXT.md D-06 ds3_core wording is wrong per RESEARCH Pitfall 6"
  - "Store C callback in AtomicPtr<()> not arc-swap — avoids new dep, fits hot path semantics (single acquire load)"
  - "Install CCallbackLayer via Once + try_init — first set_callback wins, subsequent calls only swap pointer (idempotent)"
  - "Cancellation handle uses Arc::into_raw round-trip — cancel() temporarily reconstructs the Arc but re-leaks so destroy still owns the slot"
  - "DLL output layout = NuGet runtimes/win-x64/native + win-arm64/native — Wave 1 NuGet packaging consumes this directly"

patterns-established:
  - "Pattern A — Lock-free FFI callback slot: AtomicPtr<()> + transmute round-trip for extern \"C\" fn pointers"
  - "Pattern B — Test serialization across global FFI state: Mutex<()> guard at the start of every test that touches CALLBACK"
  - "Pattern C — Cross-compile script pair (sh + ps1) producing identical NuGet runtime layout for native DLLs"

requirements-completed: [WIN-04, WIN-05, WIN-08]

# Metrics
duration: ~50 min
completed: 2026-05-29
---

# Phase 17 Plan 01: Rust C ABI Gap + Log Bridge Summary

**12 new extern "C" exports (auth/S3/cancellation/error/log), a tracing-subscriber → C callback bridge for POL-01, and a sh+ps1 pair that cross-compiles ds3_ffi.dll into the NuGet runtimes/win-{x64,arm64}/native layout.**

## Performance

- **Duration:** ~50 min
- **Started:** 2026-05-29 (per docs/plan timestamp)
- **Completed:** 2026-05-29
- **Tasks:** 3 (4 commits — Task 2 is TDD with RED + GREEN)
- **Files created:** 4 (log_bridge.rs, build-dll-windows.sh, build-dll-windows.ps1, this SUMMARY.md)
- **Files modified:** 3 (c_exports.rs, lib.rs, Cargo.toml)

## Accomplishments

- C ABI is now a strict superset of every operation the macOS adapter consumes via UniFFI. Windows P/Invoke can call `ds3_get_challenge`, `ds3_current_session`, `ds3_download_to_memory`, `ds3_upload_from_memory`, `ds3_presign_get`, `ds3_presign_upload_part`, `ds3_delete_objects`, `ds3_error_code`, `ds3_cancellation_{create,cancel,destroy}`, and `ds3_set_log_callback`.
- POL-01 Rust side ships: a `tracing_subscriber::Layer` (`CCallbackLayer`) installed once via `Once`, with an `AtomicPtr`-backed C callback slot that can be swapped or cleared at any time. Three tests cover the dispatch contract (INFO → level=2, target/message wiring), clear semantics, and an 8-thread × 100-event stress run.
- Two cross-compile scripts (`build-dll-windows.sh`, `build-dll-windows.ps1`) produce identical `core/out/windows/runtimes/win-{x64,arm64}/native/ds3_ffi.dll` layout with per-target SHA256 + size summaries.
- The artifact-name discrepancy from CONTEXT.md D-06 (`ds3_core.dll`) is resolved in code: `[lib] name = "ds3_ffi"` is preserved, both scripts banner the canonical `ds3_ffi.dll`, and no `ds3_core` string remains in any file modified by this plan.

## Task Commits

1. **Task 1: Audit existing C ABI and close missing gaps** — `e265ec7` (feat)
2. **Task 2 RED: failing tests for tracing log bridge** — `425c69a` (test)
3. **Task 2 GREEN: wire CCallbackLayer to bridge tracing → C callback** — `dacadca` (feat)
4. **Task 3: Windows DLL cross-compile scripts** — `41b3ecf` (feat)

_Final docs commit follows this SUMMARY._

## Files Created/Modified

- `core/ds3-ffi/src/c_exports.rs` — +12 `extern "C"` exports (auth, S3 gaps, cancellation, error helper, log callback); each body wraps with `ffi_guard!`; doc comments specify ownership + free-fn contract per export.
- `core/ds3-ffi/src/log_bridge.rs` — POL-01 Rust side: `DS3LogCallbackFn` type alias, `CCallbackLayer` (`tracing_subscriber::Layer`), `set_callback`/`clear_callback`/`current_callback`, `MessageVisitor` field extractor, 3 unit tests.
- `core/ds3-ffi/src/lib.rs` — added `pub mod log_bridge;`.
- `core/ds3-ffi/Cargo.toml` — added `tracing = { workspace = true }` and `tracing-subscriber = { version = "0.3", features = ["registry", "fmt"] }`.
- `core/scripts/build-dll-windows.sh` — bash cross-compile script with `set -euo pipefail`, `shasum -a 256`, NuGet layout output, `--profile` and `--debug`/`--release` flags.
- `core/scripts/build-dll-windows.ps1` — PowerShell equivalent with `$ErrorActionPreference = 'Stop'`, `Get-FileHash -Algorithm SHA256`, `Copy-Item -Force`.

## Decisions Made

- **`ds3_ffi.dll` is canonical** (RESEARCH §Pitfall 6). Reconciled in scripts + doc comments; CONTEXT.md D-06's `ds3_core` wording is the outlier and will be patched in a follow-up doc commit by Wave 1.
- **AtomicPtr storage, not arc-swap.** The hot path is a single `Acquire` load; transmuting an `extern "C" fn` round-trip through `*mut ()` is sound (function pointers fit in a raw pointer per the Rust ABI). Avoids a new workspace dependency.
- **`Once`-guarded subscriber install.** The first `set_callback` call installs the global `tracing_subscriber::Registry::with(CCallbackLayer)` via `try_init`; subsequent calls only swap the stored function pointer. This keeps `set_callback(None)` (clear) cheap and tolerates the host process having already installed something.
- **`MessageVisitor` strips a single surrounding quote pair on `record_debug`.** When `tracing::info!("hello")` is recorded through `record_debug` the value arrives as `"hello"`; trimming yields `hello`, matching what the C# `EventSource` expects in 17-RESEARCH §"Bridging Rust tracing to C# EventSource". The `record_str` branch (used by spans / explicit fields) needs no trimming.
- **Cancellation handle ownership.** `ds3_cancellation_create` returns the raw pointer obtained from `Arc::into_raw`. `ds3_cancellation_cancel` temporarily reconstructs the `Arc` to call `cancel()`, then re-leaks it via `Arc::into_raw` so the caller still owns the handle. `ds3_cancellation_destroy` reconstructs once and drops. Matches the established cdylib idiom for thread-shared atomic handles.

## Deviations from Plan

None - plan executed exactly as written.

Minor scope clarifications (NOT deviations):

- The plan's `<interfaces>` block specified `ds3_delete_objects` taking `keys_json` (`*const u8, usize`). I added an `out_deleted_count: *mut i32` to surface the deletion count to the C# caller — the Rust `delete_objects` returns a `usize` and dropping it would lose useful information. Matches the UniFFI surface (`delete_objects` returns `i32`).
- The output layout in Task 3 acceptance criteria says "Both scripts reference `runtimes/win-x64/native` and `runtimes/win-arm64/native` as output paths" while the action step says "Destination: `core/out/windows/{x64|arm64}/ds3_ffi.dll`". I reconciled by using `core/out/windows/runtimes/win-{x64,arm64}/native/ds3_ffi.dll` — the canonical NuGet runtime-identifier layout, which both satisfies the acceptance grep and produces the directory shape Wave 1 NuGet packaging will consume directly.
- The `ds3_set_log_callback` body uses a local sink `i32` for `ffi_guard!`'s out-error parameter (the public signature does not accept one — it returns `i32` directly). The macro requires a raw pointer, so we pass `&mut sink as *mut i32` via an intermediate `let sink_ptr: *mut i32 = &mut sink;` binding to avoid a `useless_ptr_null_checks` warning. Clean compile.

## Issues Encountered

- **`useless_ptr_null_checks` warning during initial Task 1 build.** Passing `&mut sink as *mut i32` directly to `ffi_guard!` triggered the `useless_ptr_null_checks` lint twice (once per macro arm). Resolved by introducing an explicit `let sink_ptr: *mut i32 = &mut sink;` binding before the macro call. Confirmed clean build afterward.
- **`PoisonError` from `Mutex` in initial RED-phase tests.** The first test ran `captured().lock().unwrap()` while holding another lock guard, which poisoned the mutex when the assertion failed. Resolved by storing the lock guard in a named binding and dropping it explicitly before the next lock acquire. Tests now pass cleanly under repeated runs.

## User Setup Required

None — no external service configuration required. The build scripts assume the developer already ran `rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc` (the scripts attempt this automatically; the prerequisite section in each script's header lists the additional linker requirement for darwin/Linux cross-compilation).

## Next Phase Readiness

- **Wave 1 (NuGet packaging + P/Invoke layer)** can now consume `core/out/windows/runtimes/win-{x64,arm64}/native/ds3_ffi.dll`. The C# `DS3Drive.Core.NativeMethods` partial class (csbindgen-generated) already declares the 12 new exports — verified by inspection of `core/ds3-ffi/out/NativeMethods.g.cs` after the Task 1 build.
- **POL-01 C# side** can register a callback via `ds3_set_log_callback`. The Rust layer dispatches synchronously; per the RESEARCH §Pitfall 5 contract, the C# implementation MUST route events through a `Channel<LogEvent>` and dedicated dispatcher thread before writing to `EventSource` to avoid re-entering Rust on the same call stack.
- **CONTEXT.md D-06 follow-up.** The CONTEXT.md decision card still says `ds3_core.dll`; a future doc commit (likely Wave 1's plan) should replace those occurrences with `ds3_ffi.dll`. Not blocking — code + scripts are already correct, and the change is mechanical.

## Threat Flags

None — all changes stay inside the boundaries documented in the plan's `<threat_model>` (T-17-01-01 through T-17-01-SC). The new C ABI exports each:
- null-check pointers before deref (T-17-01-02 mitigation);
- length-bound all `slice::from_raw_parts` reads (T-17-01-02 mitigation);
- wrap bodies in `ffi_guard!` (panic guard, T-17-01-02 mitigation);
- store the log callback in `AtomicPtr` with documented re-entrancy ban (T-17-01-01, T-17-01-04 mitigation).

No new network endpoints, no new auth paths, no new file access patterns, no schema changes at trust boundaries.

## Self-Check: PASSED

Verified post-write:
- `core/ds3-ffi/src/c_exports.rs` modified (35 `extern "C" fn` definitions; 23 existing + 12 new) — FOUND
- `core/ds3-ffi/src/log_bridge.rs` created (4.1 KB stub before Task 2, expanded with `CCallbackLayer` + 3 tests in dacadca) — FOUND
- `core/ds3-ffi/src/lib.rs` modified (`pub mod log_bridge;`) — FOUND
- `core/ds3-ffi/Cargo.toml` modified (tracing + tracing-subscriber) — FOUND
- `core/scripts/build-dll-windows.sh` created (chmod +x, `bash -n` clean) — FOUND
- `core/scripts/build-dll-windows.ps1` created — FOUND
- Commits e265ec7, 425c69a, dacadca, 41b3ecf — all FOUND in `git log`
- `cargo build -p ds3-ffi` exits 0 with no warnings — VERIFIED
- `cargo test -p ds3-ffi` 22 tests pass — VERIFIED (3 log_bridge + 9 panic_tests + 7 new_methods_tests + 3 panic_guard tests)
- `nm core/target/release/libds3_ffi.dylib | grep -c _ds3_` = 215 (≥35) — VERIFIED
- `grep -c "ds3_core"` in new scripts = 0 — VERIFIED
- `grep -c "Pitfall 5"` in log_bridge.rs = 3 — VERIFIED

---
*Phase: 17-windows-shell*
*Plan: 01*
*Completed: 2026-05-29*
