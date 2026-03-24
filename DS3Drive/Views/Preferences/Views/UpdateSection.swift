#if os(macOS)
import DS3Lib
import SwiftUI

/// Update preferences section shown in the General tab.
struct UpdateSection: View {
    @Environment(UpdateManager.self) var updateManager: UpdateManager
    @AppStorage(DefaultSettings.UserDefaultsKeys.autoCheckUpdates) var autoCheckUpdates: Bool = true

    var body: some View {
        Section {
            if updateManager.channel.supportsInAppUpdate {
                Toggle(isOn: $autoCheckUpdates) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Check for updates automatically")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Checks every 4 hours for new versions.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
                .onChange(of: autoCheckUpdates) {
                    if autoCheckUpdates {
                        updateManager.startPeriodicChecks()
                    } else {
                        updateManager.stopPeriodicChecks()
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                    if updateManager.updateAvailable, let version = updateManager.latestVersion {
                        Text("Update available: \(version)")
                            .font(DS3Typography.body)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("You're up to date")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)
                    }

                    if let lastCheck = updateManager.lastCheckDate {
                        Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }

                Spacer()

                if updateManager.updateAvailable {
                    Button(updateActionLabel) {
                        updateManager.installUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Check Now") {
                        Task { await updateManager.checkForUpdates() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateManager.isChecking)
                }
            }

            HStack {
                Text("Distribution")
                    .font(DS3Typography.body)
                    .foregroundStyle(DS3Colors.primaryText)
                Spacer()
                Text(updateManager.channel.displayName)
                    .font(DS3Typography.body)
                    .foregroundStyle(DS3Colors.secondaryText)
            }
        } header: {
            Text("Updates")
                .font(DS3Typography.caption)
        }
    }

    private var updateActionLabel: String {
        switch updateManager.channel {
        case .directDownload:
            return "Download Update"
        case .homebrew:
            return "Copy Brew Command"
        case .testFlight:
            return "Open TestFlight"
        case .appStore:
            return "Open App Store"
        }
    }
}

#Preview {
    Form {
        UpdateSection()
    }
    .formStyle(.grouped)
    .environment(UpdateManager())
}
#endif
