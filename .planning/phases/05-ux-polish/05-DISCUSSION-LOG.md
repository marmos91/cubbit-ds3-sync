# Phase 5: UX Polish - Discussion Log (Update Session)

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-03
**Phase:** 05-ux-polish
**Areas discussed:** Localization scope, CI/Swift 6 fixes, Human verification, Bug fixes scope, UI/Brand polish, iOS scope

---

## Localization Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Italian only | Verify existing Italian translations are complete and correct. No other languages for v1.0. | ✓ |
| Italian + review pass | Italian only, but do a quality review pass | |
| Add more languages | Add English, Italian, and 1-2 more (e.g., German, French) | |

**User's choice:** Italian only (Recommended)
**Notes:** 83 Italian entries already exist in .xcstrings. Sufficient for v1.0.

---

## CI/Swift 6 Fixes

| Option | Description | Selected |
|--------|-------------|----------|
| Fix blockers only | Only fix errors that break the build. Leave warnings for later. | |
| Fix all warnings | Clean up all Swift 6 concurrency warnings across the codebase. | ✓ |
| Pin Xcode version | Pin CI to Xcode 16.x to avoid new strictness. | |

**User's choice:** Fix all warnings
**Notes:** User wants a clean CI. Both macOS and iOS targets.

---

## Human Verification

| Option | Description | Selected |
|--------|-------------|----------|
| All 7 must pass | Badges, tray status, speed, recent files, quick actions, wizard, drive limit — all verified. | ✓ |
| Core 4 must pass | Badges, tray, wizard, quick actions are must-pass. | |
| Build + smoke test | App builds and launches, basic flow works. | |

**User's choice:** All 7 must pass (Recommended)
**Notes:** Full verification bar for milestone completion.

---

## Bug Fixes Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Polish only | Plan 05 stays focused on UX polish. Bug fixes are separate PRs. | |
| Include known bugs | Fold remaining known issues into plan 05. | |
| Bug sweep first | Do a bug sweep before final polish — find and fix issues, then verify. | ✓ |

**User's choice:** Bug sweep first
**Notes:** User wants to find and fix bugs before the final polish pass.

---

## UI/Brand Polish

| Option | Description | Selected |
|--------|-------------|----------|
| App icon refinement | Polish the app icon. | |
| Color/spacing audit | Audit all views for consistent spacing, padding, accent color. | |
| Tutorial flow polish | Ensure first-run tutorial matches new design language. | |
| All of the above | Full visual audit: icon, colors, spacing, tutorial. | ✓ |

**User's choice:** All of the above
**Notes:** Full visual audit across all views.

---

## iOS Scope (Additional)

| Option | Description | Selected |
|--------|-------------|----------|
| iOS bug sweep too | Include iOS in the bug sweep. | |
| iOS Swift 6 fixes | Fix Swift 6 concurrency warnings on the iOS target. | |
| Both bugs + Swift 6 | Full sweep: bugs and Swift 6 warnings on both macOS and iOS. | ✓ |
| iOS not in scope | Keep plan 05 macOS-only. | |

**User's choice:** Both bugs + Swift 6
**Notes:** Both platforms must be clean.

### iOS Verification

| Option | Description | Selected |
|--------|-------------|----------|
| Build + runtime fixes only | Fix Swift 6 warnings and runtime bugs. No formal iOS UX verification. | |
| Full iOS verification too | Add an iOS human-verify checkpoint alongside macOS. Test on real device. | ✓ |

**User's choice:** Full iOS verification too
**Notes:** Both macOS and iOS must pass human verification before milestone completion.

---

## Claude's Discretion

No areas deferred to Claude's discretion in this update session.

## Deferred Ideas

None — all discussed topics fall within phase scope.
