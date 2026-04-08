---
phase: 05-ux-polish
plan: 08
status: superseded
superseded_by:
  - 05-09
  - 05-10
  - 05-11
  - 05-12
  - 05-13
  - 05-14
  - 05-15
  - 05-16
  - 05-17
  - 05-18a
  - 05-18b
  - 05-18c
  - 05-19
closes_requirements: [UX-01, UX-02, UX-03, UX-04, UX-05, UX-06, UX-07]
---

# Plan 05-08 — Superseded by Gap Closure Plans

This plan was the **final human verification** step for phase 05 — the
user walked the built app on both macOS and iOS and surfaced 32
discrete gaps in `05-08-GAPS.md`. Rather than attempt to close all of
those gaps inside 05-08 itself, each gap was routed to a dedicated
closure plan so the scope stayed reviewable.

## Gap closure map

Every gap 05-08 surfaced has been addressed by one of the downstream
plans. See `05-08-GAPS.md` for the per-gap detail and the individual
plan summaries for the implementation.

| Gap range | Closed by | What it covered |
|-----------|-----------|-----------------|
| Gaps 1, 14, 15, 16 | **05-09** | Auth recovery, tray status coherence (round 1) |
| Gaps 4, 7, 8, 9, 10, 11, 12, 13 | **05-10** | Tray + preferences tidy-up, IA fixes |
| Gap 2 | **05-11** → superseded by **05-17** | Brand identity foundation |
| Gap 6 (tray Figma layout) | **05-12** | Sync Share 2.0 card layout |
| Gaps 17, 5 | **05-13** | iOS target scaffolding, wizard empty state |
| Gap 3 | **05-14** → re-verified in **05-20** | Tutorial polish |
| Gaps 14, 15, 16, 25, 26, 27, 32 | **05-15** | Round 2 re-fixes + Swift 6 weakSelf data races |
| Gap 28 | **05-16** | S3 SlowDown throttling (missing folders in Finder) |
| Gap 31 | **05-17** | Re-extract brand tokens from composer-canary (CORRECT palette) |
| Gaps 18, 19, 20, 21, 22, 23, 24, 29, 30 | **05-18** → split into **05-18a**, **05-18b**, **05-18c** | Sweep every macOS surface with the correct brand tokens |
| Gap 17 (iOS parity) | **05-19** | iOS brand parity |
| Gap 3 follow-up + Gap 20 re-verify | **05-20** | Final tutorial screenshots (pending user capture) |

## Status

The gap closure plans above have all shipped. The only remaining
phase-05 work is:

1. **05-20** — capture fresh tutorial screenshots of the shipped UI.
   This is a human-in-the-loop task (needs someone to actually run the
   app, take screenshots of the built views, and drop them into the
   tutorial asset catalog). Not a code task.

2. **Post-ship QA follow-ups** that surfaced during this session:
   - Login window centering regression (`012d454`)
   - Login/MFA stale error banner (`cea5362`)
   - Finder sidebar label preference revert (`2ac6f57`)

   These landed as direct commits rather than new gap plans because
   the user was doing live QA and the fixes were small and localized.
   If the team prefers every user-observable fix to land via a gsd
   plan, a future session can backfill 05-21 to document them.

## Verification

Phase 05's seven UX requirements (UX-01 through UX-07) are satisfied
by the union of the gap closure plans listed above, not by 05-08
itself. The verification that 05-08 was meant to perform has been
distributed across the closure plans' own verification sections plus
the user's live manual QA during this phase.

## Why this plan is superseded rather than completed

05-08 was structured around "human verifies everything on a real
device." That verification happened — it just produced a backlog of
gaps instead of a pass/fail signal. The subsequent plans are the work
that verification implied. Writing a pro-forma `has_summary: true` on
05-08 without acknowledging the split would hide that history; writing
this supersession note preserves it.
