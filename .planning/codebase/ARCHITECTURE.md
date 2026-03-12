# Architecture

**Analysis Date:** 2026-03-11

## Pattern Overview

**Overall:** MVVM (Model-View-ViewModel) with layered architecture

**Key Characteristics:**
- SwiftUI-based UI layer with environment-injected state managers
- Observable state management using Swift's `@Observable` macro
- Separation of concerns: UI (Views/ViewModels), business logic (Managers), API communication (SDK), and persistence (SharedData)
- Dual-target architecture: main app (CubbitDS3Sync) and file provider extension (Provider)
- Shared library (DS3Lib) contains models, authentication, persistence, and utilities
- Distributed notifications for inter-process communication between app and extension

## Layers

**Presentation Layer:**
- Purpose: User interface and UI state management
- Location: `CubbitDS3Sync/Views/`
- Contains: SwiftUI Views, ViewModels
- Depends on: DS3Lib (models, managers), local state management
- Used by: SwiftUI application entry point

**Business Logic Layer:**
- Purpose: Core application state and business operations
- Location: `DS3Lib/` (managers and authentication)
- Contains: `DS3Authentication.swift`, `DS3DriveManager.swift`, `AppStatusManager.swift`, `DS3SDK.swift`
- Depends on: Models, SharedData (persistence), external APIs
- Used by: Presentation layer, Provider extension

**Data Access Layer:**
- Purpose: Persistence and shared state between app and extension
- Location: `DS3Lib/SharedData/`
- Contains: `SharedData.swift` with extensions for accounts, API keys, drives, sync anchors
- Depends on: Models, Foundation UserDefaults with app group containers
- Used by: All layers requiring persistent storage

**File Provider Extension Layer:**
- Purpose: Handle file synchronization with S3/DS3
- Location: `Provider/`
- Contains: `FileProviderExtension.swift`, `S3Lib.swift`, `S3Item.swift`, `S3Enumerator.swift`
- Depends on: DS3Lib models and persistence, Soto S3 SDK
- Used by: macOS Finder via FileProvider framework

**Models Layer:**
- Purpose: Domain models and data structures
- Location: `DS3Lib/Models/`
- Contains: `DS3Drive.swift`, `SyncAnchor.swift`, `AccountSession.swift`, `Project.swift`, `IAMUser.swift`, etc.
- Depends on: Foundation, Codable protocols
- Used by: All other layers

## Data Flow

**Authentication Flow:**

1. User enters credentials in `LoginView` (`.../Views/Login/Views/LoginView.swift`)
2. `LoginViewModel.login()` calls `DS3Authentication.login()` method
3. `DS3Authentication` sends challenge request to DS3 API
4. User signs challenge with private key (computed in `LoginViewModel`)
5. Signed challenge sent back to DS3 API
6. Upon success, session token and refresh token stored via `DS3Authentication.persist()`
7. Data persisted to shared app group container via `SharedData.account()` and `SharedData.accountSession()`
8. Authentication environment state updated, view navigates to main screen

**Drive Setup Flow:**

1. User navigates to `SetupSyncView` when no drives present
2. `SyncSetupViewModel` orchestrates multi-step wizard
3. Step 1: `ProjectSelectionView` - user selects project via `ProjectSelectionViewModel`
4. Step 2: `SyncAnchorSelectionView` - user navigates bucket structure via `SyncAnchorSelectionViewModel`
5. Step 3: `SyncRecapView` - user names drive and confirms setup
6. `DS3DriveManager.addDrive()` creates `DS3Drive` with `SyncAnchor`
7. Drive persisted via `SharedData.persistDS3Drive()`
8. API keys generated via `DS3SDK.loadOrCreateDS3APIKeys()`, persisted
9. FileProvider extension domain registered via `NSFileProviderManager.add(domain:)`
10. Extension notified of new drive, begins synchronization

**File Synchronization Flow (Extension):**

1. `FileProviderExtension` initialized with `NSFileProviderDomain`
2. Loads drive config and API keys from `SharedData.loadDS3DriveFromPersistence()`
3. Instantiates `S3Lib` with Soto S3 client configured with endpoint and credentials
4. Finder requests item metadata → `FileProviderExtension.item(for:)` calls `S3Lib.remoteS3Item()`
5. Extension enumerates changes via `FileProviderExtension.enumerator()` → `S3Enumerator`
6. S3Enumerator lists objects via `S3Lib.listS3Items()` → `S3.listObjectsV2()`
7. Downloads triggered via `S3Lib.downloadS3Item()` → streams to local filesystem
8. Uploads triggered via `S3Lib.uploadS3Item()` → streams from local filesystem
9. Completion notified via `NotificationManager.notifyDriveStatusChanged()`
10. `DS3DriveManager` receives distributed notification, updates UI state

**State Persistence:**

1. App group container: `/var/mobile/Containers/Shared/AppGroup/group.io.cubbit.CubbitDS3Sync/`
2. UserDefaults with app group identifier: `group.io.cubbit.CubbitDS3Sync`
3. Stored data: accounts, sessions, API keys, drives, sync anchors
4. Serialized via `Codable` protocol with `JSONEncoder`/`JSONDecoder`

## Key Abstractions

**DS3Authentication:**
- Purpose: Manages user authentication, token refresh, login/logout operations
- Examples: `DS3Lib/DS3Authentication.swift`
- Pattern: Observable singleton managing session lifecycle
- Responsibilities: Challenge generation, signature verification, token refresh, persistence

**DS3SDK:**
- Purpose: API client for Cubbit DS3 backend services
- Examples: `DS3Lib/DS3SDK.swift`
- Pattern: Final class wrapping URLSession with typed error handling
- Responsibilities: Projects API, API keys management, IAM token forging

**DS3DriveManager:**
- Purpose: Manages collection of synchronized drives
- Examples: `DS3Lib/DS3DriveManager.swift`
- Pattern: Observable singleton, listens to extension notifications
- Responsibilities: Drive lifecycle, syncing state tracking, FileProvider registration

**SharedData:**
- Purpose: Centralized persistence layer with app group access
- Examples: `DS3Lib/SharedData/SharedData.swift` and extensions
- Pattern: Singleton with extension methods per entity type
- Responsibilities: UserDefaults CRUD operations, app group coordination

**S3Lib:**
- Purpose: S3/DS3 object storage abstraction
- Examples: `Provider/S3Lib.swift`
- Pattern: Wrapper around Soto S3 client with FileProvider integration
- Responsibilities: List operations, downloads, uploads, metadata resolution

**SyncSetupViewModel:**
- Purpose: Orchestrates multi-step drive configuration wizard
- Examples: `CubbitDS3Sync/Views/Sync/ViewModels/SyncViewModel.swift`
- Pattern: Observable state machine for setup steps
- Responsibilities: Step navigation, project/anchor selection, drive creation

## Entry Points

**Main App:**
- Location: `CubbitDS3Sync/CubbitDS3SyncApp.swift`
- Triggers: macOS app launch
- Responsibilities:
  - Initializes state managers (`DS3Authentication`, `DS3DriveManager`, `AppStatusManager`)
  - Creates multiple windows: login/main, manage drive, preferences, add drive, tray menu
  - Routes UI based on authentication state and drive existence
  - Registers app as login item

**File Provider Extension:**
- Location: `Provider/FileProviderExtension.swift`
- Triggers: FileProvider framework via Finder/system
- Responsibilities:
  - Loads persisted drive and API key configuration
  - Initializes S3 client with endpoint and credentials
  - Implements FileProvider delegation methods for item metadata and enumeration

**Tray Menu:**
- Location: `CubbitDS3Sync/Views/Tray/Views/TrayMenuView.swift`
- Triggers: macOS menu bar extra
- Responsibilities:
  - Displays drive status and sync state
  - Provides quick actions: add drive, preferences, help, quit
  - Observes `AppStatusManager.status` for real-time status updates

## Error Handling

**Strategy:** Typed errors at each layer with localized error messages

**Patterns:**

- `DS3AuthenticationError`: Login, token, 2FA-specific errors with descriptive messages
  - Example: `.missing2FA`, `.tokenExpired`, `.serverError`
  - Location: `DS3Lib/DS3Authentication.swift`

- `DS3SDKError`: API communication errors
  - Example: `.invalidURL()`, `.jsonConversion`, `.serverError`
  - Location: `DS3Lib/DS3SDK.swift`

- `FileProviderExtensionError`: Extension-specific failures
  - Example: `.disabled` when extension not properly initialized
  - Location: `Provider/FileProviderExtension+Errors.swift`

- `SharedData.SharedDataError`: Persistence errors
  - Example: `.cannotAccessAppGroup`, `.apiKeyNotFound`
  - Location: `DS3Lib/SharedData/SharedData.swift`

- `DS3DriveManagerError`: Drive management failures
  - Example: `.driveNotFound`, `.cannotLoadDrives`
  - Location: `DS3Lib/DS3DriveManager.swift`

## Cross-Cutting Concerns

**Logging:**
- Framework: OS Log (`os.log`)
- Pattern: Each class creates Logger with subsystem and category
- Example: `Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "MainApp")`
- Used for: Debugging, error tracking, operation flow visibility

**Validation:**
- URL validation: `.invalidURL()` errors in API clients
- Token validation: Refresh check before API calls via `DS3Authentication.refreshIfNeeded()`
- State validation: Guard statements for required data before operations

**Authentication:**
- Challenge-response: Private key signing of server-issued challenges
- Token refresh: Automatic refresh on 401 responses before retry
- 2FA support: Optional two-factor authentication with separate `tfaCode` parameter
- Persistence: Encoded session stored in app group UserDefaults

**Notifications:**
- Distributed notifications for app-extension communication
- Name: `.driveStatusChanged` (defined in extensions to Notification.Name)
- Object: JSON-encoded `DS3DriveStatusChange` struct
- Used: Extension notifies app of sync state changes, app updates UI

---

*Architecture analysis: 2026-03-11*
