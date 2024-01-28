import SwiftUI

struct SyncRecapNameSelectionView: View {
    @Environment(SyncRecapViewModel.self) var syncRecapViewModel: SyncRecapViewModel
    @FocusState var focused: Bool?
    
    var onComplete: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                Text("Drive name:")
                    .font(.custom("Nunito", size: 12))
                
                IconTextField(
                    iconName: .driveIcon,
                    placeholder: "Enter drive name",
                    text: Binding {
                        syncRecapViewModel.ds3DriveName ?? ""
                    } set: {
                        syncRecapViewModel.setDS3DriveName($0)
                    }
                )
                .focused($focused, equals: true)
                .onSubmit {
                    if let ds3DriveName = syncRecapViewModel.ds3DriveName, ds3DriveName.count > 0 {
                        onComplete?()
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        self.focused = true
                    }
                }
            }
            .padding(.vertical, 5)
            
            VStack(alignment: .leading) {
                Text("Project name:")
                    .font(.custom("Nunito", size: 12))
                Text(syncRecapViewModel.syncAnchor.project.name)
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            VStack(alignment: .leading) {
                Text("IAM Role:")
                    .font(.custom("Nunito", size: 12))
                Text(syncRecapViewModel.syncAnchor.IAMUser.username)
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            VStack(alignment: .leading) {
                Text("Bucket:")
                    .font(.custom("Nunito", size: 12))
                Text(syncRecapViewModel.syncAnchor.bucket.name)
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            if syncRecapViewModel.syncAnchor.prefix != nil {
                VStack(alignment: .leading) {
                    Text("Folder:")
                        .font(.custom("Nunito", size: 12))
                    
                    Text(syncRecapViewModel.syncAnchor.prefix!)
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.bold)
                }
                .padding(.vertical, 5)
            }
            
            Spacer()
        }
        .padding(.vertical)
        .frame(width: 400)
    }
    
    func onComplete(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onComplete = action
        return copy
    }
}


#Preview {
    SyncRecapNameSelectionView()
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
        .padding()
}
