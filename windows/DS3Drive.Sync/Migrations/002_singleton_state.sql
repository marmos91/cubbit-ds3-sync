-- Migration 002: singleton_state key/value table (PATTERNS §2.6, CONTEXT D-14).
--
-- Holds small, single-row install-scoped settings that are NOT secrets and NOT
-- build-time defaults (those live in Credential Manager / appsettings.json
-- respectively). First consumer: the stable installation_id used in the
-- deterministic API-key name (PATTERNS §2.6, threat T-17-09-04) — generated once
-- via Guid.NewGuid() on first run and persisted here so the same API key name
-- round-trips across launches and matches what the Cubbit console shows.

CREATE TABLE singleton_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO schema_version (version, applied_at) VALUES (2, CURRENT_TIMESTAMP);
