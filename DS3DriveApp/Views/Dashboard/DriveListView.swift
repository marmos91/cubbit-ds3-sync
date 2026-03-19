#if os(iOS)
import SwiftUI
import FileProvider
import DS3Lib

/// Main drive list view showing drive cards with real-time status, or empty state when no drives exist.
/// Supports pull-to-refresh, navigation to drive detail, and 3-drive limit enforcement.
struct DriveListView: View {
    @Environment(DS3DriveManager.self) private var ds3DriveManager

    @Binding var selectedDrive: DS3Drive?
    @Binding var showWizard: Bool

    let driveViewModel: IOSDriveViewModel

    var body: some View {
        Group {
            if ds3DriveManager.drives.isEmpty {
                EmptyDrivesView(onAddDrive: { showWizard = true })
            } else {
                driveList
            }
        }
        .navigationTitle("Drives")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showWizard = true
                } label: {
                    Image(systemName: "plus")
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
        List {
            Section {
                ForEach(ds3DriveManager.drives) { drive in
                    NavigationLink(value: drive) {
                        DriveCardView(
                            drive: drive,
                            status: driveViewModel.status(for: drive.id),
                            speed: driveViewModel.speed(for: drive.id),
                            onDisconnect: {
                                Task {
                                    try? await ds3DriveManager.disconnect(driveWithId: drive.id)
                                }
                            },
                            onPauseResume: {
                                driveViewModel.togglePause(for: drive.id)
                            }
                        )
                    }
                }
            }

            // Add Drive section
            if ds3DriveManager.drives.count < DefaultSettings.maxDrives {
                Section {
                    Button {
                        showWizard = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(IOSColors.accent)
                            Text("Add Drive")
                                .font(IOSTypography.body)
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(IOSColors.secondaryText)
                        Text("Maximum of \(DefaultSettings.maxDrives) drives reached")
                            .font(IOSTypography.caption)
                            .foregroundStyle(IOSColors.secondaryText)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await refreshDrives()
        }
    }

    // MARK: - Refresh

    private func refreshDrives() async {
        ds3DriveManager.drives = DS3DriveManager.loadFromDiskOrCreateNew()

        for drive in ds3DriveManager.drives {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                displayName: drive.name
            )
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }
}
#endif
