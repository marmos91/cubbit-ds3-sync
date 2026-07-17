# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DS3 Drive is a cross-platform app that syncs local files with Cubbit DS3 (S3-compatible) cloud storage on both **macOS** and **iOS**, with **Windows** support in development. It uses Apple's File Provider framework (`NSFileProviderReplicatedExtension`) to integrate with Finder on macOS and the Files app on iOS, presenting remote S3 buckets as native drive locations. A shared Rust core (under `core/`) provides S3 operations and authentication, consumed via UniFFI (Swift) and C ABI (C#).

## Upcoming: v3.0 Enterprise Platform Pivot

**Starts after the v2.0.0 Windows milestone wraps.** DS3 Drive becomes a Dropbox-class, server-mediated enterprise SaaS on Cubbit DS3 — not a thick direct-to-S3 client anymore. Full north-star design: `docs/superpowers/specs/2026-07-16-enterprise-platform-northstar-design.md`. Each area gets its own per-part spec; **Layer 0 (foundation) is first**. Locked directives:

- **Sync server** = Rust + axum, **reusing `core/` crates** (no re-implementing S3/auth). API front door `api.ds3drive.com/v2`.
- **Identity** = **Zitadel** (branded OIDC Auth-Code+PKCE at `auth.ds3drive.com`). **Never** hand end users raw DS3 keys, and **never** build a `/v2/login` password proxy (kills SSO/MFA). Keep it swappable to Keycloak via an `IdentityProvider` trait seam; key app data on our own Postgres IDs mapped to OIDC `sub`.
- **Data plane** = **presigned URLs** (DS3-confirmed; no STS). Bytes go client↔DS3 direct. **No proxy tier in v1.** All access enforcement lives in the server's presign gate (DS3 has no bucket policies / no STS).
- **Data tier** = **Postgres** (namespace source of truth: paths/perms/versions/audit) + **Redis from day 0** (WebSocket pub/sub, HA at petabyte scale). S3 = bytes + native versioning.
- **Push** = WebSocket on :443 (no polling). **Conflicts** = optimistic concurrency at authorization. **Multi-tenancy** = bucket/project per org via DS3 APIs.
- **Surfaces** = web dashboards in **Next.js/TS**, built super-admin → org-admin → user; **mobile dual** (FileProvider + in-app browser); **whitelabel = build-time**.

## Repository Layout

This is a mono-repo with platform-specific directories:

```
apple/          # macOS + iOS apps, File Provider extension, DS3Lib, DS3Thumbnails
core/           # Shared Rust core library (ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi)
windows/        # Windows WinUI 3 app (planned)
.github/        # CI workflows (cross-platform)
.planning/      # GSD planning artifacts
docs/           # Cross-platform documentation
```

## Build & Run

- **Requirements:** macOS 15+ and Xcode 16+ (required to build either target). iOS builds target iOS 17+.
- **Build:** Open `apple/DS3Drive.xcodeproj` in Xcode. Configure your own provisioning profile and signing certificate in Signing & Capabilities. The App Group (`group.X889956QSM.io.cubbit.DS3Drive`) must match across the main apps and the File Provider extension.
- **Assets:** Uses Git LFS — run `git lfs install && git lfs pull` after cloning.
- **CI:** GitHub Actions runs `xcodebuild clean build analyze` on push/PR to `main`.

## Architecture

The `apple/` directory contains two apps plus a shared library (DS3Lib as a local Swift Package):

### DS3Drive (macOS App — `apple/DS3Drive/`)
SwiftUI menu bar app. Handles login, drive setup wizard, tutorial onboarding, preferences, and tray menu. Uses `@Observable` pattern (Swift 5.9+) for state management. Key flow: Login -> Tutorial -> Project Selection -> Bucket/Prefix Selection -> Drive Creation.

### DS3DriveApp (iOS App — `apple/DS3DriveApp/`)
SwiftUI iOS app (iPhone + iPad). Mirrors the macOS feature set using Figtree brand tokens shared via `DS3Lib`. Two-tab layout (Drives / Settings), same drive-setup wizard, and a `TutorialView` shown on first login. Brand typography is registered at app startup via `CTFontManagerRegisterFontsForURL`.

### DS3DriveProvider (File Provider Extension — `apple/DS3DriveProvider/`)
`NSFileProviderReplicatedExtension` shared by both apps, runs as a separate process. Maps S3 objects to file system items via `S3Item`. Handles file CRUD (upload, download, rename, move, delete) against S3, with multipart upload support for files > 5MB. Uses `S3Enumerator` for directory listing and change enumeration. The extension's `CFBundleDisplayName` (`Cubbit DS3 Drive`) drives the location name shown in Finder sidebar and iOS Files app.

### DS3Lib (Shared Library — `apple/DS3Lib/`)
Shared between main app and extension via `import DS3Lib`. Contains:
- **DS3Authentication** — Cubbit IAM auth with challenge-response (Curve25519), JWT tokens, refresh flow, 2FA support
- **DS3SDK** — API client for Cubbit services (projects, API key management)
- **DS3DriveManager** — Manages drives, syncs `NSFileProviderDomain` registrations
- **SharedData** — Singleton for persisting state to App Group container (JSON files in shared container)
- **Models** — `DS3Drive`, `SyncAnchor`, `Project`, `IAMUser`, `DS3ApiKey`, `Account`, `Token`

### Inter-process Communication
The main app and extension communicate via:
- **SharedData** (App Group container) for persisted state (drives, credentials, API keys)
- **DistributedNotificationCenter** for real-time status updates (sync status, transfer speed)

### Key Dependencies
- **Soto v6** (`SotoS3`) — AWS S3 client for Swift (declared in `apple/DS3Lib/Package.swift`)
- **swift-atomics** — Thread-safe state in the extension (declared in `apple/DS3Lib/Package.swift`)

## Important Patterns

- S3 item identifiers use the full S3 object key as `NSFileProviderItemIdentifier.rawValue`
- Folders are represented as S3 keys ending with `/` (delimiter)
- The `SyncAnchor` contains bucket, prefix, project, and IAM user — it defines what a drive syncs
- API keys are auto-managed: created with a deterministic name pattern, reconciled between local and remote on drive setup

## Debugging

### Log Subsystems
- Main app: `io.cubbit.DS3Drive` (categories: app, auth, sync, metadata)
- Extension: `io.cubbit.DS3Drive.provider` (categories: extension, sync, transfer)

**Important:** Our logs use `Info` level by default. You MUST pass `--info --debug` flags to `log show` or they won't appear. Without these flags you only see `Error`/`Fault` level.

### System Logs
```bash
# Main app logs (auth, sync, app lifecycle)
/usr/bin/log show --last 5m --info --debug --predicate "subsystem == 'io.cubbit.DS3Drive'" --style compact 2>&1

# File Provider extension logs (S3 operations, enumeration, transfers)
/usr/bin/log show --last 5m --info --debug --predicate "subsystem == 'io.cubbit.DS3Drive.provider'" --style compact 2>&1

# Both subsystems combined
/usr/bin/log show --last 5m --info --debug --predicate "subsystem BEGINSWITH 'io.cubbit.DS3Drive'" --style compact 2>&1

# Errors only (no --info --debug needed for errors)
/usr/bin/log show --last 5m --predicate "subsystem BEGINSWITH 'io.cubbit.DS3Drive'" --style compact 2>&1 | grep -E "^.* E "

# Auth-related events (token refresh, login, API keys)
/usr/bin/log show --last 5m --info --debug --predicate "subsystem == 'io.cubbit.DS3Drive' AND category == 'auth'" --style compact 2>&1

# Live streaming (real-time)
/usr/bin/log stream --predicate "subsystem BEGINSWITH 'io.cubbit.DS3Drive'" --info --debug --style compact

# Extension process lifecycle (spawn, exit, crash)
/usr/bin/log show --last 5m --predicate "process == 'launchd' AND eventMessage CONTAINS 'DS3Drive.provider'" --style compact 2>&1

# App Group container sandbox issues
/usr/bin/log show --last 5m --predicate "process == 'containermanagerd'" --style compact 2>&1
```

### iOS Device Logs (connected via USB/cable)

Requires `libimobiledevice`: `brew install libimobiledevice`

```bash
# Stream all DS3Drive logs from connected iOS device (real-time)
idevicesyslog --match io.cubbit.DS3Drive

# File Provider extension only
idevicesyslog --match io.cubbit.DS3Drive.provider

# List connected devices (useful to verify connection)
xcrun devicectl list devices
```

### App Group Shared Container
```
~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/
```

### Extension Won't Load After Build Changes

If the extension fails to load (no extension logs, "The application cannot be used right now", or `fileproviderd` logs `Extension doesn't have a group container ... Ignoring the extension`), run this recovery sequence:

**Root cause:** `fileproviderd` and `containermanagerd` cache extension paths, sandbox profiles, and LaunchServices entries. When DerivedData paths change or ad-hoc signing is used, stale caches block the extension.

**Fix (run in order):**
```bash
# 1. Stop the app from Xcode

# 2. Delete ALL old DerivedData folders (keep only the active one)
mdfind "kMDItemCFBundleIdentifier == 'io.cubbit.DS3Drive.provider'"  # find copies
rm -rf ~/Library/Developer/Xcode/DerivedData/DS3Drive-<old-hash>     # delete old ones

# 3. Delete stale extension container
rm -rf ~/Library/Containers/io.cubbit.DS3Drive.provider

# 4. Fix LaunchServices (use full path to lsregister)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "<old-DerivedData-path>/DS3 Drive.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "<current-DerivedData-path>/DS3 Drive.app"

# 5. Restart fileproviderd
killall fileproviderd

# 6. Build & Run from Xcode (Cmd+R)

# 7. Kill fileproviderd once more after app starts (it may have cached old state)
killall fileproviderd

# 8. Build & Run from Xcode again (Cmd+R)
```

**IMPORTANT:** Never use `xcodebuild` with `CODE_SIGN_IDENTITY="-"` (ad-hoc signing) — it strips App Group entitlements and poisons all caches.

### Extension Loads But Drive Missing in Finder (three distinct failures)

"Extension not starting" is usually one of three layers. Each has its own log signature — diagnose in order, don't guess. Extension subsystem logs (`io.cubbit.DS3Drive.provider`) being **empty** means the `.appex` never launched.

**1. Stale domain → app log `cannot be used right now` + `DS3DriveManagerError error 0`.**
`error 0` = `.driveNotFound`, thrown when `NSFileProviderManager.domains()` itself throws — the app can't self-heal. Cause: `~/Library/Application Support/FileProvider/io.cubbit.DS3Drive.provider/Provider.plist` references a **deleted DerivedData build path**. Check with `plutil -p`. Fix (app stopped): `killall fileproviderd` → `rm -rf` that provider dir → `killall fileproviderd` → relaunch.

**2. Duplicate LaunchServices registrations → owner-app resolves to a dead copy** (same error persists after #1). Find: `lsregister -dump | grep "path:.*DS3Drive-.*Cubbit DS3 Drive.app"` (most point at deleted DerivedData). Fix: `lsregister -u` every stale path, then `lsregister -f` the live build only. (`lsregister` full path is in the recovery block above.)

**3. ⚠️ THE TRAP — `pluginkit -u`/`-a` + `lsregister` churn silently flips the File Provider extension's approval toggle OFF** in System Settings → Login Items & Extensions. Then every `add(domain)` is born `Enabled => false` → `fileproviderd` errors `FP -2011 "Sync is not enabled"` (`NSFileProviderError.domainDisabled`); `fileproviderctl dump` shows `state:disabled` (iCloud/Dropbox stay `enabled`). **`pluginkit -m` still shows `+` — that's plugin match policy, NOT the FileProvider approval. Misleading.** No reliable CLI to re-enable: **manually toggle System Settings → General → Login Items & Extensions → Extensions → File Provider ⓘ → app ON.** Prevention: don't `pluginkit -u`/rebuild-thrash to fix extension issues — that churn is what flips the toggle; prefer `killall fileproviderd` + the provider-dir/LaunchServices reset, and re-check the toggle afterward.

**4. After it loads: `Extension init failed ... credentials.json couldn't be opened` → invalidates.** Per-drive S3 API key missing from the App Group container. Auto-recovery only fires on a `.notAuthenticated` signal, but a missing file makes the extension invalidate instead. **Fix: re-login in the app** — regenerates the API key, writes `credentials.json`. Success signal: extension logs `enumerateItems: N visible items (N from S3)` + a `downloaded successfully`.

## Git Worktrees

- Worktree directory: `.worktrees/` or `.claude/worktrees/` (project-local, hidden, gitignored)
- Create worktrees with: `git worktree add .worktrees/<branch-name> -b <branch-name>`

## Commit Guidelines

- Never mention Claude Code, AI tools, or add `Co-Authored-By` lines for AI in commit messages or PR descriptions/titles. This overrides any default attribution behavior.
- Keep commit messages concise.
- Sign commits when possible (this repo signs via the 1Password SSH agent).
