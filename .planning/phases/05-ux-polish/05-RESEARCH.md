# Phase 5: UX Polish - Research

**Researched:** 2026-03-13
**Domain:** macOS File Provider decorations, SwiftUI menu bar UX, drive setup wizard, visual design system, localization
**Confidence:** HIGH

## Summary

Phase 5 is a large UX overhaul covering seven requirement areas: Finder sync badges (NSFileProviderItemDecoration), menu bar tray restructuring with side panels, transfer speed display, recent files tracking, quick actions (including Finder context menu), a simplified 2-step drive setup wizard, and the drive limit (already enforced). The codebase is well-prepared: `S3Item.decorationPrefix` is already defined, `MetadataStore` tracks per-item `syncStatus`, `DS3DriveViewModel` already computes transfer speed via `DistributedNotificationCenter`, and `NSLocalizedString` is used throughout with a modern `.xcstrings` String Catalog in place. The existing UI uses hardcoded custom colors (`.darkWhite`, `.darkMainStandard`, `.background`) and the Nunito font, both of which must be replaced with system semantics and SF Pro per the locked decisions.

The primary technical challenges are: (1) implementing `NSFileProviderItemDecorating` with Info.plist decoration entries and folder-level badge aggregation, (2) building side panel expansion for the tray menu using SwiftUI popover/panel patterns within `MenuBarExtra(.window)`, (3) animating the menu bar tray icon for syncing state using `Timer`-based NSImage frame swapping, and (4) implementing the Finder right-click actions via `FileProviderUI` (`FPUIActionExtensionViewController`) or `NSExtensionFileProviderActions` in Info.plist.

**Primary recommendation:** Break this phase into multiple waves -- decorations/badges first (extension-side, minimal app changes), then menu bar tray restructure + design system, then wizard + login + preferences redesign, and finally localization/copy audit.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Five badge states using SF Symbols: synced (green checkmark.circle), syncing (blue arrow.triangle.2.circlepath), error (red xmark.circle), cloud-only (gray cloud), conflict (orange exclamationmark.triangle)
- Badges use NSFileProviderItemDecoration (S3Item.decorationPrefix already defined)
- Folders show aggregate badge reflecting children's status
- No root drive badge, no badge animation, no pause badge on files
- Real-time badge updates via signalEnumerator when syncStatus changes
- Menu bar icon: status-aware with animated syncing state (rotating/pulsing arrows)
- Icon variants: idle, syncing (animated), error, paused
- Per-drive colored dot indicators: green=synced, blue=syncing, red=error, yellow/orange=paused
- Drive rows show file count, total size, current speed, sync time
- Global speed summary at top, per-drive speed inline
- Right-click context menu on drive rows
- "Signed in as user@email.com" kept in main tray
- Connection Info moved to separate side panel
- Two side panels (recent files per drive, connection info), one at a time, ~310pt width, left of main tray
- Recent files: last 10 per drive, sorted by progress > errors > completed
- Click recent file to reveal in Finder
- Per-drive pause/resume with finish-current-transfer behavior, persisted across restarts
- Drive gear menu: Disconnect, View in Finder, View in Console, Manage, Refresh, Pause/Resume, Copy S3 Path
- Finder right-click: "Copy S3 Key" and "View in Web Console"
- Wizard: 2 steps (tree view navigation + name/confirm), 800x480, skeleton loading, auto-suggested drive name
- Login: centered card, 400x500, DS3 Drive logo, Advanced collapsible, always persist session
- Preferences: macOS Settings-style tabs (General, Account, Sync), 800x600
- Design system: SF Pro everywhere (remove Nunito), follow macOS light/dark mode (remove hardcoded dark colors), SwiftUI semantic colors, Cubbit brand blue accent
- Copy audit: fix "Cubbit DS3 Sync" references to "DS3 Drive"
- Italian localization added (Localizable.strings for it locale)

### Claude's Discretion
- Exact SF Symbol names for each badge state (may vary by availability)
- Skeleton/shimmer animation implementation details
- Tray icon animation technique (NSStatusBarButton image swapping interval)
- Tree view expand/collapse animation and interaction details
- Exact Cubbit brand color hex values (from existing asset catalog or brand guidelines)
- Side panel animation (slide in/out direction and timing)
- Tab layout in preferences (icon choice, tab ordering details)
- How to implement Finder right-click actions (NSFileProviderUserInteractions or FileProviderUI)
- Recent files storage mechanism (in-memory ring buffer vs persisted)

### Deferred Ideas (OUT OF SCOPE)
None -- all discussed topics fall within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| UX-01 | Finder status overlays showing sync state per file (synced/syncing/error/cloud-only) | NSFileProviderItemDecorating protocol + Info.plist NSFileProviderDecorations entries with SF Symbol badges; folder aggregation via MetadataStore queries |
| UX-02 | Menu bar tray shows sync status per drive with colored indicators | Colored Circle SF Symbols or custom views in TrayDriveRowView; AppStatusManager extended with paused state |
| UX-03 | Menu bar tray shows real-time transfer speed (upload/download) | DS3DriveViewModel already receives DriveTransferStats via DistributedNotificationCenter; add aggregate speed computation |
| UX-04 | Menu bar tray shows recently synced files | In-memory ring buffer per drive, populated from existing transfer notifications; side panel UI |
| UX-05 | Menu bar tray quick actions: add drive, open in Finder, preferences, pause sync | Extend existing gear menu; add pause state to DS3DriveStatus and SharedData; Finder right-click via FileProviderUI |
| UX-06 | Simplified drive setup wizard with tenant-aware project/bucket selection | Refactor 3-step SetupSyncView to 2-step tree view + confirm; reuse SyncAnchorSelectionView sidebar pattern |
| UX-07 | Drive limit maintained at 3 maximum | Already enforced via DefaultSettings.maxDrives check in TrayMenuView.canAddMoreDrives -- no work needed |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI | macOS 15+ | All UI views | Native framework, @Observable pattern already in use |
| FileProvider | macOS 15+ | NSFileProviderItemDecorating for badges | Apple framework, only way to add Finder overlays |
| FileProviderUI | macOS 15+ | FPUIActionExtensionViewController for Finder context menu | Apple framework for custom File Provider actions |
| SF Symbols | 5.0+ | Badge icons, status indicators | System symbols, auto-adapt to light/dark/accessibility |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| SwiftUI-Shimmer | 1.5+ | Skeleton loading animation | Wizard loading states; `.shimmering()` + `.redacted()` modifiers |
| AppKit (NSStatusBarButton) | macOS 15+ | Animated tray icon | Timer-based frame animation for syncing state |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SwiftUI-Shimmer | Custom `.redacted()` + LinearGradient | SwiftUI-Shimmer is 1 file, zero config; custom adds maintenance |
| FileProviderUI (Finder actions) | NSExtensionFileProviderActions in Info.plist only | Info.plist actions are simpler but limited; FileProviderUI allows custom UI |

**Installation:**
No external dependencies needed beyond SwiftUI-Shimmer (optional -- can be hand-rolled with `.redacted()` modifier + animation). The decision on whether to add SwiftUI-Shimmer as an SPM dependency or hand-roll is at Claude's discretion.

## Architecture Patterns

### Recommended Project Structure
```
DS3Drive/
  Views/
    Common/
      DesignSystem/         # NEW: Colors, typography, spacing constants
        DS3Colors.swift     # Semantic color definitions wrapping system + brand colors
        DS3Typography.swift # Font definitions (SF Pro replacements for Nunito)
        DS3Spacing.swift    # Consistent spacing constants
      ShimmerModifier.swift # NEW: Shimmer/skeleton loading (if hand-rolled)
    Login/
      Views/
        LoginView.swift     # REDESIGN: Centered card layout
    Preferences/
      Views/
        PreferencesView.swift    # REDESIGN: Tabbed sections
        GeneralTab.swift         # NEW
        AccountTab.swift         # NEW
        SyncTab.swift            # NEW
    Sync/
      Views/
        SetupSyncView.swift      # REFACTOR: 2-step flow
        TreeNavigationView.swift # NEW: Project > Bucket > Prefix tree
        DriveConfirmView.swift   # NEW: Name + summary confirmation
    Tray/
      Views/
        TrayMenuView.swift       # REDESIGN: New layout with side panels
        TrayDriveRowView.swift   # REDESIGN: Colored dots, metrics, context menu
        TrayMenuFooterView.swift # UPDATE: Design system
        RecentFilesPanel.swift   # NEW: Side panel for recent files
        ConnectionInfoPanel.swift # NEW: Side panel for connection info
        SpeedSummaryView.swift   # NEW: Global speed display
      ViewModels/
        DS3DriveViewModel.swift  # EXTEND: Recent files, pause state
        TrayViewModel.swift      # NEW: Aggregate speed, panel state
DS3DriveProvider/
  S3Item.swift                   # ADD: NSFileProviderItemDecorating conformance
  Info.plist                     # ADD: NSFileProviderDecorations entries
DS3Lib/
  Sources/DS3Lib/
    Models/
      DS3Drive.swift             # ADD: isPaused property
      AppStatus.swift            # ADD: paused case
    SharedData/
      SharedData+pauseState.swift # NEW: Persist pause state per drive
```

### Pattern 1: NSFileProviderItemDecorating
**What:** S3Item conforms to `NSFileProviderItemDecorating` to provide Finder badge overlays based on sync status.
**When to use:** Every S3Item returned by the enumerator or CRUD methods.
**Example:**
```swift
// Source: Apple Developer Documentation + Claudio Cambra blog
import FileProvider

class S3Item: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    static let decorationPrefix = Bundle.main.bundleIdentifier!

    // Decoration identifiers matching Info.plist NSFileProviderDecorations keys
    static let decorationSynced = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).synced"
    )
    static let decorationSyncing = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).syncing"
    )
    static let decorationError = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).error"
    )
    static let decorationCloudOnly = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).cloudOnly"
    )
    static let decorationConflict = NSFileProviderItemDecorationIdentifier(
        rawValue: "\(decorationPrefix).conflict"
    )

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        switch syncStatus {
        case .synced:    return [Self.decorationSynced]
        case .syncing:   return [Self.decorationSyncing]
        case .error:     return [Self.decorationError]
        case .cloudOnly: return [Self.decorationCloudOnly]
        case .conflict:  return [Self.decorationConflict]
        default:         return nil
        }
    }
}
```

Info.plist additions (inside NSExtension dict):
```xml
<key>NSFileProviderDecorations</key>
<dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.synced</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>checkmark.circle.fill</string>
        <key>Label</key>
        <string>Synced</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.syncing</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>arrow.triangle.2.circlepath</string>
        <key>Label</key>
        <string>Syncing</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <!-- ... similar for error, cloudOnly, conflict -->
</dict>
```

### Pattern 2: Tray Icon Animation
**What:** Timer-based NSImage frame swapping on the NSStatusBarButton for syncing state.
**When to use:** When AppStatus is `.syncing`.
**Example:**
```swift
// The MenuBarExtra label uses SwiftUI Image, but animation requires
// Timer-driven state changes since SwiftUI in MenuBarExtra label
// doesn't support continuous animations.

// Approach: Use @State Timer in DS3DriveApp to cycle through
// syncing frame images at ~0.3s intervals

@State private var syncAnimationFrame = 0
@State private var syncAnimationTimer: Timer?

// In MenuBarExtra label:
switch appStatusManager.status {
case .syncing:
    // Cycle through 2-4 rotation frames of the sync icon
    Image(syncIconFrames[syncAnimationFrame])
default:
    Image(.trayIcon)
}

// Start/stop timer when status changes:
.onChange(of: appStatusManager.status) { _, newValue in
    if newValue == .syncing {
        syncAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            syncAnimationFrame = (syncAnimationFrame + 1) % syncIconFrames.count
        }
    } else {
        syncAnimationTimer?.invalidate()
        syncAnimationFrame = 0
    }
}
```

### Pattern 3: Side Panel via NSPopover or Additional Window
**What:** Side panels appearing to the left of the main tray menu.
**When to use:** Showing recent files per drive or connection info.
**Example approach:**
```swift
// MenuBarExtra with .window style gives an NSPanel.
// For a side panel, options are:
// 1. NSPopover attached to the tray panel's frame
// 2. A floating NSPanel positioned relative to the tray
// 3. SwiftUI overlay/sheet within a wider MenuBarExtra frame
//
// Recommended: Expand the MenuBarExtra content dynamically.
// When a side panel is active, render it inline using
// HStack { sidePanel | mainTray } and adjust frame width.
// This avoids managing separate windows.

struct TrayMenuView: View {
    @State private var activeSidePanel: SidePanel? = nil

    enum SidePanel {
        case recentFiles(driveId: UUID)
        case connectionInfo
    }

    var body: some View {
        HStack(spacing: 0) {
            if let panel = activeSidePanel {
                sidePanelContent(panel)
                    .frame(width: 310)
                    .transition(.move(edge: .leading))
            }
            mainTrayContent()
                .frame(width: 310)
        }
        .animation(.easeInOut(duration: 0.2), value: activeSidePanel != nil)
    }
}
```

### Pattern 4: Pause State Persistence
**What:** Per-drive pause state persisted to SharedData App Group container.
**When to use:** When user pauses/resumes a drive.
**Example:**
```swift
// In SharedData, add pause state file:
// pauseState.json -> { "driveId1": true, "driveId2": false }

// DS3DriveStatus extended:
public enum DS3DriveStatus: String, Codable, Hashable, Sendable {
    case sync, indexing, idle, error, paused
}

// DS3Drive gets isPaused computed from SharedData
// Extension checks pause state before starting new transfers
```

### Anti-Patterns to Avoid
- **Using FinderSync extension for badges:** File Provider already has `NSFileProviderItemDecorating` -- do not create a separate FinderSync extension, which conflicts with File Provider.
- **Hardcoding colors with Color(.darkWhite) pattern:** Replace with SwiftUI semantic colors (`.primary`, `.secondary`) and system colors. Keep only the Cubbit brand blue as a custom color.
- **Using .font(.custom("Nunito", ...)) anywhere:** Replace all instances with `.font(.system(...))` or `.font(.body)` etc. SF Pro is the macOS system font and loads with zero configuration.
- **Creating separate NSWindow for side panels:** Keep everything within the MenuBarExtra `.window` style by dynamically expanding the content width. Separate windows are fragile and hard to position correctly.
- **Querying MetadataStore from the main app for badge computation:** Badges are computed in the File Provider extension (S3Item). The extension already has MetadataStore access. The main app should not compute badges.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Finder file badges | Custom FinderSync extension | NSFileProviderItemDecorating | Built into File Provider framework; FinderSync conflicts |
| Shimmer loading | Custom gradient animation from scratch | `.redacted(reason: .placeholder)` + `.shimmering()` (SwiftUI-Shimmer) or custom ViewModifier with LinearGradient + mask | Well-solved problem, `.redacted()` is built into SwiftUI |
| System font | Custom font registration | `.font(.system(...))` | SF Pro is the default macOS system font |
| Light/dark mode | Manual color toggling | SwiftUI semantic colors + asset catalog appearances | macOS handles mode switching automatically |
| Localization | Manual string loading | String Catalogs (.xcstrings) + NSLocalizedString | Xcode auto-extracts strings, handles plurals, manages translations |
| Menu bar icon template | Separate light/dark icon assets | `NSImage.isTemplate = true` | macOS renders template images correctly in all contexts |

**Key insight:** macOS provides extensive built-in support for dark mode, localization, and system integration through semantic colors, String Catalogs, and the File Provider framework. The existing codebase fights the system by using custom colors and fonts -- the main refactoring work is removing custom styling, not adding new libraries.

## Common Pitfalls

### Pitfall 1: NSFileProviderItemDecorating Not Showing Badges
**What goes wrong:** Badges configured in Info.plist and code but nothing appears in Finder.
**Why it happens:** (a) Decoration identifier strings in code don't match Info.plist keys exactly, (b) Info.plist `NSFileProviderDecorations` dict is inside the wrong parent dict (must be inside `NSExtension`), (c) Extension needs to signal enumerator after changing item status for Finder to re-fetch decorations.
**How to avoid:** (a) Use constants for identifier strings shared between S3Item and the code that builds identifiers. (b) Put decorations dict directly inside `NSExtension` in Info.plist. (c) Call `NSFileProviderManager.signalEnumerator(for:)` after any sync status change.
**Warning signs:** Badges work for new items but not updated items; need to eject/re-add domain to see badges.

### Pitfall 2: MenuBarExtra Side Panel Sizing
**What goes wrong:** Expanding the tray menu to show a side panel causes the window to clip or position incorrectly.
**Why it happens:** `MenuBarExtra(.window)` manages its own NSPanel. Dynamic width changes may not resize the panel correctly.
**How to avoid:** Use `.frame(minWidth:maxWidth:)` on the root view and set `.fixedSize(horizontal: true, vertical: false)`. Test with the panel both open and closed. Consider using `animation(.easeInOut)` for smooth transitions.
**Warning signs:** Content is clipped on the left edge; panel appears at wrong screen position.

### Pitfall 3: Timer-Based Animation in MenuBarExtra Label
**What goes wrong:** The syncing animation in the menu bar icon stutters, doesn't update, or causes excessive CPU usage.
**Why it happens:** MenuBarExtra label view updates may be throttled by SwiftUI. Timer callbacks on a non-main RunLoop mode may not fire when the menu is open.
**How to avoid:** Schedule timer on `.common` RunLoop mode. Use moderate frame rate (3-4 frames at ~0.3s interval, not 30fps). Keep icon frames as pre-rendered template images in the asset catalog.
**Warning signs:** Animation works when menu is closed but freezes when menu is open; animation is smooth but CPU usage spikes.

### Pitfall 4: String Catalog Italian Localization
**What goes wrong:** Italian translations don't appear; app always shows English.
**Why it happens:** `.xcstrings` file needs the `it` locale added as a target language in Xcode's String Catalog editor. Simply adding strings isn't enough -- the project's localization settings must include Italian.
**How to avoid:** In Xcode, go to Project > Info > Localizations and add Italian. Then edit the `.xcstrings` file to add `it` translations for each string.
**Warning signs:** Strings show keys instead of translations; `Bundle.preferredLocalizations` doesn't include "it".

### Pitfall 5: Replacing Colors Breaks Dark Mode
**What goes wrong:** Switching from custom colors to semantic colors makes some views unreadable in one mode.
**Why it happens:** The existing color assets (`.darkWhite`, `.darkMainStandard`) have hardcoded dark mode values. Replacing them with `.secondary` or `.primary` changes the actual colors used. Some views may have layered custom colors that cancel each other out.
**How to avoid:** Replace colors systematically per view, testing both light and dark mode after each change. Start with structural/background colors, then text, then accents.
**Warning signs:** White text on white background in light mode; invisible dividers; buttons that disappear.

### Pitfall 6: Folder Badge Aggregation Performance
**What goes wrong:** Computing aggregate badges for folders with many children causes UI lag.
**Why it happens:** Querying MetadataStore for all children of a folder prefix on every enumeration is expensive.
**How to avoid:** Compute folder badges lazily -- only when the folder is visible. Use a simple heuristic: if any child has `.syncing` status, folder is syncing; if any child has `.error`, folder shows error. Cache the result and invalidate on `signalEnumerator`.
**Warning signs:** Finder hangs when opening folders with 1000+ items; extension memory usage grows.

### Pitfall 7: Pause State Race Condition
**What goes wrong:** User pauses a drive but the extension starts a new transfer before receiving the pause signal.
**Why it happens:** SharedData persistence is cross-process (App Group) but not transactional. The extension may read stale state.
**How to avoid:** The CONTEXT.md specifies "finish current transfer, stop new transfers" -- this is the correct behavior. The extension should check pause state before starting each new operation, not mid-transfer. Use NSFileCoordinator for reading pause state (already the pattern for other SharedData).
**Warning signs:** Files continue syncing after pause is pressed; pause takes effect only after all queued transfers complete.

## Code Examples

### Verified: NSFileProviderItemDecorating Implementation
```swift
// Source: Apple Developer Docs (NSFileProviderItemDecorating) + Claudio Cambra blog
// S3Item must conform to NSFileProviderItemDecorating

class S3Item: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    static let decorationPrefix = Bundle.main.bundleIdentifier!

    // Sync status for this item (set from MetadataStore or inferred)
    var syncStatus: SyncStatus = .synced

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        let prefix = Self.decorationPrefix
        switch syncStatus {
        case .synced:
            return [NSFileProviderItemDecorationIdentifier(rawValue: "\(prefix).synced")]
        case .syncing:
            return [NSFileProviderItemDecorationIdentifier(rawValue: "\(prefix).syncing")]
        case .error:
            return [NSFileProviderItemDecorationIdentifier(rawValue: "\(prefix).error")]
        case .conflict:
            return [NSFileProviderItemDecorationIdentifier(rawValue: "\(prefix).conflict")]
        case .pending:
            return [NSFileProviderItemDecorationIdentifier(rawValue: "\(prefix).cloudOnly")]
        }
    }
}
```

### Verified: Info.plist NSFileProviderDecorations
```xml
<!-- Source: Apple Developer Docs + Claudio Cambra blog -->
<!-- Add inside the existing <dict> under NSExtension key -->
<key>NSFileProviderDecorations</key>
<dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.synced</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>checkmark.circle.fill</string>
        <key>Label</key>
        <string>Synced</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.syncing</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>arrow.triangle.2.circlepath</string>
        <key>Label</key>
        <string>Syncing</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.error</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>xmark.circle.fill</string>
        <key>Label</key>
        <string>Error</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.cloudOnly</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>cloud.fill</string>
        <key>Label</key>
        <string>Cloud Only</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
    <key>io.cubbit.DS3Drive.DS3DriveProvider.conflict</key>
    <dict>
        <key>BadgeImageType</key>
        <string>Symbol</string>
        <key>SymbolName</key>
        <string>exclamationmark.triangle.fill</string>
        <key>Label</key>
        <string>Conflict</string>
        <key>Category</key>
        <string>SyncStatus</string>
    </dict>
</dict>
```

### Verified: SwiftUI Tabbed Preferences (macOS Settings Style)
```swift
// Source: SwiftUI documentation + Apple HIG
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            AccountTab()
                .tabItem {
                    Label("Account", systemImage: "person.circle")
                }
            SyncTab()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 800, height: 600)
    }
}
```

### Verified: Skeleton/Shimmer Loading
```swift
// Source: SwiftUI .redacted() modifier + custom shimmer
// Option A: Pure SwiftUI (no dependency)
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .mask(
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .white, .clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(70))
                .offset(x: phase * 400 - 200)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

// Usage:
Text("Loading bucket list...")
    .shimmering()
```

### Verified: Color System Migration
```swift
// Source: SwiftUI documentation, macOS HIG
// BEFORE (current pattern):
Color(.background)        // Custom asset catalog color
Color(.darkWhite)         // Custom gray
Color(.darkMainStandard)  // Custom dark background
.font(.custom("Nunito", size: 14))

// AFTER (design system):
// Structural colors -> SwiftUI semantics
Color(.windowBackgroundColor)  // or just remove background (system default)
.foregroundStyle(.secondary)   // replaces Color(.darkWhite)
.background(.background)       // SwiftUI semantic background

// Text -> system font
.font(.system(size: 14))       // SF Pro, same size
.font(.body)                   // Dynamic type preferred
.font(.headline)               // Semantic sizing

// Cubbit brand color -> accent
Color.accentColor              // Set in asset catalog as AccentColor
// or define:
extension Color {
    static let cubbitBlue = Color(red: 0, green: 0x9E/255.0, blue: 1) // #009EFF
}
```

### Verified: Finder Right-Click Actions via Info.plist
```xml
<!-- Source: Apple Developer Docs (NSExtensionFileProviderActions) -->
<!-- Add to File Provider extension Info.plist inside NSExtension -->
<key>NSExtensionFileProviderActions</key>
<array>
    <dict>
        <key>NSExtensionFileProviderActionIdentifier</key>
        <string>io.cubbit.DS3Drive.action.copyS3Key</string>
        <key>NSExtensionFileProviderActionName</key>
        <string>Copy S3 Key</string>
        <key>NSExtensionFileProviderActionActivationRule</key>
        <string>TRUEPREDICATE</string>
    </dict>
    <dict>
        <key>NSExtensionFileProviderActionIdentifier</key>
        <string>io.cubbit.DS3Drive.action.viewInConsole</string>
        <key>NSExtensionFileProviderActionName</key>
        <string>View in Web Console</string>
        <key>NSExtensionFileProviderActionActivationRule</key>
        <string>TRUEPREDICATE</string>
    </dict>
</array>
```

Note: Implementing the action handlers requires a FileProviderUI extension target with `FPUIActionExtensionViewController`, or handling via `performAction(identifier:onItemsWithIdentifiers:)` on the File Provider extension itself. The simpler approach for "Copy S3 Key" (which just copies to clipboard) is to add a new FileProviderUI extension target. However, since the File Provider extension runs in a sandbox without access to `NSPasteboard`, the simplest approach for "Copy S3 Key" is through a FileProviderUI extension that presents briefly and copies. Alternatively, the main app can provide this via the tray menu context for each drive's files. This is an area where implementation complexity should be evaluated -- the CONTEXT.md marks this as Claude's discretion.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| FinderSync extension for badges | NSFileProviderItemDecorating | macOS 12+ (WWDC 2021) | Badges integrated directly into File Provider items |
| .strings files | .xcstrings String Catalogs | Xcode 15 (2023) | Single file manages all languages; project already uses this |
| Storyboard preferences | SwiftUI TabView/Settings scene | macOS 13+ (2022) | Declarative preferences windows |
| Hardcoded dark theme | SwiftUI semantic colors | macOS 11+ (2020) | Automatic light/dark adaptation |
| Custom fonts via .custom() | .system() font | Always available | SF Pro matches all macOS UI automatically |
| NSUserDefaults for inter-process state | SharedData with NSFileCoordinator | Project convention | Atomic cross-process reads/writes |

**Deprecated/outdated:**
- FinderSync Extension: Still works but redundant when using File Provider's built-in decoration support. Do not add one.
- `.strings` files: Replaced by `.xcstrings` String Catalogs. Project already uses `.xcstrings`.
- `Nunito` custom font: Not a macOS system font. Should be fully replaced by SF Pro (system font).

## Open Questions

1. **Folder Badge Aggregation Strategy**
   - What we know: The extension has MetadataStore access and can query children by parentKey. S3Item is constructed per-item during enumeration.
   - What's unclear: Whether querying all children on every folder enumeration is performant for large folders (1000+ items). The MetadataStore is an actor, so queries are async.
   - Recommendation: Use a simple first-child-wins heuristic during enumeration -- if any child being enumerated has non-synced status, mark the folder accordingly. For deeply nested aggregation, consider a separate sync status summary in MetadataStore per folder prefix.

2. **Side Panel Implementation within MenuBarExtra**
   - What we know: `MenuBarExtra(.window)` creates an NSPanel. SwiftUI content can be dynamically sized.
   - What's unclear: Whether expanding the content width dynamically works smoothly, or if the NSPanel clips/repositions unexpectedly.
   - Recommendation: Prototype the HStack approach (side panel + main tray) early. If the NSPanel doesn't resize well, fall back to using the main tray area exclusively (replace main content with panel content on tap, with a back button).

3. **Finder Right-Click Action Feasibility**
   - What we know: NSExtensionFileProviderActions declares actions in Info.plist. Handling requires either `performAction(identifier:)` on the extension or a FileProviderUI extension.
   - What's unclear: Whether `performAction(identifier:onItemsWithIdentifiers:)` is available on NSFileProviderReplicatedExtension for macOS 15+. The extension sandbox may prevent clipboard access for "Copy S3 Key".
   - Recommendation: Research further during implementation. If Finder right-click proves too complex (new target required), defer to a later iteration and provide the same actions in the tray menu drive context menu instead.

4. **Cubbit Brand Color Exact Values**
   - What we know: `ButtonPrimaryColor` in the asset catalog is `#009EFF` (RGB 0, 158, 255). This appears to be the Cubbit brand blue.
   - What's unclear: Whether there are additional brand colors beyond blue (secondary, tertiary) that should be preserved.
   - Recommendation: Use `#009EFF` as the Cubbit accent color. Set it as the `AccentColor` in the asset catalog so SwiftUI's `.accentColor` picks it up automatically. Other custom colors should be replaced with system semantic colors.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift Package Manager tests in DS3Lib) |
| Config file | DS3Lib/Package.swift (test target defined) |
| Quick run command | `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test --filter DS3LibTests` |
| Full suite command | `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| UX-01 | Finder badges show correct sync state per file | manual-only | N/A -- requires Finder + File Provider extension runtime | N/A (manual) |
| UX-02 | Menu bar shows per-drive colored status indicators | manual-only | N/A -- requires running app with menu bar | N/A (manual) |
| UX-03 | Real-time transfer speed display | unit | `cd DS3Lib && swift test --filter DS3LibTests.DS3LibTests/testDriveStatsFormatting` | Partial (DS3DriveStats.toString() tested) |
| UX-04 | Recently synced files displayed | unit | `cd DS3Lib && swift test --filter DS3LibTests/testRecentFilesRingBuffer` | No -- Wave 0 |
| UX-05 | Quick actions work (pause, open Finder, etc.) | manual-only | N/A -- requires running app | N/A (manual) |
| UX-06 | Simplified 2-step wizard | manual-only | N/A -- UI flow test | N/A (manual) |
| UX-07 | Drive limit at 3 | unit | `cd DS3Lib && swift test --filter DS3LibTests/testMaxDrives` | Partial (DefaultSettings.maxDrives = 3 is a constant) |

**Justification for manual-only tests:** UX-01 through UX-06 are primarily visual/interaction requirements that depend on the macOS File Provider runtime, Finder integration, and SwiftUI window management. These cannot be meaningfully unit-tested. The verification strategy for UX requirements should focus on:
1. Unit tests for data layer logic (pause state persistence, recent files buffer, speed formatting)
2. Manual testing checklist for visual/interaction requirements
3. Build verification (xcodebuild clean build) to catch compilation errors

### Sampling Rate
- **Per task commit:** `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test --filter DS3LibTests`
- **Per wave merge:** `cd /Users/marmos91/Projects/cubbit-ds3-drive/DS3Lib && swift test`
- **Phase gate:** Full suite green + manual testing of all 7 success criteria

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/RecentFilesTests.swift` -- covers ring buffer logic for UX-04
- [ ] `DS3Lib/Tests/DS3LibTests/PauseStateTests.swift` -- covers pause state persistence for UX-05
- [ ] Verify `xcodebuild clean build analyze` still passes after UI changes (CI gate)

*(Most UX-phase requirements are visual/interaction and covered by manual testing, not automated unit tests)*

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation: NSFileProviderItemDecorating protocol -- decoration property, identifier format
- Apple Developer Documentation: NSExtensionFileProviderActions -- Finder context menu actions via Info.plist
- Apple Developer Documentation: FileProviderUI / FPUIActionExtensionViewController -- custom action UI
- Apple Developer Documentation: MenuBarExtra scene -- `.window` style for panel-based tray menus
- Claudio Cambra blog (claudiocambra.com/posts/build-file-provider-sync/) -- complete NSFileProviderItemDecorating implementation with Info.plist example
- Existing codebase: S3Item.swift, TrayMenuView.swift, DS3DriveViewModel.swift, MetadataStore.swift, Info.plist, Localizable.xcstrings

### Secondary (MEDIUM confidence)
- SwiftUI-Shimmer GitHub (markiv/SwiftUI-Shimmer) -- shimmer modifier implementation
- Multi.app blog (multi.app/blog/pushing-the-limits-nsstatusitem) -- NSStatusItem/NSStatusBarButton advanced usage
- Apple Developer Forums: File Provider badge discussions (thread/689257)
- TrozWare (troz.net/post/2025/swiftui-mac-2025/) -- SwiftUI macOS 2025 patterns

### Tertiary (LOW confidence)
- Finder right-click action feasibility for clipboard operations from sandboxed extension -- needs validation during implementation
- Side panel dynamic resizing within MenuBarExtra -- needs prototype validation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all Apple frameworks, well-documented
- Architecture (badges): HIGH -- NSFileProviderItemDecorating is well-documented, decorationPrefix already exists in S3Item
- Architecture (menu bar): MEDIUM -- side panel approach within MenuBarExtra needs prototype validation
- Architecture (Finder right-click): MEDIUM -- requires FileProviderUI extension or workaround, sandbox constraints unclear
- Pitfalls: HIGH -- common issues are well-documented in Apple forums and developer blogs
- Localization: HIGH -- project already uses .xcstrings, just needs Italian locale added
- Design system: HIGH -- straightforward replacement of custom colors/fonts with system equivalents

**Research date:** 2026-03-13
**Valid until:** 2026-04-13 (stable Apple frameworks, no rapid changes expected)
