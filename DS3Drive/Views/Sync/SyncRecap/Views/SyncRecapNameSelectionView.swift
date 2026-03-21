import SwiftUI
import DS3Lib

struct SyncRecapNameSelectionView: View {
    @Environment(SyncRecapViewModel.self) var syncRecapViewModel: SyncRecapViewModel
    @FocusState var focused: Bool?
    
    var onComplete: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                Text("Drive name:")
                    .font(DS3Typography.caption)
                
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
                    if let ds3DriveName = syncRecapViewModel.ds3DriveName, !ds3DriveName.isEmpty {
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
                    .font(DS3Typography.caption)
                Text(syncRecapViewModel.syncAnchor.project.name)
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            VStack(alignment: .leading) {
                Text("IAM Role:")
                    .font(DS3Typography.caption)
                Text(syncRecapViewModel.syncAnchor.IAMUser.username)
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            VStack(alignment: .leading) {
                Text("Bucket:")
                    .font(DS3Typography.caption)
                Text(syncRecapViewModel.syncAnchor.bucket.name)
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
            }
            .padding(.vertical, 5)
            
            if syncRecapViewModel.syncAnchor.prefix != nil {
                VStack(alignment: .leading) {
                    Text("Folder:")
                        .font(DS3Typography.caption)
                    
                    Text(syncRecapViewModel.syncAnchor.prefix!)
                        .font(DS3Typography.headline)
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
                syncAnchor: PreviewData.syncAnchor
            )
        )
        .padding()
}
