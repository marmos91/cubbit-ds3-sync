---
phase: 05-ux-polish
plan: 18a
type: execute
wave: 3
gap_closure: true
depends_on: [05-17]
parent_plan: 05-18
files_modified:
  - DS3Drive/Views/Login/Views/LoginView.swift
  - DS3Drive/Views/Login/Views/MFAView.swift
  - DS3Drive/Views/Sync/Views/TreeNavigationView.swift
  - DS3Drive/Views/Sync/Views/DriveConfirmView.swift
  - DS3Drive/Views/Common/ProjectBadge.swift
  - DS3Drive/Assets/Localizable.xcstrings
autonomous: false
requirements: [UX-01, UX-02]

must_haves:
  truths:
    - "Login window: gradient is the actual window backdrop, no inner card with its own dark fill (no 'bright blue border around dark card' bug)"
    - "Login + MFA heading reads 'DS3 Drive', NOT 'Cubbit DS3 Drive'"
    - "Login 'Log in' button uses BrandPrimaryButtonStyle, not Color.black"
    - "MFA view swept with same brand foundation"
    - "ProjectBadge.swift exists as a single shared component"
    - "TreeNavigationView and DriveConfirmView both use ProjectBadge — no inline orange-square or hand-rolled circle"
    - "TreeNavigationView Continue button uses BrandPrimaryButtonStyle"
    - "DriveConfirmView Create Drive button uses BrandPrimaryButtonStyle"
    - "DriveConfirmView form auto-focuses the drive name field on appear and Enter triggers Create Drive (.keyboardShortcut(.defaultAction))"
---

<objective>
Closes Gaps 19, 21, 22 and the wizard portion of Gap 4/5. First of three split agents from 05-18.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
</execution_context>

<context>
@.planning/phases/05-ux-polish/05-08-GAPS.md
@.planning/phases/05-ux-polish/05-18-PLAN.md
@DS3Drive/Views/Common/DesignSystem/DS3Colors.swift
@DS3Drive/Views/Common/DesignSystem/DS3Typography.swift
@DS3Drive/Views/Common/DesignSystem/DS3CardStyle.swift
@DS3Drive/Views/Common/Buttons/BrandPrimaryButtonStyle.swift
</context>

<tasks>

<task type="auto">
  <name>Task 1: Login + MFA brand sweep (Gap 19)</name>
  <files>
    DS3Drive/Views/Login/Views/LoginView.swift,
    DS3Drive/Views/Login/Views/MFAView.swift,
    DS3Drive/Assets/Localizable.xcstrings
  </files>
  <action>
    LoginView:
    - Drop the inner `RoundedRectangle.fill(brandSurface).shadow(...)` wrapper around the form (the source of the "bright blue border around dark card" bug). Form sits directly on the `brandVerticalBackground` window backdrop.
    - Replace `Image(.cubbitLogo) + DS3Gradients.brandRadialGlow` ZStack with logo only (or keep the glow if it's not the seam source — verify visually). Goal: remove the layered patchwork.
    - Subtitle "Cubbit DS3 Drive" → "DS3 Drive"
    - Heading "Log in to your account": use `DS3Typography.h3` (24pt) instead of `.headline`
    - Login button: `.buttonStyle(BrandPrimaryButtonStyle(fillWidth: true))` — remove the explicit `.frame(maxHeight: 36)`
    - Window size still 400x500

    MFAView: same sweep
    - Replace `DS3Colors.primaryText/secondaryText/separator` with `brandTextPrimary/brandTextSecondary/brandBorder`
    - Heading "Two-factor authentication": `DS3Typography.h3`
    - Wrap root in `ZStack { DS3Gradients.brandVerticalBackground.ignoresSafeArea(); ... }` so the MFA window matches login
    - "Log in" button: `BrandPrimaryButtonStyle(fillWidth: true)`
    - Hardcoded `.foregroundStyle(Color.accentColor)` lock icon → `DS3Colors.brandPrimary`

    Localizable.xcstrings: replace every "Cubbit DS3 Drive" copy literal with "DS3 Drive" (en + it). Use Grep first to find them, then surgical Edit calls.
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - Grep "Cubbit DS3 Drive" in LoginView.swift + MFAView.swift returns zero matches
    - Login + MFA reference BrandPrimaryButtonStyle
  </done>
</task>

<task type="auto">
  <name>Task 2: Shared ProjectBadge component + wizard sweep (Gaps 21, 22)</name>
  <files>
    DS3Drive/Views/Common/ProjectBadge.swift,
    DS3Drive/Views/Sync/Views/TreeNavigationView.swift,
    DS3Drive/Views/Sync/Views/DriveConfirmView.swift
  </files>
  <action>
    Step 1 — Create `DS3Drive/Views/Common/ProjectBadge.swift`:
    ```swift
    import DS3Lib
    import SwiftUI

    struct ProjectBadge: View {
        let projectId: String
        let projectName: String
        var size: CGFloat = 24

        var body: some View {
            Text(String(projectName.prefix(1).uppercased()))
                .font(.custom("Figtree-SemiBold", size: size * 0.5))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(DS3Colors.colorForProject(projectId))
                )
        }
    }
    ```
    Add to project.pbxproj under DS3Drive/Views/Common group (Sources build phase).

    Step 2 — TreeNavigationView:
    - Replace inline `iconView(for:)` project case with `ProjectBadge(projectId: projectId, projectName: node.project?.name ?? "?", size: 24)`
    - Replace inline `detailIconView(for:)` project case with `ProjectBadge(... size: 48)`
    - Continue button: `.buttonStyle(BrandPrimaryButtonStyle())`, drop `.frame(maxWidth: 120, maxHeight: 32)` constraint
    - IAM picker: leave functionally as-is but tighten chrome — use `brandSurface` capsule fill with `brandBorderSubtle` stroke
    - Empty hero (`wizardEmptyHero`): replace `Image(systemName: "cube.transparent")` with `Image(.cubbitLogo)` resized to 56pt and tinted via `.foregroundStyle(DS3Colors.brandPrimary.opacity(0.85))` (use `.renderingMode(.template)`). Keep the circle backdrop.

    Step 3 — DriveConfirmView:
    - Replace the orange-square badge in `summarySection` Project row with `ProjectBadge(projectId: syncAnchor.project.id, projectName: syncAnchor.project.name, size: 24)`
    - Wrap `summarySection` content with `.brandCard()` instead of the manual `RoundedRectangle.fill(secondaryBackground)` background
    - `.background(DS3Colors.background)` → `.background(DS3Colors.brandBackground)`
    - footerBar `secondaryBackground` → `brandSurface`; separator → `brandBorderSubtle`
    - Create Drive button: `BrandPrimaryButtonStyle()` + `.keyboardShortcut(.defaultAction)`, drop frame constraints
    - Add `@FocusState private var driveNameFocused: Bool` and `.focused($driveNameFocused)` on the TextField + `.onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { driveNameFocused = true } }`
    - Header "Confirm your drive": `DS3Typography.h3`
  </action>
  <verify>
    <automated>xcodebuild -project DS3Drive.xcodeproj -scheme "DS3 Drive" -destination "platform=macOS" build 2>&amp;1 | grep -E "error:" | head -10</automated>
  </verify>
  <done>
    - Build clean
    - ProjectBadge.swift exists and compiles
    - Both TreeNavigationView and DriveConfirmView reference ProjectBadge
    - Both reference BrandPrimaryButtonStyle
  </done>
</task>

</tasks>

<verification>
- xcodebuild clean
- grep "Cubbit DS3 Drive" in DS3Drive/Views/Login/ returns zero
- grep ProjectBadge in TreeNavigationView.swift AND DriveConfirmView.swift returns at least one match each
</verification>

<output>
Create `.planning/phases/05-ux-polish/05-18a-SUMMARY.md`. Note that visual verification is rolled into the parent 05-18 checkpoint at the end.
</output>
