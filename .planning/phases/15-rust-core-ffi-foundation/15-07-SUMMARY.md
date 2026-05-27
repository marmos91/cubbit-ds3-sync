---
phase: 15-rust-core-ffi-foundation
plan: 07
subsystem: testing-and-ci
tags: [integration-tests, panic-safety, ffi, swift-harness, csharp-harness, ci-pipeline]
dependency_graph:
  requires:
    - 15-01 (mono-repo structure)
    - 15-06 (FFI crate with UniFFI + csbindgen)
  provides:
    - Integration test suite for auth + S3 (feature-gated)
    - Panic safety test suite for FFI boundary
    - Swift test harness for XCFramework validation
    - C# test harness for P/Invoke validation
    - CI pipeline with Rust integration + C# Windows jobs
  affects:
    - .github/workflows/build.yml
    - core/ds3-auth/Cargo.toml
    - core/ds3-s3/Cargo.toml
    - core/ds3-ffi/Cargo.toml
tech_stack:
  added: []
  patterns:
    - Feature-gated integration tests (#[cfg(feature = "integration")])
    - FFI panic safety verification via direct Rust function calls
    - CI fork protection (secrets not exposed to fork PRs)
key_files:
  created:
    - core/ds3-auth/tests/integration.rs
    - core/ds3-s3/tests/integration.rs
    - core/ds3-ffi/tests/panic_tests.rs
    - core/tests/swift_harness/Package.swift
    - core/tests/swift_harness/Sources/main.swift
    - core/tests/csharp_harness/DS3CoreTest.csproj
    - core/tests/csharp_harness/Program.cs
  modified:
    - core/ds3-auth/Cargo.toml
    - core/ds3-s3/Cargo.toml
    - core/ds3-ffi/Cargo.toml
    - core/Cargo.lock
    - .github/workflows/build.yml
decisions:
  - "Integration tests gated behind feature flag to avoid requiring credentials for regular dev builds"
  - "Panic tests call FFI functions via Rust module path (not extern C) to avoid rlib linking issues"
  - "Added rlib to ds3-ffi crate-type to enable integration test compilation"
  - "C# harness uses self-contained P/Invoke declarations (no dependency on generated NativeMethods.g.cs)"
  - "CI integration tests conditional on DS3_TEST_EMAIL being set (skip if secrets unavailable)"
metrics:
  duration: 12m
  completed: 2026-05-27T12:16:27Z
---

# Phase 15 Plan 07: Integration Tests, FFI Safety, and CI Pipeline Summary

Rust integration tests (auth + S3 against real Cubbit), 9 FFI panic safety tests, Swift/C# test harnesses, and CI pipeline with Rust integration + Windows C# jobs.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Rust integration tests and panic safety tests | 6f0748f | ds3-auth/tests/integration.rs, ds3-s3/tests/integration.rs, ds3-ffi/tests/panic_tests.rs |
| 2 | Swift and C# test harnesses + CI | f44ed04 | tests/swift_harness/*, tests/csharp_harness/*, .github/workflows/build.yml |

## What Was Built

### Rust Integration Tests (feature-gated)

**ds3-auth integration tests** (`cargo test -p ds3-auth --features integration --test integration`):
- `test_authenticate` -- authenticates against real Cubbit IAM, asserts non-empty tenant_id and token
- `test_refresh_after_auth` -- verifies refresh_if_needed works post-auth
- `test_forge_iam_token` -- forges an IAM token using account.id, asserts non-empty token and positive exp
- `test_get_projects` -- fetches projects via ds3-http, asserts non-empty result

**ds3-s3 integration tests** (`cargo test -p ds3-s3 --features integration --test integration`):
- `test_list_objects` -- lists objects in test bucket (max 10)
- `test_upload_head_download_delete` -- full CRUD cycle with content verification
- `test_multipart_upload` -- 6MB file upload via multipart, progress callback verification
- `test_marker_operations` -- create/probe/delete .ds3keep folder markers

All integration tests use unique `ds3-test-{uuid}/` prefixes for isolation (T-15-20 mitigation). Tests exit cleanly if env vars are missing.

### FFI Panic Safety Tests

**ds3-ffi panic tests** (`cargo test -p ds3-ffi --test panic_tests`):
9 tests verifying null pointer handling across FFI boundary:
- `test_authenticate_null_email_returns_error` -- null email ptr returns error code
- `test_authenticate_null_password_returns_error` -- null password ptr returns error code
- `test_session_destroy_null_is_noop` -- null handle safely ignored
- `test_list_objects_null_handle_returns_error` -- null S3 handle returns error
- `test_free_string_null_is_noop` -- null pointer with zero length
- `test_free_string_null_with_nonzero_len_is_noop` -- null pointer with nonzero length
- `test_refresh_token_null_handle_returns_error` -- null session handle
- `test_account_info_null_handle_returns_error` -- null session handle
- `test_head_object_null_handle_returns_error` -- null S3 handle

All 9 tests pass. No test causes a crash, validating CORE-10 panic safety.

### Swift Test Harness

`core/tests/swift_harness/` -- Swift executable package consuming the DS3CoreFFI XCFramework. Tests authenticate, refresh, forge IAM token, get projects, connect S3, list objects, upload/download/delete cycle, compute_diff, and conflict_key. Prints "All Swift integration tests passed" on success.

### C# Test Harness

`core/tests/csharp_harness/` -- .NET 8 console app testing P/Invoke bindings. Self-contained NativeMethods declarations. Tests authenticate, account_info, refresh_token, get_projects, and null-handle panic safety. Prints "All C# integration tests passed" on success. Runs on Windows CI only (D-08).

### CI Pipeline Updates

Added two new jobs to `.github/workflows/build.yml`:
- **rust-test-integration** (ubuntu-latest): Runs panic safety tests unconditionally; runs integration tests when DS3_TEST_EMAIL is set. Fork-protected via same-repo check.
- **csharp-test** (windows-latest): Builds Rust cdylib, runs .NET C# harness with P/Invoke. Fork-protected.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed rlib crate-type for test linking**
- **Found during:** Task 1
- **Issue:** Integration tests in `tests/` need rlib linkage; ds3-ffi only had staticlib + cdylib
- **Fix:** Added `"lib"` to ds3-ffi crate-type array
- **Files modified:** core/ds3-ffi/Cargo.toml

**2. [Rule 3 - Blocking] Fixed extern "C" symbol linking in panic tests**
- **Found during:** Task 1
- **Issue:** `extern "C"` declarations in integration tests caused undefined symbol errors (rlib doesn't export C symbols)
- **Fix:** Rewrote panic tests to call FFI functions via Rust module path instead of extern "C" declarations
- **Files modified:** core/ds3-ffi/tests/panic_tests.rs

**3. [Rule 1 - Bug] Fixed DS3ApiKey field name mismatch**
- **Found during:** Task 2
- **Issue:** Integration test referenced `access_key_id` and `secret_access_key` but the Rust model uses `api_key` and `secret_key`
- **Fix:** Updated field names to match the DS3ApiKey struct definition
- **Files modified:** core/ds3-s3/tests/integration.rs

## Checkpoint Status

Task 3 is a `checkpoint:human-verify` requiring the developer to:
1. Build the XCFramework locally
2. Run integration tests with real Cubbit credentials
3. Run the Swift test harness
4. Verify panic safety tests

This checkpoint gates the first real credential use through the Rust core.

## Known Stubs

None -- all test harnesses are fully implemented and ready for execution.

## Threat Flags

None -- all security surfaces (credential handling, test isolation, fork protection) are covered by the plan's threat model.

## Self-Check: PASSED

All created files verified present. Both commits verified in git log.
