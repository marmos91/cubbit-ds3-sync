---
status: partial
phase: 17-windows-shell
source: [17-08-PLAN.md Task 4, 17-09-PLAN.md Task 3, 17-10-PLAN.md Task 5]
started: 2026-05-29
updated: 2026-05-29
---

## Current Test

[awaiting human testing — requires local x64 ds3_ffi.dll + Windows App SDK runtime + a 2FA-enabled test account; ideally run alongside the 17-11 tray-app smoke]

## Tests

### 1. App launches with Mica backdrop (17-08)
expected: `dotnet run --project DS3Drive.App` (built WITH the Rust DLL) opens a window with a visible Mica blur texture (not a solid color).
result: [pending]

### 2. Login typography + brand tokens (17-08)
expected: Headline "DS3 Drive" Figtree SemiBold 32px; subhead "Sign in to your account" SemiBold 24px; no 18px or Medium-weight text; spacing on the 4/8/16/24/32/48 grid (no 12px gaps).
result: [pending]

### 3. Primary button accent + hover (17-08)
expected: accent `#005CE8` background; hover lifts to `#337CEC`.
result: [pending]

### 4. Invalid-credentials error (17-08)
expected: Sign in with bad credentials → InfoBar Severity=Error "Sign-in failed. Check your email and password, then try again."
result: [pending]

### 5. 2FA routing parity (17-08, D-15)
expected: Valid credentials on a 2FA-enabled account → navigates to TwoFactorPage WITHOUT an inline error on Login.
result: [pending]

### 6. 2FA → Tutorial (17-08)
expected: Entering the 2FA code navigates to TutorialPage.
result: [pending]

### 7. Tutorial + Open-at-login (17-08)
expected: Tutorial walks slides; "Start DS3 Drive at login" toggle exists; "Get started" finishes.
result: [pending]

### 8. Single-instance guard (17-08, D-27)
expected: Relaunching the app does NOT open a second window.
result: [pending]

### 9. Open-at-login registry write (17-08, D-26)
expected: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` has a "Cubbit DS3 Drive" entry iff the toggle was ON.
result: [pending]

### 10. Drives list empty state (17-09)
expected: After sign-in + tutorial, DrivesListPage shows the "No drives yet" empty state with the "Add your first drive" CTA.
result: [pending]

### 11. Wizard opens to Project step (17-09)
expected: Click "Add your first drive" → wizard opens to ProjectSelectionPage; projects load (ProgressRing "Loading projects…" → list).
result: [pending]

### 12. Project → Bucket + step indicator (17-09, D-09)
expected: Click a project → navigates to BucketSelectionPage; WizardStepIndicator shows step 2 of 4 with the BrandPrimary accent on the active circle.
result: [pending]

### 13. Bucket → Prefix tree + "Use root" (17-09)
expected: Click a bucket → PrefixSelectionPage; the "Use root" option works and a tree of object prefixes lazy-loads from S3.
result: [pending]

### 14. Confirm summary card (17-09)
expected: Continue with root selected → DriveConfirmPage shows summary (Project / Bucket / Folder=Root / Drive name defaulting to bucket name).
result: [pending]

### 15. Create drive end-to-end (17-09, PATTERNS §3.3)
expected: Edit the drive name, click "Create drive" → "Setting up your drive…" ProgressRing, then navigation back to DrivesListPage with the new drive visible.
result: [pending]

### 16. API key in Cubbit console (17-09, D-10)
expected: The Cubbit web console shows an API key named `ds3drive({username}_{project}_{installation_id})` (deterministic name pattern, matches macOS).
result: [pending]

### 17. 3-drive cap hides Add (17-09, D-23)
expected: Add two more drives; on the third success the "Add drive" button is hidden/disabled.
result: [pending]

### 18. Back preserves picker state (17-09, UI-SPEC Open Q #4)
expected: From the wizard's Bucket step click Back → lands on the Project step with the previous project still selected/highlighted.
result: [pending]

### 19. SQLite rows (17-09)
expected: `%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db` → `SELECT * FROM drives;` returns 3 rows and `SELECT * FROM api_keys;` returns 3 rows.
result: [pending]

### 20. Sync root in Explorer sidebar (17-10, WIN-03)
expected: On a Win11 ARM64 VM with the Plan 04 sparse package registered + a dev sideload, sign in and create a drive pointing at a bucket with ≥10 objects (incl. one ≥100MB file). Open Explorer → "Cubbit DS3 Drive — <drive name>" appears under "This PC" / in the sidebar with the Cubbit icon.
result: [pending]

### 21. Hydration progress on a ≥100MB file (17-10, WIN-08)
expected: Right-click a ≥100MB cloud-only file → Open. Explorer's status column shows a visible progress percentage during hydration; the file opens after hydration completes.
result: [pending]

### 22. Hydration streaming never stalls > 30s (17-10, WIN-04, Pitfall 2)
expected: Repeat for a 1GB file (if available). Hydration never has a >30s "no progress" stretch. Event Viewer (`Cubbit-DS3Drive-Core`) shows chunks logged every few seconds (CfReportProviderProgress resets the watchdog).
result: [pending]

### 23. Upload on save (17-10, WIN-05)
expected: Create a new file in the sync folder → save. Exactly ONE upload event in Event Viewer; the file appears in the Cubbit web console under the expected key.
result: [pending]

### 24. No spurious upload after hydration (17-10, WIN-05, Pitfall 3 CRITICAL)
expected: Take a cloud-only file → double-click to hydrate → close WITHOUT editing. Tail the log → ZERO upload PUT requests. A PUT here means the IsDirty guard failed → REJECT.
result: [pending]

### 25. Remote-change detection within one poll cycle (17-10, WIN-06)
expected: From the Cubbit web console, upload a new object to the bucket. Within ≤60s (D-18 polling cadence) the placeholder appears in Explorer.
result: [pending]

### 26. Rename round-trips to S3 (17-10)
expected: Rename a file in Explorer → Cubbit console shows the old key deleted + the new key created (S3 has no rename: CopyObject + DeleteObject).
result: [pending]

### 27. Delete round-trips to S3 (17-10)
expected: Delete a file in Explorer → the object disappears from Cubbit.
result: [pending]

### 28. No shell icon-overlay handler (17-10, Pitfall 4)
expected: `grep -ri "IShellIconOverlayIdentifier" windows/` returns only doc-comment references (the ban note), never an implemented `IShellIconOverlayIdentifier` COM class. State icons come from cfapi placeholder pin/in-sync states, not an overlay handler.
result: [pending]

### 29. No ReadDirectoryChangesW upload trigger (17-10, Pitfall 3)
expected: `grep -ri "ReadDirectoryChangesW" windows/` returns only the doc-comment ban note, never a live call. The only upload trigger is NOTIFY_FILE_CLOSE_COMPLETION.
result: [pending]

### 30. Parent folder status not stuck (17-10, PATTERNS §2.8, f8917ee regression)
expected: Open the parent folder of an active sync operation. The parent folder's sync status badge updates correctly and does NOT stay stuck in "syncing" after the child file completes (regression check on the NotificationManager counter/debounce logic).
result: [pending]

### 31. NTFS guard + sparse-identity guard (17-10, Pitfalls 1 & 8)
expected: Point a drive at a non-NTFS volume (e.g. a FAT32/exFAT USB) → registration fails with a clear "NTFS required" error, not a crash. Without the sparse package registered, registration surfaces the E_NOT_VALID_STATE / "not supported" guidance rather than silently failing.
result: [pending]

## Summary

total: 31
passed: 0
issues: 0
pending: 31
skipped: 0
blocked: 0

## Gaps
