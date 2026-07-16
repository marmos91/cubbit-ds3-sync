-- Migration 003: per-(drive, prefix) sync anchor for the poll short-circuit (D-06).
--
-- Apple analog: NSFileProviderSyncAnchor persisted per container. The poll computes a
-- SyncAnchorHash over the full remote key->etag map each tick; when the new anchor equals
-- the stored one, nothing under the prefix changed and the diff/apply is skipped entirely
-- (macOS currentSyncAnchor parity). The anchor is a derived cache value, not user data —
-- a dropped row simply forces one full re-diff on the next poll.
--
-- Stored per (drive_id, prefix): a drive rooted at the bucket uses prefix '' while a
-- sub-prefix drive uses its S3 prefix, so the pair is the container identity.

CREATE TABLE prefix_anchors (
  drive_id   TEXT NOT NULL,
  prefix     TEXT NOT NULL,
  anchor     TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (drive_id, prefix),
  FOREIGN KEY (drive_id) REFERENCES drives(id) ON DELETE CASCADE
);

INSERT INTO schema_version (version, applied_at) VALUES (3, CURRENT_TIMESTAMP);
