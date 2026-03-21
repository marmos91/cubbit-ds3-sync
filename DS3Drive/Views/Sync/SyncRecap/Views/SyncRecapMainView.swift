import SwiftUI
import DS3Lib

struct SyncRecapMainView: View {
    @Environment(SyncRecapViewModel.self) var syncRecapViewModel: SyncRecapViewModel
    
    var onBack: (() -> Void)?
    var onComplete: ((DS3Drive) -> Void)?
    var shouldDisplayBack: Bool = true
    
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                SyncRecapNameSelectionView()
                    .onComplete {
                        if let ds3Drive = syncRecapViewModel.getDS3Drive() {
                            onComplete?(ds3Drive)
                        }
                    }
                    .environment(syncRecapViewModel)
                
                SyncRecapFooterView(
                    shouldDisplayBack: shouldDisplayBack
                )
                .onBack {
                    onBack?()
                }
                .onComplete {
                    if let ds3Drive = syncRecapViewModel.getDS3Drive() {
                        onComplete?(ds3Drive)
                    }
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
    SyncRecapMainView()
        .environment(
            SyncRecapViewModel(
                syncAnchor: PreviewData.syncAnchor
            )
        )
}
