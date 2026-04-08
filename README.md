<p align="center">
  <img alt="Cubbit" src="/Assets/Logo.png?raw=true" width="280">
</p>

<h1 align="center">DS3 Drive</h1>

<p align="center">
  Sync your files with <a href="https://www.cubbit.io">Cubbit DS3</a> cloud storage, on macOS and iOS.
</p>

<p align="center">
  <a href="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/build.yml"><img alt="Build" src="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/build.yml/badge.svg"></a>
  <a href="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-homebrew.yml"><img alt="Release — Homebrew" src="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-homebrew.yml/badge.svg"></a>
  <a href="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-testflight.yml"><img alt="Release — TestFlight" src="https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-testflight.yml/badge.svg"></a>
  <br>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B%20%7C%20iOS%2017%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/swift-5.9%2B-orange">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-GPL-green"></a>
  <a href="https://github.com/marmos91/cubbit-ds3-drive/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/marmos91/cubbit-ds3-drive?label=release"></a>
</p>

---

DS3 Drive connects your [Cubbit DS3](https://www.cubbit.io) buckets to the native file system on Apple platforms. On macOS it runs as a menu bar app and mounts your buckets as drives in Finder; on iOS it mirrors them into the Files app alongside iCloud Drive. Both apps are built on Apple's File Provider framework, so every read and write goes through the system — no custom mount daemon, no FUSE, no kexts.

<p align="center">
  <img alt="Finder integration" src="/Assets/FinderIntegration.png?raw=true" width="640">
</p>

## What's new in 1.7.0

- **iOS app (public beta).** Full-featured companion app for iPhone and iPad, built on the same File Provider extension as the macOS app. Tutorial onboarding, drive setup wizard, account settings, and Files-app integration.
- **Refreshed macOS UI.** New brand typography (Figtree), design tokens (`DS3Colors`, `DS3Typography`, `DS3Gradients`, `DS3Spacing`), redesigned tray menu with per-drive gear menu, and a new Recent Files panel with live transfer progress.
- **New Connection tab in Preferences.** Inspect and configure the Cubbit coordinator URL, view tenant info, and copy the API endpoint.
- **Tray polish.** Per-drive status pills, aggregate sync/speed summary, in-tray "empty drives" hint, and programmatic menu wiring (fixes a long-standing SwiftUI `Menu` hit-test bug on Sequoia).
- **Drive setup wizard rewrite.** Tree-based bucket navigation with IAM-user switching, folder-prefix picker, and a single confirm step that reads like a receipt.
- **Shared design system.** `DS3Lib` now ships the brand token set so iOS and macOS stay visually in lockstep.

See the full changelog on the [v1.7.0 release](https://github.com/marmos91/cubbit-ds3-drive/releases/tag/v1.7.0).

## Install

### macOS — Homebrew

```bash
brew tap marmos91/tap
brew install --cask marmos91/tap/cubbit-ds3-drive
```

Or grab the notarized `.dmg` from the [Releases](https://github.com/marmos91/cubbit-ds3-drive/releases/latest) page. Updates are delivered in-app via Sparkle.

### iOS — TestFlight

The iOS app is in public beta:

**[👉 Join the TestFlight beta](https://testflight.apple.com/join/NwEErXFQ)**

Requires iOS 17 or later and the [TestFlight app](https://apps.apple.com/app/testflight/id899247664).

## macOS

### 1. Set up your first drive

Log in with your Cubbit credentials, pick a project, expand to a bucket, and optionally drill down into a folder prefix to scope the sync.

<p align="center">
  <img alt="Setup wizard — start" src="/Assets/SetupStart.png?raw=true" width="520">
  <br><br>
  <img alt="Setup wizard — pick bucket" src="/Assets/SelectBucket.png?raw=true" width="520">
</p>

Confirm the drive in one screen — with a single drive Finder uses the app name as the sidebar label; with multiple drives the custom name shows instead.

<p align="center">
  <img alt="Confirm drive" src="/Assets/ConfirmDrive.png?raw=true" width="520">
</p>

### 2. Control your drives from the menu bar

Each drive shows its status, the last activity timestamp, and a per-drive gear menu for quick actions. The footer aggregates sync state and transfer speed across all drives.

<p align="center">
  <img alt="Tray menu" src="/Assets/TrayMenuDetail.png?raw=true" width="360">
</p>

### 3. Watch transfers in real time

The Recent Files panel surfaces in-flight uploads and downloads with per-file progress. Files stream directly to and from S3 — no intermediate local cache unless you ask for it.

<p align="center">
  <img alt="Recent files" src="/Assets/RecentFiles.png?raw=true" width="640">
</p>

### 4. Use Finder like always

Your bucket appears as a native location in Finder's sidebar. Open, edit, rename, move, and delete files the same way you would with iCloud Drive or Dropbox. Multipart uploads kick in automatically for files over 5 MB.

<p align="center">
  <img alt="Finder — icon view" src="/Assets/FinderIntegration.png?raw=true" width="640">
  <br><br>
  <img alt="Finder — list view" src="/Assets/FinderList.png?raw=true" width="640">
</p>

### 5. Preferences

Startup, notifications, account, sync, coordinator connection, and trash — each behind its own tab.

<p align="center">
  <img alt="Preferences" src="/Assets/Preferences.png?raw=true" width="500">
</p>

## iOS

The iOS app mirrors the macOS feature set with a native iPhone/iPad UI. Sign in, run through the setup wizard, and your bucket is mounted into the system Files app.

<p align="center">
  <img alt="Drives — empty state" src="/Assets/ios/NoDrives.png?raw=true" width="220">
  <img alt="Drives dashboard" src="/Assets/ios/Drives.png?raw=true" width="220">
  <img alt="Project picker" src="/Assets/ios/ProjectSelect.png?raw=true" width="220">
  <img alt="Bucket picker" src="/Assets/ios/BucketSelect.png?raw=true" width="220">
</p>

<p align="center">
  <img alt="Create drive" src="/Assets/ios/CreateDrive.png?raw=true" width="220">
  <img alt="Drive settings" src="/Assets/ios/DriveSettings.png?raw=true" width="220">
  <img alt="Settings" src="/Assets/ios/Settings.png?raw=true" width="220">
  <img alt="Files app" src="/Assets/ios/FilesApp.png?raw=true" width="220">
</p>

Your synced buckets appear directly under **Locations** in the Files app, with live sync indicators on files being uploaded or downloaded.

<p align="center">
  <img alt="Files app — syncing" src="/Assets/ios/FilesAppSync.png?raw=true" width="260">
</p>

## Features

### File Provider integration
- Virtual drives surface as native locations in Finder (macOS) and the Files app (iOS)
- Full read/write: upload, download, rename, move, delete, copy
- Multipart upload for files larger than 5 MB
- Streaming fetch — files aren't pre-cached unless you open them
- Per-file sync status badges and error propagation to the parent folder

### Tray menu (macOS)
- Real-time aggregate upload/download speed with per-drive breakdown
- Sync status pills (idle, syncing, indexing, error, paused, offline)
- Recent Files panel with per-file transfer progress
- Per-drive gear menu: view in Finder, open in web console, copy S3 path, pause/resume, refresh, reset, rename, delete
- Top-level actions: add drive, preferences, web console, check for updates, help, quit

### Drive setup wizard
- Tree-based bucket navigation with IAM-user switching
- Folder-prefix picker so a single bucket can back multiple drives
- One-screen confirm step showing project, bucket, prefix, and drive name
- Up to 3 concurrent drives

### Authentication
- Email + password login with 2FA (TOTP) support
- Custom coordinator URL for on-prem and multi-tenant deployments
- JWT access tokens with proactive refresh and persistent sessions
- Auto-managed DS3 API keys, reconciled between local and remote on setup

### Conflict handling
- Local/remote edit-collision detection with automatic `(conflicted copy)` creation
- Batched macOS notifications with "Show in Finder" action

### Preferences (macOS)
- **General** — start at login, sync notifications, update checks, Sparkle channel
- **Account** — identity, tenant, sign out
- **Sync** — per-drive sync controls
- **Connection** — coordinator URL, tenant info, endpoint copy
- **Trash** — retention and purge controls

### iOS parity
- Same File Provider extension as macOS — shared code path, shared bugs fixed once
- Brand typography and design tokens via `DS3Lib`
- Tutorial onboarding, drive dashboard, setup wizard, settings tab
- Tab layout (Drives / Settings) with live status cards

## Architecture

Two apps share a single File Provider extension and a local Swift Package for all shared code:

| Target | Platform | Role |
|--------|----------|------|
| **DS3Drive** | macOS 15+ | SwiftUI menu bar app. Login, onboarding, setup wizard, preferences, tray |
| **DS3DriveApp** | iOS 17+ | SwiftUI iPhone/iPad app. Login, tutorial, dashboard, setup, settings |
| **DS3DriveProvider** | macOS + iOS | `NSFileProviderReplicatedExtension`. Runs out-of-process, handles every S3 operation |
| **DS3DriveShareExtension** | macOS + iOS | Share-sheet target for uploading into a drive from other apps |
| **DS3Lib** | Swift Package | Auth, API client, drive manager, design tokens, shared models |

Main app ↔ extension communication goes through:
- **App Group shared container** for persisted state (drives, credentials, API keys)
- **DistributedNotificationCenter** for live status / speed updates

Key dependencies: [Soto](https://github.com/soto-project/soto) v6 for S3, [swift-atomics](https://github.com/apple/swift-atomics) for thread-safe state in the extension, [Sparkle](https://sparkle-project.org) for macOS updates.

## Build from source

Requirements:

- macOS 15 or later
- Xcode 16 or later
- Git LFS (for image assets)

```bash
git clone git@github.com:marmos91/cubbit-ds3-drive.git
cd cubbit-ds3-drive
git lfs install && git lfs pull
open DS3Drive.xcodeproj
```

In Xcode, configure your own Team and signing certificate in **Signing & Capabilities** for each target. The App Group (`group.<TeamID>.io.cubbit.DS3Drive`) must match across the main apps and the File Provider extension — on macOS 15+ the team-ID prefix is mandatory.

For a deeper tour of the codebase see [`CLAUDE.md`](CLAUDE.md).

## Contributing

Contributions are welcome — please open a pull request and follow the [contribution guidelines](CONTRIBUTING.md).

## License

Released under the [GPL](LICENSE).
