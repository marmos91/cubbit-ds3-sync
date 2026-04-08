---
phase: 05-ux-polish
plan: 18c
subsystem: ui
tags: [tutorial, branding, info.plist, file-provider, localization, swift-concurrency]

requires:
  - phase: 05-ux-polish
    provides: [DS3Gradients.brandVerticalBackground, tutorial 7-slide layout]
provides:
  - Unified brand backdrop on all 7 tutorial slides (Gap 20)
  - Single user-facing app name "DS3 Drive" replacing "Cubbit DS3 Drive" everywhere (Gaps 6, 29)
  - CFBundleDisplayName / CFBundleName explicit in DS3Drive Info.plist
  - DS3DriveProvider Info.plist updated NSFileProviderDomainDisplayName + CFBundleDisplayName
  - Localizable.xcstrings key + Italian value migrated
affects: [phase 06, marketing, app-store-listing, dmg-installer]

tech-stack:
  added: []
  patterns:
    - "INFOPLIST_KEY_CFBundleDisplayName build-setting as the source of truth for generated Info.plist"
    - "Brand-name-only product display labels — Cubbit corporate prefix dropped from end-user surfaces"

key-files:
  created: []
  modified:
    - DS3Drive/Views/Tutorial/Views/TutorialView.swift
    - DS3Drive/Info.plist
    - DS3DriveProvider/Info.plist
    - DS3Drive.xcodeproj/project.pbxproj
    - DS3Drive/DS3DriveApp.swift
    - DS3Drive/Update/UpdateNotificationHandler.swift
    - DS3Drive/Assets/Localizable.xcstrings
    - DS3Drive/Views/Tray/Views/TrayDriveGearMenu.swift  # Rule 3 blocker fix

key-decisions:
  - "Tutorial uses ONE backdrop (DS3Gradients.brandVerticalBackground) on every slide — no slide-index conditional"
  - "Drop 'Cubbit ' prefix from every user-facing display name; corporate brand stays in bundle identifiers and copyright only"
  - "CFBundleDisplayName overrides CFBundleName for sidebar/Dock label; both set to 'DS3 Drive'"
  - "DS3DriveManager.fileProviderDomain already uses drive.name (per-drive label) — no SDK code change required"

patterns-established:
  - "Single-backdrop policy for multi-slide onboarding flows — slide chrome lives on top of one ZStack root"
  - "Branding pass: build-setting INFOPLIST_KEY_* + plist + NSLocalizedString + xcstrings key all migrated together"

requirements-completed: [UX-01]

duration: 18min
completed: 2026-04-08
---

# Phase 05 Plan 18c: Tutorial Backdrop & DS3 Drive Branding Summary

**Tutorial slides now share one brand gradient and every user-facing 'Cubbit DS3 Drive' literal is shortened to 'DS3 Drive' across plists, notifications and the string catalog.**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-04-08T07:32:00Z
- **Completed:** 2026-04-08T07:50:41Z
- **Tasks:** 2
- **Files modified:** 8 (including 1 Rule-3 blocker fix outside the plan's `files_modified` list)

## Accomplishments

- Tutorial backdrop unified across all 7 slides — no more brandHeroSubtle ↔ brandBackground flicker on slide change
- Every "Cubbit DS3 Drive" literal across DS3Drive/, DS3DriveProvider/, DS3Lib/Sources/ is gone — final grep returns zero matches
- DS3Drive/Info.plist gains explicit CFBundleDisplayName and CFBundleName (was previously empty for these keys, falling through to the build-setting product name)
- DS3DriveProvider/Info.plist NSFileProviderDomainDisplayName updated + CFBundleDisplayName added — Finder sidebar fallback now reads "DS3 Drive"
- Build clean (`xcodebuild ... build` → BUILD SUCCEEDED)

## Task Commits

1. **Rule 3 blocker fix: project.pbxproj + TrayDriveGearMenu.swift** — `fff5d96` (fix)
2. **Task 1: Tutorial backdrop unification** — `c1d1d22` (style)
3. **Task 2: 'Cubbit DS3 Drive' → 'DS3 Drive' rebrand** — _staged, awaiting commit (1Password ssh signer gate, see "User Action Required")_

**Plan metadata commit:** _pending — will follow Task 2 commit_

## Files Created/Modified

### Plan files

- `DS3Drive/Views/Tutorial/Views/TutorialView.swift` — replaced slide-index `if isHeroSlide { brandHeroSubtle } else { brandBackground }` with single `DS3Gradients.brandVerticalBackground.ignoresSafeArea()` ZStack root
- `DS3Drive/Info.plist` — added `CFBundleDisplayName` and `CFBundleName` ("DS3 Drive")
- `DS3DriveProvider/Info.plist` — added `CFBundleDisplayName` ("DS3 Drive"); changed `NSFileProviderDomainDisplayName` from "Cubbit DS3 Drive" to "DS3 Drive"
- `DS3Drive.xcodeproj/project.pbxproj` — replaced all six `INFOPLIST_KEY_CFBundleDisplayName = "Cubbit DS3 Drive"` occurrences (DS3Drive macOS Debug/Release, DS3DriveApp iOS Debug/Release, DS3DriveShareExtension Debug/Release) with `"DS3 Drive"`
- `DS3Drive/DS3DriveApp.swift` — `showSessionExpiredNotification` notification title key renamed
- `DS3Drive/Update/UpdateNotificationHandler.swift` — `postNotification` title key renamed
- `DS3Drive/Assets/Localizable.xcstrings` — top-level key `"Cubbit DS3 Drive"` renamed to `"DS3 Drive"` and Italian value updated

### Rule 3 blocker fix (deviation, see below)

- `DS3Drive.xcodeproj/project.pbxproj` — added `TrayDriveGearMenu.swift` PBXBuildFile / PBXFileReference / group membership / Sources build phase entries
- `DS3Drive/Views/Tray/Views/TrayDriveGearMenu.swift` — added `@MainActor` to `build`, `addAction` and `buildS3Path` static helpers (they reference `driveViewModel.drive` and instantiate `BlockMenuItem`, both `@MainActor`-isolated)

### Plan SDK step result (no change required)

- `DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` — verified `fileProviderDomain(forDrive:)` already passes `drive.name` as `displayName` (per-drive). No literal "Cubbit DS3 Drive" present in DS3Lib. No edit needed.

## Decisions Made

- **Branding policy:** drop "Cubbit " prefix everywhere it touches the user — Finder sidebar, Dock label, banner notifications, About panel. The corporate Cubbit brand stays in `PRODUCT_BUNDLE_IDENTIFIER`, copyright strings, and the logo mark. Per-drive `displayName` (drive.name) is the actual sidebar label once a drive is registered.
- **PRODUCT_NAME left untouched:** the macOS DS3Drive target's `PRODUCT_NAME = "Cubbit DS3 Drive"` build setting was NOT changed in this plan. Renaming it would change the .app bundle filename, requiring re-signing / DerivedData cleanup / LaunchServices reset (see CLAUDE.md "Extension Won't Load" recovery sequence). Since `INFOPLIST_KEY_CFBundleDisplayName` overrides what the user sees in Finder/Dock, the rename is invisible without changing the bundle filename. A future plan can flip `PRODUCT_NAME` and bake the .app rename into a release.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Pre-existing build break: TrayDriveGearMenu.swift not in Xcode project**

- **Found during:** Task 1 build verification
- **Issue:** Commit `b6231a4` (fix(tray): replace SwiftUI Menu with NSMenu-backed gear button) added `DS3Drive/Views/Tray/Views/TrayDriveGearMenu.swift` and committed it on disk, but never added the file to `DS3Drive.xcodeproj/project.pbxproj`. Result: TrayDriveRowView.swift referenced `GearMenuButton` and `TrayDriveGearMenu` symbols that didn't exist at compile time. The DS3Drive scheme failed `xcodebuild build` with "cannot find 'GearMenuButton' in scope" / "cannot find 'TrayDriveGearMenu' in scope" — the repo was unbuildable on entry to this plan.
- **Verification:** stashed all working changes, ran `xcodebuild build` against pristine HEAD — same errors → confirmed pre-existing.
- **Fix part 1:** added `TrayDriveGearMenu.swift` to project.pbxproj across all four required sections (PBXBuildFile, PBXFileReference, group children, Sources build phase) using new IDs `A10518B20000000000000001/2`.
- **Fix part 2:** adding the file exposed Swift 6 isolation errors — `TrayDriveGearMenu.build`, `addAction` and `buildS3Path` are static helpers accessing `driveViewModel.drive` (MainActor-isolated property) and constructing `BlockMenuItem` (a `@MainActor` final class). Marked all three with `@MainActor`.
- **Files modified:** `DS3Drive.xcodeproj/project.pbxproj`, `DS3Drive/Views/Tray/Views/TrayDriveGearMenu.swift`
- **Committed in:** `fff5d96` (separate commit, ahead of Task 1)
- **Out-of-scope tracking:** none — every fix was strictly required to unblock Task 1's build verification.

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Necessary to make `xcodebuild build` succeed at all. Both Task 1 and Task 2 are verified clean as a result. No scope creep — TrayDriveRowView itself wasn't touched.

## Issues Encountered

- **GPG/SSH signing transient failure on Task 2 commit:** `git commit` for Task 2 fails with "Couldn't sign message (signer): communication with agent failed?" The repo signs commits via SSH (`gpg.format = ssh`, `gpg.ssh.program` = a Nix openssh ssh-keygen, `user.signingkey` = `ssh-rsa AAAA...`). The 1Password SSH agent (`SSH_AUTH_SOCK` = 1Password agent.sock) responds to `ssh-add -l` but `ssh-keygen -Y sign` returns the agent failure. Earlier commits in the same session (`fff5d96`, `c1d1d22` and three commits before this plan) succeeded — 1Password evidently locked or stopped surfacing the signing approval prompt to this session mid-way. **All Task 2 changes are staged and verified clean — only the commit object can't be created until 1Password is unlocked.**

## User Action Required

After unlocking 1Password (or touching any 1Password UI to surface the SSH signing approval prompt), run:

```bash
cd /Users/marmos91/Projects/cubbit-ds3-drive

# Task 2 commit (message saved at /tmp/05-18c-task2-msg.txt)
git commit -F /tmp/05-18c-task2-msg.txt

# Plan metadata commit
git add .planning/phases/05-ux-polish/05-18c-SUMMARY.md .planning/STATE.md .planning/ROADMAP.md .planning/REQUIREMENTS.md
git commit -m "docs(05-18c): complete tutorial backdrop & DS3 Drive branding plan"
```

If signing keeps failing, restart the 1Password app (or `op signin`) and retry.

## Finder Sidebar Refresh Caveat

After installing this build, **the user must remove and re-add the File Provider domain** for the Finder sidebar label to refresh from the cached `NSFileProviderDomainDisplayName` plist value. There are two ways:

1. **System Settings → General → Login Items & Extensions → File Provider** → toggle the Cubbit DS3 Drive extension off and on, OR
2. **Sign out and sign back in** to the app (the drive disconnect/reconnect cycle re-registers the domain with the system, picking up the new fallback name).

Live drives that are already registered will continue to show their per-drive `displayName` (drive.name), which is unaffected by this plan — only the system-level fallback used before any drive exists is bound to the plist value.

## Next Phase Readiness

- Tutorial polish + branding pass complete; Plan 05-18 (parent) is one step closer to closure.
- Remaining Plan 05-18 split (`05-18d`+ if any) can proceed.
- No new tests required (string + plist + view-tree changes have no behavioral surface beyond visuals).

## Self-Check

To be appended after final commits succeed.

---
*Phase: 05-ux-polish*
*Completed: 2026-04-08*
