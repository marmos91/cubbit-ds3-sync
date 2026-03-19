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

            addDriveRow
        }
        .refreshable {
            await refreshDrives()
        }
    }

    // MARK: - Add Drive Row

    @ViewBuilder
    private var addDriveRow: some View {
        if ds3DriveManager.drives.count < DefaultSettings.maxDrives {
            Button {
                showWizard = true
            } label: {
                Label("Add Drive", systemImage: "plus")
                    .font(IOSTypography.body)
            }
        } else {
            HStack {
                Label("Add Drive", systemImage: "plus")
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
                Spacer()
                Text("Maximum 3 drives reached")
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSColors.secondaryText)
            }
            .accessibilityLabel("Add Drive, maximum 3 drives reached")
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
