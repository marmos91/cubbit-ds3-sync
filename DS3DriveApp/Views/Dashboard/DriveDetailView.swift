#if os(iOS)
import SwiftUI
import FileProvider
import DS3Lib

/// Full drive detail screen showing status, bucket info, and actions.
struct DriveDetailView: View {
    let drive: DS3Drive
    let driveViewModel: IOSDriveViewModel

    @Environment(DS3DriveManager.self) private var ds3DriveManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var showDisconnectAlert = false

    private var currentStatus: DS3DriveStatus {
        driveViewModel.status(for: drive.id)
    }

    private var currentSpeed: Double? {
        driveViewModel.speed(for: drive.id)
    }

    var body: some View {
        List {
            statusSection
            actionsSection
            dangerSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(drive.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Disconnect Drive", isPresented: $showDisconnectAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                disconnectDrive()
            }
        } message: {
            Text("This will remove the drive from Files. Your files in S3 are not affected.")
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            // Status row
            HStack {
                Text("Status")
                    .font(IOSTypography.body)
                Spacer()
                HStack(spacing: IOSSpacing.sm) {
                    Circle()
                        .fill(IOSDriveViewModel.statusColor(for: currentStatus))
                        .frame(width: 10, height: 10)
                    Text(IOSDriveViewModel.statusLabel(for: currentStatus))
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }
            }

            // Transfer speed (visible when syncing)
            if currentStatus == .sync, let speed = currentSpeed, speed > 0 {
                detailRow("Transfer Speed", value: IOSDriveViewModel.formatSpeed(speed))
            }

            detailRow("Bucket", value: drive.syncAnchor.bucket.name)
            detailRow("Path", value: drive.syncAnchor.prefix ?? "/")
            detailRow("Project", value: drive.syncAnchor.project.name)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IOSTypography.body)
            Spacer()
            Text(value)
                .font(IOSTypography.body)
                .foregroundStyle(IOSColors.secondaryText)
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            Button { openInFiles() } label: {
                Label("Open in Files", systemImage: "folder.fill")
            }

            Button { refreshDrive() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button { viewInConsole() } label: {
                Label("View in Console", systemImage: "safari")
            }

            Button { togglePauseResume() } label: {
                if currentStatus == .paused {
                    Label("Resume", systemImage: "play.circle")
                } else {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDisconnectAlert = true
            } label: {
                Label("Disconnect Drive", systemImage: "xmark.circle")
            }
            .tint(.red)
        }
    }

    // MARK: - Actions

    private func openInFiles() {
        if let url = URL(string: "shareddocuments://") {
            openURL(url)
        }
    }

    private func refreshDrive() {
        Task {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                displayName: drive.name
            )
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }

    private func viewInConsole() {
        let projectId = drive.syncAnchor.project.id
        let bucketName = drive.syncAnchor.bucket.name
        if let url = URL(string: "\(ConsoleURLs.projectsURL)/\(projectId)/buckets/\(bucketName)") {
            openURL(url)
        }
    }

    private func togglePauseResume() {
        driveViewModel.togglePause(for: drive.id)
    }

    private func disconnectDrive() {
        Task {
            try? await ds3DriveManager.disconnect(driveWithId: drive.id)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            dismiss()
        }
    }
}
#endif
