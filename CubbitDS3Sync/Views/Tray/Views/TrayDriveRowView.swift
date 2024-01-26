import SwiftUI

struct TrayDriveRowView: View {
    var driveId: UUID
    var driveName: String
    var driveStatus: DS3DriveStatus
    var driveStats: String
    
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    
    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            HStack {
                switch self.driveStatus {
                case .sync:
                    Image(.driveSyncIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(.horizontal, 8)
                case .pause:
                    Image(.drivePlayIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(.horizontal, 8)
                case .idle:
                    Image(.driveIdleIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(.horizontal, 8)
                case .error:
                    Image(.driveErrorIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(.horizontal, 8)
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(driveName)
                        .font(.custom("Nunito", size: 14))
                        .padding(.bottom, 2)
                    
                    Text(ds3DriveManager.driveSyncAnchorString(driveId: driveId) ?? "")
                        .font(.custom("Nunito", size: 12))
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(.darkWhite))
                    
                    Text(self.driveStats)
                        .font(.custom("Nunito", size: 12))
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(.darkWhite))
                }
                .padding()
                
                Spacer()
                
                Menu {        
                    Button("Disconnect") {
                        Task {
                            do {
                                try await self.ds3DriveManager.disconnect(driveWithId: self.driveId)
                            } catch {
                                // TODO: Show error
                                print("Error disconnecting drive: \(error)")
                            }
                        }
                    }
                    
                    Button("View in Finder") {
                        Task {
                            try await self.ds3DriveManager.openFinder(forDriveId: self.driveId)
                        }
                    }
                    
                    Button("View in web console") {
                        if let consoleURL = ds3DriveManager.consoleURL(driveId: self.driveId) {
                            openURL(URL(string: consoleURL)!)
                        }
                    }
                    
                    Button("Manage") {
                        openWindow(id: "io.cubbit.CubbitDS3Sync.drive.manage", value: self.driveId)
                    }
                    
                    Button("Refresh") {
                        Task {
                            do {
                                try await self.ds3DriveManager.reEnumerate(driveId: self.driveId)
                            } catch {
                                // TODO: Show error
                                print("Error refreshing drive: \(error)")
                            }
                        }
                    }
                } label: {
                    Image(.settingsIcon)
                        .resizable()
                        .frame(width: 20, height: 20, alignment: .top)
                        .onChange(of: isHover) {
                            DispatchQueue.main.async {
                                if isHover {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onTapGesture {
            Task {
                try await self.ds3DriveManager.openFinder(forDriveId: self.driveId)
            }
        }
        .onHover{ hovering in
            isHover = hovering
        }
        .padding(.horizontal, 16)
        .background(
            Color(isHover ? .hover : .darkMainStandard)
        )
        
        // TODO: Add file status?
    }
}

#Preview {
    VStack(spacing: 0) {
        TrayDriveRowView(
            driveId: UUID(),
            driveName: "Test",
            driveStatus: .sync,
            driveStats: "Updated 10 minutes ago"
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
        
        Divider()
        
        TrayDriveRowView(
            driveId: UUID(),
            driveName: "Test 2",
            driveStatus: .idle,
            driveStats: "10 MB/s"
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
    }
}
