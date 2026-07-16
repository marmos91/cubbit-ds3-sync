# DS3 Drive v3.0 — Layer 2: Web Dashboards (deep-dive spec)

**Status:** Draft. Fifth per-part deep-dive. Consumes the fully-defined backend (Layer 0 + Layer 1).
**Date:** 2026-07-16
**Note:** The **end-user dashboard is the primary v1 client** (web-only greenfield) — a real file manager, not a secondary surface.

---

## 1. Scope & decisions
| Topic | Decision |
|---|---|
| App | **One Next.js (App Router) + TypeScript app**, role-gated (super-admin / org-admin / user areas). |
| UI | **Tailwind + shadcn/ui** (Radix), themed via **CSS variables**. |
| Whitelabel | **Build-time** — swap a token file + asset bundle (logo, colors, product name, support links) per reseller; one theme per instance build. |
| Auth | BFF (httpOnly cookie, from Layer-0), calls `/v2`. |
| Preview (v1) | PDF + image inline; Office = thumbnail + download. **Full GDocs-style editing = v2.** |
| Build order | **super-admin → org-admin → end-user** (must configure + provision + invite before the user surface is usable). |
| Multilanguage | **i18n first-class** — `next-intl` (frontend) + **per-user locale** + **localized backend emails/notifications** (invites, shares). Cross-cutting: also applies to mobile. |

## 2. Per-persona scope
**Super-admin (reseller operator):** first-run config (DS3 endpoint + creds, instance settings), **org lifecycle** (create / suspend / delete org, assign first org-admin), instance **usage/stats** (storage, orgs, users, activity), **instance-wide audit** + export, **force-disconnect** (sessions), health/license.

**Org-admin (end-customer admin):** **members** (invite / remove / role), **groups** (CRUD + membership), **sharing policy**, retention/audit policy, **per-org audit** + export, **external-sharing view** (active links), org usage.

**End-user (the product):** **file manager** — folder tree, list/grid, drag-drop upload, download, PDF/image preview, Office thumbnail+download; **sharing** (create links within policy, my-links, shared-with-me / by-me); **trash** (restore / purge); **version history** (list / preview / restore); **account** (profile, active sessions/devices, notifications).

## 3. Architecture
- Next.js App Router; RSC for data fetch, client components for interactivity (upload, drag-drop, live updates).
- **Browser ↔ DS3 direct** via Layer-0 presigned URLs (PUT/multipart part URLs / GET). Server never in the byte path — *if CORS works* (see risk).
- **WebSocket** (`/v2/events`) drives live updates (new files, sync status, trash, shares).
- **i18n from day 1** (`next-intl`) — resellers localize (e.g. TIM → Italian).

## 4. ⚠️ Key risk — browser presigned needs DS3 CORS
Browser `fetch` PUT/GET to the DS3 gateway with a presigned URL requires the bucket to allow the dashboard origin via **CORS** (`PutBucketCors`). **Confirm DS3 supports bucket CORS.** If it does **not**, the *web* data plane must fall back to the **proxy tier** (server streams bytes for browser up/download) — reopening "no proxy in v1" **for the web client only** (native clients can still presign direct). This is the #1 thing to verify before building the file manager.

## 5. Other open items
- **Office/PDF thumbnails** need server-side rendering (LibreOffice-headless / pdfium) — a small thumbnail-render service or an extension of `DS3Thumbnails` (which today does images only).
- **Large-upload UX** — presigned multipart + progress; docs are small so resumable is nice-to-have, not v1.
- A few branding bits (support email, product name) — build-time per the whitelabel decision; confirm none need runtime per-org override.
- **Backend i18n:** add `member.locale` (Layer-0 schema) + localized server-side email/notification templates; instance default locale set at build/config.

## 6. Testing
- **Playwright** e2e per persona journey (super-admin provisions org → org-admin invites → user uploads/previews/shares/restores).
- Component tests; a11y baseline from Radix/shadcn; visual-regression on the themeable token layer.

## 7. Design direction
Visual/UX direction (layout, information density, brand-neutral base theme that whitelabels cleanly) to be developed via the **frontend-design** skill at implementation time — not during this spec. Requirements above are the contract it fills.

## 8. Next
Mobile in-app browser, then cross-cutting Whitelabel / VPN-proxy — or `writing-plans` for the backend + dashboards.
