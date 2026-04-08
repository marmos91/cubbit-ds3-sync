---
phase: 05-ux-polish
plan: 18b
type: execute
wave: 3
gap_closure: true
depends_on: [05-17, 05-18a]
parent_plan: 05-18
files_modified:
  - DS3Drive/Views/Tray/Views/TrayMenuView.swift
  - DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift
  - DS3Drive/Views/Tray/Views/TrayDriveRowView.swift
  - DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift
  - DS3Drive/Views/Preferences/Views/PreferencesView.swift
  - DS3Drive/DS3DriveApp.swift
autonomous: false
requirements: [UX-01]

must_haves:
  truths:
    - "MenuBarExtra remains .window style (already shipped in 05-17 — verify, do not regress)"
    - "Empty-drives state: when ds3DriveManager.drives.isEmpty AND signed in, the tray shows EmptyDrivesHint, NOT 'All drives up to date'"
    - "Tray syncing icons (footer + aggregate header) use rotationEffect, not .symbolEffect(.pulse)"
    - "Preferences scene root has DS3Colors.brandBackground as backdrop"
    - "Each Preferences tab body wraps content groups with .brandCard()"
---

<objective>
Closes Gaps 18, 23, 24, 30. Second split from 05-18.

NOTE: TrayMenuItem already has a brand hover chip (Plan 05-12) and MenuBarExtra is already .window style (Plan 05-17). The remaining work is much smaller than the parent plan implied — focus on the empty-drives gap, the rotation animation gap, and the preferences background gap.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
</execution_context>

<context>
@.planning/phases/05-ux-polish/05-08-GAPS.md
@.planning/phases/05-ux-polish/05-18-PLAN.md
@DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
@DS3Drive/Views/Common/DesignSystem/DS3CardStyle.swift
</context>

<tasks>

<task type="auto">
  <name>Task 1: Tray empty-drives + rotation animation (Gaps 18, 23, 30)</name>
  <files>
    DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift,
    DS3Drive/Views/Tray/Views/TrayMenuView.swift,
    DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift
  </files>
  <action>
    Step 1 — Create `DS3Drive/Views/Tray/Views/EmptyDrivesHint.swift`:
    ```swift
    import SwiftUI

    struct EmptyDrivesHint: View {
        var body: some View {
            VStack(spacing: DS3Spacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(DS3Colors.brandTextSecondary)
                Text("No drives yet")
                    .font(DS3Typography.bodyMedium)
                    .foregroundStyle(DS3Colors.brandTextPrimary)
                Text("Click 'Add a new Drive' below to get started")
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, DS3Spacing.lg)
            .frame(maxWidth: .infinity)
        }
    }
    ```
    Add to project.pbxproj under DS3Drive/Views/Tray/Views group.

    Step 2 — TrayMenuView `loggedInMenu`: at the top of the VStack, before SpeedSummaryView, add:
    ```swift
    if ds3DriveManager.drives.isEmpty {
        EmptyDrivesHint()
        brandDivider
    }
    ```
    This guards the empty state — the existing aggregateStatusRow already only shows when `drives.count >= 2`, so the "All drives up to date" copy never fires for the empty case (verify this).

    Step 3 — Replace `.symbolEffect(.pulse, ...)` patterns with rotation in:
    - TrayMenuView.swift line 245 (aggregateStatusRow icon)
    - TrayMenuFooterView.swift line ~19 (footer icon)
    Pattern:
    ```swift
    @State private var isRotating = false
    // ...
    Image(systemName: descriptor.systemImage)
        .foregroundStyle(descriptor.color)
        .rotationEffect(.degrees(descriptor.animated && isRotating ? 360 : 0))
        .animation(
            descriptor.animated
                ? .linear(duration: 1.5).repeatForever(autoreverses: false)
                : .default,
            value: isRotating
        )
        .onAppear { if descriptor.animated { isRotating = true } }
    ```
    For TrayMenuView the `aggregateStatusRow` is a computed property — extract to a small subview (`AggregateStatusRowIcon`) that owns the `@State`.
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - grep "symbolEffect.*pulse" in DS3Drive/Views/Tray/ returns zero
    - EmptyDrivesHint.swift exists and is referenced from TrayMenuView
  </done>
</task>

<task type="auto">
  <name>Task 2: Preferences brand background (Gap 24)</name>
  <files>
    DS3Drive/Views/Preferences/Views/PreferencesView.swift,
    DS3Drive/DS3DriveApp.swift
  </files>
  <action>
    Read PreferencesView.swift first.
    - Apply `.background(DS3Colors.brandBackground.ignoresSafeArea())` to the TabView root
    - Add `.scrollContentBackground(.hidden)` to any Form/List inside tab bodies (read AccountTab/SyncTab/etc — but DO NOT modify them; if a tab uses Form with default background, mention in SUMMARY as deferred)
    - In DS3DriveApp.swift Preferences Window scene, also apply `.background(DS3Colors.brandBackground)` and `.preferredColorScheme(.dark)` so the window chrome itself is dark

    Skip wrapping individual tab cards with .brandCard() in this pass — that's a per-tab refactor that should be its own plan if needed. Document in SUMMARY as "tabs not yet card-wrapped, deferred to 05-18-followup if needed".
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - PreferencesView references brandBackground
    - Settings scene in DS3DriveApp references brandBackground
  </done>
</task>

</tasks>

<output>
Create `.planning/phases/05-ux-polish/05-18b-SUMMARY.md`.
</output>
