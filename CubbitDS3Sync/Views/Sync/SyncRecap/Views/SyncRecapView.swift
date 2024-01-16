import SwiftUI

struct SyncRecapView: View {
    var syncRecapViewModel: SyncRecapViewModel
    var onBack: (() -> Void)?
    var onComplete: ((DS3Drive) -> Void)?
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            HStack(spacing: 0) {
                SyncRecapSidebarView()
                
                SyncRecapMainView()
                    .onBack {
                        onBack?()
                    }
                    .onComplete {
                        onComplete?($0)
                    }
                    .environment(syncRecapViewModel)
            }
        }
    }
    
    func onBack(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onBack = action
        return copy
    }
    
    func onComplete(_ action: @escaping (DS3Drive) -> Void) -> Self {
        var copy = self
        copy.onComplete = action
        return copy
    }
}

#Preview {
    SyncRecapView(
        syncRecapViewModel: SyncRecapViewModel(
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
                bucket: Bucket(name: "moschet-personal"),
                prefix: "Cubbit"
            )
        )
    )
    .frame(
        minWidth: 800,
        maxWidth: 800,
        minHeight: 480,
        maxHeight: 480
    )
}
