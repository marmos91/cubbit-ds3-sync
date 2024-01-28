import SwiftUI

struct TrayDriveRowView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    
    @State var driveViewModel: DS3DriveViewModel
    
    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            HStack {
                switch self.driveViewModel.driveStatus {
                case .sync, .indexing:
                    Image(.driveSyncIcon)
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
                    Text(self.driveViewModel.drive.name)
                        .font(.custom("Nunito", size: 14))
                        .padding(.bottom, 2)
                    
                    Text(self.driveViewModel.syncAnchorString())
                        .font(.custom("Nunito", size: 12))
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(.darkWhite))
                    
                    Text(self.formatDriveStatusString())
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
                                try await self.ds3DriveManager.disconnect(
                                    driveWithId: self.driveViewModel.drive.id
                                )
                            } catch {
                                // TODO: Show error
                                print("Error disconnecting drive: \(error)")
                            }
                        }
                    }
                    
                    Button("View in Finder") {
                        Task {
                            try await self.driveViewModel.openFinder()
                        }
                    }
                    
                    Button("View in web console") {
                        if let consoleURL = self.driveViewModel.consoleURL() {
                            openURL(consoleURL)
                        }
                    }
                    
                    Button("Manage") {
                        openWindow(id: "io.cubbit.CubbitDS3Sync.drive.manage", value: self.driveViewModel.drive.id)
                    }
                    
                    Button("Refresh") {
                        Task {
                            do {
                                try await self.driveViewModel.reEnumerate()
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
                try await self.driveViewModel.openFinder()
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
    
    func formatDriveStatusString() -> String {
        switch self.driveViewModel.driveStatus {
        case .indexing:
            return "Indexing..."
        case .error:
            return "Error"
        default:
            return self.driveViewModel.driveStats.toString()
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        TrayDriveRowView(
            driveViewModel: DS3DriveViewModel(
                drive: DS3Drive(
                    id: UUID(),
                    name: "My drive",
                    syncAnchor: SyncAnchor(
                        project: Project(
                            id: UUID().uuidString,
                            name: "My Project",
                            description: "My project description",
                            email: "test@cubbit.io",
                            createdAt: "Now",
                            bannedAt: nil,
                            imageUrl: nil,
                            tenantId: UUID().uuidString,
                            rootAccountEmail: nil,
                            users: [
                                IAMUser(
                                    id: "root",
                                    username: "Root",
                                    isRoot: true
                                )
                            ]
                        ),
                        IAMUser: IAMUser(
                            id: "root",
                            username: "Root",
                            isRoot: true
                        ),
                        bucket: Bucket(name: "Personal"),
                        prefix: "folder1"
                    )
                )
            )
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
        
        Divider()
        
        TrayDriveRowView(
            driveViewModel: DS3DriveViewModel(
                drive: DS3Drive(
                    id: UUID(),
                    name: "My drive 2",
                    syncAnchor: SyncAnchor(
                        project: Project(
                            id: UUID().uuidString,
                            name: "My Project",
                            description: "My project description",
                            email: "test@cubbit.io",
                            createdAt: "Now",
                            bannedAt: nil,
                            imageUrl: nil,
                            tenantId: UUID().uuidString,
                            rootAccountEmail: nil,
                            users: [
                                IAMUser(
                                    id: "root",
                                    username: "Root",
                                    isRoot: true
                                )
                            ]
                        ),
                        IAMUser: IAMUser(
                            id: "root",
                            username: "Root",
                            isRoot: true
                        ),
                        bucket: Bucket(name: "Personal"),
                        prefix: "folder1"
                    )
                )
            )
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
    }
}
