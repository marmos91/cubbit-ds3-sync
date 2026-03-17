# Cubbit DS3 Drive

[![Xcode - Build and Analyze](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/build.yml/badge.svg)](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/build.yml)
[![Release — Homebrew Cask](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-homebrew.yml/badge.svg)](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-homebrew.yml)
[![Release — TestFlight](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-testflight.yml/badge.svg)](https://github.com/marmos91/cubbit-ds3-drive/actions/workflows/release-testflight.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
[![License: GPL](https://img.shields.io/badge/license-GPL-green)](LICENSE)

Cubbit DS3 Drive is a macOS desktop application that syncs your local files with [Cubbit DS3](https://www.cubbit.io) cloud storage. It uses Apple's File Provider framework to integrate directly with Finder, presenting remote S3 buckets as native macOS drives.

<p align="center">
  <img alt="Finder Integration" src="/Assets/FinderIntegration.png?raw=true" width="700">
</p>

## Installation

### Homebrew

```bash
brew tap marmos91/tap
brew install --cask marmos91/tap/cubbit-ds3-drive
```

### Manual Download

Download the latest `.dmg` from the [Releases](https://github.com/marmos91/cubbit-ds3-drive/releases) page.

## How It Works

DS3 Drive runs as a menu bar app and registers a File Provider extension with macOS. Once you select a project and bucket from your Cubbit account, the app creates a virtual drive that appears in Finder's sidebar — just like iCloud Drive or Dropbox.

### 1. Select a project and bucket

Browse your Cubbit projects and buckets in a tree sidebar. Expand a project to see its buckets and pick the one you want to sync.

<p align="center">
  <img alt="Select Bucket" src="/Assets/SelectBucket.png?raw=true" width="500">
</p>

### 2. Name your drive

Choose a name for your drive. This is how it will appear in Finder's sidebar.

<p align="center">
  <img alt="Name Drive" src="/Assets/NameDrive.png?raw=true" width="500">
</p>

### 3. Control your drives from the menu bar

Monitor sync status, transfer speeds, and manage your drives from the tray menu. Add up to 3 drives, pause/resume syncing, and access preferences.

<p align="center">
  <img alt="Tray Menu" src="/Assets/TrayMenu.png?raw=true" width="350">
</p>

### 4. Access your files from Finder

Your DS3 storage appears as a native drive in Finder. Open, edit, and organize your cloud files like any local folder.

<p align="center">
  <img alt="Finder Integration" src="/Assets/FinderIntegration.png?raw=true" width="600">
</p>

## Features

### Finder Integration
- Virtual drives appear in Finder's sidebar as native locations
- Upload, download, rename, move, and delete files directly from Finder
- Multipart upload support for large files (> 5 MB)
- Sync status badges on files and folders

### Menu Bar Controls
- Real-time upload/download speed monitoring per drive and aggregate
- Drive status indicators (idle, syncing, indexing, error, paused, offline)
- Recent files panel with per-file transfer progress
- Quick actions: view in Finder, open web console, copy S3 path, connection info

### Drive Management
- Create up to 3 concurrent drives
- Pause and resume syncing
- Refresh to re-scan for remote changes
- Reset sync to rebuild from scratch
- Rename drives or change the synced bucket/prefix

### Authentication
- Email and password login with 2FA support
- Multi-tenant and custom coordinator URL support
- Automatic token refresh with proactive renewal
- Persistent sessions across app restarts

### Conflict Handling
- Automatic detection when a file is modified both locally and remotely
- Creates a `(conflicted copy)` alongside the original
- Batched macOS notifications with "Show in Finder" action

### Preferences
- Start at login toggle
- Sync notification toggle
- Finder badge visibility toggle
- Account info display with link to web console

## Architecture

The project has two targets plus a shared library:

| Target | Description |
|--------|-------------|
| **DS3Drive** | SwiftUI menu bar app. Handles login, onboarding, drive setup, preferences, and tray menu |
| **DS3DriveProvider** | File Provider extension (`NSFileProviderReplicatedExtension`). Runs as a separate process and handles all S3 file operations |
| **DS3Lib** | Local Swift Package shared between both targets. Contains authentication, API client, drive manager, and shared models |

The main app and extension communicate via an App Group shared container (persisted state) and `DistributedNotificationCenter` (real-time status updates).

## Building from Source

### Prerequisites

- macOS 15 or later
- Xcode 16.0 or later

### Assets

This project uses Git LFS for image assets:

```bash
git lfs install
git lfs pull
```

### Build

Open `DS3Drive.xcodeproj` in Xcode. You need to configure your own provisioning profile and signing certificate in the Signing & Capabilities tab.

The App Group (`group.X889956QSM.io.cubbit.DS3Drive`) must match between the main app and the File Provider extension.

## Contributing

Contributions are welcome. Please open a pull request and follow the [contribution guidelines](CONTRIBUTING.md).

## License

This project is licensed under the [GPL](LICENSE).
