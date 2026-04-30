import DS3Lib
import SwiftUI

/// Read-only connection details surfaced in Preferences -> Connection.
/// Replaces the tray "Connection Info" floating panel (Gap 8).
struct ConnectionTab: View {
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication

    @State private var coordinatorURL: String = ""
    @State private var tenantName: String = ""

    var body: some View {
        Form {
            Section {
                ConnectionInfoRow(
                    icon: "globe",
                    label: NSLocalizedString("Coordinator", comment: "Connection info label"),
                    value: coordinatorURL
                )
                ConnectionInfoRow(
                    icon: "externaldrive.connected.to.line.below",
                    label: NSLocalizedString("S3 Endpoint", comment: "Connection info label"),
                    value: s3Endpoint
                )
                ConnectionInfoRow(
                    icon: "person.2",
                    label: NSLocalizedString("Tenant ID", comment: "Connection info label"),
                    value: tenantName
                )
                ConnectionInfoRow(
                    icon: "safari",
                    label: NSLocalizedString("Console", comment: "Connection info label"),
                    value: ConsoleURLs.baseURL
                )
            } header: {
                Text(NSLocalizedString(
                    "preferences.tab.connection.header",
                    value: "Backend connection",
                    comment: "Connection tab section header"
                ))
                .font(DS3Typography.caption)
            } footer: {
                Text(NSLocalizedString(
                    "preferences.tab.connection.footer",
                    value: "Click any value to copy it to the clipboard.",
                    comment: "Connection tab footer"
                ))
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(DS3Colors.brandBackground)
        .padding(DS3Spacing.lg)
        .onAppear {
            coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence())
                ?? CubbitAPIURLs.defaultCoordinatorURL
            let tenant = (try? SharedData.default().loadTenantNameFromPersistence()) ?? ""
            tenantName = tenant
        }
    }

    private var s3Endpoint: String {
        ds3Authentication.account?.endpointGateway
            ?? NSLocalizedString("N/A", comment: "Not available")
    }
}

/// Click-to-copy row used inside the Connection tab. Mirrors the previous
/// floating-panel `ConnectionInfoRow` so the visual treatment stays consistent.
struct ConnectionInfoRow: View {
    let icon: String
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS3Typography.footnote)
                    .foregroundStyle(.secondary)

                Text(copied ? NSLocalizedString("Copied!", comment: "Clipboard copy feedback") : value)
                    .font(DS3Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.vertical, DS3Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}
