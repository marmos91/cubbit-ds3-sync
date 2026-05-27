import DS3Lib
import os.log
import SwiftUI

struct SetupSyncView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(\.dismiss) var dismiss

    @State private var syncSetupViewModel = SyncSetupViewModel()
    @State private var isCreating = false
    @State private var creationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if syncSetupViewModel.thumbnailConflictDetected {
                ThumbnailConflictWarningView(
                    onChooseDifferentPrefix: { syncSetupViewModel.goBackToPrefix() },
                    onUseAnyway: {
                        if let drive = syncSetupViewModel.proceedDespiteConflict() {
                            addDrive(drive)
                        }
                    }
                )
            } else {
                switch syncSetupViewModel.setupStep {
                case .treeNavigation:
                    TreeNavigationView(authentication: ds3Authentication)
                        .onSyncAnchorSelected { anchor in
                            syncSetupViewModel.selectSyncAnchor(anchor: anchor)
                        }
                case .driveConfirm:
                    if let syncAnchor = syncSetupViewModel.selectedSyncAnchor {
                        DriveConfirmView(
                            syncAnchor: syncAnchor,
                            suggestedName: syncSetupViewModel.suggestedDriveName
                        )
                        .onBack {
                            syncSetupViewModel.goBack()
                        }
                        .onComplete { ds3Drive in
                            let vm = syncSetupViewModel
                            Task {
                                let conflictDetected = await vm.checkThumbnailConflict(drive: ds3Drive)
                                if conflictDetected { return }
                                addDrive(ds3Drive)
                            }
                        }
                        .disabled(isCreating)
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

    @MainActor
    private func addDrive(_ drive: DS3Drive) {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        let manager = ds3DriveManager
        let dismiss = dismiss
        Task { @MainActor in
            defer { isCreating = false }
            do {
                try await manager.add(drive: drive)
                dismiss()
            } catch {
                logger.error("Error adding drive: \(error.localizedDescription, privacy: .public)")
                creationError = error.localizedDescription
            }
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
