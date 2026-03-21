import SwiftUI
import os.log
import DS3Lib

struct ManageDS3DriveView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(\.dismiss) var dismiss
    @Environment(DS3DriveManager.self) var ds3DriveManager

    var ds3Drive: DS3Drive
    
    var body: some View {
        SyncRecapMainView(shouldDisplayBack: false)
            .onComplete { ds3Drive in
                let manager = ds3DriveManager
                let dismiss = dismiss
                Task {
                    do {
                        try await manager.update(drive: ds3Drive)
                    } catch {
                        logger.error("Error updating drive: \(error.localizedDescription)")
                    }
                    
                    dismiss()
                }
            }
            .environment(
                SyncRecapViewModel(
                    syncAnchor: ds3Drive.syncAnchor,
                    driveName: ds3Drive.name,
                    driveId: ds3Drive.id
                )
            )
            .frame(
                minWidth: 500,
                maxWidth: 500,
                minHeight: 400,
                maxHeight: 400
            )
    }
}

#Preview {
    ManageDS3DriveView(
        ds3Drive: PreviewData.drive
    )
    .environment(
        DS3DriveManager(appStatusManager: AppStatusManager.default())
    )
}
