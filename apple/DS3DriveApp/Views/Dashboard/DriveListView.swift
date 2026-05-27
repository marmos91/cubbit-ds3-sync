#if os(iOS)
    import DS3Lib
    import FileProvider
    import SwiftUI

    /// Main drive list — branded drive cards plus a dashed "Add Drive" tile.
    struct DriveListView: View {
        @Environment(DS3DriveManager.self) private var ds3DriveManager

        @Binding var selectedDrive: DS3Drive?
        @Binding var showWizard: Bool

        let driveViewModel: IOSDriveViewModel

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                if ds3DriveManager.drives.isEmpty {
                    EmptyDrivesView(onAddDrive: { showWizard = true })
                } else {
                    driveList
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Drives")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showWizard = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(IOSColors.brandPrimary)
                    }
                    .disabled(ds3DriveManager.drives.count >= DefaultSettings.maxDrives)
                }
            }
            .navigationDestination(for: DS3Drive.self) { drive in
                DriveDetailView(drive: drive, driveViewModel: driveViewModel)
            }
        }

        // MARK: - Drive List

        private var driveList: some View {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(ds3DriveManager.drives) { drive in
                        NavigationLink(value: drive) {
                            DriveCardView(
                                drive: drive,
                                status: driveViewModel.status(for: drive.id),
                                speed: driveViewModel.speed(for: drive.id)
                            )
                        }
                        .buttonStyle(DriveRowPressStyle())
                    }

                    if ds3DriveManager.drives.count < DefaultSettings.maxDrives {
                        addDriveTile
                    } else {
                        maxDrivesHint
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable {
                await refreshDrives()
            }
        }

        private var addDriveTile: some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showWizard = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(IOSColors.brandPrimary.opacity(0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(IOSColors.brandPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Drive")
                            .font(.custom("Figtree-SemiBold", size: 17))
                            .foregroundStyle(IOSColors.brandTextPrimary)
                        Text("Sync another S3 bucket or prefix")
                            .font(.custom("Figtree-Regular", size: 13))
                            .foregroundStyle(IOSColors.brandTextSecondary)
                    }

                    Spacer(minLength: 8)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            IOSColors.brandPrimary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )
            }
            .buttonStyle(DriveRowPressStyle())
        }

        private var maxDrivesHint: some View {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                Text("Maximum of \(DefaultSettings.maxDrives) drives reached")
                    .font(.custom("Figtree-Regular", size: 13))
                    .foregroundStyle(IOSColors.brandTextSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
            )
        }

        // MARK: - Refresh

        private func refreshDrives() async {
            ds3DriveManager.drives = DS3DriveManager.loadFromDiskOrCreateNew()

            for drive in ds3DriveManager.drives {
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                    displayName: drive.name
                )
                try? await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
            }
        }
    }

    // MARK: - Press Style

    private struct DriveRowPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .opacity(configuration.isPressed ? 0.93 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
