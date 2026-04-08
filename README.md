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

- **iOS app (public beta)** — full-featured companion app for iPhone and iPad, sharing the same File Provider extension as the macOS app
- **Refreshed macOS UI** — new brand typography (Figtree), design tokens (`DS3Colors`, `DS3Typography`, `DS3Gradients`, `DS3Spacing`), redesigned tray with per-drive gear menu, and a live Recent Files panel
- **Drive setup wizard rewrite** — tree-based bucket navigation with IAM-user switching, folder-prefix picker, and a single confirm step
- **New Connection tab in Preferences** — inspect and configure the Cubbit coordinator URL
- **Shared design system** — `DS3Lib` ships brand tokens so iOS and macOS stay visually in lockstep

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

Log in with your Cubbit credentials, pick a project, expand to a bucket, and optionally drill down into a folder prefix to scope the sync. Confirm in one screen and you're done.

<p align="center">
  <img alt="Setup wizard" src="/Assets/SetupStart.png?raw=true" width="460">
  &nbsp;
  <img alt="Confirm drive" src="/Assets/ConfirmDrive.png?raw=true" width="460">
</p>

### 2. Drive your drives from the menu bar

Each drive shows its status, last activity, and a gear menu for quick actions (view in Finder, web console, copy S3 path, pause/resume, rename, delete). The footer aggregates sync state and transfer speed across all drives. Click a drive to flip open a Recent Files panel with per-file progress.

<p align="center">
  <img alt="Tray menu" src="/Assets/TrayMenuDetail.png?raw=true" width="320">
  &nbsp;
  <img alt="Recent files panel" src="/Assets/RecentFiles.png?raw=true" width="520">
</p>

### 3. Preferences

Startup, notifications, account, sync, coordinator connection, and trash — each behind its own tab. The **Connection** tab is new in 1.7.0 and lets you point DS3 Drive at any Cubbit coordinator (SaaS, on-prem, or a custom tenant).

<p align="center">
  <img alt="Preferences" src="/Assets/Preferences.png?raw=true" width="460">
</p>

## iOS

The iOS app mirrors the macOS feature set with a native iPhone/iPad UI. Sign in, run through the setup wizard, and your bucket is mounted into the system Files app under **Locations** — with live sync indicators on files being uploaded or downloaded.

<p align="center">
  <img alt="Drives dashboard" src="/Assets/ios/Drives.png?raw=true" width="220">
  <img alt="Bucket picker" src="/Assets/ios/BucketSelect.png?raw=true" width="220">
  <img alt="Create drive" src="/Assets/ios/CreateDrive.png?raw=true" width="220">
</p>

<p align="center">
  <img alt="Settings" src="/Assets/ios/Settings.png?raw=true" width="220">
  <img alt="Files app — syncing" src="/Assets/ios/FilesAppSync.png?raw=true" width="220">
</p>

## Features

### File Provider
- Full read/write on virtual drives: upload, download, rename, move, delete, copy
- Multipart upload for files larger than 5 MB
- Streaming fetch — files aren't pre-cached unless you open them
- Per-file sync badges and error propagation to the parent folder

### Drive management
- Up to 3 concurrent drives per account
- Tree-based bucket picker with IAM-user switching and folder-prefix scoping
- Pause, resume, refresh, reset, rename, or delete from the per-drive gear menu

### Real-time feedback
- Aggregate and per-drive transfer speed in the tray footer
- Sync status pills (idle, syncing, indexing, error, paused, offline)
- Live Recent Files panel with per-file progress
- Batched conflict notifications with "Show in Finder" action, plus automatic `(conflicted copy)` fallback

### Authentication
- Email + password with 2FA (TOTP) support
- Custom coordinator URL for on-prem and multi-tenant deployments
- JWT access tokens with proactive refresh and persistent sessions
- Auto-managed DS3 API keys, reconciled between local and remote on setup

## Architecture

Two apps share a single File Provider extension and a local Swift Package for all shared code:

| Target | Platform | Role |
|--------|----------|------|
| **DS3Drive** | macOS 15+ | SwiftUI menu bar app |
| **DS3DriveApp** | iOS 17+ | SwiftUI iPhone/iPad app |
| **DS3DriveProvider** | macOS + iOS | `NSFileProviderReplicatedExtension` — runs out-of-process, handles every S3 operation |
| **DS3DriveShareExtension** | macOS + iOS | Share-sheet target for uploading into a drive from other apps |
| **DS3Lib** | Swift Package | Auth, API client, drive manager, design tokens, shared models |

Main app ↔ extension communication uses an App Group shared container (persisted state) and `DistributedNotificationCenter` (live status / speed updates).

Key dependencies: [Soto](https://github.com/soto-project/soto) v6 for S3, [swift-atomics](https://github.com/apple/swift-atomics) for thread-safe state in the extension, [Sparkle](https://sparkle-project.org) for macOS updates.

## Build from source

Requirements: macOS 15+, Xcode 16+, and Git LFS (for image assets).

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
