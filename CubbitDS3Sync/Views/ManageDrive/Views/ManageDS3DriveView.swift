import SwiftUI

struct ManageDS3DriveView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(DS3DriveManager.self) var ds3DriveManager

    var ds3Drive: DS3Drive
    
    var body: some View {
        SyncRecapMainView(shouldDisplayBack: false)
            .onComplete { ds3Drive in
                Task {
                    do {
                        try await self.ds3DriveManager.update(drive: ds3Drive)
                    } catch {
                        print("Error updating drive: \(error)")
                    }
                    
                    dismiss()
                }
            }
            .environment(
                SyncRecapViewModel(
                    syncAnchor: ds3Drive.syncAnchor,
                    driveName: ds3Drive.name,
                    driveId: ds3Drive.id
                )
            )
            .frame(
                minWidth: 500,
                maxWidth: 500,
                minHeight: 400,
                maxHeight: 400
            )
    }
}

#Preview {
    ManageDS3DriveView(
        ds3Drive: DS3Drive(
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
            )
        )
    )
    .environment(
        DS3DriveManager(appStatusManager: AppStatusManager.default())
    )
}
