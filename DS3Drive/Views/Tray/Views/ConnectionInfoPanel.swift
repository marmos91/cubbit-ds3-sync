import SwiftUI

/// Side panel showing connection details, displayed when activeSidePanel = .connectionInfo.
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.md)

            Divider()

            // Info rows
            VStack(spacing: 0) {
                ConnectionInfoRow(
                    icon: "globe",
                    label: NSLocalizedString("Coordinator", comment: "Connection info label"),
                    value: coordinatorURL
                )

                Divider().padding(.leading, 36)

                ConnectionInfoRow(
                    icon: "externaldrive.connected.to.line.below",
                    label: NSLocalizedString("S3 Endpoint", comment: "Connection info label"),
                    value: s3Endpoint
                )

                Divider().padding(.leading, 36)

                ConnectionInfoRow(
                    icon: "person.2",
                    label: NSLocalizedString("Tenant", comment: "Connection info label"),
                    value: tenant
                )

                Divider().padding(.leading, 36)

                ConnectionInfoRow(
                    icon: "safari",
                    label: NSLocalizedString("Console", comment: "Connection info label"),
                    value: consoleURL
                )
            }

            Spacer()
        }
    }
}

// MARK: - ConnectionInfoRow

private struct ConnectionInfoRow: View {
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

            VStack(alignment: .leading, spacing: 1) {
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
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}
