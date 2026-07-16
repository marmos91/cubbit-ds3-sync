# DS3 Drive v3.0 — Layer 1: Audit & Force-Disconnect (deep-dive spec)

**Status:** Draft. Fourth per-part deep-dive. Extends Layer 0 + north-star. **Closes out the backend.**
**Date:** 2026-07-16
**Build order:** backend-first, before client UI.

---

## 1. Scope
Append-only, tamper-evident audit with per-user + org + instance views, configurable retention, and export/SIEM pull. Queryable (no real-time streaming — decided). Plus **force-disconnect** of users/clients.

### Locked decisions
| Topic | Decision |
|---|---|
| Delivery | **Queryable** history (no streaming). |
| Integrity | **Append-only + hash-chain** (tamper-evident). DB audit-writer role: INSERT/SELECT only. |
| Retention | **Configurable per org**, default 365 days. |
| Export | CSV/JSON export + cursor **pull endpoint** a SIEM can poll (`?since=seq`). |
| Views | Per-user + org-wide (org-admin); instance-wide (super-admin). |

---

## 2. What's audited
Auth (login, logout, failed login, force-disconnect), provisioning (org create/delete, member invite/remove/role change), file ops (upload, download, delete/trash, restore, move, rename, purge), sharing (grant, revoke, link create/revoke/**access**), settings (sharing policy, retention, SSO, DS3 endpoint config). Anonymous link access is captured with `actor_type=guest` + ip.

## 3. Integrity & retention
- **Append-only**; no UPDATE/DELETE code path; enforced by a dedicated DB role.
- **Hash-chain:** each row stores `hash = H(prev_hash ‖ row)`. Verifiable, tamper-evident. `ponytail:` a hash column, not a blockchain.
- **Retention:** prune > `retention_days` (default 365). Partition `audit_event` by month for cheap prune + query at scale.

## 4. API additions (`/v2`)
- Org-admin: `GET /v2/orgs/{id}/audit?actor=&action=&from=&to=&since=seq`, `GET /v2/orgs/{id}/audit/export?format=csv|json`
- Super-admin: `GET /v2/admin/audit` (instance-wide, same filters)
- Policy: `GET|PUT /v2/orgs/{id}/audit-policy` (retention_days)
- Force-disconnect: `GET /v2/admin/sessions`, `DELETE /v2/admin/sessions/{id}` (instance); `…/orgs/{id}/sessions` (org-admin, own org)

## 5. Force-disconnect mechanics
Three layers, escalating:
1. **Revoke Zitadel session/token** via the `IdentityProvider` port (management API: terminate session).
2. **Redis revocation denylist** — `revoked:{session_id}` / `revoked_user:{member_id}` (TTL = max access-token lifetime). The Layer-0 auth middleware checks it on every request → **revoked token rejected immediately**, despite stateless JWT. *(Requires Layer-0: short access-token TTL, e.g. 5–15 min, + this denylist check — noted as a Layer-0 auth addendum.)*
3. **Drop WebSocket(s)** — publish a `disconnect` command over Redis to whichever instance holds the connection (via the events hub); connection closed at once.
- **Nuclear option:** rotate the org's DS3 credentials → invalidates any outstanding presigned URLs (confirm DS3 invalidates presigns on key rotation). Reserve for compromise scenarios.

## 6. Schema (extends Layer-0)
```
audit_event(id, org_id, seq, actor_type[member|guest|system], actor_id,
            action, target_type, target_id, metadata jsonb, prev_hash, hash, created_at)   -- partition by month
audit_policy(org_id PK, retention_days default 365)
-- revocation lives in Redis (denylist), not Postgres
```

## 7. Tests (e2e)
- Each action type emits an event with correct actor/target/ip; hash-chain verifies; append-only (no mutate path).
- Retention prune drops only > window; per-user/org/instance queries correctly scoped; export format valid.
- **Force-disconnect:** revoked token rejected within one TTL window; WebSocket dropped across instances (Redis); denylist honored on every node.
- Negative: org-admin can't read/force-disconnect **other** orgs.

## 8. Open items
- Zitadel **session-termination / token-revocation** API — confirm surface via management API.
- DS3 presign **invalidation on key rotation** — confirm (drives the nuclear option).
- Layer-0 auth addendum: short access-token TTL + Redis denylist check (fold into Layer-0 plan).

## 9. Next
**Backend fully defined** (Layer 0 + Sharing + Versioning + Audit). Next: client surfaces — **Web dashboards** (super-admin → org-admin → user), then Mobile, plus cross-cutting Whitelabel / VPN-proxy. Or `writing-plans` for the backend now.
