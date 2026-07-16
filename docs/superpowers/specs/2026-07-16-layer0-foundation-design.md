# DS3 Drive v3.0 — Layer 0 Foundation (deep-dive spec)

**Status:** Draft. First per-part deep-dive under the north-star (`2026-07-16-enterprise-platform-northstar-design.md`).
**Date:** 2026-07-16
**Scope discipline:** **Backend must be flawless (e2e-tested + benchmarked) before any client.** Sequence: **backend/API → web app → native clients**.

---

## 1. What Layer 0 is

The server-mediated spine, proven end-to-end on the smallest surface: **web-only, greenfield** (new orgs; existing native clients keep running direct-to-S3, untouched). No sharing/versioning/audit UI yet — just enough to prove auth + provisioning + namespace + presigned data plane + push, as a **documented, benchmarked `/v2` API** plus a thin web client.

### Locked decisions (from the deep-dive)
| Topic | Decision |
|---|---|
| MVP surface | Web-only, greenfield. Backend-first. |
| API | `/v2` REST + **OpenAPI**, a **first-class public product** (third-party integration), not just the web backend. |
| Tenancy | Two-level: reseller **instance** (self-hosted, branded) → many **orgs**. Instance connects to a configured **Cubbit DS3 instance** (on-prem/cloud). |
| Storage | **Presigned URLs**, bytes client↔DS3 direct. Server is **sole writer** to org buckets → Postgres is authoritative namespace. |
| Identity | **Zitadel** = authN + per-org SSO (org ↔ Zitadel org 1:1). **Postgres owns orgs/groups/perms.** IdP behind an `IdentityProvider` trait (Keycloak-swappable). |
| Permissions | **Folder-level, inherited + flat groups.** Roles: viewer / editor / owner. |
| Provisioning | **Reseller (super-admin) creates orgs + first org-admin**; org-admin invites users. Self-serve org signup exists but **disabled by default**. |
| Scale (per instance) | **Target: ~10k end-customer orgs (SMBs), each ~10TB docs (PDF/Word) / millions of files → tens of billions of objects; ~10k+ concurrent.** Reseller is large (e.g. a telco); its customers are SMBs. **v1 posture: partition-ready + org-scoped hot paths, prove at pilot volume, scale the DB tier later** (replicas → hash-partitioning → Citus/shard). "Scale later," not "build distributed now." |
| Data tier | Postgres (SoT) + **Redis day 0** (pub/sub, presence, cache). |
| Deploy | Docker / K8s, self-hosted, build-time whitelabel. |

---

## 2. Server structure (Rust/axum, reusing `core/`)

```
ds3-server (axum bin)   — routing, middleware (authn/z), handlers, OpenAPI
├── ds3-domain (new)    — orgs, members, groups, namespace, folder-inherited perms (pure logic)
├── ds3-db (new)        — Postgres via sqlx; migrations; partition-ready schema
├── ds3-idp (new)       — IdentityProvider trait + ZitadelProvider impl (mgmt API)
├── ds3-events (new)    — Redis pub/sub + WebSocket hub + resumable change feed
├── ds3-provision (new) — DS3 management API client (project/bucket/IAM CRUD)
├── ds3-s3 (reuse)      — S3 ops + presign (add presign helpers if missing)
└── ds3-models (reuse)  — shared types
```
`ponytail:` reuse `ds3-s3`/`ds3-models`; the only genuinely new logic is domain + db + events + idp + provision. No new S3/signing code.

---

## 3. Domain model (Postgres sketch)

All app tables carry `org_id` (partition-ready). Folder-inherited perms resolved via a **materialized path** on nodes (single indexed ancestor-prefix query — hits the <100ms folder-list / <10ms authz targets without recursive walks).

```
organization(id, zitadel_org_id, name, ds3_project_id, ds3_bucket, status, created_at)
member(id, org_id, zitadel_user_id, email, role[admin|member], status, created_at)   -- v1: user ∈ one org
group(id, org_id, name)
group_member(group_id, member_id)
node(id, org_id, parent_id, path, name, kind[file|folder], s3_key,
     size, content_hash, etag, current_version_id, created_by, updated_at)            -- namespace; root per org
permission(id, org_id, node_id, principal_type[member|group], principal_id,
           role[viewer|editor|owner])                                                  -- on folders; inherited by path
share_invite(id, org_id, node_id, email, role, token, status, expires_at)             -- pending email invites
public_link(id, org_id, node_id, token, mode[view|download], expires_at, password_hash?) -- L1 detail, table stubbed
file_version(id, node_id, s3_version_id, size, hash, author, created_at)              -- index over S3-native versions
change_event(id, org_id, seq, node_id, type, actor, created_at)                        -- monotonic seq/org → push + resumable sync
audit_event(id, org_id, actor, action, target, metadata, created_at)                   -- append-only, partition by created_at
client_session(id, member_id, ws_conn_id, device, last_seen)                           -- presence + force-disconnect
```
`ponytail:` **every hot-path query is strictly org-scoped**, so latency stays independent of instance-wide object count. Indexes on `(org_id, parent_id)`, `(org_id, path)`, `(org_id, seq)`. **org_id hash-partitioning is the design basis**; enable it as data grows → read-replicas → **Citus** (distributed Postgres) toward the tens-of-billions target. Don't build distributed now — org-scoped keys make it addable without a schema rewrite. (If the top end proves too big even for Citus, a wide-column namespace store is the escape hatch — deferred.)

---

## 4. `/v2` API surface (OpenAPI-first)

Grouped by audience. All authz enforced server-side before any DS3 access.

- **Auth/session:** `POST /v2/session` (BFF token exchange, httpOnly cookie), `GET /v2/me`
- **Super-admin (reseller):** `PUT /v2/admin/config` (DS3 endpoint/creds), `POST|GET|DELETE /v2/admin/orgs`, `GET /v2/admin/usage`, `GET /v2/admin/audit`, `GET|DELETE /v2/admin/sessions` (**force-disconnect**)
- **Org-admin:** `…/orgs/{id}/members` (invite/CRUD), `…/groups`, `…/settings` (per-org SSO), `…/audit`
- **Files/namespace:** `GET /v2/nodes/{id}/children`, `POST /v2/folders`, `POST /v2/files` (→ presigned PUT / multipart part URLs), `POST /v2/files/{id}/commit` (etag+versionId, optimistic-concurrency check), `GET /v2/files/{id}/content` (→ presigned GET), `POST /v2/nodes/{id}/{move|rename}`, `DELETE /v2/nodes/{id}`
- **Sharing (L1 surface, stubbed in L0):** `…/nodes/{id}/permissions`, `POST /v2/shares`, `POST /v2/links`
- **Push:** `GET /v2/events` (WebSocket, `?since={seq}` to resume)
- **Third-party integration:** same `/v2`, authenticated via **Zitadel service users / OAuth client-credentials** (machine tokens).

---

## 5. Key flows

**Provision org (super-admin):** create Zitadel org (via `IdentityProvider`) → create DS3 **project + bucket** (versioning on) via `ds3-provision` → insert `organization` + root `node` → assign first org-admin (Zitadel user + `member` role=admin). Target < a few seconds; idempotent + rollback on partial failure.

**Login:** OIDC Auth-Code + PKCE against the org's Zitadel org (branded `auth.…`) → web gets httpOnly cookie (BFF), native gets token in secure store → `/v2` validates JWT vs Zitadel JWKS, resolves `member`/`org`/`role` from Postgres.

**Upload:** `POST /v2/files {path,size,expectedVersion}` → authz (path-prefix perm) + optimistic version check → presigned PUT (multipart if large) → client PUTs bytes to DS3 direct → `commit` records `file_version`, bumps `node`, appends `change_event` → Redis fan-out → WebSocket push to other sessions.

**Download:** authz → presigned GET → client fetches from DS3 direct.

---

## 6. Push (WebSocket + Redis)

WebSocket on `:443`. On write, server appends a `change_event` (monotonic `seq` per org) and publishes to Redis; every server instance subscribes and forwards to its connected sessions for that org. Client tracks last `seq`; on reconnect, `GET /v2/events?since=seq` replays missed events from Postgres (durable, no lost changes). `ponytail:` no custom broker — Redis pub/sub + a Postgres change feed is the whole mechanism.

---

## 7. Non-functional gates — "flawless" is a checklist, not a vibe

**Benchmark targets (measured at pilot volume with partitioning on, CI regression-gated):**
- authz check p99 **< 10ms** · folder-list (1000 children) p99 **< 100ms** · presign issue p99 **< 50ms**
- change → push delivered **< 1s** · org provisioning **< 5s** · **10k+** concurrent WebSocket connections/instance (target; prove at pilot, scale WS tier horizontally via Redis)
- targets must **hold as instance object count grows** — validated against a DB seeded to pilot scale; hot paths are org-scoped so per-org latency ≠ f(total objects)
- (byte throughput is DS3's, not ours — server never in the path; docs are small so multipart is rare)

**e2e test strategy:**
- Rust integration tests hitting the live axum server over HTTP, backed by **testcontainers** (Postgres, Redis, Zitadel).
- **Contract tests** validated against the OpenAPI doc.
- **Journey tests:** provision org → invite → login → create folder → upload → (share → download as invitee) → push received.
- **Negative authz tests:** cross-org access denied, revoked grant denied, stale-version write rejected.
- Load/benchmark harness (`oha`/`k6` or Rust) in CI with thresholds.

**Definition of done (exit criteria before any client work):**
1. Every `/v2` endpoint: happy + key error paths covered e2e. 2. All benchmark targets met in CI. 3. All negative-authz + optimistic-concurrency tests green. 4. OpenAPI published + contract-validated. 5. Provisioning idempotent + rollback-safe. 6. Runs from a single `docker compose up` (+ K8s manifests).

---

## 8. Namespace source-of-truth assumption
The sync server is the **sole writer** to each org's bucket → Postgres is authoritative; **no S3↔DB reconciliation loop needed** in v1. If out-of-band bucket writes ever become a requirement, add a reconciler then. `ponytail:` don't build reconciliation for a bucket only we write to.

## 9. Open items / risks (confirm before execution)
- **DS3 management APIs** at the configured endpoint (project/bucket/IAM CRUD) — needed for provisioning. Confirm surface + on-prem parity.
- **Presigned multipart** flow against the DS3 gateway — confirm part-URL signing works as with AWS.
- **Zitadel org provisioning** via management API + per-org SSO config at scale — validate self-host ops.
- Membership is **one-user-one-org** in v1; multi-org membership deferred (schema via `member` allows adding later).

## 10. Next
`superpowers:writing-plans` → phased implementation plan for Layer 0 (execution starts after Windows v2.0.0 wraps).
