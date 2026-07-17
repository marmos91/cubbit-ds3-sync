# DS3 Drive v3.0 — Layer 1: Sharing, Permissions & Links (deep-dive spec)

**Status:** Draft. Second per-part deep-dive. Extends Layer 0 (`2026-07-16-layer0-foundation-design.md`) and the north-star.
**Date:** 2026-07-16
**Build order:** backend-first (extends the `/v2` API), e2e-tested + benchmarked, before dashboard/client UI.

---

## 1. Scope

**v1:** internal sharing (within an org) + **admin-governed public/private links** for external collaborators. **No cross-org accounts.**
**Deferred (own phase):** cross-org / external *named* sharing — via **guest identities + domain allowlists**, per the Google-visitor / Box-collaborator / Dropbox-approved-list pattern. Design leaves room; does not build it now.

### Locked decisions
| Topic | Decision |
|---|---|
| Boundary | Internal shares + public/private links. No cross-org account sharing (deferred). |
| Grant model | Folder-level, **inherited** (via node materialized path); roles **viewer / editor / owner**; principals = **members + flat groups**. |
| Resolution | Effective role = **most-permissive** across direct + group + inherited grants. |
| Governance | **GDrive-style: org-admin sets policy/defaults; any member creates within it.** |
| Links | Presigned-backed (no proxy). Scopes: **view / download / upload (file-request)**. Optional password + expiry, bounded by admin policy. |

---

## 2. Governance model (org sharing policy)

Per-org policy, set by org-admin, enforced server-side on every share/link action:
- `links_enabled` (bool) — kill switch for public links.
- `default_link_expiry` / `max_link_expiry` — user picks within the cap.
- `require_link_password` (off / optional / enforced).
- `allowed_link_scopes` — subset of {view, download, upload}.
- (deferred) `external_domain_allowlist` — for future named external sharing.

**Within policy, any member can create shares/links** on nodes they hold editor/owner on. Changing folder-level *permissions* (adding/removing grants) requires **owner** on that folder (or org-admin). Policy is **forward-only** — tightening it doesn't retro-revoke existing links (matches GDrive/Dropbox); an audit view surfaces existing shares for manual cleanup.

---

## 3. Flows

**Internal share:** member picks a folder + a member/group + role → `permission` row inserted → email notification. Invitee is already an org member (internal only), so no account provisioning.

**Public/private link — create:** on a node, create a link with scope + optional password + expiry (within policy) → returns stable `token`. Stored in `public_link`.

**Public link — anonymous access:** `GET /v2/l/{token}` → validate active + not expired + password (if set) → **mint a short-lived presigned GET** (download) or a preview response (view) → client fetches bytes **direct from DS3**. For **upload/file-request** links: mint a presigned **PUT** into the link's target folder. `ponytail:` the token is stable and revocable; the presigned URL is minted per-access and short-lived — no standing exposure, no proxy.

**Revoke:** disable/delete the `public_link` row (immediate) or remove a `permission` row. Presigned URLs already handed out expire on their own short TTL.

---

## 4. API additions (`/v2`)

- **Permissions:** `GET|POST /v2/nodes/{id}/permissions`, `DELETE /v2/nodes/{id}/permissions/{pid}`
- **Internal share (notify):** `POST /v2/nodes/{id}/share` (member/group + role + optional message → grant + email)
- **Links:** `POST /v2/links`, `GET|PATCH|DELETE /v2/links/{id}`
- **Public resolve (unauthenticated):** `GET /v2/l/{token}` (metadata/preview), `POST /v2/l/{token}/content` (→ presigned GET), `POST /v2/l/{token}/upload` (→ presigned PUT)
- **Org policy:** `GET|PUT /v2/orgs/{id}/sharing-policy`

---

## 5. Schema (extends Layer-0 stubs)

```
permission(id, org_id, node_id, principal_type[member|group], principal_id, role[viewer|editor|owner])
public_link(id, org_id, node_id, token, scope[view|download|upload], password_hash?, expires_at, created_by, disabled, created_at)
sharing_policy(org_id PK, links_enabled, default_link_expiry, max_link_expiry, require_link_password, allowed_link_scopes jsonb)
-- share_invite(...) retained but unused in v1 (external named sharing deferred)
```
Authz check = one indexed ancestor-prefix query over `permission` by node `path` (folder-inherited) → holds the Layer-0 `<10ms` target.

---

## 6. Audit (feeds the Audit section)
Log `share.grant`, `share.revoke`, `link.create`, `link.revoke`, `link.access` (with actor / target / ip) to `audit_event`. The **external-sharing view** (org-admin) lists all active links + external grants for policy cleanup.

---

## 7. Deferred: cross-org / external named sharing (own phase)
When added, follow the competitor blueprint — **do not** open tenant buckets to each other:
- **Guest identities:** external email → a *scoped guest* (Zitadel guest user) that sees only shared nodes (Google visitor / Box collaborator model), optional email/PIN verification.
- **Domain allowlist** in org policy (Dropbox approved-list / Google trusted domains).
- Server mints presigned URLs against the *owning* org's bucket for the guest, gated by the grant.
- Forward-only policy + external-sharing audit view.

---

## 8. Tests (e2e, extends Layer-0 suite)
- **Authz matrix:** viewer can't write; editor can't change perms; only owner/admin edits grants; most-permissive resolution correct.
- **Isolation:** cross-org access denied everywhere.
- **Links:** anonymous download works; expired/disabled/wrong-password denied; upload-link writes only into its target folder; revoke is immediate for new access.
- **Governance:** link creation blocked when `links_enabled=false`; expiry clamped to `max_link_expiry`; enforced password required.

## 9. Open items
- Preview (view-scope) rendering: presigned GET + client-side render vs. a thumbnail service — decide in the dashboard phase.
- File-request (upload link) quota/limits to prevent abuse — simple per-link size/count cap for v1.

## 10. Next
Continue section deep-dives (Versioning / Audit / Dashboards), or `writing-plans` once enough of Layer 1 is defined.
