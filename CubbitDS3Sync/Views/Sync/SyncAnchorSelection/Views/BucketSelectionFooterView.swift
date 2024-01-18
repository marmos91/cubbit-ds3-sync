import SwiftUI

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
        .background(Color(.darkMainStandard))
        .overlay(
            Rectangle().frame(
                width: nil,
                height: 1,
                alignment: .top
            )
            .foregroundColor(Color(.darkMainBorder)), alignment: .top)
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
}
