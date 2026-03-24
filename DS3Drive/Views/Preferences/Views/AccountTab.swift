import SwiftUI
import os.log
import DS3Lib

struct AccountTab: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    var preferencesViewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    Text(preferencesViewModel.formatFullName())
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.primaryText)
                }

                LabeledContent("Email") {
                    Text(preferencesViewModel.mainEmail())
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.primaryText)
                }

                LabeledContent("2FA") {
                    if preferencesViewModel.account.isTwoFactorEnabled {
                        Text("Enabled")
                            .font(DS3Typography.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, DS3Spacing.sm)
                            .padding(.vertical, DS3Spacing.xs)
                            .background(
                                Capsule()
                                    .fill(DS3Colors.statusSynced)
                            )
                    } else {
                        Text("Disabled")
                            .font(DS3Typography.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, DS3Spacing.sm)
                            .padding(.vertical, DS3Spacing.xs)
                            .background(
                                Capsule()
                                    .fill(DS3Colors.statusError)
                            )
                    }
                }
            } header: {
                Text("Account details")
                    .font(DS3Typography.caption)
            }

            Section {
                if let url = URL(string: ConsoleURLs.profileURL) {
                    Link("Edit on web console", destination: url)
                        .font(DS3Typography.body)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Section {
                Button(role: .destructive) {
                    disconnectAccount()
                } label: {
                    Text("Disconnect account")
                        .font(DS3Typography.body)
                }
            } footer: {
                Text("This will remove all drives and sign you out of DS3 Drive.")
                    .font(DS3Typography.footnote)
                    .foregroundStyle(DS3Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
        .padding(DS3Spacing.lg)
    }

    private func disconnectAccount() {
        let manager = ds3DriveManager
        let prefVM = preferencesViewModel
        Task {
            do {
                try await manager.disconnectAll()
            } catch {
                logger.error("Error disconnecting drives: \(error.localizedDescription)")
            }

            prefVM.disconnectAccount()
        }
    }
}

#Preview {
    AccountTab(
        preferencesViewModel: PreferencesViewModel(
            account: PreviewData.account
        )
    )
    .environment(
        DS3DriveManager(appStatusManager: AppStatusManager.default())
    )
    .frame(width: 800, height: 600)
}
