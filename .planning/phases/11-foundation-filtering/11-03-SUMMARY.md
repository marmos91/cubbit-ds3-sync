---
phase: 11-foundation-filtering
plan: 03
subsystem: file-provider-extension
tags: [filtering, enumeration, thumbnails, security]
dependency_graph:
  requires: ["11-01"]
  provides: ["centralized-isUserVisible-filter", "S3Lib+Thumbnails-wrapper"]
  affects: ["S3Enumerator", "BreadthFirstIndexer", "S3LibListingAdapter", "FileProviderExtension+Lifecycle", "SyncAnchorSelectionViewModel", "TreeNavigationView", "ShareFolderPickerView"]
tech_stack:
  added: []
  patterns: ["centralized-filter-choke-point", "extension-side-DS3Lib-wrapper"]
key_files:
  created:
    - DS3DriveProvider/S3Lib+Thumbnails.swift
  modified:
    - DS3DriveProvider/S3Enumerator.swift
    - DS3DriveProvider/BreadthFirstIndexer.swift
    - DS3DriveProvider/S3LibListingAdapter.swift
    - DS3DriveProvider/FileProviderExtension+Lifecycle.swift
    - DS3Drive/Views/Sync/ViewModels/SyncAnchorSelectionViewModel.swift
    - DS3Drive/Views/Sync/Views/TreeNavigationView.swift
    - DS3DriveShareExtension/ShareFolderPickerView.swift
    - DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift
    - DS3Drive.xcodeproj/project.pbxproj
decisions:
  - "S3Lib.isUserVisible wraps S3KeyFilter.isUserVisible for extension-side use (mirrors S3Lib+Trash pattern)"
  - "Non-extension sites use S3KeyFilter.isUserVisible directly (no S3Lib dependency in app targets)"
  - "deleteFolder and copyFolder intentionally exempt from filtering (must see all keys for recursive operations)"
metrics:
  duration: "7m"
  completed: "2026-04-13"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 9
---

# Phase 11 Plan 03: Centralized Enumeration Filter Integration Summary

All ListObjectsV2 consumer sites now route through S3KeyFilter.isUserVisible via extension-side S3Lib wrappers, ensuring .thumbnails/ keys never reach Finder, Files.app, MetadataStore, SyncEngine, or wizard folder pickers.

## What Was Done

### Task 1: Create S3Lib+Thumbnails.swift and ListObjectsV2 audit
- Created `DS3DriveProvider/S3Lib+Thumbnails.swift` with three static methods:
  - `isUserVisible(_:drive:)` — central choke point routing to `S3KeyFilter.isUserVisible`
  - `isThumbnailKey(_:drive:)` — routes to `S3PathUtils.isThumbnailKey`
  - `fullThumbnailPrefix(forDrive:)` — routes to `S3PathUtils.thumbnailsPrefix`
- Documented full ListObjectsV2 consumer audit (D-21) with verified line numbers
- Added file to both macOS and iOS File Provider extension targets in Xcode project
- **Commit:** ab0cc58

### Task 2: Route all 9 consumer sites through centralized filter
- **Extension sites (S3Lib.isUserVisible):**
  1. S3Enumerator per-folder enumeration — new filter before `observer.didEnumerate` and MetadataStore upsert
  2. S3Enumerator recursive/working-set — replaced inline `isTrashedKey` with `isUserVisible`
  3. S3Enumerator enumerateChanges fallback — new filter before `observer.didUpdate`
  4. BreadthFirstIndexer BFS dequeue — replaced `hasPrefix(trashPrefix)` with `isUserVisible`
  5. S3LibListingAdapter SyncEngine feed — replaced `hasPrefix(trashPrefix)` with `isUserVisible`
  6. FileProviderExtension+Lifecycle warm-up — new filter before MetadataStore upsert
- **Non-extension sites (S3KeyFilter.isUserVisible on commonPrefixes):**
  7. SyncAnchorSelectionViewModel — wizard folder browser
  8. TreeNavigationView — bucket expansion and folder expansion (2 call sites)
  9. ShareFolderPickerView — iOS Share Extension folder picker
- **Commit:** 7087feb

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed duplicate thumbnailsPrefix method in S3PathUtils.swift**
- **Found during:** Task 1 (build failure)
- **Issue:** S3PathUtils.swift contained two `thumbnailsPrefix(forDrivePrefix:)` methods (line 44 with hardcoded string, line 110 with constant). Wave-1 agent added both.
- **Fix:** Removed the duplicate at line 44-46 (kept the one using `DefaultSettings.S3.thumbnailsPrefix`)
- **Files modified:** DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift
- **Commit:** ab0cc58

## Verification Results

- `grep -rn "S3Lib.isUserVisible" DS3DriveProvider/` returns 6 call sites (+ 1 audit comment)
- `grep -rn "S3KeyFilter.isUserVisible" DS3Drive/ DS3DriveShareExtension/` returns 4 call sites
- No remaining standalone `isTrashedKey` filters on enumeration paths
- `xcodebuild` build succeeds with zero errors

## Latent Bugs Fixed (side-effect)

Two pre-existing latent trash-leak bugs were fixed as a direct side-effect of adding the centralized filter:
1. **Per-folder enumeration (S3Enumerator ~line 307):** Had NO filter — trash items could leak into Finder folder views
2. **Warm-up cache (FileProviderExtension+Lifecycle ~line 54):** Had NO filter — trash items could leak into MetadataStore on startup

## Self-Check: PASSED
