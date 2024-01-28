import SwiftUI
import os.log

@main
struct ds3syncApp: App {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "MainApp")
    
    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown
    @AppStorage(DefaultSettings.UserDefaultsKeys.loginItemSet) var loginItemSet: Bool = DefaultSettings.loginItemSet
    
    @State var ds3Authentication: DS3Authentication = DS3Authentication.loadFromPersistenceOrCreateNew()
    @State var appStatusManager: AppStatusManager = AppStatusManager.default()
    @State var ds3DriveManager: DS3DriveManager = DS3DriveManager(appStatusManager: AppStatusManager.default())
    
    // TODO: Hide tray menu when not logged in
    @State var trayMenuVisible: Bool = true
    
    var body: some Scene {
        // MARK: - Main view
        
        WindowGroup {
            if ds3Authentication.isLogged {
                if !tutorialShown {
                    TutorialView()
                } else {
                    // Note: if no drives are present, show the setup view
                    if ds3DriveManager.drives.count == 0 {
                        SetupSyncView()
                            .environment(ds3Authentication)
                            .environment(ds3DriveManager)
                    }
                }
            } else {
                LoginView()
                    .environment(ds3Authentication)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Manage drive
        
        WindowGroup(id: "io.cubbit.CubbitDS3Sync.drive.manage", for: UUID.self) { $ds3DriveId in
            if ds3DriveId != nil {
                if let drive = ds3DriveManager.driveWithID(ds3DriveId!) {
                    ManageDS3DriveView(ds3Drive: drive)
                        .environment(ds3DriveManager)
                }
                
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Preferences
        
        Window("Preferences", id: "io.cubbit.CubbitDS3Sync.preferences") {
            if ds3Authentication.account != nil {
                PreferencesView(
                    preferencesViewModel: PreferencesViewModel(
                        account: ds3Authentication.account!
                    )
                )
                .environment(ds3DriveManager)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Add new drive
        
        Window("Add new Drive", id: "io.cubbit.CubbitDS3Sync.drive.new") {
            SetupSyncView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
#if os(macOS)
        // MARK: - Tray Menu
        
        MenuBarExtra(isInserted: $trayMenuVisible) {
            TrayMenuView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .environment(appStatusManager)
        } label: {
            switch appStatusManager.status {
            case .idle:
                Image(.trayIcon)
            case .syncing:
                Image(.trayIconSync)
            case .error:
                Image(.trayIconError)
            case .info:
                Image(.trayIconInfo)
            case .offline:
                Image(.trayIconOffline)
            }
        }
        .menuBarExtraStyle(.window)
        .commandsRemoved()
#endif
    }
    
    init() {
        if !loginItemSet {
            do {
                try setLoginItem(true)
            } catch {
                self.logger.error("An error occurred while setting the app as login item: \(error)")
            }
        }
    }
}
