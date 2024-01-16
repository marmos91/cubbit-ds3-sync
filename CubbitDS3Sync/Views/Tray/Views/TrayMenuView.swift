import SwiftUI

struct TrayDriveSectionView: View {
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(ds3DriveManager.drives, id: \.self) { drive in
                TrayDriveRowView(drive: drive)
                
                Divider()
            }
        }
    }
}

struct TrayMenuView: View {
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow
    @Environment(DS3DriveManager.self) var ds3DriveManager
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                TrayDriveSectionView()
                    .environment(ds3DriveManager)
                
                TrayMenuItem(
                    title: NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive")
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
                
                TrayMenuFooterView(version: DefaultSettings.appVersion)
            }
        }
        .frame(
            maxWidth: 400
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

#Preview {
    TrayMenuView()
        .environment(DS3DriveManager())
}
