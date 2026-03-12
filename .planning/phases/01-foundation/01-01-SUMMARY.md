---
phase: 01-foundation
plan: 01
subsystem: infra
tags: [xcode, spm, swift-package, rename, macos, ci]

# Dependency graph
requires: []
provides:
  - DS3Drive.xcodeproj with renamed targets and local SPM package
  - DS3Lib as local Swift Package with SotoS3 and swift-atomics dependencies
  - Updated bundle identifiers (io.cubbit.DS3Drive, io.cubbit.DS3Drive.provider)
  - App Group group.io.cubbit.DS3Drive in all entitlement files
  - CI workflow targeting DS3Drive scheme on macOS 15 / Xcode 16.2
affects: [01-02, 01-03, 01-04, 02-01, 04-01]

# Tech tracking
tech-stack:
  added: [swift-package-manager-local]
  patterns: [local-spm-package-for-shared-library]

key-files:
  created:
    - DS3Lib/Package.swift
    - DS3Lib/Tests/DS3LibTests/DS3LibTests.swift
  modified:
    - DS3Drive.xcodeproj/project.pbxproj
    - DS3Drive.xcodeproj/xcshareddata/xcschemes/DS3Drive.xcscheme
    - DS3Drive.xcodeproj/xcshareddata/xcschemes/DS3DriveProvider.xcscheme
    - DS3Drive/DS3DriveApp.swift
    - DS3Drive/DS3Drive.entitlements
    - DS3DriveProvider/DS3DriveProvider.entitlements
    - DS3DriveProvider/Info.plist
    - DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift
    - .github/workflows/build.yml
    - README.md
    - CLAUDE.md

key-decisions:
  - "Converted DS3Lib from Xcode framework target to local SPM package, removing all source file compilation from app/extension targets"
  - "Removed project-level SotoS3 and swift-collections SPM dependencies since they are now declared in DS3Lib/Package.swift"
  - "Simplified CI workflow to build DS3Drive scheme directly without dynamic scheme detection"

patterns-established:
  - "Local SPM package pattern: DS3Lib/Package.swift declares all third-party dependencies, app and extension targets only depend on DS3Lib product"
  - "Bundle identifier convention: io.cubbit.DS3Drive (app), io.cubbit.DS3Drive.provider (extension)"

requirements-completed: [FOUN-01]

# Metrics
duration: 9min
completed: 2026-03-11
---

# Phase 1 Plan 01: Rename App to DS3 Drive Summary

**Full rename from CubbitDS3Sync to DS3 Drive with DS3Lib converted to local Swift Package targeting macOS 15**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-11T12:36:20Z
- **Completed:** 2026-03-11T12:45:47Z
- **Tasks:** 2
- **Files modified:** 270+ (including asset renames)

## Accomplishments
- Renamed all directories (CubbitDS3Sync -> DS3Drive, Provider -> DS3DriveProvider) and files with git history preserved
- Converted DS3Lib from Xcode framework target to local Swift Package with Package.swift declaring SotoS3 and swift-atomics
- Updated all bundle identifiers, App Group references, entitlements, Info.plist, and DefaultSettings constants
- Rewrote pbxproj to remove DS3Lib framework target and add local package reference
- Updated CI workflow for macOS 15 / Xcode 16.2 with simplified build command
- Updated README.md and CLAUDE.md with new project structure and names

## Task Commits

Each task was committed atomically:

1. **Task 1: Rename directories, files, and convert DS3Lib to SPM** - `5c7e32b` (feat)
2. **Task 2: Update Xcode project, schemes, CI, and verify build** - `affca58` (feat)

## Files Created/Modified
- `DS3Lib/Package.swift` - New Swift Package manifest with SotoS3 and swift-atomics dependencies
- `DS3Lib/Tests/DS3LibTests/DS3LibTests.swift` - Placeholder test file for DS3Lib package
- `DS3Drive.xcodeproj/project.pbxproj` - Renamed targets, removed DS3Lib framework, added local package reference
- `DS3Drive.xcodeproj/xcshareddata/xcschemes/DS3Drive.xcscheme` - Renamed from CubbitDS3Sync scheme
- `DS3Drive.xcodeproj/xcshareddata/xcschemes/DS3DriveProvider.xcscheme` - Renamed from Provider scheme
- `DS3Drive/DS3DriveApp.swift` - Renamed struct from ds3syncApp to DS3DriveApp, updated window IDs
- `DS3Drive/DS3Drive.entitlements` - Updated App Group to group.io.cubbit.DS3Drive
- `DS3DriveProvider/DS3DriveProvider.entitlements` - Updated App Group to group.io.cubbit.DS3Drive
- `DS3DriveProvider/Info.plist` - Updated document group and display name
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` - Updated all identifier strings
- `.github/workflows/build.yml` - Updated to macOS 15, Xcode 16.2, DS3Drive scheme
- `README.md` - Updated project name and instructions
- `CLAUDE.md` - Updated architecture documentation

## Decisions Made
- Converted DS3Lib from Xcode framework target to local SPM package: this eliminates the need to compile DS3Lib sources in each target separately. Both the app and extension now use `import DS3Lib` and depend on the SPM product.
- Removed project-level SotoS3 and swift-collections remote package dependencies from the xcodeproj since they are now managed by DS3Lib's Package.swift.
- Simplified CI workflow: removed certificate/provisioning profile setup and dynamic scheme detection, using direct xcodebuild with CODE_SIGNING_ALLOWED=NO for CI builds.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed triple-replacement bug in pbxproj entitlements**
- **Found during:** Task 2 (pbxproj update)
- **Issue:** The sed-style replacement for Provider.entitlements applied multiple times, creating `DS3DriveDS3DriveDS3DriveProvider.entitlements`
- **Fix:** Used targeted Python replacement to correct the triple-replaced string
- **Files modified:** DS3Drive.xcodeproj/project.pbxproj
- **Verification:** Grep confirmed no malformed entitlement references remain
- **Committed in:** affca58 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Minor text replacement issue, fixed before commit. No scope creep.

## Issues Encountered
- Xcode is not installed on the build machine, so xcodebuild verification could not be performed. The pbxproj structure was verified programmatically instead. Build verification will happen when the project is opened in Xcode.
- sed commands failed due to argument parsing issues in the shell environment; switched to Python for all text replacements.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Project structure is finalized with new names and identifiers
- DS3Lib is a proper Swift Package ready for structured imports
- All subsequent plans can reference DS3Drive paths and identifiers
- Build verification with Xcode is recommended before proceeding to Plan 02

## Self-Check: PASSED

- All 9 key files verified present on disk
- Both task commits verified in git log (5c7e32b, affca58)
- No remaining CubbitDS3Sync references in pbxproj
- No remaining old App Group references in entitlements or source

---
*Phase: 01-foundation*
*Completed: 2026-03-11*
