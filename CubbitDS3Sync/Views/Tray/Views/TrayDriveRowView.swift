import SwiftUI

struct TrayDriveRowView: View {
    var drive: DS3Drive
    
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    
    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            HStack {
                switch drive.status {
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
                    Text(drive.name)
                        .font(.custom("Nunito", size: 14))
                        .padding(.bottom, 2)
                    
                    Text(self.formatDriveName())
                        .font(.custom("Nunito", size: 12))
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(.darkWhite))
                    
                    Text(self.formatDriveStats())
                        .font(.custom("Nunito", size: 12))
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(.darkWhite))
                }
                .padding()
                
                Spacer()
                
                Menu {        
                    Button("Disconnect") {
                        self.ds3DriveManager.disconnect(driveWithId: self.drive.id)
                    }
                    
                    Button("View in Finder") {
                        self.ds3DriveManager.openFinder(forDrive: self.drive)
                    }
                    
                    Button("View in web console") {
                        openURL(URL(string: self.consoleURL())!)
                    }
                    
                    Button("Manage") {
                        openWindow(id: "io.cubbit.CubbitDS3Sync.drive.manage", value: self.drive)
                    }
                    
                    Button("Refresh") {
                        self.ds3DriveManager.reEnumerate(drive: self.drive)
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
        .onHover{ hovering in
            isHover = hovering
        }
        .padding(.horizontal, 16)
        .background(
            Color(isHover ? .hover : .sidebarBackground)
        )
        
        // TODO: Add file status?
    }
                                
    func consoleURL() -> String {
        var url =  "\(ConsoleURLs.projectsURL)/\(self.drive.syncAnchor.project.id)/buckets/\(self.drive.syncAnchor.bucket.name)"
        
        if self.drive.syncAnchor.prefix != nil {
            url += "/\(self.drive.syncAnchor.prefix!)"
        }
        
        return url
    }
    
    func formatDriveName() -> String {
        var name = drive.syncAnchor.project.name
        
        if drive.syncAnchor.prefix != nil {
            name += "/\(drive.syncAnchor.prefix!)"
        }
        
        return name
    }
                          
    func formatDriveStats() -> String {
        // TODO: Format correct stats
        return "<Drive Stats>"
//        return "1 file, 2.1 GB, 10 MB/s, about 20 minutes"
    }
}

#Preview {
    VStack(spacing: 0) {
        TrayDriveRowView(
            drive: DS3Drive(
                id: UUID(),
                name: "{Drive name}",
                syncAnchor: SyncAnchor(
                    project: Project(
                        id: "63611af7-0db6-465a-b2f8-2791200b69de",
                        name: "Moschet personal",
                        description: "Moschet personal project",
                        email: "Personal@cubbit.io",
                        createdAt: "2023-01-27T15:01:02.904417Z",
                        bannedAt: nil,
                        imageUrl: nil,
                        tenantId: "00000000-0000-0000-0000-000000000000",
                        rootAccountEmail: nil,
                        users: [
                            IAMUser(
                                id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
                                username: "ROOT",
                                isRoot: true
                            )
                        ]
                    ),
                    IAMUser: IAMUser(
                        id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
                        username: "ROOT",
                        isRoot: true
                    ),
                    bucket: Bucket(name: "{Bucket name}"),
                    prefix: "Personal"
                ),
                status: .sync
            )
        )
        .environment(DS3DriveManager())
        
        Divider()
        
        TrayDriveRowView(
            drive: DS3Drive(
                id: UUID(),
                name: "{Drive name}",
                syncAnchor: SyncAnchor(
                    project: Project(
                        id: "63611af7-0db6-465a-b2f8-2791200b69de",
                        name: "Moschet personal",
                        description: "Moschet personal project",
                        email: "Personal@cubbit.io",
                        createdAt: "2023-01-27T15:01:02.904417Z",
                        bannedAt: nil,
                        imageUrl: nil,
                        tenantId: "00000000-0000-0000-0000-000000000000",
                        rootAccountEmail: nil,
                        users: [
                            IAMUser(
                                id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
                                username: "ROOT",
                                isRoot: true
                            )
                        ]
                    ),
                    IAMUser: IAMUser(
                        id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
                        username: "ROOT",
                        isRoot: true
                    ),
                    bucket: Bucket(name: "{Bucket name}"),
                    prefix: "Cubbit"
                ),
                status: .sync
            )
        )
        .environment(DS3DriveManager())
    }
}
