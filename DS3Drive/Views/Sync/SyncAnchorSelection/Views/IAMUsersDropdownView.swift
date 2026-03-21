import SwiftUI
import DS3Lib

struct IAMUsersDropdownView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var iconName: ImageResource
    
    var body: some View {
        Menu {
            ForEach(syncAnchorSelectionViewModel.project.users, id: \.id) { option in
                Button {
                    let viewModel = syncAnchorSelectionViewModel
                    Task {
                        await viewModel.selectIAMUser(withID: option.id)
                    }
                } label: {
                    Text(option.username)
                        .font(DS3Typography.body)
                }
            }
        } label: {
            HStack {
                Image(iconName)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .imageScale(.small)
                
                Text(syncAnchorSelectionViewModel.selectedIAMUser?.username ?? "No user selected")
                    .padding(.trailing, 5)
                    .font(DS3Typography.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: 32)
        }
        .menuStyle(.borderlessButton)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(lineWidth: 1)
                .fill(Color(nsColor: .separatorColor))
                .frame(maxWidth: .infinity, maxHeight: 32)
        )
    }
}

#Preview {
    IAMUsersDropdownView(
        iconName: .userIcon
    )
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
    .padding()
}
