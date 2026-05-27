---
phase: 15-rust-core-ffi-foundation
plan: 04
subsystem: ds3-s3
tags: [s3, aws-sdk, multipart, crud, markers]
dependency_graph:
  requires: [15-02]
  provides: [ds3-s3-crate, s3-client, s3-crud, multipart-upload, folder-markers]
  affects: [15-06, 15-07]
tech_stack:
  added: [aws-sdk-s3, aws-config, aws-smithy-types, percent-encoding, futures]
  patterns: [force_path_style, url-decoding, multipart-concurrent-upload, marker-based-folders]
key_files:
  created:
    - core/ds3-s3/src/client.rs
    - core/ds3-s3/src/list.rs
    - core/ds3-s3/src/crud.rs
    - core/ds3-s3/src/transfer.rs
    - core/ds3-s3/src/multipart.rs
    - core/ds3-s3/src/markers.rs
  modified:
    - core/ds3-s3/src/lib.rs
    - core/ds3-s3/Cargo.toml
    - core/Cargo.lock
decisions:
  - Used behavior_version_latest() for aws-sdk-s3 client config (required by SDK v1.133)
  - Used percent-encoding crate for URL decoding (mature, minimal dependency)
  - Used futures::stream::buffer_unordered for bounded multipart concurrency
  - Applied allow(clippy::too_many_arguments) on internal upload_parts helper
metrics:
  duration: 10m 49s
  completed: 2026-05-27T11:35:44Z
  tasks_completed: 2
  tasks_total: 2
  tests_added: 15
  tests_passing: 15
---

# Phase 15 Plan 04: DS3 S3 Client Crate Summary

Complete ds3-s3 crate implementing S3 CRUD, multipart upload with concurrent parts and progress callbacks, and .ds3keep folder marker management using aws-sdk-s3 with force_path_style and custom Cubbit endpoint.

## One-liner

S3 client wrapping aws-sdk-s3 with URL-decoded listings, 5MB/4-concurrent multipart uploads, and .ds3keep folder marker operations.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | DS3S3Client, list, and CRUD operations | 0732155 (tests), 9aaef57 (impl) | client.rs, list.rs, crud.rs, lib.rs |
| 2 | Transfers, multipart upload, and markers | 5293357 | transfer.rs, multipart.rs, markers.rs |

## TDD Gate Compliance

- RED commit: `0732155` - 15 failing tests (decode_s3_key, normalize_etag, client construction, marker_key, is_ds3keep_marker_key, compute_parts)
- GREEN commits: `9aaef57` (Task 1 impl), `5293357` (Task 2 impl) - all 15 tests pass
- No REFACTOR step needed - implementation is clean

## Implementation Details

### DS3S3Client (client.rs)
- Constructor with `force_path_style(true)`, `endpoint_url`, `behavior_version_latest()`, custom credentials
- `decode_s3_key`: replaces `+` with `%20` then percent-decodes (matches Swift `decodeS3Key`)
- `normalize_etag`: strips surrounding double-quotes from ETag strings
- Constants: `LIST_BATCH_SIZE=2000`, `DELIMITER="/"`, `MULTIPART_PART_SIZE=5MB`, `MULTIPART_THRESHOLD=5MB`, `MULTIPART_CONCURRENCY=4`, `TIMEOUT_SECONDS=300`, `MAX_RETRIES=5`, `MARKER_FILE_NAME=".ds3keep"`

### Listing (list.rs)
- `list_objects`: ListObjectsV2 with encoding_type=url, URL-decodes keys and prefixes
- `list_buckets`: returns `Vec<(name, creation_date)>` pairs

### CRUD (crud.rs)
- `head_object`: returns `S3ObjectMetadata` with normalized etag
- `delete_object`: single object deletion
- `delete_objects`: batch deletion using S3 Delete with quiet mode
- `copy_object`: intra-bucket copy with optional metadata replacement
- `is_not_found_error`: checks for NoSuchKey/404 in error messages

### Transfers (transfer.rs)
- `download_object`: streams body chunk-by-chunk to file with progress callback
- `upload_object`: auto-selects multipart for files > 5MB threshold, returns normalized ETag

### Multipart (multipart.rs)
- `compute_parts`: divides file into `PartDescriptor` list with correct offsets and lengths
- `upload_multipart`: create -> concurrent uploads (buffer_unordered with limit 4) -> complete, with abort-on-error
- `abort_multipart_upload`: cleanup for failed uploads
- Progress tracking via `AtomicI64` counter across concurrent parts

### Markers (markers.rs)
- `marker_key`: computes `.ds3keep` path for any folder key variant
- `is_ds3keep_marker_key`: identifies marker files by name/path suffix
- `probe_folder_exists`: HeadObject on marker key, returns bool
- `create_folder_marker`: PutObject with empty body
- `copy_folder_marker`: copies marker with fallback to fresh creation on NotFound

## Threat Mitigations Applied

| Threat | Mitigation |
|--------|------------|
| T-15-09 (credentials in logs) | `#[tracing::instrument(skip(access_key, secret_key))]` on `DS3S3Client::new` |
| T-15-11 (multipart upload leak) | `abort_multipart_upload` called in error path of `upload_multipart` |
| T-15-12 (ETag validation) | `normalize_etag` strips quotes consistently across all operations |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added behavior_version_latest() to client config**
- **Found during:** Task 1 GREEN phase
- **Issue:** aws-sdk-s3 v1.133 requires `behavior_version_latest()` in config builder, panics without it
- **Fix:** Added `.behavior_version_latest()` to config builder chain
- **Files modified:** core/ds3-s3/src/client.rs
- **Commit:** 9aaef57

**2. [Rule 3 - Blocking] Added aws-smithy-types dependency**
- **Found during:** Task 2 implementation
- **Issue:** ByteStream type requires aws-smithy-types for S3 body handling
- **Fix:** Added `aws-smithy-types = "1"` to Cargo.toml
- **Files modified:** core/ds3-s3/Cargo.toml
- **Commit:** 9aaef57

## Verification

```
cargo test -p ds3-s3 --lib: 15 passed, 0 failed
cargo clippy -p ds3-s3 -- -D warnings: clean
cargo check --workspace: clean
```

Constants match Swift: MULTIPART_PART_SIZE=5MB, MULTIPART_CONCURRENCY=4, MARKER_FILE_NAME=".ds3keep"

## Self-Check: PASSED

All 8 key files verified present. All 3 commits (0732155, 9aaef57, 5293357) found in git log.
