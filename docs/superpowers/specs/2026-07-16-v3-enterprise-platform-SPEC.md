# DS3 Drive 3.0 — Enterprise Platform Specification

*Version 1.0 · 16 July 2026 · Status: Draft for review*

---

## 1. Executive summary

DS3 Drive today is a **desktop and mobile sync client**: it logs a user into Cubbit, then talks directly to Cubbit DS3 (S3-compatible) storage to sync files, showing them as a native drive in Finder, the iOS Files app, and Windows Explorer.

This specification describes **DS3 Drive 3.0**, a transformation of that client into a **complete, self-hosted, white-labeled enterprise file platform** — a "Dropbox for Cubbit" that a large enterprise (for example, a telecommunications operator) can run on its own infrastructure and resell to its own business customers under its own brand.

The change is significant: we move from a client that talks straight to storage, to a **server-mediated platform** with its own identity layer, sharing and permissions, versioning, audit, web dashboards, and mobile apps. Crucially, we do this **without turning our server into a bottleneck** — file bytes continue to travel directly between the user's device and Cubbit storage, while our server governs *who is allowed to do what*.

This document is the north star for that effort. It is organized so that the foundation (the server and its API) is defined first and built first — "the backend must be flawless before we add the clients" — followed by the enterprise features and the user-facing applications.

---

## 2. Where DS3 Drive is today

- **Clients:** native apps for macOS, iOS/iPadOS, and (in progress) Windows, built on a shared Rust core for storage and authentication.
- **How it works:** each client authenticates to Cubbit and receives storage credentials, then reads and writes files directly against Cubbit DS3.
- **Deliberate limitation:** there is **no backend of our own**. This kept the product simple, but it means every user effectively holds storage credentials, and there is no central place to manage users, share folders, enforce permissions, or serve a web experience.

Every capability requested for 3.0 — a managed identity layer, sharing, permissions, a web console, per-organization provisioning, audit — requires a backend. So 3.0 is, at its heart, the introduction of that backend and the re-shaping of the product around it.

---

## 3. What we are building

DS3 Drive 3.0 introduces a **Sync Server** — a control plane — and re-points the applications to it. The platform will provide:

1. **A managed identity layer** so end users never see raw storage credentials, with support for enterprise single sign-on (SAML/OIDC) and per-organization identity.
2. **A sync backend** that authenticates users, pushes changes to clients in real time (instead of polling), and holds the authoritative picture of every organization's files.
3. **Sharing, permissions, and links** — invite colleagues to folders, create public or password-protected links, with granular, admin-governed control.
4. **Versioning and trash** — full file history with restore, and a safe recycle bin.
5. **Web dashboards** for three audiences: the platform operator, the organization administrator, and the end user.
6. **Refreshed mobile apps** that browse files inside the app (like Dropbox), not only through the system Files integration.
7. **Audit logs and remote disconnect** for compliance and security.
8. **White-labeling** so each reseller ships the product under its own brand.
9. **Per-organization data isolation**, with a dedicated storage bucket/project created automatically for each customer.

---

## 4. Product model and the people who use it

The defining characteristic of 3.0 is a **two-level model**.

**Level 1 — the reseller.** A large enterprise self-hosts its own branded instance of DS3 Drive (via Docker/Kubernetes) connected to a Cubbit DS3 instance. This is *their* product, sold under *their* name to *their* customers. One reseller = one deployment = one brand.

**Level 2 — the reseller's customers.** Within a single reseller's instance, **many organizations** (typically small and medium businesses) sign up. Each organization has its own users, groups, permissions, and shared folders, and its own isolated storage. So each instance is itself multi-tenant.

This yields three distinct roles, each with its own dashboard:

| Role | Who they are | What they do |
|---|---|---|
| **Platform operator** (super-admin) | The reseller running the instance | Connect the instance to Cubbit storage, create and manage customer organizations, see usage and audit across the whole instance, disconnect users |
| **Organization administrator** | An admin at a customer business | Invite and manage users, create groups, set sharing policy, review their organization's audit log |
| **End user** | A member of a customer organization | Browse, upload, download, preview, share, and restore their files |

Organizations are created by the reseller (who assigns each one its first administrator); that administrator then invites the rest of the team. Fully self-service sign-up is supported but **switched off by default**, so resellers control who joins.

---

## 5. System architecture

### 5.1 The core idea: separate control from data

The platform cleanly separates two responsibilities:

- **The control plane (our Sync Server)** decides *who may do what*: it authenticates users, stores the file directory structure, enforces permissions, records history and audit, and notifies clients of changes. It handles only small messages, never file contents.
- **The data plane** carries the actual file bytes, and it flows **directly between the user's device and Cubbit storage** — never through our server.

We connect the two using **pre-signed URLs**. When a user wants to upload or download a file, the client asks the server; the server checks the user's permission, then issues a short-lived, single-file URL that the client uses to talk to Cubbit storage directly. The user never holds a lasting credential, every action is permission-checked, and our server never becomes a bandwidth bottleneck. This is the same principle Dropbox and Google Drive use (a dedicated data path separate from the control path), adapted to Cubbit.

### 5.2 Components

```
   Users (web / desktop / mobile)
        │  sign in
        ▼
   Identity provider (Zitadel) — branded login, SSO per organization
        │  token
        ▼
   SYNC SERVER  (control plane, Rust)
     • verifies identity            • authoritative file directory (PostgreSQL)
     • permissions / sharing        • real-time change notifications (WebSocket)
     • versioning / audit           • issues pre-signed URLs
     • provisions a bucket per org  • holds the Cubbit storage credentials
        │                                    │
        │ small control messages             │ short-lived pre-signed URL
        ▼                                    ▼
   Client apps  ───────── file bytes (direct) ─────────►  Cubbit DS3 storage
                ◄──────── file bytes (direct) ──────────  (one bucket per org)
```

Supporting pieces: **PostgreSQL** holds the authoritative directory, permissions, versions, and audit; **Redis** carries real-time notifications between server instances and enables horizontal scaling. Both run inside the reseller's deployment.

### 5.3 Technology choices at a glance

- **Sync Server:** Rust (axum web framework), reusing the existing DS3 Rust core so storage and authentication logic is not rewritten.
- **Identity:** Zitadel, self-hosted — chosen because organizations are a first-class concept in it and it supports SAML/OIDC single sign-on out of the box. The design keeps identity swappable (e.g., to Keycloak) behind a small internal interface.
- **Database:** PostgreSQL for all metadata; Redis for messaging and caching.
- **Web dashboards:** Next.js + TypeScript, styled with Tailwind and shadcn/ui so branding is a matter of swapping design tokens.
- **Storage:** Cubbit DS3, one bucket/project per organization, with native versioning enabled.
- **Operations:** Prometheus metrics, Loki logs, Grafana dashboards, and OpenTelemetry tracing — the standard self-hosted observability stack, shipped with the deployment.

---

## 6. Key decisions and why

| Decision | Rationale |
|---|---|
| **File bytes go directly to storage via pre-signed URLs; our server is control-plane only** | Keeps Cubbit's distributed storage advantage, avoids a bandwidth bottleneck, and means users never hold lasting storage credentials. Confirmed viable — Cubbit DS3 supports pre-signed URLs. |
| **Buy identity (Zitadel), don't build it** | Identity, single sign-on, and multi-factor authentication are solved problems; building them is a costly distraction. Zitadel's organization model fits our two-level design. |
| **PostgreSQL is the source of truth for the file directory; storage holds only bytes** | Sharing, permissions, versioning, and audit need a real transactional database. Because our server authorizes every change, it always knows the current state — no guessing or reconciliation. |
| **Real-time updates over a persistent connection, not polling** | Faster, lighter, and a better experience; the connection runs over the standard HTTPS port so it passes through corporate networks and VPNs. |
| **One bucket/project per organization** | Clean, automatic data isolation between customers. |
| **Backend first, fully tested and benchmarked, before any client** | The platform's correctness and performance are foundational; clients are built on a proven, stable API. |
| **White-labeling at build time** | Each reseller gets a branded build; a single instance carries a single brand, which matches the self-hosted reseller model. |

---

## 7. How it works — core user journeys

**Creating a customer organization.** The reseller's operator creates an organization from the platform dashboard. Behind the scenes the server creates a matching organization in the identity provider, provisions a dedicated storage bucket (with versioning enabled), records the organization in the database, and assigns its first administrator. This completes in seconds and is safe to retry.

**Signing in.** A user signs in through the branded login page. Enterprise customers can connect their own single sign-on. The application receives a secure token, which it presents to the server on every request; the server verifies it and looks up the user's organization and role.

**Uploading a file.** The client tells the server it wants to save a file. The server checks the user's permission and that the file hasn't changed underneath them, then returns a short-lived upload URL. The client sends the bytes straight to Cubbit storage, then confirms completion. The server records the new version and instantly notifies the user's other devices and collaborators.

**Downloading or previewing.** The server checks permission and returns a short-lived download URL; the client fetches the bytes directly from storage. In the web app, PDFs and images preview inline; on mobile, the system previewer also handles Office documents.

**Sharing a folder.** A user invites a colleague (by choosing them within the organization) or creates a link. Links can be view-only, download, or upload ("file request"), and can carry a password and an expiry — all within limits the organization's administrator has set. For a public link, when someone opens it the server validates the link and mints a one-time download URL; there is no lasting exposure.

**Restoring a previous version.** The user opens a file's history, previews an earlier version, and restores it. Restoring brings the old version back as the new current version without erasing history.

---

## 8. Feature areas in detail

### 8.1 Foundation (built first)

The foundation is the Sync Server and its public API, proven end-to-end on a **web-only** experience for **new** organizations, while today's existing clients keep working unchanged. It includes: identity integration and branded login; automatic per-organization provisioning; the authoritative file directory; the pre-signed upload/download flow with conflict detection; and real-time change notifications.

The server exposes a **documented, versioned API** (`/v2`) that is a first-class product in its own right — enterprises can integrate it with their own systems. Every endpoint is covered by automated end-to-end tests, and performance targets are enforced continuously. The foundation is considered complete only when the API is fully tested, meets its benchmarks, passes strict security checks (for example, no user can ever reach another organization's data), and runs from a single command.

### 8.2 Sharing, permissions, and links

Permissions are set on folders and inherited by their contents, with three roles — **viewer, editor, owner** — and can be granted to individuals or to **groups**. Sharing is **internal** (within an organization) plus **public/private links** for outside collaborators; cross-organization account sharing is intentionally deferred to a later phase, following the "guest account" pattern established by Google, Box, and Dropbox.

Governance follows the Google Drive model: the **organization administrator sets the policy and defaults** (whether links are allowed, maximum expiry, whether passwords are required), and **within those limits any member can share**. Administrators get a view of all active external links for periodic clean-up.

### 8.3 Versioning and trash

Every change creates a new version, backed by Cubbit's native storage versioning, with a fast history index for the user interface. **Retention is configurable, defaulting to 90 days**, after which older versions are pruned to control storage cost.

Deleting a file moves it to a **trash** (a soft delete) rather than removing it immediately — an important safety measure, because permanently deleting a specific version in storage cannot be undone. Files can be restored from trash, and only an explicit purge removes them for good.

### 8.4 Audit and remote disconnect

The platform keeps an **append-only, tamper-evident audit log** of significant actions (sign-ins, sharing, file operations, administrative changes), with configurable retention (default one year), per-user and organization-wide views, and export for compliance and security tooling.

Administrators can **force-disconnect** a user or device: the server revokes the identity session, immediately drops the live connection, and — in the most serious cases — can rotate the organization's storage credentials to invalidate any outstanding access.

### 8.5 Web dashboards

A single Next.js application serves all three roles, gated by permission. Because the foundation ships web-first, the **end-user dashboard is the primary application for version 1** — a genuine file manager with folder navigation, drag-and-drop upload, download, sharing, version history, and trash. For version 1, PDFs and images preview inline and Office documents show a thumbnail with download-to-open; **full in-browser document editing is planned for version 2**. The dashboards are built in the order operator → administrator → end user, and are **multilingual** from the outset.

### 8.6 Mobile apps

The iOS/iPadOS apps gain an **in-app file browser** (browse, preview, upload, download, share, restore) alongside the existing system Files integration — a "dual" model like Dropbox. Files already downloaded remain **available offline** through the existing system integration, so offline works without building a separate cache. Because mobile devices cannot hold a live connection in the background, the server will send **push notifications** to wake the app when files change. Desktop apps keep their native Finder/Explorer integration, re-pointed to the new server.

### 8.7 White-labeling and networking

**White-labeling** is applied at build time: each reseller supplies a branding bundle (logo, colors, product name, support links), and the build produces a branded web app, branded mobile apps (published under the reseller's own store accounts), and a branded login page. It is a configuration bundle, not a complex theming engine.

**Networking** is kept deliberately simple: the apps honor the operating system's proxy settings and corporate certificate authorities, so they work inside enterprise networks and VPNs with no special client. Real-time updates run over the standard HTTPS port, which corporate networks already allow.

### 8.8 Operations: monitoring and feature flags

Because each reseller self-hosts the platform, it ships with a standard, self-hosted **observability stack**: the Sync Server exposes **Prometheus** metrics, emits structured logs collected by **Loki**, provides **Grafana** dashboards, and supports **OpenTelemetry** tracing across requests. Operators get health, performance, and capacity visibility out of the box, and this underpins the performance targets in Section 9.

**Feature management** starts deliberately lightweight. The platform already carries per-organization policy switches in its database (for example, whether public links are allowed, or whether self-service sign-up is enabled) and per-reseller options in the build-time branding bundle; together these cover most needs. A dedicated feature-flag service (such as a self-hosted **Unleash**) can be added later if the platform needs runtime, gradual, or targeted rollouts — noted as an upgrade path, not built for version 1.

---

## 9. Scale and performance

A single reseller instance is designed to serve on the order of **10,000 organizations, roughly 10 users each (~100,000 users), each storing about 10 TB of documents** — tens of billions of files in total. The architecture is designed to scale from day one (every operation is scoped to a single organization, the server is stateless, and the real-time layer scales horizontally), while the intention is to **deploy modestly at first and scale the database tier as volume grows** rather than build for maximum scale immediately.

Performance is treated as a contract, with continuously enforced targets — for example, permission checks under ~10 ms, folder listings under ~100 ms, and change notifications delivered in under a second — validated against realistically-sized data.

---

## 10. Delivery roadmap

Work proceeds in layers, backend-first:

1. **Foundation** — Sync Server, identity, provisioning, pre-signed data plane, real-time updates, fully tested and benchmarked. *(This is the "make it flawless" phase.)*
2. **Enterprise features** — sharing/permissions/links, versioning/trash, audit/force-disconnect (extensions of the backend).
3. **Surfaces** — web dashboards (operator → administrator → end user), then the mobile in-app browser.
4. **Cross-cutting** — white-labeling and networking, wired in early and kept thin.

Execution begins after the current Windows milestone is completed. The end-user experience is the ultimate goal, but it is built last because it depends on the operator and administrator capabilities existing first.

### Beyond version 1 — future directions

The following are out of scope for the first release but recorded as intended directions. Each will get its own specification when its time comes; they are captured here so the foundation does not preclude them.

**Near-term (version 2):**

- **Full in-browser document editing** — a Google-Docs-style experience for viewing and co-editing Office documents in the web app, with comments and activity, going beyond version 1's preview-and-download.
- **Per-organization billing and metering** — usage metering and plans so resellers can bill their own customers. Close to a requirement for the reseller business model rather than a nice-to-have.
- **Migration tools** — one-click import from Dropbox, Google Drive, OneDrive, and Box. The strongest lever for winning customers away from incumbents.
- **SCIM and directory sync** — automatic user provisioning from a customer's Azure AD / Okta. Table stakes for large enterprise deals.

**Differentiators that lean on Cubbit's strengths:**

- **Zero-knowledge / end-to-end encrypted folders** — client-side encryption so not even the reseller can read protected folders. A strong trust and sovereignty proposition for regulated customers.
- **Ransomware detection and one-click mass restore** — detect abnormal bulk changes and roll an organization back. Builds directly on versioning and is a compelling data-protection story.
- **Compliance suite** — legal hold, immutable retention (WORM / object-lock), data-loss-prevention and sensitive-data (PII) detection, eDiscovery export, and data-residency reporting that leverages Cubbit's geo-distributed storage.
- **LAN / peer sync and block-level delta sync** — transfer only changed blocks, and directly between devices on the same office network. Bandwidth-efficient and aligned with Cubbit's distributed model.

**AI and content intelligence (version 4):**

- **AI over your files** — generating embeddings of document contents so users can ask natural-language questions about their own data (retrieval-augmented search and Q&A), semantic search, automatic summaries, and automatic classification of sensitive content (which doubles as a compliance feature). This fits the existing stack — vector search can reuse PostgreSQL (pgvector) and an ingestion step can hook into the existing upload flow to extract and embed text — but it is a future undertaking.
- **Optical character recognition (OCR)** for scanned documents, making everything full-text searchable.

**Collaboration and mobile polish:**

- Real-time co-editing, comments, @mentions, and an activity feed.
- Mobile camera upload / auto-backup and document scanning (scan-to-PDF).

These are directional notes, not commitments.

---

## 11. Open questions to confirm before build

A small number of storage- and identity-platform capabilities need confirmation with the Cubbit DS3 and Zitadel teams. Each has a clear fallback, so none blocks the design.

| Item | Why it matters | If unavailable |
|---|---|---|
| Pre-signed URLs | The whole direct-data-path model | **Confirmed available** |
| Temporary (STS) credentials | An alternative credential model | **Confirmed not available** — design already avoids relying on it |
| Storage management APIs (create bucket/project/user) | Automatic per-organization provisioning | Provisioning would need a manual or alternative path |
| Browser cross-origin (CORS) support on storage | Lets the **web** app upload/download directly to storage | The web app would route file bytes through a small proxy service (a known fallback) |
| Storage lifecycle rules | Automatic pruning of old versions | The server prunes on a schedule instead |
| Invalidating a pre-signed URL by rotating credentials | The strongest form of "force disconnect" | Rely on short URL lifetimes and session revocation |
| Zitadel at ~100k users, per-organization SSO, session revocation | The identity core | Validate deployment model early; identity is swappable if needed |

---

## 12. Glossary

- **Control plane / data plane** — the separation between deciding *who may do what* (our server) and moving *the actual file bytes* (device ↔ storage).
- **Pre-signed URL** — a short-lived, single-file link that lets a client read or write one object in storage directly, without holding lasting credentials.
- **Reseller / organization** — the two tenancy levels: the enterprise running a branded instance, and each of its customer businesses within that instance.
- **Sync Server** — the new backend (control plane) introduced in 3.0.
- **White-labeling** — shipping the product under a reseller's own brand.

---

*Prepared for review. Feedback welcome on any section before we turn the foundation into a detailed implementation plan.*
