import SwiftUI

@main
struct ds3syncApp: App {
    @State var showTrayIcon: Bool = true
    @State var ds3Authentication: DS3Authentication = DS3Authentication.loadFromPersistenceOrCreateNew()
    var ds3DriveManager = DS3DriveManager()
    
    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown
    
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
        
        WindowGroup(id: "io.cubbit.CubbitDS3Sync.drive.manage", for: DS3Drive.self) { $ds3Drive in
            if ds3Drive != nil {
               ManageDS3DriveView(ds3Drive: ds3Drive!)
                    .environment(ds3DriveManager)
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
        
        // MARK: - Tray Menu

        MenuBarExtra(isInserted: $showTrayIcon) {
            TrayMenuView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
        } label: {
            Image(.trayIcon)
        }
        .menuBarExtraStyle(.window)
        .commandsRemoved()
    }
}
