---
status: partial
phase: 17-windows-shell
source: [17-08-PLAN.md Task 4]
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

## Summary

total: 9
passed: 0
issues: 0
pending: 9
skipped: 0
blocked: 0

## Gaps
