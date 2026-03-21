import SwiftUI
import DS3Lib

struct SyncAnchorSelectionView: View {
    @State var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    var selectedBucket: String?
    
    var onSyncAnchorSelected: ((SyncAnchor) -> Void)?
    var onBack: (() -> Void)?
    
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
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
    SyncAnchorSelectionView(
        syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel(
            project: PreviewData.project,
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
