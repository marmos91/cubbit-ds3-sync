# DS3 Drive v3.0 — Layer 1: Versioning & Trash (deep-dive spec)

**Status:** Draft. Third per-part deep-dive. Extends Layer 0 + north-star.
**Date:** 2026-07-16
**Build order:** backend-first (extends `/v2`), before client UI.

---

## 1. Scope
Full version history with preview + restore (match Dropbox/GDrive/Nextcloud/Proton), on **S3-native versioning** + a Postgres **version index**. Plus an app-level **trash**, because **DS3 versioned deletes are irreversible** — normal deletes must never hard-delete.

### Locked decisions
| Topic | Decision |
|---|---|
| Storage | S3-native bucket versioning (enabled at org provisioning) + Postgres `file_version` index. |
| Retention | **Admin-configurable window, default 90 days.** Lifecycle prunes non-current versions older than the window. |
| Delete | **Soft-delete (trash)** via Postgres flag — S3 object untouched. No irreversible S3 delete except explicit purge/prune. |
| Restore | Previous version → S3 CopyObject(version-id)→new current. Trashed file → clear flag. Both push a change event. |

---

## 2. Delete / trash design (the careful bit)
- **Delete** = set `node.deleted_at` + `trashed_by` in Postgres. Object stays at its S3 key, hidden from namespace listings. **No S3 DELETE issued** → no delete marker, nothing irreversible.
- **Trash view** lists soft-deleted nodes; **restore** clears the flag (+ push). 
- **Purge** (manual or after trash window) = the *only* place we issue an S3 delete. By then it's intentional and past the safety window.
- `ponytail:` soft-delete is a Postgres flag, not an S3 move — no byte copy, no delete markers, cheap and reversible. The irreversible-delete footgun is simply never on the normal path.

## 3. Version lifecycle
- Every `commit` (Layer-0 upload flow) creates a new S3 version → append `file_version` row, flip `is_current`.
- **Prune job** (per org, scheduled): delete non-current `file_version`s older than the org's retention window, and their S3 version-ids (`DELETE ?versionId=`). **Never touches the current version.**
- **Prefer S3 lifecycle** (`NoncurrentVersionExpiration`) if DS3 supports it (offloads pruning to storage); else the app prune job. → open item.

## 4. Restore semantics
- **Restore a version:** `CopyObject` from the chosen `s3_version_id` to a new current version → update `node.current_version_id`, append `file_version`, append `change_event` → push. (Non-destructive: history preserved.)
- **Restore from trash:** clear `deleted_at` → node reappears → push.

## 5. API additions (`/v2`)
- `GET /v2/files/{id}/versions` → `[{version_id, size, hash, author, created_at, is_current}]`
- `GET /v2/files/{id}/versions/{vid}/content` → presigned GET of that version (preview/download old)
- `POST /v2/files/{id}/restore {version_id}`
- `DELETE /v2/nodes/{id}` → **soft-delete** (trash)
- `GET /v2/trash` · `POST /v2/trash/{id}/restore` · `DELETE /v2/trash/{id}` (**permanent purge**)
- `GET|PUT /v2/orgs/{id}/retention-policy` (window days)

## 6. Schema (extends Layer-0)
```
file_version(id, node_id, s3_version_id, size, hash, author, created_at, is_current)   -- index; org-scoped via node
node: + deleted_at, + trashed_by                                                        -- soft-delete
retention_policy(org_id PK, version_window_days default 90, trash_window_days default 30)
```
`file_version` grows with edits — org-scoped + partition-ready like the rest. Prune keeps it bounded per the window.

## 7. Tests (e2e)
- version-list + version-content (presigned) correct; **restore** creates a new current, preserves history.
- **soft-delete** hides node but keeps S3 object; **restore-from-trash** works; **purge** is the only S3 delete.
- **prune** removes only non-current versions older than window; **never** the current version; per-org isolation.
- negative: no cross-org version access/restore.
- **Benchmark:** version-list p99 < 100ms (org-scoped index).

## 8. Open items
- DS3 **lifecycle rule** support (`NoncurrentVersionExpiration`) — prefer over app prune job; confirm.
- Confirm **single-version DELETE** (`?versionId=`) works on DS3 for pruning.
- Trash window vs retention window: independent knobs (trash default 30d, versions default 90d) — confirm resellers want both.

## 9. Next
Continue deep-dives (Audit + force-disconnect, then Dashboards), or `writing-plans` once Layer 1 backend is fully defined.
