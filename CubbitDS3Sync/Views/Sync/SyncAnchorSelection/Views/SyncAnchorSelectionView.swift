import SwiftUI

struct SyncAnchorSelectionView: View {
    @State var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    var selectedBucket: String? = nil
    
    var onSyncAnchorSelected: ((SyncAnchor) -> Void)?
    var onBack: (() -> Void)?
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            HStack(spacing: 0) {
                BucketSelectionSidebarView()
                    .environment(syncAnchorSelectionViewModel)
                
                VStack(spacing: 0) {
                    SyncAnchorSelectorView()
                        .environment(syncAnchorSelectionViewModel)
                    
                    BucketSelectionFooterView()
                        .onBack {
                            onBack?()
                        }
                        .onContinue {
                            if let syncAnchor = syncAnchorSelectionViewModel.getSelectedSyncAnchor() {
                                onSyncAnchorSelected?(syncAnchor)
                            }
                        }
                        .environment(syncAnchorSelectionViewModel)
                }
            }
        }
    }
    
    func onSyncAnchorSelected(_ action: @escaping (SyncAnchor) -> Void) -> Self {
        var copy = self
        copy.onSyncAnchorSelected = action
        return copy
    }
    
    func onBack(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onBack = action
        return copy
    }
}

#Preview {
    // TODO: Remove hardcoded values
    SyncAnchorSelectionView(
        syncAnchorSelectionViewModel:SyncAnchorSelectionViewModel(
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
    .frame(
        minWidth: 800,
        maxWidth: 800,
        minHeight: 480,
        maxHeight: 480
    )
}
