import SwiftUI
import DS3Lib

struct BucketErrorView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 16.0) {
                Image(.bucketIcon)
                
                if syncAnchorSelectionViewModel.authenticationError != nil {
                    Text(syncAnchorSelectionViewModel.authenticationError?.localizedDescription ?? "No error")
                        .font(DS3Typography.body)
                        .multilineTextAlignment(.center)
                    
                    Button("Logout") {
                        syncAnchorSelectionViewModel.authentication.logout()
                    }
                    .pointingHandCursor()
                }

                if syncAnchorSelectionViewModel.error != nil {
                    Text(syncAnchorSelectionViewModel.error?.localizedDescription ?? "No error")
                        .font(DS3Typography.body)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        let viewModel = syncAnchorSelectionViewModel
                        Task {
                            await viewModel.loadBuckets()
                        }
                    }
                    .pointingHandCursor()
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
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
        .padding()
}
