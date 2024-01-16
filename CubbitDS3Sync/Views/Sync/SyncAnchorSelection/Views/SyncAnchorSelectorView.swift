import SwiftUI

struct SyncAnchorSelectorView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            if syncAnchorSelectionModel.loading {
                LoadingView()
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack {
                        BucketSelectionColumn()
                            .environment(syncAnchorSelectionModel)
                        
                        if syncAnchorSelectionModel.shouldDisplayObjectNavigator() {
                            DS3ObjectNavigatorView()
                                .environment(syncAnchorSelectionModel)
                        }
                    }
                }
            }
        }
        .task {
            await syncAnchorSelectionModel.loadBuckets()
        }
    }
}

#Preview {
    // TODO: Remove hardcoded values
    SyncAnchorSelectorView()
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
