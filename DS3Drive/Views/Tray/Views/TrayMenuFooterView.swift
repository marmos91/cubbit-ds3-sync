import SwiftUI

struct TrayMenuFooterView: View {
    var status: String
    var version: String
    var build: String
    var updateAvailable: Bool = false
    var latestVersion: String?

    var body: some View {
        HStack {
            Text(status)
                .font(DS3Typography.footnote)
                .foregroundStyle(.tertiary)

            Spacer()

            if updateAvailable, let latestVersion {
                Text("Update available: \(latestVersion)")
                    .font(DS3Typography.footnote)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Version \(version) (\(build))")
                    .font(DS3Typography.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
    }
}

#Preview {
    TrayMenuFooterView(
        status: "Idle",
        version: "1.0.0",
        build: "1"
    )
}
