---
phase: 17-windows-shell
plan: 07
subsystem: windows-logging
tags: [logging, etw, eventsource, ffi-callback, pol-01]
requires: [17-01, 17-05]
provides:
  - RustLogBridge (Initialize/Shutdown) — Rust tracing → C# log dispatch chain
  - RustCoreEventSource (Cubbit-DS3Drive-Core) ETW provider
  - AppEventSource (Cubbit-DS3Drive-App) ETW provider
affects:
  - windows/DS3Drive.App (Plan 08 calls RustLogBridge.Initialize() at startup)
tech-stack:
  added:
    - System.Diagnostics.Tracing.EventSource (BCL, ships with .NET 8)
    - System.Threading.Channels (BCL — bounded channel for back-pressure)
  patterns:
    - "Non-blocking FFI callback: decode-and-enqueue only; dedicated drainer task owns EventSource writes (Pitfall 5)"
    - "UnmanagedCallersOnly static method for a GC-stable native callback address (no GCHandle pinning)"
    - "Internal seam (CallbackRegistrar Func<bool,int>) lets unit tests verify register/clear without the native DLL"
key-files:
  created:
    - windows/DS3Drive.Core/Logging/RustCoreEventSource.cs
    - windows/DS3Drive.Core/Logging/AppEventSource.cs
    - windows/DS3Drive.Core/Logging/RustLogBridge.cs
    - windows/DS3Drive.Tests/RustLogBridgeTests.cs
  modified: []
decisions:
  - "[17-07] Native ds3_set_log_callback ABI is a function pointer (delegate* unmanaged[Cdecl]), not a marshaled delegate — so the bridge uses an [UnmanagedCallersOnly] static target whose address is GC-stable; no GCHandle/Marshal.GetFunctionPointerForDelegate needed (supersedes the RESEARCH §POL-01 marshaled-delegate sketch)"
  - "[17-07] Shutdown clears via ds3_clear_log_callback (the canonical null path) because the function-pointer ABI cannot pass a managed null cleanly"
  - "[17-07] RustLogBridge.CallbackRegistrar seam keeps all 7 tests in Category!=Integration; real native-callback round-trip deferred to windows-latest CI (17-02 MSVC linker blocker)"
metrics:
  duration: ~12min
  tasks: 1
  files: 4
  completed: 2026-05-29
---

# Phase 17 Plan 07: Cross-FFI Logging (POL-01) Summary

Bridged Rust `tracing` events through the `ds3_set_log_callback` C ABI into two C# `EventSource` ETW providers (`Cubbit-DS3Drive-Core` for Rust events, `Cubbit-DS3Drive-App` for managed logs) via a non-blocking bounded-Channel + dedicated-drainer pipeline that structurally forbids FFI re-entrancy (RESEARCH Pitfall 5).

## What Was Built

- **RustCoreEventSource.cs / AppEventSource.cs** — `[EventSource(Name=...)]` providers with `Trace/Debug/Info/Warn/Error` events (`[Event(N, Level=...)]`, ordinals 1–5) surfacing in Windows Event Viewer / ETW.
- **RustLogBridge.cs** — `Initialize()` (idempotent via `Interlocked.Exchange`) installs an `[UnmanagedCallersOnly]` callback through `ds3_set_log_callback` and starts a drainer `Task`; `Shutdown()` clears via `ds3_clear_log_callback`, cancels the drainer (2s bounded wait), and drains the tail. The native callback only decodes the read-only UTF-8 buffers (`Marshal.PtrToStringUTF8` with an `int.MaxValue` length clamp) and `TryWrite()`s onto a `Channel.CreateBounded<LogEvent>(1024)` with `BoundedChannelFullMode.DropOldest`. The drainer is the only place `RustCoreEventSource` is written.
- **RustLogBridgeTests.cs** — 7 tests: (1) Initialize registers, (2) idempotent, (3) Shutdown clears, (4) Dispatch enqueues, (5) drainer maps level→Event(5) and captures via an `EventListener`, (6) DropOldest back-pressure caps at 1024 without blocking, (7) Pitfall 5 — Dispatch never re-enters FFI.

## How It Works (dispatch chain)

`Rust tracing` → C callback (tokio worker thread) → `OnNativeCallback` decodes + `TryWrite` → bounded `Channel<LogEvent>` (DropOldest) → `DrainerLoopAsync` (own task) → `RustCoreEventSource.Log.<level>` → ETW. The Channel + drainer indirection is the load-bearing mechanism that makes Rust re-entry on the same call stack impossible; the callback body is wrapped in `try { } catch { }` so no CLR exception unwinds into Rust frames.

## Verification

- `dotnet build windows/DS3Drive.Core -p:DS3SkipRustCore=true` → 0 warnings, 0 errors.
- `dotnet test --filter "FullyQualifiedName~RustLogBridgeTests"` → 7/7 passed.
- Full non-integration suite: `dotnet test --filter "Category!=Integration"` → 56/56 passed.
- All acceptance greps satisfied (EventSource names ×1 each; Channel/DropOldest ×2; PtrToStringUTF8 ×4; ds3_set_log_callback ×4; Pitfall/reentr ×5; try{ ×1; Interlocked ×3).

## Threat Model Coverage

| Threat ID | Mitigation as built |
|-----------|---------------------|
| T-17-07-01 (Tampering/EoP on buffer length) | `DecodeUtf8` clamps `len` to `int.MaxValue`, returns empty on null ptr/zero len; pointer not retained after callback returns |
| T-17-07-03 (DoS log burst) | `BoundedChannelFullMode.DropOldest`; `TryWrite` never blocks the tokio thread |
| T-17-07-04 (DoS callback panic) | Outer `try/catch` swallow in `OnNativeCallback`; `Trace.Trace*` fallback in lifecycle paths |
| T-17-07-05 (EoP FFI re-entrancy) | Channel + drainer indirection; Test 7 enforces with thread-static reentry probe |
| T-17-07-02 (InfoDisclosure PII) | EventSource events carry only the (target, message) pair Rust already redacts; doc discipline noted (no token/email/secret args) |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Native callback ABI is a function pointer, not a marshaled delegate**
- **Found during:** Task 1 build (CS8757: no overload matches `delegate* unmanaged[Cdecl]<int, byte*, nuint, byte*, nuint, void>`).
- **Issue:** The RESEARCH §POL-01 sketch used `[UnmanagedFunctionPointer]` + `Marshal.GetFunctionPointerForDelegate`, but the committed `DS3Native.ds3_set_log_callback` (mirroring `core/ds3-ffi/out/NativeMethods.g.cs`) takes a C# function pointer.
- **Fix:** Made `OnNativeCallback` an `[UnmanagedCallersOnly(CallConvs=CallConvCdecl)]` static method with `byte*`/`nuint` params; passed its address `&OnNativeCallback` directly (GC-stable, no pinning). Clear path uses `ds3_clear_log_callback`.
- **Files modified:** windows/DS3Drive.Core/Logging/RustLogBridge.cs
- **Commit:** d042def

## Notes for Downstream Plans

- Plan 08 (App.xaml.cs): call `RustLogBridge.Initialize()` once at startup before any FFI use, and `RustLogBridge.Shutdown()` on app exit. Wire `Microsoft.Extensions.Logging` to `AppEventSource` via `AddEventSourceLogger` (provider name `Cubbit-DS3Drive-App`).
- CI (windows-latest): add a `Category=Integration` test that installs the real native callback and asserts a Rust `tracing::info!` reaches `Cubbit-DS3Drive-Core` — the round-trip is unverifiable locally (17-02 MSVC linker blocker).
- Phase 18 can layer "Open log folder" / `wevtutil` file export on top without touching this pipeline.

## Self-Check: PASSED
- FOUND: windows/DS3Drive.Core/Logging/RustCoreEventSource.cs
- FOUND: windows/DS3Drive.Core/Logging/AppEventSource.cs
- FOUND: windows/DS3Drive.Core/Logging/RustLogBridge.cs
- FOUND: windows/DS3Drive.Tests/RustLogBridgeTests.cs
- FOUND: commit d042def
