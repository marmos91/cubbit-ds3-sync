# Codebase Structure

**Analysis Date:** 2026-03-11

## Directory Layout

```
cubbit-ds3-sync/
├── CubbitDS3Sync/                    # Main macOS app target
│   ├── CubbitDS3SyncApp.swift        # App entry point, window management
│   ├── Views/                        # UI layer organized by feature
│   │   ├── Common/                   # Reusable SwiftUI components
│   │   ├── Login/                    # Authentication UI
│   │   ├── Tray/                     # Menu bar extra
│   │   ├── Tutorial/                 # Onboarding
│   │   ├── Preferences/              # Settings
│   │   ├── Sync/                     # Drive setup wizard (multi-step)
│   │   │   ├── ProjectSelection/     # Step 1: Select project
│   │   │   ├── SyncAnchorSelection/  # Step 2: Select bucket/prefix
│   │   │   ├── SyncRecap/            # Step 3: Name and confirm
│   │   │   └── Views/                # Main sync views
│   │   ├── ManageDrive/              # Drive management UI
│   │   └── Preview Content/          # Xcode previews
│   └── Assets/                       # Images, colors, icons
│
├── DS3Lib/                           # Shared library (app + extension)
│   ├── DS3SDK.swift                  # API client for Cubbit backend
│   ├── DS3Authentication.swift       # User authentication, tokens
│   ├── DS3DriveManager.swift         # Drive lifecycle management
│   ├── AppStatusManager.swift        # App-wide status tracking
│   ├── Models/                       # Domain models
│   │   ├── DS3Drive.swift            # Drive entity with status
│   │   ├── SyncAnchor.swift          # Sync configuration (project/bucket/prefix)
│   │   ├── AccountSession.swift      # Session tokens and refresh
│   │   ├── Project.swift             # DS3 project
│   │   ├── IAMUser.swift             # Identity and access management user
│   │   ├── DS3APIKey.swift           # S3 credentials
│   │   ├── Account.swift             # User account
│   │   ├── AppStatus.swift           # Sync status enum
│   │   ├── Bucket.swift              # S3 bucket
│   │   ├── Challenge.swift           # Auth challenge
│   │   ├── Token.swift               # Access/refresh tokens
│   │   └── RefreshToken.swift        # Refresh token wrapper
│   ├── SharedData/                   # Persistence layer
│   │   ├── SharedData.swift          # Base singleton, app group access
│   │   ├── SharedData+account.swift
│   │   ├── SharedData+accountSession.swift
│   │   ├── SharedData+apiKeys.swift
│   │   ├── SharedData+ds3Drive.swift
│   │   └── SharedData+syncAnchor.swift
│   ├── Constants/                    # Configuration constants
│   │   ├── DefaultSettings.swift     # App-wide settings
│   │   └── URLs.swift                # API endpoints
│   └── Utils/                        # Helper extensions
│       ├── JWT.swift
│       ├── Notifications+Extensions.swift
│       ├── DateFormatter+Extensions.swift
│       ├── Bundle+Extensions.swift
│       ├── System.swift
│       ├── URLs+Extensions.swift
│       ├── ControlFlow.swift
│       └── NSFileProvider+Extensions.swift
│
├── Provider/                         # FileProvider extension target
│   ├── FileProviderExtension.swift   # Extension entry point
│   ├── FileProviderExtension+Errors.swift
│   ├── S3Lib.swift                   # S3 operations wrapper
│   ├── S3Item.swift                  # FileProvider item abstraction
│   ├── S3Item+Metadata.swift
│   ├── S3Enumerator.swift            # Change enumeration
│   ├── NotificationsManager.swift    # App notifications
│   └── Provider.xcassets/            # Provider-specific assets
│
├── CubbitDS3Sync.xcodeproj/          # Xcode project configuration
├── .github/                          # GitHub CI/CD
├── Assets/                           # Project documentation assets
├── CLAUDE.md                         # This file - development guidance
├── README.md
├── LICENSE
└── .gitignore
```

## Directory Purposes

**CubbitDS3Sync/:**
- Purpose: Main application UI and entry point
- Contains: SwiftUI views, view models, assets
- Key files: `CubbitDS3SyncApp.swift` (entry point)

**CubbitDS3Sync/Views/:**
- Purpose: Presentation layer organized by feature
- Contains: SwiftUI View structs and @Observable ViewModels
- Pattern: Each major feature has Views/ and ViewModels/ subdirectories
- Key files: Feature-specific views and their state managers

**CubbitDS3Sync/Views/Sync/:**
- Purpose: Multi-step wizard for configuring drive synchronization
- Contains: ProjectSelection, SyncAnchorSelection, SyncRecap sub-features
- Pattern: Each step has Views/ and ViewModels/ subdirectories
- Flow: Project → Bucket/Prefix → Name → Confirmation

**CubbitDS3Sync/Views/Common/:**
- Purpose: Reusable UI components
- Contains: Button styles, text field wrappers, conditional views
- Key files: `ButtonStyles.swift`, `CubbitTextField.swift`, `IconButtonView.swift`

**DS3Lib/:**
- Purpose: Shared logic layer between app and extension
- Contains: Authentication, API client, managers, models, persistence
- Key responsibility: Enable code reuse and data sharing across targets

**DS3Lib/Models/:**
- Purpose: Domain models and data structures
- Contains: Codable structs and classes representing DS3 entities
- Pattern: Models are lightweight, use Codable for persistence
- Key files: `DS3Drive.swift`, `SyncAnchor.swift`, `Project.swift`

**DS3Lib/SharedData/:**
- Purpose: Centralized persistence with app group coordination
- Contains: UserDefaults CRUD operations via extension methods
- Pattern: Singleton with type-safe persistence methods
- Key responsibility: Data sync between main app and extension via app group container

**DS3Lib/Constants/:**
- Purpose: Configuration and constants
- Contains: DefaultSettings.swift (app UUIDs, timeouts, defaults), URLs.swift (API endpoints)
- Key usage: All layers reference these for consistency

**DS3Lib/Utils/:**
- Purpose: Helper extensions and utilities
- Contains: JWT parsing, date formatting, system info, notification handling
- Key files: `JWT.swift` (token parsing), `System.swift` (system utilities)

**Provider/:**
- Purpose: FileProvider extension for Finder integration
- Contains: Extension entry point, S3 operations, item enumeration
- Key responsibility: Translate FileProvider requests to S3 API calls
- Key files: `FileProviderExtension.swift` (extension delegate), `S3Lib.swift` (S3 wrapper)

## Key File Locations

**Entry Points:**
- `CubbitDS3Sync/CubbitDS3SyncApp.swift`: Main app entry point, window and state initialization
- `Provider/FileProviderExtension.swift`: FileProvider extension entry point

**Configuration:**
- `DS3Lib/Constants/DefaultSettings.swift`: App-wide defaults, UUIDs, timeouts
- `DS3Lib/Constants/URLs.swift`: API endpoint URLs
- `CubbitDS3Sync.xcodeproj/`: Xcode build settings

**Core Logic:**
- `DS3Lib/DS3Authentication.swift`: User authentication and token management
- `DS3Lib/DS3DriveManager.swift`: Drive collection and lifecycle
- `DS3Lib/DS3SDK.swift`: Cubbit API client
- `Provider/S3Lib.swift`: S3 operations and object manipulation

**Models:**
- `DS3Lib/Models/DS3Drive.swift`: Drive entity
- `DS3Lib/Models/SyncAnchor.swift`: Sync configuration (project/bucket/prefix)
- `DS3Lib/Models/AccountSession.swift`: Session tokens

**Persistence:**
- `DS3Lib/SharedData/SharedData.swift`: Base singleton, app group container access
- `DS3Lib/SharedData/SharedData+*.swift`: Entity-specific persistence methods

**UI - Authentication:**
- `CubbitDS3Sync/Views/Login/Views/LoginView.swift`: Login form
- `CubbitDS3Sync/Views/Login/ViewModels/LoginViewModel.swift`: Login state

**UI - Sync Setup:**
- `CubbitDS3Sync/Views/Sync/Views/SetupSyncView.swift`: Main sync setup container
- `CubbitDS3Sync/Views/Sync/ProjectSelection/Views/ProjectSelectionView.swift`: Step 1
- `CubbitDS3Sync/Views/Sync/SyncAnchorSelection/Views/SyncAnchorSelectionView.swift`: Step 2
- `CubbitDS3Sync/Views/Sync/SyncRecap/Views/SyncRecapView.swift`: Step 3

**UI - Main:**
- `CubbitDS3Sync/Views/Tray/Views/TrayMenuView.swift`: Menu bar interface
- `CubbitDS3Sync/Views/Preferences/Views/PreferencesView.swift`: Settings
- `CubbitDS3Sync/Views/ManageDrive/Views/ManageDS3DriveView.swift`: Drive management

## Naming Conventions

**Files:**
- SwiftUI Views: `*View.swift` (e.g., `LoginView.swift`, `TrayMenuView.swift`)
- ViewModels: `*ViewModel.swift` (e.g., `LoginViewModel.swift`, `DS3DriveViewModel.swift`)
- Managers: `*Manager.swift` (e.g., `DS3DriveManager.swift`, `AppStatusManager.swift`)
- Enumerations: Singular noun + optional "Error" (e.g., `AppStatus.swift`, `DS3AuthenticationError`)
- Extensions: `+Scope.swift` (e.g., `SharedData+account.swift`, `Notifications+Extensions.swift`)
- SDK/Client: `*SDK.swift` or `*Lib.swift` (e.g., `DS3SDK.swift`, `S3Lib.swift`)

**Directories:**
- Feature groups: Descriptive plural (e.g., `Views/`, `Models/`, `Constants/`)
- Sub-features: Feature name singular (e.g., `Login/`, `Sync/`, `Preferences/`)
- Layer separation: `Views/` for UI, `ViewModels/` for state
- Shared utilities: `Utils/`, `Constants/`, `SharedData/`

**Swift Code:**
- Classes: PascalCase (e.g., `DS3Authentication`, `FileProviderExtension`)
- Structs: PascalCase (e.g., `SyncAnchor`, `DS3Drive`)
- Enums: PascalCase (e.g., `AppStatus`, `DS3DriveStatus`)
- Properties/methods: camelCase (e.g., `syncAnchor`, `loadFromPersistence()`)
- Constants: UPPER_SNAKE_CASE in enums (e.g., `DefaultSettings.UserDefaultsKeys.tutorial`)

## Where to Add New Code

**New Feature:**
- Create directory: `CubbitDS3Sync/Views/[FeatureName]/`
- Create subdirectories: `Views/`, `ViewModels/`, optionally `Models/`
- Add view files: `[FeatureName]View.swift` in Views/
- Add view model: `[FeatureName]ViewModel.swift` in ViewModels/
- Register in app: Add window or navigation in `CubbitDS3SyncApp.swift`

**New Component/Module:**
- Reusable UI component: `CubbitDS3Sync/Views/Common/[ComponentName].swift`
- Manager class: `DS3Lib/[FeatureName]Manager.swift`
- Persistence helper: Add extension method to `DS3Lib/SharedData/SharedData+[Entity].swift`
- API method: Add to `DS3Lib/DS3SDK.swift`

**Utilities:**
- Extension helper: `DS3Lib/Utils/[Type]+Extensions.swift`
- Constant: Add to `DS3Lib/Constants/DefaultSettings.swift` or `URLs.swift`
- Shared model: `DS3Lib/Models/[EntityName].swift`

**File Provider Operations:**
- S3 operation: Add method to `Provider/S3Lib.swift`
- Item abstraction: Update `Provider/S3Item.swift` or `S3Item+Metadata.swift`
- Extension logic: Add to `Provider/FileProviderExtension.swift`

## Special Directories

**CubbitDS3Sync/Assets/:**
- Purpose: Image and color assets
- Contains: Asset catalogs for images, colors, icons
- Structure: `Assets.xcassets/` organized by category
- Committed: Yes (binary LFS-tracked files)
- Generated: No (manually managed via Xcode)

**CubbitDS3Sync/Preview Content/:**
- Purpose: Xcode SwiftUI previews
- Contains: Preview assets and mock data
- Generated: Yes (created by Xcode)
- Committed: Yes

**Provider/Provider.xcassets/:**
- Purpose: FileProvider extension assets
- Contains: App icon and custom symbols
- Structure: Icon sets organized by purpose
- Committed: Yes (binary LFS-tracked)
- Generated: No

**CubbitDS3Sync.xcodeproj/:**
- Purpose: Xcode project configuration
- Contains: Build settings, targets, schemes
- Committed: Yes (required for builds)
- Generated: Partially (user.xcworkspace can be generated)

---

*Structure analysis: 2026-03-11*
