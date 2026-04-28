## Plan 13-10 — out-of-scope test failures

Encountered during full DS3DriveProviderTests run after Plan 13-10:

- `S3ItemTests.testDecorationCloudOnlyDefault` — expects a `cloudOnly`
  decoration on an unmaterialized item, observed `nil`.
- `S3ItemTests.testDecorationSynced` — expects a `synced` decoration on a
  synced item, observed `nil`.

Both pre-exist on the Plan 13-10 baseline (verified by stashing the plan's
changes and re-running — failures persist). Unrelated to thumbnail rollout
(decoration identifier wiring on `S3Item`). Out of scope per executor scope
rules.

## Plan 13-11 — confirmed still failing (2026-04-26)

Re-ran full `xcodebuild test -scheme DS3Drive -destination 'platform=macOS'`
during Plan 13-11 Task 2 build sanity. The same two `S3ItemTests` failures
above persist verbatim — verified by stashing Plan 13-11's `ThumbnailUploader`
retrofit and re-running the two failing tests in isolation (still red on the
clean Plan 13-10 baseline). Unrelated to integration smoke or
`S3Lib+Thumbnails.swift` audit. Carry-forward to a follow-up fix outside
Phase 13 — likely a `S3Item.decorations` regression introduced by the
decoration identifier work in Plan 13-06 (commit fc875ce). Filed as a Phase
13 carry-forward, NOT a Plan 13-11 regression.

## Plan 13-10 — wizard/rollout conflict-check asymmetry (2026-04-26 — Phase 14 follow-up)

Surfaced during human-verify (Plan 13-11 Task 3) on a real bucket
(`personal-moschet`) that already contained an unrelated `.thumbnails/`
folder at the drive root with non-DS3Drive content
(`not-a-real.png`, `random.txt`, `nested/`).

**Observed:**

1. Drive creation in the macOS wizard completed with NO conflict warning.
2. Extension launch ran the rollout's `inspectThumbnailPrefix` check and
   correctly returned `.conflicting`, so it persisted
   `thumbnailSettings.json` as `{driveId: {enabled: false}}`.
3. Finder showed only generic file icons for cloud-only image files —
   `fetchThumbnails` early-exits with `.notAuthenticated` because the
   drive is `enabled: false`.
4. User has no UX recourse other than manually editing
   `thumbnailSettings.json` (Phase 13 D-05 — kill-switch via JSON only).

**Root cause:** wizard and rollout use different conflict-check semantics.

| Path | Function | Timeout | Error / timeout fallback |
|------|----------|---------|--------------------------|
| Wizard (Phase 11) | `inspectThumbnailPrefixWithTimeout` | 10s | Fail-open → `.empty` (silent, no log on timeout path) |
| Rollout (Phase 13 D-02) | `inspectThumbnailPrefix` | none | Throws on error; returns `.conflicting` on real conflict |

This means a wizard timeout can silently mask a real `.conflicting` state
(no warning shown, no log entry on the timeout branch), and the user only
discovers the problem indirectly when thumbnails never appear.

**Phase 14 follow-up scope:**

1. **Consistency:** wizard and rollout should use the same check semantics.
   Recommendation: both call `inspectThumbnailPrefixWithTimeout` (so a
   network blip doesn't block drive creation), and both treat
   timeout/error as `.indeterminate` rather than `.empty` — meaning the
   rollout retries on the next launch instead of persisting
   `enabled: false` based on a transient signal.
2. **Logging:** add an explicit log entry on the timeout branch of
   `inspectThumbnailPrefixWithTimeout` so debug shows whether the call
   raced past the deadline. Currently only the catch-all error branch
   logs.
3. **"Use anyway" override at the rollout site.** Phase 11 D-08 already
   ships this CTA in the wizard. Phase 13 D-05 deliberately omitted UI
   for the silent-rollout posture. The runtime UX gap means users with
   pre-existing unrelated `.thumbnails/` content (a real-world scenario,
   as just demonstrated) are silently locked out of thumbnails. Phase 14
   should add a one-time prompt — e.g., a tray menu entry "Diagnose
   thumbnails" that re-runs `inspectThumbnailPrefix` on demand, surfaces
   the conflicting sample key, and offers a "Use anyway" override that
   persists `enabled: true` in `thumbnailSettings.json` regardless of
   the inspection verdict.
4. **Documentation:** explicitly note in user-facing docs that drives
   created against buckets containing non-DS3Drive `.thumbnails/`
   content will silently disable thumbnails, and the kill-switch override
   is JSON edit. This shouldn't be surprising on the v3.1 ship since
   the silent-rollout decision was deliberate, but the absence of any
   surface UI should be called out.

**NOT a Phase 13 regression:** Phase 13 honors the discuss-phase decisions
(D-01, D-03, D-05) word-for-word. The UX gap was implicitly accepted
during /gsd-discuss-phase when the user explicitly chose "Completely
silent" first-run UX over any of the three "show something" options.
This entry exists so Phase 14 can re-evaluate that choice with the
benefit of having seen the failure mode in production.

**Workaround for Phase 13 v3.1:** Either (a) delete the conflicting
`.thumbnails/` folder from the bucket and remove
`thumbnailSettings.json` so the rollout re-fires on next launch, or
(b) edit `thumbnailSettings.json` to set
`{driveId: {enabled: true}}` and restart the extension.
