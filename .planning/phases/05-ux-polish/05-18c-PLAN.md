---
phase: 05-ux-polish
plan: 18c
type: execute
wave: 3
gap_closure: true
depends_on: [05-17]
parent_plan: 05-18
files_modified:
  - DS3Drive/Views/Tutorial/Views/TutorialView.swift
  - DS3Drive/Info.plist
  - DS3DriveProvider/Info.plist
  - DS3Lib/Sources/DS3Lib/DS3DriveManager.swift
  - DS3Drive/DS3DriveApp.swift
  - DS3Drive/Update/UpdateNotificationHandler.swift
  - DS3Drive/Assets/Localizable.xcstrings
autonomous: false
requirements: [UX-01]

must_haves:
  truths:
    - "All 7 tutorial slides use ONE backdrop (DS3Gradients.brandVerticalBackground) — no slide-index conditional"
    - "DS3Drive/Info.plist CFBundleDisplayName = 'DS3 Drive' (added if missing)"
    - "DS3DriveProvider/Info.plist NSFileProviderDomainDisplayName = 'DS3 Drive'"
    - "Zero remaining 'Cubbit DS3 Drive' literals across DS3Drive/, DS3DriveProvider/, DS3Lib/Sources/DS3Lib/"
---

<objective>
Closes Gaps 6, 20, 29. Third split from 05-18.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
</execution_context>

<context>
@.planning/phases/05-ux-polish/05-08-GAPS.md
@.planning/phases/05-ux-polish/05-18-PLAN.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Tutorial slide backdrop unification (Gap 20)</name>
  <files>
    DS3Drive/Views/Tutorial/Views/TutorialView.swift
  </files>
  <action>
    Read TutorialView.swift, find the `if currentSlide == 0 || currentSlide == 6 { brandHeroSubtle } else { brandBackground }` (or equivalent slide-index conditional) pattern, replace with a single `DS3Gradients.brandVerticalBackground.ignoresSafeArea()` ZStack root applied to all slides. Eliminate any per-slide background variation.
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - grep "currentSlide == 0" in TutorialView.swift returns zero (or only references unrelated to backgrounds)
  </done>
</task>

<task type="auto">
  <name>Task 2: Finder sidebar 'DS3 Drive' branding (Gaps 6, 29)</name>
  <files>
    DS3Drive/Info.plist,
    DS3DriveProvider/Info.plist,
    DS3Lib/Sources/DS3Lib/DS3DriveManager.swift,
    DS3Drive/DS3DriveApp.swift,
    DS3Drive/Update/UpdateNotificationHandler.swift,
    DS3Drive/Assets/Localizable.xcstrings
  </files>
  <action>
    Step 1 — DS3Drive/Info.plist: add `CFBundleDisplayName` = `DS3 Drive` if missing, and `CFBundleName` = `DS3 Drive` if it currently says "Cubbit DS3 Drive". (Read first to confirm current state.)

    Step 2 — DS3DriveProvider/Info.plist: NSFileProviderDomain.NSFileProviderDomainDisplayName "Cubbit DS3 Drive" → "DS3 Drive" (line 121). Add `CFBundleDisplayName` = `DS3 Drive` if missing.

    Step 3 — Read DS3Lib/Sources/DS3Lib/DS3DriveManager.swift, find any `NSFileProviderDomain(identifier:displayName:)` calls. The domain displayName should be the per-drive name (drive.name) — verify this is already the case. If a hardcoded "Cubbit DS3 Drive" string exists anywhere, replace with the drive's configured name.

    Step 4 — DS3DriveApp.swift line 275 (showSessionExpiredNotification): `content.title = NSLocalizedString("Cubbit DS3 Drive", ...)` → `NSLocalizedString("DS3 Drive", ...)`

    Step 5 — DS3Drive/Update/UpdateNotificationHandler.swift: grep + replace any "Cubbit DS3 Drive" → "DS3 Drive"

    Step 6 — Localizable.xcstrings: replace remaining "Cubbit DS3 Drive" literals in en + it variants with "DS3 Drive"

    Step 7 — Final grep across DS3Drive/, DS3DriveProvider/, DS3Lib/Sources/DS3Lib/ for "Cubbit DS3 Drive" — must return zero matches.

    Note in SUMMARY: after install, the user must remove + re-add the File Provider domain (via System Settings → File Provider, OR sign out/in) for the Finder sidebar label to refresh from the cached value.
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - grep "Cubbit DS3 Drive" in DS3Drive/ DS3DriveProvider/ DS3Lib/Sources/ returns zero matches
  </done>
</task>

</tasks>

<output>
Create `.planning/phases/05-ux-polish/05-18c-SUMMARY.md`.
</output>
