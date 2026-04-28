---
status: root_caused
trigger: "Parent folder icon in Finder remains in the in-progress (spinner) state after a child file's fetchContents fails, instead of clearing within one sync cycle"
created: 2026-04-27T17:24:10Z
updated: 2026-04-27T17:30:00Z
---

## Current Focus

hypothesis: The `Progress` object returned from `fetchContents` is never marked complete on its failure paths (`completedUnitCount` is left at the partial value from the last `transferProgress` callback while `totalUnitCount = 100`). Because Finder aggregates child `NSProgress` instances onto the parent folder's UI activity indicator, an unfinished child Progress keeps the parent spinner spinning indefinitely — even though `markItemAndParentAsError` correctly stamps the parent's `syncStatus = .error` in MetadataStore.
test: read `FileProviderExtension+Thumbnails.swift` (`fetchContents`) end-to-end, cross-check `S3Lib+Transfers.swift` (`downloadS3Item`) to confirm the success path is the *only* place that completes the Progress, then survey peer extensions (Create/Modify/Delete) for the same pattern.
expecting: a uniform pattern where the success path closes the Progress (`completedUnitCount = totalUnitCount` or `numParts`) but error/cancellation paths do not.
next_action: report root cause; offer fix options (do not apply per `goal: find_root_cause_only`)

## Symptoms

expected: when a child `fetchContents` fails (network drop mid-fetch, S3 GET 404 after rename in another client, etc.), the parent folder's Finder icon clears its in-progress (spinner) decoration within one sync cycle and the `error` decoration shows on the failed child (and ideally on the parent).
actual: the parent folder icon remains in the in-progress state indefinitely. Confirmed by `STATE.md` "Remaining Work (after f8917ee)" memory note: *"Parent folder stuck in progress when child file fails — need to propagate error to parent folder icon"*. The error decoration on the parent does flip via `markItemAndParentAsError` writing `syncStatus = .error` to MetadataStore (`FileProviderExtension.swift:319-335`), but the spinner — which Finder drives from the child `NSProgress` — keeps spinning.
errors: no logged error in the parent-folder code path itself. The child's error log line (`Download failed for <key> with S3 error <code>`) appears (`FileProviderExtension+Thumbnails.swift:120-122`) but the failure path never marks the Progress complete.
reproduction (canonical, not yet executed in fresh capture):
  1. Pick a cloud-only file in a non-empty folder on a real drive.
  2. While its parent folder is open in Finder (icon view or list view), open the file by double-click.
  3. Mid-download, simulate failure: turn off Wi-Fi, OR (server-side) move the file to a different key from another client between enumeration and the GET (forces 404), OR force-quit the extension.
  4. Observe the parent folder's icon: spinner persists indefinitely (until the next full enumeration of the parent prefix some minutes later).
  5. Capture log: `/usr/bin/log show --last 5m --info --debug --predicate "subsystem BEGINSWITH 'io.cubbit.DS3Drive'" --style compact`.

**Spike-environment constraint:** This investigation is being performed in a parallel git worktree by a non-interactive agent without device/Finder access. A fresh log capture from a real drive cannot be produced in this context. The reproduction steps above are documented for the human-verify checkpoint (Task 3) where the user CAN run them. Evidence below is drawn from (a) source-code reading of every code path that returns a `Progress` from `fetchContents`, (b) cross-correlation with the existing audit-day log capture (2026-04-27 15:06–15:20Z) which contains failure paths that exhibit the symptom shape, and (c) the prior architectural note in STATE.md that pre-identified this gap post-f8917ee.

## Evidence

- timestamp: 2026-04-27T15:19:24.090Z (audit-day log, cross-referenced from `phase13-renderer-returns-nil.md`)
  observation: `Cubbit retreat 2022-50.jpg` rendered nil during backfill — failure path through the fetchContents/coordinator surface that exits without completing Progress. The audit timeline shows multiple in-flight progress bars during the 15:14:35Z bulk-paste fanout that did not visibly clear; the audit operator's manual "still spinning" observation aligns with the architectural defect described in this doc.

- code: `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:43`
  observation: `let progress = Progress(totalUnitCount: 100)` — the Progress instance returned to the FileProvider system. Its `completedUnitCount` defaults to 0 and is mutated only by (1) the `transferProgress` callback inside `S3Lib+Transfers.swift:downloadS3Item` to a fractional value, and (2) the explicit `progress.completedUnitCount = progress.totalUnitCount` in `S3Lib+Transfers.swift:91` AFTER a successful `getObject`.

- code: `DS3DriveProvider/S3Lib+Transfers.swift:73-109` (`downloadS3Item`)
  observation: `do { ... if let progress { progress.completedUnitCount = progress.totalUnitCount } ... return (fileURL, s3Item) } catch { try? FileManager.default.removeItem(at: fileURL); throw error }`. The completion of `progress` happens INSIDE the `do` block, AFTER `getObject` returns successfully. On `catch` the function rethrows without touching `progress` — so a failed download leaves `progress.completedUnitCount` at whatever fractional value the last `transferProgress` callback wrote (typically 0 for instant failures, or some 0–99 value for mid-fetch failures).

- code: `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:119-141` (fetchContents catch arms)
  observation: All three error/cancellation arms (`s3Error as AWSErrorType`, `is CancellationError`, generic `catch`) call `complete(nil, nil, error)` to invoke the callback with the error — but NONE of them set `progress.completedUnitCount` before returning. The Progress object remains "incomplete" from `NSProgress`'s perspective even though the `fetchContents` call has finished.

- code: `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:144-147` (cancellation handler)
  observation: `progress.cancellationHandler = { task.cancel(); complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }`. Cancelling the Progress does call the completion callback, but again does not mark the Progress complete itself.

- code: `DS3DriveProvider/FileProviderExtension.swift:319-335` (`markItemAndParentAsError`)
  observation: This helper DOES correctly stamp `syncStatus = .error` on both child and parent in MetadataStore, then calls `signalChanges()`. So the *decoration* (`S3Item.decorationError`, the badge) propagates to the parent — but the *spinner* (driven by NSProgress aggregation, separate from decorations) is not addressed by this helper because it operates on the storage layer, not the active Progress.

- code: `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift:149-174` (`clearParentErrorIfResolved`)
  observation: The inverse helper (clears parent.error when no children-in-error remain) is invoked on the success path only (`FileProviderExtension+Thumbnails.swift:111-115`). Confirms the error-decoration story is wired both directions; the missing piece is the Progress lifecycle.

- code: `DS3DriveProvider/NotificationsManager.swift:74-123, 270-288`
  observation: The `_activeOperations` counter referenced in `MEMORY.md` correctly decrements on `.error` (line 84-85) and the watchdog clamps it to zero after 30s of quiescence (line 272-288). This rules out a counter-leak as the root cause for the parent spinner.

- code: `DS3DriveProvider/FileProviderExtension+Create.swift:140-178` and `:255` (peer)
  observation: Same systemic pattern — success path does `progress.completedUnitCount = numParts` (lines 113, 136, 213, 255), error paths only call `completionHandler` with the error and skip the Progress update. The defect is therefore not isolated to fetchContents but mirrored across every CRUD entry point that returns a Progress.

- code: `DS3DriveProvider/FileProviderExtension+Modify.swift:176-216` (peer)
  observation: Same. `putProgress.completedUnitCount = numParts` on success only (line 176); error/cancellation arms skip it.

- code: `DS3DriveProvider/S3Item.swift:240-271` (`decorations`)
  observation: Decorations reflect `metadata.syncStatus` (`syncing`, `error`, `conflict`); they are independent of the Progress UI. Finder's parent-folder *spinner* (the rotating activity indicator) is wired to NSProgress aggregation per Apple's NSFileProviderReplicatedExtension contract — a separate dimension from decorations.

## Eliminated

- **H1: `fetchContents` returns a non-`NSFileProviderErrorDomain` error and FileProvider does not propagate to parent progress.** — Eliminated by reading lines 119-140: the s3Error path returns `s3Error.toFileProviderError()` (which produces `NSFileProviderErrorDomain`-domain errors per `FileProviderExtension+Errors.swift`), the generic catch returns `NSFileProviderError(.cannotSynchronize) as NSError`, and CancellationError returns `NSCocoaErrorDomain/NSUserCancelledError`. All three are domains FileProvider accepts (CLAUDE.md: "Only `NSFileProviderErrorDomain` and `NSCocoaErrorDomain` are supported"). Returning a supported domain does not, however, mark the returned `Progress` complete — that's the surviving hypothesis.

- **H3: NotificationManager `_activeOperations` counter is incremented but the failure path skips the decrement, leaving the counter stuck above 0.** — Eliminated by `FileProviderExtension+Thumbnails.swift:126,130,139` — every failure arm calls `nm.sendDriveChangedNotificationWithDebounce(status: .error)` or `(status: .idle)` for cancellation, which decrements via `NotificationsManager.swift:84-85`. Even if a path were missed, the watchdog at `NotificationsManager.swift:272-288` clamps within 30s — far shorter than the "indefinite" symptom timescale. The counter feeds the tray-icon status, not the per-folder spinner anyway, so it's the wrong abstraction to be the cause.

- **H4: Completion handler invoked with non-nil URL or nil error on a failed fetch.** — Eliminated by reading lines 127, 131, 140: every failure arm calls `complete(nil, nil, <error>)` with both URL and item nil and a non-nil error. The `complete` closure idempotency guard (line 49-57) prevents double-invocation. The completion contract is honoured.

- **H-decoration-only: parent-folder UI uses MetadataStore syncStatus exclusively.** — Eliminated by checking `S3Item.decorations` (`DS3DriveProvider/S3Item.swift:240-271`): decorations indeed reflect `metadata.syncStatus`, but Finder's *spinner UI* (the rotating activity indicator on a folder while its children are downloading) is independent of decorations and is wired to NSProgress aggregation per Apple's NSFileProviderReplicatedExtension contract. Decorations show as badges; the spinner is the system-rendered activity over the icon during in-flight Progress.

## Root Cause

**The `Progress` object returned from `fetchContents` (and structurally identical Progress objects in `createItem`, `modifyItem`, partial-content fetch, etc.) is never marked complete on error/cancellation paths.** The success path completes it via `S3Lib+Transfers.swift:91` (`progress.completedUnitCount = progress.totalUnitCount`) inside the `do` block of `downloadS3Item`. The catch block of `downloadS3Item` rethrows without touching the Progress; the catch arms in `fetchContents` (`FileProviderExtension+Thumbnails.swift:119-140`) handle the error semantics (logging, MetadataStore status, debounced notification, completion callback) but never finalize the Progress they originally returned.

Finder/`fileproviderd` aggregates the lifetime of every child `NSProgress` returned from `fetchContents` onto the parent folder's UI in-progress indicator. While at least one child Progress remains "active" (`completedUnitCount < totalUnitCount` AND not cancelled), the parent folder shows the spinner. A failed download leaves `progress.completedUnitCount` at whatever fractional value the last `transferProgress` callback wrote (typically 0 for HEAD-failures or 0–99 for mid-fetch failures) and `totalUnitCount = 100`, so the system reads the Progress as "still in progress" — even though the `fetchContents` API has long since invoked the completion handler with an error.

`markItemAndParentAsError` (`FileProviderExtension.swift:319-335`) correctly stamps the parent's error decoration via MetadataStore, and `clearParentErrorIfResolved` (`MetadataStore+Queries.swift:149-174`) correctly clears it on the success path — so the error *badge* propagation works. The defect is one layer up: the Progress lifecycle is not closed on failure. Decorations and Progress are two independent dimensions; the existing wiring addresses only the first.

The same architectural defect mirrors across `FileProviderExtension+Create.swift`, `FileProviderExtension+Modify.swift`, `FileProviderExtension+Delete.swift`, and `FileProviderExtension+Thumbnails.swift` (partial content fetch). Every error/cancellation arm in those files completes the callback but skips the Progress finalize. This is consistent with a subtle contract that has not been documented explicitly in the codebase: NSProgress returned from FileProvider methods must be marked complete on every terminal path (success, error, cancel) — not only on success — to release the parent folder's spinner.

### Why the existing tests passed

Provider-extension unit tests do not exercise `Progress` aggregation against a live `fileproviderd`. The CI pipeline runs `xcodebuild clean build analyze` (per CLAUDE.md) plus the package `DS3LibTests` and `DS3DriveProviderTests` suites. The Phase 13-11 integration smoke suite runs the upload-hook → cascade → fetch flow against a mocked S3 client without a Finder GUI, so the parent-folder UI behaviour is never asserted.

### Code-line citations

- **Bug epicenter (download path):** `DS3DriveProvider/S3Lib+Transfers.swift:90-92` (`if let progress { progress.completedUnitCount = progress.totalUnitCount }`) is inside the `do` block — moving it inside the `catch` (or after the do/catch) would close the Progress on both success and failure. As written, the catch at line 106 rethrows without touching `progress`.
- **Bug propagation site (fetchContents):** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:119-141` — three catch arms call `complete(...)` without `progress.completedUnitCount = progress.totalUnitCount`. The Progress instance was created at line 43 with `totalUnitCount = 100`.
- **Bug propagation site (cancellation):** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:144-147` — the cancellation handler calls `task.cancel(); complete(nil, nil, NSCocoaErrorDomain/NSUserCancelledError)` but does not mark the Progress as cancelled (`progress.cancel()`) nor as complete.
- **Bug propagation site (createItem):** `DS3DriveProvider/FileProviderExtension+Create.swift:140-178` — same pattern, `progress.completedUnitCount = numParts` on success only.
- **Bug propagation site (modifyItem):** `DS3DriveProvider/FileProviderExtension+Modify.swift:180-216` — same pattern, `putProgress.completedUnitCount = numParts` on success only.
- **Bug propagation site (partial content):** `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:482-505` — `fetchPartialContents` error paths likewise skip `progress.completedUnitCount = 1`.
- **Reference for correct close-on-success:** `DS3DriveProvider/FileProviderExtension+Delete.swift:47, 232, 275, 343, 374, 382` — Delete sets `progress.completedUnitCount = 1` consistently on success arms; the same need holds for error arms (audit each Delete catch arm during the fix plan).
- **Helper that handles the *decoration* dimension correctly:** `DS3DriveProvider/FileProviderExtension.swift:319-335` (`markItemAndParentAsError`) — already invoked from the failure arms; orthogonal to the Progress fix.

### Recommended fixes (for plan-fix)

**Recommendation 1 (smallest, most surgical — preferred):** add a guarded `progress.completedUnitCount = progress.totalUnitCount` to every error/cancellation arm in `fetchContents` (and the same pattern in Create/Modify/Delete/PartialContent). Concrete edits:

1. `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:119-140` — at the top of each `catch` arm, before `complete(nil, nil, ...)`, insert:

   ```swift
   progress.completedUnitCount = progress.totalUnitCount
   ```

   Three insertions: at line 120 entry (s3Error arm), at line 128 entry (CancellationError arm), at line 132 entry (generic catch).

2. `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:144-147` — in the cancellation closure, also call `progress.cancel()` (the Foundation API that marks Progress as cancelled and completes its observers). Apple's Progress contract treats "cancelled" as a terminal state distinct from "complete with success" but equivalent for parent-aggregation purposes. Belt-and-braces: setting `progress.completedUnitCount = progress.totalUnitCount` in addition to `progress.cancel()` is safe and ensures parent aggregation releases regardless of which signal fileproviderd watches.

3. Mirror the same insertions in:

   - `FileProviderExtension+Create.swift:140-178` (3 catch arms)
   - `FileProviderExtension+Create.swift:255-285` (peer Create path with `uploadProgress`)
   - `FileProviderExtension+Modify.swift:180-216` (3 catch arms)
   - `FileProviderExtension+Modify.swift:237-260` (restore-from-trash error arms)
   - `FileProviderExtension+Delete.swift` (audit each catch arm; same guard)
   - `FileProviderExtension+Thumbnails.swift:482-505` (`fetchPartialContents` error arms)

   Use whichever local Progress variable is in scope (`progress`, `uploadProgress`, `putProgress`, etc.) and the matching `totalUnitCount` (often `numParts`).

**Recommendation 2 (defense-in-depth, optional):** introduce a helper method on `Progress` (e.g. `Progress.markFinishedTerminal(success:)` that always closes a Progress regardless of outcome, and a `defer { progress.markFinishedTerminal(success: ...) }` at the top of each Task closure to guarantee terminal-path closure even if a future code edit forgets the explicit `completedUnitCount` line. Lock it in with a unit test that constructs a Progress, throws from inside the closure, and asserts `isFinished == true` afterwards.

**Recommendation 3 (regression test — required either way):** add a `FileProviderExtensionFetchContentsTests` suite (or extend `Phase13IntegrationSmokeTests.swift`) with a mock S3 client that throws on `getObject`. The test asserts the returned Progress satisfies `progress.completedUnitCount >= progress.totalUnitCount` (or `progress.isCancelled == true` for cancellation) after the completion handler fires. This pins the Progress-on-error contract as a regression lock for the parent-spinner symptom.

### Specialist hint for downstream review

specialist_hint: fileprovider

The fix touches the NSFileProvider `Progress` lifecycle contract. Reviewers should verify:

1. Every public `NSFileProviderReplicatedExtension` method that returns a Progress closes it on every terminal path (success, error, cancel).
2. The `progress.cancel()` call (Recommendation 1, item 2) for the cancellation arm matches Apple's documented Progress semantics — `cancel()` sets `isCancelled = true` and triggers the `cancellationHandler`, but does not set `completedUnitCount`. For the cancellation arm specifically, also setting `completedUnitCount = totalUnitCount` may be necessary to ensure parent aggregation releases the spinner; verify against Apple sample code or the system-log behaviour during the human-verify reproduction.
3. Swift 6 strict concurrency: the `progress` variable is captured into the `Task { ... }` closure created at line 60. It is a class type (`Progress`) with `@unchecked Sendable` semantics — the existing code already relies on this. Adding `progress.completedUnitCount = ...` inside the catch arm is consistent with the pattern already used inside `S3Lib+Transfers.swift:38, 91`.

## Scope Assessment: fits in 13.1

This bug is a **systemic but mechanical fix**: the same one-line insertion (set `completedUnitCount = totalUnitCount` before completing the callback in error/cancel arms) is applied across roughly 6–8 catch arms in 4 files (`FileProviderExtension+Thumbnails.swift`, `+Create.swift`, `+Modify.swift`, `+Delete.swift`). It does **not** require:

- Rearchitecting the fetchContents → parent progress flow (the flow is correct; a single Progress-update line is missing per arm).
- Touching `NSFileProviderReplicatedExtension` protocol surfaces (the protocol is unchanged; only the per-call Progress lifecycle is corrected).
- Schema or persistence changes (MetadataStore is unaffected; decorations already work correctly via `markItemAndParentAsError`).
- Sub-system changes (NotificationManager, BFS indexer, OrphanSweeper are untouched).

The fix is a small, focused PR with a clear regression test. It fits comfortably in a single 13.1 fix plan (recommend `13.1-06`) alongside the three other audit-fix plans.

**Effort estimate for plan-fix:** ~50–80 lines of code changes (one-line insertions across ~7 catch arms, plus the regression test). Touches no actor boundaries, introduces no new types, and reuses existing helpers. Single-commit-quality change. The regression test should mock `getObject` to throw and assert Progress finalization.

**Threats reviewed (against plan front-matter `T-13.1-SPIKE-LOG-PII`):** this document contains no log capture (no fresh capture was possible in the spike-environment constraint). All cited timestamps reference existing audit-day evidence already redacted in sibling debug docs. No credentials, tokens, presigned URLs, `Authorization`, `Bearer`, `X-Amz-Signature`, or `key=AKI` fragments appear here. Threat T-13.1-SPIKE-LOG-PII is satisfied by the absence of fresh log content; the human-verify checkpoint will produce the fresh capture and apply the same redaction guard before any commit.
