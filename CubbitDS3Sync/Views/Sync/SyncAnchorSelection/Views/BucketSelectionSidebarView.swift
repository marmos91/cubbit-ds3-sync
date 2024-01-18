import SwiftUI

struct BucketSelectionSidebarView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        ZStack {
            Color(.darkMainStandard)
                .ignoresSafeArea()

                VStack(alignment: .leading) {
                    Text("Project:")
                        .font(.custom("Nunito", size: 12))
                    
                    Text(syncAnchorSelectionViewModel.project.name)
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.bold)
                        .padding(.bottom, 5.0)
                    
                    IAMUsersDropdownView(
                        iconName: .userIcon
                    )
                    .environment(syncAnchorSelectionViewModel)
                    
                    Text("Select an IAM user & bucket to continue. You can manage buckets and IAM users from the [Cubbit DS3 Console](https://console.cubbit.eu)")
                        .font(.custom("Nunito", size: 14))
                        .padding(.vertical)
                }
                .padding(20.0)
        }
        .border(width: 1, edges: [.trailing], color: .darkMainBorder)
        .frame(width: 240)
    }
}

#Preview {
    // TODO: Remove hardcoded values
    BucketSelectionSidebarView()
        .environment(
            SyncAnchorSelectionViewModel(
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
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
}
