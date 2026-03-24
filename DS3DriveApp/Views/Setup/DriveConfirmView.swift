#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Summary card + editable drive name field + "Create Drive" button.
    /// Final step of the drive setup wizard. Shows project/bucket/prefix summary,
    /// auto-suggests drive name, warns on duplicates, and creates drive with API keys.
    struct DriveConfirmView: View {
        var setupViewModel: SyncSetupViewModel
        let onDismiss: () -> Void

        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(DS3DriveManager.self) private var ds3DriveManager

        @State private var driveName: String = ""
        @State private var isCreating = false
        @State private var creationError: Error?
        @State private var showDuplicateWarning = false

        var body: some View {
            ScrollView {
                VStack(spacing: IOSSpacing.lg) {
                    summaryCard
                    driveNameSection
                    duplicateWarning
                    errorSection
                    createButton
                    Spacer()
                }
                .padding(IOSSpacing.md)
            }
            .navigationTitle("Create Drive")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                driveName = setupViewModel.suggestedDriveName
                checkForDuplicate()
            }
        }

        // MARK: - Summary Card

        private var summaryCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                summaryRow(label: "Project") {
                    Text(setupViewModel.selectedProject?.short().uppercased() ?? "")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.orange)
                        )
                    Text(setupViewModel.selectedProject?.name ?? "")
                }

                Divider().padding(.leading, 70)

                summaryRow(label: "Bucket") {
                    Image(.bucketIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                    Text(setupViewModel.selectedBucket?.name ?? "")
                }

                if let prefix = setupViewModel.selectedPrefix, !prefix.isEmpty {
                    Divider().padding(.leading, 70)

                    summaryRow(label: "Path") {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                        Text(prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
                    }
                }
            }
            .padding(IOSSpacing.md)
            .background(IOSColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        private func summaryRow(label: String, @ViewBuilder content: () -> some View) -> some View {
            HStack(spacing: IOSSpacing.sm) {
                Text(label)
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSColors.secondaryText)
                    .frame(width: 54, alignment: .leading)

                content()
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, IOSSpacing.sm)
        }

        // MARK: - Drive Name

        private var driveNameSection: some View {
            VStack(alignment: .leading, spacing: IOSSpacing.xs) {
                Text("Drive Name")
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSColors.secondaryText)
                TextField("Drive name", text: $driveName)
                    .textFieldStyle(.roundedBorder)
                    .font(IOSTypography.body)
                    .onChange(of: driveName) {
                        checkForDuplicate()
                    }

                Text(
                    "With a single drive, Files displays the app name. This name will be shown when multiple drives are configured. [Learn more](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/displayname)"
                )
                .font(IOSTypography.footnote)
                .foregroundStyle(IOSColors.secondaryText)
            }
        }

        // MARK: - Duplicate Warning

        @ViewBuilder private var duplicateWarning: some View {
            if showDuplicateWarning {
                HStack(spacing: IOSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text("A drive with this bucket and prefix already exists. You can still create another.")
                        .font(IOSTypography.caption)
                        .foregroundStyle(Color.orange)
                }
                .padding(IOSSpacing.sm)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }

        // MARK: - Error Section

        @ViewBuilder private var errorSection: some View {
            if creationError != nil {
                HStack(spacing: IOSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    Text("Failed to create drive. Please try again.")
                        .font(IOSTypography.caption)
                        .foregroundStyle(Color.red)
                }
            }
        }

        // MARK: - Create Button

        private var createButton: some View {
            Button {
                Task { await createDrive() }
            } label: {
                if isCreating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Create Drive")
                }
            }
            .buttonStyle(IOSPrimaryButtonStyle())
            .disabled(isCreating || driveName.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        // MARK: - Actions

        private func checkForDuplicate() {
            guard let bucket = setupViewModel.selectedBucket else {
                showDuplicateWarning = false
                return
            }

            let prefix = setupViewModel.selectedPrefix
            showDuplicateWarning = ds3DriveManager.drives.contains { drive in
                drive.syncAnchor.bucket.name == bucket.name && drive.syncAnchor.prefix == prefix
            }
        }

        @MainActor
        private func createDrive() async {
            isCreating = true
            creationError = nil

            do {
                guard let anchor = setupViewModel.selectedSyncAnchor else { return }
                let drive = DS3Drive(
                    id: UUID(),
                    name: driveName.trimmingCharacters(in: .whitespaces),
                    syncAnchor: anchor
                )

                // Create API keys for the drive
                let sdk = DS3SDK(withAuthentication: ds3Authentication)
                _ = try await sdk.loadOrCreateDS3APIKeys(
                    forIAMUser: anchor.IAMUser,
                    ds3ProjectName: anchor.project.name
                )

                try await ds3DriveManager.add(drive: drive)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                setupViewModel.reset()
                onDismiss()
            } catch {
                creationError = error
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isCreating = false
            }
        }
    }
#endif
