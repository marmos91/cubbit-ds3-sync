import SwiftUI
import DS3Lib

struct SyncRecapFooterView: View {
    @Environment(SyncRecapViewModel.self) var syncRecapViewModel: SyncRecapViewModel

    var shouldDisplayBack: Bool = true
    var onBack: (() -> Void)?
    var onComplete: (() -> Void)?
    
    var body: some View {
        HStack {
            if shouldDisplayBack {
                IconButtonView(iconName: .arrowWestIcon) {
                    onBack?()
                }.padding(.horizontal)
            }
            
            Spacer()
            Button(NSLocalizedString("Sync", comment: "Complete sync button")) {
                onComplete?()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(buttonDisabled())
            .frame(maxWidth: 95, maxHeight: 32, alignment: .trailing)
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(
                    width: nil,
                    height: 1,
                    alignment: .top
                )
                .foregroundColor(Color(nsColor: .separatorColor)), alignment: .top)
    }
    
    func buttonDisabled() -> Bool {
        if let driveName = syncRecapViewModel.ds3DriveName {
            return driveName.isEmpty
        }
        
        return true
    }
    
    func onBack(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onBack = action
        return copy
    }
    
    func onComplete(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onComplete = action
        return copy
    }
}

#Preview {
    SyncRecapFooterView()
        .environment(
            SyncRecapViewModel(
                syncAnchor: PreviewData.syncAnchor
            )
        )
}
