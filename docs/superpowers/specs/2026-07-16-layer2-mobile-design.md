# DS3 Drive v3.0 — Layer 2: Mobile In-App Browser (deep-dive spec)

**Status:** Draft. Sixth per-part deep-dive. Consumes the backend; a *later* client (after web).
**Date:** 2026-07-16
**Reverses:** `.planning/PROJECT.md` "Files-app-only on iOS" — now **dual** (in-app browser + FileProvider), like Dropbox.

---

## 1. Scope & decisions
| Topic | Decision |
|---|---|
| Platforms | iOS / iPadOS. (Desktop stays OS-integrated — Finder/Explorer — just re-pointed to the server.) |
| Model | **Server-mediated, greenfield** (v3/new orgs). Existing direct-S3 iOS app keeps serving existing users. |
| Surfaces | **Dual:** in-app file browser **+** re-pointed FileProvider (Files-app integration, open-in-other-apps). |
| Access | **On-demand + native offline (v1).** FileProvider already materializes files locally and supports **"keep downloaded"** (offline) — shipped behavior. The in-app browser **coordinates with the FileProvider domain** (single local store) so offline is native, not a separate cache to build. On-demand hydration (presigned) for un-materialized items. |
| Preview | **QuickLook** — native PDF / Office / image preview (richer than web, free). |
| Reuse | Rust core (`ds3-models`, `ds3-s3`, UniFFI) already exists — re-point from direct-S3 to `/v2` + presigned. |

## 2. Components
- **Auth:** Zitadel OIDC + PKCE via `ASWebAuthenticationSession`; tokens in Keychain. (IdP-portable per Layer-0 seam.)
- **`/v2` API client:** control plane (namespace, shares, versions, trash, account).
- **In-app browser (SwiftUI):** folder list/grid, file/photo upload (picker + re-pointed Share Extension), download, QuickLook preview, share links (within org policy), shared-with-me, version history/restore, trash. Reuse iPad-adaptive patterns already shipped. **Backed by the FileProvider domain** (single local store) → materialized/"keep-downloaded" files are offline-available in the browser for free; no parallel cache.
- **FileProvider extension:** re-pointed to hydrate via **presigned URLs** from the server (keep the existing 20MB streaming-I/O memory pattern).
- **Push:** WebSocket (foreground) **+ APNs (background)** — see §3.

## 3. ⚠️ Backend addition — APNs for background sync
iOS can't hold a WebSocket in the background, so the server must send **APNs** notifications to wake the app for remote changes (WebSocket handles foreground live updates). **This is a new backend capability** (APNs sender + device-token registration) beyond the web's WebSocket-only push. Fold an APNs provider into the events service; register device tokens per `client_session`. (Android later → FCM, same shape.)

## 4. Key concerns
- **Background sync:** APNs wake + `BGTask`; on-demand hydration on access. No persistent background socket.
- **Memory:** keep streaming I/O in the FileProvider extension (existing pattern).
- **Upload:** presigned PUT / multipart from picker + Share Extension.
- **Whitelabel = per-reseller app build** (build-time) → each reseller ships a branded binary under **their own App Store account / MDM** ("sell through their own store profiles"). Separate app targets/config per reseller. (Detailed in the whitelabel spec.)

## 5. Testing
- XCUITest for in-app journeys (login → browse → preview → upload → share → restore).
- FileProvider integration (hydrate via presigned, push-driven refresh).
- On-demand fetch + QuickLook; auth/session; APNs-triggered background sync.

## 6. Open items
- **APNs backend integration** + device-token lifecycle (and FCM for a future Android).
- Existing direct-S3 app **coexistence / eventual migration** path for old users.
- Confirm QuickLook covers the reseller's required doc types.

## 7. Next
Last section: cross-cutting **Whitelabel + VPN/proxy**. Then index + `writing-plans`.
