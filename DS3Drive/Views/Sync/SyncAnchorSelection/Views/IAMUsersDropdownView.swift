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
                        try await viewModel.selectIAMUser(withID: option.id)
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
            project: PreviewData.project,
            authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
        )
    )
    .padding()
}
