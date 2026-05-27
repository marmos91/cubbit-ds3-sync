---
phase: 15-rust-core-ffi-foundation
plan: 05
subsystem: ds3-sync
tags: [sync, diff, conflict, pure-computation, tdd]
dependency_graph:
  requires: [ds3-models (DiffResult type)]
  provides: [compute_diff, conflict_key, TreeSnapshot]
  affects: [ds3-ffi (will consume sync exports)]
tech_stack:
  added: []
  patterns: [set-based diff, NSString-compatible path splitting]
key_files:
  created:
    - core/ds3-sync/src/tree.rs
    - core/ds3-sync/src/diff.rs
    - core/ds3-sync/src/conflict.rs
    - core/ds3-sync/tests/sync_tests.rs
  modified:
    - core/ds3-sync/src/lib.rs
decisions:
  - "TreeSnapshot wraps HashMap<String, Option<String>> with inner() accessor for diff"
  - "conflict_key uses manual string splitting (rfind) instead of std::path::Path to match S3 forward-slash semantics"
  - "NSString.pathExtension behavior replicated: .hidden treated as no-extension, last dot splits name/ext"
metrics:
  duration: 4m 27s
  completed: 2026-05-27T11:29:39Z
  tests: 22 passed
  files_created: 4
  files_modified: 1
---

# Phase 15 Plan 05: Sync Diff and Conflict Naming Summary

Pure-computation sync crate with set-based diff and deterministic conflict key generation matching Swift EnumerationDiff and ConflictNaming formats exactly.

## TDD Gate Compliance

- RED commit: `904c7b5` - `test(15-05): add failing tests for sync diff and conflict key`
- GREEN commit: `732d0bf` - `feat(15-05): implement sync diff and conflict key`
- REFACTOR commit: `c158c63` - `refactor(15-05): simplify compute_diff to single-pass filter`

All three gates present in correct order.

## What Was Built

### TreeSnapshot (`tree.rs`)
HashMap wrapper mapping S3 object keys to optional ETags. Provides `new()`, `insert()`, `get()`, `keys()`, `len()`, `is_empty()`, and a crate-internal `inner()` accessor used by the diff function.

### compute_diff (`diff.rs`)
Pure function comparing local and remote TreeSnapshot instances. Returns a `DiffResult` (from ds3-models) with `new_or_modified` and `deleted` HashSets. Algorithm: single-pass filter over remote keys checking local presence and ETag equality, then set difference for deletions. Matches Swift `EnumerationDiff.compute` semantics including `None` vs `Some` ETag handling.

### conflict_key (`conflict.rs`)
Deterministic conflict key generator producing S3 keys in the format `"name (Conflict on hostname YYYY-MM-DD HH-MM-SS nonce).ext"`. Carefully replicates NSString path splitting behavior:
- `.hidden` files (dot-prefixed, no other dot) treated as name-only with no extension
- Multi-dot files like `c.tar.gz` split at last dot: name=`c.tar`, ext=`gz`
- Parent path preserved from S3 key structure using forward-slash splitting
- Default 4-char lowercase hex nonce from UUID

### Test Coverage (22 tests)
- TreeSnapshot: 5 tests (empty, insert/get, None etag, keys, overwrite)
- compute_diff: 9 tests (add, modify, identical, delete, mixed, both-empty, None etag variants)
- conflict_key: 8 tests (standard, root-level, hidden, no-ext, multi-dot, default nonce, deep path, hostname with spaces)

## Verification

```
cargo test -p ds3-sync: 22 passed, 0 failed
cargo clippy -p ds3-sync -- -D warnings: clean
```

## Deviations from Plan

None - plan executed exactly as written.

## Decisions Made

1. **Manual string splitting over std::path::Path** - S3 keys use forward slashes universally. Using `std::path::Path` would introduce platform-dependent behavior on Windows (backslash). Manual `rfind('/')` is correct for S3 key semantics.

2. **Single-pass filter for compute_diff** - Refactored from the initial two-set-then-union approach to a single iterator over remote keys with a match on local map presence. Cleaner and avoids intermediate allocations.

3. **inner() accessor on TreeSnapshot** - Exposes the underlying HashMap as `pub(crate)` to allow diff.rs direct access without re-implementing the iteration logic. The accessor is not part of the public API.

## Self-Check: PASSED
