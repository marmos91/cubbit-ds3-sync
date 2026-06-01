---
phase: 17-windows-shell
plan: 06
subsystem: windows-sync-storage
tags: [sqlite, persistence, schema-migration, placeholder-index, enumeration]
requires:
  - "17-02: DS3Drive.Sync project scaffold + Microsoft.Data.Sqlite reference"
provides:
  - "SyncDatabase: SQLite store at %LOCALAPPDATA%\\Cubbit\\DS3Drive\\sync.db with versioned migrations + silent schema recovery"
  - "PlaceholderStore: composite-key CRUD over the placeholders table"
  - "EnumerationDiff: C# reference port of Apple EnumerationDiff.swift"
  - "001_initial.sql: 5-table schema (drives, sync_anchors→placeholders, api_keys, account_info, schema_version)"
affects:
  - "17-09 drive setup wizard (INSERT drives)"
  - "17-10 cfapi sync engine (UPSERT placeholders, read on every FETCH_DATA)"
  - "17-11 tray (SELECT drives + last_synced_at)"
tech-stack:
  added: []
  patterns:
    - "EmbeddedResource SQL migrations enumerated via GetManifestResourceStream"
    - "schema_version probed through sqlite_master before SELECT (no pre-create)"
    - "Cache-not-user-data schema recovery: delete .db/.db-shm/.db-wal + retry once"
    - "Fully parameterized SqliteCommand (no string-interpolated SQL values)"
key-files:
  created:
    - windows/DS3Drive.Sync/Storage/EnumerationDiff.cs
    - windows/DS3Drive.Sync/Storage/SyncDatabase.cs
    - windows/DS3Drive.Sync/Storage/SchemaMigrator.cs
    - windows/DS3Drive.Sync/Migrations/001_initial.sql
    - windows/DS3Drive.Sync/SyncEngine/PlaceholderStore.cs
    - windows/DS3Drive.Tests/EnumerationDiffTests.cs
    - windows/DS3Drive.Tests/SyncDatabaseTests.cs
    - windows/DS3Drive.Tests/PlaceholderStoreTests.cs
  modified:
    - windows/DS3Drive.Sync/DS3Drive.Sync.csproj
decisions:
  - "schema_version table is created by migration 001 itself, NOT pre-created by SchemaMigrator — pre-creation would make the 001 CREATE TABLE conflict; applied-versions are read defensively via sqlite_master probe"
  - "Private cache mode (not shared); WAL alone provides the concurrent cfapi-reader/engine-writer behaviour D-11 requires for a file-backed store"
  - "PRAGMA journal_mode=WAL is set on the connection before migration AND appears in 001_initial.sql for documentation; inside the migration transaction it is a harmless SQLite no-op"
metrics:
  duration: 8min
  completed: 2026-05-29
---

# Phase 17 Plan 06: SQLite Persistence Layer Summary

SQLite-backed persistence for the Windows sync engine — the Apple `SharedData` + `MetadataStore` analog: a versioned `sync.db` at `%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db` (D-11) with five tables, a composite-key `PlaceholderStore` CRUD facade, silent schema recovery (cache, not user data), and a unit-testable `EnumerationDiff` ported verbatim from `EnumerationDiff.swift`.

## What Was Built

**Task 1 — EnumerationDiff (TDD):** `EnumerationDiff.Compute(local, remote)` returns an `EnumerationDelta(NewOrModified, Deleted)`. Pure key→etag diff: `added ∪ modified → NewOrModified`, `localKeys − remoteKeys → Deleted`. Null-tolerant ordinal ETag comparison (`string.Equals(a, b, Ordinal)`) matches Swift optional semantics — two nulls equal, null vs string not equal. 8 parity tests green. Carries the D-17 cross-reference: production calls Rust `ds3_compute_diff`; this is the deterministic reference.

**Task 2 — SyncDatabase + 001_initial.sql + SchemaMigrator:**
- `001_initial.sql`: `schema_version`, `drives`, `placeholders` (PK `(drive_id, s3_key)`, FK→drives ON DELETE CASCADE, 3 indexes incl. partial `idx_placeholders_dirty`), `api_keys`, `account_info`. WAL pragma. Embedded resource.
- `SchemaMigrator`: enumerates embedded `Migrations/00N_*.sql`, orders by version, applies missing ones in a transaction; reads applied versions defensively (sqlite_master probe → empty if table absent).
- `SyncDatabase`: opens at the D-11 path (dir auto-created), sets WAL+foreign_keys on the connection, runs migrations; on `SqliteException` clears pools, deletes `.db/.db-shm/.db-wal`, retries once (PATTERNS §2.12). `AcquireConnectionAsync` opens a pooled connection with `PRAGMA foreign_keys = ON`. 4 tests green (fresh-open, corrupt-recovery, reentrant-dispose, no-reapply).

**Task 3 — PlaceholderStore CRUD (TDD):** `PlaceholderRecord` record + `PlaceholderStore` with `UpsertAsync` (ON CONFLICT DO UPDATE), `FindAsync`, `DeleteAsync`, `ListByPrefixAsync`, `ListDirtyAsync`, `MarkDirtyAsync`, `SetSyncStatusAsync`. Every query uses `SqliteParameter`/`AddWithValue` (24 bindings) — no interpolated SQL values. 10 tests green incl. FK cascade and a `DROP TABLE` injection payload stored verbatim with schema intact.

## Verification

- `dotnet build DS3Drive.Sync -p:DS3SkipRustCore=true` → 0 warnings, 0 errors.
- `dotnet test DS3Drive.Tests --filter "Category!=Integration" -p:DS3SkipRustCore=true` → **49 passed, 0 failed** (8 EnumerationDiff + 4 SyncDatabase + 10 PlaceholderStore + 27 pre-existing).
- All acceptance greps satisfied (Compute=1, swift/D-17=2, ds3_compute_diff=1; 5 CREATE TABLE, WAL≥1, FK≥1, 3 placeholder indexes, MetadataStore comment≥1, LocalApplicationData≥1, EmbeddedResource≥1; AddWithValue=24, ON CONFLICT DO UPDATE=1, dirty/status methods=3).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] SchemaMigrator double-created `schema_version`, so migration 001 was skipped and the version row never inserted**
- **Found during:** Task 2 — all 3 row-counting SyncDatabaseTests returned 0 rows.
- **Issue:** `SchemaMigrator.EnsureSchemaVersionTableAsync` pre-created the `schema_version` table; migration 001 also contains `CREATE TABLE schema_version`. The interaction left the migration in a state where its terminal `INSERT INTO schema_version VALUES (1, ...)` did not land.
- **Fix:** Removed the pre-create. `GetAppliedVersionsAsync` now probes `sqlite_master` for the table and returns an empty set when absent, letting migration 001 own its own `schema_version` creation. Also switched the connection from `Cache=Shared` to `Cache=Private` (shared cache is for in-memory DBs and added no value to a file-backed store; WAL provides the required concurrency).
- **Files modified:** `windows/DS3Drive.Sync/Storage/SchemaMigrator.cs`, `windows/DS3Drive.Sync/Storage/SyncDatabase.cs`
- **Commit:** f59172d (fix folded into the Task 2 feat commit before first green)

## Known Stubs

None. All three components are fully wired against a real SQLite store and exercised by tests.

## TDD Gate Compliance

- Task 1: `test(17-06)` (c272357, RED) → `feat(17-06)` (0d31ba8, GREEN). No refactor needed.
- Task 3: `test(17-06)` (b81dcf0, RED) → `feat(17-06)` (ede536f, GREEN). No refactor needed.
- Task 2 was a non-TDD `type="auto"` task; its tests and implementation landed together (f59172d) with the bug fix folded in before first green, as the plan specified for that task.

## Self-Check: PASSED

All created files verified on disk; all commit hashes present in `git log`.
