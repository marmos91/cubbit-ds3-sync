#if os(iOS)
    import DS3Lib
    import FileProvider
    import SwiftUI

    /// Full drive detail / settings screen with brand-styled hero, details
    /// card, action list, and destructive "Disconnect Drive" footer.
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
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        hero
                            .padding(.top, 8)

                        detailsCard

                        actionsCard

                        disconnectButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(drive.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert("Disconnect Drive", isPresented: $showDisconnectAlert) {
                Button("Cancel", role: .cancel) { /* dismiss */ }
                Button("Disconnect", role: .destructive) {
                    disconnectDrive()
                }
            } message: {
                Text("This will remove the drive from Files. Your files in S3 are not affected.")
            }
        }

        // MARK: - Hero

        private var hero: some View {
            let statusColor = IOSDriveViewModel.statusColor(for: currentStatus)
            return VStack(spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    Image(.rawDriveIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)

                    statusBadgeImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .offset(x: -3, y: 3)
                }
                .accessibilityLabel(IOSDriveViewModel.statusLabel(for: currentStatus))

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(statusText)
                        .font(.custom("Figtree-SemiBold", size: 14))
                        .foregroundStyle(statusColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(statusColor.opacity(0.12)))
                .overlay(Capsule().stroke(statusColor.opacity(0.25), lineWidth: 1))
            }
        }

        private var statusText: String {
            let base = IOSDriveViewModel.statusLabel(for: currentStatus)
            if currentStatus == .sync, let speed = currentSpeed, speed > 0 {
                return "\(base) — \(IOSDriveViewModel.formatSpeed(speed))"
            }
            return base
        }

        private var statusBadgeImage: Image {
            switch currentStatus {
            case .idle: Image(.statusIdleBadge)
            case .sync: Image(.statusSyncBadge)
            case .error: Image(.statusErrorBadge)
            case .paused: Image(.statusPauseBadge)
            }
        }

        // MARK: - Details Card

        private var detailsCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("DETAILS")

                VStack(spacing: 0) {
                    detailRow(label: "Project") {
                        HStack(spacing: 12) {
                            projectEmblem(drive.syncAnchor.project.short())
                            Text(drive.syncAnchor.project.name)
                                .font(.custom("Figtree-SemiBold", size: 16))
                                .foregroundStyle(IOSColors.brandTextPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    divider

                    detailRow(label: "Bucket") {
                        HStack(spacing: 12) {
                            Image(.bucketIcon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                            Text(drive.syncAnchor.bucket.name)
                                .font(.custom("Figtree-SemiBold", size: 16))
                                .foregroundStyle(IOSColors.brandTextPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    divider

                    detailRow(label: "Path") {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(IOSColors.brandPrimary)
                                .frame(width: 28, height: 28)

                            if let prefix = drive.syncAnchor.prefix, !prefix.isEmpty, prefix != "/" {
                                Text(prefix)
                                    .font(.custom("Figtree-SemiBold", size: 16))
                                    .foregroundStyle(IOSColors.brandTextPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("Bucket root")
                                    .font(.custom("Figtree-SemiBold", size: 16))
                                    .foregroundStyle(IOSColors.brandTextSecondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .background(cardBackground)
            }
        }

        private func detailRow(label: String, @ViewBuilder content: () -> some View) -> some View {
            HStack(spacing: 12) {
                Text(label)
                    .font(.custom("Figtree-Medium", size: 12))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .frame(width: 60, alignment: .leading)

                content()

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
        }

        private func projectEmblem(_ shortName: String) -> some View {
            Text(shortName.uppercased())
                .font(.custom("Figtree-SemiBold", size: 11))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    IOSColors.brandPrimary,
                                    IOSColors.brandPrimaryDark
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        }

        // MARK: - Actions Card

        private var actionsCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("ACTIONS")

                VStack(spacing: 0) {
                    actionRow(
                        icon: "folder.fill",
                        tint: IOSColors.brandPrimary,
                        title: "Open in Files",
                        action: openInFiles
                    )

                    divider

                    actionRow(
                        icon: "arrow.clockwise",
                        tint: IOSColors.brandPrimary,
                        title: isRefreshing ? "Refreshing…" : "Refresh",
                        isLoading: isRefreshing,
                        action: refreshDrive
                    )
                    .disabled(isRefreshing)

                    divider

                    actionRow(
                        icon: "safari.fill",
                        tint: IOSColors.brandPrimary,
                        title: "View in Console",
                        trailingSymbol: "arrow.up.right",
                        action: viewInConsole
                    )

                    divider

                    actionRow(
                        icon: currentStatus == .paused ? "play.fill" : "pause.fill",
                        tint: IOSColors.brandPrimary,
                        title: currentStatus == .paused ? "Resume Sync" : "Pause Sync",
                        action: togglePauseResume
                    )
                }
                .padding(.horizontal, 4)
                .background(cardBackground)
            }
        }

        private func actionRow(
            icon: String,
            tint: Color,
            title: String,
            trailingSymbol: String? = nil,
            isLoading: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.14))
                            .frame(width: 32, height: 32)
                        if isLoading {
                            ProgressView().tint(tint)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                    }

                    Text(title)
                        .font(.custom("Figtree-SemiBold", size: 16))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Spacer(minLength: 0)

                    Image(systemName: trailingSymbol ?? "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        // MARK: - Disconnect

        private var disconnectButton: some View {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showDisconnectAlert = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Disconnect Drive")
                        .font(.custom("Figtree-SemiBold", size: 17))
                }
                .foregroundStyle(IOSColors.statusError)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(IOSColors.statusError.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(IOSColors.statusError.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }

        // MARK: - Shared

        private func sectionHeader(_ text: String) -> some View {
            Text(text)
                .font(.custom("Figtree-Medium", size: 12))
                .foregroundStyle(IOSColors.brandTextSecondary)
                .tracking(0.5)
                .padding(.leading, 4)
        }

        private var cardBackground: some View {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
                )
        }

        private var divider: some View {
            Rectangle()
                .fill(IOSColors.brandBorderSubtle)
                .frame(height: 1)
                .padding(.leading, 14)
        }

        // MARK: - Actions

        private func openInFiles() {
            guard let url = URL(string: "shareddocuments://") else { return }
            openURL(url)
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
            guard let url = URL(string: "\(ConsoleURLs.projectsURL)/\(projectId)/buckets/\(bucketName)") else { return }
            openURL(url)
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
