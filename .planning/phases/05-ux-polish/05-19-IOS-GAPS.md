# Plan 05-19 — iOS Gap Matrix (investigation pass)

Investigation produced during Task 1 of Plan 05-19. Each iOS surface
audited against the corrected Composer canary brand foundation that
landed in Plan 05-17 (`DS3Lib/Sources/DS3Lib/DesignSystem/`).

## Summary

| Concern | Status before sweep |
|---|---|
| `UIAppFonts` registered in `DS3DriveApp/Info.plist` | OK (Plan 05-17) |
| `UIAppFonts` registered in `DS3DriveShareExtension/Info.plist` | OK (Plan 05-17) |
| Figtree TTFs in `DS3DriveApp` Copy Bundle Resources | **MISSING** — only macOS target had them. iOS app would silently fall back to system font even with Info.plist registered, because the files aren't in the bundle. |
| Figtree TTFs in `DS3DriveShareExtension` Copy Bundle Resources | **MISSING** — same reason. |
| `IOSColors` re-exports corrected DS3Lib tokens | Partial — only legacy `brandPrimary/Background/Surface/TextPrimary/TextSecondary/Border` exposed; missing `brandPrimaryDark`, `brandPrimaryLight`, `statusInfo`, `brandBorderUltraSubtle`, `brandBorderSubtle`, `brandBorderStrong`, `brandBg900/800/700`, `textTertiary`. |
| `IOSTypography` uses Figtree | **NO** — uses `Font.title2.bold()` / `Font.headline` / `Font.body` / `Font.caption` (San Francisco). Plan 05-13 left this as the system font. Needs to point at `DS3Lib.DS3Typography`. |
| `ShareTypography` uses Figtree | **NO** — same problem, plain `Font.title2.bold()` / `Font.headline` etc. |
| `IOSPrimaryButtonStyle` uses brand primary | OK (Plan 05-13) |
| `SharePrimaryButtonStyle` uses brand primary | OK (Plan 05-13) |
| iOS Login uses macOS-style ZStack hero gradient | **NO** — flat `IOSColors.background`. iPad branch has the "background then card with another background" double-fill anti-pattern (Gap 19 mirror). |
| Hardcoded `Color.orange` project emblem | YES — `ProjectListView`, `DriveDetailView`, `DriveConfirmView` all hardcode `Color.orange` instead of pulling a hashed color from `DS3Colors.colorForProject(_:)` (which exists in `DS3Lib`). Mirror of macOS pre-05-13 pattern. |
| `.system(size:)` font calls | YES — see grep below. |

## Hardcoded values found via grep

```text
DS3DriveApp/Views/Login/IOSMFAView.swift:27          .font(.system(size: 48))
DS3DriveApp/Views/Dashboard/DriveDetailView.swift:114 .font(.system(size: 13))
DS3DriveApp/Views/Dashboard/DriveDetailView.swift:136 .font(.system(size: 8, weight: .bold))
DS3DriveApp/Views/Setup/ProjectListView.swift:139    .font(.system(size: 11, weight: .bold))
DS3DriveApp/Views/Dashboard/EmptyDrivesView.swift:14 .font(.system(size: 64))
DS3DriveApp/Views/Setup/DriveConfirmView.swift:46    .font(.system(size: 9, weight: .bold))
DS3DriveApp/Views/Setup/DriveConfirmView.swift:72    .font(.system(size: 14))
DS3DriveShareExtension/ShareUnauthenticatedView.swift:32 .font(.system(size: 48))
```

(`.system(size:)` SF symbols glyph sizing is intentional — those are
icon size hints, not text fonts. Left in place; they don't fight the
typography system.)

## Per-file gap matrix

### DS3DriveApp

| File | Gaps |
|---|---|
| `Views/Common/IOSDesignSystem.swift` | `IOSTypography` uses system fonts; missing semantic tokens; missing border ramp. |
| `Views/Common/IOSButtonStyles.swift` | `font(IOSTypography.headline)` will start using Figtree once IOSTypography is rewired. No other change needed; primary fill is already `IOSColors.brandPrimary`. |
| `Views/App/IOSAppRootView.swift` | No backdrop wrapper — relies on IOSLoginView/IOSMainTabView to set it. Add a global `IOSColors.background` to ensure brand is visible during transitions. |
| `Views/App/IOSMainTabView.swift` | Tab/list backgrounds are system default — should use brand backdrop. |
| `Views/Login/IOSLoginView.swift` | **Gap 19 iOS mirror** — needs ZStack hero gradient fix; iPad branch has double-fill border; "DS3 Drive" title uses `IOSTypography.title` which is currently SF; Logo + form on flat background. |
| `Views/Login/IOSMFAView.swift` | Same backdrop issue (no brand background on the sheet). |
| `Views/Dashboard/DriveListView.swift` | `List` uses system grouped background instead of brand. |
| `Views/Dashboard/DriveCardView.swift` | Already uses IOSColors/IOSTypography — picks up brand automatically once typography is rewired. |
| `Views/Dashboard/DriveDetailView.swift` | Project emblem hardcodes `Color.orange` + black text. |
| `Views/Dashboard/EmptyDrivesView.swift` | OK — already uses IOSColors/IOSTypography. |
| `Views/Setup/IOSSetupWizardView.swift` | OK structurally — wizard nav inherits backdrop from steps. |
| `Views/Setup/ProjectListView.swift` | Project emblem hardcodes `Color.orange`. |
| `Views/Setup/BucketListView.swift` | OK. |
| `Views/Setup/PrefixListView.swift` | OK. |
| `Views/Setup/DriveConfirmView.swift` | Project emblem hardcodes `Color.orange`; summary card uses `IOSColors.secondaryBackground` already (good). |
| `Views/Settings/IOSSettingsView.swift` | OK — pure List sections with brand colors. |

### DS3DriveShareExtension

| File | Gaps |
|---|---|
| `ShareExtensionView.swift` | `ShareTypography` uses system fonts. |
| `ShareDrivePickerView.swift` | OK. |
| `ShareFolderPickerView.swift` | OK. |
| `ShareUploadProgressView.swift` | OK. |
| `ShareUnauthenticatedView.swift` | OK. |

## Out of scope for Plan 05-19

The following candidates were found but deferred — they are not strictly
brand sweep work and would require behavioural verification:

1. **iOS state machine consumes `AggregateStatus`?** — `IOSDriveViewModel`
   has its own per-drive status machine (Plan 05-15 added
   `AggregateStatus` only on macOS). iOS may have the equivalent of
   Gaps 14/15/27 if `IOSDriveViewModel.statusColor(for:)` ever returns
   stale state. Out of scope for Plan 05-19; track as potential 05-20
   followup.
2. **iOS app icon polish (Plan 05-08 Task 1 macOS counterpart)** — iOS
   icon is a single 1024 universal asset (`AppIcon-1024.png`). Whether
   it matches the polish that landed for the macOS app icon is a visual
   judgement that requires running the app on a device. Out of scope.
3. **`Color.orange` project emblem deduplication** — iOS could call
   `DS3Lib.DS3Colors.colorForProject(_:)` (exists in DS3Lib) for hashed
   colors. The macOS app does this; iOS still hardcodes `Color.orange`.
   In scope: replace with the DS3Lib hashed palette in this sweep.

## Decisions taken during investigation

1. **Figtree TTF target membership** — add the existing
   `DS3Drive/Assets/Fonts/Figtree-*.ttf` file references to the
   `DS3DriveApp` and `DS3DriveShareExtension` Resources build phases.
   Files do not need to move; Xcode can copy from the same source path
   into multiple bundles.
2. **`IOSTypography` rewrite** — point every alias at
   `DS3Lib.DS3Typography.*` (Figtree). Existing call sites
   (`.font(IOSTypography.title)` etc.) will pick up Figtree
   automatically with zero per-view edits.
3. **`ShareTypography` rewrite** — same as above for the Share
   Extension target.
4. **iOS Login backdrop** — wrap content in a ZStack with
   `DS3Lib.DS3Gradients.brandVerticalBackground.ignoresSafeArea()` as
   the bottom layer. Drop the iPad-specific double-card pattern; use
   the same flow on both size classes (a max-width wrapper is fine,
   but no second background fill).
5. **Project emblem hashed color** — replace `Color.orange` with
   `DS3Lib.DS3Colors.colorForProject(projectId)` where the project ID
   is available; fall back to `IOSColors.brandPrimary` where the call
   site doesn't have an ID handy (the wizard summary card has the
   project struct so it can pass the id).

## Verification strategy

Agent Xcode lacks the iOS 26.4 SDK so iOS builds happen on CI. Local
verification is limited to:

- Source-grep verification matrix (zero `.system(\.|size:` for text in
  iOS view files; zero `Color.orange` in iOS view files)
- Cross-platform compile of DS3Lib (the macOS DS3Drive build proves the
  shared types still compile)
- Visual checkpoint (Task 4) — human runs the iOS simulator
