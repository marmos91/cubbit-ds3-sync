import SwiftUI
import os.log
import DS3Lib

struct PreferencesView: View {
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    var preferencesViewModel: PreferencesViewModel

    var body: some View {
        TabView {
            GeneralTab(preferencesViewModel: preferencesViewModel)
                .tabItem { Label("General", systemImage: "gear") }

            AccountTab(preferencesViewModel: preferencesViewModel)
                .tabItem { Label("Account", systemImage: "person.circle") }
                .environment(ds3DriveManager)

            SyncTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(
            minWidth: 500,
            maxWidth: 500,
            minHeight: 380,
            maxHeight: 380
        )
    }
}

#Preview {
    PreferencesView(
        preferencesViewModel: PreferencesViewModel(
            account: PreviewData.account
        )
    )
    .environment(
        DS3DriveManager(appStatusManager: AppStatusManager.default())
    )
}
