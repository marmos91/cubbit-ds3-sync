import SwiftUI

struct BucketSelectionColumn: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(syncAnchorSelectionViewModel.buckets, id: \.name) { bucket in
                ColumnSelectionRowView(
                    icon: .bucketIcon,
                    name: bucket.name,
                    selected: syncAnchorSelectionViewModel.selectedBucket == bucket
                ) {
                    Task {
                        await syncAnchorSelectionViewModel.selectBucket(withName: bucket.name)
                    }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10.0)
        .frame(maxHeight: .infinity, alignment: .top)
        .border(width: 1, edges: [.trailing], color: Color(.textFieldBorder))
    }
}
#Preview {
    // TODO: Remove hardcoded values
    BucketSelectionColumn()
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
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew(),
                buckets: [
                    Bucket(name: "bucket1"),
                    Bucket(name: "bucket2")
                ]
            )
        )
        .frame(width: 300, height: 300)
}
