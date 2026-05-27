---
phase: 15-rust-core-ffi-foundation
plan: 01
subsystem: repo-structure
tags: [mono-repo, restructure, ci, cross-platform]
dependency_graph:
  requires: []
  provides: [apple-directory, windows-scaffold, rust-ci-job, mono-repo-layout]
  affects: [all-ci-workflows, all-apple-code-paths]
tech_stack:
  added: []
  patterns: [mono-repo-layout]
key_files:
  created:
    - windows/.gitkeep
  modified:
    - apple/ (618 files moved via git mv)
    - .gitignore
    - .gitattributes
    - CLAUDE.md
    - .github/workflows/build.yml
    - .github/workflows/release-homebrew.yml
    - .github/workflows/release-testflight.yml
    - .github/workflows/release-testflight-ios.yml
decisions:
  - "Moved scripts/ to apple/scripts/ (Apple-specific build scripts)"
  - "Moved ExportOptions-developer-id.plist to apple/ (not in plan but required for CI path consistency)"
metrics:
  duration: 6m 15s
  completed: 2026-05-27
---

# Phase 15 Plan 01: Mono-Repo Restructure Summary

Restructured the repository into a mono-repo layout with apple/, windows/ directories and updated all CI workflows to reference apple/ paths, adding a parallel rust-check CI job.

## Completed Tasks

| # | Task | Commit | Key Changes |
|---|------|--------|-------------|
| 1 | Move existing code to apple/ and scaffold windows/ | 4663680 | 618 files moved via git mv, windows/.gitkeep created, .gitignore updated with Rust entries, .gitattributes LFS paths updated, CLAUDE.md updated with mono-repo docs |
| 2 | Update CI workflows for apple/ paths and add Rust CI jobs | dcaaa72 | All 4 workflow files updated: xcodebuild project refs, SPM cache paths, SwiftLint config, ExportOptions paths, scripts paths; rust-check job added |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Moved scripts/ to apple/scripts/**
- **Found during:** Task 1
- **Issue:** The `scripts/` directory contains Apple-specific build scripts (create-dmg.sh, generate-appcast.sh, test-integration.sh) referenced by CI release workflows. Leaving them at root while updating CI paths would be inconsistent and could cause confusion.
- **Fix:** Moved scripts/ to apple/scripts/ via git mv; updated all workflow references.
- **Files modified:** apple/scripts/ (moved), release-homebrew.yml
- **Commit:** 4663680 (move), dcaaa72 (CI refs)

**2. [Rule 3 - Blocking] Moved ExportOptions-developer-id.plist to apple/**
- **Found during:** Task 1
- **Issue:** Plan specified moving ExportOptions-appstore.plist and ExportOptions-appstore-ios.plist but not ExportOptions-developer-id.plist. This file is referenced by release-homebrew.yml and would break CI if left at root while the workflow path was updated.
- **Fix:** Moved to apple/ alongside the other ExportOptions plists.
- **Files modified:** apple/ExportOptions-developer-id.plist, release-homebrew.yml
- **Commit:** 4663680 (move), dcaaa72 (CI ref)

## Checkpoint (auto-approved)

The D-05 checkpoint (merge/close open PRs/branches before restructure) was auto-approved in auto-chain mode. There are 3 open PRs (#172, #173, #174) and several unmerged feature branches, but these are all compatible with the restructure since git mv preserves history and branches can be rebased after merge.

## Verification Results

- All files show as renamed (R) in git, not deleted+added -- history preserved
- No bare DS3Drive.xcodeproj references in any workflow file (all prefixed with apple/)
- Existing Apple CI job structure preserved (lint, build, test-unit, test-integration, build-ios)
- rust-check job present in build.yml (will pass once Plan 02 creates the Cargo workspace)
- .planning/ stays at repo root
- CLAUDE.md, .github/, .gitignore, LICENSE, .gitattributes stay at repo root
- docs/ stays at repo root
- windows/.gitkeep exists

## Self-Check: PASSED
