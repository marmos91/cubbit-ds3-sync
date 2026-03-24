#if os(iOS)
    import DS3Lib
    import FileProvider
    import SwiftUI

    /// Full drive detail screen showing status, bucket info, and actions.
    struct DriveDetailView: View {
        let drive: DS3Drive
        let driveViewModel: IOSDriveViewModel

        @Environment(DS3DriveManager.self) private var ds3DriveManager
        @Environment(\.openURL) private var openURL
        @Environment(\.dismiss) private var dismiss

        @State private var showDisconnectAlert = false
        @State private var isRefreshing = false

        private var currentStatus: DS3DriveStatus {
            driveViewModel.status(for: drive.id)
        }

        private var currentSpeed: Double? {
            driveViewModel.speed(for: drive.id)
        }

        var body: some View {
            List {
                // Header card
                Section {
                    driveHeader
                }

                // Info
                infoSection

                // Actions
                actionsSection

                // Danger
                dangerSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(drive.name)
            .navigationBarTitleDisplayMode(.inline)
            .alert("Disconnect Drive", isPresented: $showDisconnectAlert) {
                Button("Cancel", role: .cancel) { /* No action needed */ }
                Button("Disconnect", role: .destructive) {
                    disconnectDrive()
                }
            } message: {
                Text("This will remove the drive from Files. Your files in S3 are not affected.")
            }
        }

        // MARK: - Drive Header

        private var driveHeader: some View {
            HStack(spacing: IOSSpacing.md) {
                ZStack(alignment: .bottomLeading) {
                    Image(.rawDriveIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)

                    statusBadgeImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .offset(x: -3, y: 3)
                }

                VStack(alignment: .leading, spacing: IOSSpacing.xs) {
                    Text(drive.name)
                        .font(IOSTypography.headline)

                    HStack(spacing: IOSSpacing.xs) {
                        Circle()
                            .fill(IOSDriveViewModel.statusColor(for: currentStatus))
                            .frame(width: 7, height: 7)

                        if currentStatus == .sync, let speed = currentSpeed, speed > 0 {
                            Text(
                                "\(IOSDriveViewModel.statusLabel(for: currentStatus)) — \(IOSDriveViewModel.formatSpeed(speed))"
                            )
                            .font(IOSTypography.caption)
                            .foregroundStyle(IOSDriveViewModel.statusColor(for: currentStatus))
                        } else {
                            Text(IOSDriveViewModel.statusLabel(for: currentStatus))
                                .font(IOSTypography.caption)
                                .foregroundStyle(IOSDriveViewModel.statusColor(for: currentStatus))
                        }
                    }
                }

                Spacer()
            }
        }

        // MARK: - Info Section

        private var infoSection: some View {
            Section("Details") {
                detailRow("Project", value: drive.syncAnchor.project.name) {
                    projectEmblem(drive.syncAnchor.project.short())
                }
                detailRow("Bucket", value: drive.syncAnchor.bucket.name) {
                    Image(.bucketIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                detailRow("Path", value: drive.syncAnchor.prefix ?? "/") {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(IOSColors.secondaryText)
                }
            }
        }

        private func detailRow(_ label: String, value: String, @ViewBuilder icon: () -> some View) -> some View {
            HStack(spacing: IOSSpacing.sm) {
                icon()
                    .frame(width: 20)
                Text(label)
                    .font(IOSTypography.body)
                Spacer()
                Text(value)
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
                    .lineLimit(1)
            }
        }

        private func projectEmblem(_ shortName: String) -> some View {
            Text(shortName.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange)
                )
        }

        private var statusBadgeImage: Image {
            switch currentStatus {
            case .idle: Image(.statusIdleBadge)
            case .sync, .indexing: Image(.statusSyncBadge)
            case .error: Image(.statusErrorBadge)
            case .paused: Image(.statusPauseBadge)
            }
        }

        // MARK: - Actions Section

        private var actionsSection: some View {
            Section {
                Button { openInFiles() } label: {
                    Label("Open in Files", systemImage: "folder.fill")
                }

                Button { refreshDrive() } label: {
                    if isRefreshing {
                        Label("Refreshing…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)

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
            guard !isRefreshing else { return }
            isRefreshing = true

            Task {
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                    displayName: drive.name
                )
                try? await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)

                UINotificationFeedbackGenerator().notificationOccurred(.success)

                try? await Task.sleep(for: .milliseconds(600))
                isRefreshing = false
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
