import SwiftUI
import DS3Lib

struct BucketSelectionFooterView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var onBack: (() -> Void)?
    var onContinue: (() -> Void)?
    
    var body: some View {
        HStack {
            IconButtonView(iconName: .arrowWestIcon) {
                onBack?()
            }.padding(.horizontal)
            
            Spacer()
            Button(NSLocalizedString("Continue", comment: "Continue button")) {
                onContinue?()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(buttonDisabled())
            .frame(maxWidth: 95, maxHeight: 32, alignment: .trailing)
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle().frame(
                width: nil,
                height: 1,
                alignment: .top
            )
            .foregroundColor(Color(nsColor: .separatorColor)), alignment: .top)
    }
    
    func buttonDisabled() -> Bool {
        return false
    }
    
    func onContinue(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onContinue = action
        return copy
    }
    
    func onBack(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onBack = action
        return copy
    }
}

#Preview {
    BucketSelectionFooterView()
        .environment(
            SyncAnchorSelectionViewModel(
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
}
