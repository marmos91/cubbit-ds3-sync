import DS3Lib
import SwiftUI

enum SyncSetupStep {
    case treeNavigation
    case driveConfirm
}

@MainActor @Observable
class SyncSetupViewModel {
    var selectedProject: Project?
    var selectedSyncAnchor: SyncAnchor?
    var selectedBucket: Bucket?
    var selectedPrefix: String?
    var setupStep: SyncSetupStep = .treeNavigation

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

        if let prefix = selectedPrefix, !prefix.isEmpty {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lastComponent = trimmed.components(separatedBy: "/").last ?? trimmed
            return "\(bucket.name)/\(lastComponent)"
        }

        return bucket.name
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

    func reset() {
        self.selectedProject = nil
        self.selectedSyncAnchor = nil
        self.selectedBucket = nil
        self.selectedPrefix = nil
        self.setupStep = .treeNavigation
        self.anchorViewModel?.shutdownClient()
        self.anchorViewModel = nil
    }
}
