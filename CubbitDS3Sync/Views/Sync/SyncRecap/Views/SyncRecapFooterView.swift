import SwiftUI

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
        .background(Color(.sidebarBackground))
        .overlay(
            Rectangle()
                .frame(
                    width: nil,
                    height: 1,
                    alignment: .top
                )
                .foregroundColor(Color(.textFieldBorder)), alignment: .top)
    }
    
    func buttonDisabled() -> Bool {
        if let driveName = syncRecapViewModel.ds3DriveName {
            return driveName.count == 0
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
                syncAnchor: SyncAnchor(
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
                    IAMUser: IAMUser(
                        id: "77d5961c-365d-4d55-a3cb-8f7cf22ce9f6",
                        username: "ROOT",
                        isRoot: true
                    ),
                    bucket: Bucket(name: "moschet-personal"),
                    prefix: "Cubbit"
                )
            )
        )
}
