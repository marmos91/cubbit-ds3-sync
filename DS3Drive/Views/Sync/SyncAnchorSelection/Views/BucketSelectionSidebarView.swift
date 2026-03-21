import SwiftUI
import DS3Lib

struct BucketSelectionSidebarView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

                VStack(alignment: .leading) {
                    Text("Project:")
                        .font(DS3Typography.caption)

                    Text(syncAnchorSelectionViewModel.project.name)
                        .font(DS3Typography.headline)
                        .fontWeight(.bold)
                        .padding(.bottom, 5.0)

                    IAMUsersDropdownView(
                        iconName: .userIcon
                    )
                    .environment(syncAnchorSelectionViewModel)

                    Text("Select an IAM user & bucket to continue. You can manage buckets and IAM users from the [Cubbit DS3 Console](https://console.cubbit.eu)")
                        .font(DS3Typography.body)
                        .padding(.vertical)
                }
                .padding(20.0)
        }
        .border(width: 1, edges: [.trailing], color: Color(nsColor: .separatorColor))
        .frame(width: 240)
    }
}

#Preview {
    BucketSelectionSidebarView()
        .environment(
            SyncAnchorSelectionViewModel(
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
}
