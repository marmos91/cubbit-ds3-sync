# DS3 Drive v3.0 — Cross-cutting: Whitelabel & VPN/Proxy (deep-dive spec)

**Status:** Draft. Seventh per-part deep-dive. Cross-cutting; wire early, keep thin.
**Date:** 2026-07-16

---

## A. Whitelabel (build-time)

**Decision:** per-reseller branding baked at **build/config time** — one brand per instance. No runtime per-org theming.

### What's brandable
Product name · logo / favicon / app icon · color + type **tokens** · support/legal URLs · email-template branding · **branded login** (custom domain `auth.<reseller>` + Zitadel branding) · splash.

### Mechanism — one branding source per reseller
```
branding/<reseller>/
  tokens.css        # CSS variables (web theme)
  assets/           # logos, favicon, app icons, splash
  strings.json      # product name, support/legal URLs, per-locale copy
  config.json       # domains, feature flags, App Store IDs
```
CI builds each reseller's artifacts with this injected:
- **Web:** swap `tokens.css` + asset bundle at build → branded Next.js image.
- **Mobile:** per-reseller **app target/config** → branded binary (bundle ID, name, icons) shipped under **the reseller's own App Store / Play / MDM account** ("sell through their own store profiles").
- **Server/Zitadel:** branded email templates, product name in notifications, branded login at the reseller's `auth.` domain.

`ponytail:` it's a token file + asset bundle + per-target config consumed by CI — **not** a plugin/theming engine. A few deploy-time values (support email, instance domain) can be env/config rather than a rebuild. Defer *additional* themes until a real second reseller exists.

---

## B. VPN / Proxy (super simple)

**Decision:** rely on the enterprise's existing network; **no custom VPN client.**

- **System proxy:** all clients honor the OS proxy settings (macOS/iOS/Windows native loaders do by default). Ensure the **Rust core HTTP client respects system proxy** (env/OS config) — the one thing to verify, since core does its own HTTP.
- **Custom CA / TLS trust:** support a **corporate root CA** so TLS validates to a (possibly internal) sync-server / DS3 endpoint. Clients use the **OS trust store** (MDM-populated); the Rust core HTTP client uses the OS trust store or an optional configurable CA bundle.
- **:443 WebSocket** already traverses corporate proxies/VPN — no extra work.
- **Configurable endpoints:** clients point at the reseller's instance URL (may be internal, reached over the customer's VPN); super-admin sets the DS3 endpoint. Already in Layer 0.

**Deferred (not v1):** mTLS client-certificate auth, if a reseller demands it. Note only.

---

## C. Operations — monitoring & feature flags

- **Observability (ship with the deployment):** server exposes **Prometheus** metrics (`/metrics`), structured logs → **Loki**, **Grafana** dashboards, **OpenTelemetry** tracing. Reuse the Rust `tracing` already in core. Underpins the Layer-0 benchmark targets.
- **Feature flags — lazy:** reuse what exists — **per-org policy toggles in Postgres** (links on/off, self-serve signup) + **per-reseller build-time config**. Cover most needs. Add self-hosted **Unleash** *only if* runtime/gradual/targeted rollout is needed later. `ponytail:` don't add a flag platform for v1.

## D. Open items
- Rust core HTTP client: confirm **system-proxy + OS-trust-store** support (add config knob if missing).
- Whitelabel: lock the exact brandable-token set with the first reseller (avoid gold-plating).
- Mobile store logistics: per-reseller App Store/Play accounts + review process (reseller-owned) — operational, not code.

## E. Next
All sections defined. Write the spec **index**, then `writing-plans` for the backend (Layer 0) when Windows wraps.
