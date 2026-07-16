# DS3 Drive v3.0 — Enterprise Platform Spec Set (index)

Brainstormed 2026-07-16. Turns the direct-to-S3 sync client into a **server-mediated, multi-tenant, self-hosted enterprise SaaS** on Cubbit DS3. Execution starts **after v2.0.0 Windows wraps**. Branch: `feat/enterprise-platform-v3`.

## Read in this order
1. **[north-star](2026-07-16-enterprise-platform-northstar-design.md)** — the map + locked foundation.
2. **[Layer 0 — Foundation](2026-07-16-layer0-foundation-design.md)** — server, `/v2` API, auth, provisioning, presigned data plane, push, schema, benchmark/test gates. *(build first; backend flawless before clients)*
3. **[Layer 1 — Sharing](2026-07-16-layer1-sharing-design.md)** — grants, GDrive-style governance, links, deferred external blueprint.
4. **[Layer 1 — Versioning & Trash](2026-07-16-layer1-versioning-design.md)** — S3 versions + index, 90-day retention, irreversible-delete-safe trash.
5. **[Layer 1 — Audit & Force-Disconnect](2026-07-16-layer1-audit-forcedisconnect-design.md)** — tamper-evident audit, export/SIEM, revoke+drop.
6. **[Layer 2 — Web Dashboards](2026-07-16-layer2-web-dashboards-design.md)** — 3 personas, Next.js/shadcn, i18n, the primary v1 client.
7. **[Layer 2 — Mobile](2026-07-16-layer2-mobile-design.md)** — dual in-app browser + re-pointed FileProvider, offline-native.
8. **[Cross-cutting — Whitelabel & VPN/Proxy](2026-07-16-crosscutting-whitelabel-vpn-design.md)** — build-time branding, system proxy + custom CA.

## Decision summary (the load-bearing calls)
- **Data plane:** presigned URLs, bytes client↔DS3 direct, no proxy in v1. **Identity:** Zitadel (authN + per-org SSO), Keycloak-swappable seam. **Server:** Rust/axum reusing `core/`. **Data:** Postgres (SoT) + Redis (day 0). **Push:** WebSocket :443 (+ APNs for mobile background).
- **Tenancy:** two-level — reseller self-hosts a **branded instance** → many SMB **orgs** (each = DS3 project/bucket). Target ~10k orgs × ~10 users × ~10TB → design-to-scale, deploy small.
- **Perms:** folder-level inherited + flat groups. **Sharing:** internal + admin-governed links (GDrive-style); cross-org deferred. **Versioning:** S3-native + trash. **Audit:** immutable + exportable.
- **Surfaces:** web dashboards (primary v1 client) → mobile dual. **Whitelabel:** build-time. **i18n + multilanguage:** first-class.
- **Order:** backend (e2e-tested + benchmarked, *flawless*) → web → native.

## ⚠️ Confirm before execution (DS3 / Zitadel team)
| # | Item | Impact if unavailable |
|---|---|---|
| 1 | Presigned URLs | ✅ **confirmed** |
| 2 | DS3 **management APIs** (project/bucket/IAM CRUD) at endpoint | blocks per-org provisioning |
| 3 | DS3 **presigned multipart** part-URL signing | large-upload path |
| 4 | DS3 **bucket CORS** (`PutBucketCors`) | **web** browser must proxy uploads/downloads (reopens proxy for web only) |
| 5 | DS3 **lifecycle** (`NoncurrentVersionExpiration`) | fall back to app prune job |
| 6 | DS3 **single-version DELETE** (`?versionId=`) | version pruning mechanism |
| 7 | DS3 **presign invalidation on key rotation** | force-disconnect nuclear option |
| 8 | **Zitadel** at ~100k users/~10k orgs, per-org SSO, session-termination + org-provisioning APIs | identity core |
| 9 | Rust core HTTP: **system-proxy + OS-trust-store** | VPN/proxy + custom CA |
| — | STS | ✅ confirmed **not** supported — design accounts for it |

## Human-readable spec (for collaborators)
**[2026-07-16-v3-enterprise-platform-SPEC.md](2026-07-16-v3-enterprise-platform-SPEC.md)** — a single narrative document consolidating the whole set (also exported to a Google Doc). Includes **operations** (Prometheus/Loki/Grafana + feature flags) and a **future-directions** section (v2 in-browser editing + billing + migration + SCIM; zero-knowledge folders; ransomware rollback + compliance/WORM; LAN/delta sync; v4 AI-over-files; OCR; collaboration & mobile polish).

## Next
`superpowers:writing-plans` → phased implementation plan for **Layer 0**, once Windows v2.0.0 is done.
