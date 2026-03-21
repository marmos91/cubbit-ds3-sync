import SwiftUI
import DS3Lib

struct SyncRecapView: View {
    var syncRecapViewModel: SyncRecapViewModel
    var onBack: (() -> Void)?
    var onComplete: ((DS3Drive) -> Void)?
    
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
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
            syncAnchor: PreviewData.syncAnchor
        )
    )
    .frame(
        minWidth: 800,
        maxWidth: 800,
        minHeight: 480,
        maxHeight: 480
    )
}
