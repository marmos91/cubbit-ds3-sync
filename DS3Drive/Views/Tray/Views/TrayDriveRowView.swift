import SwiftUI
import os.log
import DS3Lib

struct TrayDriveRowView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
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
                        let manager = ds3DriveManager
                        let driveId = driveViewModel.drive.id
                        Task {
                            do {
                                try await manager.disconnect(
                                    driveWithId: driveId
                                )
                            } catch {
                                // TODO: Show error
                                logger.error("Error disconnecting drive: \(error.localizedDescription)")
                            }
                        }
                    }

                    Button("View in Finder") {
                        let viewModel = driveViewModel
                        Task {
                            try await viewModel.openFinder()
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
                        let viewModel = driveViewModel
                        Task {
                            do {
                                try await viewModel.reEnumerate()
                            } catch {
                                // TODO: Show error
                                logger.error("Error refreshing drive: \(error.localizedDescription)")
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
            let viewModel = driveViewModel
            Task {
                try await viewModel.openFinder()
            }
        }
        .onHover { hovering in
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
