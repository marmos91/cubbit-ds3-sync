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
            minHeight: 320,
            maxHeight: 320
        )
    }
}

#Preview {
    PreferencesView(
        preferencesViewModel: PreferencesViewModel(
            account: Account(
                id: UUID().uuidString,
                firstName: "Marco",
                lastName: "Moschettini",
                isInternal: false,
                isBanned: false,
                createdAt: "yesterday",
                maxAllowedProjects: 1,
                emails: [
                    AccountEmail(
                        id: UUID().uuidString,
                        email: "connect@cubbit.io",
                        isDefault: true,
                        createdAt: "yesterday",
                        isVerified: true,
                        tenantId: "tenant"
                    )
                ],
                isTwoFactorEnabled: true,
                tenantId: "tenant",
                endpointGateway: "https://s3.cubbit.eu",
                authProvider: "cubbit"
            )
        )
    )
}
