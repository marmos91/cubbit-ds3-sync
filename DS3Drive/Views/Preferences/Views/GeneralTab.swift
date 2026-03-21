import SwiftUI
import DS3Lib

struct GeneralTab: View {
    @AppStorage(DefaultSettings.UserDefaultsKeys.loginItemSet) var loginItemSet: Bool = DefaultSettings.loginItemSet
    @State var startAtLogin: Bool = DefaultSettings.appIsLoginItem

    var preferencesViewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $startAtLogin) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Start DS3 Drive at login")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Keep DS3 Drive running in the background so your drives stay synchronized.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
                .onChange(of: self.startAtLogin) {
                    self.preferencesViewModel.setStartAtLogin(self.startAtLogin)
                    self.loginItemSet = true
                }
            } header: {
                Text("Startup")
                    .font(DS3Typography.caption)
            }

            Section {
                Toggle(isOn: .constant(true)) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Show sync notifications")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Display notifications for sync events such as conflicts and errors.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
            } header: {
                Text("Notifications")
                    .font(DS3Typography.caption)
            }

            UpdateSection()
        }
        .formStyle(.grouped)
        .padding(DS3Spacing.lg)
    }
}

#Preview {
    GeneralTab(
        preferencesViewModel: PreferencesViewModel(
            account: Account(
                id: UUID().uuidString,
                firstName: "Marco",
                lastName: "Moschettini",
                isInternal: false,
                isBanned: false,
                createdAt: "yesterday",
                maxAllowedProjects: 1,
                emails: [],
                isTwoFactorEnabled: false,
                tenantId: "tenant",
                endpointGateway: "https://s3.cubbit.eu",
                authProvider: "cubbit"
            )
        )
    )
    .environment(UpdateManager())
    .frame(width: 800, height: 600)
}
