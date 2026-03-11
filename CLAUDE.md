# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DS3 Drive is a macOS desktop app that syncs local files with Cubbit DS3 (S3-compatible) cloud storage. It uses Apple's File Provider framework (`NSFileProviderReplicatedExtension`) to integrate with Finder, presenting remote S3 buckets as native macOS drives.

## Build & Run

- **Requirements:** macOS 15+, Xcode 16+
- **Build:** Open `DS3Drive.xcodeproj` in Xcode. You must configure your own provisioning profile and signing certificate in Signing & Capabilities. The App Group (`group.io.cubbit.DS3Drive`) must match between the main app and the FileProvider extension.
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

## Commit Guidelines

- Don't mention Claude Code in commits or PRs
- Keep commit messages concise
