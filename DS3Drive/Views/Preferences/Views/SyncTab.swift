import SwiftUI
import DS3Lib

struct SyncTab: View {
    @AppStorage("io.cubbit.DS3Drive.showSyncBadges") var showSyncBadges: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showSyncBadges) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Show sync badges in Finder")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Display sync status badges on files and folders in Finder.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
            } header: {
                Text("Finder integration")
                    .font(DS3Typography.caption)
            }

            Section {
                VStack(alignment: .leading, spacing: DS3Spacing.sm) {
                    Text("Auto-pause")
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.primaryText)

                    Text("Automatic pause settings will be available in a future update.")
                        .font(DS3Typography.caption)
                        .foregroundStyle(DS3Colors.secondaryText)
                }
            } header: {
                Text("Advanced")
                    .font(DS3Typography.caption)
            }
        }
        .formStyle(.grouped)
        .padding(DS3Spacing.lg)
    }
}

#Preview {
    SyncTab()
        .frame(width: 800, height: 600)
}
