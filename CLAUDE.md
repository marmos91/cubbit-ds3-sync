# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DS3 Drive is a macOS desktop app that syncs local files with Cubbit DS3 (S3-compatible) cloud storage. It uses Apple's File Provider framework (`NSFileProviderReplicatedExtension`) to integrate with Finder, presenting remote S3 buckets as native macOS drives.

## Build & Run

- **Requirements:** macOS 15+, Xcode 16+
- **Build:** Open `DS3Drive.xcodeproj` in Xcode. You must configure your own provisioning profile and signing certificate in Signing & Capabilities. The App Group (`group.X889956QSM.io.cubbit.DS3Drive`) must match between the main app and the FileProvider extension.
- **Assets:** Uses Git LFS — run `git lfs install && git lfs pull` after cloning.
- **CI:** GitHub Actions runs `xcodebuild clean build analyze` on push/PR to `main`.

## Architecture

The project has two targets plus a shared library (DS3Lib as a local Swift Package):

### DS3Drive (Main App)
SwiftUI app with a menu bar tray icon. Handles login, drive setup wizard, and preferences. Uses `@Observable` pattern (Swift 5.9+) for state management. Key flow: Login -> Tutorial -> Project Selection -> Bucket/Prefix Selection -> Drive Creation.

### DS3DriveProvider (File Provider Extension)
`NSFileProviderReplicatedExtension` that runs as a separate process. Maps S3 objects to file system items via `S3Item`. Handles file CRUD (upload, download, rename, move, delete) against S3, with multipart upload support for files > 5MB. Uses `S3Enumerator` for directory listing and change enumeration.

### DS3Lib (Shared Library - Local Swift Package)
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
- **Soto v6** (`SotoS3`) — AWS S3 client for Swift (declared in DS3Lib/Package.swift)
- **swift-atomics** — Thread-safe state in the extension (declared in DS3Lib/Package.swift)

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

### App Group Shared Container
```
~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/
```

## Commit Guidelines

- Don't mention Claude Code in commits or PRs
- Keep commit messages concise
