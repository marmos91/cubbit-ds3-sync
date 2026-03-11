import SwiftUI
import os.log
import DS3Lib

struct SetupSyncView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(\.dismiss) var dismiss
    
    @State var syncSetupViewModel: SyncSetupViewModel = SyncSetupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch syncSetupViewModel.setupStep {
            case .projectSelection:
                ProjectSelectionView(
                    projectSelectionViewModel: ProjectSelectionViewModel(
                        authentication: ds3Authentication
                    )
                )
                .onProjectSelected { project in
                    syncSetupViewModel.selectProject(project: project)
                }
            case .anchorSelection:
                SyncAnchorSelectionView(
                    syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel(
                        project: syncSetupViewModel.selectedProject!,
                        authentication: ds3Authentication
                    )
                )
                .onBack {
                    syncSetupViewModel.selectSyncSetupStep(.projectSelection)
                }
                .onSyncAnchorSelected { syncAnchor in
                    syncSetupViewModel.selectSyncAnchor(
                        anchor: syncAnchor
                    )
                }
            case .driveNameSelection:
                SyncRecapView(
                    syncRecapViewModel: SyncRecapViewModel(
                        syncAnchor: syncSetupViewModel.selectedSyncAnchor!
                    )
                )  
                .onBack {
                    syncSetupViewModel.selectSyncSetupStep(.anchorSelection)
                }
                .onComplete { ds3Drive in
                    let manager = ds3DriveManager
                    let dismiss = dismiss
                    Task {
                        do {
                            try await manager.add(drive: ds3Drive)
                        } catch {
                            // TODO: Show error
                            logger.error("Error adding drive: \(error.localizedDescription)")
                        }

                        dismiss()
                    }
                }
            }
        }
        .frame(
            minWidth: 800,
            maxWidth: 800,
            minHeight: 480,
            maxHeight: 480
        )
        .onWillDisappear {
            self.syncSetupViewModel.reset()
        }
    }
}

#Preview {
    SetupSyncView()
        .environment(DS3Authentication.loadFromPersistenceOrCreateNew())
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
}
