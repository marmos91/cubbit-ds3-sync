import SwiftUI

struct TrayMenuView: View {
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow
    
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(AppStatusManager.self) var appStatusManager: AppStatusManager
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                ForEach(ds3DriveManager.drives, id: \.id) { drive in
                    TrayDriveRowView(driveId: drive.id, driveName: drive.name, driveStatus: drive.status)
                    
                    Divider()
                }
                
                TrayMenuItem(
                    title: self.canAddMoreDrives() ? NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive") : NSLocalizedString("You have reached the maximum number of Drives", comment: "Tray menu add new drive disabled"),
                    enabled: self.canAddMoreDrives()
                ) {
                    openWindow(id: "io.cubbit.CubbitDS3Sync.drive.new")
                }
                
                Divider()
                
                TrayMenuItem(
                    title: NSLocalizedString("Help", comment: "Tray menu help")
                ) {
                    openURL(URL(string: HelpURLs.baseURL)!)
                }
                
                Divider()
                
                TrayMenuItem(
                    title: NSLocalizedString("Preferences", comment: "Tray open preferences")
                ) {
                    openWindow(id: "io.cubbit.CubbitDS3Sync.preferences")
                }
                
                Divider()
                
                TrayMenuItem(
                    title: NSLocalizedString("Open web console ", comment: "Tray menu open console button")
                ) {
                    openURL(URL(string: ConsoleURLs.baseURL)!)
                }
                
                Divider()
                
                TrayMenuItem(
                    title: NSLocalizedString("Quit", comment: "Tray menu quit")
                ) {
                    NSApplication.shared.terminate(self)
                }
                
                Divider()
                
                TrayMenuFooterView(
                    status: appStatusManager.status.toString(),
                    version: DefaultSettings.appVersion
                )
            }
        }
        .frame(
            maxWidth: 400
        )
        .fixedSize(horizontal: true, vertical: true)
    }
    
    func canAddMoreDrives() -> Bool {
        return ds3DriveManager.drives.count < DefaultSettings.maxDrives
    }
}

#Preview {
    TrayMenuView()
        .environment(
            AppStatusManager.default()
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
}
