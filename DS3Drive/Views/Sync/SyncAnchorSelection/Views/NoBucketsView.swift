import SwiftUI
import DS3Lib

struct NoBucketsView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionModel: SyncAnchorSelectionViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 16.0) {
                Image(.bucketIcon)
                
                Text("You haven't created any bucket yet, create your first bucket on [the console](https://console.cubbit.eu/) and then come back here to synchronize it.")
                    .font(DS3Typography.body)
                    .multilineTextAlignment(.center)
                
                Button("Refresh") {
                    let viewModel = syncAnchorSelectionModel
                    Task {
                        await viewModel.loadBuckets()
                    }
                }
                .pointingHandCursor()
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
    NoBucketsView()
        .environment(
            SyncAnchorSelectionViewModel(
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
        .padding()
}
