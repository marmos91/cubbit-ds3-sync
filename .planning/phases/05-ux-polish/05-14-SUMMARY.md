---
phase: 05-ux-polish
plan: 14
subsystem: tutorial, design-system, brand-identity
tags: [tutorial, brand, design-system, gap-closure, ux-onboarding, partial]
gap_closure: true
gaps_closed: [3]
status: partial-awaiting-human-screenshots
requirements: [UX-02]
dependency-graph:
  requires:
    - DS3Colors.brand* tokens (Plan 05-11)
    - DS3Gradients.brandHero / brandHeroSubtle (Plan 05-11)
    - Tray redesign (Plan 05-12)
    - iOS brand parity + wizard hero (Plan 05-13)
  provides:
    - "7-slide tutorial showcasing all UX-01..UX-07 features"
    - "Tutorial slide imagesets (placeholder, awaiting human screenshots)"
    - "tutorial.slide{1..7}.title / .description localizations (en + it)"
  affects:
    - DS3Drive/Views/Tutorial/Models/SlideModel.swift
    - DS3Drive/Views/Tutorial/ViewModels/TutorialViewModel.swift
    - DS3Drive/Views/Tutorial/Views/TutorialView.swift
    - DS3Drive/Assets/Localizable.xcstrings
    - DS3Drive/Assets/Assets.xcassets/tutorial/
tech-stack:
  added: []
  patterns:
    - "TutorialViewModel exposes a static defaultSlides array (7 entries) keyed by stable slide id; ViewModel init takes the array as a parameter so tests can substitute"
    - "Slide model uses LocalizedStringKey for title/description so SwiftUI Text() picks up Localizable.xcstrings translations automatically"
    - "Hero slide treatment (slides 1 and 7) uses DS3Gradients.brandHeroSubtle as backdrop; inner slides use brandBackground — opens and closes the tutorial with brand splash"
    - "Page indicator dots use animated capsule (brandPrimary) for the active slide and brandBorder@60% for inactive"
key-files:
  created:
    - DS3Drive/Assets/Assets.xcassets/tutorial/Contents.json
    - DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-1.imageset/* (and -2 through -7)
  modified:
    - DS3Drive/Views/Tutorial/Models/SlideModel.swift
    - DS3Drive/Views/Tutorial/ViewModels/TutorialViewModel.swift
    - DS3Drive/Views/Tutorial/Views/TutorialView.swift
    - DS3Drive/Assets/Localizable.xcstrings
key-decisions:
  - "Slide model rewritten from {imageName: ImageResource, title, paragraph} to {id, imageName: String, titleKey: LocalizedStringKey, descriptionKey: LocalizedStringKey}. String-based imageName decouples the model from Xcode's auto-generated ImageResource enum so the asset catalog can be regenerated without code changes."
  - "Slide count expanded from 4 to 7 to map 1:1 onto Phase 05's UX-01..UX-07 requirements (Finder badges, tray, speed, recent files, quick actions, wizard, drive limit)"
  - "Placeholder imagesets are 1024x640 solid brand-blue PNGs generated in pure Python (no Pillow dependency). They build green and don't break the tutorial — but they need to be replaced with real screenshots at the human-verify checkpoint"
  - "Slide model dropped Hashable conformance — LocalizedStringKey is not Hashable; Identifiable (via stable id String) is sufficient for ForEach"
  - "isHeroSlide logic only highlights the first AND last slide with the gradient backdrop (instead of every slide) to avoid visual fatigue and to bookend the tutorial with brand identity"
metrics:
  duration_human: ~12 min
  tasks: "2 of 3 (Task 3 awaiting human verification)"
  completed_date: 2026-04-07
---

# Phase 05 Plan 14: Tutorial Refresh — 7-Slide Brand Layout Summary

**Closes Gap 3 (tutorial window lacks meaningful polish and uses stale screenshots) in code; the screenshot assets themselves are placeholders pending the human-verify checkpoint where a reviewer captures fresh shots of the post-brand-overhaul UI.**

This is the **final** code-side plan of Phase 05 — every UX-01..UX-07 requirement now has a tutorial slide that surfaces it to new users at first launch.

## Tasks

| # | Name | Commit | Outcome |
|---|------|--------|---------|
| 1 | Redesign TutorialView with brand tokens + 7-feature slide structure | `e050741` | Build green |
| 2 | Add 7 tutorial slide placeholder imagesets | `5017101` | Build green |
| 3 | Human verification of tutorial visuals | — | **awaiting checkpoint** |

## What Shipped

### Task 1 — TutorialView redesign

- **`Slide` model rewritten** to use a stable `id: String`, `imageName: String`, and two `LocalizedStringKey` fields (`titleKey`, `descriptionKey`). Drops the old `ImageResource` coupling — assets can be regenerated independently.
- **`TutorialViewModel.defaultSlides`** is now a static array of 7 slides, one per UX requirement:
  - `slide-1` → Finder Sync Badges (UX-01)
  - `slide-2` → Menu Bar Status (UX-02)
  - `slide-3` → Transfer Speed (UX-03)
  - `slide-4` → Recent Files (UX-04)
  - `slide-5` → Quick Actions (UX-05)
  - `slide-6` → Drive Setup Wizard (UX-06)
  - `slide-7` → Drive Limit (UX-07)
- **`TutorialView` redesigned** with:
  - `ZStack` backdrop that switches between `DS3Gradients.brandHeroSubtle` (first/last slide) and `DS3Colors.brandBackground` (inner slides) — bookends the tutorial with brand identity.
  - Hero screenshot bordered with `RoundedRectangle.strokeBorder(DS3Colors.brandPrimary @ 20%)` and a soft drop shadow.
  - Slide title in `DS3Typography.title.bold()` over `brandTextPrimary`.
  - Slide description in `DS3Typography.body` over `brandTextSecondary`, with a max-width of 520pt for legibility.
  - Animated capsule page indicator (active slide grows to 20pt, others 8pt; active fill is `brandPrimary`, inactive is `brandBorder @ 60%`).
  - Frame bumped from 700×520 to 720×580 to accommodate the larger title typography and 7-dot indicator.

### Task 2 — Placeholder slide imagesets

- Created `DS3Drive/Assets/Assets.xcassets/tutorial/` with `provides-namespace: true` and 7 imagesets (`tutorial-slide-1.imageset` through `tutorial-slide-7.imageset`).
- Each imageset contains a single 1024×640 solid `#3384ff` (brand blue 400) PNG and a `Contents.json` with universal 1x/2x/3x slots.
- PNGs were generated via pure-Python (`struct` + `zlib`) so the build doesn't depend on Pillow or any extra tooling.
- **These are placeholders.** They build green and the tutorial flow renders without missing-asset warnings, but the actual screenshots are awaiting the human-verify checkpoint.

### Task 3 — Human verification (NOT YET PERFORMED)

This task **cannot be completed by the agent** because:

1. The agent runs headless and cannot launch the macOS app, capture screenshots interactively, or evaluate visual fidelity.
2. The plan explicitly defines this as a `checkpoint:human-verify` task.

The human reviewer needs to:

1. Build and run the app from Xcode.
2. Sign out / sign back in (or otherwise reset `tutorialShown`) to trigger the tutorial flow.
3. Step through all 7 slides — but they will see the **brand-blue placeholder PNG** instead of a real screenshot.
4. For each slide, capture a fresh screenshot of the corresponding UI surface:
   - **slide-1** — Finder window with sync badges visible on files
   - **slide-2** — Open menu bar tray showing the new card layout
   - **slide-3** — Tray with active transfer + SpeedSummaryView
   - **slide-4** — Recent Files side panel populated with entries
   - **slide-5** — Drive gear menu (quick actions) open
   - **slide-6** — Wizard tree view with selection (and/or empty hero state)
   - **slide-7** — Tray with multiple drives near the 3-drive limit
5. Replace each `tutorial-slide-N.png` in the corresponding imageset (and add `@2x` if desired).
6. Verify the title + description copy reads correctly in **both English and Italian** by toggling `Settings → Language → DS3 Drive`.
7. Type `approved` (or describe what's wrong) to close out the checkpoint.

## Localization

14 new keys added to `Localizable.xcstrings`, all in English **and** Italian:

| Key | English | Italiano |
|-----|---------|----------|
| `tutorial.slide1.title` | See sync status right in Finder | Vedi lo stato di sincronizzazione direttamente nel Finder |
| `tutorial.slide1.description` | Every file in your DS3 drive shows a badge — synced, syncing, error, or cloud-only — so you always know what's safe in the cloud. | Ogni file del tuo drive DS3 mostra un'icona — sincronizzato, in sincronizzazione, errore o solo nel cloud — così sai sempre cosa è al sicuro. |
| `tutorial.slide2.title` | Control everything from the menu bar | Controlla tutto dalla barra dei menu |
| `tutorial.slide2.description` | Click the Cubbit icon to open the tray. Each drive shows up as a card with its sync state, recent activity, and quick actions. | Clicca l'icona Cubbit per aprire il pannello. Ogni drive appare come una scheda con stato, attività recente e azioni rapide. |
| `tutorial.slide3.title` | Watch your transfers in real time | Monitora i trasferimenti in tempo reale |
| `tutorial.slide3.description` | Live upload and download speeds appear at the top of the tray, so you know exactly how fast your files are moving. | Le velocità di upload e download in tempo reale appaiono in cima al pannello, così sai esattamente quanto sono veloci i tuoi trasferimenti. |
| `tutorial.slide4.title` | Jump back to recent files instantly | Torna ai file recenti in un attimo |
| `tutorial.slide4.description` | The Recent Files panel shows everything you've just uploaded or downloaded — open one with a click. | Il pannello File recenti mostra tutto ciò che hai appena caricato o scaricato — aprilo con un clic. |
| `tutorial.slide5.title` | Quick actions for every drive | Azioni rapide per ogni drive |
| `tutorial.slide5.description` | Pause sync, reveal in Finder, open the web console, or remove a drive — all from the gear menu on each card. | Metti in pausa, mostra nel Finder, apri la console web o rimuovi un drive — tutto dal menu a forma di ingranaggio su ogni scheda. |
| `tutorial.slide6.title` | Set up new drives in seconds | Configura nuovi drive in pochi secondi |
| `tutorial.slide6.description` | Pick a project, choose a bucket, and decide which folder to sync — the wizard walks you through every step. | Scegli un progetto, seleziona un bucket e decidi quale cartella sincronizzare — la procedura guidata ti accompagna ad ogni passo. |
| `tutorial.slide7.title` | Sync up to three drives at once | Sincronizza fino a tre drive contemporaneamente |
| `tutorial.slide7.description` | Manage multiple buckets side by side. Add up to three drives to keep all your projects in sync. | Gestisci più bucket affiancati. Aggiungi fino a tre drive per tenere tutti i tuoi progetti sincronizzati. |

## Verification

### Acceptance grep matrix

| Criterion | File | Required | Actual |
|-----------|------|----------|--------|
| `Slide(\|TutorialSlide` | `TutorialViewModel.swift` | ≥1 | 8 |
| `tutorial-slide-1\|tutorial-slide-7` | `TutorialViewModel.swift` | ≥1 | 8 |
| `DS3Colors.brand\|DS3Gradients.brand` | `TutorialView.swift` | ≥1 | 7 |
| `tutorial.slide[1-7].title\|description` | `Localizable.xcstrings` | ≥1 | 14 |
| imagesets in `tutorial/` | filesystem | exactly 7 | 7 |

### Build

```
xcodebuild build -project DS3Drive.xcodeproj -scheme DS3Drive -destination 'platform=macOS'
** BUILD SUCCEEDED **
```

(Only the pre-existing AppIntents metadata note. No new analyzer warnings.)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Slide model could not synthesize Hashable**

- **Found during:** Task 1 first build attempt.
- **Issue:** Initial Slide model declared `Hashable` conformance, but `LocalizedStringKey` is not `Hashable`, so Swift refused to synthesize the conformance: `error: type 'Slide' does not conform to protocol 'Hashable'`.
- **Fix:** Dropped `Hashable` from the Slide declaration. `Identifiable` (via the stable `id: String`) is sufficient for `ForEach` and the page indicator's `\.self` semantics aren't used anywhere.
- **Files modified:** `DS3Drive/Views/Tutorial/Models/SlideModel.swift`
- **Commit:** rolled into `e050741` (Task 1).

**2. [Rule 3 - Blocker] Linter reformatted TutorialView.swift after commit**

- **Found during:** Task 1 commit hook.
- **Issue:** SwiftFormat collapsed a multiline `@AppStorage` declaration onto a single line.
- **Fix:** None needed — the linter change is intentional and was included in the same commit. Noted only for completeness.
- **Files modified:** `DS3Drive/Views/Tutorial/Views/TutorialView.swift`
- **Commit:** `e050741`

### Out of Scope Discoveries

- The pre-existing `Tutorial1.imageset` through `Tutorial4.imageset` under `Assets.xcassets/images/` are now orphaned (no Swift code references them). They are **kept in place** to avoid touching the asset catalog more than necessary; a future cleanup plan can delete them once the new tutorial is verified.

---

**Total deviations:** 2 (1 in-scope build fix, 1 lint cosmetic). Neither affects deliverables.

## Known Stubs

**Yes — placeholder screenshot assets.** All 7 imagesets ship with a 1024×640 brand-blue solid PNG instead of a real screenshot. They build green and the tutorial flow runs without missing-asset warnings, but they are placeholders awaiting the human-verify checkpoint.

| Stub | File | Reason |
|------|------|--------|
| `tutorial-slide-1.png` | `tutorial-slide-1.imageset/` | Awaiting Finder sync badge screenshot |
| `tutorial-slide-2.png` | `tutorial-slide-2.imageset/` | Awaiting menu bar tray screenshot |
| `tutorial-slide-3.png` | `tutorial-slide-3.imageset/` | Awaiting tray + speed summary screenshot |
| `tutorial-slide-4.png` | `tutorial-slide-4.imageset/` | Awaiting Recent Files panel screenshot |
| `tutorial-slide-5.png` | `tutorial-slide-5.imageset/` | Awaiting gear/quick actions menu screenshot |
| `tutorial-slide-6.png` | `tutorial-slide-6.imageset/` | Awaiting wizard tree view screenshot |
| `tutorial-slide-7.png` | `tutorial-slide-7.imageset/` | Awaiting multi-drive tray screenshot |

These stubs are **intentional and tracked** — capturing them is the entire purpose of the human-verify checkpoint (Task 3). The plan cannot be marked fully complete until they are replaced.

## Threat Flags

None — pure UI / asset change. No new endpoints, auth paths, file access patterns, or schema changes.

## Issues Encountered

- Slide model Hashable synthesis (deviation 1) — fixed inline.
- Screenshot capture cannot be automated from a headless agent — by design, deferred to human checkpoint.

## Self-Check: PASSED

**Verified files exist:**

- FOUND (modified): `DS3Drive/Views/Tutorial/Models/SlideModel.swift`
- FOUND (modified): `DS3Drive/Views/Tutorial/ViewModels/TutorialViewModel.swift`
- FOUND (modified): `DS3Drive/Views/Tutorial/Views/TutorialView.swift`
- FOUND (modified): `DS3Drive/Assets/Localizable.xcstrings`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-1.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-1.imageset/tutorial-slide-1.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-2.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-2.imageset/tutorial-slide-2.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-3.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-3.imageset/tutorial-slide-3.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-4.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-4.imageset/tutorial-slide-4.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-5.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-5.imageset/tutorial-slide-5.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-6.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-6.imageset/tutorial-slide-6.png`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-7.imageset/Contents.json`
- FOUND: `DS3Drive/Assets/Assets.xcassets/tutorial/tutorial-slide-7.imageset/tutorial-slide-7.png`

**Verified commits:**

- FOUND: `e050741` — Task 1: redesign tutorial with 7-slide brand layout
- FOUND: `5017101` — Task 2: add tutorial slide placeholder imagesets

---

*Phase: 05-ux-polish*
*Status: PARTIAL — code complete, awaiting human-verify checkpoint for fresh screenshots*
*Completed (code): 2026-04-07*
