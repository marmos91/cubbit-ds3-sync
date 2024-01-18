import SwiftUI

struct BucketErrorView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 16.0) {
                Image(.bucketIcon)
                
                if syncAnchorSelectionViewModel.authenticationError != nil {
                    Text(syncAnchorSelectionViewModel.authenticationError?.localizedDescription ?? "No error")
                        .font(.custom("Nunito", size: 14))
                        .multilineTextAlignment(.center)
                    
                    Button("Logout") {
                        Task {
                            try self.syncAnchorSelectionViewModel.authentication.logout()
                        }
                    }
                }
                
                if syncAnchorSelectionViewModel.error != nil {
                    Text(syncAnchorSelectionViewModel.error?.localizedDescription ?? "No error")
                        .font(.custom("Nunito", size: 14))
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        Task {
                            await self.syncAnchorSelectionViewModel.loadBuckets()
                        }
                    }
                }
            }
            .padding()
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.errorBorder), lineWidth: 1)
            }
            
            Spacer()
        }
    }
}

#Preview {
    BucketErrorView()
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
