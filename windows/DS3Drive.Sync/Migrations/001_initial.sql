-- Initial schema for the DS3 Drive Windows sync engine (PATTERNS §3.4, CONTEXT D-11/D-14).
--
-- Apple analog: apple/DS3Lib/Sources/DS3Lib/Metadata/SyncedItemSchemaV7.swift.
-- All structured runtime data (drives, sync anchors, placeholder index, api keys,
-- account info) lives here; secrets (secretKey / refreshToken) live in Windows
-- Credential Manager (Plan 05, D-12), never in this database.
--
-- WAL is mandatory (D-11): cfapi callbacks read the placeholder index while the
-- sync engine writes it concurrently. WAL gives multiple readers + one writer
-- without blocking.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);

CREATE TABLE drives (
  id            TEXT PRIMARY KEY,         -- Guid
  name          TEXT NOT NULL,
  bucket        TEXT NOT NULL,
  prefix        TEXT,
  project_id    TEXT NOT NULL,
  iam_user_id   TEXT NOT NULL,
  local_root_path TEXT NOT NULL,
  paused        INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  last_synced_at TEXT
);
CREATE INDEX idx_drives_bucket ON drives(bucket);

CREATE TABLE placeholders (
  drive_id      TEXT NOT NULL,
  s3_key        TEXT NOT NULL,
  parent_key    TEXT,
  etag          TEXT,
  size          INTEGER NOT NULL,
  last_modified TEXT,
  is_folder     INTEGER NOT NULL DEFAULT 0,
  is_dirty      INTEGER NOT NULL DEFAULT 0,
  sync_status   TEXT NOT NULL DEFAULT 'unknown',  -- 'cloud-only' | 'syncing' | 'synced' | 'error'
  last_seen_at  TEXT NOT NULL,
  PRIMARY KEY (drive_id, s3_key),
  FOREIGN KEY (drive_id) REFERENCES drives(id) ON DELETE CASCADE
);
CREATE INDEX idx_placeholders_parent ON placeholders(drive_id, parent_key);
CREATE INDEX idx_placeholders_dirty ON placeholders(drive_id, is_dirty) WHERE is_dirty = 1;
CREATE INDEX idx_placeholders_status ON placeholders(drive_id, sync_status);

CREATE TABLE api_keys (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  access_key    TEXT NOT NULL,
  iam_user_id   TEXT NOT NULL,
  created_at    TEXT NOT NULL
);   -- secretKey lives in Credential Manager (Plan 05), NOT here
CREATE INDEX idx_api_keys_iam_user ON api_keys(iam_user_id);

CREATE TABLE account_info (
  account_id    TEXT PRIMARY KEY,
  email         TEXT NOT NULL,
  display_name  TEXT,
  tenant_id     TEXT,
  updated_at    TEXT NOT NULL
);

INSERT INTO schema_version (version, applied_at) VALUES (1, CURRENT_TIMESTAMP);
