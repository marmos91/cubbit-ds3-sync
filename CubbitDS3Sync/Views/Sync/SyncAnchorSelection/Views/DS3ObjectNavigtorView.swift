import SwiftUI

struct DS3ObjectNavigtorColumView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var folders: [String]
    var prefix: String
    
    var body: some View {
        VStack {
            ScrollView(.vertical, showsIndicators: false) {
                ForEach(folders, id: \.self) { folderName in
                    ColumnSelectionRowView(
                        icon: .folderIcon,
                        name: self.cleanFolderName(folderName),
                        selected: folderSelected(folderName)
                    ) {
                        Task {
                            await syncAnchorSelectionViewModel.selectFolder(withPrefix: folderName)
                        }
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 10.0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    
    func cleanFolderName(_ folderName: String) -> String {
        let cleanFolder = folderName.replacingOccurrences(of: self.prefix, with: "")
        
        guard var cleanFolderName = cleanFolder.split(separator: DefaultSettings.S3.delimiter).last else { return folderName }
        
        if cleanFolderName.last == DefaultSettings.S3.delimiter {
            cleanFolderName = cleanFolderName.dropLast()
        }
        
        return cleanFolderName.removingPercentEncoding ?? String(cleanFolderName)
    }
    
    func folderSelected(_ folderName: String) -> Bool {
        let selectedPrefix = self.syncAnchorSelectionViewModel.selectedPrefix ?? ""
        
        for component in selectedPrefix.split(separator: DefaultSettings.S3.delimiter) {
            if component.removingPercentEncoding == self.cleanFolderName(folderName) {
                return true
            }
        }
        
        return false
    }
}

struct DS3ObjectNavigatorView: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        VStack {
            if syncAnchorSelectionViewModel.loading {
                LoadingView()
            } else {
                HStack {
                    ForEach(Array(syncAnchorSelectionViewModel.folders.keys.sorted()), id: \.self) { prefix in
                        if (syncAnchorSelectionViewModel.folders[prefix]?.count ?? 0) > 0 {
                            DS3ObjectNavigtorColumView(
                                folders: syncAnchorSelectionViewModel.folders[prefix] ?? [],
                                prefix: prefix
                            )
                            
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    struct AsyncPreviewView: View {
        @State var syncAnchorSelectionViewModel = SyncAnchorSelectionViewModel(
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
        
        var body: some View {
            DS3ObjectNavigatorView()
                .environment(syncAnchorSelectionViewModel)
                .task {
                    await syncAnchorSelectionViewModel.loadBuckets()
                }
                .frame(
                    minWidth: 600,
                    maxWidth: 600,
                    minHeight: 480,
                    maxHeight: 480
                )
        }
    }
    
    return AsyncPreviewView()
}
