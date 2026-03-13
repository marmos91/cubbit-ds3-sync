import SwiftUI

/// Side panel showing connection details with click-to-copy, displayed when activeSidePanel = .connectionInfo.
struct ConnectionInfoPanel: View {
    let coordinatorURL: String
    let s3Endpoint: String
    let tenant: String
    let consoleURL: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(NSLocalizedString("Connection Info", comment: "Connection info panel title"))
                    .font(DS3Typography.headline)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.md)

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 0) {
                ConnectionInfoRow(
                    label: NSLocalizedString("Coordinator", comment: "Connection info label"),
                    value: coordinatorURL
                )
                ConnectionInfoRow(
                    label: NSLocalizedString("S3 Endpoint", comment: "Connection info label"),
                    value: s3Endpoint
                )
                ConnectionInfoRow(
                    label: NSLocalizedString("Tenant", comment: "Connection info label"),
                    value: tenant
                )
                ConnectionInfoRow(
                    label: NSLocalizedString("Console", comment: "Connection info label"),
                    value: consoleURL
                )
            }
            .padding(.horizontal, DS3Spacing.md)
            .padding(.vertical, DS3Spacing.sm)

            Spacer()
        }
    }
}

// MARK: - ConnectionInfoRow

struct ConnectionInfoRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label)
                .font(DS3Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(copied ? NSLocalizedString("Copied", comment: "Clipboard copy feedback") : value)
                .font(DS3Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
        }
        .padding(.vertical, 2)
    }
}
