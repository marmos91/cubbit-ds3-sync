#if os(iOS)
    import DS3Lib
    import os.log
    import SwiftUI

    /// Final wizard step — summary hero + editable drive name + pinned
    /// "Create Drive" CTA. Matches the rest of the iOS setup flow:
    /// brand gradient backdrop, Figtree typography, bordered field, and
    /// a bottom-pinned CTA with safe-area handling.
    struct DriveConfirmView: View {
        var setupViewModel: SyncSetupViewModel
        let onDismiss: () -> Void

        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(DS3DriveManager.self) private var ds3DriveManager
        @FocusState private var nameFieldFocused: Bool

        @State private var driveName: String = ""
        @State private var isCreating = false
        @State private var creationError: Error?
        @State private var showDuplicateWarning = false
        @State private var showThumbnailConflict = false

        private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

        private let buttonHeight: CGFloat = 54

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 24) {
                            hero
                                .padding(.top, 16)

                            summaryCard

                            driveNameSection

                            if showDuplicateWarning {
                                duplicateWarning
                            }

                            if creationError != nil {
                                errorSection
                            }

                            Spacer(minLength: 16)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.interactively)

                    pinnedCTA
                }
            }
            .navigationTitle("Create Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                driveName = setupViewModel.suggestedDriveName
                checkForDuplicate()
            }
            .fullScreenCover(isPresented: $showThumbnailConflict) {
                NavigationStack {
                    IOSThumbnailConflictWarningView(
                        onChooseDifferentPrefix: {
                            showThumbnailConflict = false
                            // Pop back to prefix selection by dismissing the wizard
                            // and letting the user re-enter
                            onDismiss()
                        },
                        onUseAnyway: {
                            proceedDespiteConflict()
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                showThumbnailConflict = false
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(IOSColors.primaryText)
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Hero

        private var hero: some View {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(IOSColors.brandPrimary.opacity(0.12))
                        .frame(width: 112, height: 112)

                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 52, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(IOSColors.brandPrimary)
                }

                VStack(spacing: 8) {
                    Text("Ready to create")
                        .font(.custom("Figtree-SemiBold", size: 26))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Text("Review the details and give your drive a name.")
                        .font(.custom("Figtree-Regular", size: 16))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.bottom, 8)
        }

        // MARK: - Summary Card

        private var summaryCard: some View {
            VStack(spacing: 0) {
                summaryRow(label: "Project") {
                    HStack(spacing: 12) {
                        projectEmblem(setupViewModel.selectedProject?.short() ?? "")
                        Text(setupViewModel.selectedProject?.name ?? "")
                            .font(.custom("Figtree-SemiBold", size: 17))
                            .foregroundStyle(IOSColors.brandTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                divider

                summaryRow(label: "Bucket") {
                    HStack(spacing: 12) {
                        Image(.bucketIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                        Text(setupViewModel.selectedBucket?.name ?? "")
                            .font(.custom("Figtree-SemiBold", size: 17))
                            .foregroundStyle(IOSColors.brandTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let prefix = setupViewModel.selectedPrefix, !prefix.isEmpty {
                    divider

                    summaryRow(label: "Path") {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(IOSColors.brandPrimary)
                                .frame(width: 32, height: 32)
                            Text(prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
                                .font(.custom("Figtree-Regular", size: 16))
                                .foregroundStyle(IOSColors.brandTextPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
            )
        }

        private var divider: some View {
            Rectangle()
                .fill(IOSColors.brandBorderSubtle)
                .frame(height: 1)
        }

        private func summaryRow(
            label: LocalizedStringKey,
            @ViewBuilder content: () -> some View
        ) -> some View {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.custom("Figtree-Medium", size: 12))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .frame(width: 56, alignment: .leading)

                content()

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
        }

        private func projectEmblem(_ shortName: String) -> some View {
            Text(shortName.uppercased())
                .font(.custom("Figtree-SemiBold", size: 10))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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

        // MARK: - Drive Name

        private var driveNameSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("DRIVE NAME")
                    .font(.custom("Figtree-Medium", size: 12))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .tracking(0.5)

                HStack(spacing: 12) {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .frame(width: 22)

                    TextField(
                        "Drive name",
                        text: $driveName,
                        prompt: Text("Drive name")
                            .foregroundColor(IOSColors.brandTextSecondary)
                    )
                    .font(.custom("Figtree-Regular", size: 17))
                    .foregroundStyle(IOSColors.brandTextPrimary)
                    .textFieldStyle(.plain)
                    .tint(IOSColors.brandPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($nameFieldFocused)
                    .onChange(of: driveName) {
                        if driveName.count > 64 {
                            driveName = String(driveName.prefix(64))
                        }
                        checkForDuplicate()
                    }

                    if !driveName.isEmpty {
                        Button {
                            driveName = ""
                            checkForDuplicate()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            nameFieldFocused
                                ? IOSColors.brandPrimary
                                : IOSColors.brandBorderSubtle,
                            lineWidth: nameFieldFocused ? 1.5 : 1
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: nameFieldFocused)

                Text(
                    "Files displays the drive name when multiple drives are configured. [Learn more](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/displayname)"
                )
                .font(.custom("Figtree-Regular", size: 12))
                .foregroundStyle(IOSColors.brandTextSecondary)
                .tint(IOSColors.brandPrimary)
                .lineSpacing(2)
            }
        }

        // MARK: - Duplicate Warning

        private var duplicateWarning: some View {
            statusBanner(
                message: "A drive with this bucket and prefix already exists. You can still create another.",
                color: IOSColors.statusWarning
            )
        }

        // MARK: - Error Section

        private var errorSection: some View {
            statusBanner(
                message: "Failed to create drive. Please try again.",
                color: IOSColors.statusError
            )
        }

        private func statusBanner(message: LocalizedStringKey, color: Color) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(color)

                Text(message)
                    .font(.custom("Figtree-Regular", size: 13))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
        }

        // MARK: - Pinned CTA

        private var pinnedCTA: some View {
            VStack(spacing: 0) {
                Divider()
                    .background(IOSColors.brandBorderSubtle)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await createDrive(skipThumbnailCheck: false) }
                } label: {
                    ZStack {
                        if isCreating {
                            ProgressView().tint(.white)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Create Drive")
                                    .font(.custom("Figtree-SemiBold", size: 17))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                createDisabled
                                    ? IOSColors.brandPrimary.opacity(0.35)
                                    : IOSColors.brandPrimary
                            )
                    )
                }
                .buttonStyle(ConfirmPressableScale())
                .disabled(createDisabled)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .background(.ultraThinMaterial)
        }

        private var createDisabled: Bool {
            isCreating || driveName.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // MARK: - Actions

        private func checkForDuplicate() {
            guard let bucket = setupViewModel.selectedBucket,
                  let project = setupViewModel.selectedProject
            else {
                showDuplicateWarning = false
                return
            }

            // Scope the duplicate check to the selected project. Bucket
            // names are only unique within a project — two projects can
            // legitimately share the same bucket name, so comparing bucket
            // name + prefix without the project produced false positives.
            let prefix = setupViewModel.selectedPrefix
            showDuplicateWarning = ds3DriveManager.drives.contains { drive in
                drive.syncAnchor.project.id == project.id
                    && drive.syncAnchor.bucket.name == bucket.name
                    && drive.syncAnchor.prefix == prefix
            }
        }

        /// Builds a DS3Drive from the current form state. Returns nil if no anchor is selected.
        private func buildDrive() -> DS3Drive? {
            guard let anchor = setupViewModel.selectedSyncAnchor else { return nil }
            return DS3Drive(
                id: UUID(),
                name: driveName.trimmingCharacters(in: .whitespaces),
                syncAnchor: anchor
            )
        }

        @MainActor
        private func createDrive(skipThumbnailCheck: Bool) async {
            isCreating = true
            creationError = nil
            defer { isCreating = false }

            do {
                guard let drive = buildDrive() else { return }

                if !skipThumbnailCheck, let s3Client = setupViewModel.anchorViewModel?.s3Client {
                    let state = await s3Client.inspectThumbnailPrefixWithTimeout(
                        bucket: drive.syncAnchor.bucket.name,
                        prefix: drive.syncAnchor.prefix
                    )
                    if case let .conflicting(sampleKey) = state {
                        logger.warning("Thumbnail prefix conflict detected (sample: \(sampleKey, privacy: .public))")
                        showThumbnailConflict = true
                        return
                    }
                }

                try await finalizeDriveCreation(drive: drive)
            } catch {
                creationError = error
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }

        @MainActor
        private func finalizeDriveCreation(drive: DS3Drive) async throws {
            let sdk = DS3SDK(withAuthentication: ds3Authentication)
            _ = try await sdk.loadOrCreateDS3APIKeys(
                forIAMUser: drive.syncAnchor.IAMUser,
                ds3ProjectName: drive.syncAnchor.project.name
            )

            try await ds3DriveManager.add(drive: drive)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            setupViewModel.reset()
            onDismiss()
        }

        @MainActor
        private func proceedDespiteConflict() {
            showThumbnailConflict = false
            isCreating = true
            Task { await createDrive(skipThumbnailCheck: true) }
        }
    }

    // MARK: - Press Style

    private struct ConfirmPressableScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
