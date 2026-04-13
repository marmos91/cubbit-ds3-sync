import DS3Lib
import os.log
import SwiftUI

enum SyncSetupStep {
    case treeNavigation
    case driveConfirm
}

@MainActor @Observable
class SyncSetupViewModel {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.sync.rawValue)

    var selectedProject: Project?
    var selectedSyncAnchor: SyncAnchor?
    var selectedBucket: Bucket?
    var selectedPrefix: String?
    var setupStep: SyncSetupStep = .treeNavigation

    /// Set to `true` when `inspectThumbnailPrefix` returns `.conflicting`.
    /// The wizard shows `ThumbnailConflictWarningView` instead of proceeding.
    var thumbnailConflictDetected = false

    /// The drive pending creation while the conflict warning is shown.
    var pendingDrive: DS3Drive?

    /// Shared anchor-selection VM for the wizard session. Hoisted here so
    /// `BucketListView` and `PrefixListView` reuse the same `s3Client` and
    /// IAM credentials instead of forging a new token on every navigation
    /// push — which was triggering S3 `SlowDown` throttling on iOS.
    var anchorViewModel: SyncAnchorSelectionViewModel?

    /// Returns the existing anchor VM for `project`, or creates a new one
    /// if absent, bound to a different project, or bound to a stale
    /// `DS3Authentication` instance (e.g. after a re-login). Idempotent
    /// for the same project + auth so nested views can call it in `.task`
    /// blocks safely.
    func ensureAnchorViewModel(
        for project: Project,
        authentication: DS3Authentication
    ) -> SyncAnchorSelectionViewModel {
        if let existing = anchorViewModel,
           existing.project.id == project.id,
           existing.authentication === authentication {
            return existing
        }
        anchorViewModel?.shutdownClient()
        let vm = SyncAnchorSelectionViewModel(
            project: project,
            authentication: authentication
        )
        anchorViewModel = vm
        return vm
    }

    var suggestedDriveName: String {
        guard let bucket = selectedBucket else { return "" }
        return S3PathUtils.suggestedDriveName(bucketName: bucket.name, prefix: selectedPrefix)
    }

    func selectProject(project: Project) {
        self.selectedProject = project
    }

    func selectSyncAnchor(anchor: SyncAnchor) {
        self.selectedSyncAnchor = anchor
        self.selectedBucket = anchor.bucket
        self.selectedPrefix = anchor.prefix
        self.setupStep = .driveConfirm
    }

    func selectSyncSetupStep(_ step: SyncSetupStep) {
        self.setupStep = step
    }

    func goBack() {
        self.setupStep = .treeNavigation
    }

    // MARK: - Thumbnail conflict handling

    /// Navigate back to prefix selection, clearing the conflict state.
    func goBackToPrefix() {
        thumbnailConflictDetected = false
        pendingDrive = nil
        setupStep = .treeNavigation
    }

    /// Proceed with drive creation despite the thumbnail conflict.
    /// Returns the pending drive so the caller can add it via DS3DriveManager.
    func proceedDespiteConflict() -> DS3Drive? {
        thumbnailConflictDetected = false
        let drive = pendingDrive
        pendingDrive = nil
        return drive
    }

    /// Checks the thumbnail prefix state for the selected bucket/prefix.
    /// Returns `true` if a conflict was detected (caller should NOT proceed).
    /// Returns `false` on `.empty`, `.matchesOurs`, or any error (caller proceeds).
    func checkThumbnailConflict(drive: DS3Drive) async -> Bool {
        guard let s3Client = anchorViewModel?.s3Client else { return false }

        let state = await s3Client.inspectThumbnailPrefixWithTimeout(
            bucket: drive.syncAnchor.bucket.name,
            prefix: drive.syncAnchor.prefix
        )

        if case .conflicting = state {
            pendingDrive = drive
            thumbnailConflictDetected = true
            return true
        }

        return false
    }

    func reset() {
        self.selectedProject = nil
        self.selectedSyncAnchor = nil
        self.selectedBucket = nil
        self.selectedPrefix = nil
        self.setupStep = .treeNavigation
        self.thumbnailConflictDetected = false
        self.pendingDrive = nil
        self.anchorViewModel?.shutdownClient()
        self.anchorViewModel = nil
    }
}
