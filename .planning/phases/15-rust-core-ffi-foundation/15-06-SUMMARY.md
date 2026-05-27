---
phase: 15-rust-core-ffi-foundation
plan: 06
subsystem: ds3-ffi
tags: [ffi, uniffi, csbindgen, xcframework, swift, csharp, panic-safety]
dependency_graph:
  requires: [15-03, 15-04, 15-05]
  provides: [uniffi-swift-bindings, csbindgen-csharp-bindings, xcframework-build-script, ffi-patterns]
  affects: [ds3-models, ds3-auth, ds3-s3, ds3-sync]
tech_stack:
  added: [uniffi-0.31, csbindgen-1.9]
  patterns: [opaque-session-handle, shared-tokio-runtime, catch-unwind-panic-guard, uniffi-callback-interface, ffi-string-contract]
key_files:
  created:
    - core/ds3-ffi/src/uniffi_exports.rs
    - core/ds3-ffi/src/c_exports.rs
    - core/ds3-ffi/src/handles.rs
    - core/ds3-ffi/src/progress.rs
    - core/ds3-ffi/src/panic_guard.rs
    - core/ds3-ffi/build.rs
    - core/ds3-ffi/uniffi.toml
    - core/ds3-ffi/uniffi-bindgen.rs
    - core/scripts/build-xcframework.sh
    - core/.gitignore
    - core/ds3-ffi/.gitignore
  modified:
    - core/ds3-models/Cargo.toml
    - core/ds3-models/src/lib.rs
    - core/ds3-models/src/account.rs
    - core/ds3-models/src/auth.rs
    - core/ds3-models/src/project.rs
    - core/ds3-models/src/api_key.rs
    - core/ds3-models/src/s3.rs
    - core/ds3-models/src/sync.rs
    - core/ds3-models/src/error.rs
    - core/ds3-ffi/Cargo.toml
    - core/ds3-ffi/src/lib.rs
    - core/ds3-auth/src/session.rs
    - core/ds3-s3/src/client.rs
    - core/ds3-sync/src/tree.rs
decisions:
  - "Used uniffi::flat_error for DS3Error since variants have mixed field types"
  - "Created DiffResultRecord with Vec<String> as UniFFI-compatible wrapper for HashSet-based DiffResult"
  - "Added S3DownloadResult and BucketInfo to ds3-models as FFI-boundary Record types"
  - "Made DS3Session fields pub (from pub(crate)) so FFI layer can access http/urls for project/key operations"
  - "Added authenticate_with_2fa to DS3Session rather than constructing session manually in FFI"
  - "Added Clone to DS3S3Client (internally Arc-based) for RwLock access pattern"
  - "Memory management functions (free_string, free_bytes, session_destroy) exempt from ffi_guard -- trivial ops with no meaningful error path"
metrics:
  duration: 17m 50s
  completed: 2026-05-27T11:58:48Z
  tasks_completed: 3
  tasks_total: 3
  tests_added: 5
  tests_passing: 73
  files_created: 11
  files_modified: 14
---

# Phase 15 Plan 06: FFI Bridge Layer (UniFFI + csbindgen) Summary

ds3-ffi crate with 32 UniFFI exports for Swift, 23 C exports for C#, panic guards on all C functions, shared tokio runtime, progress callbacks, and XCFramework build script.

## What Was Done

### Task 1: Retrofit UniFFI derives on ds3-models types
Added `uniffi = "0.31"` dependency to ds3-models and `uniffi::setup_scaffolding!()` macro. Applied `#[derive(uniffi::Record)]` to 16 model structs that cross the FFI boundary: Account, AccountEmail, Challenge, Token, AccountSession, Project, IAMUser, DS3ApiKey, S3ListingResult, S3ObjectSummary, S3ObjectMetadata, TransferProgress, MultipartUploadContext, CompletedPartResult, S3DownloadResult (new), BucketInfo (new). Applied `#[derive(uniffi::Error)]` with `#[uniffi(flat_error)]` to DS3Error. Created DiffResultRecord with `Vec<String>` as a UniFFI-compatible wrapper since `HashSet` is not supported by UniFFI.

### Task 2: UniFFI exports, C exports, shared runtime, and panic guards
Created `DS3SessionHandle` as an opaque `uniffi::Object` wrapping `Arc<DS3Session>` plus an optional `DS3S3Client` behind `RwLock`. Implemented 32 UniFFI-exported functions covering auth (authenticate, verify_2fa, refresh_token, forge_iam_token, account_info, get_challenge, connect_s3), projects/keys (get_projects, load_api_keys, create_api_key, delete_api_key), S3 (list_objects, list_buckets, head_object, download_object, upload_object, delete_object, delete_objects, copy_object, probe_folder_exists, create_folder_marker), and sync (compute_diff, conflict_key as free functions). Implemented 23 matching C exports with `extern "C"` functions using byte-slice string parameters. Created `ffi_guard!` macro for `catch_unwind` panic safety. Created shared tokio runtime via `OnceLock`. Created `ProgressCallback` trait (UniFFI callback_interface) and `DS3ProgressCallbackFn` C function pointer type.

### Task 3: csbindgen build.rs and XCFramework build script
Added csbindgen 1.9 as build-dependency. Created `build.rs` that generates `NativeMethods.g.cs` with `DS3Drive.Core` namespace. Created `build-xcframework.sh` that builds for 4 targets (aarch64-apple-darwin, aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios), generates Swift bindings via uniffi-bindgen, creates a fat simulator library via lipo, renames the modulemap to `module.modulemap`, and produces `DS3CoreFFI.xcframework`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] DS3Session fields were pub(crate)**
- **Found during:** Task 2
- **Issue:** FFI layer needs direct access to `http` and `urls` fields on DS3Session for project/key operations
- **Fix:** Changed fields from `pub(crate)` to `pub` in ds3-auth/src/session.rs
- **Files modified:** core/ds3-auth/src/session.rs

**2. [Rule 2 - Missing] authenticate_with_2fa not present on DS3Session**
- **Found during:** Task 2
- **Issue:** The verify_2fa FFI constructor needs to pass tfa_code through the auth flow, but DS3Session only had a no-2FA authenticate method
- **Fix:** Added `authenticate_with_2fa` method to DS3Session
- **Files modified:** core/ds3-auth/src/session.rs

**3. [Rule 3 - Blocking] DS3S3Client not Clone**
- **Found during:** Task 2
- **Issue:** FFI handle needs to clone the S3 client out of an RwLock guard
- **Fix:** Added `#[derive(Clone)]` to DS3S3Client (internally uses Arc-based aws_sdk_s3::Client)
- **Files modified:** core/ds3-s3/src/client.rs

**4. [Rule 3 - Blocking] TreeSnapshot missing from_map constructor**
- **Found during:** Task 2
- **Issue:** compute_diff FFI function needs to construct TreeSnapshot from deserialized HashMap
- **Fix:** Added `from_map` method to TreeSnapshot
- **Files modified:** core/ds3-sync/src/tree.rs

**5. [Rule 2 - Missing] S3DownloadResult and BucketInfo not in ds3-models**
- **Found during:** Task 1
- **Issue:** S3DownloadResult existed only in ds3-s3 without UniFFI derives; BucketInfo didn't exist at all. Both needed as FFI return types.
- **Fix:** Added both types to ds3-models/src/s3.rs with uniffi::Record derives
- **Files modified:** core/ds3-models/src/s3.rs, core/ds3-models/src/lib.rs

## Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Retrofit UniFFI derives on ds3-models | 56589d4 | ds3-models/Cargo.toml, account.rs, auth.rs, error.rs, s3.rs, sync.rs, project.rs, api_key.rs |
| 2 | UniFFI exports, C exports, panic guards, shared runtime | 33204c4 | uniffi_exports.rs, c_exports.rs, handles.rs, progress.rs, panic_guard.rs, session.rs |
| 3 | csbindgen build.rs and XCFramework build script | 040a1af | build.rs, build-xcframework.sh, Cargo.toml |

## Verification Results

- `cargo build -p ds3-ffi` succeeds with zero warnings
- `cargo test -p ds3-ffi` passes (5 tests: runtime singleton, block_on, panic guard success/error/panic)
- `cargo test --workspace` passes (73 total tests across all crates)
- `bash -n build-xcframework.sh` syntax check passes
- 20 of 23 extern "C" functions use `ffi_guard!` (3 exempt: free_string, free_bytes, session_destroy)
- 20 UniFFI Record/Enum/Error derives across ds3-models source files
- csbindgen generates NativeMethods.g.cs (10.7KB) with DS3Drive.Core namespace

## Known Stubs

None -- all FFI functions are wired to real implementations in downstream crates.

## Self-Check: PASSED
