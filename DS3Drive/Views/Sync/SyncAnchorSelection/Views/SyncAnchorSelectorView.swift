import SwiftUI
import DS3Lib

struct SyncAnchorSelectorView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            
            if syncAnchorSelectionModel.loading {
                LoadingView()
            } else {
                if self.shouldDisplayError() {
                    BucketErrorView()
                        .environment(syncAnchorSelectionModel)
                        .padding(100)
                } else {
                    if syncAnchorSelectionModel.buckets.isEmpty {
                        NoBucketsView()
                            .environment(syncAnchorSelectionModel)
                            .padding(100)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack {
                                BucketSelectionColumn()
                                    .environment(syncAnchorSelectionModel)
                                
                                if syncAnchorSelectionModel.shouldDisplayObjectNavigator() {
                                    Divider()
                                    
                                    DS3ObjectNavigatorView()
                                        .environment(syncAnchorSelectionModel)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            await syncAnchorSelectionModel.loadBuckets()
        }
    }
    
    func shouldDisplayError() -> Bool {
        return syncAnchorSelectionModel.error != nil || syncAnchorSelectionModel.authenticationError != nil
    }
}

#Preview {
    SyncAnchorSelectorView()
        .environment(
            SyncAnchorSelectionViewModel(
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
}
