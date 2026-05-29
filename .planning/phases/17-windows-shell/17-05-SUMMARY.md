---
phase: 17-windows-shell
plan: 05
subsystem: windows-core-ffi-facade
tags: [pinvoke, ffi-facade, exceptions, credential-manager, dpapi, config]
requires:
  - "core/ds3-ffi C ABI (Phase 15) — ds3_authenticate … ds3_clear_log_callback"
  - "DS3Drive.Core scaffold + central package management (Plan 17-02)"
  - "Test harness + RequiresCredentials fixture (Plan 17-03)"
provides:
  - "DS3Session : IDisposable — idiomatic C# facade over ds3_ffi.dll"
  - "DS3ExceptionFactory — DS3Error code → typed C# exception (D-15 byte-identical 2FA)"
  - "CredentialStore — Windows Credential Manager wrapper (D-12)"
  - "ConfigStore — appsettings.json defaults reader (D-13)"
  - "9 domain records mirroring ds3-models"
affects:
  - "Wave 2 (Login, Drive Setup) — import DS3Drive.Core, call DS3Session.Authenticate"
  - "Wave 3 (sync engine) — CredentialStore for refreshToken, ConfigStore for coordinator URL"
tech-stack:
  added:
    - "Microsoft.Extensions.Configuration 8.0.0 (DS3Drive.Core — ConfigStore)"
  patterns:
    - "Hand-mirror of csbindgen output (IntPtr handles, out-param error codes)"
    - "Interlocked.Exchange dispose guard for native handle lifetime"
    - "Centralized error translation via Check/Parse/Complete helpers"
    - "Hand-rolled Advapi32 P/Invoke (no third-party credential dependency)"
key-files:
  created:
    - windows/DS3Drive.Core/Generated/DS3Native.cs
    - windows/DS3Drive.Core/DS3Session.cs
    - windows/DS3Drive.Core/Native/CancellationHandle.cs
    - windows/DS3Drive.Core/Native/DS3ProgressCallback.cs
    - windows/DS3Drive.Core/Records/*.cs (10 records)
    - windows/DS3Drive.Core/CredentialStore.cs
    - windows/DS3Drive.Core/ConfigStore.cs
    - windows/DS3Drive.Core/appsettings.json
    - windows/DS3Drive.Tests/DS3SessionTests.cs
    - windows/DS3Drive.Tests/CredentialStoreTests.cs
  modified:
    - windows/DS3Drive.Core/Exceptions/* (Task 1 — pre-committed 6226f73)
    - windows/DS3Drive.Core/DS3Drive.Core.csproj
    - windows/DS3Drive.Core/Properties/AssemblyInfo.cs
decisions:
  - "DS3ExceptionFactory.From appears 4× (not 5) in DS3Session.cs because error translation is DRY'd into Check/Parse/Complete helpers — every method funnels through them rather than duplicating From() inline. Stronger than the literal ≥5 criterion."
  - "Plan target-name format 'Cubbit DS3 Drive — <accountId> — <credentialKey>' chosen over CONTEXT D-12's shorter 'Cubbit DS3 Drive — <accountId>' so multiple credential keys (refreshToken, secretKey) per account don't collide. Consistent with must_haves + behavior spec."
  - "CredentialStoreTests use plain [Fact] + early-return on non-Windows (RuntimeInformation.IsOSPlatform) instead of Xunit.SkippableFact — avoids adding an unvetted test package; CI windows-latest runs the real assertions."
metrics:
  duration: "~17 min"
  completed: 2026-05-29
---

# Phase 17 Plan 05: DS3Drive.Core P/Invoke Facade Summary

The DS3Drive.Core FFI facade — `DS3Session : IDisposable` over `ds3_ffi.dll`, the
typed exception hierarchy with byte-identical Apple D-15 2FA mapping, 10 domain
records, Windows Credential Manager secret storage, and `appsettings.json`
defaults — built and green on the local Windows-on-ARM64 box via
`DS3SkipRustCore=true` (managed-only; native verification deferred to CI).

## What Was Built

- **Task 1 — Exception hierarchy + DS3ExceptionFactory** (pre-committed `6226f73`):
  `AuthFailureReason` enum, `DS3AuthenticationException`/`DS3S3Exception`/
  `DS3TransportException`/`DS3PanicException`, and the `From(code)` switch porting
  `DS3Authentication.swift:56-88`. 1007 → `TwoFactorRequired` is colocated and
  D-15-traceable. 13 TDD tests.
- **Task 2 — DS3Native + DS3Session + records + cancellation** (`e28f623`):
  `DS3Native.cs` hand-mirror of `c_exports.rs` (36 `DllImport("ds3_ffi")`, zero
  `ds3_core`); `DS3Session` facade with `EnsureHandle` loggedOut short-circuit
  (PATTERNS §3.2), `Interlocked.Exchange` dispose guard, and centralized error
  translation; `CancellationHandle`, `DS3ProgressCallback`; 10 records. 4
  managed-only unit tests + 1 gated Integration smoke.
- **Task 3 — CredentialStore + ConfigStore + appsettings.json** (`158a46e`):
  hand-rolled `Advapi32` P/Invoke (CredWrite/Read/Delete/Free/Enumerate), em-dash
  target-name format (D-12), `ConfigStore` over `IConfiguration` (D-13). 6
  round-trip tests green against the live Windows Credential Manager.

## Verification Performed

- `dotnet build windows/DS3Drive.Core -p:DS3SkipRustCore=true` → 0 warnings, 0 errors.
- `dotnet test --filter "Category!=Integration"` → **27 passed, 0 failed**
  (13 ExceptionFactory + 4 Session + 6 Credential + 4 prior).
- CredentialStore tests executed against the real OS keychain on the Windows host
  (not mocked): save/load/overwrite/delete/enumerate + em-dash format + empty-secret guard.
- Acceptance greps: 36 `ds3_ffi` DllImports / 0 `ds3_core`; 14 Advapi32; 1
  em-dash target; 10 records; 2× Interlocked.Exchange; appsettings valid JSON.

## Deferred / Honest Limitations

- **Native invocation not exercised locally.** The MSVC C++ linker is absent on this
  machine (STATE.md 17-02 blocker), so `ds3_ffi.dll` cannot be built/linked here.
  All managed P/Invoke binds at runtime, so the facade *compiles* and the dispose /
  EnsureHandle / error-translation logic is unit-tested without the DLL. Any test
  that actually calls into Rust (`DS3Session.Authenticate` live round-trip) is
  marked `[RequiresCredentials, Trait("Category","Integration")]` and runs only on
  the secrets-enabled `windows-latest` CI job — **not** faked as passing locally.
- **DS3Native.cs is a hand-mirror**, not regenerated. The committed Phase 15
  csbindgen output (`core/ds3-ffi/out/NativeMethods.g.cs`) is the authoritative
  source; regeneration via `cargo run -p ds3-ffi` is deferred to CI (same linker
  blocker). The file header documents the regenerate-or-verify contract.

## Deviations from Plan

### Auto-fixed / adjusted

**1. [Rule 3 - Blocking] Added Microsoft.Extensions.Configuration to DS3Drive.Core**
- ConfigStore requires `IConfiguration`; the package was centrally pinned (8.0.0)
  but not referenced by Core. Added the reference + `appsettings.json` content item.
- Transitive pinning repinned `DS3Drive.Sync` and `DS3Drive.Tests` lockfiles.
- Files: `DS3Drive.Core.csproj`, three `packages.lock.json`. Commit `158a46e`.

**2. [Design] Error-translation count (DS3ExceptionFactory.From ×4, not ×5)**
- The plan's acceptance criterion expects ≥5 `From()` call sites in DS3Session.cs.
  Translation is instead centralized in `Check`/`Parse`/`Complete` (each calls
  `From`), so every public method funnels through them — DRY and stronger than
  literal duplication. Count is 4; behavior (every rc translated via factory) holds.

**3. [Test infra] CredentialStoreTests gating without Xunit.SkippableFact**
- Used `[Fact]` + `if (!OnWindows) return;` instead of a `SkippableFact` package
  (not in the vetted package set) to keep cross-platform CI green.

## Known Stubs

None. `DS3Session.CopyObject` ignores `dstBucket` (the C ABI `ds3_copy_object` is
single-bucket) — this matches the current Rust surface, documented inline, not a stub.

## Self-Check: PASSED

- Files exist: DS3Native.cs, DS3Session.cs, CredentialStore.cs, ConfigStore.cs,
  appsettings.json, DS3SessionTests.cs, CredentialStoreTests.cs — all confirmed.
- Commits exist: 6226f73, e28f623, 158a46e — all in `git log`.
